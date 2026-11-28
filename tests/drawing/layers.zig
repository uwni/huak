//! A layer as one opacity group in SVG and one transparency group in PDF.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const DisplayList = @import("huak").core.DisplayList;
const options = @import("test_options");

test "a layer is one group with an opacity in SVG and one transparency group in PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    // Two opaque fills that overlap, in one layer at half strength: the
    // upper fill hides the lower one, and what shows is blended once.
    var left = try demo.rectangle(t.allocator, .{ .x = 10, .y = 10 }, 30, 40);
    defer left.deinit();
    var right = try demo.rectangle(t.allocator, .{ .x = 30, .y = 10 }, 20, 40);
    defer right.deinit();
    try picture.beginLayer(.{}, null, 0.5);
    try picture.fill(left, .{ .color = .{ .r = 1 } }, .{});
    try picture.fill(right, .{ .color = .{ .b = 1 } }, .{});
    try picture.endScope();
    const scene: @import("huak").render.Scene = .{ .picture = &picture, .size = .{ .x = 60, .y = 60 } };
    {
        var diagnostic: ?typst.Buffer = null;
        var output = try scene.render(t.allocator, &library, .svg, &diagnostic);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, " data-typst-label=\"huak-opacity-0.5\""));
        try t.expect(std.mem.find(u8, svg, "<style>[data-typst-label=\"huak-opacity-0.5\"]{opacity:0.5}</style></svg>") != null);
        // The fills themselves stay opaque.
        try t.expect(std.mem.find(u8, svg, "fill-opacity") == null);
        try t.expectEqual(@as(usize, 2), std.mem.count(u8, svg, "<path fill=\"#"));
    }
    {
        var diagnostic: ?typst.Buffer = null;
        var output = try scene.render(t.allocator, &library, .pdf, &diagnostic);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "/ca 0.5"));
        const image = try @import("../support/pdf.zig").raster(output.bytes(), .{});
        defer t.allocator.free(image);
        const header = "P6\n60 60\n255\n";
        try t.expect(std.mem.startsWith(u8, image, header));
        const pixels = image[header.len..];
        // Rows run down. Red alone, the overlap, blue alone, and the page:
        // the overlap is blue at half strength, with no red under it.
        for ([_]struct { at: [2]usize, color: [3]f64 }{
            .{ .at = .{ 20, 30 }, .color = .{ 255, 127.5, 127.5 } },
            .{ .at = .{ 35, 30 }, .color = .{ 127.5, 127.5, 255 } },
            .{ .at = .{ 45, 30 }, .color = .{ 127.5, 127.5, 255 } },
            .{ .at = .{ 5, 5 }, .color = .{ 255, 255, 255 } },
            .{ .at = .{ 30, 55 }, .color = .{ 255, 255, 255 } },
        }) |sample| {
            const pixel = pixels[3 * (sample.at[1] * 60 + sample.at[0]) ..][0..3];
            for (pixel, sample.color) |channel, expected| try t.expect(@abs(@as(f64, @floatFromInt(channel)) - expected) <= 2);
        }
    }
    // Typst exports the page of a layer, so a layer holds whatever Typst
    // draws, such as a gradient and text, in PDF as in SVG.
    var engine = try library.createEngine();
    defer engine.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var text = try engine.layoutContent(&.{.{ .source = "Layer $x^2$", .syntax = .markup }}, &metrics, null);
    defer text.deinit();
    const frames = [_]typst.FrameRef{try text.frame(0)};
    var ramp = DisplayList.init(t.allocator);
    defer ramp.deinit();
    try ramp.beginLayer(.{}, null, 0.5);
    try ramp.addPath(left, .{ .fill = .{ .gradient = &.{ .linear = .{ .start = .{ .x = 10, .y = 10 }, .end = .{ .x = 40, .y = 10 }, .colors = &.{ .black, .{ .r = 1 } } } } } }, .{});
    try ramp.labelAtBaseline(0, demo.metrics(metrics[0]), .{ .x = 2, .y = 2 }, .{});
    try ramp.endScope();
    const shaded: @import("huak").render.Scene = .{ .picture = &ramp, .size = .{ .x = 60, .y = 60 }, .frames = &frames };
    var diagnostic: ?typst.Buffer = null;
    {
        var output = try shaded.render(t.allocator, &library, .pdf, &diagnostic);
        defer output.deinit();
        const words = try @import("../support/pdf.zig").text(output.bytes(), .{});
        defer t.allocator.free(words);
        try t.expect(std.mem.find(u8, words, "Layer") != null);
        const image = try @import("../support/pdf.zig").raster(output.bytes(), .{});
        defer t.allocator.free(image);
        const header = "P6\n60 60\n255\n";
        try t.expect(std.mem.startsWith(u8, image, header));
        // Across the ramp the layer goes from black to red, at half
        // strength over the white page.
        for ([_]usize{ 15, 25, 35 }) |x| {
            const along = (@as(f64, @floatFromInt(x)) + 0.5 - 10) / 30;
            const pixel = image[header.len + 3 * (30 * 60 + x) ..][0..3];
            for (pixel, [3]f64{ 127.5 * (1 + along), 127.5, 127.5 }) |channel, expected| try t.expect(@abs(@as(f64, @floatFromInt(channel)) - expected) <= 3);
        }
    }
    var output = try shaded.render(t.allocator, &library, .svg, &diagnostic);
    defer output.deinit();
    try t.expect(std.mem.find(u8, output.bytes(), "{opacity:0.5}") != null);
}

