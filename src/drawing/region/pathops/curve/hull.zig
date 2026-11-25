// Copyright 2012 Google Inc.; BSD-style license: ../LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
//! Cubic control-hull classification for TSect: the convex hull, its rotation onto the y axis, and hull intersection with another curve's points.
const std = @import("std");
const n = @import("../numeric.zig");
const Point = @import("../point.zig").Point;
const curves = @import("../curve.zig");
const Quad = @import("Quad.zig");

pub fn convexHull(self: *const curves.Cubic, order: *[4]usize) usize {
    var y_min: usize = 0;
    for (1..4) |i| if (self.points[y_min].y > self.points[i].y or
        (self.points[y_min].y == self.points[i].y and self.points[y_min].x > self.points[i].x))
    {
        y_min = i;
    };
    order[0] = y_min;
    var mid_x: ?usize = null;
    var backup_y_min: ?usize = null;
    for (0..2) |_| {
        for (0..4) |index| {
            if (index == y_min) continue;
            const mask = otherTwo(y_min, index);
            const side1 = y_min ^ mask;
            const side2 = index ^ mask;
            var rotated_y: [4]f64 = undefined;
            if (!rotateHullY(self, y_min, index, &rotated_y)) {
                order[1] = side1;
                order[2] = side2;
                return 3;
            }
            const sides = n.side(rotated_y[side1] - rotated_y[y_min]) ^ n.side(rotated_y[side2] - rotated_y[y_min]);
            if (sides == 2) {
                if (mid_x != null) {
                    order[0] = 0;
                    order[1] = 3;
                    if (self.points[1].eql(self.points[0]) or self.points[1].eql(self.points[3])) {
                        order[2] = 2;
                        return 3;
                    }
                    if (self.points[2].eql(self.points[0]) or self.points[2].eql(self.points[3])) {
                        order[2] = 1;
                        return 3;
                    }
                    const smallest1 = @min(self.points[1].distanceSquared(self.points[0]), self.points[1].distanceSquared(self.points[3]));
                    const smallest2 = @min(self.points[2].distanceSquared(self.points[0]), self.points[2].distanceSquared(self.points[3]));
                    if (n.approximatelyZero(@min(smallest1, smallest2))) {
                        order[2] = if (smallest1 < smallest2) 2 else 1;
                        return 3;
                    }
                }
                mid_x = index;
            } else if (sides == 0) backup_y_min = index;
        }
        if (mid_x != null or backup_y_min == null) break;
        y_min = backup_y_min.?;
        backup_y_min = null;
    }
    const mid = mid_x orelse (y_min ^ 3);
    const mask = otherTwo(y_min, mid);
    const least = y_min ^ mask;
    const most = mid ^ mask;
    order[0] = y_min;
    order[1] = least;
    var rotated_y: [4]f64 = undefined;
    if (!rotateHullY(self, least, most, &rotated_y)) {
        order[2] = mid;
        return 3;
    }
    const sides = n.side(rotated_y[y_min] - rotated_y[least]) ^ n.side(rotated_y[mid] - rotated_y[least]);
    if (sides != 2) {
        order[2] = most;
        return 3;
    }
    order[2] = mid;
    order[3] = most;
    return 4;
}

// Convex-hull classification reads only rotated Y. Keep the source
// arithmetic/snaps while avoiding unused X rotations and a Cubic return.
fn rotateHullY(self: *const curves.Cubic, zero: usize, index: usize, result: *[4]f64) bool {
    const dy = self.points[index].y - self.points[zero].y;
    const dx = self.points[index].x - self.points[zero].x;
    if (n.approximatelyZero(dy)) {
        if (n.approximatelyZero(dx)) return false;
        for (self.points, result) |point, *out| out.* = point.y;
        if (dy != 0) {
            result[index] = self.points[zero].y;
            const mask = otherTwo(index, zero);
            const side1 = index ^ mask;
            const side2 = zero ^ mask;
            if (n.approximatelyEqual(self.points[side1].y, self.points[zero].y)) result[side1] = self.points[zero].y;
            if (n.approximatelyEqual(self.points[side2].y, self.points[zero].y)) result[side2] = self.points[zero].y;
        }
        return true;
    }
    for (self.points, result) |point, *out| out.* = point.y * dx - point.x * dy;
    return true;
}

pub inline fn hullIntersectsPoints(self: *const curves.Cubic, points: []const Point, is_linear: *bool) bool {
    var linear = true;
    var order: [4]usize = undefined;
    const count = convexHull(self, &order);
    var end1 = order[0];
    var hull_index: usize = 0;
    var first = self.points[end1];
    while (true) {
        hull_index = (hull_index + 1) % count;
        const end2 = order[hull_index];
        const second = self.points[end2];
        const adj = second.x - first.x;
        const opp = second.y - first.y;
        const mask = otherTwo(end1, end2);
        const odd = self.points[end1 ^ mask];
        const odd2 = self.points[end2 ^ mask];
        var sign_value = (odd.y - first.y) * adj - (odd.x - first.x) * opp;
        const sign2 = (odd2.y - first.y) * adj - (odd2.x - first.x) * opp;
        if (sign_value * sign2 < 0) {
            if (hull_index == 0) break;
            continue;
        }
        if (n.approximatelyZero(sign_value)) {
            sign_value = sign2;
            if (n.approximatelyZero(sign_value)) {
                if (hull_index == 0) break;
                continue;
            }
        }
        linear = false;
        var found_outlier = false;
        for (points) |p| {
            const value = (p.y - first.y) * adj - (p.x - first.x) * opp;
            // Preserve the established f64 same-side hull correction.
            if (value * sign_value > 0) {
                found_outlier = true;
                break;
            }
        }
        if (!found_outlier) return false;
        first = second;
        end1 = end2;
        if (hull_index == 0) break;
    }
    is_linear.* = linear;
    return true;
}

