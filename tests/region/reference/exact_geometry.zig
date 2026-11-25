//! Exact glyph-outline cuts and binary64 Path retention.
const std = @import("std");
const t = std.testing;
const core = @import("drawing");
const Path = core.Path;
const Point = core.geometry.Point;
const harness = @import("harness.zig");

fn cubic(path: *Path, points: [3][2]f64) !void {
    try path.cubicTo(.{ .x = points[0][0], .y = points[0][1] }, .{ .x = points[1][0], .y = points[1][1] }, .{ .x = points[2][0], .y = points[2][1] });
}

test "reference: exact glyph O boundary cut retains its counter without installed fonts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const domain = try harness.polygon(allocator, &.{
        .{ -0.78132812500000004, -0.54656249999999995 },
        .{ 0.78132812499999993, -0.54656249999999995 },
        .{ 0.78132812499999993, 0.54734375000000002 },
        .{ -0.78132812500000004, 0.54734375000000002 },
    });
    var glyph = Path.init(allocator);
    try glyph.moveTo(.{ .x = -0.75168749999999995, .y = -0.48993749999999991 });
    try cubic(&glyph, .{ .{ -0.76835937499999996, -0.48993749999999991 }, .{ -0.77807031250000003, -0.50317187499999994 }, .{ -0.77807031250000003, -0.51984374999999994 } });
    try cubic(&glyph, .{ .{ -0.77807031250000003, -0.53677343749999995 }, .{ -0.76578124999999997, -0.54734374999999991 }, .{ -0.75117187500000004, -0.54734374999999991 } });
    try cubic(&glyph, .{ .{ -0.74163281250000002, -0.54734374999999991 }, .{ -0.73407031249999999, -0.54321874999999986 }, .{ -0.72934374999999996, -0.53651562499999994 } });
    try cubic(&glyph, .{ .{ -0.72590624999999998, -0.53161718749999987 }, .{ -0.72401562500000005, -0.52542968749999996 }, .{ -0.72401562500000005, -0.51821093749999991 } });
    try cubic(&glyph, .{ .{ -0.72401562500000005, -0.5004218749999999 }, .{ -0.7363046875, -0.48993749999999991 }, .{ -0.75168749999999995, -0.48993749999999991 } });
    try glyph.close();
    try glyph.moveTo(.{ .x = -0.73226562500000003, .y = -0.51984374999999994 });
    try cubic(&glyph, .{ .{ -0.73226562500000003, -0.53522656249999989 }, .{ -0.73965625000000002, -0.5442499999999999 }, .{ -0.74945312500000005, -0.5442499999999999 } });
    try cubic(&glyph, .{ .{ -0.75993750000000004, -0.5442499999999999 }, .{ -0.76982031250000005, -0.53488281249999992 }, .{ -0.76982031250000005, -0.51838281249999996 } });
    try cubic(&glyph, .{ .{ -0.76982031250000005, -0.50033593749999994 }, .{ -0.76131249999999995, -0.49303124999999992 }, .{ -0.75280468749999996, -0.49303124999999992 } });
    try cubic(&glyph, .{ .{ -0.74146093749999997, -0.49303124999999992 }, .{ -0.73226562500000003, -0.50248437499999987 }, .{ -0.73226562500000003, -0.51984374999999994 } });
    try glyph.close();
    var result = try core.region.combine(allocator, domain, glyph, .difference, .{});
    defer result.deinit();
    var components: usize = 0;
    var cubics: usize = 0;
    var start: usize = 0;
    for (result.segments.items, 0..) |segment, index| switch (segment) {
        .move => start = index,
        .cubic => cubics += 1,
        .close => {
            try t.expect(harness.segmentArea(result.segments.items[start .. index + 1]) > 0);
            components += 1;
        },
        .line => {},
    };
    try t.expectEqual(@as(usize, 2), components);
    try t.expect(cubics >= 9);
    const probes = [_]struct { x: f64, y: f64, expected: f64, name: []const u8 }{
        .{ .x = -0.70, .y = -0.52, .expected = 4e-8, .name = "glyph cut keeps surrounding canvas" },
        .{ .x = -0.751, .y = -0.519, .expected = 4e-8, .name = "glyph cut keeps the counter island" },
        .{ .x = -0.775, .y = -0.52, .expected = 0, .name = "glyph cut removes the left stroke" },
        .{ .x = -0.750, .y = -0.545, .expected = 0, .name = "glyph cut removes the bottom stroke" },
        .{ .x = -0.79, .y = -0.50, .expected = 0, .name = "glyph cut preserves the domain boundary" },
    };
    for (probes) |probe| try harness.expectArea(allocator, result, try harness.rect(allocator, probe.x, probe.y, 0.0002, 0.0002), .intersect, .nonzero, probe.expected, 1e-9, probe.name);
}

test "reference: owned Path retains binary64 controls reversal and explicit close semantics" {
    // This carries the C++ container test's geometric intent. The removed
    // legacy iterator's synthetic line records are not a public Path API.
    const base = 1e12;
    const detail = 0.001;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = base, .y = base });
    try source.lineTo(.{ .x = base + detail, .y = base });
    try source.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    try t.expectEqual(@as(f64, base + detail), source.segments.items[1].line.x);
    try t.expectEqual(Point{ .x = 1, .y = 2 }, source.segments.items[2].cubic.c1);
    try t.expectEqual(Point{ .x = 3, .y = 4 }, source.segments.items[2].cubic.c2);
    try t.expectEqual(Point{ .x = 5, .y = 6 }, source.segments.items[2].cubic.end);
    var reversed = try source.reverse(t.allocator);
    defer reversed.deinit();
    var restored = try reversed.reverse(t.allocator);
    defer restored.deinit();
    try t.expectEqualDeep(source.segments.items, restored.segments.items);
    try source.close();
    try t.expect(!source.open);
    try t.expect(source.segments.items[source.segments.items.len - 1] == .close);
    try t.expectEqual(@as(usize, 3), source.segmentCount());
}
