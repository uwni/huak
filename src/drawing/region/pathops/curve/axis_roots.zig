// Copyright 2012 Google Inc.; BSD-style license: ../LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
//! Cubic axis-intercept roots: the bracketed root search along x or y, its bound, the binary search, and the coefficients and inflections it uses.
const std = @import("std");
const n = @import("../numeric.zig");
const roots = @import("../roots.zig");
const Point = @import("../point.zig").Point;
const curves = @import("../curve.zig");

pub fn coefficients(self: curves.Cubic, axis: curves.Axis) [4]f64 {
    var a = curves.coordinate(self.points[3], axis);
    var b = curves.coordinate(self.points[2], axis) * 3;
    var c = curves.coordinate(self.points[1], axis) * 3;
    const d = curves.coordinate(self.points[0], axis);
    a -= d - c + b;
    b += @mulAdd(f64, d, 3, -2 * c);
    c = @mulAdd(f64, d, -3, c);
    return .{ a, b, c, d };
}

pub fn findInflections(self: curves.Cubic, out: *[2]f64) usize {
    const p = self.points;
    const ax = p[1].x - p[0].x;
    const ay = p[1].y - p[0].y;
    const bx = @mulAdd(f64, p[1].x, -2, p[2].x) + p[0].x;
    const by = @mulAdd(f64, p[1].y, -2, p[2].y) + p[0].y;
    const cx = @mulAdd(f64, p[1].x - p[2].x, 3, p[3].x) - p[0].x;
    const cy = @mulAdd(f64, p[1].y - p[2].y, 3, p[3].y) - p[0].y;
    return roots.quadraticValidT(@mulAdd(f64, bx, cy, -(by * cx)), @mulAdd(f64, ax, cy, -(ay * cx)), @mulAdd(f64, ax, by, -(ay * bx)), out);
}

pub fn atIntercept(self: curves.Cubic, value: f64, t: f64, axis: curves.Axis, intercept: f64) bool {
    const s = 1 - t;
    const weighted = s * s * s * @abs(curves.coordinate(self.points[0], axis)) + 3 * s * s * t * @abs(curves.coordinate(self.points[1], axis)) + 3 * s * t * t * @abs(curves.coordinate(self.points[2], axis)) + t * t * t * @abs(curves.coordinate(self.points[3], axis));
    const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
    return value == intercept or @abs(value - intercept) <= gamma * (weighted + @abs(intercept));
}

fn interceptUpperBound(self: curves.Cubic, axis: curves.Axis, intercept: f64) f64 {
    // For t,s in [0,1], the original nonnegative product chains are
    // bounded by |p0|, 3|p1|, 3|p2|, |p3|. Preserve their summation order:
    // rounded multiplication/addition is monotone on nonnegative values.
    // Infinity disables the filter for overflow or nonfinite input.
    const weighted = @abs(curves.coordinate(self.points[0], axis)) + 3 * @abs(curves.coordinate(self.points[1], axis)) + 3 * @abs(curves.coordinate(self.points[2], axis)) + @abs(curves.coordinate(self.points[3], axis));
    const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
    const bound = gamma * (weighted + @abs(intercept));
    return if (std.math.isFinite(bound)) bound else std.math.inf(f64);
}

inline fn atInterceptWithinBound(self: curves.Cubic, value: f64, t: f64, axis: curves.Axis, intercept: f64, upper_bound: f64) bool {
    if (t >= 0 and t <= 1 and @abs(value - intercept) > upper_bound) return false;
    return atIntercept(self, value, t, axis, intercept);
}

pub fn binarySearch(self: curves.Cubic, min: f64, max: f64, intercept: f64, axis: curves.Axis) f64 {
    var t = (min + max) / 2;
    var step = (t - min) / 2;
    var at = self.ptAtT(t);
    var position = curves.coordinate(at, axis);
    var distance = position - intercept;
    const min_position = curves.coordinate(self.ptAtT(min), axis);
    const max_position = curves.coordinate(self.ptAtT(max), axis);
    const bracketed = (min_position <= intercept and intercept <= max_position) or (max_position <= intercept and intercept <= min_position);
    const upper_bound = interceptUpperBound(self, axis, intercept);
    if (atInterceptWithinBound(self, position, t, axis, intercept, upper_bound)) return t;
    while (true) {
        const prior_t = @max(min, t - step);
        const less = self.ptAtT(prior_t);
        if (prior_t == t or less.eql(at)) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
        const less_distance = curves.coordinate(less, axis) - intercept;
        const last_step = step;
        step /= 2;
        if (if (distance > 0) distance > less_distance else distance < less_distance) {
            t = prior_t;
            at = less;
        } else {
            const next_t = t + last_step;
            if (next_t > max) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
            const more = self.ptAtT(next_t);
            if (next_t == t or more.eql(at)) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
            const more_distance = curves.coordinate(more, axis) - intercept;
            if (if (distance > 0) distance <= more_distance else distance >= more_distance) continue;
            t = next_t;
            at = more;
        }
        position = curves.coordinate(at, axis);
        distance = position - intercept;
        if (atInterceptWithinBound(self, position, t, axis, intercept, upper_bound)) return t;
    }
}

pub fn searchRoots(self: curves.Cubic, extremes: []const f64, intercept: f64, axis: curves.Axis, out: *[3]f64) usize {
    var ts: [6]f64 = undefined;
    @memcpy(ts[0..extremes.len], extremes);
    var inflections: [2]f64 = undefined;
    const inflection_count = findInflections(self, &inflections);
    @memcpy(ts[extremes.len..][0..inflection_count], inflections[0..inflection_count]);
    const count = extremes.len + inflection_count + 2;
    ts[count - 2] = 0;
    ts[count - 1] = 1;
    std.mem.sort(f64, ts[0..count], {}, std.sort.asc(f64));
    var valid: usize = 0;
    for (0..count - 1) |i| {
        if (ts[i] == ts[i + 1]) continue;
        const t = binarySearch(self, ts[i], ts[i + 1], intercept, axis);
        if (t >= 0) {
            if (valid >= 3) return 0;
            out[valid] = t;
            valid += 1;
        }
    }
    return valid;
}

