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
        try t.expect(std.mem.indexOf(u8, svg, "<style>[data-typst-label=\"huak-opacity-0.5\"]{opacity:0.5}</style></svg>") != null);
        // The fills themselves stay opaque.
        try t.expect(std.mem.indexOf(u8, svg, "fill-opacity") == null);
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
        try t.expect(std.mem.indexOf(u8, words, "Layer") != null);
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
    try t.expect(std.mem.indexOf(u8, output.bytes(), "{opacity:0.5}") != null);
}
