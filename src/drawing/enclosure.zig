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
    var result: Rgba(T) = undefined;
    constantsInto(T, color, &result);
    return result;
}

/// Writes the channels of a color as constants into `out`.
pub fn constantsInto(comptime T: type, color: anytype, out: *Rgba(T)) void {
    out.r.setConstant(color.r);
    out.g.setConstant(color.g);
    out.b.setConstant(color.b);
    out.a.setConstant(color.a);
}

/// A channel at a point.
pub const Real = struct {
    value: f64,

    pub fn constant(c: f64) Real {
        return .{ .value = c };
    }
    pub fn setConstant(self: *Real, c: f64) void {
        self.value = c;
    }
    pub fn add(a: Real, b: Real) Real {
        return .{ .value = a.value + b.value };
    }
    pub fn addInto(a: *const Real, b: *const Real, out: *Real) void {
        out.value = a.value + b.value;
    }
    pub fn sub(a: Real, b: Real) Real {
        return .{ .value = a.value - b.value };
    }
    pub fn subInto(a: *const Real, b: *const Real, out: *Real) void {
        out.value = a.value - b.value;
    }
    pub fn mul(a: Real, b: Real) Real {
        return .{ .value = a.value * b.value };
    }
    pub fn mulInto(a: *const Real, b: *const Real, out: *Real) void {
        out.value = a.value * b.value;
    }
    pub fn scale(a: Real, k: f64) Real {
        return .{ .value = a.value * k };
    }
    pub fn scaleInto(a: *const Real, k: f64, out: *Real) void {
        out.value = a.value * k;
    }
};

