//! Fill rules and boolean operations on repeated, reversed and self-crossing shapes.
const std = @import("std");
const t = std.testing;
const core = @import("drawing");
const Path = core.Path;
const harness = @import("harness.zig");

test "reference: rectangles curved lens coincidence and fine holes retain native thresholds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const a = try harness.rect(allocator, 0, 0, 10, 10);
    const b = try harness.rect(allocator, 5, 0, 10, 10);
    for (harness.operations, [_]f64{ 150, 50, 50, 100 }) |operation, expected| try harness.expectArea(allocator, a, b, operation, .nonzero, expected, 1e-10, "rectangle operation area");
    const c = try harness.circle(allocator, 45, 50, 35);
    const d = try harness.circle(allocator, 75, 50, 35);
    var lens = try core.region.combine(allocator, c, d, .intersect, .{});
    defer lens.deinit();
    var has_cubic = false;
    for (lens.segments.items) |segment| if (segment == .cubic) {
        has_cubic = true;
    };
    try t.expect(has_cubic);
    var difference = try core.region.combine(allocator, c, c, .difference, .{});
    defer difference.deinit();
    try t.expectEqual(@as(usize, 0), difference.segments.items.len);
    for ([_]f64{ 1e5, 1e6, 1e8 }) |span| {
        var result = try core.region.combine(allocator, try harness.rect(allocator, 0, 0, span, 100), try harness.rect(allocator, span * 0.75, 20, 0.001, 20), .difference, .{});
        defer result.deinit();
        var count: usize = 0;
        for (result.segments.items) |segment| if (segment == .move) {
            count += 1;
        };
        try t.expectEqual(@as(usize, 2), count);
    }
}

test "reference: four fill rules preserve repeated reverse and self crossing rectangle matrices" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const ccw = try harness.rect(allocator, 0, 0, 10, 10);
    // Keep the reference reverse's original final-vertex start position.
    const cw = try harness.polygon(allocator, &.{ .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 0 } });
    const twice = try harness.compound(allocator, ccw, ccw);
    const cancelled = try harness.compound(allocator, ccw, cw);
    const crossing = try harness.polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 10, 0 } });
    const upper = try harness.rect(allocator, -1, 5, 12, 6);
    const lower = try harness.rect(allocator, -1, -1, 12, 6);
    const ccw_expected = [_]f64{ 100, 100, 100, 0 };
    const cw_expected = [_]f64{ 100, 100, 0, 100 };
    const twice_expected = [_]f64{ 0, 100, 100, 0 };
    const crossing_expected = [_]f64{ 50, 50, 25, 25 };
    const upper_expected = [_]f64{ 25, 25, 25, 0 };
    const lower_expected = [_]f64{ 25, 25, 0, 25 };
    for (harness.rules, 0..) |rule, index| {
        try harness.expectArea(allocator, ccw, empty, .unite, rule, ccw_expected[index], 1e-9, "CCW fill rule");
        try harness.expectArea(allocator, cw, empty, .unite, rule, cw_expected[index], 1e-9, "CW fill rule");
        try harness.expectArea(allocator, twice, empty, .unite, rule, twice_expected[index], 1e-9, "same direction double winding");
        try harness.expectArea(allocator, cancelled, empty, .unite, rule, 0, 1e-9, "opposite winding cancellation");
        try harness.expectArea(allocator, crossing, empty, .unite, rule, crossing_expected[index], 1e-9, "self crossing fill rule");
        var resolved = try core.region.combine(allocator, crossing, empty, .unite, .{ .fill_rule = rule });
        defer resolved.deinit();
        try harness.expectArea(allocator, resolved, upper, .intersect, .nonzero, upper_expected[index], 1e-9, "self crossing upper lobe");
        try harness.expectArea(allocator, resolved, lower, .intersect, .nonzero, lower_expected[index], 1e-9, "self crossing lower lobe");
        for ([_]bool{ false, true }) |reverse| for (harness.operations) |operation| {
            const other = if (reverse) cw else ccw;
            const other_area = if (reverse) cw_expected[index] else ccw_expected[index];
            try harness.expectArea(allocator, ccw, other, operation, rule, harness.operationArea(operation, ccw_expected[index], other_area), 1e-9, "coincident rectangles each operand fill");
        };
    }
}

test "reference: four fill rules preserve all identical and reversed cubic operations" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const curve = try harness.circle(allocator, 12, 15, 10);
    const back = try curve.reverse(allocator);
    const curve_area = harness.area(curve);
    for (harness.rules) |rule| for ([_]bool{ false, true }) |reverse| for (harness.operations) |operation| {
        const a = if (rule == .negative) 0 else curve_area;
        const b = if (reverse) (if (rule == .positive) 0 else curve_area) else a;
        try harness.expectArea(allocator, curve, if (reverse) back else curve, operation, rule, harness.operationArea(operation, a, b), 1e-9, "coincident cubics each operand fill");
    };
}

test "reference: normalization preserves repeated traversal and overlapping contour winding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const overlapping = try harness.compound(allocator, try harness.rect(allocator, 0, 0, 10, 10), try harness.rect(allocator, 5, 0, 10, 10));
    // One contour visits the same boundary twice; its winding is two, not zero.
    const twice = try harness.polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } });
    for (harness.rules, [_]f64{ 100, 150, 150, 0 }, [_]f64{ 0, 100, 100, 0 }) |rule, overlap_area, twice_area| {
        try harness.expectArea(allocator, overlapping, empty, .unite, rule, overlap_area, 1e-9, "same-direction overlapping contours");
        try harness.expectArea(allocator, twice, empty, .unite, rule, twice_area, 1e-9, "twice-traversed contour");
    }
}
