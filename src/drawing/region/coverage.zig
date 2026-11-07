//! Occupied curve regions from vector pictures. Curves and native stroke
//! semantics are preserved during explicit curve-region normalization.
//! Independent paints are normalized before combination; tolerance belongs here.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const regions = @import("root.zig");
const DisplayList = @import("../DisplayList.zig");
const pen = @import("../pen/root.zig");
const Allocator = std.mem.Allocator;

const vectorization = @import("../outline.zig");
const StyledPath = vectorization.StyledPath;

const Collection = struct {
    allocator: Allocator,
    /// One canonical nonzero filled path per visible painted path command.
    /// A path may contain multiple components and holes. Independent commands
    /// remain separate and retain their drawing order.
    paths: []Path,

    pub fn deinit(self: *Collection) void {
        for (self.paths) |*path| path.deinit();
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

/// Convert a vector picture into a nonzero filled curve region. Every
/// primitive is normalized separately, so independent reversed paints cannot
/// cancel each other. The result owns its storage; the picture stays borrowed.
pub fn extract(allocator: Allocator, source: *const DisplayList, options: regions.Options) !Path {
    var collection = try collect(allocator, source, options);
    defer collection.deinit();
    var result = Path.init(allocator);
    errdefer result.deinit();
    for (collection.paths) |path| try result.append(path);
    return result;
}

fn collect(allocator: Allocator, source: *const DisplayList, options: regions.Options) !Collection {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.tolerance * 0.25 == 0) return error.PrecisionRange;
    if (options.max_segments == 0 or options.max_vertices == 0 or options.max_depth > 64) return error.GeometryWorkLimit;
    var builder: Builder = .{ .allocator = allocator, .options = options };
    errdefer builder.deinit();
    try builder.visitPicture(source, .{}, 0);
    return .{ .allocator = allocator, .paths = try builder.output.toOwnedSlice(allocator) };
}

const State = struct {
    transform: g.Transform = .{},
    /// null means unbounded; a present empty path means empty visibility.
    clip: ?*const Path = null,
};
const Builder = struct {
    allocator: Allocator,
    options: regions.Options,
    output: std.ArrayList(Path) = .empty,
    segments: usize = 0,
    vertices: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.output.items) |*path| path.deinit();
        self.output.deinit(self.allocator);
    }

    fn remaining(self: *const Builder, tolerance: f64) !regions.Options {
        if (self.segments >= self.options.max_segments or self.vertices >= self.options.max_vertices) return error.GeometryWorkLimit;
        var result = self.options;
        result.max_segments -= self.segments;
        result.max_vertices -= self.vertices;
        result.tolerance = tolerance;
        result.fill_rule = .nonzero;
        return result;
    }

    /// Validate even invisible source geometry; counting actual control points
    /// also bounds inputs with many moves or degenerate segments.
    fn consume(self: *Builder, path: Path) !void {
        var active = false;
        var count_segments: usize = 0;
        var count_vertices: usize = 0;
        for (path.segments.items) |segment| switch (segment) {
            .move => |point| {
                if (!point.isFinite()) return error.NonFinite;
                active = true;
                count_vertices = std.math.add(usize, count_vertices, 1) catch return error.GeometryWorkLimit;
            },
            .line => |point| {
                if (!active) return error.InvalidPath;
                if (!point.isFinite()) return error.NonFinite;
                count_segments = std.math.add(usize, count_segments, 1) catch return error.GeometryWorkLimit;
                count_vertices = std.math.add(usize, count_vertices, 1) catch return error.GeometryWorkLimit;
            },
            .cubic => |curve| {
                if (!active) return error.InvalidPath;
                if (!curve.c1.isFinite() or !curve.c2.isFinite() or !curve.end.isFinite()) return error.NonFinite;
                count_segments = std.math.add(usize, count_segments, 1) catch return error.GeometryWorkLimit;
                count_vertices = std.math.add(usize, count_vertices, 3) catch return error.GeometryWorkLimit;
            },
            .close => {
                if (!active) return error.InvalidPath;
                active = false;
                count_segments = std.math.add(usize, count_segments, 1) catch return error.GeometryWorkLimit;
            },
        };
        if (count_segments > self.options.max_segments - self.segments or count_vertices > self.options.max_vertices - self.vertices) return error.GeometryWorkLimit;
        self.segments += count_segments;
        self.vertices += count_vertices;
    }

    fn combine(self: *Builder, a: Path, b: Path, operation: regions.Operation, rule: regions.FillRule) !Path {
        var options = try self.remaining(self.options.tolerance);
        options.fill_rule = rule;
        var result = try regions.combine(self.allocator, a, b, operation, options);
        errdefer result.deinit();
        try self.consume(result);
        return result;
    }

    fn region(self: *Builder, path: Path, transform: g.Transform, rule: regions.FillRule) !Path {
        var closed = try closeFill(self.allocator, path);
        defer closed.deinit();
        try closed.transform(transform);
        return self.combine(closed, Path.init(self.allocator), .unite, rule);
    }

    fn strokeOptions(self: *const Builder, paint: DisplayList.Pen, tolerance: f64) !pen.StrokeOptions {
        const options = try self.remaining(tolerance);
        return .{
            .tolerance = tolerance,
            .max_segments = options.max_segments,
            .max_vertices = options.max_vertices,
            .max_depth = options.max_depth,
            .cap = paint.cap,
            .join = paint.join,
            .miter_limit = paint.miter_limit,
        };
    }

    fn stroke(self: *Builder, path: Path, paint: DisplayList.Pen, transform: g.Transform) !Path {
        const tolerance = try localTolerance(self.options.tolerance, transform);
        if (paint.motion) |motion| {
            var expanded = try pen.motionOutline(self.allocator, path, &paint, try self.strokeOptions(paint, @min(tolerance, motion.tolerance)));
            defer expanded.deinit();
            try self.consume(expanded);
            return self.region(expanded, transform, .nonzero);
        }
        var dashed: ?Path = null;
        defer if (dashed) |*value| value.deinit();
        const center = if (paint.dash.len == 0) path else value: {
            dashed = pen.dashed(self.allocator, path, paint.dash, paint.dash_phase, try self.strokeOptions(paint, tolerance)) catch |err| switch (err) {
                error.StrokeWorkLimit => return error.GeometryWorkLimit,
                else => return err,
            };
            try self.consume(dashed.?);
            break :value dashed.?;
        };
        var nib = paint.nib orelse pen.Nib{ .ellipse = g.Transform.scaling(paint.width, paint.width) };
        var normalized = if (paint.nib != null) try nib.normalizePath(self.allocator, center) else null;
        defer if (normalized) |*value| value.deinit();
        const placement = if (normalized != null) nib.ellipse.then(transform) else transform;
        if (normalized != null) nib = .{ .ellipse = g.Transform.scaling(1, 1) };
        const stroke_tolerance = if (paint.nib == null or normalized != null) try localTolerance(self.options.tolerance, placement) else tolerance;
        // Every native stroke style uses the same physical envelope.
        var expanded = pen.strokeOutline(self.allocator, nib, normalized orelse center, try self.strokeOptions(paint, stroke_tolerance)) catch |err| switch (err) {
            error.StrokeWorkLimit => return error.GeometryWorkLimit,
            else => return err,
        };
        defer expanded.deinit();
        try self.consume(expanded);
        return self.region(expanded, placement, .nonzero);
    }

    fn painted(self: *Builder, styled: StyledPath, state: State) !void {
        try DisplayList.validateStyle(&styled.style);
        try self.consume(styled.path);
        const transform = styled.transform.then(state.transform);
        if (!transform.isFinite()) return error.NonFinite;
        if (state.clip) |clip| if (clip.segments.items.len == 0) return;
        var fill: ?Path = null;
        defer if (fill) |*value| value.deinit();
        if (styled.style.hasInk(.fill)) {
            fill = try self.region(styled.path, transform, if (styled.style.fill_rule == .evenodd) .evenodd else .nonzero);
        }
        var outline: ?Path = null;
        defer if (outline) |*value| value.deinit();
        if (styled.style.pen) |paint| if (styled.style.hasInk(.stroke) and (paint.needsGeometry() or paint.width != 0)) {
            outline = try self.stroke(styled.path, paint, transform);
        };
        if (fill == null and outline == null) return;
        var result = if (fill != null and outline != null)
            try self.combine(fill.?, outline.?, .unite, .nonzero)
        else if (fill) |value| value else outline.?;
        if (fill == null or outline == null) {
            fill = null;
            outline = null;
        }
        errdefer result.deinit();
        if (state.clip) |clip| {
            const clipped = try self.combine(result, clip.*, .intersect, .nonzero);
            result.deinit();
            result = clipped;
        }
        if (result.segments.items.len == 0) {
            result.deinit();
            return;
        }
        try self.output.append(self.allocator, result);
    }

    fn visitPicture(self: *Builder, value: *const DisplayList, state: State, depth: usize) anyerror!void {
        if (value.scope_depth != 0) return error.UnbalancedGroups;
        var index: usize = 0;
        try self.commands(value, &index, state, depth, false);
    }

    fn commands(self: *Builder, value: *const DisplayList, index: *usize, state: State, depth: usize, grouped: bool) anyerror!void {
        if (depth > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
        while (index.* < value.commands.items.len) {
            const command = value.commands.items[index.*];
            index.* += 1;
            switch (command) {
                .path => |draw| try self.painted(.{ .path = try value.geometry().view(self.allocator, draw.path), .style = draw.style.*, .transform = draw.transform }, state),
                .push => |group| {
                    var child: State = .{ .transform = group.transform.then(state.transform), .clip = state.clip };
                    if (!child.transform.isFinite()) return error.NonFinite;
                    var owned_clip: ?Path = null;
                    defer if (owned_clip) |*clip| clip.deinit();
                    if (group.clip) |reference| {
                        const clip = try value.geometry().view(self.allocator, reference);
                        try self.consume(clip);
                        owned_clip = try self.region(clip, child.transform, .nonzero);
                        if (state.clip) |parent| {
                            const intersection = try self.combine(owned_clip.?, parent.*, .intersect, .nonzero);
                            owned_clip.?.deinit();
                            owned_clip = intersection;
                        }
                        child.clip = &owned_clip.?;
                    }
                    try self.commands(value, index, child, depth + 1, true);
                },
                .pop => {
                    if (!grouped) return error.UnbalancedGroups;
                    return;
                },
                .label => {
                    if (state.clip) |clip| if (clip.segments.items.len == 0) continue;
                    return error.LabelResolverRequired;
                },
            }
        }
        if (grouped) return error.UnbalancedGroups;
    }
};

