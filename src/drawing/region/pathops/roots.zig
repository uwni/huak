// Copyright 2012 Google Inc.; BSD-style license: LICENSE.
// SkPathOpsQuad/Cubic polynomial roots, including the retained binary64 scaling
// and endpoint recovery checks. Real roots are distinct under upstream ULP rules.
const std = @import("std");
const n = @import("numeric.zig");
// Cardano must use the same host libm as the reference C++ implementation.
// A one-ULP acos difference can be amplified by the final root subtraction.
extern "c" fn acos(x: f64) f64;
fn linear(b: f64, c: f64, out: []f64) usize {
    if (n.approximatelyZero(b)) {
        out[0] = 0;
        return @intFromBool(c == 0);
    }
    out[0] = -c / b;
    return 1;
}
pub fn quadraticReal(a: f64, b: f64, c: f64, out: *[2]f64) usize {
    if (a == 0) return linear(b, c, out);
    const p = b / (2 * a);
    const q = c / a;
    if (n.approximatelyZero(a) and (n.approximatelyZeroInverse(p) or n.approximatelyZeroInverse(q))) return linear(b, c, out);
    const p2 = p * p;
    if (!n.almostDequalUlps(p2, q) and p2 < q) return 0;
    const sqrt_d = if (p2 > q) @sqrt(p2 - q) else 0;
    out[0] = sqrt_d - p;
    out[1] = -sqrt_d - p;
    return 1 + @as(usize, @intFromBool(!n.almostDequalUlps(out[0], out[1])));
}
pub fn addValidTs(real: []const f64, out: []f64) usize {
    var count: usize = 0;
    next: for (real) |value| {
        if (!n.approximatelyZeroOrMore(value) or !n.approximatelyOneOrLess(value)) continue;
        const t = if (n.approximatelyLessThanZero(value)) 0 else if (n.approximatelyGreaterThanOne(value)) 1 else value;
        for (out[0..count]) |existing| if (n.approximatelyEqual(existing, t)) continue :next;
        out[count] = t;
        count += 1;
    }
    return count;
}
pub fn quadraticValidT(a: f64, b: f64, c: f64, out: *[2]f64) usize {
    var real: [2]f64 = undefined;
    const count = quadraticReal(a, b, c, &real);
    return addValidTs(real[0..count], out);
}
pub fn cubicReal(aa: f64, bb: f64, cc: f64, dd: f64, out: *[3]f64) usize {
    var a = aa;
    var b = bb;
    var c = cc;
    var d = dd;
    const coefficient_scale = @max(@max(@abs(a), @abs(b)), @max(@abs(c), @abs(d)));
    if (coefficient_scale > 0 and std.math.isFinite(coefficient_scale)) {
        const exponent = std.math.frexp(coefficient_scale).exponent;
        a = std.math.ldexp(a, -exponent);
        b = std.math.ldexp(b, -exponent);
        c = std.math.ldexp(c, -exponent);
        d = std.math.ldexp(d, -exponent);
    }
    var qroots: [2]f64 = undefined;
    if (n.approximatelyZero(a) and n.approximatelyZeroWhenComparedTo(a, b) and n.approximatelyZeroWhenComparedTo(a, c) and n.approximatelyZeroWhenComparedTo(a, d)) {
        const count = quadraticReal(b, c, d, &qroots);
        @memcpy(out[0..count], qroots[0..count]);
        return count;
    }
    if (n.approximatelyZeroWhenComparedTo(d, a) and n.approximatelyZeroWhenComparedTo(d, b) and n.approximatelyZeroWhenComparedTo(d, c)) {
        const count = quadraticReal(a, b, c, &qroots);
        @memcpy(out[0..count], qroots[0..count]);
        for (out[0..count]) |value| if (n.approximatelyZero(value)) return count;
        out[count] = 0;
        return count + 1;
    }
    if (n.approximatelyZero(a + b + c + d)) {
        const count = quadraticReal(a, a + b, -d, &qroots);
        @memcpy(out[0..count], qroots[0..count]);
        for (out[0..count]) |value| if (n.almostDequalUlps(value, 1)) return count;
        out[count] = 1;
        return count + 1;
    }
    const inv_a = 1 / a;
    const na = b * inv_a;
    const nb = c * inv_a;
    const nc = d * inv_a;
    const a2 = na * na;
    // Preserve the retained C++ solver's fused evaluation order. Splitting
    // these operations changes Cardano's intermediate Q/R rounding.
    const q = @mulAdd(f64, -nb, 3, a2) / 9;
    const r = @mulAdd(f64, nc, 27, @mulAdd(f64, 2 * a2, na, (-nb) * (9 * na))) / 54;
    const r2 = r * r;
    const q3 = q * q * q;
    const discriminant = r2 - q3;
    const adiv3 = na / 3;
    var count: usize = 1;
    if (discriminant < 0) {
        const theta = acos(std.math.clamp(r / @sqrt(q3), -1, 1));
        const neg2rootq = -2 * @sqrt(q);
        out[0] = @mulAdd(f64, neg2rootq, @cos(theta / 3), -adiv3);
        var value = @mulAdd(f64, neg2rootq, @cos((theta + 2 * std.math.pi) / 3), -adiv3);
        if (!n.almostDequalUlps(out[0], value)) {
            out[count] = value;
            count += 1;
        }
        value = @mulAdd(f64, neg2rootq, @cos((theta - 2 * std.math.pi) / 3), -adiv3);
        if (!n.almostDequalUlps(out[0], value) and (count == 1 or !n.almostDequalUlps(out[1], value))) {
            out[count] = value;
            count += 1;
        }
    } else {
        var value = std.math.cbrt(@abs(r) + @sqrt(discriminant));
        if (r > 0) value = -value;
        if (value != 0) value += q / value;
        out[0] = value - adiv3;
        if (n.almostDequalUlps(r2, q3)) {
            const second = -value / 2 - adiv3;
            if (!n.almostDequalUlps(out[0], second)) {
                out[count] = second;
                count += 1;
            }
        }
    }
    return count;
}
pub fn cubicValidT(a: f64, b: f64, c: f64, d: f64, out: *[3]f64) usize {
    var real: [3]f64 = undefined;
    const count = cubicReal(a, b, c, d, &real);
    var found = addValidTs(real[0..count], out);
    const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
    const endpoint_error = gamma * (@abs(a) + @abs(b) + @abs(c) + @abs(d));
    next: for (real[0..count]) |value| {
        var endpoint: f64 = undefined;
        if (!n.approximatelyOneOrLess(value) and n.between(1, value, 1.00005) and @abs(a + b + c + d) <= endpoint_error) endpoint = 1 else if (!n.approximatelyZeroOrMore(value) and n.between(-0.00005, value, 0) and @abs(d) <= endpoint_error) endpoint = 0 else continue;
        for (out[0..found]) |existing| if (n.approximatelyEqual(existing, endpoint)) continue :next;
        std.debug.assert(found < 3);
        out[found] = endpoint;
        found += 1;
    }
    return found;
}
test "near-coincident ray rejects an outside root without loosening endpoints" {
    var values: [3]f64 = undefined;
    const count = cubicValidT(-1.9061917744743601e-6, 7.4612132339500506e-6, 2.8462181529076762e-11, -5.726148722041931e-17, &values);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(values[0] > 0 and values[0] < 1);
}