fn otherTwo(one: usize, two: usize) usize {
    return (@as(usize, 1) >> @as(std.math.Log2Int(usize), @intCast(3 - (one ^ two)))) ^ 3;
}

test "upstream curve hull methods retain strict separation" {
    const cubic: curves.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } };
    const quad: Quad = .{ .points = .{ .{ .x = 0, .y = 2 }, .{ .x = 2, .y = -1 }, .{ .x = 4, .y = 2 } } };
    const far: Quad = .{ .points = .{ .{ .x = 10, .y = 2 }, .{ .x = 12, .y = -1 }, .{ .x = 14, .y = 2 } } };
    var linear = false;
    try std.testing.expect(!(curves.Curve{ .cubic = cubic }).hullIntersects(&.{ .quad = far }, &linear));
    try std.testing.expect(!(curves.Curve{ .quad = far }).hullIntersects(&.{ .cubic = cubic }, &linear));
    try std.testing.expect((curves.Curve{ .quad = quad }).hullIntersects(&.{ .cubic = cubic }, &linear));
    try std.testing.expect(quad.hullIntersects(quad, &linear));
    try std.testing.expect(cubic.hullIntersects(cubic, &linear));
    try std.testing.expect(!(curves.Curve{ .cubic = cubic }).collapsed());
    try std.testing.expectEqual(@as(usize, 4), (curves.Curve{ .cubic = cubic }).pointCount());
    try std.testing.expect((curves.Curve{ .cubic = cubic }).point(3).eql(cubic.points[3]));
    _ = cubic.controlsInside();
    _ = quad.controlsInside();
}

test "hull Y projection preserves original rotation bits and degeneracy" {
    const Reference = struct {
        // The original full rotation is retained only as the test oracle.
        fn rotate(curve: curves.Cubic, zero: usize, index: usize) ?curves.Cubic {
            const dy = curve.points[index].y - curve.points[zero].y;
            const dx = curve.points[index].x - curve.points[zero].x;
            var result = curve;
            if (n.approximatelyZero(dy)) {
                if (n.approximatelyZero(dx)) return null;
                if (dy != 0) {
                    result.points[index].y = curve.points[zero].y;
                    const mask = otherTwo(index, zero);
                    const side1 = index ^ mask;
                    const side2 = zero ^ mask;
                    if (n.approximatelyEqual(curve.points[side1].y, curve.points[zero].y)) result.points[side1].y = curve.points[zero].y;
                    if (n.approximatelyEqual(curve.points[side2].y, curve.points[zero].y)) result.points[side2].y = curve.points[zero].y;
                }
                return result;
            }
            for (curve.points, &result.points) |point, *out| out.* = .{ .x = point.x * dx + point.y * dy, .y = point.y * dx - point.x * dy };
            return result;
        }

        fn check(points: [4]Point) !void {
            const curve: curves.Cubic = .{ .points = points };
            for (0..4) |zero| for (0..4) |index| {
                const marker: f64 = @bitCast(@as(u64, 0x7ff8000000000055));
                var actual: [4]f64 = @splat(marker);
                const expected = rotate(curve, zero, index);
                try std.testing.expectEqual(expected != null, rotateHullY(&curve, zero, index, &actual));
                if (expected) |want| {
                    for (want.points, actual) |point, value| try std.testing.expectEqual(@as(u64, @bitCast(point.y)), @as(u64, @bitCast(value)));
                } else {
                    for (actual) |value| try std.testing.expectEqual(@as(u64, @bitCast(marker)), @as(u64, @bitCast(value)));
                }
            };
        }

        fn scales(points: [4]Point) !void {
            for ([_]i32{ -900, -500, -80, 0, 80, 500, 900 }) |exponent| {
                var scaled: [4]Point = undefined;
                for (points, &scaled) |point, *out| out.* = .{
                    .x = std.math.ldexp(point.x, exponent),
                    .y = std.math.ldexp(point.y, exponent),
                };
                try check(scaled);
                try check(.{ scaled[3], scaled[2], scaled[1], scaled[0] });
            }
        }
    };
    const fixtures = [_][4]Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 3 } },
        .{ .{ .x = -0.0, .y = 0 }, .{ .x = 0, .y = -0.0 }, .{ .x = -0.0, .y = -0.0 }, .{ .x = 0, .y = 0 } },
        .{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = n.EPSILON / 2 }, .{ .x = 2, .y = -n.EPSILON / 2 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = n.EPSILON }, .{ .x = 2, .y = -n.EPSILON }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = -1, .y = -1 }, .{ .x = 0.5, .y = 1 }, .{ .x = -0.5, .y = 1 }, .{ .x = 1, .y = -1 } },
    };
    for (fixtures) |points| try Reference.scales(points);
    var prng: std.Random.DefaultPrng = .init(0x6ad2a8e4172c3f5b);
    const random = prng.random();
    for (0..64) |_| {
        var points: [4]Point = undefined;
        for (&points) |*point| point.* = .{ .x = (random.float(f64) - 0.5) * 8, .y = (random.float(f64) - 0.5) * 8 };
        try Reference.scales(points);
    }
}
