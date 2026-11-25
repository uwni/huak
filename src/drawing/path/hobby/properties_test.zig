//! Properties of the solved controls: the mock-curvature equations, invariance under transforms and reindexing, extreme inputs, diagnostics and allocation failure.
const std = @import("std");
const geometry = @import("../../geometry.zig");
const Point = geometry.Point;
const hobby = @import("../hobby.zig");
const testing = @import("testing.zig");

fn expectMockCurvature(knots: []const hobby.Knot, options: hobby.Options) !void {
    const curves = try hobby.interpolate(std.testing.allocator, knots, options);
    defer std.testing.allocator.free(curves);
    var previous_end: f64 = 0;
    var first_start: f64 = 0;
    for (curves, 0..) |curve, i| {
        const chord = curve.p3.sub(curve.p0);
        const angle = std.math.atan2(chord.y, chord.x);
        const outgoing = curve.p1.sub(curve.p0);
        const incoming = curve.p3.sub(curve.p2);
        const theta = hobby.wrapped(std.math.atan2(outgoing.y, outgoing.x) - angle);
        const phi = hobby.wrapped(angle - std.math.atan2(incoming.y, incoming.x));
        const alpha = 1 / knots[i].outgoing_tension;
        const beta = 1 / knots[(i + 1) % knots.len].incoming_tension;
        // Independently evaluate the published endpoint mock-curvatures from
        // the actual returned cubics, not the internal solver coefficients.
        const start = (2 * beta * (theta + phi) - 6 * theta) / (alpha * alpha * chord.norm());
        const end = (2 * alpha * (theta + phi) - 6 * phi) / (beta * beta * chord.norm());
        if (i == 0) {
            first_start = start;
            if (!options.closed) try std.testing.expectApproxEqAbs(options.start_curl * end, start, 1e-10);
        } else {
            try std.testing.expectApproxEqAbs(previous_end, start, 1e-10);
            const prior_tangent = curves[i - 1].p3.sub(curves[i - 1].p2);
            try std.testing.expectApproxEqAbs(@as(f64, 0), prior_tangent.cross(outgoing) / (prior_tangent.norm() * outgoing.norm()), 1e-12);
            try std.testing.expect(prior_tangent.dot(outgoing) > 0);
        }
        previous_end = end;
        if (!options.closed and i + 1 == curves.len) try std.testing.expectApproxEqAbs(options.end_curl * start, end, 1e-10);
    }
    if (options.closed) try std.testing.expectApproxEqAbs(previous_end, first_start, 1e-10);
}

test "returned controls preserve the published mock-curvature and curl equations" {
    try expectMockCurvature(&testing.example_open, .{});
    try expectMockCurvature(&testing.example_closed, .{ .closed = true });
    var knots = testing.example_open;
    knots[0].outgoing_tension = 0.75;
    knots[1].incoming_tension = 2.2;
    knots[2].outgoing_tension = 1.3;
    knots[3].incoming_tension = 1.1;
    try expectMockCurvature(&knots, .{ .start_curl = 2.5, .end_curl = 0.2 });
}

