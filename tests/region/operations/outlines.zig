//! Offsets and stroke outlines: expansion and contraction, caps and closed seams, two-point paths and point strokes.
const std = @import("std");
const core = @import("drawing");
const Path = core.Path;
const api = core.region;
const Join = api.Join;
const Cap = api.Cap;
const combine = api.combine;
const offset = api.offset;
const stroke = api.stroke;
const harness = @import("harness.zig");
const testRectangle = harness.testRectangle;
const area = harness.area;
const contourCount = harness.contourCount;

test "offset expands contracts and removes regions with their holes" {
    const t = std.testing;
    var outer = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    for ([_]f64{ 2, -2, -6 }, [_]f64{ 196, 36, 0 }) |distance, expected| {
        var result = try offset(t.allocator, outer, distance, .{ .join = .miter });
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 1e-7);
    }
    var inner = try testRectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    var ring = try combine(t.allocator, outer, inner, .difference, .{});
    defer ring.deinit();
    var expanded = try offset(t.allocator, ring, 1, .{ .join = .miter });
    defer expanded.deinit();
    try t.expectApproxEqAbs(@as(f64, 128), area(expanded), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(expanded));
    var vanished = try offset(t.allocator, ring, -1, .{ .join = .miter });
    defer vanished.deinit();
    try t.expectEqual(@as(usize, 0), vanished.segments.items.len);
    var duplicate = try ring.clone(t.allocator);
    defer duplicate.deinit();
    try ring.append(duplicate);
    var normalized = try offset(t.allocator, ring, 0, .{ .fill_rule = .evenodd });
    defer normalized.deinit();
    try t.expectEqual(@as(usize, 0), normalized.segments.items.len);
}

test "ordinary stroke outlines honor caps and closed seams in mixed input" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    for ([_]Cap{ .butt, .square, .round }, [_]f64{ 40, 56, 40 + 4 * std.math.pi }) |cap, expected| {
        var result = try stroke(t.allocator, line, 4, .{ .cap = cap });
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 0.01);
    }
    var closed = try testRectangle(t.allocator, 30, 0, 10, 10);
    defer closed.deinit();
    var outline = try stroke(t.allocator, closed, 2, .{ .join = .miter });
    defer outline.deinit();
    try t.expectApproxEqAbs(@as(f64, 80), area(outline), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(outline));
    try line.append(closed);
    var mixed = try stroke(t.allocator, line, 2, .{ .cap = .square, .join = .miter });
    defer mixed.deinit();
    try t.expectApproxEqAbs(@as(f64, 104), area(mixed), 1e-7);
    var zero = try stroke(t.allocator, line, 0, .{});
    defer zero.deinit();
    try t.expectEqual(@as(usize, 0), zero.segments.items.len);
}

test "a two-point closed path does not change the seam of later closed paths" {
    const t = std.testing;
    var pair = Path.init(t.allocator);
    defer pair.deinit();
    try pair.moveTo(.zero);
    try pair.lineTo(.{ .x = 10, .y = 0 });
    try pair.close();
    var square = try testRectangle(t.allocator, 30, 0, 10, 10);
    defer square.deinit();
    var both = try pair.clone(t.allocator);
    defer both.deinit();
    try both.append(square);
    for ([_]Join{ .miter, .round, .bevel, .square }) |join| {
        var first = try stroke(t.allocator, pair, 2, .{ .join = join });
        defer first.deinit();
        var second = try stroke(t.allocator, square, 2, .{ .join = join });
        defer second.deinit();
        var result = try stroke(t.allocator, both, 2, .{ .join = join });
        defer result.deinit();
        try t.expectApproxEqAbs(area(first) + area(second), area(result), 0.01);
        try t.expectEqual(contourCount(first) + contourCount(second), contourCount(result));
    }
}

test "point strokes use the cap rather than unrelated join choices" {
    const t = std.testing;
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try point.lineTo(.zero);
    for ([_]Join{ .miter, .round }) |join| {
        for ([_]Cap{ .butt, .round, .square }, [_]f64{ 0, 4 * std.math.pi, 16 }) |cap, expected| {
            var result = try stroke(t.allocator, point, 4, .{ .cap = cap, .join = join });
            defer result.deinit();
            try t.expectApproxEqAbs(expected, area(result), 0.01);
        }
    }
    try point.close();
    var closed = try stroke(t.allocator, point, 4, .{ .cap = .round, .join = .round });
    defer closed.deinit();
    try t.expectEqual(@as(usize, 0), closed.segments.items.len);
}
