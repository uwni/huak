// Copyright 2012 Google Inc.; binary64 adaptation copyright 2026 Huak contributors.
// BSD-style license: LICENSE.
// Port of Skia 1c2b83b5af8f53181742af1505edd18c2418c777 SkPathOpsTypes
// and the retained f64 SkPathOpsExact arithmetic. Coordinates use ULP tests;
// parameter tests keep their distinct epsilon policies.
const std = @import("std");
pub const EPSILON = std.math.floatEps(f64);
pub const EPSILON_HALF = EPSILON / 2;
pub const EPSILON_DOUBLE = EPSILON * 2;
pub const EPSILON_INVERSE = 1 / EPSILON;
pub const PRECISE_EPSILON = EPSILON * 4;
pub const ROUGH_EPSILON = EPSILON * 64;
pub const MORE_ROUGH_EPSILON = EPSILON * 256;

fn orderedBits(value: f64) u64 {
    const bits: u64 = @bitCast(value);
    const sign_mask: u64 = 1 << 63;
    const magnitude = bits & ~sign_mask;
    return if (bits & sign_mask != 0) sign_mask - magnitude else sign_mask + magnitude;
}
fn ulpsDistanceInternal(a: f64, b: f64) u64 {
    const aa = orderedBits(a);
    const bb = orderedBits(b);
    return if (aa > bb) aa - bb else bb - aa;
}
pub fn ulpsDistance(a: f64, b: f64) i32 {
    if (a == b) return 0;
    const sa = @as(u64, @bitCast(a)) >> 63;
    const sb = @as(u64, @bitCast(b)) >> 63;
    if (!std.math.isFinite(a) or !std.math.isFinite(b) or sa != sb) return std.math.maxInt(i32);
    return @intCast(@min(ulpsDistanceInternal(a, b), std.math.maxInt(i32)));
}
fn denormalized(a: f64, b: f64, epsilon: f64) bool {
    const check = EPSILON * epsilon / 2;
    return @abs(a) <= check and @abs(b) <= check;
}
fn equalNoNormal(a: f64, b: f64, epsilon: u64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return false;
    if (a == b) return true;
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return false;
    return ulpsDistanceInternal(a, b) < epsilon;
}
fn equal(a: f64, b: f64, epsilon: u64, depsilon: f64) bool {
    return denormalized(a, b, depsilon) or equalNoNormal(a, b, epsilon);
}
fn less(a: f64, b: f64, epsilon: u64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return false;
    if (denormalized(a, b, @floatFromInt(epsilon))) return a <= b - EPSILON * @as(f64, @floatFromInt(epsilon));
    return a < b and ulpsDistanceInternal(a, b) >= epsilon;
}
fn lessEqual(a: f64, b: f64, epsilon: u64) bool {
    if (std.math.isNan(a) or std.math.isNan(b)) return false;
    if (denormalized(a, b, @floatFromInt(epsilon))) return a < b + EPSILON * @as(f64, @floatFromInt(epsilon));
    return a <= b or ulpsDistanceInternal(a, b) < epsilon;
}
pub fn almostBequalUlps(a: f64, b: f64) bool {
    return equal(a, b, 2, 2);
}
pub fn almostPequalUlps(a: f64, b: f64) bool {
    return equal(a, b, 8, 8);
}
pub fn almostDequalUlps(a: f64, b: f64) bool {
    return equalNoNormal(a, b, 16);
}
pub fn almostEqualUlps(a: f64, b: f64) bool {
    return equal(a, b, 16, 16);
}
pub fn almostEqualUlpsPin(a: f64, b: f64) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and almostEqualUlps(a, b);
}
pub fn notAlmostEqualUlps(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and !almostEqualUlps(a, b);
}
pub fn notAlmostEqualUlpsPin(a: f64, b: f64) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and notAlmostEqualUlps(a, b);
}
pub fn notAlmostDequalUlps(a: f64, b: f64) bool {
    return !std.math.isNan(a) and !std.math.isNan(b) and !almostDequalUlps(a, b);
}
pub fn roughlyEqualUlps(a: f64, b: f64) bool {
    return equal(a, b, 256, 1024);
}
pub fn almostLessUlps(a: f64, b: f64) bool {
    return less(a, b, 16);
}
pub fn almostLessOrEqualUlps(a: f64, b: f64) bool {
    return lessEqual(a, b, 16);
}
pub fn almostBetweenUlps(a: f64, b: f64, c: f64) bool {
    return if (a <= c) lessEqual(a, b, 2) and lessEqual(b, c, 2) else lessEqual(b, a, 2) and lessEqual(c, b, 2);
}
pub fn zeroOrOne(x: f64) bool {
    return x == 0 or x == 1;
}
pub fn approximatelyZero(x: f64) bool {
    return @abs(x) < EPSILON;
}
pub fn preciselyZero(x: f64) bool {
    return @abs(x) < PRECISE_EPSILON;
}
pub fn approximatelyZeroHalf(x: f64) bool {
    return @abs(x) < EPSILON_HALF;
}
pub fn approximatelyZeroInverse(x: f64) bool {
    return @abs(x) > EPSILON_INVERSE;
}
pub fn approximatelyZeroWhenComparedTo(x: f64, y: f64) bool {
    return x == 0 or @abs(x) < @abs(y * EPSILON);
}
pub const preciselyZeroWhenComparedTo = approximatelyZeroWhenComparedTo;
pub fn approximatelyEqual(x: f64, y: f64) bool {
    return approximatelyZero(x - y);
}
pub fn preciselyEqual(x: f64, y: f64) bool {
    return preciselyZero(x - y);
}
pub fn approximatelyEqualHalf(x: f64, y: f64) bool {
    return approximatelyZeroHalf(x - y);
}
pub fn approximatelyGreaterThanOne(x: f64) bool {
    return x > 1 - EPSILON;
}
pub fn preciselyGreaterThanOne(x: f64) bool {
    return x > 1 - PRECISE_EPSILON;
}
pub fn approximatelyLessThanZero(x: f64) bool {
    return x < EPSILON;
}
pub fn preciselyLessThanZero(x: f64) bool {
    return x < PRECISE_EPSILON;
}
pub const preciselyNegative = preciselyLessThanZero;
pub fn approximatelyOneOrLess(x: f64) bool {
    return x < 1 + EPSILON;
}
pub fn approximatelyOneOrLessDouble(x: f64) bool {
    return x < 1 + EPSILON_DOUBLE;
}
pub fn approximatelyPositive(x: f64) bool {
    return x > -EPSILON;
}
pub const approximatelyZeroOrMore = approximatelyPositive;
pub fn approximatelyZeroOrMoreDouble(x: f64) bool {
    return x > -EPSILON_DOUBLE;
}
pub fn preciselyBetween(a: f64, b: f64, c: f64) bool {
    return if (a <= c) preciselyNegative(a - b) and preciselyNegative(b - c) else preciselyNegative(b - a) and preciselyNegative(c - b);
}
pub fn between(a: f64, b: f64, c: f64) bool {
    return (a - b) * (c - b) <= 0;
}
pub fn roughlyEqual(x: f64, y: f64) bool {
    return @abs(x - y) < ROUGH_EPSILON;
}
pub fn roughlyNegative(x: f64) bool {
    return x < ROUGH_EPSILON;
}
pub fn roughlyBetween(a: f64, b: f64, c: f64) bool {
    return if (a <= c) roughlyNegative(a - b) and roughlyNegative(b - c) else roughlyNegative(b - a) and roughlyNegative(c - b);
}
pub fn moreRoughlyEqual(x: f64, y: f64) bool {
    return @abs(x - y) < MORE_ROUGH_EPSILON;
}
pub fn interp(a: f64, b: f64, t: f64) f64 {
    return @mulAdd(f64, b - a, t, a);
}
pub fn sign(x: f64) i32 {
    return @as(i32, @intFromBool(x > 0)) - @as(i32, @intFromBool(x < 0));
}
pub fn side(x: f64) u2 {
    return @as(u2, @intFromBool(x > 0)) + @as(u2, @intFromBool(x >= 0));
}
pub fn pinT(t: f64) f64 {
    return if (preciselyLessThanZero(t)) 0 else if (preciselyGreaterThanOne(t)) 1 else t;
}

