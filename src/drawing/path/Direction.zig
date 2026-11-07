//! Direction of a line or cubic as a quadratic Bernstein vector field.
//! Positive scalar factors may be cancelled without changing the local frame.
const std = @import("std");
const g = @import("../geometry.zig");
const Direction = @This();

// Form differences in wide precision too: rounding individual derivatives
// before cancellation can give a completely different frame near a stop.
pub const Ray = [2]f128;
const zero: Ray = @splat(0);
controls: [3]Ray,

fn difference(p: g.Point, q: g.Point) Ray {
    return .{ @as(f128, p.x) - q.x, @as(f128, p.y) - q.y };
}

/// Only replace a cubic by its chord when the *stored* control points
/// prove a single, forward direction. A tiny bend or reversal stays cubic.
pub fn monotoneLine(curve: g.Cubic) bool {
    inline for (.{ curve.p1, curve.p2, curve.p3 }, .{ curve.p0, curve.p1, curve.p2 }) |p, q| {
        inline for (.{ "x", "y" }) |axis| {
            const a: f128 = @field(p, axis);
            const b: f128 = @field(q, axis);
            const delta = a - b;
            const v = a - delta;
            if ((a - (delta + v)) + (v - b) != 0) return false;
        }
    }
    const field = init(curve, true) catch return false;
    return equal(field.controls[0], field.controls[1]) and equal(field.controls[1], field.controls[2]);
}

pub fn init(curve: g.Cubic, cubic: bool) !Direction {
    if (!curve.isFinite()) return error.NonFinite;
    if (!cubic) return constant(difference(curve.p3, curve.p0));
    var a = difference(curve.p1, curve.p0);
    const b = difference(curve.p2, curve.p1);
    var c = difference(curve.p3, curve.p2);
    if (equal(a, zero) and equal(c, zero)) return constant(b);
    // Cancel u or (1-u) to recover one-sided endpoint directions. Elevate
    // the remaining linear polynomial back to degree two.
    if (equal(a, zero) or equal(c, zero)) {
        const doubled: Ray = .{ 2 * b[0], 2 * b[1] };
        if (equal(a, zero)) a = doubled else c = doubled;
        if (equal(a, zero)) return constant(c);
        if (equal(c, zero)) return constant(a);
        if (parallel(a, c)) {
            if (!sameRay(a, c)) return error.UndefinedPathFrame;
            return constant(a);
        }
        return .{ .controls = .{ a, .{ (a[0] + c[0]) / 2, (a[1] + c[1]) / 2 }, c } };
    }
    if (parallel(a, b) and parallel(a, c)) {
        if (!sameRay(a, c)) return error.UndefinedPathFrame;
        // For positive endpoints a and c, b >= -sqrt(ac) gives a
        // nonnegative quadratic, including a removable interior stop.
        if (!equal(b, zero) and !sameRay(a, b)) {
            const order = if (@abs(a[0]) >= @abs(a[1]))
                compareProducts(b[0], b[0], a[0], c[0])
            else
                compareProducts(b[1], b[1], a[1], c[1]);
            if (order == .gt) return error.UndefinedPathFrame;
        }
        return constant(a);
    }
    return .{ .controls = .{ a, b, c } };
}

fn equal(a: Ray, b: Ray) bool {
    return a[0] == b[0] and a[1] == b[1];
}
fn constant(v: Ray) !Direction {
    if (equal(v, zero)) return error.UndefinedPathFrame;
    return .{ .controls = @splat(v) };
}
fn parallel(a: Ray, b: Ray) bool {
    return compareProducts(a[0], b[1], a[1], b[0]) == .eq;
}

// If rounded products tie, compare their residuals using Dekker's split.
// The inputs originate in binary64, well inside binary128's exponent range.
fn compareProducts(a: f128, b: f128, c: f128, d: f128) std.math.Order {
    @setFloatMode(.strict);
    const p = a * b;
    const q = c * d;
    if (p != q or p == 0) return std.math.order(p, q);
    return std.math.order(residual(a, b, p), residual(c, d, q));
}

