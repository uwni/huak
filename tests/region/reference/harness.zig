//! The independent area oracle and fixtures shared by the reference tests: polygons, rectangles, circles, compound shapes and a three-point Gauss area integral.
const std = @import("std");
const t = std.testing;
const core = @import("drawing");
const Path = core.Path;
const Point = core.geometry.Point;
const Operation = core.region.Operation;
const FillRule = core.region.FillRule;
const Allocator = std.mem.Allocator;

pub const operations = [_]Operation{ .unite, .intersect, .difference, .xor };

pub const rules = [_]FillRule{ .evenodd, .nonzero, .positive, .negative };

pub fn polygon(allocator: Allocator, points: []const [2]f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    if (points.len == 0) return result;
    try result.moveTo(.{ .x = points[0][0], .y = points[0][1] });
    for (points[1..]) |point| try result.lineTo(.{ .x = point[0], .y = point[1] });
    try result.close();
    return result;
}

pub fn rect(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    return polygon(allocator, &.{ .{ x, y }, .{ x + width, y }, .{ x + width, y + height }, .{ x, y + height } });
}

pub fn circle(allocator: Allocator, x: f64, y: f64, radius: f64) !Path {
    // Keep the exact reference's kappa literal rather than recomputing tan.
    const k = radius * 0.5522847498307936;
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x + radius, .y = y });
    try result.cubicTo(.{ .x = x + radius, .y = y + k }, .{ .x = x + k, .y = y + radius }, .{ .x = x, .y = y + radius });
    try result.cubicTo(.{ .x = x - k, .y = y + radius }, .{ .x = x - radius, .y = y + k }, .{ .x = x - radius, .y = y });
    try result.cubicTo(.{ .x = x - radius, .y = y - k }, .{ .x = x - k, .y = y - radius }, .{ .x = x, .y = y - radius });
    try result.cubicTo(.{ .x = x + k, .y = y - radius }, .{ .x = x + radius, .y = y - k }, .{ .x = x + radius, .y = y });
    try result.close();
    return result;
}

pub fn compound(allocator: Allocator, first: Path, second: Path) !Path {
    var result = try first.clone(allocator);
    errdefer result.deinit();
    try result.append(second);
    return result;
}

// The reference's three-point Gauss integral is exact for the degree-five
// polynomial in real arithmetic and independent of the engine's signedArea.
fn cubicArea(start: Point, curve: core.geometry.Cubic) f64 {
    const root = @sqrt(@as(f64, 3.0 / 5.0));
    const times = [_]f64{ 0.5 * (1 - root), 0.5, 0.5 * (1 + root) };
    const weights = [_]f64{ 5.0 / 18.0, 4.0 / 9.0, 5.0 / 18.0 };
    const px = [_]f64{ start.x, curve.p1.x, curve.p2.x, curve.p3.x };
    const py = [_]f64{ start.y, curve.p1.y, curve.p2.y, curve.p3.y };
    var total: f64 = 0;
    for (times, weights) |parameter, weight| {
        const u = 1 - parameter;
        const x = u * u * u * px[0] + 3 * u * u * parameter * px[1] + 3 * u * parameter * parameter * px[2] + parameter * parameter * parameter * px[3];
        const y = u * u * u * py[0] + 3 * u * u * parameter * py[1] + 3 * u * parameter * parameter * py[2] + parameter * parameter * parameter * py[3];
        const dx = 3 * (u * u * (px[1] - px[0]) + 2 * u * parameter * (px[2] - px[1]) + parameter * parameter * (px[3] - px[2]));
        const dy = 3 * (u * u * (py[1] - py[0]) + 2 * u * parameter * (py[2] - py[1]) + parameter * parameter * (py[3] - py[2]));
        total += weight * (x * dy - y * dx);
    }
    return total;
}

pub fn segmentArea(segments: []const core.Path.Segment) f64 {
    var current: Point = .zero;
    var start: Point = .zero;
    var total: f64 = 0;
    for (segments) |segment| switch (segment) {
        .move => |point| {
            current = point;
            start = point;
        },
        .line => |point| {
            total += current.cross(point);
            current = point;
        },
        .close => {
            total += current.cross(start);
            current = start;
        },
        .cubic => |curve| {
            total += cubicArea(current, .{ .p0 = current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end });
            current = curve.end;
        },
    };
    return total * 0.5;
}

pub fn area(path: Path) f64 {
    return segmentArea(path.segments.items);
}

pub fn expectArea(allocator: Allocator, first: Path, second: Path, operation: Operation, rule: FillRule, expected: f64, tolerance: f64, description: []const u8) !void {
    var result = core.region.combine(allocator, first, second, operation, .{ .fill_rule = rule }) catch |err| {
        std.debug.print("reference {s}, {s}/{s}: {s}\n", .{ description, @tagName(operation), @tagName(rule), @errorName(err) });
        return err;
    };
    defer result.deinit();
    const actual = area(result);
    if (@abs(actual - expected) > tolerance) std.debug.print("reference {s}, {s}/{s}: expected {d}, got {d}\n", .{ description, @tagName(operation), @tagName(rule), expected, actual });
    try t.expectApproxEqAbs(expected, actual, tolerance);
}

pub fn operationArea(operation: Operation, a: f64, b: f64) f64 {
    return switch (operation) {
        .unite => @max(a, b),
        .intersect => @min(a, b),
        .difference => if (b == 0) a else 0,
        .xor => @abs(a - b),
    };
}
