//! Tests of picture-level coverage: label resolution, work budgets, allocation failure and the public region conversion.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const DisplayList = @import("../../DisplayList.zig");
const pen = @import("../../pen/root.zig");
const Allocator = std.mem.Allocator;
const coverage = @import("../coverage.zig");
const testing = @import("testing.zig");
const rectangle = testing.rectangle;
const extractFixture = testing.extractFixture;
const area = testing.area;
const extract = coverage.extract;
const contains = testing.contains;

const TestLabels = struct {
    calls: *usize,
    pub fn resolveOutline(self: @This(), allocator: Allocator, reference: u32) !DisplayList {
        self.calls.* += 1;
        if (reference != 7) return error.UnknownTestReference;
        var result = DisplayList.init(allocator);
        errdefer result.deinit();
        var glyph = try rectangle(allocator, 0, 0, 10, 10);
        defer glyph.deinit();
        var clip = try rectangle(allocator, 0, 0, 5, 10);
        defer clip.deinit();
        try result.beginScope(.{}, clip);
        try result.fill(glyph, .black, .{});
        try result.endScope();
        return result;
    }
};

test "label resolution composes frame-local transforms with ancestor clips and releases temporary pictures" {
    const t = std.testing;
    var clip = try rectangle(t.allocator, 10, 20, 5, 5);
    defer clip.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.beginScope(g.Transform.translation(100, 50), clip);
    try pic.labelAtBaseline(7, .{ .width = 10, .height = 10, .baseline = 8 }, .{ .x = 10, .y = 17 }, .{});
    try pic.endScope();
    try t.expectError(error.LabelResolverRequired, extractFixture(t.allocator, .{ .picture = &pic }, .{}, null));
    var calls: usize = 0;
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{}, TestLabels{ .calls = &calls });
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), calls);
    try t.expectEqual(@as(usize, 1), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 25), area(result.paths[0]), 1e-8);
    try t.expectEqual(g.Point{ .x = 110, .y = 70 }, result.paths[0].bounds().?.min);
    try t.expectEqual(g.Point{ .x = 115, .y = 75 }, result.paths[0].bounds().?.max);
}

test "work budgets accumulate across independent picture commands" {
    const t = std.testing;
    var square = try rectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var one = try extractFixture(t.allocator, .{ .path = square }, .{ .max_segments = 20, .max_vertices = 20 }, null);
    defer one.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.fill(square, .black, .{});
    try pic.fill(square, .black, g.Transform.translation(20, 0));
    try t.expectError(error.GeometryWorkLimit, extractFixture(t.allocator, .{ .picture = &pic }, .{ .max_segments = 14 }, null));
    try t.expectError(error.GeometryWorkLimit, extractFixture(t.allocator, .{ .picture = &pic }, .{ .max_vertices = 14 }, null));
    try t.expectError(error.InvalidTolerance, extractFixture(t.allocator, .{ .path = square }, .{ .tolerance = 0 }, null));
    var invalid = Path.init(t.allocator);
    defer invalid.deinit();
    try invalid.segments.append(t.allocator, .{ .line = .zero });
    try t.expectError(error.InvalidPath, extractFixture(t.allocator, .{ .styled = .{ .path = invalid, .style = .{ .fill = .{ .color = .{ .a = 0 } } } } }, .{}, null));
    try t.expectError(error.GroupNestingTooDeep, recursionExercise(t.allocator));
}

const RecursiveLabels = struct {
    pub fn resolveOutline(_: @This(), allocator: Allocator, _: u32) !DisplayList {
        var pic = DisplayList.init(allocator);
        errdefer pic.deinit();
        try pic.addLabel(0, .{ .width = 1, .height = 1, .baseline = 0 }, .{});
        return pic;
    }
};

fn recursionExercise(allocator: Allocator) !void {
    var pic = try RecursiveLabels.resolveOutline(.{}, allocator, 0);
    defer pic.deinit();
    var result = try extractFixture(allocator, .{ .picture = &pic }, .{}, RecursiveLabels{});
    defer result.deinit();
}

fn allocationExercise(allocator: Allocator) !void {
    var path = try rectangle(allocator, 0, 0, 10, 10);
    defer path.deinit();
    var pic = DisplayList.init(allocator);
    defer pic.deinit();
    try pic.beginScope(.{}, path);
    try pic.filldraw(path, .black, .{ .nib = pen.Nib.square(), .dash = &.{ 3, 2 } }, .{});
    try pic.labelAtBaseline(7, .{ .width = 10, .height = 10, .baseline = 8 }, .{ .x = 1, .y = 0 }, .{});
    try pic.endScope();
    var calls: usize = 0;
    var result = try extractFixture(allocator, .{ .picture = &pic }, .{}, TestLabels{ .calls = &calls });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
}

test "extraction unwinds all owned paths clips labels and collections on allocation failure" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}

fn publicRegionExercise(allocator: Allocator) !void {
    var square = try rectangle(allocator, 0, 0, 10, 10);
    defer square.deinit();
    var reversed = try square.reverse(allocator);
    defer reversed.deinit();
    var ring = try rectangle(allocator, 20, 0, 10, 10);
    defer ring.deinit();
    var hole = try rectangle(allocator, 22, 2, 6, 6);
    defer hole.deinit();
    try ring.append(hole);
    var source = DisplayList.init(allocator);
    defer source.deinit();
    try source.fill(square, .black, .{});
    try source.fill(reversed, .black, g.Transform.translation(5, 0));
    try source.addPath(ring, .{ .fill = .black, .fill_rule = .evenodd }, .{});
    try source.fill(square, .{ .color = .{ .a = 0 } }, g.Transform.translation(40, 0));
    var result = try extract(allocator, &source, .{});
    defer result.deinit();
    source.storage.segments.clearRetainingCapacity();
    try std.testing.expect(contains(result, .{ .x = 7, .y = 5 }));
    try std.testing.expect(contains(result, .{ .x = 12, .y = 5 }));
    try std.testing.expect(contains(result, .{ .x = 21, .y = 1 }));
    try std.testing.expect(!contains(result, .{ .x = 25, .y = 5 }));
    try std.testing.expect(!contains(result, .{ .x = 45, .y = 5 }));
}

test "public region conversion keeps independent winding and frees aggregation storage on OOM" {
    try publicRegionExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), publicRegionExercise, .{});
}
