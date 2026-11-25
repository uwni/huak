//! Varying-width tracing of one contour: strips between width knots, corners and caps.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const pen_stroke = @import("../../pen/stroke.zig");
const Point = g.Point;
const Cap = pen_stroke.Cap;
const stroke = @import("../stroke.zig");
const Builder = @import("Builder.zig");
const Vertex = Builder.Vertex;
const profileTracing = stroke.profileTracing;

pub fn profiledContour(builder: *Builder, points: []const Point, closed: bool, positions: []const f64, widths: []const f64) !void {
    if (points.len == 0) return error.InvalidPath;
    var length: f64 = 0;
    for (points[1..], points[0 .. points.len - 1]) |point, before| length += before.distance(point);
    if (!std.math.isFinite(length)) return error.NonFinite;
    if (length == 0) {
        if (!closed) try builder.stamp(points[0], widths[0] * 0.5, builder.options.cap);
        return;
    }
    const allocator = builder.result.allocator;
    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(allocator);
    try vertices.append(allocator, .{ .point = points[0], .radius = widths[0] * 0.5 });
    var distance: f64 = 0;
    var knot: usize = 1;
    for (points[1..], points[0 .. points.len - 1]) |point, before| {
        const edge_length = before.distance(point);
        const finish_distance = distance + edge_length;
        if (edge_length > 0 and finish_distance == distance) return error.PrecisionRange;
        while (knot < positions.len - 1 and positions[knot] * length < finish_distance) : (knot += 1) {
            const fraction = (positions[knot] * length - distance) / edge_length;
            if (fraction > 0) {
                if (vertices.items.len >= builder.options.max_vertices) return error.GeometryWorkLimit;
                // Interpolate a displacement, rather than weighted absolute
                // positions, so collinear translated segments stay collinear.
                const interpolated = try builder.point(before, point.sub(before).scale(fraction));
                try vertices.append(allocator, .{ .point = interpolated, .radius = widths[knot] * 0.5 });
            }
        }
        const u = if (finish_distance == length) 1 else finish_distance / length;
        while (knot < positions.len - 1 and positions[knot] < u) knot += 1;
        const index = @min(knot, positions.len - 1);
        const fraction = std.math.clamp((u - positions[index - 1]) / (positions[index] - positions[index - 1]), 0, 1);
        const radius = (widths[index - 1] * (1 - fraction) + widths[index] * fraction) * 0.5;
        if (vertices.items.len >= builder.options.max_vertices) return error.GeometryWorkLimit;
        try vertices.append(allocator, .{ .point = point, .radius = radius });
        distance = finish_distance;
    }
    const count = vertices.items.len - @intFromBool(closed);
    const values = vertices.items[0..count];
    const two_point = closed and count == 2;
    const cycle = closed and !two_point;
    for (0..if (cycle) count else count - 1) |index| {
        const a = values[index];
        const b = values[(index + 1) % count];
        if (a.point.eql(b.point)) continue;
        const delta = b.point.sub(a.point);
        const tangent = try delta.normalized();
        const normal: Point = .{ .x = -tangent.y, .y = tangent.x };
        try builder.polygon(a.point, &.{ normal.scale(a.radius), normal.scale(-a.radius), delta.add(normal.scale(-b.radius)), delta.add(normal.scale(b.radius)) });
    }
    if (count == 1) return;
    for ((if (cycle) @as(usize, 0) else 1)..(if (cycle) count else count - 1)) |index| {
        const before = values[(index + count - 1) % count].point;
        const at = values[index];
        const after = values[(index + 1) % count].point;
        if (before.eql(at.point) or at.point.eql(after)) continue;
        try builder.corner(at.point, try at.point.sub(before).normalized(), try after.sub(at.point).normalized(), at.radius);
    }
    if (!cycle) {
        const cap: Cap = if (two_point) (if (builder.options.join == .round) .round else .square) else builder.options.cap;
        try builder.capPatch(values[0], try values[0].point.sub(values[1].point).normalized(), cap);
        try builder.capPatch(values[count - 1], try values[count - 1].point.sub(values[count - 2].point).normalized(), cap);
    }
}

test "profile tracing has exact straight taper and diamond areas" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 100, .y = 0 });
    var taper = try profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer taper.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 600), taper.signedArea(), 1e-10);
    var diamond = try profileTracing(std.testing.allocator, line, &.{ 0, 0.5, 1 }, &.{ 0, 10, 0 }, .{});
    defer diamond.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 500), diamond.signedArea(), 1e-10);
}

test "profile tracing restarts at moves and validates closed seams" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 100, .y = 0 });
    try line.moveTo(.{ .x = 0, .y = 20 });
    try line.lineTo(.{ .x = 100, .y = 20 });
    var pair = try profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer pair.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1200), pair.signedArea(), 1e-9);
    try line.close();
    try std.testing.expectError(error.DiscontinuousClosedProfile, profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{}));
}
