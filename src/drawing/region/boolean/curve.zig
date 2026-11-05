// Ported from Paper.js v0.16.0 src/path/Curve.js and Point/Line helpers.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey, https://paperjs.org/
// Distributed under the MIT license. See the retained upstream LICENSE.
const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const n = @import("numeric.zig");
const Cubic = geometry.Cubic;
pub const Point = types.Point;
pub const MonoCurves = struct { items: [3]Cubic = undefined, len: usize = 0 };
pub fn getPart(v: *const Cubic, from_: f64, to_: f64) Cubic {
    const flip = from_ > to_;
    const from = if (flip) to_ else from_;
    const to = if (flip) from_ else to_;
    var part = v.*;
    if (from > 0) part = part.split(from).right;
    if (to < 1) part = part.split((to - from) / (1 - from)).left;
    return if (flip) part.reversed() else part;
}
pub fn isCollinear(x1: f64, y1: f64, x2: f64, y2: f64) bool {
    return @abs(x1 * y2 - y1 * x2) <= @sqrt((x1 * x1 + y1 * y1) * (x2 * x2 + y2 * y2)) * n.TRIGONOMETRIC_EPSILON;
}
pub fn getSignedDistance(px: f64, py: f64, vx: f64, vy: f64, x: f64, y: f64) f64 {
    return if (vx == 0) (if (vy > 0) x - px else px - x) else if (vy == 0) (if (vx < 0) y - py else py - y) else ((x - px) * vy - (y - py) * vx) / (if (vy > vx) @abs(vy) * @sqrt(1 + (vx * vx) / (vy * vy)) else @abs(vx) * @sqrt(1 + (vy * vy) / (vx * vx)));
}
pub fn isStraight(v: *const Cubic) bool {
    const h1x = v.p1.x - v.p0.x;
    const h1y = v.p1.y - v.p0.y;
    const h2x = v.p2.x - v.p3.x;
    const h2y = v.p2.y - v.p3.y;
    if (n.isZero(h1x) and n.isZero(h1y) and n.isZero(h2x) and n.isZero(h2y)) return true;
    const vx = v.p3.x - v.p0.x;
    const vy = v.p3.y - v.p0.y;
    if (n.isZero(vx) and n.isZero(vy)) return false;
    if (isCollinear(vx, vy, h1x, h1y) and isCollinear(vx, vy, h2x, h2y) and
        @abs(getSignedDistance(v.p0.x, v.p0.y, vx, vy, v.p0.x + h1x, v.p0.y + h1y)) < n.GEOMETRIC_EPSILON and
        @abs(getSignedDistance(v.p0.x, v.p0.y, vx, vy, v.p3.x + h2x, v.p3.y + h2y)) < n.GEOMETRIC_EPSILON)
    {
        const div = vx * vx + vy * vy;
        const s1 = (vx * h1x + vy * h1y) / div;
        const s2 = (vx * h2x + vy * h2y) / div;
        return s1 >= 0 and s1 <= 1 and s2 <= 0 and s2 >= -1;
    }
    return false;
}
pub fn hasHandles(v: *const Cubic) bool {
    return !n.isZero(v.p1.x - v.p0.x) or !n.isZero(v.p1.y - v.p0.y) or !n.isZero(v.p2.x - v.p3.x) or !n.isZero(v.p2.y - v.p3.y);
}
pub fn yMonotoneParts(v: *const Cubic) MonoCurves {
    var result: MonoCurves = .{};
    const o0 = v.p0.y;
    const o1 = v.p1.y;
    const o2 = v.p2.y;
    const o3 = v.p3.y;
    if (((o0 >= o1) == (o1 >= o2) and (o1 >= o2) == (o2 >= o3)) or isStraight(v)) {
        result.items[0] = v.*;
        result.len = 1;
        return result;
    }
    const a = 3 * (o1 - o2) - o0 + o3;
    const b = 2 * (o0 + o2) - 4 * o1;
    const c = o1 - o0;
    var roots: [2]f64 = undefined;
    const count = n.solveQuadratic(a, b, c, &roots, n.CURVETIME_EPSILON, 1 - n.CURVETIME_EPSILON);
    if (count <= 0) {
        result.items[0] = v.*;
        result.len = 1;
    } else {
        if (count > 1 and roots[0] > roots[1]) std.mem.swap(f64, &roots[0], &roots[1]);
        var parts = v.split(roots[0]);
        result.items[0] = parts.left;
        result.len = 1;
        if (count > 1) {
            parts = parts.right.split((roots[1] - roots[0]) / (1 - roots[0]));
            result.items[result.len] = parts.left;
            result.len += 1;
        }
        result.items[result.len] = parts.right;
        result.len += 1;
    }
    return result;
}
pub fn solveCubic(v: *const Cubic, comptime coord: usize, value: f64, roots: *[3]f64, min: ?f64, max: ?f64) i32 {
    const v0 = if (coord == 0) v.p0.x else v.p0.y;
    const v1 = if (coord == 0) v.p1.x else v.p1.y;
    const v2 = if (coord == 0) v.p2.x else v.p2.y;
    const v3 = if (coord == 0) v.p3.x else v.p3.y;
    if ((v0 < value and v3 < value and v1 < value and v2 < value) or (v0 > value and v3 > value and v1 > value and v2 > value)) return 0;
    const c = 3 * (v1 - v0);
    const b = 3 * (v2 - v1) - c;
    const a = v3 - v0 - c - b;
    return n.solveCubic(a, b, c, v0 - value, roots, min, max);
}
pub fn getArea(v: *const Cubic) f64 {
    return 3 * ((v.p3.y - v.p0.y) * (v.p1.x + v.p2.x) - (v.p3.x - v.p0.x) * (v.p1.y + v.p2.y) + v.p1.y * (v.p0.x - v.p2.x) - v.p1.x * (v.p0.y - v.p2.y) + v.p3.y * (v.p2.x + v.p0.x / 3) - v.p3.x * (v.p2.y + v.p0.y / 3)) / 20;
}
fn getCoefficients(v: *const Cubic) [10]f64 {
    var x1 = v.p1.x;
    var y1 = v.p1.y;
    var x2 = v.p2.x;
    var y2 = v.p2.y;
    if (n.isZero(x1 - v.p0.x) and n.isZero(y1 - v.p0.y)) {
        x1 = v.p0.x;
        y1 = v.p0.y;
    }
    if (n.isZero(x2 - v.p3.x) and n.isZero(y2 - v.p3.y)) {
        x2 = v.p3.x;
        y2 = v.p3.y;
    }
    const cx = 3 * (x1 - v.p0.x);
    const bx = 3 * (x2 - x1) - cx;
    const ax = v.p3.x - v.p0.x - cx - bx;
    const cy = 3 * (y1 - v.p0.y);
    const by = 3 * (y2 - y1) - cy;
    const ay = v.p3.y - v.p0.y - cy - by;
    return .{ ax, bx, cx, ay, by, cy, x1, y1, x2, y2 };
}
fn getCoordinate(v0: f64, v3: f64, a: f64, b: f64, c: f64, t: f64) f64 {
    return if (t == 0) v0 else if (t == 1) v3 else ((a * t + b) * t + c) * t + v0;
}
pub fn getPoint(v: *const Cubic, t: f64) Point {
    const c = getCoefficients(v);
    return pointWithCoefficients(v, &c, t);
}
fn pointWithCoefficients(v: *const Cubic, c: *const [10]f64, t: f64) Point {
    return .{ .x = getCoordinate(v.p0.x, v.p3.x, c[0], c[1], c[2], t), .y = getCoordinate(v.p0.y, v.p3.y, c[3], c[4], c[5], t) };
}
pub fn getTangent(v: *const Cubic, t: f64) Point {
    const c = getCoefficients(v);
    var x: f64 = undefined;
    var y: f64 = undefined;
    if (t < n.CURVETIME_EPSILON) {
        x = c[2];
        y = c[5];
    } else if (t > 1 - n.CURVETIME_EPSILON) {
        x = 3 * (v.p3.x - c[8]);
        y = 3 * (v.p3.y - c[9]);
    } else {
        x = (3 * c[0] * t + 2 * c[1]) * t + c[2];
        y = (3 * c[3] * t + 2 * c[4]) * t + c[5];
    }
    if (x == 0 and y == 0 and (t < n.CURVETIME_EPSILON or t > 1 - n.CURVETIME_EPSILON)) {
        x = c[8] - c[6];
        y = c[9] - c[7];
    }
    const len = @sqrt(x * x + y * y);
    if (len != 0) {
        x /= len;
        y /= len;
    }
    return .{ .x = x, .y = y };
}
/// The loop branch of Paper's cubic classification gives two distinct interior parameters.
pub fn selfIntersectionTimes(v: *const Cubic) ?[2]f64 {
    const a1 = v.p0.x * (v.p3.y - v.p2.y) + v.p0.y * (v.p2.x - v.p3.x) + v.p3.x * v.p2.y - v.p3.y * v.p2.x;
    const a2 = v.p1.x * (v.p0.y - v.p3.y) + v.p1.y * (v.p3.x - v.p0.x) + v.p0.x * v.p3.y - v.p0.y * v.p3.x;
    const a3 = v.p2.x * (v.p1.y - v.p0.y) + v.p2.y * (v.p0.x - v.p1.x) + v.p1.x * v.p0.y - v.p1.y * v.p0.x;
    var d3 = 3 * a3;
    var d2 = d3 - a2;
    var d1 = d2 - a2 + a1;
    const len = @sqrt(d1 * d1 + d2 * d2 + d3 * d3);
    var magnitude: f64 = 0;
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }) |p| {
        magnitude = @max(magnitude, @abs(p.x), @abs(p.y));
    }
    const s = if (len > magnitude * n.getEpsilon(magnitude, null)) 1 / len else 0;
    d1 *= s;
    d2 *= s;
    d3 *= s;
    if (n.isZero(d1)) return null;
    const d = 3 * d2 * d2 - 4 * d1 * d3;
    if (d >= -n.EPSILON) return null;
    const root = @sqrt(-d);
    const denominator = 2 * d1;
    const a = (d2 + root) / denominator;
    const b = (d2 - root) / denominator;
    const low = n.CURVETIME_EPSILON;
    const high = 1 - low;
    if (!(a > low and a < high and b > low and b < high)) return null;
    return .{ @min(a, b), @max(a, b) };
}