/// Filling implicitly closes every open contour, including those followed by
/// another moveto. Rebuild using Path's checks rather than inventing an edge
/// interpretation or relying on its cached final-subpath state.
fn closeFill(allocator: Allocator, path: Path) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (result.open) try result.close();
            try result.moveTo(point);
        },
        .line => |point| try result.lineTo(point),
        .cubic => |curve| try result.cubicTo(curve.c1, curve.c2, curve.end),
        .close => try result.close(),
    };
    if (result.open) try result.close();
    return result;
}

fn localTolerance(tolerance: f64, transform: g.Transform) !f64 {
    if (!transform.isFinite()) return error.NonFinite;
    // The Frobenius norm bounds the largest singular value. Reserving half
    // the world tolerance for expansion leaves room for final normalization.
    const norm = std.math.hypot(std.math.hypot(transform.a, transform.b), std.math.hypot(transform.c, transform.d));
    if (!std.math.isFinite(norm)) return error.PrecisionRange;
    const result = (tolerance * 0.5) / @max(@as(f64, 1), norm);
    if (result * 0.25 == 0) return error.PrecisionRange;
    return result;
}

fn rectangle(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y + height });
    try result.lineTo(.{ .x = x, .y = y + height });
    try result.close();
    return result;
}

fn area(path: Path) f64 {
    return path.signedArea();
}

