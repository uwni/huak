// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
//! Implicit-form intersection: the fallback when clipping stops, by Bernstein implicitization with error bounds.
const std = @import("std");
const types = @import("../types.zig");
const geometry = @import("../../../geometry.zig");
const curve = @import("../curve.zig");
const numerical = @import("../numeric.zig");
const Cubic = geometry.Cubic;
const Point = types.Point;
const roundoff = numerical.MACHINE_EPSILON;
const intersections = @import("../intersections.zig");
const Builder = intersections.Builder;

pub fn addImplicitIntersections(self: *Builder, a: Cubic, b: Cubic, c1: usize, c2: usize, flip: bool, t_min: f64, t_max: f64, u_min: f64, u_max: f64) !bool {
    const x0 = b.p0.x;
    const y0 = b.p0.y;
    var size: f64 = 0;
    inline for ([_]struct { a: Point, b: Point }{
        .{ .a = a.p0, .b = b.p0 },
        .{ .a = a.p1, .b = b.p1 },
        .{ .a = a.p2, .b = b.p2 },
        .{ .a = a.p3, .b = b.p3 },
    }) |points| {
        size = @max(size, @abs(points.a.x - x0), @abs(points.a.y - y0), @abs(points.b.x - x0), @abs(points.b.y - y0));
    }
    if (size == 0) return false;
    const p = localPoints(a, x0, y0, size);
    const q = localPoints(b, x0, y0, size);
    const dx = b.p3.x - 3 * (b.p2.x - b.p1.x) - x0;
    const dy = b.p3.y - 3 * (b.p2.y - b.p1.y) - y0;
    const is_quadratic = 4.0 / 27.0 * @sqrt(dx * dx + dy * dy) <= self.epsilon;
    const polynomial = if (is_quadratic)
        quadraticImplicit(p, .{ q[0], quadraticHandle(q), q[3] })
    else
        cubicImplicit(p, q);
    var speed: f64 = 0;
    inline for ([_]struct { a: Point, b: Point }{
        .{ .a = a.p0, .b = a.p1 },
        .{ .a = a.p1, .b = a.p2 },
        .{ .a = a.p2, .b = a.p3 },
    }) |segment| {
        const x = segment.b.x - segment.a.x;
        const y = segment.b.y - segment.a.y;
        speed = @max(speed, 3 * @sqrt(x * x + y * y));
    }
    const all_zero = for (polynomial.coefficients[0..polynomial.len], polynomial.errors[0..polynomial.len]) |coefficient, err| {
        if (@abs(coefficient) > err) break false;
    } else true;
    if (all_zero) return false;
    self.roots.clearRetainingCapacity();
    const count = try numerical.solveBernstein(self.allocator, polynomial.coefficients[0..polynomial.len], polynomial.errors[0..polynomial.len], &self.roots, if (speed != 0) self.epsilon / speed else 1);
    for (self.roots.items[0..count]) |root| {
        if (curve.getTimeOf(&b, curve.getPoint(&a, root), self.epsilon)) |other| {
            const t = t_min + (t_max - t_min) * root;
            const u = u_min + (u_max - u_min) * other;
            try self.addLocation(if (flip) c2 else c1, if (flip) u else t, if (flip) c1 else c2, if (flip) t else u, false);
        }
    }
    return true;
}

const ErrorPoint = struct { x: f64, y: f64, ex: f64, ey: f64 };

const Polynomial = struct { coefficients: [10]f64 = undefined, errors: [10]f64 = undefined, len: usize };

fn localPoints(v: Cubic, x0: f64, y0: f64, size: f64) [4]ErrorPoint {
    var points: [4]ErrorPoint = undefined;
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }, 0..) |source, i| {
        const x = (source.x - x0) / size;
        const y = (source.y - y0) / size;
        points[i] = .{ .x = x, .y = y, .ex = 2 * roundoff * @abs(x), .ey = 2 * roundoff * @abs(y) };
    }
    return points;
}

fn productError(a: f64, ea: f64, b: f64, eb: f64) f64 {
    return @abs(a) * eb + @abs(b) * ea + ea * eb + roundoff * @abs(a * b);
}