test "opaque patches with translucent overlay fold into one opaque type 7 PDF mesh with no SMask" {
    const core = @import("huak").core;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var boundary = try demo.rectangle(t.allocator, .zero, 60, 60);
    defer boundary.deinit();
    // Far red patch covers the whole square; near blue patch covers the right
    // half where the translucent white overlay has alpha = 0 and must not drop
    // the near patch.
    var far_net: [16]core.geometry.Point = undefined;
    var near_net: [16]core.geometry.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3.0;
        const v = @as(f64, @floatFromInt(j)) / 3.0;
        far_net[i * 4 + j] = .{ .x = 60.0 * u, .y = 60.0 * v };
        near_net[i * 4 + j] = .{ .x = 30.0 + 30.0 * u, .y = 60.0 * v };
    };
    const nets = [_][16]core.geometry.Point{ far_net, near_net };
    const base_values = [_][16]f64{ @splat(0.0), @splat(1.0) };
    const overlay_values = [_][16]f64{ @splat(1.0), @splat(0.0) };

    var piece = DisplayList.init(t.allocator);
    defer piece.deinit();
    try piece.addPath(boundary, .{ .fill = .{ .gradient = &.{ .patches = .{
        .points = &nets,
        .values = &base_values,
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .b = 1 } } },
        .tolerance = 1.0 / 256.0,
    } } } }, .{});
    try piece.addPath(boundary, .{ .fill = .{ .gradient = &.{ .patches = .{
        .points = &nets,
        .values = &overlay_values,
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1, .a = 0.5 } } },
        .tolerance = 1.0 / 256.0,
    } } } }, .{});

    var composed = try core.transparency.flatten(t.allocator, &piece, .{}, null);
    defer composed.deinit();
    // Single opaque color_patches fill, no /SMask in flat PDF.
    var path_count: usize = 0;
    for (composed.commands.items) |cmd| if (cmd == .path) {
        path_count += 1;
        try t.expect(cmd.path.style.fill.?.isOpaque());
    };
    try t.expectEqual(@as(usize, 1), path_count);

    {
        const scene: @import("huak").render.Scene = .{ .picture = &composed, .size = .{ .x = 60, .y = 60 } };
        var diagnostic: ?typst.Buffer = null;
        var output = try scene.render(t.allocator, &library, .pdf, &diagnostic);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "/ShadingType 7"));
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, output.bytes(), "/SMask"));
        const image = try @import("../support/pdf.zig").raster(output.bytes(), .{});
        defer t.allocator.free(image);
        const header = "P6\n60 60\n255\n";
        try t.expect(std.mem.startsWith(u8, image, header));
        const pixels = image[header.len..];
        // Left half: red with 0.5 white overlay -> (255, 128, 128).
        // Right half: near blue patch must overwrite far red patch -> (0, 0, 255).
        const left_px = pixels[3 * (30 * 60 + 15) ..][0..3];
        for (left_px, [3]f64{ 255, 127.5, 127.5 }) |ch, want| try t.expect(@abs(@as(f64, @floatFromInt(ch)) - want) <= 3);
        const right_px = pixels[3 * (30 * 60 + 45) ..][0..3];
        for (right_px, [3]f64{ 0, 0, 255 }) |ch, want| try t.expect(@abs(@as(f64, @floatFromInt(ch)) - want) <= 3);
    }

    // Group opacity 0.6 wrapping the single opaque mesh: still 1 Type 7 mesh, 0 /SMask, /ca 0.6.
    var grouped = DisplayList.init(t.allocator);
    defer grouped.deinit();
    try grouped.beginLayer(.{}, null, 0.6);
    try grouped.append(&composed, .{});
    try grouped.endScope();
    {
        const scene: @import("huak").render.Scene = .{ .picture = &grouped, .size = .{ .x = 60, .y = 60 } };
        var diagnostic: ?typst.Buffer = null;
        var output = try scene.render(t.allocator, &library, .pdf, &diagnostic);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "/ShadingType 7"));
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, output.bytes(), "/SMask"));
        try t.expect(std.mem.find(u8, output.bytes(), "/ca 0.6") != null);
    }
}