fn contains(path: Path, point: g.Point) bool {
    // Independent test probes are deliberately away from the boundary. Only
    // this test oracle samples curves; region construction keeps them native.
    for (path.segments.items) |segment| if (segment == .cubic) {
        var flat = @import("../path/flatten.zig").flatten(std.testing.allocator, path, .{ .tolerance = 1e-8, .length_tolerance = 1e-8, .max_segments = 1048576, .max_depth = 32 }) catch @panic("test reference flattening failed");
        defer flat.deinit();
        return contains(flat, point);
    };
    var winding: i32 = 0;
    var current = g.Point.zero;
    var start = g.Point.zero;
    for (path.segments.items) |segment| {
        const end = switch (segment) {
            .move => |value| {
                current = value;
                start = value;
                continue;
            },
            .line => |value| value,
            .close => start,
            .cubic => unreachable,
        };
        const cross = end.sub(current).cross(point.sub(current));
        if (current.y <= point.y and end.y > point.y and cross > 0) winding += 1;
        if (current.y > point.y and end.y <= point.y and cross < 0) winding -= 1;
        current = end;
    }
    return winding != 0;
}

fn extractFixture(allocator: Allocator, source: vectorization.Source, options: regions.Options, resolver: anytype) !Collection {
    // The adapter itself never resolves labels. Tests can supply an already
    // vector picture or exercise the complete vectorization-to-region route.
    if (@TypeOf(resolver) == @TypeOf(null) and source == .picture) return collect(allocator, source.picture, options);
    var vector = try vectorization.extract(allocator, source, resolver);
    defer vector.deinit();
    return collect(allocator, &vector, options);
}

