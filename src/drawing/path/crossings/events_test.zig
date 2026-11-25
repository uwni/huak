//! Tests of crossing events: batch order and provenance, closed seams and nodes, near-end diagnostics, tangency, incident rays, budgets and allocation failure.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../Path.zig");
const Allocator = std.mem.Allocator;
const crossings = @import("../crossings.zig");
const testing = @import("testing.zig");

test "crossings batch order and same-position branches retain path and contour provenance" {
    const allocator = std.testing.allocator;
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -3, .y = 0 });
    try horizontal.lineTo(.{ .x = 3, .y = 0 });
    var later = Path.init(allocator);
    defer later.deinit();
    try later.moveTo(.{ .x = 1, .y = -2 });
    try later.lineTo(.{ .x = 1, .y = 2 });
    var earlier = Path.init(allocator);
    defer earlier.deinit();
    try earlier.moveTo(.{ .x = -1, .y = -2 });
    try earlier.lineTo(.{ .x = -1, .y = 2 });
    const events = try crossings.find(allocator, &.{ horizontal, later, earlier }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(usize, 2), events[0].second.path);
    try std.testing.expectEqual(@as(usize, 1), events[1].second.path);
    try std.testing.expect(events[0].first.time < events[1].first.time);
    for (events) |event| {
        try std.testing.expectEqual(@as(usize, 0), event.first.path);
        try std.testing.expectEqual(@as(usize, 0), event.first.contour);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), event.second.time, 1e-14);
    }
    var crossed = Path.init(allocator);
    defer crossed.deinit();
    try crossed.moveTo(.{ .x = 100, .y = 100 });
    try crossed.moveTo(.{ .x = -1, .y = -1 });
    try crossed.lineTo(.{ .x = 1, .y = 1 });
    try crossed.moveTo(.{ .x = -1, .y = 1 });
    try crossed.lineTo(.{ .x = 1, .y = -1 });
    const self = try crossings.find(allocator, &.{crossed}, .{ .tolerance = 1e-9 });
    defer allocator.free(self);
    try std.testing.expectEqual(@as(usize, 1), self.len);
    try std.testing.expectEqual(@as(usize, 1), self[0].first.contour);
    try std.testing.expectEqual(@as(usize, 2), self[0].second.contour);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), self[0].first.time, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), self[0].second.time, 1e-14);
}

test "crossings exclude only ordinary closed nodes and canonicalize a queried seam" {
    const allocator = std.testing.allocator;
    var square = Path.init(allocator);
    defer square.deinit();
    try square.moveTo(.zero);
    try square.lineTo(.{ .x = 4, .y = 0 });
    try square.lineTo(.{ .x = 4, .y = 4 });
    try square.lineTo(.{ .x = 0, .y = 4 });
    try square.close();
    const none = try crossings.find(allocator, &.{square}, .{ .tolerance = 1e-9 });
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var circle = try Path.circle(allocator, .zero, 4);
    defer circle.deinit();
    const rounded = try crossings.find(allocator, &.{circle}, .{ .tolerance = 1e-9 });
    defer allocator.free(rounded);
    try std.testing.expectEqual(@as(usize, 0), rounded.len);
    var seam = Path.init(allocator);
    defer seam.deinit();
    try seam.moveTo(.{ .x = -1, .y = -1 });
    try seam.lineTo(.{ .x = 1, .y = 1 });
    const events = try crossings.find(allocator, &.{ square, seam }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(f64, 0), events[0].first.time);
    try std.testing.expectEqual(@as(f64, 0.5), events[0].second.time);
}

test "crossings closed three cubic trefoil excludes its ordinary smooth nodes" {
    const allocator = std.testing.allocator;
    const root_three = @sqrt(@as(f64, 3));
    for ([_]f64{ 1, 72.0 / 25.4 }) |scale| {
        const p0: g.Point = .{ .x = 0, .y = 40 * scale };
        const p1: g.Point = .{ .x = -root_three * 20 * scale, .y = -20 * scale };
        const p2: g.Point = .{ .x = root_three * 20 * scale, .y = -20 * scale };
        const x = 22 * scale;
        const y = root_three * 22 * scale;
        var path = try Path.fromCubics(allocator, &.{
            .{ .p0 = p0, .p1 = p0.add(.{ .x = 44 * scale, .y = 0 }), .p2 = p1.add(.{ .x = x, .y = -y }), .p3 = p1 },
            .{ .p0 = p1, .p1 = p1.add(.{ .x = -x, .y = y }), .p2 = p2.add(.{ .x = x, .y = y }), .p3 = p2 },
            .{ .p0 = p2, .p1 = p2.add(.{ .x = -x, .y = -y }), .p2 = p0.add(.{ .x = -44 * scale, .y = 0 }), .p3 = p0 },
        }, true);
        defer path.deinit();
        const events = try crossings.find(allocator, &.{path}, .{});
        defer allocator.free(events);
        try std.testing.expectEqual(@as(usize, 3), events.len);
        const Visit = struct { time: f64, id: usize };
        var visits: [6]Visit = undefined;
        for (events, 0..) |event, index| {
            visits[2 * index] = .{ .time = event.first.time, .id = index + 1 };
            visits[2 * index + 1] = .{ .time = event.second.time, .id = index + 1 };
        }
        std.mem.sort(Visit, &visits, {}, struct {
            fn less(_: void, first: Visit, second: Visit) bool {
                return first.time < second.time;
            }
        }.less);
        for (visits, [_]usize{ 1, 2, 3, 1, 2, 3 }) |visit, id| try std.testing.expectEqual(id, visit.id);
        for (events) |event| {
            try std.testing.expect(event.first.time != @floor(event.first.time));
            try std.testing.expect(event.second.time != @floor(event.second.time));
        }
    }
}

