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

pub const Collection = struct {
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

pub fn collect(allocator: Allocator, source: *const DisplayList, options: regions.Options) !Collection {
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
                    // A group at opacity 0 leaves no ink, like an empty clip.
                    if (group.opacity == 0) {
                        if (owned_clip) |*clip| clip.deinit();
                        owned_clip = Path.init(self.allocator);
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

test {
    _ = @import("coverage/paint_test.zig");
    _ = @import("coverage/picture_test.zig");
}