test "raw filled regions close implicitly and preserve explicit fill rules and holes" {
    const t = std.testing;
    var outer = try rectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    var inner = try rectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    try outer.append(inner);
    var nonzero = try extractFixture(t.allocator, .{ .path = outer }, .{ .fill_rule = .evenodd }, null);
    defer nonzero.deinit();
    try t.expectEqual(@as(usize, 1), nonzero.paths.len);
    try t.expectApproxEqAbs(@as(f64, 100), area(nonzero.paths[0]), 1e-8);
    var evenodd = try extractFixture(t.allocator, .{ .styled = .{ .path = outer, .style = .{ .fill = .black, .fill_rule = .evenodd }, .transform = g.Transform.scaling(-1, 1) } }, .{}, null);
    defer evenodd.deinit();
    try t.expectApproxEqAbs(@as(f64, 64), area(evenodd.paths[0]), 1e-8);
    try t.expect(contains(evenodd.paths[0], .{ .x = -1, .y = 1 }));
    try t.expect(!contains(evenodd.paths[0], .{ .x = -5, .y = 5 }));
    var triangle = Path.init(t.allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 0, .y = 10 });
    var implicit = try extractFixture(t.allocator, .{ .path = triangle }, .{}, null);
    defer implicit.deinit();
    try t.expectApproxEqAbs(@as(f64, 50), area(implicit.paths[0]), 1e-8);
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var zero_area = try extractFixture(t.allocator, .{ .path = line }, .{}, null);
    defer zero_area.deinit();
    try t.expectEqual(@as(usize, 0), zero_area.paths.len);
    var empty = try extractFixture(t.allocator, .{ .path = Path.init(t.allocator) }, .{}, null);
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.paths.len);
}

