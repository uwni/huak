//! Tests of dash placement: phases, odd patterns, resets, dots, arc length on cubics, curved controls and unrepresentable steps.
const std = @import("std");
const Path = @import("../../path/Path.zig");
const dash = @import("../dash.zig");

test "physical dash placement handles phases odd patterns and subpath resets" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 12, .y = 0 });
    try line.moveTo(.{ .x = 100, .y = 0 });
    try line.lineTo(.{ .x = 112, .y = 0 });
    var result = try dash.dashed(std.testing.allocator, line, &.{ 3, 2 }, 1, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(f64, 2), result.segments.items[1].line.x);
    try std.testing.expectEqual(@as(f64, 4), result.segments.items[2].move.x);
    try std.testing.expectEqual(@as(f64, 100), result.segments.items[6].move.x);
    var odd = try dash.dashed(std.testing.allocator, line, &.{3}, 0, .{});
    defer odd.deinit();
    try std.testing.expectEqual(@as(f64, 6), odd.segments.items[2].move.x);
}

test "zero on lengths preserve physical dots without infinite loops" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var dots = try dash.dashed(std.testing.allocator, line, &.{ 0, 5 }, 0, .{});
    defer dots.deinit();
    try std.testing.expectEqual(@as(usize, 6), dots.segments.items.len);
    try std.testing.expectEqual(@as(f64, 5), dots.segments.items[2].move.x);
    try std.testing.expectEqual(@as(f64, 10), dots.segments.items[5].line.x);
    try std.testing.expectError(error.InvalidDash, dash.dashed(std.testing.allocator, line, &.{ 0, 0 }, 0, .{}));
}

test "cubic dash distances follow arc length rather than Bezier time" {
    var cubic = Path.init(std.testing.allocator);
    defer cubic.deinit();
    try cubic.moveTo(.zero);
    try cubic.cubicTo(.zero, .zero, .{ .x = 100, .y = 0 });
    var result = try dash.dashed(std.testing.allocator, cubic, &.{ 50, 50 }, 0, .{});
    defer result.deinit();
    try std.testing.expect(result.segments.items[1] == .cubic);
    try std.testing.expectApproxEqAbs(@as(f64, 50), result.segments.items[1].cubic.end.x, 0.001);
}

test "physical dashes retain native curved controls and whole on cubics" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    var whole = try dash.dashed(std.testing.allocator, curve, &.{ 300, 10 }, 0, .{});
    defer whole.deinit();
    try std.testing.expectEqualSlices(Path.Segment, curve.segments.items, whole.segments.items);
    // This symmetric cubic has total arc length 200. The half-length cut is
    // t=1/2, whose de Casteljau controls are independently known exactly.
    var half = try dash.dashed(std.testing.allocator, curve, &.{ 100, 300 }, 0, .{ .tolerance = 1e-4 });
    defer half.deinit();
    try std.testing.expectEqual(@as(usize, 2), half.segments.items.len);
    try std.testing.expect(half.segments.items[1] == .cubic);
    const retained = half.segments.items[1].cubic;
    try std.testing.expectApproxEqAbs(@as(f64, 0), retained.c1.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 50), retained.c1.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 25), retained.c2.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 75), retained.c2.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 50), retained.end.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 75), retained.end.y, 1e-4);
    try std.testing.expectError(error.StrokeWorkLimit, dash.dashed(std.testing.allocator, curve, &.{ 10, 5 }, 0, .{ .max_depth = 0 }));
}

test "unrepresentable physical dash steps and invalid empty-pattern budgets fail" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = 1e20, .y = 0 });
    try line.lineTo(.{ .x = 1e20 + 1e6, .y = 0 });
    try std.testing.expectError(error.PrecisionRange, dash.dashed(std.testing.allocator, line, &.{ 1, 1 }, 0, .{}));
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.{ .x = 1e20, .y = 0 });
    try curve.cubicTo(.{ .x = 1e20 + 3e5, .y = 0 }, .{ .x = 1e20 + 6e5, .y = 0 }, .{ .x = 1e20 + 1e6, .y = 0 });
    // Permit the shared metric table's coordinate error at this magnitude;
    // the one-unit dash still cannot be represented by native curve points.
    try std.testing.expectError(error.PrecisionRange, dash.dashed(std.testing.allocator, curve, &.{ 1, 1 }, 0, .{ .tolerance = 1e5 }));
    try std.testing.expectError(error.InvalidTolerance, dash.dashed(std.testing.allocator, line, &.{}, 0, .{ .tolerance = 0 }));
}