/// Compensated finite-precision working arithmetic; stored parameters stay f64.
pub const DoubleDouble = struct {
    hi: f64,
    lo: f64 = 0,
    pub fn sum(a: f64, b: f64) DoubleDouble {
        const s = a + b;
        const v = s - a;
        return .{ .hi = s, .lo = (a - (s - v)) + (b - v) };
    }
    pub fn difference(a: f64, b: f64) DoubleDouble {
        return sum(a, -b);
    }
    pub fn product(a: f64, b: f64) DoubleDouble {
        const p = a * b;
        return .{ .hi = p, .lo = @mulAdd(f64, a, b, -p) };
    }
    pub fn neg(a: DoubleDouble) DoubleDouble {
        return .{ .hi = -a.hi, .lo = -a.lo };
    }
    pub fn add(a: DoubleDouble, b: DoubleDouble) DoubleDouble {
        const high = sum(a.hi, b.hi);
        const low = sum(a.lo, b.lo);
        const middle = sum(high.lo, low.hi);
        const result = sum(high.hi, middle.hi);
        return sum(result.hi, result.lo + middle.lo + low.lo);
    }
    pub fn sub(a: DoubleDouble, b: DoubleDouble) DoubleDouble {
        return a.add(b.neg());
    }
    pub fn mul(a: DoubleDouble, b: DoubleDouble) DoubleDouble {
        return product(a.hi, b.hi).add(product(a.hi, b.lo)).add(product(a.lo, b.hi)).add(product(a.lo, b.lo));
    }
    pub fn dividedBy(a: DoubleDouble, b: DoubleDouble) f64 {
        const first = a.hi / b.hi;
        const remainder = a.sub(b.mul(.{ .hi = first }));
        const correction = (remainder.hi + remainder.lo) / b.hi;
        return first + correction;
    }
};
pub const DD = DoubleDouble;
pub fn ddCross(ax: DD, ay: DD, bx: DD, by: DD) DD {
    return ax.mul(by).sub(ay.mul(bx));
}

