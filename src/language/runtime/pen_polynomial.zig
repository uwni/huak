//! Compile the ordinary list expressions produced by std.pen_motion into
//! Bernstein coefficients once, while constructing the pen.
const std = @import("std");
const types = @import("../types.zig");
const Motion = @import("../../drawing/pen/Motion.zig");

const Polynomial = @This();
coeff: [Motion.max_degree + 1]f64 = @splat(0),
degree: usize = 0,
dimension: types.units.Dimension = .scalar,
// Uniform absolute forward error in Bernstein ordinates. Positive product
// weights sum to one. Keep the bound even when large operands cancel.
uncertainty: f64 = 0,

fn magnitude(self: *const Polynomial) f64 {
    var maximum: f64 = 0;
    for (self.coeff[0 .. self.degree + 1]) |v| maximum = @max(maximum, @abs(v));
    return maximum;
}

fn rounding(scale: f64, operations: usize) f64 {
    return 4 * @as(f64, @floatFromInt(operations)) * (std.math.floatEps(f64) * scale + std.math.floatMin(f64));
}

fn binomial(n: usize, k: usize) f64 {
    var v: usize = 1;
    for (0..@min(k, n - k)) |i| v = v * (n - i) / (i + 1);
    return @floatFromInt(v);
}

fn elevate(self: *Polynomial, degree: usize) void {
    while (self.degree < degree) {
        self.uncertainty += rounding(self.magnitude() + self.uncertainty, 5);
        self.degree += 1;
        var k = self.degree;
        while (k > 0) : (k -= 1) {
            const u = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(self.degree));
            self.coeff[k] = u * self.coeff[k - 1] + (1 - u) * self.coeff[k];
        }
    }
}

pub fn read(node: types.Value, depth: usize, visits: *usize) anyerror!Polynomial {
    if (depth > 32 or visits.* >= 65536) return error.MotionExpressionLimit;
    visits.* += 1;
    var p: Polynomial = .{};
    if (node != .list) {
        const q = try (try types.asQuantity(node)).checked();
        p.coeff[0] = q.value;
        p.dimension = q.dimension;
        return p;
    }
    const items = node.list.items();
    if (items.len == 0 or items[0] != .string) return error.InvalidMotion;
    const name = items[0].string;
    if (std.mem.eql(u8, name, "progress") and items.len == 1) {
        p.degree = 1;
        p.coeff[1] = 1;
        return p;
    }
    if (items.len != 3 or name.len != 1) return error.InvalidMotion;
    p = try read(items[1], depth + 1, visits);
    var q = try read(items[2], depth + 1, visits);
    switch (name[0]) {
        '+', '-' => {
            if (!p.dimension.eql(q.dimension)) return error.DimensionMismatch;
            const degree = @max(p.degree, q.degree);
            p.elevate(degree);
            q.elevate(degree);
            p.uncertainty += q.uncertainty + rounding(p.magnitude() + q.magnitude() + p.uncertainty + q.uncertainty, 2);
            for (0..degree + 1) |i| p.coeff[i] += if (name[0] == '+') q.coeff[i] else -q.coeff[i];
        },
        '*' => {
            const degree = p.degree + q.degree;
            if (degree > Motion.max_degree) return error.MotionExpressionLimit;
            var product: Polynomial = .{ .degree = degree, .dimension = try p.dimension.combine(q.dimension, false) };
            const m = p.magnitude();
            const n = q.magnitude();
            product.uncertainty = (m + p.uncertainty) * q.uncertainty + n * p.uncertainty +
                rounding((m + p.uncertainty) * (n + q.uncertainty), 5 * (degree + 1));
            for (0..p.degree + 1) |i| for (0..q.degree + 1) |j| {
                const weight = binomial(p.degree, i) * binomial(q.degree, j) / binomial(degree, i + j);
                product.coeff[i + j] += weight * p.coeff[i] * q.coeff[j];
            };
            p = product;
        },
        '/' => {
            if (q.degree != 0) return error.MotionNeedsPolynomial;
            if (q.coeff[0] == 0) return error.DivisionByZero;
            const lower = @abs(q.coeff[0]) - q.uncertainty;
            if (lower <= 0) return error.PrecisionRange;
            const max_quotient = (p.magnitude() + p.uncertainty) / lower;
            p.uncertainty = (p.uncertainty + max_quotient * q.uncertainty) / lower + rounding(max_quotient, 3);
            p.dimension = try p.dimension.combine(q.dimension, true);
            for (p.coeff[0 .. p.degree + 1]) |*c| c.* /= q.coeff[0];
        },
        else => return error.InvalidMotion,
    }
    if (!std.math.isFinite(p.uncertainty)) return error.PrecisionRange;
    for (p.coeff[0 .. p.degree + 1]) |c| if (!std.math.isFinite(c)) return error.NonFinite;
    return p;
}

pub fn append(self: Polynomial, kind: Motion.Kind, a: std.mem.Allocator, keys: *std.ArrayList(Motion.Key)) !Motion.Track {
    if (!self.dimension.eql(.scalar) and !(kind == .rotate and self.dimension.eql(.rotation))) return error.DimensionMismatch;
    var p = self;
    p.elevate(1);
    const first = keys.items.len;
    for (p.coeff[0 .. p.degree + 1], 0..) |v, i| {
        try keys.append(a, .{ .t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(p.degree)), .value = v });
    }
    return .{ .kind = kind, .first = first, .len = keys.items.len - first, .polynomial = true, .uncertainty = p.uncertainty };
}

test "ill-conditioned symbolic arithmetic retains its uncertainty" {
    const t = types.listView(&.{.{ .string = "progress" }});
    const big: types.Value = .{ .number = 1e30 };
    const sum = types.listView(&.{ .{ .string = "+" }, big, t });
    const difference = types.listView(&.{ .{ .string = "-" }, sum, big });
    var visits: usize = 0;
    const p = try read(difference, 0, &visits);
    try std.testing.expect(p.uncertainty >= 1);
    const reciprocal = types.listView(&.{ .{ .string = "/" }, big, t });
    try std.testing.expectError(error.MotionNeedsPolynomial, read(reciprocal, 0, &visits));
}
