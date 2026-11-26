//! Tests of corner colors: sub-nets, fields as corner colors, composites within the tolerance and splitting along the parameters that vary.
const std = @import("std");
const g = @import("../geometry.zig");
const style = @import("../style.zig");
const enclosure = @import("../enclosure.zig");
const Color = style.Color;
const Gradient = style.Gradient;
const Rgba = enclosure.Rgba;
const testing = std.testing;
const color_patches = @import("../color_patches.zig");
const Workers = @import("workers");
const fixtures = @import("testing.zig");
const plane = fixtures.plane;
const subnet = color_patches.subnet;
const fromField = color_patches.fromField;
const bilinearColor = color_patches.bilinearColor;
const Owned = color_patches.Owned;
const compose = color_patches.compose;

test "a sub-net is the restriction of the patch" {
    var net = plane(30, 12);
    net[5] = .{ .x = 14, .y = 9 };
    const part = subnet(&net, .{ 0.25, 0.75 }, .{ 0.5, 1 });
    const flat: [16]f64 = @splat(0);
    for ([_][2]f64{ .{ 0, 0 }, .{ 0.3, 0.7 }, .{ 1, 1 }, .{ 0.5, 0.5 } }) |uv| {
        const whole = @import("../patches.zig").evaluate(&net, &flat, 0.25 + 0.5 * uv[0], 0.5 + 0.5 * uv[1]).point;
        const piece = @import("../patches.zig").evaluate(&part, &flat, uv[0], uv[1]).point;
        try testing.expectApproxEqAbs(whole.x, piece.x, 1e-12);
        try testing.expectApproxEqAbs(whole.y, piece.y, 1e-12);
    }
}

test "an opaque field becomes corner colors, split only where a stop falls inside" {
    const a = testing.allocator;
    const stops: Gradient.Stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 0.1, .g = 0.2, .b = 0.6 }, .{ .r = 0.5, .g = 0.5, .b = 0.5 }, .{ .r = 1, .g = 1, .b = 1 } } };
    // Field 0.6 to 0.9: no stop inside, one patch.
    var high: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        high[i * 4 + j] = 0.6 + 0.1 * @as(f64, @floatFromInt(i));
    };
    // Field 0 to 0.9 across the patch: the stop at 0.5 is inside, off the
    // lines a split runs along.
    var across: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        across[i * 4 + j] = 0.9 * @as(f64, @floatFromInt(i)) / 3;
    };
    const tolerance = Color.tolerance;
    const one = try fromField(a, .{ .points = &.{plane(10, 10)}, .values = &.{high}, .stops = stops, .tolerance = 0.01 }, tolerance, 10_000);
    defer one.deinit(a);
    try testing.expectEqual(@as(usize, 1), one.points.len);
    const split = try fromField(a, .{ .points = &.{plane(10, 10)}, .values = &.{across}, .stops = stops, .tolerance = 0.01 }, tolerance, 10_000);
    defer split.deinit(a);
    try testing.expect(split.points.len > 4);
    // Check the colors against the stops of the bilinear field on a grid.
    for (split.points, split.colors) |net, colors| {
        // A piece is a part of the unit square of the patch: find its range
        // from its corners (the net is the plane scaled by 10).
        const start = net[0].x / 10;
        const stop = net[12].x / 10;
        for (0..5) |p| for (0..5) |q| {
            const s = @as(f64, @floatFromInt(p)) / 4;
            const r = @as(f64, @floatFromInt(q)) / 4;
            const want = stops.at(0.9 * (start + (stop - start) * s));
            const got = bilinearColor(colors, s, r);
            try testing.expectApproxEqAbs(want.r, got.r, tolerance);
            try testing.expectApproxEqAbs(want.g, got.g, tolerance);
            try testing.expectApproxEqAbs(want.b, got.b, tolerance);
        };
    }
    try testing.expectError(error.InvalidPatches, fromField(a, .{ .points = &.{plane(10, 10)}, .values = &.{high}, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .a = 0.5 }, .{} } }, .tolerance = 0.01 }, tolerance, 10_000));
}

/// Over a grid of each piece, the largest difference between its bilinear
/// colors and `want` at the same point of the whole patch, which is the
/// plane `plane(10, 10)`.
fn worst(patches: Owned, want: anytype) !f64 {
    var largest: f64 = 0;
    for (patches.points, patches.colors) |net, colors| {
        const u = [2]f64{ net[0].x / 10, net[12].x / 10 };
        const v = [2]f64{ net[0].y / 10, net[3].y / 10 };
        for (0..9) |p| for (0..9) |q| {
            const s = @as(f64, @floatFromInt(p)) / 8;
            const r = @as(f64, @floatFromInt(q)) / 8;
            const expected: Color = want.at(u[0] + (u[1] - u[0]) * s, v[0] + (v[1] - v[0]) * r);
            const got = bilinearColor(colors, s, r);
            largest = @max(largest, @abs(expected.r - got.r), @abs(expected.g - got.g), @abs(expected.b - got.b));
        };
    }
    return largest;
}

