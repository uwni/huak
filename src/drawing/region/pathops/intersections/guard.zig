// Copyright 2012 Google Inc.; compensated adaptation copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
// Port of the retained SkPathOpsTSect.cpp guard_evaluate/guard_refine block.
// This bounded fallback is invoked after ordinary tangent iteration loses
// progress. Curve/event parameters and coordinate acceptance remain unchanged.
const std = @import("std");
const curves = @import("../curve.zig");
const n = @import("../numeric.zig");
const DD = n.DoubleDouble;
const Curve = curves.Curve;
const Point = curves.Point;
const GuardPoint = struct { x: DD, y: DD };
pub const Range = struct { start: f64 = 0, end: f64 = 1 };

const PreparedCurve = struct {
    points: [4]GuardPoint = undefined,
    derivative: [3]GuardPoint = undefined,
    point_count: usize,

    fn init(curve: Curve) PreparedCurve {
        return switch (curve) {
            inline else => |value| blk: {
                const count = value.points.len;
                const degree: f64 = @floatFromInt(count - 1);
                var result: PreparedCurve = .{ .point_count = count };
                inline for (0..count) |index| {
                    const point = value.points[index];
                    result.points[index] = .{ .x = .{ .hi = point.x }, .y = .{ .hi = point.y } };
                }
                inline for (0..count - 1) |index| {
                    const a = value.points[index];
                    const b = value.points[index + 1];
                    result.derivative[index] = .{ .x = multiplyScalar(DD.difference(b.x, a.x), degree), .y = multiplyScalar(DD.difference(b.y, a.y), degree) };
                }
                break :blk result;
            },
        };
    }

    fn evaluate(self: *const PreparedCurve, t: f64, comptime derivative: bool) GuardPoint {
        const points: []const GuardPoint = if (derivative) &self.derivative else &self.points;
        return switch (self.point_count - @intFromBool(derivative)) {
            1 => evaluatePoints(1, points[0..1], t),
            2 => evaluatePoints(2, points[0..2], t),
            3 => evaluatePoints(3, points[0..3], t),
            4 => if (derivative) unreachable else evaluatePoints(4, points[0..4], t),
            else => unreachable,
        };
    }
};

inline fn multiplyScalar(value: DD, scalar: f64) DD {
    const low: f64 = 0x1p-400;
    const high: f64 = 0x1p400;
    const magnitude = @abs(value.hi);
    const tail = @abs(value.lo);
    const multiplier = @abs(scalar);
    if (magnitude >= low and magnitude <= high and multiplier >= low and multiplier <= high and
        (value.lo == 0 or (tail >= low and tail <= high)))
    {
        // Exact product bits are multiples of at least 2^-904; every
        // intermediate remains far from subnormal and overflow. Product's
        // FMA remainder is exact, and Add's final TwoSum is normalized.
        // Adding either signed zero product therefore leaves both fixed
        // points unchanged. Preserve the nonzero products and their Add order.
        return DD.product(value.hi, scalar).add(DD.product(value.lo, scalar));
    }
    // Keep the original signed-zero, special-number and extreme-scale path.
    return value.mul(.{ .hi = scalar });
}

fn evaluatePoints(comptime count: usize, source: *const [count]GuardPoint, t: f64) GuardPoint {
    var points = source.*;
    const parameter: DD = .{ .hi = t };
    const inverse = (DD{ .hi = 1 }).sub(parameter);
    const scalar_inverse = @as(u64, @bitCast(inverse.lo)) == 0;
    // Keep the original de Casteljau stage and left-to-right update order.
    // Only the small curve degree and loop bounds are specialized.
    inline for (0..count - 1) |level| {
        inline for (0..count - level - 1) |index| points[index] = .{
            .x = (if (scalar_inverse) multiplyScalar(points[index].x, inverse.hi) else points[index].x.mul(inverse)).add(multiplyScalar(points[index + 1].x, t)),
            .y = (if (scalar_inverse) multiplyScalar(points[index].y, inverse.hi) else points[index].y.mul(inverse)).add(multiplyScalar(points[index + 1].y, t)),
        };
    }
    return points[0];
}
fn difference(a: GuardPoint, b: GuardPoint) GuardPoint {
    return .{ .x = a.x.sub(b.x), .y = a.y.sub(b.y) };
}
fn norm(point: GuardPoint) f64 {
    return @max(@abs(point.x.hi) + @abs(point.x.lo), @abs(point.y.hi) + @abs(point.y.lo));
}

