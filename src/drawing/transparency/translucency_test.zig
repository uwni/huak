//! Tests of flattening translucent paints and layers over the paper and over opaque paints, and of releasing every allocation on failure.
const std = @import("std");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const transparency = @import("../transparency.zig");
const fixtures = @import("testing.zig");
const rectangle = fixtures.rectangle;
const flatten = transparency.flatten;
const expectOpaque = fixtures.expectOpaque;
const paths = fixtures.paths;
const expectSameColors = fixtures.expectSameColors;

test "a translucent fill on the paper becomes its color mixed with the paper" {
    const a = testing.allocator;
    var square = try rectangle(a, 0, 0, 10, 10);
    defer square.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.fill(square, .{ .color = .{ .r = 0.2, .g = 0.4, .b = 1, .a = 0.5 } }, .{});
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try testing.expectEqual(@as(usize, 1), paths(&result));
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -2, .y = -2 }, .max = .{ .x = 12, .y = 12 } }, 9);
}

test "a translucent fill over opaque ones repeats them in its colors and keeps their order" {
    const a = testing.allocator;
    var left = try rectangle(a, 0, 0, 10, 10);
    defer left.deinit();
    var right = try rectangle(a, 6, 2, 10, 6);
    defer right.deinit();
    var veil = try rectangle(a, 4, -2, 6, 14);
    defer veil.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.fill(left, .{ .color = .{ .r = 0.9, .g = 0.1, .b = 0.1 } }, .{});
    try source.fill(right, .{ .color = .{ .r = 0.1, .g = 0.6, .b = 0.2 } }, .{});
    try source.fill(veil, .{ .color = .{ .r = 0.1, .g = 0.2, .b = 0.9, .a = 0.4 } }, .{});
    var result = try flatten(a, &source, .{ .paper = .{ .r = 0.95, .g = 0.9, .b = 0.8 } }, null);
    defer result.deinit();
    try expectOpaque(&result);
    // The two originals, the veil over the paper, and the two in its colors.
    try testing.expectEqual(@as(usize, 5), paths(&result));
    try expectSameColors(&source, &result, .{ .r = 0.95, .g = 0.9, .b = 0.8 }, .{ .min = .{ .x = -1, .y = -3 }, .max = .{ .x = 17, .y = 13 } }, 17);
}

test "a layer flattens as one: its paints cover each other inside it" {
    const a = testing.allocator;
    var whole = try rectangle(a, 0, 0, 20, 10);
    defer whole.deinit();
    var lighter = try rectangle(a, 8, 0, 12, 10);
    defer lighter.deinit();
    var line = try rectangle(a, -5, 4, 30, 2);
    defer line.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.fill(line, .{ .color = .{ .r = 0.1, .g = 0.1, .b = 0.1 } }, .{});
    try source.beginLayer(.{}, null, 0.8);
    try source.fill(whole, .{ .color = .{ .r = 0.2, .g = 0.5, .b = 0.6 } }, .{});
    try source.fill(lighter, .{ .color = .{ .r = 0.6, .g = 0.8, .b = 0.85 } }, .{});
    try source.endScope();
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -6, .y = -1 }, .max = .{ .x = 26, .y = 11 } }, 23);
}

test "nested translucency repeats what lies under it once, not once per level" {
    const a = testing.allocator;
    var source = DisplayList.init(a);
    defer source.deinit();
    for (0..6) |k| {
        var bar = try rectangle(a, @floatFromInt(k * 3), 0, 2, 30);
        defer bar.deinit();
        try source.fill(bar, .{ .color = .{ .r = 0.1 * @as(f64, @floatFromInt(k)), .g = 0.3, .b = 0.2 } }, .{});
    }
    const veils = 10;
    for (0..veils) |k| {
        var veil = try rectangle(a, -1, @floatFromInt(k), 20, 30);
        defer veil.deinit();
        try source.fill(veil, .{ .color = .{ .r = 0.9, .g = 0.8 - 0.05 * @as(f64, @floatFromInt(k)), .b = 0.3, .a = 0.3 } }, .{});
    }
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 20, .y = 31 } }, 21);
    // Painting every combination would double the result with each veil.
    // Each veil shows only in the strip the next one leaves, where the ones
    // before it cover everything: one paint over the bars, and the bars.
    for ([_]usize{ 2, 4, 8, 16, 32 }) |count| {
        var stack = DisplayList.init(a);
        defer stack.deinit();
        for (0..6) |k| {
            var bar = try rectangle(a, @floatFromInt(k * 3), 0, 2, 30);
            defer bar.deinit();
            try stack.fill(bar, .{ .color = .{ .r = 0.1 * @as(f64, @floatFromInt(k)), .g = 0.3, .b = 0.2 } }, .{});
        }
        for (0..count) |k| {
            var veil = try rectangle(a, -1, @floatFromInt(k), 20, 30);
            defer veil.deinit();
            try stack.fill(veil, .{ .color = .{ .r = 0.9, .g = 0.5, .b = 0.3, .a = 0.3 } }, .{});
        }
        var flat = try flatten(a, &stack, .{}, null);
        defer flat.deinit();
        try testing.expect(paths(&flat) <= 6 + 8 * count + 5);
    }
}

test "translucent circles that all overlap one another composite as in the source" {
    // Many pieces of the plane, some of them slivers between nearly tangent
    // arcs, decide what shows. From eight circles on, a region kernel that
    // took two distant points for one crossing lost pieces.
    for ([_]usize{ 6, 8, 12, 16 }) |count| try overlappingCircles(count);
}

fn overlappingCircles(count: usize) !void {
    const a = testing.allocator;
    var source = DisplayList.init(a);
    defer source.deinit();
    for (0..5) |k| {
        var bar = try rectangle(a, @as(f64, @floatFromInt(k)) * 24 - 60, -50, 12, 100);
        defer bar.deinit();
        try source.fill(bar, .{ .color = .{ .r = 0.2 + 0.15 * @as(f64, @floatFromInt(k)), .g = 0.3, .b = 0.4 } }, .{});
    }
    for (0..count) |k| {
        const turn = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
        var disk = try Path.circle(a, .{ .x = 22 * @cos(turn), .y = 22 * @sin(turn) }, 30);
        defer disk.deinit();
        try source.fill(disk, .{ .color = .{ .r = 0.5 + 0.5 * @cos(turn), .g = 0.5, .b = 0.5 + 0.5 * @sin(turn), .a = 0.35 } }, .{});
    }
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -62, .y = -54 }, .max = .{ .x = 54, .y = 54 } }, 41);
}

fn allocationExercise(allocator: Allocator) !void {
    var left = try rectangle(allocator, 0, 0, 10, 10);
    defer left.deinit();
    var veil = try rectangle(allocator, 4, -2, 6, 14);
    defer veil.deinit();
    var source = DisplayList.init(allocator);
    defer source.deinit();
    try source.fill(left, .{ .color = .{ .r = 0.9 } }, .{});
    try source.beginLayer(.{}, null, 0.5);
    try source.fill(veil, .{ .color = .{ .b = 0.9 } }, .{});
    try source.fill(left, .{ .color = .{ .g = 0.9, .a = 0.5 } }, .{});
    try source.endScope();
    var result = try flatten(allocator, &source, .{}, null);
    result.deinit();
}

test "every allocation failure releases what was made" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationExercise, .{});
}
