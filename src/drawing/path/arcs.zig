//! Circular arcs as cubic spans: a new arc path, the span count for a sweep, and an arc continued from the current point.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const Segment = Path.Segment;

/// An oriented circular arc, approximated by cubic spans of at most 90 degrees.
pub fn arc(allocator: std.mem.Allocator, center: Point, radius: f64, start: f64, sweep: f64) !Path {
    try validateArc(radius, start, sweep);
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.segments.ensureTotalCapacityPrecise(allocator, 1 + arcSpans(sweep));
    try path.moveTo(center.add((Point{ .x = @cos(start), .y = @sin(start) }).scale(radius)));
    try appendArc(&path, center, radius, start, sweep);
    return path;
}

/// Cubic spans that `appendArc` uses for `sweep`: at most a quarter turn each.
pub fn arcSpans(sweep: f64) usize {
    return @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 2.0)));
}

/// Continue the current subpath along an oriented circular arc around
/// `center`. The current point is the arc start, at angle `start`; each span
/// uses the standard endpoint-exact kappa, so the curve stays editable cubics.
pub fn appendArc(self: *Path, center: Point, radius: f64, start: f64, sweep: f64) !void {
    try validateArc(radius, start, sweep);
    if (!self.open) return error.InvalidPath;
    const count = arcSpans(sweep);
    const step = sweep / @as(f64, @floatFromInt(count));
    const k = radius * (4.0 / 3.0) * @tan(step / 4);
    var angle = start;
    var radial: Point = .{ .x = @cos(angle), .y = @sin(angle) };
    for (0..count) |_| {
        const c1 = self.current.?.add(.{ .x = -radial.y * k, .y = radial.x * k });
        angle += step;
        radial = .{ .x = @cos(angle), .y = @sin(angle) };
        const end = center.add(radial.scale(radius));
        try self.cubicTo(c1, end.add(.{ .x = radial.y * k, .y = -radial.x * k }), end);
    }
}

fn validateArc(radius: f64, start: f64, sweep: f64) error{InvalidParameter}!void {
    if (!std.math.isFinite(start) or !std.math.isFinite(sweep) or !std.math.isFinite(radius) or
        radius <= 0 or sweep == 0 or @abs(sweep) > 2 * std.math.pi) return error.InvalidParameter;
}

test "appendArc continues the current point exactly as arc constructs it" {
    var whole = try arc(std.testing.allocator, .{ .x = 3, .y = -2 }, 5, 0.25, -2.5);
    defer whole.deinit();
    try std.testing.expectEqual(@as(usize, 1 + arcSpans(-2.5)), whole.segments.items.len);
    try std.testing.expectEqual(whole.segments.items.len, whole.segments.capacity);

    var continued = Path.init(std.testing.allocator);
    defer continued.deinit();
    try std.testing.expectError(error.InvalidPath, appendArc(&continued, .{ .x = 3, .y = -2 }, 5, 0.25, -2.5));
    try continued.moveTo(whole.segments.items[0].move);
    try appendArc(&continued, .{ .x = 3, .y = -2 }, 5, 0.25, -2.5);
    try std.testing.expectEqualSlices(Segment, whole.segments.items, continued.segments.items);
    try std.testing.expectError(error.InvalidParameter, appendArc(&continued, .zero, 0, 0, 1));
}
