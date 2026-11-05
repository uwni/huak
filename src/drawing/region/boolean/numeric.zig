// Ported from Paper.js v0.16.0 src/util/Numerical.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey, https://paperjs.org/
// Distributed under the MIT license. See the retained upstream LICENSE.
const std = @import("std");
pub const EPSILON: f64 = 1e-12;
pub const MACHINE_EPSILON: f64 = 1.12e-16;
pub const CURVETIME_EPSILON: f64 = 1e-8;
pub const GEOMETRIC_EPSILON: f64 = 1e-7;
pub const TRIGONOMETRIC_EPSILON: f64 = 1e-8;
pub const ANGULAR_EPSILON: f64 = 1e-5;
pub const KAPPA: f64 = 4 * (@sqrt(@as(f64, 2)) - 1) / 3;
pub fn clamp(value: f64, min: f64, max: f64) f64 {
    return if (value < min) min else if (value > max) max else value;
}
pub fn isZero(value: f64) bool {
    return value >= -EPSILON and value <= EPSILON;
}
pub fn isMachineZero(value: f64) bool {
    return value >= -MACHINE_EPSILON and value <= MACHINE_EPSILON;
}
pub fn getEpsilon(magnitude: f64, epsilon: ?f64) f64 {
    return @max(EPSILON, magnitude * 4 * MACHINE_EPSILON, epsilon orelse 0);
}
fn split(value: f64) [2]f64 {
    const x = value * 134217729;
    const y = value - x;
    const hi = y + x;
    return .{ hi, value - hi };
}
fn getDiscriminant(a: f64, b: f64, c: f64) f64 {
    var d = b * b - a * c;
    const e = b * b + a * c;
    if (@abs(d) * 3 < e) {
        const ad = split(a);
        const bd = split(b);
        const cd = split(c);
        const p = b * b;
        const dp = (bd[0] * bd[0] - p + 2 * bd[0] * bd[1]) + bd[1] * bd[1];
        const q = a * c;
        const dq = (ad[0] * cd[0] - q + ad[0] * cd[1] + ad[1] * cd[0]) + ad[1] * cd[1];
        d = (p - q) + (dp - dq);
    }
    return d;
}
fn getNormalizationFactor(norm: f64) f64 {
    if (norm == 0 or !(norm < 1e-8 or norm > 1e8) or !std.math.isFinite(norm)) return 0;
    // The upstream power is exact for integer exponents; ldexp produces the
    // same binary64 factor without a libm pow call.
    const exponent: i32 = @intFromFloat(-@floor(@log2(norm) + 0.5));
    return std.math.ldexp(@as(f64, 1), exponent);
}
pub fn solveQuadratic(a_: f64, b_: f64, c_: f64, roots: *[2]f64, min: ?f64, max: ?f64) i32 {
    var a = a_;
    var b = b_;
    var c = c_;
    var x1 = std.math.nan(f64);
    var x2 = std.math.inf(f64);
    if (@abs(a) < EPSILON) {
        if (@abs(b) < EPSILON) return if (@abs(c) < EPSILON) -1 else 0;
        x1 = -c / b;
    } else {
        b *= -0.5;
        var d = getDiscriminant(a, b, c);
        if (d != 0 and @abs(d) < MACHINE_EPSILON) {
            const f = getNormalizationFactor(@max(@abs(a), @abs(b), @abs(c)));
            if (f != 0) {
                a *= f;
                b *= f;
                c *= f;
                d = getDiscriminant(a, b, c);
            }
        }
        if (d >= -MACHINE_EPSILON) {
            const q = if (d < 0) 0 else @sqrt(d);
            const r = b + (if (b < 0) -q else q);
            if (r == 0) {
                x1 = c / a;
                x2 = -x1;
            } else {
                x1 = r / a;
                x2 = c / r;
            }
        }
    }
    var count: usize = 0;
    const min_b = (min orelse 0) - EPSILON;
    const max_b = (max orelse 0) + EPSILON;
    if (std.math.isFinite(x1) and (min == null or (x1 > min_b and x1 < max_b))) {
        roots[count] = if (min) |m| clamp(x1, m, max.?) else x1;
        count += 1;
    }
    if (x2 != x1 and std.math.isFinite(x2) and (min == null or (x2 > min_b and x2 < max_b))) {
        roots[count] = if (min) |m| clamp(x2, m, max.?) else x2;
        count += 1;
    }
    return @intCast(count);
}
pub fn solveCubic(a_: f64, b_: f64, c_: f64, d_: f64, roots: *[3]f64, min: ?f64, max: ?f64) i32 {
    var a = a_;
    var b = b_;
    var c = c_;
    var d = d_;
    const f = getNormalizationFactor(@max(@abs(a), @abs(b), @abs(c), @abs(d)));
    if (f != 0) {
        a *= f;
        b *= f;
        c *= f;
        d *= f;
    }
    var x: f64 = undefined;
    var b1: f64 = undefined;
    var c2: f64 = undefined;
    if (@abs(a) < EPSILON) {
        a = b;
        b1 = c;
        c2 = d;
        x = std.math.inf(f64);
    } else if (@abs(d) < EPSILON) {
        b1 = b;
        c2 = c;
        x = 0;
    } else {
        x = -(b / a) / 3;
        var tmp = a * x;
        b1 = tmp + b;
        c2 = b1 * x + c;
        var qd = (tmp + b1) * x + c2;
        var q = c2 * x + d;
        const t = q / a;
        const r = std.math.pow(f64, @abs(t), @as(f64, 1) / 3);
        const s: f64 = if (t < 0) -1 else 1;
        const td = -qd / a;
        const rd = if (td > 0) 1.324717957244746 * @max(r, @sqrt(td)) else r;
        var x0 = x - s * rd;
        if (x0 != x) {
            while (true) {
                x = x0;
                tmp = a * x;
                b1 = tmp + b;
                c2 = b1 * x + c;
                qd = (tmp + b1) * x + c2;
                q = c2 * x + d;
                x0 = if (qd == 0) x else x - q / qd / (1 + MACHINE_EPSILON);
                if (!(s * x0 > s * x)) break;
            }
            if (@abs(a) * x * x > @abs(d / x)) {
                c2 = -d / x;
                b1 = (c2 - c) / x;
            }
        }
    }
    var quadratic: [2]f64 = .{ std.math.nan(f64), std.math.nan(f64) };
    var count = solveQuadratic(a, b1, c2, &quadratic, min, max);
    if (count > 0) @memcpy(roots[0..@intCast(count)], quadratic[0..@intCast(count)]);
    if (std.math.isFinite(x) and (count == 0 or (count > 0 and x != quadratic[0] and x != quadratic[1])) and (min == null or (x > min.? - EPSILON and x < max.? + EPSILON))) {
        roots[@intCast(count)] = if (min) |m| clamp(x, m, max.?) else x;
        count += 1;
    }
    return count;
}
// Callbacks carry their state explicitly; arithmetic and stopping rules follow upstream.
pub fn integrate(context: anytype, comptime f: anytype, a: f64, b: f64, n: usize) f64 {
    const x = abscissas[n - 2];
    const w = weights[n - 2];
    const half = (b - a) * 0.5;
    const middle = half + a;
    var i: usize = 0;
    const m = (n + 1) >> 1;
    var sum: f64 = 0;
    if (n & 1 != 0) {
        sum = w[i] * f(context, middle);
        i += 1;
    }
    while (i < m) : (i += 1) {
        const ax = half * x[i];
        sum += w[i] * (f(context, middle + ax) + f(context, middle - ax));
    }
    return half * sum;
}
pub fn findRoot(context: anytype, comptime f: anytype, comptime df: anytype, x_: f64, a_: f64, b_: f64, n: usize, tolerance: f64) f64 {
    var x = x_;
    var a = a_;
    var b = b_;
    for (0..n) |_| {
        const fx = f(context, x);
        const dx = fx / df(context, x);
        const nx = x - dx;
        if (@abs(dx) < tolerance) {
            x = nx;
            break;
        }
        if (fx > 0) {
            b = x;
            x = if (nx <= a) (a + b) * 0.5 else nx;
        } else {
            a = x;
            x = if (nx >= b) (a + b) * 0.5 else nx;
        }
    }
    return clamp(x, a, b);
}
pub fn solveBernstein(allocator: std.mem.Allocator, coefficients: []const f64, errors: []const f64, roots: *std.ArrayList(f64), width: f64) std.mem.Allocator.Error!usize {
    std.debug.assert(coefficients.len <= 10 and coefficients.len == errors.len);
    const before = roots.items.len;
    try bernsteinSolve(allocator, coefficients, errors, roots, width, 0, 1);
    return roots.items.len - before;
}
fn bernsteinSolve(allocator: std.mem.Allocator, values: []const f64, bounds: []const f64, roots: *std.ArrayList(f64), width: f64, from: f64, to: f64) std.mem.Allocator.Error!void {
    var changes: usize = 0;
    var zeros: usize = 0;
    var sign: i2 = 0;
    for (values, bounds) |value, bound| {
        if (@abs(value) <= bound) {
            zeros += 1;
        } else {
            const s: i2 = if (value > 0) 1 else -1;
            if (sign != 0 and s != sign) changes += 1;
            sign = s;
        }
    }
    if (zeros == values.len or ((changes != 0 or zeros != 0) and to - from <= width)) {
        try roots.append(allocator, (from + to) / 2);
    } else if (changes == 1 and zeros == 0) {
        var a: f64 = 0;
        var b: f64 = 1;
        const negative = values[0] < 0;
        while (from + (to - from) * a < from + (to - from) * b and (a + b) / 2 > a and (a + b) / 2 < b) {
            const t = (a + b) / 2;
            var v: [10]f64 = undefined;
            @memcpy(v[0..values.len], values);
            var n = values.len - 1;
            while (n > 0) : (n -= 1) {
                for (0..n) |i| v[i] = v[i] + (v[i + 1] - v[i]) * t;
            }
            if ((v[0] < 0) == negative) a = t else b = t;
        }
        try roots.append(allocator, from + (to - from) * (a + b) / 2);
    } else if (changes != 0 or zeros != 0) {
        var v: [10]f64 = undefined;
        var e: [10]f64 = undefined;
        @memcpy(v[0..values.len], values);
        @memcpy(e[0..bounds.len], bounds);
        var left: [10]f64 = undefined;
        var right: [10]f64 = undefined;
        var le: [10]f64 = undefined;
        var re: [10]f64 = undefined;
        var n = values.len;
        while (n > 0) : (n -= 1) {
            const j = values.len - n;
            left[j] = v[0];
            right[n - 1] = v[n - 1];
            le[j] = e[0];
            re[n - 1] = e[n - 1];
            for (0..n - 1) |i| {
                v[i] = (v[i] + v[i + 1]) / 2;
                e[i] = (e[i] + e[i + 1]) / 2 + MACHINE_EPSILON * @abs(v[i]);
            }
        }
        const middle = (from + to) / 2;
        try bernsteinSolve(allocator, left[0..values.len], le[0..values.len], roots, width, from, middle);
        try bernsteinSolve(allocator, right[0..values.len], re[0..values.len], roots, width, middle, to);
    }
}

