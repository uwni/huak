// Copyright 2012 Google Inc.; BSD-style license: ../LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
//! A quadratic Bézier in binary64: evaluation, subdivision, axis intercepts, hull tests and the nearest point.
const n = @import("../numeric.zig");
const roots = @import("../roots.zig");
const Point = @import("../point.zig").Point;
const Bounds = @import("../point.zig").Bounds;
const curves = @import("../curve.zig");
const Quad = @This();

points: [3]Point,
pub fn ptAtT(self: Quad, t: f64) Point {
    if (t == 0) return self.points[0];
    if (t == 1) return self.points[2];
    const s = 1 - t;
    const a = s * s;
    const b = 2 * s * t;
    const c = t * t;
    return .{ .x = a * self.points[0].x + b * self.points[1].x + c * self.points[2].x, .y = a * self.points[0].y + b * self.points[1].y + c * self.points[2].y };
}
pub fn dxdyAtT(self: Quad, t: f64) Point {
    const a = t - 1;
    const b = 1 - 2 * t;
    const c = t;
    var result: Point = .{ .x = a * self.points[0].x + b * self.points[1].x + c * self.points[2].x, .y = a * self.points[0].y + b * self.points[1].y + c * self.points[2].y };
    if (result.x == 0 and result.y == 0 and n.zeroOrOne(t)) result = self.points[2].sub(self.points[0]);
    return result;
}
pub fn interpPoint(self: Quad, t: f64) Point {
    if (t == 0) return self.points[0];
    if (t == 1) return self.points[2];
    return self.points[0].interp(self.points[1], t).interp(self.points[1].interp(self.points[2], t), t);
}
pub fn subDivide(self: Quad, t1: f64, t2: f64) Quad {
    if (t1 == 0 and t2 == 1) return self;
    const a = self.interpPoint(t1);
    const d = self.interpPoint((t1 + t2) / 2);
    const c = self.interpPoint(t2);
    return .{ .points = .{ a, .{ .x = 2 * d.x - (a.x + c.x) / 2, .y = 2 * d.y - (a.y + c.y) / 2 }, c } };
}
pub fn hullBounds(self: Quad) Bounds {
    return Bounds.fromPoints(&self.points);
}
pub fn bounds(self: Quad) Bounds {
    var result = Bounds.fromPoints(&.{ self.points[0], self.points[2] });
    var ts: [1]f64 = undefined;
    for ([_]curves.Axis{ .x, .y }) |axis| {
        if (curves.controlsWithinEndpoints(&self.points, axis)) continue;
        const count = self.findExtrema(axis, &ts);
        for (ts[0..count]) |t| result.include(self.ptAtT(t));
    }
    return result;
}
pub fn reverse(self: Quad) Quad {
    return .{ .points = .{ self.points[2], self.points[1], self.points[0] } };
}
pub fn findExtrema(self: Quad, axis: curves.Axis, out: *[1]f64) usize {
    const a = curves.coordinate(self.points[0], axis);
    const b = curves.coordinate(self.points[1], axis);
    const c = curves.coordinate(self.points[2], axis);
    var numer = a - b;
    var denom = a - b - b + c;
    if (numer < 0) {
        numer = -numer;
        denom = -denom;
    }
    if (denom == 0 or numer == 0 or numer >= denom) return 0;
    const ratio = numer / denom;
    if (ratio == 0) return 0;
    out[0] = ratio;
    return 1;
}
pub fn axisIntersect(self: Quad, axis: curves.Axis, intercept: f64, out: *[2]f64) usize {
    var d = curves.coordinate(self.points[2], axis);
    var e = curves.coordinate(self.points[1], axis);
    var f = curves.coordinate(self.points[0], axis);
    d += f - 2 * e;
    e -= f;
    f -= intercept;
    return roots.quadraticValidT(d, 2 * e, f, out);
}
pub fn horizontalIntersect(self: Quad, y: f64, out: *[2]f64) usize {
    return self.axisIntersect(.y, y, out);
}
pub fn verticalIntersect(self: Quad, x: f64, out: *[2]f64) usize {
    return self.axisIntersect(.x, x, out);
}
pub fn nearPoint(self: Quad, p: Point, opposite: Point) f64 {
    return curves.curveNearPoint(self, p, opposite);
}
pub fn collapsed(self: Quad) bool {
    return self.points[0].approximatelyEqual(self.points[1]) and self.points[0].approximatelyEqual(self.points[2]);
}
pub fn controlsInside(self: Quad) bool {
    const v01 = self.points[0].sub(self.points[1]);
    const v02 = self.points[0].sub(self.points[2]);
    const v12 = self.points[1].sub(self.points[2]);
    return v02.dot(v01) > 0 and v02.dot(v12) > 0;
}
pub fn hullIntersects(self: *const Quad, other: anytype, is_linear: *bool) bool {
    if (@TypeOf(other) == curves.Cubic or @TypeOf(other) == *const curves.Cubic) return other.hullIntersects(self, is_linear);
    return self.hullIntersectsPoints(&other.points, is_linear);
}
pub inline fn hullIntersectsPoints(self: *const Quad, points: []const Point, is_linear: *bool) bool {
    var linear = true;
    for (0..3) |odd_man| {
        const first: usize = if (odd_man == 0) 1 else 0;
        const second: usize = if (odd_man == 2) 1 else 2;
        const origin = self.points[first];
        const adj = self.points[second].x - origin.x;
        const opp = self.points[second].y - origin.y;
        const sign_value = (self.points[odd_man].y - origin.y) * adj - (self.points[odd_man].x - origin.x) * opp;
        if (n.approximatelyZero(sign_value)) continue;
        linear = false;
        var found_outlier = false;
        for (points) |p| {
            const value = (p.y - origin.y) * adj - (p.x - origin.x) * opp;
            if (value * sign_value > 0 and !n.preciselyZero(value)) {
                found_outlier = true;
                break;
            }
        }
        if (!found_outlier) return false;
    }
    if (linear and !self.points[0].eql(points[0]) and !self.points[2].eql(points[0]) and
        !self.points[0].eql(points[points.len - 1]) and !self.points[2].eql(points[points.len - 1]))
    {
        if (pointInTriangle(self.points, points[0]) or pointInTriangle(self.points, points[points.len - 1])) linear = false;
    }
    is_linear.* = linear;
    return true;
}

fn pointInTriangle(points: [3]Point, test_point: Point) bool {
    const v0 = points[2].sub(points[0]);
    const v1 = points[1].sub(points[0]);
    const v2 = test_point.sub(points[0]);
    const dot00 = v0.dot(v0);
    const dot01 = v0.dot(v1);
    const dot02 = v0.dot(v2);
    const dot11 = v1.dot(v1);
    const dot12 = v1.dot(v2);
    const denom = dot00 * dot11 - dot01 * dot01;
    const u = dot11 * dot02 - dot01 * dot12;
    const v = dot00 * dot12 - dot01 * dot02;
    return if (denom >= 0) u >= 0 and v >= 0 and u + v < denom else u <= 0 and v <= 0 and u + v > denom;
}
