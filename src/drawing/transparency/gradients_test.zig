//! Tests of translucency over gradients and patch paints: new stops, ramps composed into one, colors at patch corners, and paints that cover only their patches.
const std = @import("std");
const g = @import("../geometry.zig");
const DisplayList = @import("../DisplayList.zig");
const style = @import("../style.zig");
const Gradient = style.Gradient;
const testing = std.testing;
const transparency = @import("../transparency.zig");
const fixtures = @import("testing.zig");
const rectangle = fixtures.rectangle;
const flatten = transparency.flatten;
const expectOpaque = fixtures.expectOpaque;
const expectSameColors = fixtures.expectSameColors;
const plane = fixtures.plane;
const bilinearField = fixtures.bilinearField;

test "a gradient under a translucent fill keeps its geometry and gets new stops" {
    const a = testing.allocator;
    var band = try rectangle(a, 0, 0, 30, 10);
    defer band.deinit();
    var veil = try rectangle(a, 10, -1, 10, 12);
    defer veil.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    const ramp: Gradient = .{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 30, .y = 0 }, .colors = &.{ .{ .r = 1, .g = 0.2, .b = 0.1, .a = 0.3 }, .{ .r = 0.1, .g = 0.3, .b = 1, .a = 1 } }, .offsets = &.{ 0, 1 } } };
    try source.addPath(band, .{ .fill = .{ .gradient = &ramp } }, .{});
    try source.fill(veil, .{ .color = .{ .r = 0.2, .g = 0.9, .b = 0.3, .a = 0.5 } }, .{});
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    // Its opacity varies, so the composite curves and stops are inserted.
    var stops: usize = 0;
    for (result.commands.items) |command| if (command == .path) if (command.path.style.gradientFor(.fill)) |gradient| {
        stops = @max(stops, gradient.linear.colors.len);
    };
    try testing.expect(stops > 2);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -1, .y = -2 }, .max = .{ .x = 31, .y = 12 } }, 31);
}

test "ramps on one line composite into one ramp, and on different lines are refused" {
    const a = testing.allocator;
    var band = try rectangle(a, 0, 0, 30, 10);
    defer band.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    const under: Gradient = .{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 30, .y = 0 }, .colors = &.{ .{ .r = 0.9, .g = 0.2, .b = 0.1 }, .{ .r = 0.2, .g = 0.3, .b = 0.9 }, .{ .r = 0.1, .g = 0.8, .b = 0.3 } }, .offsets = &.{ 0, 0.4, 1 } } };
    // With a step at 0.7.
    const veil: Gradient = .{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 30, .y = 0 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0.9 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.1 }, .{ .r = 0, .g = 0, .b = 0, .a = 0.6 }, .{ .r = 0, .g = 0, .b = 0, .a = 0.2 } }, .offsets = &.{ 0, 0.7, 0.7, 1 } } };
    try source.addPath(band, .{ .fill = .{ .gradient = &under } }, .{});
    try source.addPath(band, .{ .fill = .{ .gradient = &veil } }, .{});
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -1, .y = -2 }, .max = .{ .x = 31, .y = 12 } }, 32);

    var apart = DisplayList.init(a);
    defer apart.deinit();
    const across: Gradient = .{ .linear = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 0, .y = 10 }, .colors = veil.linear.colors, .offsets = veil.linear.offsets } };
    try apart.addPath(band, .{ .fill = .{ .gradient = &under } }, .{});
    try apart.addPath(band, .{ .fill = .{ .gradient = &across } }, .{});
    try testing.expectError(error.OverlappingVaryingPaints, flatten(a, &apart, .{}, null));
}

