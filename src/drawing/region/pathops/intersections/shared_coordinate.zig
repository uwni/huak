// Copyright 2026 Huak contributors. BSD-style license: ../LICENSE.
//! Exact reduction when a shared injective coordinate proves equal parameters.
const std = @import("std");
const curves = @import("../curve.zig");
const n = @import("../numeric.zig");
const Intersections = @import("../Intersections.zig");
const Curve = curves.Curve;

/// Return false without changing results when the strict structure does not
/// apply. Equal shared coordinates imply t=u (or u=1-t after reversal), so
/// the existing scalar intersector solves the remaining coordinate difference.
pub fn intersect(first: Curve, second: Curve, result: *Intersections) bool {
    if (first == .line or second == .line or std.meta.activeTag(first) != std.meta.activeTag(second)) return false;
    return alongAxis(.x, first, second, result) or alongAxis(.y, first, second, result);
}

fn alongAxis(comptime axis: curves.Axis, first: Curve, second: Curve, result: *Intersections) bool {
    const count = first.pointCount();
    const name = @tagName(axis);
    const other_name = @tagName(if (axis == .x) curves.Axis.y else curves.Axis.x);
    const increasing = @field(first.point(1), name) > @field(first.point(0), name);
    var monotone = true;
    for (1..count) |index| {
        const previous = @field(first.point(index - 1), name);
        const current = @field(first.point(index), name);
        monotone = monotone and if (increasing) previous < current else previous > current;
    }
    if (!monotone) return false;
    for ([_]bool{ false, true }) |reversed| {
        const aligned = if (reversed) second.reverse() else second;
        var differences: [4]f64 = undefined;
        var maximum: f64 = 0;
        var shared = true;
        for (0..count) |index| {
            const a = first.point(index);
            const b = aligned.point(index);
            if (!a.isFinite() or !b.isFinite() or @field(a, name) != @field(b, name)) {
                shared = false;
                break;
            }
            const difference = n.DoubleDouble.difference(@field(a, other_name), @field(b, other_name));
            if (difference.lo != 0 or !std.math.isFinite(difference.hi)) {
                shared = false;
                break;
            }
            differences[index] = difference.hi;
            maximum = @max(maximum, @abs(difference.hi));
        }
        // The zero polynomial retains the original coincidence semantics.
        if (!shared or maximum == 0) continue;
        const exponent = std.math.frexp(maximum).exponent;
        var exact_scaling = true;
        for (differences[0..count]) |*difference| {
            const scaled = std.math.ldexp(difference.*, -exponent);
            if (!std.math.isFinite(scaled) or std.math.ldexp(scaled, exponent) != difference.*) {
                exact_scaling = false;
                break;
            }
            difference.* = scaled;
        }
        if (!exact_scaling) continue;
        var scalar = first;
        switch (scalar) {
            inline else => |*curve| {
                for (&curve.points, 0..) |*point, index| point.* = .{ .x = 0, .y = differences[index] };
            },
        }
        var times: [3]f64 = undefined;
        const roots = switch (scalar) {
            .line => unreachable,
            .quad => |curve| curve.horizontalIntersect(0, times[0..2]),
            .cubic => |curve| curve.horizontalIntersect(0, &times),
        };
        // Preserve the original coordinate acceptance and source-domain
        // point values. A failed residual leaves the general path intact.
        for (times[0..roots]) |time| {
            const other = if (reversed) 1 - time else time;
            if (!first.ptAtT(time).approximatelyEqual(second.ptAtT(other))) return false;
        }
        result.reset();
        result.setMax(if (first == .cubic) 13 else 8);
        for (times[0..roots]) |time| _ = result.insert(time, if (reversed) 1 - time else time, first.ptAtT(time));
        return true;
    }
    return false;
}

