//! Tests of fresh transforms, appending transformed paths, reversal and joins.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const contours = @import("contours.zig");

test "appendTransformed matches a transformed temporary without copying it" {
    const allocator = std.testing.allocator;
    var prefix = Path.init(allocator);
    defer prefix.deinit();
    try prefix.moveTo(.{ .x = 1, .y = 2 });
    try prefix.lineTo(.{ .x = 3, .y = 4 });
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = -0.0, .y = 5 });
    try source.cubicTo(.{ .x = 6, .y = 7 }, .{ .x = 8, .y = 9 }, .{ .x = 10, .y = 11 });
    try source.close();
    const matrix = g.Transform{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 12, .f = -3 };
    var direct = Path.init(allocator);
    defer direct.deinit();
    try direct.append(prefix);
    try contours.appendTransformed(&direct, source, matrix);

    var expected_source = try source.transformed(allocator, matrix);
    defer expected_source.deinit();
    var expected = Path.init(allocator);
    defer expected.deinit();
    try expected.append(prefix);
    try expected.append(expected_source);
    try std.testing.expectEqualDeep(expected.segments.items, direct.segments.items);
    try std.testing.expectEqual(expected.current, direct.current);
    try std.testing.expectEqual(expected.start, direct.start);
    try std.testing.expectEqual(expected.open, direct.open);

    var unchanged = Path.init(allocator);
    defer unchanged.deinit();
    try unchanged.append(prefix);
    const before = unchanged.segments.items.len;
    try std.testing.expectError(error.NonFinite, contours.appendTransformed(&unchanged, source, .{ .a = std.math.nan(f64) }));
    try std.testing.expectEqual(before, unchanged.segments.items.len);
}

test "open and closed reversal, joins and transformed bounds" {
    const allocator = std.testing.allocator;
    var p = Path.init(allocator);
    defer p.deinit();
    try p.moveTo(.{ .x = 0, .y = 0 });
    try p.cubicTo(.{ .x = 0, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 0 });
    var next = Path.init(allocator);
    defer next.deinit();
    try next.moveTo(.{ .x = 4, .y = 0 });
    try next.lineTo(.{ .x = 8, .y = 0 });
    try contours.join(&p, next);
    var reversed = try p.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expect(g.tolerance.points(reversed.current.?, Point.zero));
    try std.testing.expectEqual(@as(usize, 2), reversed.segmentCount());
    try p.close();
    var closed = try p.reverse(allocator);
    defer closed.deinit();
    try std.testing.expect(!closed.open);
    try std.testing.expectEqual(p.bounds().?, closed.bounds().?);
    var rotated = try p.transformed(allocator, g.Transform.rotation(std.math.pi / 4.0));
    defer rotated.deinit();
    try std.testing.expect(rotated.bounds().?.height() > p.bounds().?.height());
    var mismatch = Path.init(allocator);
    defer mismatch.deinit();
    try mismatch.moveTo(.{ .x = 99, .y = 0 });
    try std.testing.expectError(error.InvalidPath, contours.join(&p, mismatch));
}

test "fresh transforms preserve clone then transform bits and source state" {
    const Check = struct {
        fn point(expected: Point, actual: Point) !void {
            try std.testing.expectEqual(@as(u64, @bitCast(expected.x)), @as(u64, @bitCast(actual.x)));
            try std.testing.expectEqual(@as(u64, @bitCast(expected.y)), @as(u64, @bitCast(actual.y)));
        }
        fn optional(expected: ?Point, actual: ?Point) !void {
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |value| try point(value, actual.?);
        }
        fn path(expected: Path, actual: Path) !void {
            try std.testing.expectEqual(expected.segments.items.len, actual.segments.items.len);
            for (expected.segments.items, actual.segments.items) |left, right| {
                try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
                switch (left) {
                    .move, .line => |value| try point(value, if (right == .move) right.move else right.line),
                    .cubic => |curve| {
                        try point(curve.c1, right.cubic.c1);
                        try point(curve.c2, right.cubic.c2);
                        try point(curve.end, right.cubic.end);
                    },
                    .close => {},
                }
            }
            try optional(expected.current, actual.current);
            try optional(expected.start, actual.start);
            try std.testing.expectEqual(expected.open, actual.open);
        }
    };
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |closed| {
        var source = Path.init(allocator);
        defer source.deinit();
        try source.moveTo(.{ .x = -0.0, .y = 0.0 });
        try source.cubicTo(.{ .x = 1e140, .y = -1e140 }, .{ .x = -2e140, .y = 3e140 }, .{ .x = 2, .y = -3 });
        try source.close();
        try source.moveTo(.{ .x = 0.0, .y = -0.0 });
        try source.cubicTo(.{ .x = -1e-140, .y = 1e-140 }, .{ .x = 2e-140, .y = -3e-140 }, .{ .x = -0.0, .y = 0.0 });
        try source.lineTo(.{ .x = 1e-140, .y = -1e-140 });
        if (closed) try source.close();
        var snapshot = try source.clone(allocator);
        defer snapshot.deinit();
        for ([_]g.Transform{
            .{},
            .{ .a = -0.0, .b = 0.0, .c = -0.0, .d = -0.0, .e = -0.0, .f = 0.0 },
            .{ .a = 1.25, .b = -0.5, .c = 0.25, .d = 2, .e = 10, .f = -30 },
            .{ .a = 1e140, .b = -1e140, .c = 1e140, .d = 1e140 },
            .{ .a = 1e-140, .b = -1e-140, .c = 1e-140, .d = 1e-140 },
        }) |placement| {
            var reference = try source.clone(allocator);
            defer reference.deinit();
            try reference.transform(placement);
            var actual = try source.transformed(allocator, placement);
            defer actual.deinit();
            try Check.path(reference, actual);
            try Check.path(snapshot, source);
        }
        try std.testing.expectError(error.NonFinite, source.transformed(allocator, .{ .a = std.math.nan(f64) }));
        try std.testing.expectError(error.NonFinite, source.transformed(allocator, .scaling(std.math.floatMax(f64), 1)));
        try std.testing.expectError(error.NonFinite, source.transform(.scaling(std.math.floatMax(f64), 1)));
        try Check.path(snapshot, source);
    }
    var empty = Path.init(allocator);
    defer empty.deinit();
    var transformed_empty = try empty.transformed(allocator, .{});
    defer transformed_empty.deinit();
    try Check.path(empty, transformed_empty);
}

fn exerciseFreshTransform(allocator: std.mem.Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = -2, .y = 4 }, .{ .x = 5, .y = -1 });
    var output = try source.transformed(allocator, .{ .a = 2, .d = -1, .e = 3 });
    defer output.deinit();
    try std.testing.expectEqual(@as(f64, 0), source.segments.items[0].move.x);
    try std.testing.expectEqual(@as(f64, 3), output.segments.items[0].move.x);
}

test "fresh transform releases every failed result allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFreshTransform, .{});
}
