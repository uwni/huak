//! Tests of directed envelopes against MetaPost: original knots and controls, clockwise cycles, caps and joins, singleton and zero segments, pen kinds, miter clamping, allocation failure.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const nibs = @import("../nib.zig");
const styles = @import("../stroke.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
const pen_envelope = @import("../envelope.zig");
const testing = @import("testing.zig");
const envelope = pen_envelope.envelope;
const test_nib = testing.test_nib;
const expectTestPoint = testing.expectTestPoint;
const testWinding = testing.testWinding;
const Options = pen_envelope.Options;
const stroke = pen_envelope.stroke;

test "directed envelope retains the original knot and MetaPost full cubic controls" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .zero);
    try source.close();
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    // MetaPost 3.00 double: envelope (pensquare xscaled 4 yscaled 2)
    // of ((0,0)..controls (10,0) and (10,10)..cycle), rounded join.
    // Every retained knot/control is checked, including the original join.
    const expected = [_]Path.Segment{
        .{ .move = .{ .x = -2, .y = 1 } },
        .{ .line = .{ .x = -2, .y = -1 } },
        .{ .line = .{ .x = 2, .y = -1 } },
        .{ .cubic = .{ .c1 = .{ .x = 7, .y = -1 }, .c2 = .{ .x = 9.5, .y = 1.5 }, .end = .{ .x = 9.5, .y = 2.75 } } },
        .{ .line = .{ .x = 9.5, .y = 4.75 } },
        .{ .cubic = .{ .c1 = .{ .x = 9.5, .y = 31.0 / 6.0 }, .c2 = .{ .x = 83.0 / 9.0, .y = 49.0 / 9.0 }, .end = .{ .x = 26.0 / 3.0, .y = 49.0 / 9.0 } } },
        .{ .line = .{ .x = 14.0 / 3.0, .y = 49.0 / 9.0 } },
        .{ .cubic = .{ .c1 = .{ .x = 32.0 / 9.0, .y = 49.0 / 9.0 }, .c2 = .{ .x = 4.0 / 3.0, .y = 13.0 / 3.0 }, .end = .{ .x = -2, .y = 1 } } },
        .close,
    };
    try std.testing.expectEqual(expected.len, result.segments.items.len);
    for (expected, result.segments.items) |wanted, actual| {
        try std.testing.expectEqual(std.meta.activeTag(wanted), std.meta.activeTag(actual));
        switch (wanted) {
            .move => |point| try expectTestPoint(point, actual.move),
            .line => |point| try expectTestPoint(point, actual.line),
            .cubic => |curve| {
                try expectTestPoint(curve.c1, actual.cubic.c1);
                try expectTestPoint(curve.c2, actual.cubic.c2);
                try expectTestPoint(curve.end, actual.cubic.end);
            },
            .close => {},
        }
    }
    // The other directed side has different translated controls; it is not
    // the complete stroke or a reversal of the already-offset result.
    var reversed = try source.reverse(allocator);
    defer reversed.deinit();
    var other = try envelope(allocator, .{ .polygon = &test_nib }, reversed, .{});
    defer other.deinit();
    const other_cubics = [_]g.Cubic{
        .{ .p0 = .{ .x = 2, .y = -1 }, .p1 = .{ .x = 16.0 / 3.0, .y = 7.0 / 3.0 }, .p2 = .{ .x = 68.0 / 9.0, .y = 31.0 / 9.0 }, .p3 = .{ .x = 26.0 / 3.0, .y = 31.0 / 9.0 } },
        .{ .p0 = .{ .x = 14.0 / 3.0, .y = 31.0 / 9.0 }, .p1 = .{ .x = 47.0 / 9.0, .y = 31.0 / 9.0 }, .p2 = .{ .x = 5.5, .y = 19.0 / 6.0 }, .p3 = .{ .x = 5.5, .y = 2.75 } },
        .{ .p0 = .{ .x = 5.5, .y = 4.75 }, .p1 = .{ .x = 5.5, .y = 3.5 }, .p2 = .{ .x = 3, .y = 1 }, .p3 = .{ .x = -2, .y = 1 } },
    };
    var index: usize = 0;
    var current: Point = .zero;
    for (other.segments.items) |segment| switch (segment) {
        .move, .line => |point| current = point,
        .cubic => |curve| {
            try std.testing.expect(index < other_cubics.len);
            const wanted = other_cubics[index];
            try expectTestPoint(wanted.p0, current);
            try expectTestPoint(wanted.p1, curve.c1);
            try expectTestPoint(wanted.p2, curve.c2);
            try expectTestPoint(wanted.p3, curve.end);
            current = curve.end;
            index += 1;
        },
        .close => {},
    };
    try std.testing.expectEqual(other_cubics.len, index);
}

