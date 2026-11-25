//! Tests of cubic self-intersection roots: known roots, adjacent and split segments, large origins, scaling and reflection, and the endpoint convention.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../Path.zig");
const crossings = @import("../crossings.zig");
const testing = @import("testing.zig");
const self_intersection = @import("self_intersection.zig");

test "crossings power-basis cubic self intersection has independently known roots" {
    // C(t)=(48t³-39t,48t²-48t). Distinct parameters 1/4 and 3/4
    // both give (-9,-9); neither is a curve endpoint or midpoint.
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{testing.loop}, false);
    defer path.deinit();
    const events = try crossings.find(allocator, &.{path}, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const event = events[0];
    try std.testing.expectEqual(@as(usize, 0), event.first.path);
    try std.testing.expectEqual(@as(usize, 0), event.first.contour);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), event.first.time, 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), event.second.time, 1e-13);
    try std.testing.expect(event.point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);
    try std.testing.expect((try path.pointAt(event.first.time)).distance(event.point) <= 1e-9);
    try std.testing.expect((try path.pointAt(event.second.time)).distance(event.point) <= 1e-9);
}

test "crossings retain adjacent-segment interior roots after a cubic split" {
    const allocator = std.testing.allocator;
    const halves = testing.loop.split(0.5);
    var path = try Path.fromCubics(allocator, &.{ halves.left, halves.right }, false);
    defer path.deinit();
    const events = try crossings.find(allocator, &.{path}, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), events[0].first.time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), events[0].second.time, 1e-9);
    try std.testing.expect(events[0].point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);

    // Put each crossing passage exactly on an internal source node. A node's
    // outgoing segment owns it, so no duplicated incident-segment roots leak.
    const first = testing.loop.split(0.25);
    const rest = first.right.split(2.0 / 3.0);
    var nodes = try Path.fromCubics(allocator, &.{ first.left, rest.left, rest.right }, false);
    defer nodes.deinit();
    const at_nodes = try crossings.find(allocator, &.{nodes}, .{ .tolerance = 1e-9 });
    defer allocator.free(at_nodes);
    try std.testing.expectEqual(@as(usize, 1), at_nodes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), at_nodes[0].first.time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), at_nodes[0].second.time, 1e-9);
    try std.testing.expect(at_nodes[0].point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);
}

test "crossings retain cubic source roots under a large common origin" {
    const allocator = std.testing.allocator;
    const origin: g.Point = .{ .x = 1e9, .y = -1e9 };
    var path = try Path.fromCubics(allocator, &.{testing.loop.transformed(.translation(origin.x, origin.y))}, false);
    defer path.deinit();
    const events = try crossings.find(allocator, &.{path}, .{ .tolerance = 1e-6 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), events[0].first.time, 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), events[0].second.time, 1e-13);
    try std.testing.expect(events[0].point.distance(origin.add(.{ .x = -9, .y = -9 })) <= 1e-6);
}

test "crossings preserve source parameters under spatial scaling and reflection" {
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{testing.loop}, false);
    defer path.deinit();
    for ([_]f64{ 1e-12, 1e12 }) |scale| for ([_]f64{ -1, 1 }) |sign| {
        const transform = g.Transform.scaling(sign * scale, scale);
        var mapped = try path.transformed(allocator, transform);
        defer mapped.deinit();
        const tolerance = scale * 1e-9;
        const events = try crossings.find(allocator, &.{mapped}, .{ .tolerance = tolerance });
        defer allocator.free(events);
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectApproxEqAbs(@as(f64, 0.25), events[0].first.time, 1e-13);
        try std.testing.expectApproxEqAbs(@as(f64, 0.75), events[0].second.time, 1e-13);
        try std.testing.expect(events[0].point.distance(transform.apply(.{ .x = -9, .y = -9 })) <= tolerance);
    };
}

