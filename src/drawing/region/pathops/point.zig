// Copyright 2012 Google Inc.; BSD-style license: LICENSE.
// Binary64 port of SkPathOpsPoint.h. Point/vector arithmetic shares storage.
const std = @import("std");
const n = @import("numeric.zig");
pub const Point = struct {
    x: f64,
    y: f64,
    pub const zero: Point = .{ .x = 0, .y = 0 };
    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Point, s: f64) Point {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn neg(a: Point) Point {
        return .{ .x = -a.x, .y = -a.y };
    }
    pub fn dot(a: Point, b: Point) f64 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn cross(a: Point, b: Point) f64 {
        return a.x * b.y - a.y * b.x;
    }
    pub fn lengthSquared(a: Point) f64 {
        return a.x * a.x + a.y * a.y;
    }
    pub fn length(a: Point) f64 {
        return @sqrt(a.lengthSquared());
    }
    pub fn distance(a: Point, b: Point) f64 {
        return a.sub(b).length();
    }
    pub fn distanceSquared(a: Point, b: Point) f64 {
        return a.sub(b).lengthSquared();
    }
    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
    pub fn isFinite(a: Point) bool {
        return std.math.isFinite(a.x) and std.math.isFinite(a.y);
    }
    pub fn mid(a: Point, b: Point) Point {
        return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    }
    pub fn interp(a: Point, b: Point, t: f64) Point {
        return .{ .x = n.interp(a.x, b.x, t), .y = n.interp(a.y, b.y, t) };
    }
    fn largest(a: Point, b: Point) f64 {
        const tiniest = @min(@min(a.x, b.x), @min(a.y, b.y));
        return @max(@max(@max(a.x, b.x), @max(a.y, b.y)), -tiniest);
    }
    pub fn approximatelyEqual(a: Point, b: Point) bool {
        if (n.approximatelyEqual(a.x, b.x) and n.approximatelyEqual(a.y, b.y)) return true;
        if (!n.roughlyEqualUlps(a.x, b.x) or !n.roughlyEqualUlps(a.y, b.y)) return false;
        const scale_value = largest(a, b);
        return n.almostPequalUlps(scale_value, scale_value + a.distance(b));
    }
    pub fn approximatelyDEqual(a: Point, b: Point) bool {
        if (n.approximatelyEqual(a.x, b.x) and n.approximatelyEqual(a.y, b.y)) return true;
        if (!n.roughlyEqualUlps(a.x, b.x) or !n.roughlyEqualUlps(a.y, b.y)) return false;
        const scale_value = largest(a, b);
        return n.almostDequalUlps(scale_value, scale_value + a.distance(b));
    }
    pub fn approximatelyZero(a: Point) bool {
        return n.approximatelyZero(a.x) and n.approximatelyZero(a.y);
    }
    pub fn roughlyEqual(a: Point, b: Point) bool {
        if (n.roughlyEqual(a.x, b.x) and n.roughlyEqual(a.y, b.y)) return true;
        const scale_value = largest(a, b);
        return n.roughlyEqualUlps(scale_value, scale_value + a.distance(b));
    }
};
pub const Bounds = struct {
    min: Point,
    max: Point,
    pub fn valid(self: Bounds) bool {
        return self.min.isFinite() and self.max.isFinite() and self.min.x <= self.max.x and self.min.y <= self.max.y;
    }
    pub fn fromPoints(points: []const Point) Bounds {
        std.debug.assert(points.len > 0);
        var result: Bounds = .{ .min = points[0], .max = points[0] };
        for (points[1..]) |p| result.include(p);
        return result;
    }
    pub fn include(self: *Bounds, p: Point) void {
        self.min.x = @min(self.min.x, p.x);
        self.min.y = @min(self.min.y, p.y);
        self.max.x = @max(self.max.x, p.x);
        self.max.y = @max(self.max.y, p.y);
    }
    pub fn contains(self: Bounds, p: Point) bool {
        return self.min.x <= p.x and p.x <= self.max.x and self.min.y <= p.y and p.y <= self.max.y;
    }
    pub fn containsBounds(self: Bounds, b: Bounds) bool {
        return self.min.x <= b.min.x and self.min.y <= b.min.y and self.max.x >= b.max.x and self.max.y >= b.max.y;
    }
    pub fn intersects(self: Bounds, b: Bounds) bool {
        return self.min.x <= b.max.x and b.min.x <= self.max.x and self.min.y <= b.max.y and b.min.y <= self.max.y;
    }
    pub fn width(self: Bounds) f64 {
        return self.max.x - self.min.x;
    }
    pub fn height(self: Bounds) f64 {
        return self.max.y - self.min.y;
    }
};
test "point distance and coordinate comparisons use binary64 budgets" {
    const a: Point = .{ .x = 1e5, .y = 1e5 };
    const b: Point = .{ .x = 1e5 + 1e-3, .y = 1e5 };
    try std.testing.expect(!a.approximatelyEqual(b));
    try std.testing.expectEqual(@as(f64, 25), (Point{ .x = 3, .y = 4 }).lengthSquared());
    try std.testing.expectEqual(@as(f64, 5), (Point{ .x = 3, .y = 4 }).length());
    const bounds = Bounds.fromPoints(&.{ a, b });
    try std.testing.expect(bounds.contains(a) and bounds.contains(b));
}