test "a highlight over shading on the same patches becomes colors at their corners" {
    const a = testing.allocator;
    var band = try rectangle(a, 0, 0, 20, 10);
    defer band.deinit();
    var backing = try rectangle(a, 5, -5, 25, 20);
    defer backing.deinit();
    const nets = [_][16]g.Point{ plane(.{ .x = 0, .y = 0 }, 10, 10), plane(.{ .x = 10, .y = 0 }, 10, 10) };
    const light = [_][16]f64{ bilinearField(.{ 0.1, 0.1, 0.5, 0.5 }), bilinearField(.{ 0.5, 0.5, 0.95, 0.95 }) };
    const glint = [_][16]f64{ bilinearField(.{ 0, 0.4, 0.9, 0.5 }), bilinearField(.{ 0.5, 0.9, 0.3, 0 }) };
    const shade: Gradient = .{ .patches = .{ .points = &nets, .values = &light, .stops = .{ .levels = &.{ 0, 0.6, 1 }, .colors = &.{ .{ .r = 0.1, .g = 0.3, .b = 0.4 }, .{ .r = 0.2, .g = 0.6, .b = 0.7 }, .{ .r = 0.6, .g = 0.85, .b = 0.9 } } }, .tolerance = 0.01 } };
    const highlight: Gradient = .{ .patches = .{ .points = &nets, .values = &glint, .stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.22 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.88 } } }, .tolerance = 0.01 } };
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.fill(backing, .{ .color = .{ .r = 0.9, .g = 0.3, .b = 0.2 } }, .{});
    // One solid at an opacity: its shading and highlight in a layer.
    try source.beginLayer(.{}, null, 0.75);
    try source.addPath(band, .{ .fill = .{ .gradient = &shade } }, .{});
    try source.addPath(band, .{ .fill = .{ .gradient = &highlight } }, .{});
    try source.endScope();
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    var corners: usize = 0;
    for (result.commands.items) |command| if (command == .path) if (command.path.style.gradientFor(.fill)) |gradient| {
        corners += @intFromBool(gradient.* == .color_patches);
    };
    try testing.expect(corners > 0);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -1, .y = -6 }, .max = .{ .x = 31, .y = 16 } }, 32);
}

test "a highlight over shading on the same rays becomes colors at shared patches" {
    const a = testing.allocator;
    var square = try rectangle(a, -10, -10, 20, 20);
    defer square.deinit();
    // A whole turn of rays around the origin, a step on the third.
    const points = [_]g.Point{ .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 9 }, .{ .x = -7, .y = 0 }, .{ .x = -7, .y = 0 }, .{ .x = 0, .y = -6 }, .{ .x = 8, .y = 0 } };
    const light = [_]f64{ 0.1, 0.9, 0.4, 0.45, 0.7, 0.1 };
    const glint = [_]f64{ 0, 0.8, 0.3, 0, 0, 0 };
    const shade: Gradient = .{ .fan = .{ .center = .zero, .points = &points, .values = &light, .stops = .{ .levels = &.{ 0, 0.6, 1 }, .colors = &.{ .{ .r = 0.1, .g = 0.3, .b = 0.4 }, .{ .r = 0.2, .g = 0.6, .b = 0.7 }, .{ .r = 0.6, .g = 0.85, .b = 0.9 } } }, .tolerance = 1e-5 } };
    const highlight: Gradient = .{ .fan = .{ .center = .zero, .points = &points, .values = &glint, .stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.22 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.88 } } }, .tolerance = 1e-5 } };
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.addPath(square, .{ .fill = .{ .gradient = &shade } }, .{});
    try source.addPath(square, .{ .fill = .{ .gradient = &highlight } }, .{});
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -9, .y = -9 }, .max = .{ .x = 9, .y = 9 } }, 30);
}

test "a paint on patches covers only its patches, so what is under it shows elsewhere" {
    const a = testing.allocator;
    var band = try rectangle(a, 0, 0, 20, 10);
    defer band.deinit();
    var box = try rectangle(a, 5, 2, 10, 6);
    defer box.deinit();
    const nets = [_][16]g.Point{plane(.{ .x = 0, .y = 0 }, 10, 10)};
    const field = [_][16]f64{bilinearField(.{ 0, 0, 1, 1 })};
    const half: Gradient = .{ .patches = .{ .points = &nets, .values = &field, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 0.2, .g = 0.2, .b = 0.9, .a = 0.3 }, .{ .r = 0.9, .g = 0.8, .b = 0.1, .a = 0.6 } } }, .tolerance = 0.01 } };
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.fill(box, .{ .color = .{ .r = 0.9, .g = 0.1, .b = 0.1, .a = 0.5 } }, .{});
    try source.addPath(band, .{ .fill = .{ .gradient = &half } }, .{});
    var result = try flatten(a, &source, .{}, null);
    defer result.deinit();
    try expectOpaque(&result);
    try expectSameColors(&source, &result, .{ .r = 1, .g = 1, .b = 1 }, .{ .min = .{ .x = -1, .y = -1 }, .max = .{ .x = 21, .y = 11 } }, 22);
}
