//! Rectangle clipping of regions and of linework.
const std = @import("std");
const core = @import("drawing");
const g = core.geometry;
const Path = core.Path;
const api = core.region;
const combine = api.combine;
const clipRegion = api.clipRegion;
const clipLines = api.clipLines;
const harness = @import("harness.zig");
const testRectangle = harness.testRectangle;
const area = harness.area;
const contourCount = harness.contourCount;

test "rectangle region clipping resolves a hole opening onto its boundary" {
    const t = std.testing;
    var outer = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    var inner = try testRectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    var ring = try combine(t.allocator, outer, inner, .difference, .{});
    defer ring.deinit();
    var clipped = try clipRegion(t.allocator, ring, .{ .min = .{ .x = 5, .y = -1 }, .max = .{ .x = 12, .y = 11 } }, .{});
    defer clipped.deinit();
    try t.expectApproxEqAbs(@as(f64, 32), area(clipped), 1e-7);
    try t.expectEqual(@as(usize, 1), contourCount(clipped));
}

test "line rectangle clipping keeps open fragments and implicit closing edges" {
    const t = std.testing;
    var closed = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer closed.deinit();
    var left = try clipLines(t.allocator, closed, .{ .min = .{ .x = -1, .y = 2 }, .max = .{ .x = 1, .y = 8 } }, .{});
    defer left.deinit();
    try t.expectEqual(@as(usize, 1), contourCount(left));
    try t.expectEqual(@as(usize, 1), left.segmentCount());
    try t.expect(left.open);
    const box = left.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 0), box.min.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 0), box.max.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 2), box.min.y, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 8), box.max.y, 1e-7);
}

test "line rectangle clipping retains boundary segments and drops point-only contacts" {
    const t = std.testing;
    const box = g.BBox.fromPoints(.zero, .{ .x = 1, .y = 1 });
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = -1, .y = 0 });
    try line.lineTo(.{ .x = 2, .y = 0 });
    var boundary = try clipLines(t.allocator, line, box, .{});
    defer boundary.deinit();
    try t.expectEqual(@as(usize, 1), boundary.segmentCount());
    try t.expectApproxEqAbs(@as(f64, 0), boundary.bounds().?.min.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 1), boundary.bounds().?.max.x, 1e-7);
    var touching = Path.init(t.allocator);
    defer touching.deinit();
    try touching.moveTo(.{ .x = -1, .y = 1 });
    try touching.lineTo(.{ .x = 1, .y = -1 });
    var contact = try clipLines(t.allocator, touching, box, .{});
    defer contact.deinit();
    try t.expectEqual(@as(usize, 0), contact.segmentCount());
}

test "line clipping retains physically nonempty short parameter intervals" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = -1e12, .y = 0 });
    try line.lineTo(.{ .x = 1e12, .y = 0 });
    const rectangle = g.BBox.fromPoints(.{ .x = 1, .y = -1 }, .{ .x = 1.01, .y = 1 });
    var clipped = try clipLines(t.allocator, line, rectangle, .{ .tolerance = 0.001 });
    defer clipped.deinit();
    try t.expectEqual(@as(usize, 1), clipped.segmentCount());
    try t.expectApproxEqAbs(@as(f64, 1), clipped.bounds().?.min.x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 1.01), clipped.bounds().?.max.x, 0.001);
}

test "fully retained closed linework still returns open fragments" {
    const t = std.testing;
    var square = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var result = try clipLines(t.allocator, square, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 11, .y = 11 }), .{});
    defer result.deinit();
    try t.expect(result.open);
    try t.expectEqual(@as(usize, 4), result.segmentCount());
    for (result.segments.items) |segment| try t.expect(segment != .close);
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try point.lineTo(.zero);
    var empty = try clipLines(t.allocator, point, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 1, .y = 1 }), .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.segments.items.len);
}
