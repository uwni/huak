//! Tests of color patches lowered to pieces whose colors lie along lines.
const std = @import("std");
const style = @import("../style.zig");
const Color = style.Color;
const testing = std.testing;
const color_patches = @import("../color_patches.zig");
const scalar = @import("scalar.zig");
const fixtures = @import("testing.zig");
const lines = scalar.lines;
const plane = fixtures.plane;
const bilinearColor = color_patches.bilinearColor;

test "color patches become pieces whose colors lie along lines" {
    const a = testing.allocator;
    // Colors on one line: one piece. Colors in a plane: pieces.
    const along: [4]Color = .{ .{ .r = 0.2, .g = 0.2, .b = 0.2 }, .{ .r = 0.4, .g = 0.4, .b = 0.4 }, .{ .r = 1, .g = 1, .b = 1 }, .{ .r = 0.6, .g = 0.6, .b = 0.6 } };
    const spread: [4]Color = .{ .{ .r = 1, .g = 0, .b = 0 }, .{ .r = 0, .g = 1, .b = 0 }, .{ .r = 0, .g = 0, .b = 1 }, .{ .r = 1, .g = 1, .b = 0 } };
    const tolerance = 0.01;
    const single = try lines(a, .{ .points = &.{plane(10, 10)}, .colors = &.{along} }, tolerance, 10_000);
    defer a.free(single);
    try testing.expectEqual(@as(usize, 1), single.len);
    const many = try lines(a, .{ .points = &.{plane(10, 10)}, .colors = &.{spread} }, tolerance, 100_000);
    defer a.free(many);
    try testing.expect(many.len > 16);
    for (many) |piece| {
        const start = piece.net[0].x / 10;
        const stop = piece.net[12].x / 10;
        const low = piece.net[0].y / 10;
        const high = piece.net[3].y / 10;
        for (0..3) |p| for (0..3) |q| {
            const s = @as(f64, @floatFromInt(p)) / 2;
            const r = @as(f64, @floatFromInt(q)) / 2;
            const want = bilinearColor(spread, start + (stop - start) * s, low + (high - low) * r);
            const value = @import("../patches.zig").evaluate(&piece.net, &piece.values, s, r).value;
            const a_ = piece.line[0];
            const b_ = piece.line[1];
            try testing.expectApproxEqAbs(want.r, a_.r + (b_.r - a_.r) * value, 2 * tolerance);
            try testing.expectApproxEqAbs(want.g, a_.g + (b_.g - a_.g) * value, 2 * tolerance);
            try testing.expectApproxEqAbs(want.b, a_.b + (b_.b - a_.b) * value, 2 * tolerance);
        };
    }
}