test "clockwise directed cycles preserve MetaPost first offset correction" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 20, .y = 0 });
    try source.cubicTo(.{ .x = 20, .y = -11 }, .{ .x = 11, .y = -20 }, .{ .x = 0, .y = -20 });
    try source.cubicTo(.{ .x = -11, .y = -20 }, .{ .x = -20, .y = -11 }, .{ .x = -20, .y = 0 });
    try source.cubicTo(.{ .x = -20, .y = 11 }, .{ .x = -11, .y = 20 }, .{ .x = 0, .y = 20 });
    try source.cubicTo(.{ .x = 11, .y = 20 }, .{ .x = 20, .y = 11 }, .{ .x = 20, .y = 0 });
    try source.close();
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    // Independent mp_offset_prep behavior: the seam's change is +3, not -1.
    // These three pen edges form a visible stub, not an ignorable retracing.
    const start = [_]Point{ .{ .x = 18, .y = -1 }, .{ .x = 22, .y = -1 }, .{ .x = 22, .y = 1 }, .{ .x = 18, .y = 1 } };
    try expectTestPoint(start[0], result.segments.items[0].move);
    for (start[1..], result.segments.items[1..4]) |wanted, actual| try expectTestPoint(wanted, actual.line);
    const expected = [_]g.Cubic{
        .{ .p0 = .{ .x = 18, .y = 1 }, .p1 = .{ .x = 18, .y = -10 }, .p2 = .{ .x = 9, .y = -19 }, .p3 = .{ .x = -2, .y = -19 } },
        .{ .p0 = .{ .x = 2, .y = -19 }, .p1 = .{ .x = -9, .y = -19 }, .p2 = .{ .x = -18, .y = -10 }, .p3 = .{ .x = -18, .y = 1 } },
        .{ .p0 = .{ .x = -18, .y = -1 }, .p1 = .{ .x = -18, .y = 10 }, .p2 = .{ .x = -9, .y = 19 }, .p3 = .{ .x = 2, .y = 19 } },
        .{ .p0 = .{ .x = -2, .y = 19 }, .p1 = .{ .x = 9, .y = 19 }, .p2 = .{ .x = 18, .y = 10 }, .p3 = .{ .x = 18, .y = -1 } },
    };
    var current: Point = .zero;
    var index: usize = 0;
    for (result.segments.items) |segment| switch (segment) {
        .move, .line => |point| current = point,
        .cubic => |curve| {
            try std.testing.expect(index < expected.len);
            try expectTestPoint(expected[index].p0, current);
            try expectTestPoint(expected[index].p1, curve.c1);
            try expectTestPoint(expected[index].p2, curve.c2);
            try expectTestPoint(expected[index].p3, curve.end);
            current = curve.end;
            index += 1;
        },
        .close => {},
    };
    try std.testing.expectEqual(expected.len, index);
    try std.testing.expect(testWinding(result, .{ .x = 21, .y = 0 }) != 0);
    var bevel = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .bevel });
    defer bevel.deinit();
    try std.testing.expectEqual(@as(i32, 0), testWinding(bevel, .{ .x = 21, .y = 0 }));
}

test "open directed envelopes reuse every cap and join of complete strokes" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 20 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| for ([_]styles.Join{ .miter, .round, .bevel }) |join| {
        const options: Options = .{ .cap = cap, .join = join };
        var directed = try envelope(allocator, .{ .polygon = &test_nib }, source, options);
        defer directed.deinit();
        var complete = try stroke(allocator, &test_nib, source, options);
        defer complete.deinit();
        try std.testing.expectEqualDeep(complete.segments.items, directed.segments.items);
    };
}

test "directed envelope follows MetaPost singleton and zero segment rules" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 5, .y = 7 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| {
        var point = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .cap = cap });
        defer point.deinit();
        try std.testing.expectEqual(@as(usize, if (cap == .round) 5 else 2), point.segmentCount());
        try expectTestPoint(.{ .x = 3, .y = 6 }, point.segments.items[0].move);
    }
    try source.lineTo(.{ .x = 5, .y = 7 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| {
        var zero = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .cap = cap });
        defer zero.deinit();
        try std.testing.expectEqual(@as(usize, 2), zero.segmentCount());
        try std.testing.expectEqual(Point{ .x = 3, .y = 6 }, zero.bounds().?.min);
        try std.testing.expectEqual(zero.bounds().?.min, zero.bounds().?.max);
    }
    try source.close();
    for ([_]styles.Join{ .miter, .round, .bevel }) |join| {
        var closed = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = join });
        defer closed.deinit();
        try std.testing.expectEqual(@as(usize, if (join == .round) 5 else 2), closed.segmentCount());
    }
}

test "directed envelope rejects ellipse and point pens but accepts line pens" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    var empty = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.segments.items.len);
    try std.testing.expectError(error.EllipticalPen, envelope(allocator, nibs.Nib.circle(), source, .{}));
    try std.testing.expectError(error.EllipticalPen, envelope(allocator, .{ .polygon = &.{.zero} }, source, .{}));
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 0, .y = 10 });
    var line = try envelope(allocator, .{ .polygon = &.{ .zero, .{ .x = 2, .y = 0 } } }, source, .{});
    defer line.deinit();
    try std.testing.expect(testWinding(line, .{ .x = 1, .y = 5 }) != 0);
    try source.segments.append(allocator, .{ .cubic = .{ .c1 = .zero, .c2 = .zero, .end = .{ .x = std.math.inf(f64), .y = 0 } } });
    try std.testing.expectError(error.NonFinite, envelope(allocator, .{ .polygon = &test_nib }, source, .{}));
}

test "only directed envelope clamps finite miter limits as MetaPost does" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 5, .y = 5 });
    var baseline = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .miter, .miter_limit = 1 });
    defer baseline.deinit();
    for ([_]f64{ -3, 0, 0.5 }) |limit| {
        var clamped = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .miter, .miter_limit = limit });
        defer clamped.deinit();
        try std.testing.expectEqualDeep(baseline.segments.items, clamped.segments.items);
        try std.testing.expectError(error.InvalidStroke, stroke(allocator, &test_nib, source, .{ .miter_limit = limit }));
    }
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |limit| {
        try std.testing.expectError(error.InvalidStroke, envelope(allocator, .{ .polygon = &test_nib }, source, .{ .miter_limit = limit }));
    }
}

fn allocationCaseDirected(allocator: Allocator) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .zero);
    try source.close();
    try source.moveTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 30, .y = 0 });
    try source.moveTo(.{ .x = 40, .y = 0 });
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    source.segments.clearRetainingCapacity();
    try std.testing.expect(result.segments.items.len != 0);
}

test "directed envelope snapshots and temporary storage survive all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCaseDirected, .{});
}
