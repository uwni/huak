// Copyright 2012 Google Inc.
// Copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Tests of the curve-curve dispatch and TSect intersections.
const std = @import("std");
const Point = @import("../point.zig").Point;
const Cubic = @import("../curve.zig").Cubic;
const Curve = @import("../curve.zig").Curve;
const Intersections = @import("../Intersections.zig");

test "TSect cubic intersections retain two curved source events" {
    const base_a: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } };
    const base_b: Cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    // x=3t is injective, so t=u. The independent equation
    // 6t(1-t)=1-6t(1-t) gives these two exact mathematical events.
    const first = (1 - @sqrt(@as(f64, 2.0 / 3.0))) / 2;
    const expected = [_]f64{ first, 1 - first };
    for ([_]i32{ -8, 0, 8 }) |exponent| for (0..4) |reverse| for (0..2) |swapped_inputs| {
        errdefer std.debug.print("two-event fixture: scale=2^{d} reverse={d} swap={d}\n", .{ exponent, reverse, swapped_inputs });
        var a = base_a;
        var b = base_b;
        if (reverse & 1 != 0) std.mem.reverse(Point, &a.points);
        if (reverse & 2 != 0) std.mem.reverse(Point, &b.points);
        for (&a.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        for (&b.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        const source_a: Curve = .{ .cubic = if (swapped_inputs == 0) a else b };
        const source_b: Curve = .{ .cubic = if (swapped_inputs == 0) b else a };
        const reverse_a = reverse & (if (swapped_inputs == 0) @as(usize, 1) else 2) != 0;
        const reverse_b = reverse & (if (swapped_inputs == 0) @as(usize, 2) else 1) != 0;
        var result: Intersections = .{};
        try std.testing.expectEqual(@as(usize, 2), try result.curveCurve(std.testing.allocator, source_a, source_b));
        for (0..expected.len) |index| {
            const parameter = expected[if (reverse_a) expected.len - 1 - index else index];
            try std.testing.expectApproxEqAbs(if (reverse_a) 1 - parameter else parameter, result.parameters[0][index], 1e-12);
            try std.testing.expectApproxEqAbs(if (reverse_b) 1 - parameter else parameter, result.parameters[1][index], 1e-12);
            const pa = source_a.ptAtT(result.parameters[0][index]);
            const pb = source_b.ptAtT(result.parameters[1][index]);
            try std.testing.expect(pa.distance(pb) < 1e-12);
            try std.testing.expect(!result.isCoincident(index));
        }
    };
}

test "TSect rejects curved hull overlaps without a true event" {
    const a: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } } };
    const b: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0.1 }, .{ .x = 1, .y = 2.1 }, .{ .x = 2, .y = 2.1 }, .{ .x = 3, .y = 0.1 } } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 0), try result.curveCurve(std.testing.allocator, a, b));
}

test "curve dispatch returns exact coincident cubic endpoints under either near policy" {
    const curves = [_]Curve{
        .{ .cubic = .{ .points = .{ Point.zero, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } } },
        // TSect alone can return both endpoints without marking this overlap.
        .{ .cubic = .{ .points = .{ Point.zero, .{ .x = 0.0625, .y = -0.75 }, .{ .x = 0.1875, .y = 0.25 }, .{ .x = 0.5, .y = 0 } } } },
    };
    for (curves) |a| for ([_]bool{ false, true }) |allow_near| for ([_]bool{ false, true }) |reversed| {
        var result: Intersections = .{ .allow_near = allow_near };
        const b = if (reversed) a.reverse() else a;
        try std.testing.expectEqual(@as(usize, 2), try result.curveCurve(std.testing.allocator, a, b));
        try std.testing.expectEqualSlices(f64, &.{ 0, 1 }, result.parameters[0][0..result.used]);
        try std.testing.expectEqualSlices(f64, if (reversed) &.{ 1, 0 } else &.{ 0, 1 }, result.parameters[1][0..result.used]);
        try std.testing.expectEqual(@as(u16, 3), result.coincident);
    };
}

test "successive curve queries preserve the near policy and clear prior endpoint observations" {
    const a: Curve = .{ .quad = .{ .points = .{ Point.zero, .{ .x = 1, .y = 0.5 }, .{ .x = 2, .y = 1 } } } };
    var b = a;
    b.quad.points[2].y = std.math.nextAfter(f64, 1, 2);
    var exact: Intersections = .{ .allow_near = false };
    try std.testing.expectEqual(@as(usize, 1), try exact.curveCurve(std.testing.allocator, a, b));
    try std.testing.expectEqual(@as(f64, 0), exact.parameters[0][0]);
    try std.testing.expectEqual(@as(f64, 0), exact.parameters[1][0]);
    try std.testing.expectEqual(Point.zero, exact.points[0]);
    try std.testing.expectEqual(@as(usize, 1), try exact.curveCurve(std.testing.allocator, a, b));

    // The endpoint at t=1 is only present under the near policy.
    var near: Intersections = .{};
    _ = try near.curveCurve(std.testing.allocator, a, b);
    try std.testing.expect(near.nearly_same[1]);
    try std.testing.expect(near.hasT(1));
    _ = try near.curveCurve(std.testing.allocator, a, a);
    try std.testing.expectEqual([2]bool{ false, false }, near.nearly_same);
}