/// Both spans belong to the original event candidate. Damping must remain
/// inside them; proximity within a caller's physical tolerance is not a root.
pub fn refineWithin(a: Curve, b: Curve, a_range: Range, b_range: Range, a_t: *f64, b_t: *f64, point: *Point) bool {
    var u = a_t.*;
    var v = b_t.*;
    if (!n.between(a_range.start, u, a_range.end) or !n.between(b_range.start, v, b_range.end)) return false;
    const first = PreparedCurve.init(a);
    const second = PreparedCurve.init(b);
    var pa = first.evaluate(u, false);
    var pb = second.evaluate(v, false);
    const max_evaluations = 64;
    var work: usize = 0;
    while (work < max_evaluations) {
        work += 1;
        const residual = difference(pa, pb);
        const da = first.evaluate(u, true);
        const db = second.evaluate(v, true);
        const determinant = n.ddCross(da.x, da.y, db.x, db.y);
        if (determinant.hi == 0 and determinant.lo == 0) return false;
        const first_point: Point = .{ .x = pa.x.hi + pa.x.lo, .y = pa.y.hi + pa.y.lo };
        const second_point: Point = .{ .x = pb.x.hi + pb.x.lo, .y = pb.y.hi + pb.y.lo };
        if (first_point.approximatelyEqual(second_point)) {
            const half: DD = .{ .hi = 0.5 };
            const x = pa.x.add(pb.x).mul(half);
            const y = pa.y.add(pb.y).mul(half);
            point.* = .{ .x = x.hi + x.lo, .y = y.hi + y.lo };
            a_t.* = u;
            b_t.* = v;
            return true;
        }
        const du = n.ddCross(residual.x, residual.y, db.x, db.y).dividedBy(determinant);
        const dv = n.ddCross(residual.x, residual.y, da.x, da.y).dividedBy(determinant);
        if (!std.math.isFinite(du) or !std.math.isFinite(dv)) return false;
        var damping: f64 = 1;
        var advanced = false;
        while (work < max_evaluations) {
            work += 1;
            const next_u = u - damping * du;
            const next_v = v - damping * dv;
            if (next_u == u and next_v == v) return false;
            if (n.between(a_range.start, next_u, a_range.end) and n.between(b_range.start, next_v, b_range.end)) {
                const next_a = first.evaluate(next_u, false);
                const next_b = second.evaluate(next_v, false);
                if (norm(difference(next_a, next_b)) < norm(residual)) {
                    u = next_u;
                    v = next_v;
                    pa = next_a;
                    pb = next_b;
                    advanced = true;
                    break;
                }
            }
            damping *= 0.5;
        }
        if (!advanced) return false;
    }
    return false;
}

test "guard scalar multiplication preserves normal bits and exceptional fallback" {
    const subnormal: f64 = @bitCast(@as(u64, 1));
    const values = [_]f64{
        0,        -0.0,                   subnormal,         -subnormal,         std.math.floatMin(f64),
        0x1p-401, 0x1p-400,               -0x1p-400,         0x1p-54,            -0x1p-54,
        0.1,      -1,                     1,                 0x1p400,            -0x1p400,
        0x1p401,  std.math.floatMax(f64), std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64),
    };
    for (values) |hi| for (values) |lo| for (values) |scalar| {
        const value: DD = .{ .hi = hi, .lo = lo };
        const expected = value.mul(.{ .hi = scalar });
        const actual = multiplyScalar(value, scalar);
        try std.testing.expectEqual(@as(u64, @bitCast(expected.hi)), @as(u64, @bitCast(actual.hi)));
        try std.testing.expectEqual(@as(u64, @bitCast(expected.lo)), @as(u64, @bitCast(actual.lo)));
    };
}

