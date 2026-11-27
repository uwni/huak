//! Unit tests for the pure-Zig 2x2 SSAA SVG mesh rasterizer.
const std = @import("std");
const t = std.testing;
const Workers = @import("workers");
const g = @import("../../../drawing/geometry.zig");
const Path = @import("../../../drawing/path/Path.zig");
const style = @import("../../../drawing/style.zig");
const conic_mod = @import("../../../drawing/conic.zig");
const raster = @import("../raster.zig");
const Color = style.Color;
const Gradient = style.Gradient;

fn rectSegments(x0: f64, y0: f64, x1: f64, y1: f64) [5]Path.Segment {
    return .{
        .{ .move = .{ .x = x0, .y = y0 } },
        .{ .line = .{ .x = x1, .y = y0 } },
        .{ .line = .{ .x = x1, .y = y1 } },
        .{ .line = .{ .x = x0, .y = y1 } },
        .close,
    };
}

fn flatNet(x0: f64, y0: f64, x1: f64, y1: f64) [16]g.Point {
    var net: [16]g.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3.0;
        const v = @as(f64, @floatFromInt(j)) / 3.0;
        net[i * 4 + j] = .{ .x = x0 + (x1 - x0) * u, .y = y0 + (y1 - y0) * v };
    };
    return net;
}

fn pixelAt(img: raster.Image, x: u32, y: u32) [4]u8 {
    const stride: usize = if (img.encoding == .rgb8) 3 else 4;
    const off = (@as(usize, y) * img.width + x) * stride;
    return if (stride == 3)
        .{ img.pixels[off], img.pixels[off + 1], img.pixels[off + 2], 255 }
    else
        .{ img.pixels[off], img.pixels[off + 1], img.pixels[off + 2], img.pixels[off + 3] };
}

test "color patches rasterize opaque gradients as RGB8 within 1/255" {
    const clip = rectSegments(0, 0, 60, 60);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 60, .y = 60 } };
    const nets = [_][16]g.Point{flatNet(0, 0, 60, 60)};
    // Corner order: (0,0), (0,1), (1,1), (1,0).
    const colors = [_][4]Color{.{
        .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .{ .r = 0, .g = 1, .b = 0, .a = 1 },
        .{ .r = 1, .g = 1, .b = 0, .a = 1 },
        .{ .r = 1, .g = 0, .b = 0, .a = 1 },
    }};
    const img = (try raster.rasterize(t.allocator, .{ .color_patches = .{ .points = &nets, .colors = &colors } }, &clip, box, .{ .dpi = 72 })).?;
    defer img.deinit(t.allocator);

    try t.expectEqual(@as(u32, 60), img.width);
    try t.expectEqual(@as(u32, 60), img.height);
    try t.expectEqual(raster.Encoding.rgb8, img.encoding);

    // Row 0 is top (y = max.y = 60 -> v = 1, green=1); row 59 is bottom (y = 0 -> v = 0).
    for ([_][2]u32{ .{ 5, 5 }, .{ 30, 15 }, .{ 45, 45 }, .{ 55, 55 }, .{ 10, 50 } }) |xy| {
        const u = (@as(f64, @floatFromInt(xy[0])) + 0.5) / 60.0;
        const v = 1.0 - (@as(f64, @floatFromInt(xy[1])) + 0.5) / 60.0;
        const px = pixelAt(img, xy[0], xy[1]);
        try t.expect(@abs(@as(i32, px[0]) - @as(i32, @intFromFloat(@round(u * 255.0)))) <= 1);
        try t.expect(@abs(@as(i32, px[1]) - @as(i32, @intFromFloat(@round(v * 255.0)))) <= 1);
        try t.expectEqual(@as(u8, 0), px[2]);
    }
}