test "crossings diagnose unresolved unique near-end observations" {
    const a = std.testing.allocator;
    var first = try Path.fromCubics(a, &.{.{
        .p0 = .{ .x = 0.6855028164095287, .y = -0.052920675614067214 },
        .p1 = .{ .x = 0.68511706257494875, .y = -0.057912611829187721 },
        .p2 = .{ .x = 0.68468439187328545, .y = -0.062891398462162851 },
        .p3 = .{ .x = 0.68420524464335863, .y = -0.067856595174174528 },
    }}, false);
    defer first.deinit();
    var second = try Path.fromCubics(a, &.{.{
        .p0 = .{ .x = 0.68430475604368124, .y = -0.066845930293522704 },
        .p1 = .{ .x = 0.68375286442238825, .y = -0.072488543101240532 },
        .p2 = .{ .x = 0.68314094325928587, .y = -0.078113553109506295 },
        .p3 = .{ .x = 0.68246963955255446, .y = -0.083720313320140294 },
    }}, false);
    defer second.deinit();
    try std.testing.expectError(error.ResolutionLimit, crossings.find(a, &.{ first, second }, .{}));
}

test "crossings diagnose tangency multiway contacts and exact overlapping support" {
    const allocator = std.testing.allocator;
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -2, .y = 0 });
    try horizontal.lineTo(.{ .x = 2, .y = 0 });
    var tangent = try Path.fromCubics(allocator, &.{.{ .p0 = .{ .x = -1, .y = 1 }, .p1 = .{ .x = -1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } }}, false);
    defer tangent.deinit();
    try std.testing.expectError(error.NonTransverseCrossing, crossings.find(allocator, &.{ horizontal, tangent }, .{ .tolerance = 1e-9 }));
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 0, .y = -2 });
    try vertical.lineTo(.{ .x = 0, .y = 2 });
    var diagonal = Path.init(allocator);
    defer diagonal.deinit();
    try diagonal.moveTo(.{ .x = -2, .y = -2 });
    try diagonal.lineTo(.{ .x = 2, .y = 2 });
    try std.testing.expectError(error.MultipleCrossing, crossings.find(allocator, &.{ horizontal, vertical, diagonal }, .{ .tolerance = 1e-9 }));
    try std.testing.expectError(error.CoincidentCurves, crossings.find(allocator, &.{ horizontal, horizontal }, .{ .tolerance = 1e-9 }));
    const retraced: g.Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 2, .y = 0 }, .p2 = .{ .x = -2, .y = 0 }, .p3 = .{ .x = 1, .y = 0 } };
    var folded = try Path.fromCubics(allocator, &.{retraced}, false);
    defer folded.deinit();
    try std.testing.expectError(error.CoincidentCurves, crossings.find(allocator, &.{folded}, .{ .tolerance = 1e-9 }));
}

test "crossings classify all incident rays at a corner and reject terminal contacts" {
    const allocator = std.testing.allocator;
    var corner = Path.init(allocator);
    defer corner.deinit();
    try corner.moveTo(.{ .x = -2, .y = 0 });
    try corner.lineTo(.zero);
    try corner.lineTo(.{ .x = 0, .y = 2 });
    var touching = Path.init(allocator);
    defer touching.deinit();
    try touching.moveTo(.{ .x = -2, .y = -2 });
    try touching.lineTo(.{ .x = 2, .y = 2 });
    try std.testing.expectError(error.NonTransverseCrossing, crossings.find(allocator, &.{ corner, touching }, .{}));
    var passing = Path.init(allocator);
    defer passing.deinit();
    try passing.moveTo(.{ .x = -2, .y = 2 });
    try passing.lineTo(.{ .x = 2, .y = -2 });
    const events = try crossings.find(allocator, &.{ corner, passing }, .{});
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(f64, 1), events[0].first.time);
    var terminal = Path.init(allocator);
    defer terminal.deinit();
    try terminal.moveTo(.zero);
    try terminal.lineTo(.{ .x = 2, .y = 0 });
    try std.testing.expectError(error.NonTransverseCrossing, crossings.find(allocator, &.{ terminal, passing }, .{}));
}

test "crossings budgets are aggregate and retain their exact boundaries" {
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{testing.loop}, false);
    defer path.deinit();
    const events = try crossings.find(allocator, &.{path}, .{ .max_source_items = 3, .max_comparisons = 1, .max_events = 1 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{path}, .{ .max_source_items = 2 }));
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{path}, .{ .max_comparisons = 0 }));
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{path}, .{ .max_events = 0 }));
    var second = try Path.fromCubics(allocator, &.{.{ .p0 = .{ .x = 100, .y = 0 }, .p1 = .{ .x = 87, .y = -16 }, .p2 = .{ .x = 74, .y = -16 }, .p3 = .{ .x = 109, .y = 0 } }}, false);
    defer second.deinit();
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{ path, second }, .{ .max_source_items = 5 }));
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{ path, second }, .{ .max_comparisons = 2 }));
    try std.testing.expectError(error.GeometryWorkLimit, crossings.find(allocator, &.{ path, second }, .{ .max_events = 1 }));
    const pair = try crossings.find(allocator, &.{ path, second }, .{ .max_source_items = 6, .max_comparisons = 4, .max_events = 2 });
    defer allocator.free(pair);
    try std.testing.expectEqual(@as(usize, 2), pair.len);
}

fn allocationExercise(allocator: Allocator) !void {
    var path = try Path.fromCubics(allocator, &.{testing.loop}, false);
    defer path.deinit();
    var other = Path.init(allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 20, .y = -2 });
    try other.lineTo(.{ .x = 20, .y = 2 });
    const events = try crossings.find(allocator, &.{ path, other }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "crossings release source indexes root hits and events at every allocation failure" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}
