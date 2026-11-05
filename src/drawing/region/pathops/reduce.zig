// Copyright 2006, 2012 Google Inc.; BSD-style license: LICENSE.
// SkReduceOrder plus SkDCubic::ComplexBreak and the selected SkGeometry cubic
// classification. Reduction preserves genuine curves; it never replaces a
// nonlinear cubic by the chord merely because its endpoints coincide.
const std = @import("std");
const c = @import("curve.zig");
const n = @import("numeric.zig");
const Point = c.Point;
const Curve = c.Curve;
fn reducedLine(a: Point, b: Point) ?Curve {
    return if (a.approximatelyEqual(b)) null else .{ .line = .{ .points = .{ a, b } } };
}
pub fn quad(value: c.Quad) ?Curve {
    const p = value.points;
    var min_x: usize = 0;
    var min_y: usize = 0;
    for (1..3) |i| {
        if (p[min_x].x > p[i].x) min_x = i;
        if (p[min_y].y > p[i].y) min_y = i;
    }
    var xs: u3 = 0;
    var ys: u3 = 0;
    for (p, 0..) |point, i| {
        const bit = @as(u3, 1) << @as(u2, @intCast(i));
        if (n.almostEqualUlps(point.x, p[min_x].x)) xs |= bit;
        if (n.almostEqualUlps(point.y, p[min_y].y)) ys |= bit;
    }
    if (xs & 5 == 5 and ys & 5 == 5) return null;
    if (xs == 7 or ys == 7 or value.isLinear(0, 2)) return reducedLine(p[0], p[2]);
    return .{ .quad = value };
}
pub fn cubic(value: c.Cubic) ?Curve {
    const p = value.points;
    if (p[0].approximatelyDEqual(p[1]) and p[0].approximatelyDEqual(p[2]) and p[0].approximatelyDEqual(p[3])) return null;
    var min_x: usize = 0;
    var min_y: usize = 0;
    for (1..4) |i| {
        if (p[min_x].x > p[i].x) min_x = i;
        if (p[min_y].y > p[i].y) min_y = i;
    }
    var xs: u4 = 0;
    var ys: u4 = 0;
    for (p, 0..) |point, i| {
        const bit = @as(u4, 1) << @as(u2, @intCast(i));
        const denominator = @max(@abs(point.x), @max(@abs(point.y), @max(@abs(p[min_x].x), @abs(p[min_y].y))));
        if (denominator == 0) {
            xs |= bit;
            ys |= bit;
            continue;
        }
        const inverse = 1 / denominator;
        if (n.approximatelyEqualHalf(point.x * inverse, p[min_x].x * inverse)) xs |= bit;
        if (n.approximatelyEqualHalf(point.y * inverse, p[min_y].y * inverse)) ys |= bit;
    }
    if (xs == 15) {
        if (ys == 15) return null;
        return reducedLine(p[0], p[3]);
    }
    if (ys == 15 or value.isLinear(0, 3)) return reducedLine(p[0], p[3]);
    const dx10 = p[1].x - p[0].x;
    const dx23 = p[2].x - p[3].x;
    const mid_x = p[0].x + dx10 * 3 / 2;
    const side_ax = mid_x - p[3].x;
    const side_bx = dx23 * 3 / 2;
    if (if (n.approximatelyZero(side_ax)) !n.approximatelyEqual(side_ax, side_bx) else !n.almostEqualUlpsPin(side_ax, side_bx)) return .{ .cubic = value };
    const dy10 = p[1].y - p[0].y;
    const dy23 = p[2].y - p[3].y;
    const mid_y = p[0].y + dy10 * 3 / 2;
    const side_ay = mid_y - p[3].y;
    const side_by = dy23 * 3 / 2;
    if (if (n.approximatelyZero(side_ay)) !n.approximatelyEqual(side_ay, side_by) else !n.almostEqualUlpsPin(side_ay, side_by)) return .{ .cubic = value };
    return .{ .quad = .{ .points = .{ p[0], .{ .x = mid_x, .y = mid_y }, p[3] } } };
}
pub fn quadMaxCurvature(value: c.Quad) f64 {
    const p = value.points;
    const ax = p[1].x - p[0].x;
    const ay = p[1].y - p[0].y;
    const bx = p[0].x - p[1].x - p[1].x + p[2].x;
    const by = p[0].y - p[1].y - p[1].y + p[2].y;
    var numerator = -(ax * bx + ay * by);
    var denominator = bx * bx + by * by;
    if (denominator < 0) {
        numerator = -numerator;
        denominator = -denominator;
    }
    if (numerator <= 0) return 0;
    if (numerator >= denominator) return 1;
    return numerator / denominator;
}
const CubicKind = enum { serpentine, loop, local_cusp, cusp_at_infinity, quadratic, line_or_point };
const Classification = struct { kind: CubicKind, t: [2]f64, s: [2]f64 };
fn dotCross(p0: Point, p1: Point, p2: Point) f64 {
    return p0.x * (p1.y - p2.y) + p0.y * (p2.x - p1.x) + (p1.x * p2.y - p1.y * p2.x);
}
fn inversePow2(value: f64) f64 {
    var bits: u64 = @bitCast(value);
    bits = ((@as(u64, 1023) * 2 << 52) + ((@as(u64, 1) << 52) - 1)) -% bits;
    bits &= @as(u64, 0x7ff) << 52;
    return @bitCast(bits);
}
fn copySign(value: f64, sign: f64) f64 {
    const mask: u64 = 1 << 63;
    return @bitCast((@as(u64, @bitCast(value)) & ~mask) | (@as(u64, @bitCast(sign)) & mask));
}
fn classification(kind: CubicKind, t0: f64, s0: f64, t1: f64, s1: f64) Classification {
    var result: Classification = .{ .kind = kind, .t = .{ t0, -copySign(t1, t1 * s1) }, .s = .{ s0, -@abs(s1) } };
    if (copySign(result.s[1], result.s[0]) * result.t[0] > -@abs(result.s[0]) * result.t[1]) {
        std.mem.swap(f64, &result.t[0], &result.t[1]);
        std.mem.swap(f64, &result.s[0], &result.s[1]);
    }
    return result;
}
fn classify(value: c.Cubic) Classification {
    const p = value.points;
    const a1 = dotCross(p[0], p[3], p[2]);
    const a2 = dotCross(p[1], p[0], p[3]);
    const a3 = dotCross(p[2], p[1], p[0]);
    var d3 = 3 * a3;
    var d2 = d3 - a2;
    var d1 = d2 - a2 + a1;
    const norm = inversePow2(@max(@max(@abs(d1), @abs(d2)), @abs(d3)));
    d1 *= norm;
    d2 *= norm;
    d3 *= norm;
    if (d1 != 0) {
        const discriminant = 3 * d2 * d2 - 4 * d1 * d3;
        if (discriminant > 0) {
            const q = 3 * d2 + copySign(@sqrt(3 * discriminant), d2);
            return classification(.serpentine, q, 6 * d1, 2 * d3, q);
        }
        if (discriminant < 0) {
            const q = d2 + copySign(@sqrt(-discriminant), d2);
            return classification(.loop, q, 2 * d1, 2 * (d2 * d2 - d3 * d1), d1 * q);
        }
        return classification(.local_cusp, d2, 2 * d1, d2, 2 * d1);
    }
    if (d2 != 0) return classification(.cusp_at_infinity, d3, 3 * d2, 1, 0);
    return classification(if (d3 != 0) .quadratic else .line_or_point, 1, 0, 1, 0);
}