test "cubic loop returns ordered interior times and excludes an endpoint-only contact" {
    const cubic: Cubic = .{ .p0 = .zero, .p1 = .{ .x = -16, .y = 3 }, .p2 = .{ .x = -16, .y = -10 }, .p3 = .{ .x = 0, .y = 9 } };
    for ([_]Cubic{ cubic, cubic.reversed() }) |v| {
        const times = selfIntersectionTimes(&v) orelse return error.TestUnexpectedResult;
        try std.testing.expectApproxEqAbs(@as(f64, 0.25), times[0], 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 0.75), times[1], 1e-12);
    }
    const loop = getPart(&cubic, 0.25, 0.75);
    try std.testing.expect(selfIntersectionTimes(&loop) == null);
}
const LengthIntegrand = struct {
    ax: f64,
    bx: f64,
    cx: f64,
    ay: f64,
    by: f64,
    cy: f64,
    fn init(v: *const Cubic) LengthIntegrand {
        const c = getCoefficients(v);
        return .{ .ax = 3 * c[0], .bx = 2 * c[1], .cx = c[2], .ay = 3 * c[3], .by = 2 * c[4], .cy = c[5] };
    }
    fn evaluate(self: *const LengthIntegrand, t: f64) f64 {
        const dx = (self.ax * t + self.bx) * t + self.cx;
        const dy = (self.ay * t + self.by) * t + self.cy;
        return @sqrt(dx * dx + dy * dy);
    }
};
fn getIterations(a: f64, b: f64) usize {
    return @intFromFloat(@max(2, @min(16, @ceil(@abs(b - a) * 32))));
}
fn lengthWithIntegrand(v: *const Cubic, a_: f64, b: f64, ds: ?*const LengthIntegrand) f64 {
    var a = a_;
    if (isStraight(v)) {
        var c = v.*;
        if (b < 1) {
            c = c.split(b).left;
            a /= b;
        }
        if (a > 0) c = c.split(a).right;
        const dx = c.p3.x - c.p0.x;
        const dy = c.p3.y - c.p0.y;
        return @sqrt(dx * dx + dy * dy);
    }
    var local: LengthIntegrand = undefined;
    const integrand = ds orelse blk: {
        local = LengthIntegrand.init(v);
        break :blk &local;
    };
    return n.integrate(integrand, LengthIntegrand.evaluate, a, b, getIterations(a, b));
}
pub fn getLength(v: *const Cubic, a: f64, b: f64) f64 {
    if (a == b) return 0;
    return lengthWithIntegrand(v, a, b, null);
}
pub fn getTimeAt(v: *const Cubic, offset: f64, start_: ?f64) ?f64 {
    const start = start_ orelse (if (offset < 0) @as(f64, 1) else 0);
    if (offset == 0) return start;
    const forward = offset > 0;
    const a = if (forward) start else 0;
    const b = if (forward) @as(f64, 1) else start;
    const ds = LengthIntegrand.init(v);
    const range_length = lengthWithIntegrand(v, a, b, &ds);
    const diff = @abs(offset) - range_length;
    if (@abs(diff) < n.EPSILON) return if (forward) b else a else if (diff > n.EPSILON) return null;
    const Context = struct {
        ds: LengthIntegrand,
        start: f64,
        length: f64 = 0,
        offset: f64,
        fn f(self: *@This(), t: f64) f64 {
            self.length += n.integrate(&self.ds, LengthIntegrand.evaluate, self.start, t, getIterations(self.start, t));
            self.start = t;
            return self.length - self.offset;
        }
        fn df(self: *@This(), t: f64) f64 {
            return self.ds.evaluate(t);
        }
    };
    var context: Context = .{ .ds = ds, .start = start, .offset = offset };
    return n.findRoot(&context, Context.f, Context.df, start + offset / range_length, a, b, 32, n.EPSILON);
}
fn pointDistance(a: Point, b: Point) f64 {
    const d = a.sub(b);
    return @sqrt(d.dot(d));
}
pub fn withinDistance(a: Point, b: Point, epsilon: f64) bool {
    const d = a.sub(b);
    return d.dot(d) <= epsilon * epsilon;
}
/// The projection of a Bézier onto the chord normal is contained in the
/// interval spanned by its four projected controls. Distance from this strip
/// lower-bounds distance to the curve, including when its handles straddle the chord.
pub fn outsideChordStrip(v: *const Cubic, p: Point, epsilon: f64) bool {
    const chord = v.p3.sub(v.p0);
    const projection = p.sub(v.p0).cross(chord);
    const first = v.p1.sub(v.p0).cross(chord);
    const second = v.p2.sub(v.p0).cross(chord);
    const gap = @max(@min(0, first, second) - projection, projection - @max(0, first, second));
    const magnitude = @max(@abs(p.x), @abs(p.y), @abs(v.p0.x), @abs(v.p0.y), @abs(v.p1.x), @abs(v.p1.y), @abs(v.p2.x), @abs(v.p2.y), @abs(v.p3.x), @abs(v.p3.y));
    // Underflow in a squared chord must only widen the acceptance strip.
    const length = @sqrt(@max(chord.dot(chord), std.math.floatMin(f64)));
    return gap > (epsilon + 16384 * std.math.floatEps(f64) * magnitude) * length;
}