test "shared monotone coordinate solves captured false coincidence and overflow pairs across source mappings" {
    const Case = struct { a: curves.Cubic, b: curves.Cubic, time: f64 };
    const cases = [_]Case{
        // Circle XOR: the exact difference is 2^-51*t^3, only root zero.
        .{ .a = .{ .points = .{ .{ .x = 0, .y = 0.6875048549840361 }, .{ .x = 0.005086232954145009, .y = 0.6874983840256892 }, .{ .x = 0.010161077664941898, .y = 0.6874433086828295 }, .{ .x = 0.015224094605083671, .y = 0.6873400684827615 } } }, .b = .{ .points = .{ .{ .x = 0, .y = 0.6875048549840361 }, .{ .x = 0.005086232954145009, .y = 0.6874983840256892 }, .{ .x = 0.010161077664941898, .y = 0.6874433086828295 }, .{ .x = 0.015224094605083671, .y = 0.6873400684827611 } } }, .time = 0 },
        // Open self weave: difference controls [-4,2,4,6]*2^-54.
        .{ .a = .{ .points = .{ .{ .x = -0.7725931959874202, .y = -0.40056638700555225 }, .{ .x = -0.7725920519585499, .y = -0.40057614154269516 }, .{ .x = -0.7725908112941076, .y = -0.4005858340131847 }, .{ .x = -0.7725894740390862, .y = -0.40059546441702054 } } }, .b = .{ .points = .{ .{ .x = -0.7725931959874202, .y = -0.400566387005552 }, .{ .x = -0.7725920519585499, .y = -0.4005761415426953 }, .{ .x = -0.7725908112941076, .y = -0.4005858340131849 }, .{ .x = -0.7725894740390862, .y = -0.4005954644170209 } } }, .time = 0.26486074095009854 },
    };
    for (cases, 0..) |case, case_index| for ([_]i32{ -40, 0, 40 }) |exponent| for (0..2) |axis| for (0..4) |reversed| for (0..2) |swapped| {
        errdefer std.debug.print("shared coordinate case={d} scale={d} axis={d} reverse={d} swap={d}\n", .{ case_index, exponent, axis, reversed, swapped });
        var a = case.a;
        var b = case.b;
        for ([_]*curves.Cubic{ &a, &b }) |curve| for (&curve.points) |*point| {
            point.x = std.math.ldexp(point.x, exponent);
            point.y = std.math.ldexp(point.y, exponent);
            if (axis != 0) std.mem.swap(f64, &point.x, &point.y);
        };
        if (reversed & 1 != 0) a = a.reverse();
        if (reversed & 2 != 0) b = b.reverse();
        if (swapped != 0) std.mem.swap(curves.Cubic, &a, &b);
        const first: Curve = .{ .cubic = a };
        const second: Curve = .{ .cubic = b };
        var result: Intersections = .{};
        try std.testing.expect(intersect(first, second, &result));
        try std.testing.expectEqual(@as(usize, 1), result.used);
        const times = [2]f64{ if (reversed & 1 == 0) case.time else 1 - case.time, if (reversed & 2 == 0) case.time else 1 - case.time };
        try std.testing.expectApproxEqAbs(times[swapped], result.parameters[0][0], 1e-13);
        try std.testing.expectApproxEqAbs(times[1 - swapped], result.parameters[1][0], 1e-13);
        try std.testing.expect(result.points[0].eql(first.ptAtT(result.parameters[0][0])));
        try std.testing.expect(first.ptAtT(result.parameters[0][0]).approximatelyEqual(second.ptAtT(result.parameters[1][0])));
        try std.testing.expectEqualSlices(u16, &.{ 0, 0 }, &result.coincident);
        try std.testing.expect(!result.overflow);
        var dispatched: Intersections = .{ .allow_near = false };
        try std.testing.expectEqual(@as(usize, 1), try dispatched.curveCurve(std.testing.allocator, first, second));
        try std.testing.expectEqualDeep(result.parameters, dispatched.parameters);
        try std.testing.expectEqualDeep(result.points, dispatched.points);
    };
}

test "shared monotone coordinate leaves nonqualifying and coincident curves on the original path" {
    const base: curves.Cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 } } };
    var result: Intersections = .{ .max = 2 };
    _ = result.insert(0.25, 0.5, .{ .x = 7, .y = 8 });
    const original = result;
    var second = base;
    second.points[0].y = 0x1p-60; // The exact difference 1-2^-60 needs a tail.
    try std.testing.expect(!intersect(.{ .cubic = base }, .{ .cubic = second }, &result));
    try std.testing.expectEqualDeep(original, result);
    var first = base;
    first.points[1].x = 2;
    first.points[2].x = 1;
    second = first;
    second.points[0].y = 0;
    try std.testing.expect(!intersect(.{ .cubic = first }, .{ .cubic = second }, &result));
    try std.testing.expectEqualDeep(original, result);
    first = base;
    first.points[0].y = 0;
    first.points[1].y = std.math.floatTrueMin(f64);
    second = first;
    second.points[0].y = -1e100; // Scaling the maximum would lose the subnormal.
    second.points[1].y = 0;
    try std.testing.expect(!intersect(.{ .cubic = first }, .{ .cubic = second }, &result));
    try std.testing.expectEqualDeep(original, result);
    try std.testing.expect(!intersect(.{ .cubic = base }, .{ .cubic = base }, &result));
    try std.testing.expectEqualDeep(original, result);
}
