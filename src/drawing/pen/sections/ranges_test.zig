//! Tests of requested stroke sections: real and artificial caps, dash phases and contour identities, and allocation failure.
const std = @import("std");
const Path = @import("../../path/Path.zig");
const Allocator = std.mem.Allocator;
const sections = @import("../sections.zig");

test "source stroke sections retain real caps and do not cap artificial boundaries" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    const result = try sections.extract(t.allocator, source, .{ .width = 2, .cap = .round }, &.{ .{ .contour = 0, .begin = 0, .end = 0.5 }, .{ .contour = 0, .begin = 0.5, .end = 1 } }, .{});
    defer {
        for (result) |*path| path.deinit();
        t.allocator.free(result);
    }
    try t.expectApproxEqAbs(@as(f64, -1), result[0].bounds().?.min.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 5), result[0].bounds().?.max.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5), result[1].bounds().?.min.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 11), result[1].bounds().?.max.x, 1e-3);
}

test "source section phase true dash caps and contour identities stay on the original path" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.moveTo(.{ .x = 100, .y = 0 });
    try source.lineTo(.{ .x = 120, .y = 0 });
    const output = try sections.extract(t.allocator, source, .{ .width = 2, .cap = .round, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &.{ .{ .contour = 0, .begin = 0.5, .end = 1 }, .{ .contour = 1, .begin = 1, .end = 1.5 } }, .{});
    defer {
        for (output) |*path| path.deinit();
        t.allocator.free(output);
    }
    try t.expectApproxEqAbs(@as(f64, 10), output[0].bounds().?.min.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 21), output[0].bounds().?.max.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 99), output[1].bounds().?.min.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 110), output[1].bounds().?.max.x, 1e-9);
    try t.expectError(error.InvalidSection, sections.extract(t.allocator, source, .{}, &.{.{ .contour = 1, .begin = 0, .end = 1 }}, .{}));
    try t.expectError(error.InvalidSection, sections.extract(t.allocator, source, .{}, &.{.{ .contour = 0, .begin = 0.5, .end = 0.5 }}, .{}));
}

fn allocationCase(allocator: Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    const result = try sections.extract(allocator, source, .{ .nib = @import("../nib.zig").Nib.square(), .cap = .round, .join = .bevel, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &.{ .{ .contour = 0, .begin = 0, .end = 1 }, .{ .contour = 0, .begin = 1, .end = 2 } }, .{});
    defer {
        for (result) |*path| path.deinit();
        allocator.free(result);
    }
    try std.testing.expect(result[0].segments.items.len != 0 and result[1].segments.items.len != 0);
}

test "source section coverage releases working data and partial results at every allocation failure" {
    try allocationCase(std.testing.allocator);
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationCase, .{});
    // The coverage owns its geometry and outlives the source.
    var source = Path.init(std.testing.allocator);
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    const results = try sections.extract(std.testing.allocator, source, .{ .width = 2, .cap = .square }, &.{.{ .contour = 0, .begin = 0, .end = 1 }}, .{});
    defer std.testing.allocator.free(results);
    var retained = results[0];
    source.deinit();
    defer retained.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 24), retained.signedArea(), 1e-5);
}