test "two fields on the same patches compose within the tolerance" {
    const a = testing.allocator;
    // A highlight's white over a shade: translucent white, its opacity a
    // square of the glint, over n·l's tones.
    const shade: Gradient.Stops = .{ .levels = &.{ 0, 0.6, 1 }, .colors = &.{ .{ .r = 0.1, .g = 0.3, .b = 0.3 }, .{ .r = 0.2, .g = 0.6, .b = 0.6 }, .{ .r = 0.5, .g = 0.8, .b = 0.8 } } };
    const glow: Gradient.Stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.22 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.88 } } };
    var light: [16]f64 = undefined;
    var glint: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        light[i * 4 + j] = 0.2 + 0.7 * @as(f64, @floatFromInt(i)) / 3;
        glint[i * 4 + j] = @as(f64, @floatFromInt(i + j)) / 6;
    };
    const Over = struct {
        pub fn color(_: @This(), comptime T: type, colors: []const Rgba(T)) Rgba(T) {
            // Translucent colors[1] over opaque colors[0].
            const top = colors[1];
            const rest = T.constant(1).sub(top.a);
            var result: Rgba(T) = undefined;
            inline for (.{ "r", "g", "b" }) |channel| {
                @field(result, channel) = @field(top, channel).mul(top.a).add(rest.mul(@field(colors[0], channel)));
            }
            result.a = T.constant(1);
            return result;
        }
    };
    const tolerance = Color.tolerance;
    const composed = try compose(a, &.{plane(10, 10)}, &.{ .{ .field = .{ .values = &.{light}, .stops = shade } }, .{ .field = .{ .values = &.{glint}, .stops = glow } } }, Over{}, .{ .tolerance = tolerance, .max_patches = 100_000 });
    defer composed.deinit(a);
    const Want = struct {
        shade: Gradient.Stops,
        glow: Gradient.Stops,
        fn at(self: @This(), u: f64, v: f64) Color {
            const under = self.shade.at(0.2 + 0.7 * u);
            const top = self.glow.at((u + v) / 2);
            return .{ .r = top.a + (1 - top.a) * under.r, .g = top.a + (1 - top.a) * under.g, .b = top.a + (1 - top.a) * under.b };
        }
    };
    try testing.expect(composed.points.len > 1);
    try testing.expect(try worst(composed, Want{ .shade = shade, .glow = glow }) <= tolerance);
    try testing.expectError(error.InvalidPatches, compose(a, &.{plane(10, 10)}, &.{.{ .field = .{ .values = &.{ light, light }, .stops = shade } }}, Over{}, .{ .tolerance = tolerance, .max_patches = 100 }));
}

test "a patch splits only along the parameters it varies in" {
    const a = testing.allocator;
    // Constant in v, with a stop inside the range in u: pieces span v.
    var across_u: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        across_u[i * 4 + j] = @as(f64, @floatFromInt(i)) / 3;
    };
    const stops: Gradient.Stops = .{ .levels = &.{ 0, 0.3, 1 }, .colors = &.{ .{ .r = 0 }, .{ .r = 0.9 }, .{ .r = 1 } } };
    const split = try fromField(a, .{ .points = &.{plane(10, 10)}, .values = &.{across_u}, .stops = stops, .tolerance = 0.01 }, Color.tolerance, 10_000);
    defer split.deinit(a);
    try testing.expect(split.points.len > 2);
    for (split.points) |net| {
        try testing.expectEqual(@as(f64, 0), net[0].y);
        try testing.expectEqual(@as(f64, 10), net[3].y);
    }
}

test "parallel composition matches serial patch-by-patch output bit-for-bit" {
    const a = testing.allocator;
    const count = 600;
    const nets = try a.alloc([16]g.Point, count);
    defer a.free(nets);
    const values = try a.alloc([16]f64, count);
    defer a.free(values);
    for (0..count) |k| {
        nets[k] = plane(10, 10);
        const shift: f64 = @as(f64, @floatFromInt(k)) * 0.25;
        for (&nets[k]) |*p| p.x += shift;
        const base: f64 = @as(f64, @floatFromInt(k % 17)) / 20.0;
        for (0..4) |i| for (0..4) |j| {
            values[k][i * 4 + j] = base + 0.15 * @as(f64, @floatFromInt(i + j)) / 6.0;
        };
    }
    const stops: Gradient.Stops = .{ .levels = &.{ 0, 0.4, 1 }, .colors = &.{ .{ .r = 0.1, .g = 0.2, .b = 0.3 }, .{ .r = 0.8, .g = 0.4, .b = 0.1 }, .{ .r = 1, .g = 1, .b = 0.9 } } };
    const Itself = struct {
        pub fn colorInto(_: @This(), comptime T: type, colors: []const Rgba(T), out: *Rgba(T)) void {
            out.* = colors[0];
        }
    };
    var threaded: std.Io.Threaded = .init(a, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    var expected_points: std.ArrayList([16]g.Point) = .empty;
    defer expected_points.deinit(a);
    var expected_colors: std.ArrayList([4]Color) = .empty;
    defer expected_colors.deinit(a);
    for (0..count) |k| {
        const single = try compose(a, nets[k .. k + 1], &.{.{ .field = .{ .values = values[k .. k + 1], .stops = stops } }}, Itself{}, .{ .tolerance = Color.tolerance, .max_patches = 100_000 });
        defer single.deinit(a);
        try expected_points.appendSlice(a, single.points);
        try expected_colors.appendSlice(a, single.colors);
    }
    for ([_]Workers{ .serial, Workers.init(threaded.io(), 1), Workers.init(threaded.io(), 4) }) |workers| {
        const got = try compose(a, nets, &.{.{ .field = .{ .values = values, .stops = stops } }}, Itself{}, .{ .tolerance = Color.tolerance, .max_patches = 100_000, .workers = workers });
        defer got.deinit(a);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_points.items), std.mem.sliceAsBytes(got.points));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected_colors.items), std.mem.sliceAsBytes(got.colors));
    }
}