fn residual(a: f128, b: f128, p: f128) f128 {
    @setFloatMode(.strict);
    const splitter: f128 = 0x1p57 + 1;
    const x = splitter * a;
    const y = splitter * b;
    const hi = x - (x - a);
    const hj = y - (y - b);
    const lo = a - hi;
    const lj = b - hj;
    return (((hi * hj - p) + hi * lj) + lo * hj) + lo * lj;
}
pub fn sameRay(a: Ray, b: Ray) bool {
    return parallel(a, b) and a[0] * b[0] + a[1] * b[1] > 0;
}

/// Signed shortest turn in path coordinates. An exact reversal turns +pi.
pub fn turnAngle(a: Ray, b: Ray) f64 {
    const order = compareProducts(a[0], b[1], a[1], b[0]);
    const dot = a[0] * b[0] + a[1] * b[1];
    if (order == .eq) return if (dot < 0) std.math.pi else 0;
    const cross = @abs(a[0] * b[1] - a[1] * b[0]);
    const scale = @max(@abs(dot), cross);
    const angle = std.math.atan2(@as(f64, @floatCast(cross / scale)), @as(f64, @floatCast(dot / scale)));
    return if (order == .lt) -angle else angle;
}

fn blossom(self: *const Direction, u: f128, v: f128) Ray {
    const a, const b, const c = self.controls;
    var value: Ray = undefined;
    inline for (0..2) |i| value[i] = (1 - v) * ((1 - u) * a[i] + u * b[i]) + v * ((1 - u) * b[i] + u * c[i]);
    return value;
}

pub fn ray(self: *const Direction, u: f64) Ray {
    if (u == 0) return self.controls[0];
    if (u == 1) return self.controls[2];
    return self.blossom(u, u);
}

pub fn narrow(v: Ray) !g.Point {
    const scale = @max(@abs(v[0]), @abs(v[1]));
    if (scale == 0) return error.UndefinedPathFrame;
    return .{ .x = @floatCast(v[0] / scale), .y = @floatCast(v[1] / scale) };
}

pub fn at(self: *const Direction, u: f64) !g.Point {
    return narrow(self.ray(u));
}

pub const AngularBounds = struct { speed: f64 = 0, acceleration: f64 = 0 };

/// In unit interval time, |angle'| <= |D'|/min|D| and
/// |angle''| <= |D''|/min|D| + 2*(|D'|/min|D|)^2.
/// A Bernstein hull meeting both axes needs a smaller interval.
pub fn angularBounds(self: *const Direction, lo: f64, hi: f64) ?AngularBounds {
    if (equal(self.controls[0], self.controls[1]) and equal(self.controls[0], self.controls[2])) return .{};
    const a = self.ray(lo);
    const b = self.blossom(lo, hi);
    const c = self.ray(hi);
    var lower: f128 = 0;
    var first: f128 = 0;
    var second: f128 = 0;
    var noise: f128 = 0;
    inline for (0..2) |i| {
        const magnitude = @max(@abs(self.controls[0][i]), @abs(self.controls[1][i]), @abs(self.controls[2][i]));
        const e = magnitude * (32 * std.math.floatEps(f128));
        noise += e;
        lower = @max(lower, @min(a[i], b[i], c[i]) - e, -@max(a[i], b[i], c[i]) - e);
        first += 2 * (@max(@abs(b[i] - a[i]), @abs(c[i] - b[i])) + 2 * e);
        second += 2 * (@abs((c[i] - b[i]) - (b[i] - a[i])) + 4 * e);
    }
    // Only certify directions resolvable to binary64 accuracy.
    if (lower <= 0 or noise > lower * std.math.floatEps(f64)) return null;
    const speed = first / lower;
    return .{ .speed = @floatCast(speed), .acceleration = @floatCast(second / lower + 2 * speed * speed) };
}
