//! Adaptive cubic reconstruction under a point operator. Mapping only the
//! original control points is valid for affine transformations, not nonlinear ones.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const outline = @import("../outline.zig");

pub const Options = struct {
    tolerance: f64 = 1e-3,
    /// Bound source control-polygon steps, as in nonlinear drawing systems.
    /// Tolerance is additionally checked at interior parameter samples.
    max_step: f64 = 1,
    max_segments: usize = 65536,
    max_depth: usize = 24,

    pub fn validate(self: Options) !void {
        if (!std.math.isFinite(self.tolerance) or self.tolerance <= 0 or !std.math.isFinite(self.max_step) or self.max_step <= 0) return error.InvalidTolerance;
        if (self.max_depth > 64 or self.max_segments == 0) return error.GeometryWorkLimit;
    }
};

/// `operator.point(Point) !Point` maps ordinary coordinates. The caller owns
/// its context; the result owns all geometry. No callback is retained.
pub fn mapped(allocator: std.mem.Allocator, source: Path, operator: anytype, options: Options) !Path {
    try options.validate();
    if (source.segments.items.len > options.max_segments) return error.GeometryWorkLimit;
    const Builder = struct {
        result: Path,
        operator: @TypeOf(operator),
        options: Options,
        visits: usize = 0,

        fn point(self: *@This(), p: g.Point) !g.Point {
            if (!p.isFinite()) return error.NonFinite;
            const out = try self.operator.point(p);
            if (!out.isFinite()) return error.NonFinite;
            return out;
        }

        fn cubic(self: *@This(), source_curve: g.Cubic, depth: usize) anyerror!void {
            self.visits += 1;
            if (self.visits > self.options.max_segments *| 2) return error.GeometryWorkLimit;
            const p0 = try self.point(source_curve.p0);
            const p3 = try self.point(source_curve.p3);
            const a = (try self.point(source_curve.at(1.0 / 3.0))).sub(p0);
            const b = (try self.point(source_curve.at(2.0 / 3.0))).sub(p0);
            const c = p3.sub(p0);
            // Cubic interpolation at four equally spaced parameters, using
            // relative coordinates to avoid cancellation at large origins.
            const curve = g.Cubic{ .p0 = p0, .p1 = p0.add(a.scale(3).sub(b.scale(1.5)).add(c.scale(1.0 / 3.0))), .p2 = p0.add(b.scale(3).sub(a.scale(1.5)).sub(c.scale(5.0 / 6.0))), .p3 = p3 };
            var accept = @max(source_curve.p0.distance(source_curve.p1), @max(source_curve.p1.distance(source_curve.p2), source_curve.p2.distance(source_curve.p3))) <= self.options.max_step;
            for ([_]f64{ 0.25, 0.5, 0.75 }) |t| {
                if ((try self.point(source_curve.at(t))).distance(curve.at(t)) > self.options.tolerance) accept = false;
            }
            if (accept) {
                if (self.result.segments.items.len >= self.options.max_segments) return error.GeometryWorkLimit;
                try self.result.cubicTo(curve.p1, curve.p2, curve.p3);
            } else {
                if (depth >= self.options.max_depth) return error.GeometryWorkLimit;
                const halves = source_curve.split(0.5);
                try self.cubic(halves.left, depth + 1);
                try self.cubic(halves.right, depth + 1);
            }
        }
    };
    var builder = Builder{ .result = Path.init(allocator), .operator = operator, .options = options };
    errdefer builder.result.deinit();
    var current: ?g.Point = null;
    var start: ?g.Point = null;
    for (source.segments.items) |segment| switch (segment) {
        .move => |p| {
            current = p;
            start = p;
            try builder.result.moveTo(try builder.point(p));
        },
        .line, .close => {
            const from = current orelse return error.InvalidPath;
            const to = if (segment == .line) segment.line else start.?;
            if (segment == .line or !std.meta.eql(from, to)) try builder.cubic(g.Cubic.line(from, to), 0);
            current = to;
            if (segment == .close) {
                try builder.result.close();
                current = null;
            }
        },
        .cubic => |c| {
            try builder.cubic(.{ .p0 = current orelse return error.InvalidPath, .p1 = c.c1, .p2 = c.c2, .p3 = c.end }, 0);
            current = c.end;
        },
    };
    if (builder.result.segments.items.len > options.max_segments) return error.GeometryWorkLimit;
    return builder.result;
}

