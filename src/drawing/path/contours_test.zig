//! Tests of subpaths, contour ranges and the straight-contour axis.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const contours = @import("contours.zig");
const ContourRange = contours.ContourRange;

test "contour ranges distinguish CLOSE from an open return to the start" {
    var p = Path.init(std.testing.allocator);
    defer p.deinit();
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 2, .y = 3 });
    try p.lineTo(.zero);
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 4, .y = 1 });
    try p.close();
    try p.moveTo(.zero);
    try p.close();
    const ranges = try contours.contourRanges(p, std.testing.allocator);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqualSlices(ContourRange, &.{
        .{ .begin = 0, .end = 2 },
        .{ .begin = 2, .end = 4, .closed = true },
        .{ .begin = 4, .end = 4, .closed = true },
    }, ranges);
}

test "a straight cubic admits an arc-length gradient exactly while its direction is monotone" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 3, .y = 3 }, .{ .x = 2, .y = 2 }, .{ .x = 5, .y = 5 });
    try std.testing.expectEqual(Point{ .x = 5, .y = 5 }, contours.linearAxis(curve).?[1]);
    try curve.lineTo(.{ .x = 4, .y = 4 });
    try std.testing.expect(contours.linearAxis(curve) == null);
    curve.segments.items.len = 2;
    curve.segments.items[1].cubic.c2 = .{ .x = -4, .y = -4 };
    try std.testing.expect(contours.linearAxis(curve) == null);
}

test "subpaths round trip exact mixed contours and own independent paths" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = -0.0, .y = 1 });
    try source.cubicTo(.{ .x = 1, .y = 4 }, .{ .x = 3, .y = 2 }, .{ .x = 2, .y = 1 });
    try source.lineTo(.{ .x = -0.0, .y = 1 });
    try source.close();
    try source.moveTo(.{ .x = 10, .y = 1 });
    try source.lineTo(.{ .x = 11, .y = 3 });
    try source.moveTo(.{ .x = 20, .y = 5 });
    try source.moveTo(.{ .x = 20, .y = 5 });
    try source.close();
    const parts = try contours.subpaths(source, allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expect(!parts[0].open);
    try std.testing.expectEqual(Point{ .x = -0.0, .y = 1 }, parts[0].current.?);
    try std.testing.expect(parts[1].open);
    try std.testing.expectEqual(Point{ .x = 10, .y = 1 }, parts[1].start.?);
    try std.testing.expectEqual(Point{ .x = 11, .y = 3 }, parts[1].current.?);
    try std.testing.expect(parts[2].open);
    try std.testing.expectEqual(@as(usize, 1), parts[2].segments.items.len);
    try std.testing.expect(!parts[3].open);
    try std.testing.expectEqual(@as(usize, 2), parts[3].segments.items.len);
    var joined = Path.init(allocator);
    defer joined.deinit();
    for (parts) |part| try joined.append(part);
    try std.testing.expectEqualDeep(source.segments.items, joined.segments.items);
    try std.testing.expect(std.math.signbit(parts[0].segments.items[0].move.x));
    try std.testing.expectEqual(source.current, joined.current);
    try std.testing.expectEqual(source.start, joined.start);
    try std.testing.expectEqual(source.open, joined.open);
    try source.transform(g.Transform.translation(100, 200));
    try std.testing.expectError(error.InvalidPath, parts[0].lineTo(.zero));
    try parts[1].lineTo(.{ .x = 12, .y = 4 });
    try std.testing.expectEqual(Point{ .x = -0.0, .y = 1 }, parts[0].segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 20, .y = 5 }, parts[2].current.?);
    try std.testing.expectEqual(Point{ .x = 120, .y = 205 }, source.current.?);
    try std.testing.expectEqual(@as(usize, 9), source.segments.items.len);
}

test "subpaths retain separate hole winding and handle empty and single paths" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    const empty = try contours.subpaths(source, allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();
    const single = try contours.subpaths(source, allocator);
    defer {
        for (single) |*part| part.deinit();
        allocator.free(single);
    }
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualDeep(source.segments.items, single[0].segments.items);
    try source.moveTo(.{ .x = 2, .y = 2 });
    try source.lineTo(.{ .x = 2, .y = 8 });
    try source.lineTo(.{ .x = 8, .y = 8 });
    try source.lineTo(.{ .x = 8, .y = 2 });
    try source.close();
    const parts = try contours.subpaths(source, allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(@as(f64, 100), parts[0].signedArea());
    try std.testing.expectEqual(@as(f64, -36), parts[1].signedArea());
    try std.testing.expectEqual(source.signedArea(), parts[0].signedArea() + parts[1].signedArea());
}

test "subpaths diagnose malformed topology and nonfinite coordinates" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, contours.subpaths(source, allocator));
    source.segments.clearRetainingCapacity();
    try source.moveTo(.zero);
    try source.close();
    try source.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, contours.subpaths(source, allocator));
    source.segments.items[2] = .close;
    try std.testing.expectError(error.InvalidPath, contours.subpaths(source, allocator));
    source.segments.clearRetainingCapacity();
    try source.segments.append(allocator, .{ .move = .{ .x = std.math.nan(f64), .y = 0 } });
    try std.testing.expectError(error.NonFinite, contours.subpaths(source, allocator));
    source.segments.clearRetainingCapacity();
    try source.moveTo(.zero);
    try source.segments.append(allocator, .{ .cubic = .{ .c1 = .zero, .c2 = .{ .x = 0, .y = std.math.inf(f64) }, .end = .zero } });
    try std.testing.expectError(error.NonFinite, contours.subpaths(source, allocator));
}

fn exerciseSubpaths(allocator: std.mem.Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    try source.close();
    try source.moveTo(.{ .x = 8, .y = 9 });
    try source.lineTo(.{ .x = 10, .y = 11 });
    try source.moveTo(.{ .x = 12, .y = 13 });
    const parts = try contours.subpaths(source, allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
}

test "subpaths release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSubpaths, .{});
}