test "Cardano preserves the reference host acos rounding at a captured ray ratio" {
    const ratio: f64 = 0.11961732394784848;
    const theta = acos(ratio);
    try std.testing.expectApproxEqAbs(ratio, @cos(theta), 2 * n.EPSILON);
    const target = @import("builtin");
    if (target.os.tag == .macos and target.cpu.arch == .aarch64) {
        // Measured from the retained binary64 C++ intersector on this target.
        try std.testing.expectEqual(@as(u64, 0x3ff736da6bf15035), @as(u64, @bitCast(theta)));
    }
}
test "quadratic and cubic roots preserve distinct real roots" {
    var q: [2]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 2), quadraticValidT(1, -1, 0, &q));
    var c: [3]f64 = undefined;
    const count = cubicValidT(1, -1.5, 0.5, 0, &c);
    try std.testing.expectEqual(@as(usize, 3), count);
    std.mem.sort(f64, c[0..count], {}, std.sort.asc(f64));
    try std.testing.expectEqualSlices(f64, &.{ 0, 0.5, 1 }, c[0..count]);
}

test "Cardano preserves known real roots and coefficient scaling" {
    const cases = [_]struct { coefficients: [4]f64, expected: []const f64 }{
        // (t-1/8)(t-3/8)(t-7/8): three distinct roots in the general branch.
        .{ .coefficients = .{ 1, -1.375, 0.484375, -0.041015625 }, .expected = &.{ 0.125, 0.375, 0.875 } },
        // (t-1/4)^2(t+1/2): exact zero discriminant, two distinct real roots.
        .{ .coefficients = .{ 1, 0, -0.1875, 0.03125 }, .expected = &.{ -0.5, 0.25 } },
        // (t-1/4)^3: zero Q and R, one distinct real root.
        .{ .coefficients = .{ 1, -0.75, 0.1875, -0.015625 }, .expected = &.{0.25} },
        // Positive derivative everywhere gives exactly one real root.
        .{ .coefficients = .{ 1, 0, 1, -1 }, .expected = &.{0.6823278038280193} },
    };
    for (cases) |case| for ([_]i32{ -800, -80, 0, 80, 800 }) |exponent| {
        var coefficients: [4]f64 = undefined;
        for (&coefficients, case.coefficients) |*scaled, value| scaled.* = std.math.ldexp(value, exponent);
        var actual: [3]f64 = undefined;
        const count = cubicReal(coefficients[0], coefficients[1], coefficients[2], coefficients[3], &actual);
        try std.testing.expectEqual(case.expected.len, count);
        std.mem.sort(f64, actual[0..count], {}, std.sort.asc(f64));
        for (case.expected, actual[0..count]) |expected, value| {
            try std.testing.expectApproxEqAbs(expected, value, 1e-14);
            // Independently evaluate the original polynomial in binary128.
            const t: f128 = value;
            var residual: f128 = coefficients[0];
            var scale: f128 = @abs(residual);
            for (coefficients[1..]) |coefficient| {
                residual = residual * t + @as(f128, coefficient);
                scale = scale * @abs(t) + @abs(@as(f128, coefficient));
            }
            try std.testing.expect(@abs(residual) <= 16 * @as(f128, n.EPSILON) * scale);
        }
    };
}