pub fn complexBreak(value: c.Cubic, out: *[3]f64) usize {
    if (value.monotonicInX() and value.monotonicInY()) return 0;
    const info = classify(value);
    if (info.kind == .loop and n.roughlyBetween(0, info.t[0], info.s[0]) and n.roughlyBetween(0, info.t[1], info.s[1])) {
        out[0] = (info.t[0] * info.s[1] + info.t[1] * info.s[0]) / (2 * info.s[0] * info.s[1]);
        return @intFromBool(out[0] > 0 and out[0] < 1);
    }
    switch (info.kind) {
        .loop, .serpentine, .local_cusp, .cusp_at_infinity => {
            var inflections: [2]f64 = undefined;
            const inflection_count = value.findInflections(&inflections);
            var curvature: [3]f64 = undefined;
            const count = value.findMaxCurvature(&curvature);
            if (inflection_count == 2) {
                for (curvature[0..count]) |t| if (n.between(inflections[0], t, inflections[1])) {
                    out[0] = t;
                    return @intFromBool(t > 0 and t < 1);
                };
                return 0;
            }
            var found: usize = 0;
            const precision = value.calcPrecision() * 2;
            for (curvature[0..count]) |t| {
                if (t <= 0 or t >= 1) continue;
                // ComplexBreak needs the raw derivative, including a zero cusp.
                const p = value.points;
                const s = 1 - t;
                const dx = 3 * ((p[1].x - p[0].x) * s * s + 2 * (p[2].x - p[1].x) * t * s + (p[3].x - p[2].x) * t * t);
                const dy = 3 * ((p[1].y - p[0].y) * s * s + 2 * (p[2].y - p[1].y) * t * s + (p[3].y - p[2].y) * t * t);
                if (@sqrt(dx * dx + dy * dy) < precision) {
                    out[found] = t;
                    found += 1;
                }
            }
            if (found == 0 and inflection_count == 1) {
                out[0] = inflections[0];
                found = @intFromBool(out[0] > 0 and out[0] < 1);
            }
            return found;
        },
        else => return 0,
    }
}

test "degree reduction preserves curved controls and exact quadratic elevation" {
    const curved: c.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } };
    try std.testing.expect(cubic(curved).? == .cubic);
    const elevated: c.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 6, .y = 0 } } };
    const reduced = cubic(elevated).?;
    try std.testing.expect(reduced == .quad);
    try std.testing.expect(reduced.quad.points[1].eql(.{ .x = 3, .y = 6 }));
    const loop: c.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 5 }, .{ .x = -3, .y = 5 }, .{ .x = 0, .y = 0 } } };
    try std.testing.expect(cubic(loop).? == .cubic);
    var breaks: [3]f64 = undefined;
    try std.testing.expect(complexBreak(loop, &breaks) > 0);
    try std.testing.expect(breaks[0] > 0 and breaks[0] < 1);
}

test "reference quadratic maximum curvature split preserves its exact controls" {
    // Geometry contract from the former C++ container test, independent of
    // its storage representation or legacy iterator API.
    const source: c.Quad = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 0 } } };
    const parameter = quadMaxCurvature(source);
    try std.testing.expectEqual(@as(f64, 0.5), parameter);
    const halves = source.chopAt(parameter);
    try std.testing.expect(halves[0].points[0].eql(source.points[0]));
    try std.testing.expect(halves[0].points[1].eql(.{ .x = 0.5, .y = 1 }));
    try std.testing.expect(halves[0].points[2].eql(.{ .x = 1, .y = 1 }));
    try std.testing.expect(halves[0].points[2].eql(halves[1].points[0]));
    try std.testing.expect(halves[1].points[1].eql(.{ .x = 1.5, .y = 1 }));
    try std.testing.expect(halves[1].points[2].eql(source.points[2]));
}