fn after(value: f64, count: u64) f64 {
    return @bitCast(@as(u64, @bitCast(value)) + count);
}
test "binary64 ULP budgets preserve the original strict endpoints" {
    const t = std.testing;
    try t.expect(almostEqualUlps(1, after(1, 15)));
    try t.expect(!almostEqualUlps(1, after(1, 16)));
    try t.expect(notAlmostEqualUlps(1, after(1, 16)));
    try t.expect(!notAlmostEqualUlps(1, after(1, 15)));
    try t.expect(almostBequalUlps(1, after(1, 1)));
    try t.expect(!almostBequalUlps(1, after(1, 2)));
    try t.expect(almostPequalUlps(1, after(1, 7)));
    try t.expect(!almostPequalUlps(1, after(1, 8)));
    try t.expect(roughlyEqualUlps(1, after(1, 255)));
    try t.expect(!roughlyEqualUlps(1, after(1, 256)));
    try t.expectEqual(@as(i32, 1), ulpsDistance(1, after(1, 1)));
    try t.expectEqual(@as(i32, 1), ulpsDistance(-1, -after(1, 1)));
    try t.expectEqual(@as(i32, 0), ulpsDistance(-0.0, 0.0));
    const tiny: f64 = @bitCast(@as(u64, 1));
    try t.expectEqual(std.math.maxInt(i32), ulpsDistance(-tiny, 0));
    try t.expect(almostDequalUlps(-tiny, 0));
    try t.expect(almostDequalUlps(-0.0, 0.0));
    try t.expect(almostLessUlps(1, after(1, 16)));
    try t.expect(!almostLessUlps(1, after(1, 15)));
    try t.expect(almostLessOrEqualUlps(1, 1));
    try t.expect(almostBetweenUlps(0, 0.5, 1) and almostBetweenUlps(1, 0.5, 0));
}
test "binary64 scales and nonfinite ordering match retained native contracts" {
    const t = std.testing;
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    try t.expect(!almostEqualUlps(1e5, 1e5 + 1e-3));
    try t.expect(!almostDequalUlps(1e-300, 2e-300));
    try t.expect(almostEqualUlps(0, EPSILON));
    try t.expect(!almostEqualUlps(0, 1e-12));
    try t.expect(!almostEqualUlps(-1e308, 1e308));
    try t.expectEqual(std.math.maxInt(i32), ulpsDistance(-1e308, 1e308));
    try t.expect(!almostEqualUlpsPin(inf, inf));
    try t.expect(!notAlmostEqualUlpsPin(inf, 1));
    try t.expect(!almostEqualUlps(nan, nan));
    try t.expect(!almostLessUlps(nan, 1));
    try t.expect(!almostLessOrEqualUlps(1, nan));
    try t.expect(!almostEqualUlps(std.math.floatMax(f64), inf));
}
test "interpolation preserves retained C++ fused rounding" {
    // Fixed outputs from SkDInterp in the retained f64 reference, including
    // cancellation and a large-coordinate halfway case.
    const cases = [_][4]u64{
        .{ 0x3fb999999999999a, 0x3feccccccccccccd, 0x3fd3333333333333, 0x3fd5c28f5c28f5c3 },
        .{ 0x3fc999999999999a, 0x3fe999999999999a, 0x3fe6666666666666, 0x3fe3d70a3d70a3d7 },
        .{ 0x3ff0000000000000, 0xc000000000000000, 0x3fd5555555555555, 0x3c90000000000000 },
        .{ 0x426d1a94a2000000, 0xc27d1a94a2000000, 0x3fd5555555555555, 0x3f0d1a94a2000000 },
        .{ 0x4310000000000000, 0x431000000000000c, 0x3fa5555555555556, 0x4310000000000001 },
    };
    for (cases) |case| {
        const actual = interp(@bitCast(case[0]), @bitCast(case[1]), @bitCast(case[2]));
        try std.testing.expectEqual(case[3], @as(u64, @bitCast(actual)));
    }
}

test "compensated products and subtraction keep cancellation tails" {
    const t = std.testing;
    const a = DD.difference(1, 0x1p-54);
    try t.expectEqual(@as(f64, 1), a.hi);
    try t.expectEqual(@as(f64, -0x1p-54), a.lo);
    const b = DD.product(1 + 0x1p-27, 1 - 0x1p-27);
    try t.expectEqual(@as(f64, 1), b.hi);
    try t.expectEqual(@as(f64, -0x1p-54), b.lo);
    try t.expectEqual(@as(f64, 0x1p-54), (DD{ .hi = 1 }).sub(b).hi);
    try t.expectEqual(@as(f64, 0.25), (DD{ .hi = 1 }).dividedBy(.{ .hi = 4 }));
}