test "prepared guard evaluation preserves original DD coordinate and derivative bits" {
    const Reference = struct {
        // The pre-preparation evaluator is retained only as a test oracle.
        fn evaluate(curve: Curve, t: f64, derivative: bool) GuardPoint {
            var points: [4]GuardPoint = undefined;
            var count = curve.pointCount();
            if (derivative) {
                const degree: DD = .{ .hi = @floatFromInt(count - 1) };
                for (0..count - 1) |index| {
                    const a = curve.point(index);
                    const b = curve.point(index + 1);
                    points[index] = .{ .x = DD.difference(b.x, a.x).mul(degree), .y = DD.difference(b.y, a.y).mul(degree) };
                }
                count -= 1;
            } else {
                for (0..count) |index| {
                    const point = curve.point(index);
                    points[index] = .{ .x = .{ .hi = point.x }, .y = .{ .hi = point.y } };
                }
            }
            const parameter: DD = .{ .hi = t };
            const inverse = (DD{ .hi = 1 }).sub(parameter);
            while (count > 1) : (count -= 1) {
                for (0..count - 1) |index| points[index] = .{
                    .x = points[index].x.mul(inverse).add(points[index + 1].x.mul(parameter)),
                    .y = points[index].y.mul(inverse).add(points[index + 1].y.mul(parameter)),
                };
            }
            return points[0];
        }

        fn expectBits(expected: GuardPoint, actual: GuardPoint) !void {
            for ([_]DD{ expected.x, expected.y }, [_]DD{ actual.x, actual.y }) |want, got| {
                try std.testing.expectEqual(@as(u64, @bitCast(want.hi)), @as(u64, @bitCast(got.hi)));
                try std.testing.expectEqual(@as(u64, @bitCast(want.lo)), @as(u64, @bitCast(got.lo)));
            }
        }
    };

    const controls = [_][4]Point{
        .{
            .{ .x = 0.45588299192121773, .y = -0.42502936011202347 },
            .{ .x = 0.48970774818035510, .y = -0.45885411637116086 },
            .{ .x = -0.2, .y = 0.7 },
            .{ .x = -1.1, .y = -0.3 },
        },
        .{
            .{ .x = 80, .y = 50 },
            .{ .x = 80, .y = 66.5685424949238 },
            .{ .x = 66.5685424949238, .y = 80 },
            .{ .x = 50, .y = 80 },
        },
        .{
            .{ .x = 1e16, .y = -1e16 },
            .{ .x = 1e16 + 2, .y = -1e16 + 4 },
            .{ .x = 1e16 + 6, .y = -1e16 - 2 },
            .{ .x = 1e16 + 8, .y = -1e16 + 6 },
        },
        .{ .{ .x = -0.0, .y = 0 }, .{ .x = 0, .y = -0.0 }, .{ .x = -0.0, .y = -0.0 }, .{ .x = 0, .y = 0 } },
    };
    const subnormal: f64 = @bitCast(@as(u64, 1));
    const parameters = [_]f64{ -0.0, 0, subnormal, 0x1p-54, 0x1p-52, 0.1, 0.125, 0.37, 0.5, 0.99999, 1 - 0x1p-53, 1 };
    var has_scalar_inverse = false;
    var has_compensated_inverse = false;
    for (parameters) |parameter| {
        const inverse = (DD{ .hi = 1 }).sub(.{ .hi = parameter });
        if (@as(u64, @bitCast(inverse.lo)) == 0) has_scalar_inverse = true else has_compensated_inverse = true;
    }
    try std.testing.expect(has_scalar_inverse and has_compensated_inverse);
    for (controls) |source| for ([_]i32{ -900, -500, -80, 0, 80, 500, 900 }) |exponent| {
        var points: [4]Point = undefined;
        for (source, &points) |point, *scaled| scaled.* = .{
            .x = std.math.ldexp(point.x, exponent),
            .y = std.math.ldexp(point.y, exponent),
        };
        for ([_]Curve{
            .{ .line = .{ .points = points[0..2].* } },
            .{ .quad = .{ .points = points[0..3].* } },
            .{ .cubic = .{ .points = points } },
        }) |curve| {
            const prepared = PreparedCurve.init(curve);
            for (parameters) |parameter| inline for ([_]bool{ false, true }) |derivative| {
                try Reference.expectBits(Reference.evaluate(curve, parameter, derivative), prepared.evaluate(parameter, derivative));
            };
        }
    };
}

test "guard singular refinement leaves all failure outputs untouched" {
    const line: Curve = .{ .line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } } } };
    var u: f64 = 0.25;
    var v: f64 = 0.75;
    var point: Point = .{ .x = -12.5, .y = 3.25 };
    try std.testing.expect(!refineWithin(line, line, .{}, .{}, &u, &v, &point));
    try std.testing.expectEqual(@as(f64, 0.25), u);
    try std.testing.expectEqual(@as(f64, 0.75), v);
    try std.testing.expectEqual(@as(f64, -12.5), point.x);
    try std.testing.expectEqual(@as(f64, 3.25), point.y);
}

test "guard refinement resolves original near-coincident quarter-circle event" {
    const radius: f64 = 30;
    const k = radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const a: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 80, .y = 50 }, .{ .x = 80, .y = 50 + k }, .{ .x = 50 + k, .y = 80 }, .{ .x = 50, .y = 80 },
    } } };
    const b: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 50.0001, .y = 80 }, .{ .x = 50.0001 - k, .y = 80 }, .{ .x = 20.0001, .y = 50 + k }, .{ .x = 20.0001, .y = 50 },
    } } };
    var u: f64 = 0.99999;
    var v: f64 = 0.00001;
    var point: Point = undefined;
    try std.testing.expect(refineWithin(a, b, .{ .start = 0.99 }, .{ .end = 0.01 }, &u, &v, &point));
    try std.testing.expect(a.ptAtT(u).approximatelyEqual(b.ptAtT(v)));
    try std.testing.expect(u > 0.99 and u < 1 and v > 0 and v < 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 50.00005), point.x, 1e-10);
    // Restricting away the candidate must fail without publishing new values.
    var invalid_u: f64 = 0.5;
    var invalid_v: f64 = 0.5;
    try std.testing.expect(!refineWithin(a, b, .{ .start = 0.99 }, .{ .end = 0.01 }, &invalid_u, &invalid_v, &point));
    try std.testing.expectEqual(@as(f64, 0.5), invalid_u);
    try std.testing.expectEqual(@as(f64, 0.5), invalid_v);
}