fn linearFactor(p: [4]ErrorPoint, q: []const ErrorPoint, i: usize, j: usize, factor: f64) Polynomial {
    var result: Polynomial = .{ .len = 4 };
    for (p, 0..) |r, k| {
        const dx1 = q[i].x - r.x;
        const dy1 = q[j].y - r.y;
        const dx2 = q[j].x - r.x;
        const dy2 = q[i].y - r.y;
        const error1 = productError(dx1, q[i].ex + r.ex + roundoff * @abs(dx1), dy1, q[j].ey + r.ey + roundoff * @abs(dy1));
        const error2 = productError(dx2, q[j].ex + r.ex + roundoff * @abs(dx2), dy2, q[i].ey + r.ey + roundoff * @abs(dy2));
        const difference = dx1 * dy1 - dx2 * dy2;
        const value = factor * difference;
        result.coefficients[k] = value;
        result.errors[k] = factor * (error1 + error2 + roundoff * @abs(difference)) + roundoff * @abs(value);
    }
    return result;
}

const binomials = blk: {
    var rows: [10][10]f64 = @splat(@splat(0));
    rows[0][0] = 1;
    for (1..10) |i| {
        rows[i][0] = 1;
        for (1..i) |j| rows[i][j] = rows[i - 1][j - 1] + rows[i - 1][j];
        rows[i][i] = 1;
    }
    break :blk rows;
};

fn multiply(a: Polynomial, b: Polynomial) Polynomial {
    const m = a.len - 1;
    const n = b.len - 1;
    var result: Polynomial = .{ .len = m + n + 1 };
    for (0..result.len) |k| {
        var sum: f64 = 0;
        var err: f64 = 0;
        var i = k -| n;
        while (i <= @min(m, k)) : (i += 1) {
            const factor = binomials[m][i] * binomials[n][k - i] / binomials[m + n][k];
            const a1 = a.coefficients[i];
            const b1 = b.coefficients[k - i];
            const term = factor * (a1 * b1);
            sum += term;
            err += factor * productError(a1, a.errors[i], b1, b.errors[k - i]) + roundoff * (2 * @abs(term) + @abs(sum));
        }
        result.coefficients[k] = sum;
        result.errors[k] = err;
    }
    return result;
}

fn add(a: Polynomial, b: Polynomial, sign: f64) Polynomial {
    std.debug.assert(a.len == b.len);
    var result: Polynomial = .{ .len = a.len };
    for (0..a.len) |i| {
        const sum = a.coefficients[i] + sign * b.coefficients[i];
        result.coefficients[i] = sum;
        result.errors[i] = a.errors[i] + b.errors[i] + roundoff * @abs(sum);
    }
    return result;
}

fn cubicImplicit(p: [4]ErrorPoint, q: [4]ErrorPoint) Polynomial {
    const l32 = linearFactor(p, &q, 3, 2, 3);
    const l31 = linearFactor(p, &q, 3, 1, 3);
    const l30 = linearFactor(p, &q, 3, 0, 1);
    const l21 = linearFactor(p, &q, 2, 1, 9);
    const l20 = linearFactor(p, &q, 2, 0, 3);
    const l10 = linearFactor(p, &q, 1, 0, 3);
    const m = add(l30, l21, 1);
    return add(add(multiply(l32, add(multiply(m, l10), multiply(l20, l20), -1)), multiply(l31, add(multiply(l31, l10), multiply(l20, l30), -1)), -1), multiply(l30, add(multiply(l31, l20), multiply(m, l30), -1)), 1);
}

fn quadraticHandle(q: [4]ErrorPoint) ErrorPoint {
    const x = (3 * q[1].x - q[0].x) / 2;
    const y = (3 * q[1].y - q[0].y) / 2;
    return .{ .x = x, .y = y, .ex = (3 * q[1].ex + q[0].ex) / 2 + 2 * roundoff * @abs(x), .ey = (3 * q[1].ey + q[0].ey) / 2 + 2 * roundoff * @abs(y) };
}

fn quadraticImplicit(p: [4]ErrorPoint, q: [3]ErrorPoint) Polynomial {
    const l21 = linearFactor(p, &q, 2, 1, 2);
    const l20 = linearFactor(p, &q, 2, 0, 1);
    const l10 = linearFactor(p, &q, 1, 0, 2);
    return add(multiply(l21, l10), multiply(l20, l20), -1);
}