test "painted paths union filldraw internally and preserve order across reflected primitives" {
    const t = std.testing;
    var square = try rectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.fill(square, .{ .a = 0 }, .{});
    try pic.filldraw(square, .{ .a = 0.2 }, .{ .width = 2 }, .{});
    try pic.fill(square, .black, g.Transform.scaling(-1, 1).then(g.Transform.translation(10, 0)));
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{}, null);
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 144), area(result.paths[0]), 1e-8);
    try t.expectApproxEqAbs(@as(f64, 100), area(result.paths[1]), 1e-8);
    try t.expectEqual(@as(f64, -1), result.paths[0].bounds().?.min.x);
    try t.expectEqual(@as(f64, 0), result.paths[1].bounds().?.min.x);
    var singular = try extractFixture(t.allocator, .{ .styled = .{ .path = square, .style = .{ .fill = .black }, .transform = g.Transform.scaling(0, 1) } }, .{}, null);
    defer singular.deinit();
    try t.expectEqual(@as(usize, 0), singular.paths.len);
}

test "stroke expansion precedes affine transforms and supports ellipse offsets and dash dots" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var scaled = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 2 } }, .transform = g.Transform.scaling(2, 3) } }, .{}, null);
    defer scaled.deinit();
    try t.expectApproxEqAbs(@as(f64, 120), area(scaled.paths[0]), 1e-8);
    try t.expectApproxEqAbs(@as(f64, 6), scaled.paths[0].bounds().?.height(), 1e-8);
    var ellipse = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 0, .cap = .round, .nib = .{ .ellipse = .{ .a = 8, .d = 2, .e = 3, .f = 4 } } } } } }, .{}, null);
    defer ellipse.deinit();
    const box = ellipse.paths[0].bounds().?;
    try t.expectApproxEqAbs(@as(f64, -1), box.min.x, 0.002);
    try t.expectApproxEqAbs(@as(f64, 17), box.max.x, 0.002);
    try t.expectApproxEqAbs(@as(f64, 3), box.min.y, 0.002);
    try t.expectApproxEqAbs(@as(f64, 5), box.max.y, 0.002);
    var dots = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 2, .cap = .round, .dash = &.{ 0, 5 } } } } }, .{}, null);
    defer dots.deinit();
    try t.expectEqual(@as(usize, 1), dots.paths.len);
    try t.expect(contains(dots.paths[0], .{ .x = 0, .y = 0 }));
    try t.expect(contains(dots.paths[0], .{ .x = 5, .y = 0 }));
    try t.expect(!contains(dots.paths[0], .{ .x = 2.5, .y = 0 }));
    var hairline = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 0 } } } }, .{}, null);
    defer hairline.deinit();
    try t.expectEqual(@as(usize, 0), hairline.paths.len);
}

test "nested clipping uses the actual curved region and preserves empty intersections" {
    const t = std.testing;
    var circle = try Path.circle(t.allocator, .zero, 10);
    defer circle.deinit();
    var half = try rectangle(t.allocator, 0, -20, 20, 40);
    defer half.deinit();
    var large = try rectangle(t.allocator, -20, -20, 40, 40);
    defer large.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.beginScope(g.Transform.translation(100, 50), circle);
    try pic.beginScope(.{}, half);
    try pic.fill(large, .black, .{});
    try pic.endScope();
    try pic.endScope();
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{ .tolerance = 0.01 }, null);
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 50 * std.math.pi), area(result.paths[0]), 0.1);
    try t.expect(contains(result.paths[0], .{ .x = 105, .y = 50 }));
    try t.expect(!contains(result.paths[0], .{ .x = 109, .y = 59 }));
    var empty_clip = Path.init(t.allocator);
    defer empty_clip.deinit();
    try empty_clip.moveTo(.zero);
    try empty_clip.lineTo(.{ .x = 1, .y = 0 });
    try empty_clip.close();
    var invisible = DisplayList.init(t.allocator);
    defer invisible.deinit();
    try invisible.beginScope(.{}, empty_clip);
    try invisible.fill(large, .black, .{});
    try invisible.addLabel(99, .{ .width = 10, .height = 10, .baseline = 8 }, .{});
    try invisible.endScope();
    var none = try extractFixture(t.allocator, .{ .picture = &invisible }, .{}, null);
    defer none.deinit();
    try t.expectEqual(@as(usize, 0), none.paths.len);
}