/// Map path geometry and clips, then draw with the original paints. Existing
/// affine placement is retained, so stroke widths/dashes/nibs are not warped.
/// Native labels need explicit outlines first; implicit text conversion would
/// lose selectable PDF text. No source command or borrowed style is changed.
pub fn picture(allocator: std.mem.Allocator, source: *const DisplayList, operator: anytype, options: Options) !DisplayList {
    try options.validate();
    if (source.scope_depth != 0) return error.UnbalancedGroups;
    try outline.ensureWithinBudget(source);
    var result = DisplayList.init(allocator);
    errdefer result.deinit();
    var transforms: [DisplayList.max_scope_depth + 1]g.Transform = undefined;
    transforms[0] = .{};
    var depth: usize = 0;
    const Coordinates = struct {
        operator: @TypeOf(operator),
        transform: g.Transform,
        inverse: g.Transform,
        fn init(op: @TypeOf(operator), transform: g.Transform) !?@This() {
            const inverse = transform.inverse() catch |err| switch (err) {
                error.SingularTransform => return null,
                else => return err,
            };
            return .{ .operator = op, .transform = transform, .inverse = inverse };
        }
        pub fn point(self: @This(), p: g.Point) !g.Point {
            return self.inverse.apply(try self.operator.point(self.transform.apply(p)));
        }
        fn localOptions(self: @This(), options_: Options) Options {
            // Largest singular value of a 2x2 matrix: world-space tolerance
            // and step size scale with placement, but not with an isometry.
            const t = self.transform;
            const norm = std.math.hypot(t.a * 0.5 + t.d * 0.5, t.b * 0.5 - t.c * 0.5) + std.math.hypot(t.a * 0.5 - t.d * 0.5, t.b * 0.5 + t.c * 0.5);
            var result_ = options_;
            result_.tolerance /= norm;
            result_.max_step /= norm;
            return result_;
        }
    };
    for (source.commands.items) |command| switch (command) {
        .push => |group| {
            if (depth == DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
            transforms[depth + 1] = group.transform.then(transforms[depth]);
            depth += 1;
            var clip: ?Path = null;
            defer if (clip) |*value| value.deinit();
            if (group.clip) |reference| if (try Coordinates.init(operator, transforms[depth])) |coordinates| {
                var local = Path.init(allocator);
                local.segments.items = @constCast(try source.range(reference));
                var remaining = options;
                remaining.max_segments -= result.storage.segments.items.len;
                clip = try mapped(allocator, local, coordinates, coordinates.localOptions(remaining));
            };
            try result.beginScope(group.transform, clip);
        },
        .pop => {
            if (depth == 0) return error.UnbalancedGroups;
            depth -= 1;
            try result.endScope();
        },
        .label => return error.LabelResolverRequired,
        .path => |draw| {
            var local = Path.init(allocator);
            local.segments.items = @constCast(try source.range(draw.path));
            // A singular placement has zero-area ink. Otherwise conjugate
            // the point map by its placement and retain the original style.
            const coordinates = try Coordinates.init(operator, draw.transform.then(transforms[depth])) orelse continue;
            var remaining = options;
            remaining.max_segments -= result.storage.segments.items.len;
            var bent = try mapped(allocator, local, coordinates, coordinates.localOptions(remaining));
            defer bent.deinit();
            try result.addPath(bent, draw.style.*, draw.transform);
        },
    };
    if (depth != 0) return error.UnbalancedGroups;
    try outline.ensureWithinBudget(&result);
    return result;
}

test "point operators bend straight segments and implicit closing edges" {
    const Warp = struct {
        pub fn point(_: @This(), p: g.Point) !g.Point {
            return .{ .x = p.x, .y = p.y + p.x * p.x / 8 };
        }
    };
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 16, .y = 0 });
    try source.close();
    var result = try mapped(std.testing.allocator, source, Warp{}, .{});
    defer result.deinit();
    try std.testing.expect(result.segments.items[result.segments.items.len - 1] == .close);
    for (0..result.segmentCount()) |i| {
        const section = try result.curveAt(@floatFromInt(i));
        for ([_]f64{ 0.13, 0.37, 0.61, 0.91 }) |t| {
            const p = section.curve.at(t);
            try std.testing.expectApproxEqAbs(p.x * p.x / 8, p.y, 1e-11);
        }
    }
    try std.testing.expectError(error.GeometryWorkLimit, mapped(std.testing.allocator, source, Warp{}, .{ .max_segments = 3 }));

    var drawing = DisplayList.init(std.testing.allocator);
    defer drawing.deinit();
    try drawing.beginScope(g.Transform.translation(2, 3), source);
    const fill: DisplayList.Color = .{ .r = 1, .a = 0.5 };
    const stroke: DisplayList.Color = .{ .b = 1, .a = 0.7 };
    const placement: g.Transform = .{ .a = -2, .c = 0.5, .d = 3, .e = 4 };
    try drawing.filldraw(source, fill, .{ .color = stroke, .width = 0.5, .cap = .round, .dash = &.{ 2, 1 } }, placement);
    try drawing.endScope();
    var painted = try picture(std.testing.allocator, &drawing, Warp{}, .{});
    defer painted.deinit();
    // Fill and stroke remain one styled path. Clip coordinates and original
    // placement compose to the mapped world position; dash and width persist.
    try std.testing.expectEqual(@as(usize, 3), painted.commands.items.len);
    const clip = painted.commands.items[0].push.clip.?;
    try std.testing.expectEqual(g.Point{ .x = 2, .y = 3.5 }, painted.commands.items[0].push.transform.apply((try painted.range(clip))[0].move));
    try std.testing.expectEqualDeep(drawing.commands.items[1].path.style, painted.commands.items[1].path.style);
    const transformed = painted.commands.items[1].path;
    try std.testing.expectEqual(placement, transformed.transform);
    const world = placement.then(painted.commands.items[0].push.transform);
    const first = world.apply((try painted.range(transformed.path))[0].move);
    const expected = try (Warp{}).point(world.apply(.zero));
    try std.testing.expectApproxEqAbs(expected.x, first.x, 1e-12);
    try std.testing.expectApproxEqAbs(expected.y, first.y, 1e-12);
    try std.testing.expectEqual(fill, drawing.commands.items[1].path.style.fill.?);
    try std.testing.expect(drawing.commands.items[1].path.style.pen != null);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const Warp = struct {
        pub fn point(_: @This(), p: g.Point) !g.Point {
            return .{ .x = p.x, .y = p.y + p.x * p.x / 8 };
        }
    };
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 4, .y = 1 });
    try source.lineTo(.{ .x = 0, .y = 2 });
    try source.close();
    var drawing = DisplayList.init(allocator);
    defer drawing.deinit();
    try drawing.beginScope(.{}, source);
    try drawing.filldraw(source, .{ .r = 1, .a = 0.5 }, .{ .width = 0.5 }, .{});
    try drawing.endScope();
    var warped = try picture(allocator, &drawing, Warp{}, .{});
    defer warped.deinit();
}

test "mapping releases workspaces on every allocation failure" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationCase, .{});
}