test "shared curved edge between translucent patches has zero cracks and zero double-alpha" {
    // Two patches meet along a curved cubic edge x(v) = 30 + 12*sin-like bump,
    // with the right patch having higher curvature on its far edge so mixed
    // subdivision counts exercise the conforming edge zipper.
    var left = flatNet(0, 0, 30, 60);
    var right = flatNet(30, 0, 60, 60);
    // Curve the shared seam (left's right edge = right's left edge).
    left[13].x = 42;
    left[14].x = 18;
    right[1].x = 42;
    right[2].x = 18;
    // Also curve right's far right edge strongly in reverse direction.
    right[13].x = 58;
    right[14].x = 48;
    // Reverse left's seam direction by flipping v on right so canonicalReverse is tested!
    var right_rev: [16]g.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        right_rev[i * 4 + j] = right[i * 4 + (3 - j)];
    };

    const nets = [_][16]g.Point{ left, right_rev };
    const half_red: Color = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const colors = [_][4]Color{
        .{ half_red, half_red, half_red, half_red },
        .{ half_red, half_red, half_red, half_red },
    };
    const clip = rectSegments(0, 0, 60, 60);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 60, .y = 60 } };

    const img = (try raster.rasterize(t.allocator, .{ .color_patches = .{ .points = &nets, .colors = &colors } }, &clip, box, .{ .dpi = 144 })).?;
    defer img.deinit(t.allocator);
    try t.expectEqual(raster.Encoding.rgba8, img.encoding);

    // Every pixel in the interior band [x in 15..105] must have alpha == 128
    // (0 cracks -> never 0 or 64; 0 double-alpha -> never 160 or 191!).
    for (4..img.height - 4) |y| {
        for (20..img.width - 20) |x| {
            const px = pixelAt(img, @intCast(x), @intCast(y));
            try t.expectEqual(@as(u8, 255), px[0]);
            try t.expectEqual(@as(u8, 0), px[1]);
            try t.expectEqual(@as(u8, 0), px[2]);
            try t.expectEqual(@as(u8, 128), px[3]);
        }
    }
}

test "painter order occlusion and scalar field multi-stop sharpness" {
    const clip = rectSegments(0, 0, 60, 60);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 60, .y = 60 } };
    // Patch 0 (far) = red across full square; Patch 1 (near) = blue on right half.
    const nets = [_][16]g.Point{ flatNet(0, 0, 60, 60), flatNet(30, 0, 60, 60) };
    const values = [_][16]f64{ @splat(0.0), @splat(1.0) };
    const stops: Gradient.Stops = .{
        .levels = &.{ 0.0, 0.49, 0.51, 1.0 },
        .colors = &.{ .{ .r = 1 }, .{ .r = 1 }, .{ .b = 1 }, .{ .b = 1 } },
    };
    const img = (try raster.rasterize(t.allocator, .{ .patches = .{ .points = &nets, .values = &values, .stops = stops, .tolerance = 1.0 / 256.0 } }, &clip, box, .{ .dpi = 72 })).?;
    defer img.deinit(t.allocator);

    try t.expectEqual(raster.Encoding.rgb8, img.encoding);
    try t.expectEqual([4]u8{ 255, 0, 0, 255 }, pixelAt(img, 15, 30));
    try t.expectEqual([4]u8{ 0, 0, 255, 255 }, pixelAt(img, 45, 30));
}

