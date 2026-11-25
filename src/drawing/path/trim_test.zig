//! Tests of trimming, reversal across pen-up moves and closes, rectangle clipping, and allocation failure in owned path operations.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Path = @import("Path.zig");
const trim = @import("trim.zig");
const cubic_intersect = @import("cubic_intersect.zig");
const intersectLineCubic = cubic_intersect.intersectLineCubic;
const intersectCubics = cubic_intersect.intersectCubics;

test "exact trimming preserves curves and pen-up subpaths" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .zero, .p1 = .{ .x = 0, .y = 4 }, .p2 = .{ .x = 4, .y = 4 }, .p3 = .{ .x = 4, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    try p.moveTo(.{ .x = 9, .y = 0 });
    try p.lineTo(.{ .x = 10, .y = 0 });
    var cut = try trim.trimmed(p, allocator, 0.25, 1.5);
    defer cut.deinit();
    try std.testing.expectEqual(@as(usize, 4), cut.segments.items.len);
    try std.testing.expect(g.tolerance.points(cut.segments.items[0].move, c.at(0.25)));
    try std.testing.expect(g.tolerance.points(cut.current.?, .{ .x = 9.5, .y = 0 }));
    var backward = try trim.trimmed(p, allocator, 0.75, 0.25);
    defer backward.deinit();
    try std.testing.expect(g.tolerance.points(backward.current.?, c.at(0.25)));
    try std.testing.expectError(error.InvalidParameter, trim.trimmed(p, allocator, -1, 0));
}

test "zero-width trimming follows query boundaries across pen-up moves" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 11, .y = 0 });
    for ([_]f64{ 0, 0.5, 1, 1.5, 2 }) |time| {
        var point = try trim.trimmed(path, allocator, time, time);
        defer point.deinit();
        try std.testing.expect(g.tolerance.points(try path.pointAt(time), try point.pointAt(0)));
        try std.testing.expectEqual(@as(usize, 2), point.segments.items.len);
        try std.testing.expect(point.segments.items[1] == .line);
    }
    var before = try trim.trimmed(path, allocator, 0.5, 1);
    defer before.deinit();
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, before.current.?);
    var after = try trim.trimmed(path, allocator, 1, 1.5);
    defer after.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, try after.pointAt(0));
    var backward = try trim.trimmed(path, allocator, 1.5, 1);
    defer backward.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, backward.current.?);
}

test "zero-width trimming preserves segment kinds across closes reversal and final endpoints" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |zero_close| {
        var path = Path.init(allocator);
        defer path.deinit();
        try path.moveTo(.{ .x = -2, .y = -3 });
        try path.lineTo(.{ .x = -1, .y = -3 });
        if (zero_close) try path.lineTo(.{ .x = -2, .y = -3 });
        try path.close();
        try path.moveTo(.{ .x = 10, .y = 5 });
        try path.cubicTo(.{ .x = 10, .y = 6 }, .{ .x = 11, .y = 6 }, .{ .x = 11, .y = 5 });
        try path.close();
        try path.moveTo(.{ .x = 100, .y = 100 });
        try std.testing.expectEqual(@as(usize, 4), path.segmentCount());
        var reversed = try path.reverse(allocator);
        defer reversed.deinit();
        for ([_]f64{ 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4 }) |time| {
            var point = try trim.trimmed(path, allocator, time, time);
            defer point.deinit();
            try std.testing.expect(g.tolerance.points(try path.pointAt(time), try point.pointAt(0)));
            try std.testing.expectEqual(@as(usize, 2), point.segments.items.len);
            if (time >= 2 and time < 3) {
                try std.testing.expect(point.segments.items[1] == .cubic);
                const controls = point.segments.items[1].cubic;
                try std.testing.expectEqual(point.current.?, controls.c1);
                try std.testing.expectEqual(point.current.?, controls.c2);
            } else try std.testing.expect(point.segments.items[1] == .line);
            var reverse_point = try trim.trimmed(reversed, allocator, time, time);
            defer reverse_point.deinit();
            try std.testing.expect(g.tolerance.points(try reversed.pointAt(time), try reverse_point.pointAt(0)));
        }
        var complete = try trim.trimmed(path, allocator, 0, 2);
        defer complete.deinit();
        try std.testing.expect(!complete.open);
        try std.testing.expect(complete.segments.items[complete.segments.items.len - 1] == .close);
    }
}

test "closed reversal retains the time origin and reverses implicit closing edges" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 3, .y = 1 });
    try path.close();
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 3), path.segmentCount());
    try std.testing.expectEqual(path.segmentCount(), reversed.segmentCount());
    try std.testing.expectEqual(Point.zero, reversed.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 3, .y = 1 }, reversed.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 2, .y = 2 }, reversed.segments.items[3].cubic.c1);
    try std.testing.expectEqual(Point{ .x = 0, .y = 2 }, reversed.segments.items[3].cubic.c2);
    for ([_]f64{ 0, 0.25, 0.5, 1, 1.5, 2, 2.5, 3 }) |time| {
        var original_point = try trim.trimmed(path, allocator, 3 - time, 3 - time);
        defer original_point.deinit();
        var reverse_point = try trim.trimmed(reversed, allocator, time, time);
        defer reverse_point.deinit();
        try std.testing.expect(g.tolerance.points(original_point.current.?, reverse_point.current.?));
    }
    var backward = try trim.trimmed(path, allocator, 3, 0);
    defer backward.deinit();
    try std.testing.expectEqual(Point.zero, backward.segments.items[0].move);
    try std.testing.expectEqual(@as(usize, 3), backward.segmentCount());
}