pub fn axisIntersect(self: curves.Cubic, axis: curves.Axis, intercept: f64, out: *[3]f64) usize {
    var c = coefficients(self, axis);
    c[3] -= intercept;
    const count = roots.cubicValidT(c[0], c[1], c[2], c[3], out);
    for (out[0..count]) |t| if (!n.approximatelyEqual(curves.coordinate(self.ptAtT(t), axis), intercept)) {
        var extremes: [2]f64 = undefined;
        const extreme_count = self.findExtrema(axis, &extremes);
        return searchRoots(self, extremes[0..extreme_count], intercept, axis, out);
    };
    return count;
}

fn nearestRoot(t: f64, distance: f64, min: f64, max: f64, min_position: f64, max_position: f64, intercept: f64, bracketed: bool) f64 {
    if (!bracketed) return -1;
    var result = t;
    var error_value = @abs(distance);
    if (@abs(min_position - intercept) < error_value) {
        error_value = @abs(min_position - intercept);
        result = min;
    }
    if (@abs(max_position - intercept) < error_value) result = max;
    return result;
}

fn checkInterceptBound(curve: curves.Cubic, t: f64, axis: curves.Axis, intercept: f64) !void {
    const s = 1 - t;
    // The original acceptance threshold, including its exact evaluation order.
    const weighted = s * s * s * @abs(curves.coordinate(curve.points[0], axis)) + 3 * s * s * t * @abs(curves.coordinate(curve.points[1], axis)) + 3 * s * t * t * @abs(curves.coordinate(curve.points[2], axis)) + t * t * t * @abs(curves.coordinate(curve.points[3], axis));
    const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
    const threshold = gamma * (weighted + @abs(intercept));
    const bound = interceptUpperBound(curve, axis, intercept);
    try std.testing.expect(threshold <= bound);
    const inf = std.math.inf(f64);
    for ([_]f64{
        0,
        std.math.nextAfter(f64, threshold, 0),
        threshold,
        std.math.nextAfter(f64, threshold, inf),
        bound,
        std.math.nextAfter(f64, bound, inf),
        bound * 2,
        std.math.floatMax(f64),
        inf,
    }) |offset| for ([_]f64{ -1, 1 }) |sign| {
        const value = intercept + sign * offset;
        try std.testing.expectEqual(atIntercept(curve, value, t, axis, intercept), atInterceptWithinBound(curve, value, t, axis, intercept, bound));
    };
}

test "cubic intercept bound preserves the original predicate at rounded boundaries" {
    const sources = [_]curves.Cubic{
        .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = 8, .y = 9 }, .{ .x = -16, .y = -2 }, .{ .x = 3, .y = 4 } } },
        .{ .points = @splat(.{ .x = 1, .y = -1 }) },
        .{ .points = @splat(Point.zero) },
    };
    for (sources) |source| for ([_]i32{ -1020, -500, -80, 0, 80, 500, 1000 }) |exponent| {
        var curve = source;
        for (&curve.points) |*point| {
            point.x = std.math.ldexp(point.x, exponent);
            point.y = std.math.ldexp(point.y, exponent);
        }
        for ([_]f64{ 0, std.math.nextAfter(f64, 0, 1), 0.125, 0.5, 0.875, std.math.nextAfter(f64, 1, 0), 1 }) |t| {
            for ([_]curves.Axis{ .x, .y }) |axis| {
                try checkInterceptBound(curve, t, axis, 0);
                try checkInterceptBound(curve, t, axis, curves.coordinate(curve.ptAtT(t), axis));
            }
        }
    };
}

test "cubic intercept bound falls back outside the unit interval and for nonfinite inputs" {
    const curve: curves.Cubic = .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = 8, .y = 9 }, .{ .x = -16, .y = -2 }, .{ .x = 3, .y = 4 } } };
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const bound = interceptUpperBound(curve, .x, 0);
    for ([_]f64{ -1, std.math.nextAfter(f64, 0, -1), std.math.nextAfter(f64, 1, inf), 2, inf, nan }) |t| {
        for ([_]f64{ 0, 1, -1, inf, nan }) |value| {
            try std.testing.expectEqual(atIntercept(curve, value, t, .x, 0), atInterceptWithinBound(curve, value, t, .x, 0, bound));
        }
    }
    for ([_]f64{ inf, nan, std.math.floatMax(f64) }) |nonfinite_bound| {
        var extreme = curve;
        extreme.points[1].x = nonfinite_bound;
        const disabled = interceptUpperBound(extreme, .x, 0);
        try std.testing.expectEqual(inf, disabled);
        for ([_]f64{ 0, 0.5, 1 }) |t| for ([_]f64{ 0, 1, inf, nan }) |value| {
            try std.testing.expectEqual(atIntercept(extreme, value, t, .x, 0), atInterceptWithinBound(extreme, value, t, .x, 0, disabled));
        };
    }
    for ([_]f64{ inf, nan }) |intercept| {
        const disabled = interceptUpperBound(curve, .x, intercept);
        try std.testing.expectEqual(inf, disabled);
        try std.testing.expectEqual(atIntercept(curve, intercept, 0.5, .x, intercept), atInterceptWithinBound(curve, intercept, 0.5, .x, intercept, disabled));
    }
}