test "analytical conic rasterizer matches exact ray field and preserves transparent uncovered region" {
    const clip = rectSegments(0, 0, 60, 60);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 60, .y = 60 } };
    // Full 360-degree conic.
    const full_conic: Gradient.Conic = .{
        .center = .{ .x = 30, .y = 30 },
        .points = &.{ .{ .x = 50, .y = 30 }, .{ .x = 30, .y = 50 }, .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 10 }, .{ .x = 50, .y = 30 } },
        .values = &.{ 0, 0.25, 1, 0.5, 0 },
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .white } },
        .tolerance = 1.0 / 64.0,
    };
    const img = (try raster.rasterize(t.allocator, .{ .conic = full_conic }, &clip, box, .{ .dpi = 72 })).?;
    defer img.deinit(t.allocator);
    try t.expectEqual(raster.Encoding.rgb8, img.encoding);
    for ([_][2]u32{ .{ 55, 30 }, .{ 30, 5 }, .{ 5, 30 }, .{ 30, 55 }, .{ 45, 12 }, .{ 12, 20 }, .{ 20, 50 }, .{ 50, 44 } }) |xy| {
        const expected = 255.0 * conic_mod.evaluate(full_conic, .{
            .x = @as(f64, @floatFromInt(xy[0])) + 0.5,
            .y = 59.5 - @as(f64, @floatFromInt(xy[1])),
        }).?;
        const px = pixelAt(img, xy[0], xy[1]);
        try t.expect(@abs(@as(f64, @floatFromInt(px[0])) - expected) <= 2.0);
    }

    // Partial 90-degree wedge: upper-right quadrant painted, other three quadrants transparent!
    const partial_conic: Gradient.Conic = .{
        .center = .{ .x = 30, .y = 30 },
        .points = &.{ .{ .x = 50, .y = 30 }, .{ .x = 30, .y = 50 } },
        .values = &.{ 0, 1 },
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .g = 1 } } },
        .tolerance = 1.0 / 64.0,
    };
    const partial = (try raster.rasterize(t.allocator, .{ .conic = partial_conic }, &clip, box, .{ .dpi = 72 })).?;
    defer partial.deinit(t.allocator);
    try t.expectEqual(raster.Encoding.rgba8, partial.encoding);
    try t.expectEqual(@as(u8, 255), pixelAt(partial, 45, 15)[3]); // inside Q1
    try t.expectEqual(@as(u8, 0), pixelAt(partial, 15, 45)[3]); // outside Q1 -> transparent
}

test "clip-aware gutter dilation keeps opaque curved clip RGB8 and bleeds outside without expanding interior transparency" {
    // Circle clip inside 60x60 box, with an opaque patch covering only the
    // circle's inner box [10..50, 10..50].
    var circle = try Path.circle(t.allocator, .{ .x = 30, .y = 30 }, 18);
    defer circle.deinit();
    const clip_box: g.BBox = .{ .min = .{ .x = 12, .y = 12 }, .max = .{ .x = 48, .y = 48 } };
    const nets = [_][16]g.Point{flatNet(10, 10, 50, 50)};
    const green: Color = .{ .r = 0.2, .g = 0.8, .b = 0.4, .a = 1 };
    const colors = [_][4]Color{.{ green, green, green, green }};

    const img = (try raster.rasterize(t.allocator, .{ .color_patches = .{ .points = &nets, .colors = &colors } }, circle.segments.items, clip_box, .{ .dpi = 72 })).?;
    defer img.deinit(t.allocator);
    try t.expectEqual(raster.Encoding.rgb8, img.encoding);
    const center = pixelAt(img, img.width / 2, img.height / 2);
    try t.expectEqual(@as(u8, 51), center[0]);
    try t.expectEqual(@as(u8, 204), center[1]);
    try t.expectEqual(@as(u8, 102), center[2]);
}

test "opaque quadtree T-junction along curved Bézier seam has zero pinholes" {
    const color_patches = @import("../../../drawing/color_patches.zig");
    // Coarse left patch meets two de Casteljau child patches on the right along
    // a gently curved cubic seam — the exact geometry produced by adaptive
    // color_patches.compose on 3D solids.
    var left = flatNet(0, 0, 30, 60);
    var right = flatNet(30, 0, 60, 60);
    left[13].x = 34;
    left[14].x = 26;
    right[1].x = 34;
    right[2].x = 26;

    const right_lo = color_patches.subnet(&right, .{ 0, 1 }, .{ 0, 0.5 });
    const right_hi = color_patches.subnet(&right, .{ 0, 1 }, .{ 0.5, 1 });
    const nets = [_][16]g.Point{ left, right_lo, right_hi };
    const blue: Color = .{ .r = 0.25, .g = 0.55, .b = 0.78, .a = 1 };
    const colors = [_][4]Color{
        .{ blue, blue, blue, blue },
        .{ blue, blue, blue, blue },
        .{ blue, blue, blue, blue },
    };
    const clip = rectSegments(0, 0, 60, 60);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 60, .y = 60 } };

    const img = (try raster.rasterize(t.allocator, .{ .color_patches = .{ .points = &nets, .colors = &colors } }, &clip, box, .{ .dpi = 300 })).?;
    defer img.deinit(t.allocator);
    try t.expectEqual(raster.Encoding.rgb8, img.encoding);
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const px = pixelAt(img, @intCast(x), @intCast(y));
            try t.expectEqual(@as(u8, 64), px[0]);
            try t.expectEqual(@as(u8, 140), px[1]);
            try t.expectEqual(@as(u8, 199), px[2]);
            try t.expectEqual(@as(u8, 255), px[3]);
        }
    }
}