test "ordinary miter strokes bevel at the SVG limit including limit one" {
    const t = std.testing;
    var corner = Path.init(t.allocator);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 10, .y = 0 });
    try corner.lineTo(.{ .x = 10, .y = 10 });
    var one = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 1 } } } }, .{}, null);
    defer one.deinit();
    try t.expect(contains(one.paths[0], .{ .x = 10.1, .y = -0.1 }));
    try t.expect(!contains(one.paths[0], .{ .x = 10.9, .y = -0.9 }));
    var full = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 4 } } } }, .{}, null);
    defer full.deinit();
    try t.expect(contains(full.paths[0], .{ .x = 10.9, .y = -0.9 }));
    corner.deinit();
    corner = Path.init(t.allocator);
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 10, .y = 0 });
    try corner.lineTo(.{ .x = 0, .y = 1 });
    var acute = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 4 } } } }, .{}, null);
    defer acute.deinit();
    try t.expect(acute.paths[0].bounds().?.max.x < 10.11);
    try t.expect(!contains(acute.paths[0], .{ .x = 10.5, .y = -0.5 }));
}

test "wide almost straight bevel strokes do not grow a miter tip" {
    const t = std.testing;
    var corner = Path.init(t.allocator);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 1000, .y = 0 });
    try corner.lineTo(.{ .x = 2000, .y = 20 });
    var bevel = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 1000, .join = .bevel } } } }, .{}, null);
    defer bevel.deinit();
    var miter = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 1000, .join = .miter } } } }, .{}, null);
    defer miter.deinit();
    const between: g.Point = .{ .x = 1005, .y = -499.975 };
    try t.expect(!contains(bevel.paths[0], between));
    try t.expect(contains(miter.paths[0], between));
}

const TestLabels = struct {
    calls: *usize,
    pub fn resolveOutline(self: @This(), allocator: Allocator, reference: u32) !DisplayList {
        self.calls.* += 1;
        if (reference != 7) return error.UnknownTestReference;
        var result = DisplayList.init(allocator);
        errdefer result.deinit();
        var glyph = try rectangle(allocator, 0, 0, 10, 10);
        defer glyph.deinit();
        var clip = try rectangle(allocator, 0, 0, 5, 10);
        defer clip.deinit();
        try result.beginScope(.{}, clip);
        try result.fill(glyph, .black, .{});
        try result.endScope();
        return result;
    }
};

test "label resolution composes frame-local transforms with ancestor clips and releases temporary pictures" {
    const t = std.testing;
    var clip = try rectangle(t.allocator, 10, 20, 5, 5);
    defer clip.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.beginScope(g.Transform.translation(100, 50), clip);
    try pic.labelAtBaseline(7, .{ .width = 10, .height = 10, .baseline = 8 }, .{ .x = 10, .y = 17 }, .{});
    try pic.endScope();
    try t.expectError(error.LabelResolverRequired, extractFixture(t.allocator, .{ .picture = &pic }, .{}, null));
    var calls: usize = 0;
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{}, TestLabels{ .calls = &calls });
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), calls);
    try t.expectEqual(@as(usize, 1), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 25), area(result.paths[0]), 1e-8);
    try t.expectEqual(g.Point{ .x = 110, .y = 70 }, result.paths[0].bounds().?.min);
    try t.expectEqual(g.Point{ .x = 115, .y = 75 }, result.paths[0].bounds().?.max);
}