pub fn getTimeOf(v: *const Cubic, point: Point, tolerance: ?f64) ?f64 {
    var magnitude: f64 = 0;
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }) |p| {
        magnitude = @max(magnitude, @abs(p.x), @abs(p.y));
    }
    const epsilon = if (tolerance != null and tolerance.? != 0) tolerance.? else n.getEpsilon(magnitude, n.GEOMETRIC_EPSILON);
    if (pointDistance(v.p0, point) <= epsilon) return 0;
    if (pointDistance(v.p3, point) <= epsilon) return 1;
    const coefficients = getCoefficients(v);
    var roots: [3]f64 = undefined;
    inline for (0..2) |i| {
        const count = solveCubic(v, i, if (i == 1) point.y else point.x, &roots, 0, 1);
        if (count > 0) {
            for (roots[0..@intCast(count)]) |t| {
                if (pointDistance(pointWithCoefficients(v, &coefficients, t), point) <= epsilon) return t;
            }
        }
    }
    return null;
}
pub fn getNearestTime(v: *const Cubic, point: Point) ?f64 {
    if (isStraight(v)) {
        const vx = v.p3.x - v.p0.x;
        const vy = v.p3.y - v.p0.y;
        const det = vx * vx + vy * vy;
        if (det == 0) return 0;
        const u = ((point.x - v.p0.x) * vx + (point.y - v.p0.y) * vy) / det;
        return if (u < n.EPSILON) 0 else if (u > 1 - n.EPSILON) 1 else getTimeOf(v, .{ .x = v.p0.x + u * vx, .y = v.p0.y + u * vy }, null);
    }
    const Refine = struct {
        values: *const Cubic,
        coefficients: [10]f64,
        point: Point,
        min_dist: f64 = std.math.inf(f64),
        min_t: f64 = 0,
        fn run(self: *@This(), t: f64) bool {
            if (t >= 0 and t <= 1) {
                const p = pointWithCoefficients(self.values, &self.coefficients, t);
                const dx = p.x - self.point.x;
                const dy = p.y - self.point.y;
                const dist = dx * dx + dy * dy;
                if (dist < self.min_dist) {
                    self.min_dist = dist;
                    self.min_t = t;
                    return true;
                }
            }
            return false;
        }
    };
    var refine: Refine = .{ .values = v, .point = point, .coefficients = getCoefficients(v) };
    for (0..101) |i| _ = refine.run(@as(f64, @floatFromInt(i)) / 100);
    var step: f64 = @as(f64, 1) / (100 * 2);
    while (step > n.CURVETIME_EPSILON) {
        if (!refine.run(refine.min_t - step) and !refine.run(refine.min_t + step)) step /= 2;
    }
    return refine.min_t;
}
