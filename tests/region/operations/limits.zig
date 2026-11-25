//! Validation and limits: empty regions, vertex and segment budgets, precision and work limits, allocation failure.
const std = @import("std");
const core = @import("drawing");
const Path = core.Path;
const api = core.region;
const Allocator = std.mem.Allocator;
const Operation = api.Operation;
const combine = api.combine;
const offset = api.offset;
const stroke = api.stroke;
const clipRegion = api.clipRegion;
const clipLines = api.clipLines;
const harness = @import("harness.zig");
const testRectangle = harness.testRectangle;
const area = harness.area;

test "empty and zero-area regions remain empty and every contour must close" {
    const t = std.testing;
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    for ([_]Operation{ .unite, .intersect, .difference, .xor }) |operation| {
        var result = try combine(t.allocator, empty, empty, operation, .{});
        defer result.deinit();
        try t.expectEqual(@as(usize, 0), result.segments.items.len);
    }
    var collinear = Path.init(t.allocator);
    defer collinear.deinit();
    try collinear.moveTo(.zero);
    try collinear.lineTo(.{ .x = 10, .y = 0 });
    try collinear.lineTo(.{ .x = 20, .y = 0 });
    try collinear.close();
    var collapsed = try combine(t.allocator, collinear, empty, .unite, .{});
    defer collapsed.deinit();
    try t.expectEqual(@as(usize, 0), collapsed.segments.items.len);
    try collinear.moveTo(.zero);
    try collinear.moveTo(.{ .x = 5, .y = 5 });
    try collinear.close();
    try t.expectError(error.OpenPath, offset(t.allocator, collinear, 1, .{}));
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try t.expectError(error.OpenPath, combine(t.allocator, point, empty, .unite, .{}));
    try point.close();
    var closed_point = try offset(t.allocator, point, 1, .{});
    defer closed_point.deinit();
    try t.expectEqual(@as(usize, 0), closed_point.segments.items.len);
}

test "region vertex budgets count coordinates independently of close markers" {
    const t = std.testing;
    var square = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    var result = try combine(t.allocator, square, empty, .unite, .{ .max_vertices = 4 });
    defer result.deinit();
    try t.expectApproxEqAbs(@as(f64, 100), area(result), 1e-7);
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, square, empty, .unite, .{ .max_vertices = 3 }));
}

test "region validation precision and aggregate work limits are explicit" {
    const t = std.testing;
    var a = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer a.deinit();
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    var open = Path.init(t.allocator);
    defer open.deinit();
    try open.moveTo(.zero);
    try open.lineTo(.{ .x = 10, .y = 0 });
    try t.expectError(error.OpenPath, combine(t.allocator, open, a, .unite, .{}));
    try t.expectError(error.OpenPath, offset(t.allocator, open, 1, .{}));
    try t.expectError(error.OpenPath, clipRegion(t.allocator, open, .fromPoints(.zero, .{ .x = 10, .y = 10 }), .{}));
    try t.expectError(error.InvalidTolerance, combine(t.allocator, a, empty, .unite, .{ .tolerance = 0 }));
    try t.expectError(error.InvalidWidth, stroke(t.allocator, open, -1, .{}));
    try t.expectError(error.PrecisionRange, stroke(t.allocator, open, @bitCast(@as(u64, 1)), .{}));
    try t.expectError(error.InvalidOffset, offset(t.allocator, a, std.math.inf(f64), .{}));
    try t.expectError(error.InvalidMiterLimit, offset(t.allocator, a, 1, .{ .miter_limit = 0 }));
    try t.expectError(error.InvalidRectangle, clipRegion(t.allocator, a, .{ .min = .{ .x = 2, .y = 0 }, .max = .{ .x = 1, .y = 1 } }, .{}));
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, a, a, .unite, .{ .max_segments = 6 }));
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, a, a, .unite, .{ .max_vertices = 6 }));
    var huge = try testRectangle(t.allocator, 1e16, 0, 100, 100);
    defer huge.deinit();
    try t.expectError(error.PrecisionRange, offset(t.allocator, huge, 0, .{}));
    var horizontal = try testRectangle(t.allocator, 0, 4, 10, 2);
    defer horizontal.deinit();
    var vertical = try testRectangle(t.allocator, 4, 0, 2, 10);
    defer vertical.deinit();
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, horizontal, vertical, .unite, .{ .max_vertices = 8 }));
}

fn allocationExercise(allocator: Allocator) !void {
    var a = try testRectangle(allocator, 0, 0, 10, 10);
    defer a.deinit();
    var b = try testRectangle(allocator, 3, 3, 10, 10);
    defer b.deinit();
    var united = try combine(allocator, a, b, .unite, .{});
    defer united.deinit();
    var expanded = try offset(allocator, united, 1, .{});
    defer expanded.deinit();
    var outline = try stroke(allocator, a, 2, .{});
    defer outline.deinit();
    var clipped = try clipRegion(allocator, expanded, .fromPoints(.zero, .{ .x = 10, .y = 10 }), .{});
    defer clipped.deinit();
    var lines = try clipLines(allocator, a, .fromPoints(.zero, .{ .x = 5, .y = 5 }), .{});
    defer lines.deinit();
}

test "allocation failures release prepared paths native results and copied contours" {
    // In-place arena/list growth can change the allocation count with the
    // backing allocator's address layout. Force growth to allocate and copy,
    // so every allocation is a deterministic failure-injection point.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}

test "source segment limits do not count derived stroke and offset boundaries again" {
    const t = std.testing;
    var rectangle = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer rectangle.deinit();
    const options: api.Options = .{ .max_segments = 4, .join = .miter };
    var outline = try stroke(t.allocator, rectangle, 2, options);
    defer outline.deinit();
    try t.expectApproxEqAbs(@as(f64, 80), area(outline), 1e-7);
    var expanded = try offset(t.allocator, rectangle, 2, options);
    defer expanded.deinit();
    try t.expectApproxEqAbs(@as(f64, 196), area(expanded), 1e-7);
    try t.expectError(error.GeometryWorkLimit, stroke(t.allocator, rectangle, 2, .{ .max_segments = 3 }));
    try t.expectError(error.GeometryWorkLimit, stroke(t.allocator, rectangle, 0, .{ .max_vertices = 3 }));
}
