//! Color channels computed at a point, or enclosed across a domain.
//!
//! A composite of paints is a sum of products of their channels. Computed
//! with `Real`, it is the color at one point. Computed with `Enclosure`, it
//! encloses the color across the unit square of two parameters, or the unit
//! interval of the first, in affine arithmetic (Stolfi and de Figueiredo,
//! Self-Validated Numerical Methods and Applications, 1997) around a
//! polynomial in tensor-product Bernstein form: the polynomial, plus
//! unknowns in [-1, 1] with constant coefficients, plus an interval for the
//! rest. An unknown stands for one function across the domain, so where it
//! enters a composite twice the two terms cancel as they should; intervals
//! would count both. Sums and products of enclosures enclose the sums and
//! products of what they enclose.
//!
//! An enclosure bounds how far what it encloses strays from interpolating
//! its values at the corners: by how far the polynomial's coefficients lie
//! from those of that interpolation, which are its values at the points
//! (i / m, j / n) for degrees m and n, since the Bernstein polynomials sum to
//! one; plus what the rest ranges over, twice each unknown's coefficient and
//! the width of the interval.
const std = @import("std");

/// The highest degree in each parameter.
pub const max_degree = 6;
/// How many unknowns an enclosure tracks.
pub const max_unknowns = 16;

/// A color whose channels are of type T: Real or Enclosure.
pub fn Rgba(comptime T: type) type {
    return struct { r: T, g: T, b: T, a: T };
}

/// The channels of a color, as constants.
pub fn constants(comptime T: type, color: anytype) Rgba(T) {
    return .{ .r = .constant(color.r), .g = .constant(color.g), .b = .constant(color.b), .a = .constant(color.a) };
}

/// A channel at a point.
pub const Real = struct {
    value: f64,

    pub fn constant(c: f64) Real {
        return .{ .value = c };
    }
    pub fn add(a: Real, b: Real) Real {
        return .{ .value = a.value + b.value };
    }
    pub fn sub(a: Real, b: Real) Real {
        return .{ .value = a.value - b.value };
    }
    pub fn mul(a: Real, b: Real) Real {
        return .{ .value = a.value * b.value };
    }
    pub fn scale(a: Real, k: f64) Real {
        return .{ .value = a.value * k };
    }
};

