// Copyright 2012 Google Inc.; BSD-style license: ../LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
//! Tests of cubic ray and axis roots against the retained reference implementation.
const std = @import("std");
const n = @import("../numeric.zig");
const roots = @import("../roots.zig");
const curves = @import("../curve.zig");
const axis_roots = @import("axis_roots.zig");

test "original cubic ray contracts retain roots at physical and parameter limits" {
    for ([_]f64{ 6, 10 }) |radius| {
        const k = radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
        const quarter: curves.Cubic = .{ .points = .{ .{ .x = -radius, .y = 0 }, .{ .x = -radius, .y = -k }, .{ .x = -k, .y = -radius }, .{ .x = 0, .y = -radius } } };
        const y = -@sqrt(@as(f64, 2));
        var ts: [3]f64 = undefined;
        const count = quarter.horizontalIntersect(y, &ts);
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(@abs(quarter.ptAtT(ts[0]).y - y) <= 16 * n.EPSILON / (1 - 16 * n.EPSILON) * radius);
    }
    const radius = 0.66113130760175032;
    const cx = -0.18889465931478577;
    const k = radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const quarter: curves.Cubic = .{ .points = .{ .{ .x = cx, .y = -radius }, .{ .x = cx - k, .y = -radius }, .{ .x = cx - radius, .y = -k }, .{ .x = cx - radius, .y = 0 } } };
    var ts: [3]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), quarter.horizontalIntersect(-5.5511151231257827e-17, &ts));
    try std.testing.expectEqual(@as(f64, 1), ts[0]);
}

test "cubic binary search reuses sampled points with identical reference root bits" {
    const Reference = struct {
        fn finish(t: f64, distance: f64, min: f64, max: f64, min_position: f64, max_position: f64, intercept: f64, bracketed: bool) f64 {
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

        // Full pre-cache search, including the original acceptance test and
        // every parameter/point progress check and nearest-root return.
        fn search(curve: curves.Cubic, min: f64, max: f64, intercept: f64, axis: curves.Axis) f64 {
            var t = (min + max) / 2;
            var step = (t - min) / 2;
            var at = curve.ptAtT(t);
            var position = curves.coordinate(at, axis);
            var distance = position - intercept;
            const min_position = curves.coordinate(curve.ptAtT(min), axis);
            const max_position = curves.coordinate(curve.ptAtT(max), axis);
            const bracketed = (min_position <= intercept and intercept <= max_position) or (max_position <= intercept and intercept <= min_position);
            if (axis_roots.atIntercept(curve, position, t, axis, intercept)) return t;
            while (true) {
                const prior_t = @max(min, t - step);
                const less = curve.ptAtT(prior_t);
                if (prior_t == t or less.eql(at)) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                const less_distance = curves.coordinate(less, axis) - intercept;
                const last_step = step;
                step /= 2;
                if (if (distance > 0) distance > less_distance else distance < less_distance) t = prior_t else {
                    const next_t = t + last_step;
                    if (next_t > max) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                    const more = curve.ptAtT(next_t);
                    if (next_t == t or more.eql(at)) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                    const more_distance = curves.coordinate(more, axis) - intercept;
                    if (if (distance > 0) distance <= more_distance else distance >= more_distance) continue;
                    t = next_t;
                }
                at = curve.ptAtT(t);
                position = curves.coordinate(at, axis);
                distance = position - intercept;
                if (axis_roots.atIntercept(curve, position, t, axis, intercept)) return t;
            }
        }
    };
    const k: f64 = 6 * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const tiny_radius: f64 = 0.66113130760175032;
    const tiny_x: f64 = -0.18889465931478577;
    const tiny_k: f64 = tiny_radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const sources = [_]curves.Cubic{
        .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } },
        .{ .points = .{ .{ .x = -6, .y = 0 }, .{ .x = -6, .y = -k }, .{ .x = -k, .y = -6 }, .{ .x = 0, .y = -6 } } },
        .{ .points = .{ .{ .x = tiny_x, .y = -tiny_radius }, .{ .x = tiny_x - tiny_k, .y = -tiny_radius }, .{ .x = tiny_x - tiny_radius, .y = -tiny_k }, .{ .x = tiny_x - tiny_radius, .y = 0 } } },
        .{ .points = @splat(.{ .x = 1, .y = -1 }) },
    };
    const intervals = [_][2]f64{
        .{ 0, 1 },
        .{ 0, 0.5 },
        .{ 0.5, 1 },
        .{ 0.125, 0.875 },
        .{ 0.5, 0.5 },
        .{ 0, std.math.nextAfter(f64, 0, 1) },
        .{ std.math.nextAfter(f64, 1, 0), 1 },
    };
    var saw_failure = false;
    var saw_endpoint = false;
    var saw_interior = false;
    for (sources) |source| for ([_]i32{ -500, -80, 0, 80, 500 }) |exponent| {
        var curve = source;
        for (&curve.points) |*point| {
            point.x = std.math.ldexp(point.x, exponent);
            point.y = std.math.ldexp(point.y, exponent);
        }
        const bounds = curve.bounds();
        for ([_]curves.Axis{ .x, .y }) |axis| {
            const first = curves.coordinate(curve.points[0], axis);
            const last = curves.coordinate(curve.points[3], axis);
            const low = curves.coordinate(bounds.min, axis);
            const high = curves.coordinate(bounds.max, axis);
            const intercepts = [_]f64{
                0,
                -0.0,
                first,
                last,
                curves.coordinate(curve.ptAtT(0.375), axis),
                low,
                high,
                std.math.nextAfter(f64, last, std.math.inf(f64)),
                high + @max(1, high - low),
                std.math.ldexp(-@sqrt(@as(f64, 2)), exponent),
            };
            for (intercepts) |intercept| for (intervals) |interval| {
                const expected = Reference.search(curve, interval[0], interval[1], intercept, axis);
                const actual = axis_roots.binarySearch(curve, interval[0], interval[1], intercept, axis);
                try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
                if (expected < 0) saw_failure = true else if (expected == 0 or expected == 1) saw_endpoint = true else saw_interior = true;
            };
        }
    };
    try std.testing.expect(saw_failure and saw_endpoint and saw_interior);
}

