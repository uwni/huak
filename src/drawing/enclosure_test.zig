//! Tests of affine-arithmetic Bernstein enclosures.
const std = @import("std");
const enclosure = @import("enclosure.zig");
const Enclosure = enclosure.Enclosure;
const max_unknowns = enclosure.max_unknowns;
const binomial = enclosure.binomial;
const testing = std.testing;

/// The polynomial and the unknowns' terms at (u, v), with each unknown at
/// the value given.
fn at(e: Enclosure, u: f64, v: f64, unknowns: [max_unknowns]f64) f64 {
    var total: f64 = 0;
    for (0..e.degree[0] + 1) |i| for (0..e.degree[1] + 1) |j| {
        const bu = binomial[e.degree[0]][i] * std.math.pow(f64, u, @floatFromInt(i)) * std.math.pow(f64, 1 - u, @floatFromInt(e.degree[0] - i));
        const bv = binomial[e.degree[1]][j] * std.math.pow(f64, v, @floatFromInt(j)) * std.math.pow(f64, 1 - v, @floatFromInt(e.degree[1] - j));
        total += e.b[i][j] * bu * bv;
    };
    var mask = e.unknown_mask;
    while (mask != 0) {
        const k: usize = @ctz(mask);
        mask &= mask - 1;
        total += e.unknowns[k] * unknowns[k];
    }
    return total;
}

const none: [max_unknowns]f64 = @splat(0);

test "products and sums of enclosures are the products and sums of their polynomials" {
    const p = Enclosure.bilinear(.{ 0.2, 0.9, -0.4, 0.5 });
    const q = Enclosure.bilinear(.{ 1, 0.3, 0.7, -0.6 });
    const r = Enclosure.linear(0.25, 2);
    const composite = p.mul(q).add(r.mul(p)).sub(Enclosure.constant(0.5)).scale(-3);
    for ([_][2]f64{ .{ 0, 0 }, .{ 0.3, 0.8 }, .{ 1, 0.5 }, .{ 0.6, 0.1 } }) |uv| {
        const u, const v = uv;
        const bp = (1 - u) * (1 - v) * 0.2 + (1 - u) * v * 0.9 + u * v * -0.4 + u * (1 - v) * 0.5;
        const bq = (1 - u) * (1 - v) * 1 + (1 - u) * v * 0.3 + u * v * 0.7 + u * (1 - v) * -0.6;
        const br = 0.25 + 1.75 * u;
        try testing.expectApproxEqAbs(-3 * (bp * bq + br * bp - 0.5), at(composite, u, v, none), 1e-12);
    }
    try testing.expectEqual(@as(f64, 0), composite.high - composite.low);
}

test "a product's rest holds every product of what the factors enclose" {
    const p = Enclosure.bilinear(.{ 0.1, 0.4, 0.9, 0.3 }).uncertain(0, -0.05, 0.02);
    var q = Enclosure.linear(-0.5, 0.5).uncertain(1, 0, 0.1);
    q.low = -0.01;
    q.high = 0.03;
    const pq = p.mul(q);
    var random: std.Random.DefaultPrng = .init(3);
    for (0..1000) |_| {
        const u = random.random().float(f64);
        const v = random.random().float(f64);
        var unknowns = none;
        unknowns[0] = 2 * random.random().float(f64) - 1;
        unknowns[1] = 2 * random.random().float(f64) - 1;
        const x = at(p, u, v, unknowns);
        const y = at(q, u, v, unknowns) + (-0.01 + 0.04 * random.random().float(f64));
        const rest = x * y - at(pq, u, v, unknowns);
        try testing.expect(rest >= pq.low - 1e-12 and rest <= pq.high + 1e-12);
    }
}

test "an unknown that enters twice cancels" {
    // An opacity a with an uncertain kink: a + (1 - a) is one, exactly.
    const a = Enclosure.bilinear(.{ 0.2, 0.5, 0.9, 0.3 }).uncertain(3, 0, 0.01);
    const whole = a.add(Enclosure.constant(1).sub(a).mul(Enclosure.bilinear(.{ 1, 1, 1, 1 })));
    try testing.expectApproxEqAbs(@as(f64, 0), whole.interpolationError(), 1e-12);
    // Translucent white over b: a + (1 - a) b, whose rest is (1 - b) times
    // a's, not (1 + b) times as intervals would have it.
    const b = Enclosure.constant(0.6);
    const lit = a.add(Enclosure.constant(1).sub(a).mul(b));
    try testing.expectApproxEqAbs(@as(f64, 2 * 0.4 * 0.005), lit.interpolationError(), 1e-12);
}

test "the interpolation error bounds the distance from bilinear interpolation" {
    // u^2 v is 1/4 from its bilinear interpolation u v at u = 1/2, v = 1.
    // At degree 3 in u its coefficients are 0, 0, 1/3, 1 where v = 1, at
    // most 1/3 from u v's 0, 1/3, 2/3, 1.
    var square = Enclosure.linear(0, 1).mul(Enclosure.linear(0, 1)).mul(Enclosure.bilinear(.{ 0, 1, 1, 0 }));
    try testing.expectEqual(@as(f64, 0), Enclosure.bilinear(.{ 0.3, 0.1, 0.8, 0.2 }).interpolationError());
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), square.interpolationError(), 1e-12);
    square = square.uncertain(5, -0.1, 0.2);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0 + 0.3), square.interpolationError(), 1e-12);
    // 3 u^2 - 2 u bends by 6.
    const bent = Enclosure.linear(0, 1).mul(Enclosure.linear(0, 3)).sub(Enclosure.linear(0, 2));
    try testing.expectApproxEqAbs(@as(f64, 6), bent.curvature(), 1e-12);
}