test "work budgets accumulate across independent picture commands" {
    const t = std.testing;
    var square = try rectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var one = try extractFixture(t.allocator, .{ .path = square }, .{ .max_segments = 20, .max_vertices = 20 }, null);
    defer one.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.fill(square, .black, .{});
    try pic.fill(square, .black, g.Transform.translation(20, 0));
    try t.expectError(error.GeometryWorkLimit, extractFixture(t.allocator, .{ .picture = &pic }, .{ .max_segments = 14 }, null));
    try t.expectError(error.GeometryWorkLimit, extractFixture(t.allocator, .{ .picture = &pic }, .{ .max_vertices = 14 }, null));
    try t.expectError(error.InvalidTolerance, extractFixture(t.allocator, .{ .path = square }, .{ .tolerance = 0 }, null));
    var invalid = Path.init(t.allocator);
    defer invalid.deinit();
    try invalid.segments.append(t.allocator, .{ .line = .zero });
    try t.expectError(error.InvalidPath, extractFixture(t.allocator, .{ .styled = .{ .path = invalid, .style = .{ .fill = .{ .a = 0 } } } }, .{}, null));
    try t.expectError(error.GroupNestingTooDeep, recursionExercise(t.allocator));
}

const RecursiveLabels = struct {
    pub fn resolveOutline(_: @This(), allocator: Allocator, _: u32) !DisplayList {
        var pic = DisplayList.init(allocator);
        errdefer pic.deinit();
        try pic.addLabel(0, .{ .width = 1, .height = 1, .baseline = 0 }, .{});
        return pic;
    }
};
fn recursionExercise(allocator: Allocator) !void {
    var pic = try RecursiveLabels.resolveOutline(.{}, allocator, 0);
    defer pic.deinit();
    var result = try extractFixture(allocator, .{ .picture = &pic }, .{}, RecursiveLabels{});
    defer result.deinit();
}

fn allocationExercise(allocator: Allocator) !void {
    var path = try rectangle(allocator, 0, 0, 10, 10);
    defer path.deinit();
    var pic = DisplayList.init(allocator);
    defer pic.deinit();
    try pic.beginScope(.{}, path);
    try pic.filldraw(path, .black, .{ .nib = pen.Nib.square(), .dash = &.{ 3, 2 } }, .{});
    try pic.labelAtBaseline(7, .{ .width = 10, .height = 10, .baseline = 8 }, .{ .x = 1, .y = 0 }, .{});
    try pic.endScope();
    var calls: usize = 0;
    var result = try extractFixture(allocator, .{ .picture = &pic }, .{}, TestLabels{ .calls = &calls });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
}
test "extraction unwinds all owned paths clips labels and collections on allocation failure" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}

fn publicRegionExercise(allocator: Allocator) !void {
    var square = try rectangle(allocator, 0, 0, 10, 10);
    defer square.deinit();
    var reversed = try square.reverse(allocator);
    defer reversed.deinit();
    var ring = try rectangle(allocator, 20, 0, 10, 10);
    defer ring.deinit();
    var hole = try rectangle(allocator, 22, 2, 6, 6);
    defer hole.deinit();
    try ring.append(hole);
    var source = DisplayList.init(allocator);
    defer source.deinit();
    try source.fill(square, .black, .{});
    try source.fill(reversed, .black, g.Transform.translation(5, 0));
    try source.addPath(ring, .{ .fill = .black, .fill_rule = .evenodd }, .{});
    try source.fill(square, .{ .a = 0 }, g.Transform.translation(40, 0));
    var result = try extract(allocator, &source, .{});
    defer result.deinit();
    source.storage.segments.clearRetainingCapacity();
    try std.testing.expect(contains(result, .{ .x = 7, .y = 5 }));
    try std.testing.expect(contains(result, .{ .x = 12, .y = 5 }));
    try std.testing.expect(contains(result, .{ .x = 21, .y = 1 }));
    try std.testing.expect(!contains(result, .{ .x = 25, .y = 5 }));
    try std.testing.expect(!contains(result, .{ .x = 45, .y = 5 }));
}

test "public region conversion keeps independent winding and frees aggregation storage on OOM" {
    try publicRegionExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), publicRegionExercise, .{});
}