test "translation rotation scaling reflection and reverse traversal" {
    var knots = testing.example_open;
    knots[0].outgoing_direction = testing.up;
    knots[2].outgoing_tension = 1.5;
    const options: hobby.Options = .{ .end_curl = 0.3 };
    const reference = try hobby.interpolate(std.testing.allocator, &knots, options);
    defer std.testing.allocator.free(reference);
    const transform = geometry.Transform.rotation(0.713).then(geometry.Transform.scaling(2.5, -2.5)).then(geometry.Transform.translation(83, -17));
    const linear = geometry.Transform.rotation(0.713).then(geometry.Transform.scaling(2.5, -2.5));
    var transformed = knots;
    for (&transformed) |*knot| {
        knot.point = transform.apply(knot.point);
        if (knot.incoming_direction) |d| knot.incoming_direction = linear.apply(d);
        if (knot.outgoing_direction) |d| knot.outgoing_direction = linear.apply(d);
    }
    const result = try hobby.interpolate(std.testing.allocator, &transformed, options);
    defer std.testing.allocator.free(result);
    for (result, reference) |actual, original| {
        const expected = original.transformed(transform);
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
    var reverse: [knots.len]hobby.Knot = undefined;
    for (&reverse, 0..) |*target, i| {
        const source = knots[knots.len - 1 - i];
        target.* = .{ .point = source.point, .incoming_tension = source.outgoing_tension, .outgoing_tension = source.incoming_tension, .incoming_direction = if (source.outgoing_direction) |d| d.scale(-1) else null, .outgoing_direction = if (source.incoming_direction) |d| d.scale(-1) else null };
    }
    const reversed = try hobby.interpolate(std.testing.allocator, &reverse, .{ .start_curl = options.end_curl, .end_curl = options.start_curl });
    defer std.testing.allocator.free(reversed);
    for (reversed, 0..) |actual, i| {
        const expected = reference[reference.len - 1 - i].reversed();
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
}

test "closed constrained paths are independent of the first knot index" {
    var knots = testing.example_closed;
    knots[1].outgoing_direction = testing.right;
    knots[3].incoming_direction = testing.up;
    knots[3].outgoing_direction = testing.left;
    const original = try hobby.interpolate(std.testing.allocator, &knots, .{ .closed = true });
    defer std.testing.allocator.free(original);
    var shifted: [knots.len]hobby.Knot = undefined;
    for (&shifted, 0..) |*knot, i| knot.* = knots[(i + 2) % knots.len];
    const result = try hobby.interpolate(std.testing.allocator, &shifted, .{ .closed = true });
    defer std.testing.allocator.free(result);
    for (result, 0..) |actual, i| {
        const expected = original[(i + 2) % knots.len];
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
}

test "finite extreme scales and large batches keep valid controls" {
    const reference = try hobby.interpolate(std.testing.allocator, &testing.example_open, .{});
    defer std.testing.allocator.free(reference);
    for ([_]f64{ 1e-250, 1e250 }) |scale| {
        var knots = testing.example_open;
        for (&knots) |*knot| knot.point = knot.point.scale(scale);
        const result = try hobby.interpolate(std.testing.allocator, &knots, .{});
        defer std.testing.allocator.free(result);
        for (result, reference) |actual, expected| {
            inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
                const rescaled = @field(actual, field).scale(1 / scale);
                try std.testing.expectApproxEqAbs(@field(expected, field).x, rescaled.x, 1e-9);
                try std.testing.expectApproxEqAbs(@field(expected, field).y, rescaled.y, 1e-9);
            }
        }
    }
    var batch: [2048]hobby.Knot = undefined;
    for (&batch, 0..) |*knot, i| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / batch.len;
        knot.* = .{ .point = .{ .x = 100 * @cos(angle), .y = 100 * @sin(angle) } };
    }
    const result = try hobby.interpolate(std.testing.allocator, &batch, .{ .closed = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(batch.len, result.len);
    for (result) |curve| try std.testing.expect(curve.isFinite());
}

test "invalid inputs and unrepresentable arithmetic are diagnosed" {
    try std.testing.expectError(error.TooFewKnots, hobby.interpolate(std.testing.allocator, &.{}, .{}));
    var knots = testing.example_open;
    knots[1].point = knots[0].point;
    try std.testing.expectError(error.CoincidentKnots, hobby.interpolate(std.testing.allocator, &knots, .{}));
    knots = testing.example_open;
    knots[3].point = knots[0].point;
    try std.testing.expectError(error.CoincidentKnots, hobby.interpolate(std.testing.allocator, &knots, .{ .closed = true }));
    knots = testing.example_open;
    try std.testing.expectError(error.CoincidentKnots, hobby.interpolate(std.testing.allocator, &knots, .{ .minimum_chord = 101 }));
    knots[0].point.x = std.math.nan(f64);
    try std.testing.expectError(error.NonFinite, hobby.interpolate(std.testing.allocator, &knots, .{}));
    knots = testing.example_open;
    knots[0].incoming_tension = 0.74;
    try std.testing.expectError(error.InvalidTension, hobby.interpolate(std.testing.allocator, &knots, .{}));
    knots = testing.example_open;
    knots[2].outgoing_tension = std.math.inf(f64);
    try std.testing.expectError(error.InvalidTension, hobby.interpolate(std.testing.allocator, &knots, .{}));
    knots = testing.example_open;
    knots[1].outgoing_direction = Point.zero;
    try std.testing.expectError(error.InvalidDirection, hobby.interpolate(std.testing.allocator, &knots, .{}));
    knots[1].outgoing_direction = .{ .x = std.math.inf(f64), .y = 0 };
    try std.testing.expectError(error.InvalidDirection, hobby.interpolate(std.testing.allocator, &knots, .{}));
    try std.testing.expectError(error.InvalidCurl, hobby.interpolate(std.testing.allocator, &testing.example_open, .{ .start_curl = -1 }));
    try std.testing.expectError(error.InvalidTolerance, hobby.interpolate(std.testing.allocator, &testing.example_open, .{ .minimum_chord = -1 }));
    knots = testing.example_open;
    knots[0].point.x = -1e308;
    knots[1].point.x = 1e308;
    try std.testing.expectError(error.NumericalFailure, hobby.interpolate(std.testing.allocator, &knots, .{}));
}

fn allocationFailureExercise(allocator: std.mem.Allocator) !void {
    const result = try hobby.interpolate(allocator, &testing.example_closed, .{ .closed = true });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 4), result.len);
}

test "allocation failure frees all partially allocated storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