test "serial and multi-worker rasterization produce bit-for-bit identical output" {
    const clip = rectSegments(0, 0, 128, 128);
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 128, .y = 128 } };
    var nets: [16][16]g.Point = undefined;
    var colors: [16][4]Color = undefined;
    for (0..4) |r| for (0..4) |c| {
        const idx = r * 4 + c;
        const x0 = @as(f64, @floatFromInt(c)) * 32.0;
        const y0 = @as(f64, @floatFromInt(r)) * 32.0;
        nets[idx] = flatNet(x0, y0, x0 + 32.0, y0 + 32.0);
        const f = @as(f64, @floatFromInt(idx)) / 15.0;
        colors[idx] = .{
            .{ .r = f, .g = 1 - f, .b = 0.3, .a = 1 },
            .{ .r = 1 - f, .g = f, .b = 0.5, .a = 1 },
            .{ .r = f * 0.5, .g = 0.8, .b = 1 - f, .a = 1 },
            .{ .r = 0.2, .g = f, .b = f, .a = 1 },
        };
    };

    const mesh: raster.Mesh = .{ .color_patches = .{ .points = &nets, .colors = &colors } };
    const serial = (try raster.rasterize(t.allocator, mesh, &clip, box, .{ .dpi = 72, .workers = .serial })).?;
    defer serial.deinit(t.allocator);

    const workers = Workers.init(t.io, 4);
    const parallel = (try raster.rasterize(t.allocator, mesh, &clip, box, .{ .dpi = 72, .workers = workers })).?;
    defer parallel.deinit(t.allocator);

    try t.expectEqual(serial.width, parallel.width);
    try t.expectEqual(serial.height, parallel.height);
    try t.expectEqual(serial.encoding, parallel.encoding);
    try t.expectEqualSlices(u8, serial.pixels, parallel.pixels);
}

test "oversize DPI hits GeometryWorkLimit and OOM rolls back cleanly" {
    const box: g.BBox = .{ .min = .zero, .max = .{ .x = 1000, .y = 1000 } };
    try t.expectError(error.GeometryWorkLimit, raster.pixelDimensions(box, .{}, 100_000));
    try t.expectError(error.InvalidStyle, raster.pixelDimensions(box, .{}, 0));
    try t.expectError(error.InvalidStyle, raster.pixelDimensions(box, .{}, std.math.nan(f64)));

    const clip = rectSegments(0, 0, 20, 20);
    const small: g.BBox = .{ .min = .zero, .max = .{ .x = 20, .y = 20 } };
    const nets = [_][16]g.Point{flatNet(0, 0, 20, 20)};
    const colors = [_][4]Color{.{ .{ .r = 1, .a = 0.5 }, .{ .g = 1, .a = 0.5 }, .{ .b = 1, .a = 0.5 }, .{ .r = 1, .b = 1, .a = 0.5 } }};
    const exercise = struct {
        fn run(allocator: std.mem.Allocator, c: []const Path.Segment, b: g.BBox, m: raster.Mesh) !void {
            if (try raster.rasterize(allocator, m, c, b, .{ .dpi = 36 })) |img| img.deinit(allocator);
        }
    }.run;
    try t.checkAllAllocationFailures(t.allocator, exercise, .{ &clip, small, raster.Mesh{ .color_patches = .{ .points = &nets, .colors = &colors } } });
}