test "crossings endpoint convention diagnoses collapsed roots and leaves later roots intact" {
    const allocator = std.testing.allocator;
    const Fixture = struct {
        fn curve(first: f64, second: f64) g.Cubic {
            // A=(1,0), B=(0,1), C=(-Q,-S): both coordinates agree at
            // the prescribed distinct roots, without relying on find itself.
            const s = first + second;
            const q = first * first + first * second + second * second;
            return .{ .p0 = .zero, .p1 = .{ .x = -q / 3, .y = -s / 3 }, .p2 = .{ .x = -2 * q / 3, .y = (1 - 2 * s) / 3 }, .p3 = .{ .x = 1 - q, .y = 1 - s } };
        }
    };
    const close = Fixture.curve(1e-16, 2e-16);
    try std.testing.expect(close.at(1e-16).distance(close.at(2e-16)) < 1e-45);
    var unresolved = try Path.fromCubics(allocator, &.{close}, false);
    defer unresolved.deinit();
    try std.testing.expectError(error.ResolutionLimit, crossings.find(allocator, &.{unresolved}, .{ .tolerance = 1e-25 }));
    const first: f64 = 1e-9;
    const second: f64 = 0.75;
    var resolved = try Path.fromCubics(allocator, &.{Fixture.curve(first, second)}, false);
    defer resolved.deinit();
    const events = try crossings.find(allocator, &.{resolved}, .{ .tolerance = 1e-12 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].first.time > self_intersection.endpoint_roundoff);
    try std.testing.expectApproxEqAbs(first, events[0].first.time, 1e-16);
    try std.testing.expectApproxEqAbs(second, events[0].second.time, 1e-14);
}

test "crossings retain a real crossing close to an adjacent source node" {
    const allocator = std.testing.allocator;
    const split_time = 0.25 + 1e-9;
    const pieces = testing.loop.split(split_time);
    var path = try Path.fromCubics(allocator, &.{ pieces.left, pieces.right }, false);
    defer path.deinit();
    const events = try crossings.find(allocator, &.{path}, .{ .tolerance = 1e-12 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].first.time < 1);
    try std.testing.expectApproxEqAbs(0.25 / split_time, events[0].first.time, 1e-13);
    try std.testing.expectApproxEqAbs(1 + (0.75 - split_time) / (1 - split_time), events[0].second.time, 1e-13);
}

test "crossings distinguish a small loop crossing from its shared source node" {
    const allocator = std.testing.allocator;
    const delta: f64 = 1e-6;
    const q = 0.75 + delta * delta;
    const curve: g.Cubic = .{ .p0 = .zero, .p1 = .{ .x = -q / 3, .y = -1.0 / 3.0 }, .p2 = .{ .x = -2 * q / 3, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1 - q, .y = 0 } };
    const pieces = curve.split(0.5);
    var path = try Path.fromCubics(allocator, &.{ pieces.left, pieces.right }, false);
    defer path.deinit();
    try std.testing.expectError(error.ResolutionLimit, crossings.find(allocator, &.{path}, .{ .tolerance = 1e-18 }));
}

test "crossings keep injective quadratic and straight cubic inputs empty" {
    const allocator = std.testing.allocator;
    var arc = try Path.fromCubics(allocator, &.{.{ .p0 = .zero, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 2, .y = 0 } }}, false);
    defer arc.deinit();
    const none = try crossings.find(allocator, &.{arc}, .{ .tolerance = 1e-9 });
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var line = try Path.fromCubics(allocator, &.{g.Cubic.line(.{ .x = -1, .y = -1 }, .{ .x = 1, .y = 1 })}, false);
    defer line.deinit();
    const straight = try crossings.find(allocator, &.{line}, .{ .tolerance = 1e-9 });
    defer allocator.free(straight);
    try std.testing.expectEqual(@as(usize, 0), straight.len);
    try std.testing.expectError(error.InvalidTolerance, crossings.find(allocator, &.{line}, .{ .tolerance = 0 }));
}
