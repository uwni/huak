//! Native special functions. Gamma kernels come from Zig's standard library;
//! error functions use C99 libm, already linked by the native runtime.
const std = @import("std");

pub extern "c" fn erf(x: f64) f64;
pub extern "c" fn erfc(x: f64) f64;

/// Euler beta on positive real arguments. Adapted from the positive-argument
/// branches of SciPy/xsf Cephes beta.h, commit 9ee993361a7b44e698f359062d56bfef0ffc3a38.
/// Copyright 1984, 1987 Stephen L. Moshier; Copyright 2024 SciPy.
/// BSD-3-Clause; see special.LICENSE. Gamma and log-gamma are not reimplemented.
pub fn beta(x: f64, y: f64) !f64 {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.NonFinite;
    if (x <= 0 or y <= 0) return error.DomainError;
    const a = @max(x, y);
    const b = @min(x, y);
    if (a > 1e6 * b and a > 1e6) {
        // Upstream's log-beta expansion avoids subtracting nearly equal
        // log-gammas. Small ratios avoid overflow in its correction terms.
        var result = std.math.lgamma(f64, b) - b * @log(a);
        const t = b / a;
        const u = (1 - b) / a;
        result += t * (1 - b) / 2;
        result += t * u * (1 - 2 * b) / 12;
        result += -t * t * u * (1 - b) / 12;
        return @exp(result);
    }
    const sum = a + b;
    if (sum > 171.624376956302725) {
        return @exp(std.math.lgamma(f64, a) + (std.math.lgamma(f64, b) - std.math.lgamma(f64, sum)));
    }
    const reciprocal = 1 / std.math.gamma(f64, sum);
    const ga = std.math.gamma(f64, a);
    const gb = std.math.gamma(f64, b);
    return if (@abs(ga * reciprocal - 1) > @abs(gb * reciprocal - 1))
        (gb * reciprocal) * ga
    else
        (ga * reciprocal) * gb;
}

test "beta keeps finite gamma ratios and unequal-argument tails" {
    const t = std.testing;
    for ([_]struct { a: f64, b: f64, expected: f64 }{
        .{ .a = 2, .b = 3, .expected = 1.0 / 12.0 },
        .{ .a = 0.5, .b = 0.5, .expected = std.math.pi },
        .{ .a = 100, .b = 2, .expected = 1.0 / 10100.0 },
        .{ .a = 200, .b = 2, .expected = 1.0 / 40200.0 },
        .{ .a = 1e16, .b = 1, .expected = 1e-16 },
        .{ .a = 1e100, .b = 2, .expected = 1e-200 },
    }) |case| {
        try t.expectApproxEqRel(case.expected, try beta(case.a, case.b), 3e-13);
        try t.expectEqual(try beta(case.a, case.b), try beta(case.b, case.a));
    }
    try t.expectEqual(@as(f64, 0), try beta(1000, 1000));
    try t.expectError(error.DomainError, beta(0, 1));
    try t.expectError(error.DomainError, beta(-0.5, 1));
}

test "error function complement retains small tails" {
    try std.testing.expectEqual(@as(f64, 0), erf(0));
    try std.testing.expectEqual(@as(f64, 1), erfc(0));
    try std.testing.expectApproxEqRel(@as(f64, 0.84270079294971486934), erf(1), 2e-15);
    try std.testing.expectApproxEqRel(@as(f64, 2.0884875837625447570e-45), erfc(10), 2e-14);
}