/// A channel across the domain: the sum of b[i][j] B_i(u) B_j(v) over
/// i <= degree[0] and j <= degree[1], with B the Bernstein polynomials of
/// those degrees, plus the sum of unknowns[k] times unknown k (for bits
/// set in `unknown_mask`), plus something in [low, high]. Entries outside
/// `degree` or unset in `unknown_mask` are undefined and never read.
pub const Enclosure = struct {
    degree: [2]usize = .{ 0, 0 },
    unknown_mask: u16 = 0,
    low: f64 = 0,
    high: f64 = 0,
    b: [max_degree + 1][max_degree + 1]f64 = undefined,
    unknowns: [max_unknowns]f64 = undefined,

    pub fn setConstant(self: *Enclosure, c: f64) void {
        self.degree = .{ 0, 0 };
        self.unknown_mask = 0;
        self.low = 0;
        self.high = 0;
        self.b[0][0] = c;
    }

    pub fn constant(c: f64) Enclosure {
        var result: Enclosure = undefined;
        result.setConstant(c);
        return result;
    }

    /// Bilinear, with `corners` at (u, v) = (0, 0), (0, 1), (1, 1), (1, 0).
    pub fn setBilinear(self: *Enclosure, corners: [4]f64) void {
        self.degree = .{ 1, 1 };
        self.unknown_mask = 0;
        self.low = 0;
        self.high = 0;
        self.b[0][0] = corners[0];
        self.b[0][1] = corners[1];
        self.b[1][1] = corners[2];
        self.b[1][0] = corners[3];
    }

    pub fn bilinear(corners: [4]f64) Enclosure {
        var result: Enclosure = undefined;
        result.setBilinear(corners);
        return result;
    }

    /// Linear in the first parameter, from `start` to `end`.
    pub fn setLinear(self: *Enclosure, start: f64, end: f64) void {
        self.degree = .{ 1, 0 };
        self.unknown_mask = 0;
        self.low = 0;
        self.high = 0;
        self.b[0][0] = start;
        self.b[1][0] = end;
    }

    pub fn linear(start: f64, end: f64) Enclosure {
        var result: Enclosure = undefined;
        result.setLinear(start, end);
        return result;
    }

    /// Adds a function across the domain that ranges over [low, high]:
    /// unknown `index`, which must stand for no other.
    pub fn addUncertainty(self: *Enclosure, index: usize, low: f64, high: f64) void {
        const middle = (low + high) / 2;
        for (0..self.degree[0] + 1) |i| for (0..self.degree[1] + 1) |j| {
            self.b[i][j] += middle;
        };
        const flag: u16 = @as(u16, 1) << @intCast(index);
        const radius = (high - low) / 2;
        if ((self.unknown_mask & flag) != 0) {
            self.unknowns[index] += radius;
        } else {
            self.unknown_mask |= flag;
            self.unknowns[index] = radius;
        }
    }

    /// What it encloses plus a function across the domain that ranges over
    /// [low, high]: unknown `index`, which must stand for no other.
    pub fn uncertain(self: Enclosure, index: usize, low: f64, high: f64) Enclosure {
        var result = self;
        result.addUncertainty(index, low, high);
        return result;
    }

    pub fn add(a: Enclosure, b: Enclosure) Enclosure {
        var result: Enclosure = undefined;
        a.addInto(&b, &result);
        return result;
    }

    pub fn addInto(a: *const Enclosure, b: *const Enclosure, out: *Enclosure) void {
        sumInto(a, b, false, out);
    }

    pub fn sub(a: Enclosure, b: Enclosure) Enclosure {
        var result: Enclosure = undefined;
        a.subInto(&b, &result);
        return result;
    }

    pub fn subInto(a: *const Enclosure, b: *const Enclosure, out: *Enclosure) void {
        sumInto(a, b, true, out);
    }

    pub fn scale(a: Enclosure, k: f64) Enclosure {
        var result: Enclosure = undefined;
        a.scaleInto(k, &result);
        return result;
    }

    pub fn scaleInto(a: *const Enclosure, k: f64, out: *Enclosure) void {
        out.degree = a.degree;
        out.unknown_mask = a.unknown_mask;
        for (0..a.degree[0] + 1) |i| for (0..a.degree[1] + 1) |j| {
            out.b[i][j] = a.b[i][j] * k;
        };
        var mask = a.unknown_mask;
        while (mask != 0) {
            const bit: usize = @ctz(mask);
            mask &= mask - 1;
            out.unknowns[bit] = a.unknowns[bit] * k;
        }
        const ak0 = a.low * k;
        const ak1 = a.high * k;
        out.low = @min(ak0, ak1);
        out.high = @max(ak0, ak1);
    }

    /// The degree of a product must stay within `max_degree`. With p and q
    /// the polynomials, s and t the unknowns' terms and i and j the
    /// intervals, (p + s + i)(q + t + j) is pq, plus p t + s q taken at the
    /// middles of p and q, plus intervals for p t + s q off those middles,
    /// for s t, and for the products with i and j.
    pub fn mul(a: Enclosure, b: Enclosure) Enclosure {
        var result: Enclosure = undefined;
        a.mulInto(&b, &result);
        return result;
    }

    pub fn mulInto(a: *const Enclosure, b: *const Enclosure, out: *Enclosure) void {
        std.debug.assert(out != a and out != b);
        productInto(a, b, out);
        const mask = a.unknown_mask | b.unknown_mask;
        const has_interval = a.low != 0 or a.high != 0 or b.low != 0 or b.high != 0;
        if (mask == 0 and !has_interval) {
            out.unknown_mask = 0;
            out.low = 0;
            out.high = 0;
            return;
        }
        const p = a.hull();
        const q = b.hull();
        const middles = [2]f64{ (p[0] + p[1]) / 2, (q[0] + q[1]) / 2 };
        const radii = [2]f64{ (p[1] - p[0]) / 2, (q[1] - q[0]) / 2 };
        var spreads: [2]f64 = .{ 0, 0 };
        out.unknown_mask = mask;
        var bits = mask;
        while (bits != 0) {
            const k: usize = @ctz(bits);
            const flag: u16 = @as(u16, 1) << @intCast(k);
            bits &= bits - 1;
            const s = if ((a.unknown_mask & flag) != 0) a.unknowns[k] else 0;
            const t = if ((b.unknown_mask & flag) != 0) b.unknowns[k] else 0;
            out.unknowns[k] = middles[0] * t + middles[1] * s;
            spreads[0] += @abs(s);
            spreads[1] += @abs(t);
        }
        const off = radii[0] * spreads[1] + radii[1] * spreads[0] + spreads[0] * spreads[1];
        var low = -off;
        var high = off;
        if (b.low != 0 or b.high != 0) {
            const term = times(.{ p[0] - spreads[0], p[1] + spreads[0] }, .{ b.low, b.high });
            low += term[0];
            high += term[1];
        }
        if (a.low != 0 or a.high != 0) {
            const term = times(.{ a.low, a.high }, .{ q[0] - spreads[1], q[1] + spreads[1] });
            low += term[0];
            high += term[1];
        }
        if ((a.low != 0 or a.high != 0) and (b.low != 0 or b.high != 0)) {
            const term = times(.{ a.low, a.high }, .{ b.low, b.high });
            low += term[0];
            high += term[1];
        }
        out.low = low;
        out.high = high;
    }

    /// How far what it encloses strays from the bilinear interpolation of
    /// its values at the corners of the domain.
    pub fn interpolationError(self: *const Enclosure) f64 {
        const m = self.degree[0];
        const n = self.degree[1];
        var largest: f64 = 0;
        if (m > 1 or n > 1) {
            const corners = [4]f64{ self.b[0][0], self.b[0][n], self.b[m][n], self.b[m][0] };
            const inv_m: f64 = if (m == 0) 0 else 1.0 / @as(f64, @floatFromInt(m));
            const inv_n: f64 = if (n == 0) 0 else 1.0 / @as(f64, @floatFromInt(n));
            for (0..m + 1) |i| {
                const u = @as(f64, @floatFromInt(i)) * inv_m;
                for (0..n + 1) |j| {
                    const v = @as(f64, @floatFromInt(j)) * inv_n;
                    const interpolated = (1 - u) * (1 - v) * corners[0] + (1 - u) * v * corners[1] + u * v * corners[2] + u * (1 - v) * corners[3];
                    largest = @max(largest, @abs(self.b[i][j] - interpolated));
                }
            }
        }
        var rest = self.high - self.low;
        var mask = self.unknown_mask;
        while (mask != 0) {
            const k: usize = @ctz(mask);
            mask &= mask - 1;
            rest += 2 * @abs(self.unknowns[k]);
        }
        return largest + rest;
    }

    /// A bound on the polynomial's second derivative in the first parameter.
    pub fn curvature(self: *const Enclosure) f64 {
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
    fn hull(self: *const Enclosure) [2]f64 {
        var result: [2]f64 = .{ std.math.inf(f64), -std.math.inf(f64) };
        for (0..self.degree[0] + 1) |i| for (0..self.degree[1] + 1) |j| {
            result[0] = @min(result[0], self.b[i][j]);
            result[1] = @max(result[1], self.b[i][j]);
        };
        return result;
    }

    /// Same degree in each parameter, the polynomials added (or subtracted
    /// when `negate_b`), and the unknowns and the intervals too.
    fn sumInto(a: *const Enclosure, b: *const Enclosure, comptime negate_b: bool, out: *Enclosure) void {
        if (a.degree[0] == b.degree[0] and a.degree[1] == b.degree[1]) {
            out.degree = a.degree;
            for (0..a.degree[0] + 1) |i| for (0..a.degree[1] + 1) |j| {
                out.b[i][j] = if (negate_b) a.b[i][j] - b.b[i][j] else a.b[i][j] + b.b[i][j];
            };
        } else if (a.degree[0] == 0 and a.degree[1] == 0) {
            const c = a.b[0][0];
            out.degree = b.degree;
            for (0..b.degree[0] + 1) |i| for (0..b.degree[1] + 1) |j| {
                out.b[i][j] = if (negate_b) c - b.b[i][j] else c + b.b[i][j];
            };
        } else if (b.degree[0] == 0 and b.degree[1] == 0) {
            const c = b.b[0][0];
            out.degree = a.degree;
            for (0..a.degree[0] + 1) |i| for (0..a.degree[1] + 1) |j| {
                out.b[i][j] = if (negate_b) a.b[i][j] - c else a.b[i][j] + c;
            };
        } else {
            const degree: [2]usize = .{ @max(a.degree[0], b.degree[0]), @max(a.degree[1], b.degree[1]) };
            var ea_buf: Enclosure = undefined;
            var eb_buf: Enclosure = undefined;
            const ea: *const Enclosure = if (a.degree[0] == degree[0] and a.degree[1] == degree[1]) a else blk: {
                elevatePoly(a, degree, &ea_buf);
                break :blk &ea_buf;
            };
            const eb: *const Enclosure = if (b.degree[0] == degree[0] and b.degree[1] == degree[1]) b else blk: {
                elevatePoly(b, degree, &eb_buf);
                break :blk &eb_buf;
            };
            out.degree = degree;
            for (0..degree[0] + 1) |i| for (0..degree[1] + 1) |j| {
                out.b[i][j] = if (negate_b) ea.b[i][j] - eb.b[i][j] else ea.b[i][j] + eb.b[i][j];
            };
        }
        const mask = a.unknown_mask | b.unknown_mask;
        out.unknown_mask = mask;
        var bits = mask;
        while (bits != 0) {
            const k: usize = @ctz(bits);
            const flag: u16 = @as(u16, 1) << @intCast(k);
            bits &= bits - 1;
            const av = if ((a.unknown_mask & flag) != 0) a.unknowns[k] else 0;
            const bv = if ((b.unknown_mask & flag) != 0) b.unknowns[k] else 0;
            out.unknowns[k] = if (negate_b) av - bv else av + bv;
        }
        if (negate_b) {
            out.low = a.low - b.high;
            out.high = a.high - b.low;
        } else {
            out.low = a.low + b.low;
            out.high = a.high + b.high;
        }
    }

    /// Polynomial-only elevation to higher degrees: times one at the
    /// difference in degree, whose coefficients are all one.
    fn elevatePoly(self: *const Enclosure, degree: [2]usize, out: *Enclosure) void {
        out.degree = degree;
        const dm = degree[0] - self.degree[0];
        const dn = degree[1] - self.degree[1];
        for (0..degree[0] + 1) |i| for (0..degree[1] + 1) |j| {
            out.b[i][j] = 0;
        };
        for (0..self.degree[0] + 1) |ai| for (0..dm + 1) |bi| {
            const in_u = binomial[self.degree[0]][ai] * binomial[dm][bi] / binomial[degree[0]][ai + bi];
            for (0..self.degree[1] + 1) |aj| {
                const base = self.b[ai][aj] * in_u;
                for (0..dn + 1) |bj| {
                    const in_v = binomial[self.degree[1]][aj] * binomial[dn][bj] / binomial[degree[1]][aj + bj];
                    out.b[ai + bi][aj + bj] += base * in_v;
                }
            }
        };
    }

    /// The product of the polynomials alone.
    fn productInto(a: *const Enclosure, b: *const Enclosure, out: *Enclosure) void {
        if (a.degree[0] == 0 and a.degree[1] == 0) {
            const c = a.b[0][0];
            out.degree = b.degree;
            for (0..b.degree[0] + 1) |i| for (0..b.degree[1] + 1) |j| {
                out.b[i][j] = c * b.b[i][j];
            };
            return;
        }
        if (b.degree[0] == 0 and b.degree[1] == 0) {
            const c = b.b[0][0];
            out.degree = a.degree;
            for (0..a.degree[0] + 1) |i| for (0..a.degree[1] + 1) |j| {
                out.b[i][j] = a.b[i][j] * c;
            };
            return;
        }
        const degree: [2]usize = .{ a.degree[0] + b.degree[0], a.degree[1] + b.degree[1] };
        std.debug.assert(degree[0] <= max_degree and degree[1] <= max_degree);
        out.degree = degree;
        for (0..degree[0] + 1) |i| for (0..degree[1] + 1) |j| {
            out.b[i][j] = 0;
        };
        for (0..a.degree[0] + 1) |ai| for (0..b.degree[0] + 1) |bi| {
            const in_u = binomial[a.degree[0]][ai] * binomial[b.degree[0]][bi] / binomial[degree[0]][ai + bi];
            for (0..a.degree[1] + 1) |aj| {
                const a_val = a.b[ai][aj] * in_u;
                for (0..b.degree[1] + 1) |bj| {
                    const in_v = binomial[a.degree[1]][aj] * binomial[b.degree[1]][bj] / binomial[degree[1]][aj + bj];
                    out.b[ai + bi][aj + bj] += a_val * b.b[bi][bj] * in_v;
                }
            }
        };
    }
};

fn times(a: [2]f64, b: [2]f64) [2]f64 {
    const products = [4]f64{ a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1] };
    return .{ std.mem.min(f64, &products), std.mem.max(f64, &products) };
}

pub const binomial = table: {
    var rows: [2 * max_degree + 1][2 * max_degree + 1]f64 = @splat(@splat(0));
    for (0..rows.len) |n| {
        rows[n][0] = 1;
        for (1..n + 1) |k| rows[n][k] = rows[n - 1][k - 1] + (if (k < n) rows[n - 1][k] else 0);
    }
    break :table rows;
};

test {
    _ = @import("enclosure_test.zig");
}