test "zero-length closes mark topology without consuming segment time" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.lineTo(.zero);
    try path.close();
    try path.moveTo(.{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 3, .y = 0 });
    try std.testing.expectEqual(@as(usize, 3), path.segmentCount());
    var first = try trim.trimmed(path, allocator, 0, 2);
    defer first.deinit();
    try std.testing.expect(!first.open);
    try std.testing.expect(first.segments.items[first.segments.items.len - 1] == .close);
    try std.testing.expectEqual(@as(usize, 2), first.segmentCount());
    var partial = try trim.trimmed(path, allocator, 0.5, 2);
    defer partial.deinit();
    try std.testing.expect(partial.open);
    var second = try trim.trimmed(path, allocator, 2, 3);
    defer second.deinit();
    try std.testing.expectEqual(Point{ .x = 2, .y = 0 }, second.segments.items[0].move);
    try std.testing.expectEqual(@as(usize, 1), second.segmentCount());
}

test "reversal and backward trimming reverse subpath order across pen-up jumps" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 11, .y = 0 });
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 4), reversed.segments.items.len);
    try std.testing.expectEqual(Point{ .x = 11, .y = 0 }, reversed.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, reversed.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, reversed.segments.items[2].move);
    try std.testing.expectEqual(Point.zero, reversed.segments.items[3].line);
    var backward = try trim.trimmed(path, allocator, 1.75, 0.25);
    defer backward.deinit();
    try std.testing.expectEqual(Point{ .x = 10.75, .y = 0 }, backward.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, backward.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, backward.segments.items[2].move);
    try std.testing.expectEqual(Point{ .x = 0.25, .y = 0 }, backward.current.?);
    try path.close();
    var mixed = try path.reverse(allocator);
    defer mixed.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, mixed.segments.items[0].move);
    try std.testing.expect(mixed.segments.items[3] == .close);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, mixed.segments.items[4].move);
}

test "rectangle clipping retains exact cubic pieces and handles boundary segments" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    const rect = g.BBox.fromPoints(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 });
    var clipped = try trim.clippedToRect(p, allocator, rect);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(usize, 2), clipped.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), clipped.segments.items[0].move.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), clipped.current.?.x, 1e-12);
    try std.testing.expect(clipped.segments.items[1] == .cubic);
    try std.testing.expect(clipped.bounds().?.max.y <= 2);
    var edge = Path.init(allocator);
    defer edge.deinit();
    try edge.moveTo(.{ .x = -1, .y = 0 });
    try edge.lineTo(.{ .x = 3, .y = 0 });
    var on_boundary = try trim.clippedToRect(edge, allocator, rect);
    defer on_boundary.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 2), on_boundary.bounds().?.width(), 1e-12);
}

test "rectangle clipping preserves fully retained closed contours and opens cut ones" {
    const allocator = std.testing.allocator;
    var triangle = Path.init(allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 1, .y = 0 });
    try triangle.lineTo(.{ .x = 1, .y = 1 });
    try triangle.close();
    var whole = try trim.clippedToRect(triangle, allocator, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer whole.deinit();
    try std.testing.expect(!whole.open);
    try std.testing.expect(whole.segments.items[whole.segments.items.len - 1] == .close);
    try std.testing.expectEqual(triangle.segmentCount(), whole.segmentCount());
    var cut = try trim.clippedToRect(triangle, allocator, .fromPoints(.{ .x = 0.5, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer cut.deinit();
    try std.testing.expect(cut.open);
    for (cut.segments.items) |segment| try std.testing.expect(segment != .close);
    var returned = Path.init(allocator);
    defer returned.deinit();
    try returned.moveTo(.zero);
    try returned.cubicTo(.{ .x = 0, .y = 1 }, .{ .x = 1, .y = 0 }, .zero);
    try returned.close();
    var returned_clip = try trim.clippedToRect(returned, allocator, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer returned_clip.deinit();
    try std.testing.expect(!returned_clip.open);
    try std.testing.expectEqual(@as(usize, 1), returned_clip.segmentCount());
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const c: Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    var reversed = try p.reverse(allocator);
    defer reversed.deinit();
    var cut = try trim.trimmed(p, allocator, 0.1, 0.9);
    defer cut.deinit();
    var clipped = try trim.clippedToRect(p, allocator, .fromPoints(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }));
    defer clipped.deinit();
    const hits = try intersectLineCubic(allocator, .{ .x = -2, .y = 1 }, .{ .x = 4, .y = 1 }, c);
    defer allocator.free(hits);
    const endpoint = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }));
    defer allocator.free(endpoint);
    const bounded = try intersectCubics(allocator, Cubic.line(.{ .x = -2, .y = 1 }, .{ .x = 4, .y = 1 }), c, 1e-10);
    defer allocator.free(bounded);
    var point_curve = try trim.trimmed(p, allocator, 0.5, 0.5);
    defer point_curve.deinit();
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 1, .y = 0 });
    var point_line = try trim.trimmed(p, allocator, 1, 1);
    defer point_line.deinit();
}

test "owned path operations release resources on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}