const abscissas = [_][]const f64{
    &.{0.5773502691896257},
    &.{ 0, 0.7745966692414834 },
    &.{ 0.33998104358485626, 0.8611363115940526 },
    &.{ 0, 0.5384693101056831, 0.906179845938664 },
    &.{ 0.2386191860831969, 0.6612093864662645, 0.932469514203152 },
    &.{ 0, 0.4058451513773972, 0.7415311855993945, 0.9491079123427585 },
    &.{ 0.1834346424956498, 0.525532409916329, 0.7966664774136267, 0.9602898564975363 },
    &.{ 0, 0.3242534234038089, 0.6133714327005904, 0.8360311073266358, 0.9681602395076261 },
    &.{ 0.14887433898163122, 0.4333953941292472, 0.6794095682990244, 0.8650633666889845, 0.9739065285171717 },
    &.{ 0, 0.26954315595234496, 0.5190961292068118, 0.7301520055740494, 0.8870625997680953, 0.978228658146057 },
    &.{ 0.1252334085114689, 0.3678314989981802, 0.5873179542866175, 0.7699026741943047, 0.9041172563704749, 0.9815606342467192 },
    &.{ 0, 0.2304583159551348, 0.44849275103644687, 0.6423493394403402, 0.8015780907333099, 0.9175983992229779, 0.9841830547185881 },
    &.{ 0.10805494870734367, 0.31911236892788974, 0.5152486363581541, 0.6872929048116855, 0.827201315069765, 0.9284348836635735, 0.9862838086968123 },
    &.{ 0, 0.20119409399743451, 0.3941513470775634, 0.5709721726085388, 0.7244177313601701, 0.8482065834104272, 0.937273392400706, 0.9879925180204854 },
    &.{ 0.09501250983763744, 0.2816035507792589, 0.45801677765722737, 0.6178762444026438, 0.755404408355003, 0.8656312023878318, 0.9445750230732326, 0.9894009349916499 },
};
const weights = [_][]const f64{
    &.{1},
    &.{ 0.8888888888888888, 0.5555555555555556 },
    &.{ 0.6521451548625461, 0.34785484513745385 },
    &.{ 0.5688888888888889, 0.47862867049936647, 0.23692688505618908 },
    &.{ 0.46791393457269104, 0.3607615730481386, 0.17132449237917036 },
    &.{ 0.4179591836734694, 0.3818300505051189, 0.27970539148927664, 0.1294849661688697 },
    &.{ 0.362683783378362, 0.31370664587788727, 0.22238103445337448, 0.10122853629037626 },
    &.{ 0.3302393550012598, 0.31234707704000286, 0.26061069640293544, 0.1806481606948574, 0.08127438836157441 },
    &.{ 0.29552422471475287, 0.26926671930999635, 0.21908636251598204, 0.1494513491505806, 0.06667134430868814 },
    &.{ 0.2729250867779006, 0.26280454451024665, 0.23319376459199048, 0.18629021092773426, 0.1255803694649046, 0.05566856711617366 },
    &.{ 0.24914704581340277, 0.2334925365383548, 0.20316742672306592, 0.16007832854334622, 0.10693932599531843, 0.04717533638651183 },
    &.{ 0.2325515532308739, 0.22628318026289723, 0.2078160475368885, 0.17814598076194574, 0.13887351021978725, 0.09212149983772845, 0.04048400476531588 },
    &.{ 0.2152638534631578, 0.2051984637212956, 0.18553839747793782, 0.15720316715819355, 0.12151857068790319, 0.08015808715976021, 0.03511946033175186 },
    &.{ 0.2025782419255613, 0.19843148532711158, 0.1861610000155622, 0.16626920581699392, 0.13957067792615432, 0.10715922046717194, 0.07036604748810812, 0.03075324199611727 },
    &.{ 0.1894506104550685, 0.18260341504492358, 0.16915651939500254, 0.14959598881657674, 0.12462897125553388, 0.09515851168249279, 0.062253523938647894, 0.027152459411754096 },
};