/// A channel across the domain: the sum of b[i][j] B_i(u) B_j(v) over
/// i <= degree[0] and j <= degree[1], with B the Bernstein polynomials of
/// those degrees, plus the sum of unknowns[k] times unknown k, plus
/// something in [low, high].
pub const Enclosure = struct {
    degree: [2]usize = .{ 0, 0 },
    b: [max_degree + 1][max_degree + 1]f64 = @splat(@splat(0)),
    unknowns: [max_unknowns]f64 = @splat(0),
    low: f64 = 0,
    high: f64 = 0,

    pub fn constant(c: f64) Enclosure {
        var result: Enclosure = .{};
        result.b[0][0] = c;
        return result;
    }

    /// Bilinear, with `corners` at (u, v) = (0, 0), (0, 1), (1, 1), (1, 0).
    pub fn bilinear(corners: [4]f64) Enclosure {
        var result: Enclosure = .{ .degree = .{ 1, 1 } };
        result.b[0][0] = corners[0];
        result.b[0][1] = corners[1];
        result.b[1][1] = corners[2];
        result.b[1][0] = corners[3];
        return result;
    }

    /// Linear in the first parameter, from `start` to `end`.
    pub fn linear(start: f64, end: f64) Enclosure {
        var result: Enclosure = .{ .degree = .{ 1, 0 } };
        result.b[0][0] = start;
        result.b[1][0] = end;
        return result;
    }

    /// What it encloses plus a function across the domain that ranges over
    /// [low, high]: unknown `index`, which must stand for no other.
    pub fn uncertain(self: Enclosure, index: usize, low: f64, high: f64) Enclosure {
        var result = self;
        const middle = (low + high) / 2;
        for (&result.b) |*row| for (row) |*c| {
            c.* += middle;
        };
        result.unknowns[index] += (high - low) / 2;
        return result;
    }

    pub fn add(a: Enclosure, b: Enclosure) Enclosure {
        return sum(a, b);
    }

    pub fn sub(a: Enclosure, b: Enclosure) Enclosure {
        return sum(a, b.scale(-1));
    }

    pub fn scale(a: Enclosure, k: f64) Enclosure {
        var result = a;
        for (&result.b) |*row| for (row) |*c| {
            c.* *= k;
        };
        for (&result.unknowns) |*c| c.* *= k;
        result.low = @min(a.low * k, a.high * k);
        result.high = @max(a.low * k, a.high * k);
        return result;
    }

    /// The degree of a product must stay within `max_degree`. With p and q
    /// the polynomials, s and t the unknowns' terms and i and j the
    /// intervals, (p + s + i)(q + t + j) is pq, plus p t + s q taken at the
    /// middles of p and q, plus intervals for p t + s q off those middles,
    /// for s t, and for the products with i and j.
    pub fn mul(a: Enclosure, b: Enclosure) Enclosure {
        var result = product(a, b);
        const p = a.hull();
        const q = b.hull();
        const middles = [2]f64{ (p[0] + p[1]) / 2, (q[0] + q[1]) / 2 };
        const radii = [2]f64{ (p[1] - p[0]) / 2, (q[1] - q[0]) / 2 };
        var spreads: [2]f64 = .{ 0, 0 };
        for (a.unknowns, b.unknowns, &result.unknowns) |s, t, *out| {
            out.* = middles[0] * t + middles[1] * s;
            spreads[0] += @abs(s);
            spreads[1] += @abs(t);
        }
        const off = radii[0] * spreads[1] + radii[1] * spreads[0] + spreads[0] * spreads[1];
        const terms = [_][2]f64{
            .{ -off, off },
            times(.{ p[0] - spreads[0], p[1] + spreads[0] }, .{ b.low, b.high }),
            times(.{ a.low, a.high }, .{ q[0] - spreads[1], q[1] + spreads[1] }),
            times(.{ a.low, a.high }, .{ b.low, b.high }),
        };
        for (terms) |term| {
            result.low += term[0];
            result.high += term[1];
        }
        return result;
    }

    /// How far what it encloses strays from the bilinear interpolation of
    /// its values at the corners of the domain.
    pub fn interpolationError(self: Enclosure) f64 {
        const m = self.degree[0];
        const n = self.degree[1];
        const corners = [4]f64{ self.b[0][0], self.b[0][n], self.b[m][n], self.b[m][0] };
        var largest: f64 = 0;
        for (0..m + 1) |i| for (0..n + 1) |j| {
            const u = if (m == 0) 0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(m));
            const v = if (n == 0) 0 else @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n));
            const interpolated = (1 - u) * (1 - v) * corners[0] + (1 - u) * v * corners[1] + u * v * corners[2] + u * (1 - v) * corners[3];
            largest = @max(largest, @abs(self.b[i][j] - interpolated));
        };
        var rest = self.high - self.low;
        for (self.unknowns) |c| rest += 2 * @abs(c);
        return largest + rest;
    }

    /// A bound on the polynomial's second derivative in the first parameter.
    pub fn curvature(self: Enclosure) f64 {
        const m = self.degree[0];
        if (m < 2) return 0;
        var largest: f64 = 0;
        for (0..self.degree[1] + 1) |j| for (0..m - 1) |i| {
            largest = @max(largest, @abs(self.b[i + 2][j] - 2 * self.b[i + 1][j] + self.b[i][j]));
        };
        return @as(f64, @floatFromInt(m * (m - 1))) * largest;
    }

    /// The least and greatest of the polynomial's coefficients, between
    /// which it lies.
    fn hull(self: Enclosure) [2]f64 {
        var result: [2]f64 = .{ std.math.inf(f64), -std.math.inf(f64) };
        for (0..self.degree[0] + 1) |i| for (0..self.degree[1] + 1) |j| {
            result[0] = @min(result[0], self.b[i][j]);
            result[1] = @max(result[1], self.b[i][j]);
        };
        return result;
    }

    /// Same degree in each parameter, the polynomials added, and the
    /// unknowns and the intervals too.
    fn sum(a: Enclosure, b: Enclosure) Enclosure {
        const degree: [2]usize = .{ @max(a.degree[0], b.degree[0]), @max(a.degree[1], b.degree[1]) };
        var result = a.elevated(degree);
        const other = b.elevated(degree);
        for (&result.b, other.b) |*row, more| for (row, more) |*c, d| {
            c.* += d;
        };
        for (&result.unknowns, other.unknowns) |*c, d| c.* += d;
        result.low += other.low;
        result.high += other.high;
        return result;
    }

    /// The same, at higher degrees: times one at the difference in degree,
    /// whose coefficients are all one.
    fn elevated(self: Enclosure, degree: [2]usize) Enclosure {
        if (std.mem.eql(usize, &self.degree, &degree)) return self;
        var one: Enclosure = .{ .degree = .{ degree[0] - self.degree[0], degree[1] - self.degree[1] } };
        for (0..one.degree[0] + 1) |i| for (0..one.degree[1] + 1) |j| {
            one.b[i][j] = 1;
        };
        var result = product(self, one);
        result.unknowns = self.unknowns;
        result.low = self.low;
        result.high = self.high;
        return result;
    }

    /// The product of the polynomials alone.
    fn product(a: Enclosure, b: Enclosure) Enclosure {
        const degree: [2]usize = .{ a.degree[0] + b.degree[0], a.degree[1] + b.degree[1] };
        std.debug.assert(degree[0] <= max_degree and degree[1] <= max_degree);
        var result: Enclosure = .{ .degree = degree };
        for (0..a.degree[0] + 1) |ai| for (0..a.degree[1] + 1) |aj| for (0..b.degree[0] + 1) |bi| for (0..b.degree[1] + 1) |bj| {
            const in_u = binomial[a.degree[0]][ai] * binomial[b.degree[0]][bi] / binomial[degree[0]][ai + bi];
            const in_v = binomial[a.degree[1]][aj] * binomial[b.degree[1]][bj] / binomial[degree[1]][aj + bj];
            result.b[ai + bi][aj + bj] += a.b[ai][aj] * b.b[bi][bj] * in_u * in_v;
        };
        return result;
    }
};

fn times(a: [2]f64, b: [2]f64) [2]f64 {
    const products = [4]f64{ a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1] };
    return .{ std.mem.min(f64, &products), std.mem.max(f64, &products) };
}

const binomial = table: {
    var rows: [2 * max_degree + 1][2 * max_degree + 1]f64 = @splat(@splat(0));
    for (0..rows.len) |n| {
        rows[n][0] = 1;
        for (1..n + 1) |k| rows[n][k] = rows[n - 1][k - 1] + (if (k < n) rows[n - 1][k] else 0);
    }
    break :table rows;
};

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
    for (e.unknowns, unknowns) |c, x| total += c * x;
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
