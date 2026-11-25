//! The exact-offset patch polygons of a stroke tracing: points, polygons, corners, arcs and cap patches under the work budget.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const pen_stroke = @import("../../pen/stroke.zig");
const Point = g.Point;
const Cap = pen_stroke.Cap;
const stroke = @import("../stroke.zig");
const Builder = @This();
const Options = stroke.Options;

result: Path,
options: Options,
vertices: usize = 0,

pub fn append(self: *Builder, path: Path) !void {
    for (path.segments.items) |segment| try self.budget(if (segment == .cubic) 3 else if (segment == .close) 0 else 1);
    try self.result.append(path);
}
fn budget(self: *Builder, count: usize) !void {
    if (count > self.options.max_vertices -| self.vertices) return error.GeometryWorkLimit;
    self.vertices += count;
}
pub fn point(self: *const Builder, origin: Point, displacement: Point) !Point {
    @setFloatMode(.strict);
    var result: Point = undefined;
    inline for (.{ "x", "y" }) |field| {
        const a = @field(origin, field);
        const b = @field(displacement, field);
        const value = a + b;
        const virtual = value - a;
        const residual = (a - (value - virtual)) + (b - virtual);
        if (!std.math.isFinite(value) or !std.math.isFinite(residual)) return error.NonFinite;
        if (@abs(residual) > self.options.tolerance * 0.125) return error.PrecisionRange;
        @field(result, field) = value;
    }
    return result;
}
pub fn polygon(self: *Builder, origin: Point, offsets: []const Point) !void {
    if (offsets.len < 3) return;
    var twice_area: f64 = 0;
    for (offsets, 0..) |p, index| twice_area += p.cross(offsets[(index + 1) % offsets.len]);
    if (!std.math.isFinite(twice_area)) return error.NonFinite;
    if (twice_area == 0) return;
    try self.budget(offsets.len);
    try self.result.moveTo(try self.point(origin, offsets[0]));
    for (1..offsets.len) |index| {
        const i = if (twice_area > 0) index else offsets.len - index;
        try self.result.lineTo(try self.point(origin, offsets[i]));
    }
    try self.result.close();
}
pub fn corner(self: *Builder, at: Point, incoming: Point, outgoing: Point, radius: f64) !void {
    if (radius == 0) return;
    const cross = incoming.cross(outgoing);
    const cosine = std.math.clamp(incoming.dot(outgoing), -1, 1);
    if (cross == 0 and cosine >= 0) return;
    const side: f64 = if (cross >= 0) 1 else -1;
    const n0 = (Point{ .x = incoming.y, .y = -incoming.x }).scale(side);
    const n1 = (Point{ .x = outgoing.y, .y = -outgoing.x }).scale(side);
    const first = n0.scale(radius);
    const last = n1.scale(radius);
    if (self.options.join == .round) return self.arc(at, radius, n0, side * std.math.atan2(@abs(cross), cosine));
    const miter = cosine > 0.999 or (self.options.join == .miter and cosine > 2 / (self.options.miter_limit * self.options.miter_limit) - 1);
    if (miter and cosine > -1) {
        const tip = n0.add(n1).scale(radius / (1 + cosine));
        return self.polygon(at, &.{ .zero, first, tip, last });
    }
    if (self.options.join == .bevel) return self.polygon(at, &.{ .zero, first, last });
    // Intersect both offset edge lines with the perpendicular through a
    // point one radius along the outer angle bisector. This is the square
    // join definition, including the 180-degree reversal.
    const normal = n0.add(n1).normalized() catch incoming;
    const denominator = normal.dot(incoming);
    if (denominator == 0) return error.PrecisionRange;
    const q = normal.scale(radius);
    const a = first.add(incoming.scale((radius - normal.dot(first)) / denominator));
    const b = q.scale(2).sub(a);
    try self.polygon(at, &.{ .zero, first, a, b, last });
}
fn arc(self: *Builder, at: Point, radius: f64, from: Point, angle: f64) !void {
    if (radius == 0 or angle == 0) return;
    const ratio = @min(@as(f64, 1), self.options.tolerance * 0.125 / radius);
    // 1-cos(theta) loses tiny angles. The equivalent asin expression
    // keeps the requested bound without a minimum-angle clamp.
    const half_angle = 2 * std.math.asin(@sqrt(ratio * 0.5));
    if (half_angle == 0 or !std.math.isFinite(half_angle)) return error.PrecisionRange;
    const count_float = @max(@as(f64, 1), @ceil(@abs(angle) / (2 * half_angle)));
    if (count_float > @as(f64, @floatFromInt(self.options.max_vertices))) return error.GeometryWorkLimit;
    const count: usize = @intFromFloat(count_float);
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(self.result.allocator);
    try points.ensureTotalCapacity(self.result.allocator, count + 2);
    points.appendAssumeCapacity(.zero);
    for (0..count + 1) |index| {
        const theta = angle * (@as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count)));
        points.appendAssumeCapacity(.{ .x = radius * (from.x * @cos(theta) - from.y * @sin(theta)), .y = radius * (from.y * @cos(theta) + from.x * @sin(theta)) });
    }
    try self.polygon(at, points.items);
}
pub fn stamp(self: *Builder, at: Point, radius: f64, cap: Cap) !void {
    if (radius == 0 or cap == .butt) return;
    if (cap == .round) return self.arc(at, radius, .{ .x = 1, .y = 0 }, 2 * std.math.pi);
    try self.polygon(at, &.{ .{ .x = -radius, .y = -radius }, .{ .x = radius, .y = -radius }, .{ .x = radius, .y = radius }, .{ .x = -radius, .y = radius } });
}
pub fn capPatch(self: *Builder, at: Vertex, outward: Point, kind: Cap) !void {
    if (at.radius == 0 or kind == .butt) return;
    const normal: Point = .{ .x = outward.y, .y = -outward.x };
    if (kind == .round) return self.arc(at.point, at.radius, normal, std.math.pi);
    const side = normal.scale(at.radius);
    const tip = outward.scale(at.radius);
    try self.polygon(at.point, &.{ side, side.add(tip), tip.sub(side), side.scale(-1) });
}

pub const Vertex = struct { point: Point, radius: f64 };

test "square joins and miter-limit fallback retain the square corner" {
    const incoming: Point = .{ .x = 1, .y = 0 };
    const outgoing: Point = .{ .x = 0, .y = 1 };
    var square: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .square } };
    defer square.result.deinit();
    try square.corner(.zero, incoming, outgoing, 2);
    const expected = 4 * (2 * @sqrt(@as(f64, 2)) - 2);
    try std.testing.expectApproxEqAbs(expected, square.result.signedArea(), 1e-12);
    var limited: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .miter, .miter_limit = 1 } };
    defer limited.result.deinit();
    try limited.corner(.zero, incoming, outgoing, 2);
    try std.testing.expectApproxEqAbs(expected, limited.result.signedArea(), 1e-12);
    var miter: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .miter, .miter_limit = 4 } };
    defer miter.result.deinit();
    try miter.corner(.zero, incoming, outgoing, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 4), miter.result.signedArea(), 1e-12);
}