test "captured Cardano candidates pass the original cubic back substitution" {
    const queries = [_]struct { curve: curves.Cubic, axis: curves.Axis, intercept: f64 }{
        .{ .curve = .{ .points = .{
            .{ .x = 0.42473070360522436, .y = -0.9910383084121902 },
            .{ .x = 0.15106303148814484, .y = -0.9910383084121902 },
            .{ .x = -0.07078845060087073, .y = -0.7691868263231746 },
            .{ .x = -0.07078845060087073, .y = -0.4955191542060951 },
        } }, .axis = .x, .intercept = 0 },
        .{ .curve = .{ .points = .{
            .{ .x = 0.3125, .y = 0 },
            .{ .x = 0.3125, .y = 0.3020307225637151 },
            .{ .x = 0.0676557225637151, .y = 0.546875 },
            .{ .x = -0.234375, .y = 0.546875 },
        } }, .axis = .y, .intercept = 0.29601827545333426 },
    };
    for (queries) |query| {
        var coefficients = axis_roots.coefficients(query.curve, query.axis);
        coefficients[3] -= query.intercept;
        var base_roots: [3]f64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), roots.cubicValidT(coefficients[0], coefficients[1], coefficients[2], coefficients[3], &base_roots));
        const t = base_roots[0];
        try std.testing.expect(t > 0 and t < 1);
        const value = curves.coordinate(query.curve.ptAtT(t), query.axis);
        try std.testing.expect(n.approximatelyEqual(value, query.intercept));
        var recovered: [3]f64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), axis_roots.axisIntersect(query.curve, query.axis, query.intercept, &recovered));
        try std.testing.expectEqual(@as(u64, @bitCast(t)), @as(u64, @bitCast(recovered[0])));
        for ([_]i32{ -800, -80, 80, 800 }) |exponent| {
            var scaled: [4]f64 = undefined;
            for (&scaled, coefficients) |*scaled_value, coefficient| scaled_value.* = std.math.ldexp(coefficient, exponent);
            var values: [3]f64 = undefined;
            try std.testing.expectEqual(@as(usize, 1), roots.cubicValidT(scaled[0], scaled[1], scaled[2], scaled[3], &values));
            try std.testing.expectEqual(@as(u64, @bitCast(t)), @as(u64, @bitCast(values[0])));
        }
    }
}
