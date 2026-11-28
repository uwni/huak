//! Mesh PDFs: curved clips, holes, alpha order and live text, and the typesetting context they borrow.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const backend = @import("huak").backend;
const DisplayList = @import("huak").core.DisplayList;
const options = @import("test_options");

test "mesh PDFs keep curved clips holes alpha order and live text without changing ordinary export" {
    const core = @import("huak").core;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var box = try demo.rectangle(t.allocator, .zero, 100, 100);
    defer box.deinit();
    try picture.fill(box, .{ .color = .{ .b = 1 } }, .{});
    var plain = try backend.submit(t.allocator, &library, &picture, 100, 100, .{});
    defer plain.deinit();
    var normal_pdf = try plain.exportPdf();
    defer normal_pdf.deinit();
    var enabled = try backend.submit(t.allocator, &library, &picture, 100, 100, .{ .pdf = true });
    defer enabled.deinit();
    var unchanged = try enabled.exportPdf();
    defer unchanged.deinit();
    try t.expectEqualSlices(u8, normal_pdf.bytes(), unchanged.bytes());
    try t.expect(library.shared_context == null);

    var engine = try library.createEngine();
    defer engine.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var text = try engine.layoutContent(&.{.{ .source = "Native mesh $x^2$", .syntax = .markup }}, &metrics, null);
    defer text.deinit();
    var boundary = try demo.rectangle(t.allocator, .zero, 60, 60);
    defer boundary.deinit();
    // Same winding as the outer boundary: only even-odd clipping leaves a hole.
    try boundary.moveTo(.{ .x = 20, .y = 20 });
    try boundary.lineTo(.{ .x = 40, .y = 20 });
    try boundary.lineTo(.{ .x = 40, .y = 40 });
    try boundary.lineTo(.{ .x = 20, .y = 40 });
    try boundary.close();
    var outer_clip = core.Path.init(t.allocator);
    defer outer_clip.deinit();
    try outer_clip.moveTo(.{ .x = 5, .y = 5 });
    try outer_clip.lineTo(.{ .x = 75, .y = 5 });
    try outer_clip.cubicTo(.{ .x = 75, .y = 75 }, .{ .x = 5, .y = 75 }, .{ .x = 5, .y = 5 });
    try outer_clip.close();
    try picture.beginScope(.{}, outer_clip);
    try picture.addPath(boundary, .{ .fill_rule = .evenodd, .fill = .{ .gradient = &.{ .patches = .{
        .points = &.{flatPatch(.zero, 60)},
        .values = &.{@as([16]f64, @splat(0))},
        .stops = .{ .levels = &.{0}, .colors = &.{.{ .r = 1, .a = 0.5 }} },
        .tolerance = 1.0 / 256.0,
    } } } }, .{ .e = 10, .f = 10 });
    try picture.endScope();
    var foreground = try demo.rectangle(t.allocator, .{ .x = 12, .y = 12 }, 6, 6);
    defer foreground.deinit();
    try picture.fill(foreground, .{ .color = .{ .g = 1 } }, .{});
    try picture.labelAtBaseline(0, demo.metrics(metrics[0]), .{ .x = 4, .y = 85 }, .{});
    const frames = [_]typst.FrameRef{try text.frame(0)};
    const scene: @import("huak").render.Scene = .{ .picture = &picture, .size = .{ .x = 100, .y = 100 }, .frames = &frames };
    try scene.validate(.pdf);
    {
        // Default SVG rasterizes only the mesh fill into a clipped PNG image;
        // foreground paths and Typst text remain pure vectors.
        var diagnostic: ?typst.Buffer = null;
        var output = try scene.render(t.allocator, &library, .svg, &diagnostic);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "<image"));
        try t.expect(std.mem.find(u8, output.bytes(), "data:image/png;base64,") != null);
        try t.expect(std.mem.find(u8, output.bytes(), "clip-path=") != null);
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, output.bytes(), " data-typst-label=\"huak-mesh\""));
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, output.bytes(), "shape-rendering:crispEdges"));
        try t.expect(std.mem.find(u8, output.bytes(), "<use") != null);
    }
    {
        const capabilities = library.capabilities.?;
        defer library.capabilities = capabilities;
        library.capabilities = capabilities & ~@as(u64, typst.c.TYPST_CAP_RASTER_IMAGE);
        try t.expectError(error.Unsupported, backend.submit(t.allocator, &library, &picture, 100, 100, .{ .frames = &frames }));
    }
    {
        // Explicit triangle mode: SVG draws the mesh as a labeled group of
        // triangle paths, clipped to the normalized even-odd boundary, with crispEdges.
        var tri_scene = scene;
        tri_scene.svg_mesh = .triangles;
        var diagnostic: ?typst.Buffer = null;
        var output = try tri_scene.render(t.allocator, &library, .svg, &diagnostic);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), " data-typst-label=\"huak-mesh\""));
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "shape-rendering:crispEdges"));
        try t.expect(std.mem.find(u8, output.bytes(), "<image") == null);
    }
    {
        const capabilities = library.capabilities.?;
        defer library.capabilities = capabilities;
        library.capabilities = capabilities & ~@as(u64, typst.c.TYPST_CAP_PDF_IMPORT);
        try t.expectError(error.Unsupported, backend.submit(t.allocator, &library, &picture, 100, 100, .{ .frames = &frames, .pdf = true }));
    }
    var document = try backend.submit(t.allocator, &library, &picture, 100, 100, .{ .frames = &frames, .pdf = true });
    defer document.deinit();
    text.deinit();
    engine.deinit();
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    // One color at one opacity: the mesh page fills its clip with that
    // color at that opacity, through the coverage of the patch mesh.
    try t.expect(std.mem.find(u8, pdf.bytes(), "/ShadingType 7") != null);
    try t.expect(std.mem.find(u8, pdf.bytes(), "/Subtype /Image") == null);
    const words = try @import("../support/pdf.zig").text(pdf.bytes(), .{});
    defer t.allocator.free(words);
    try t.expect(std.mem.find(u8, words, "Native mesh") != null);
    try t.expect(std.mem.find(u8, words, "𝑥") != null);
    try t.expect(std.mem.find(u8, words, "2") != null);
    const image = try @import("../support/pdf.zig").raster(pdf.bytes(), .{});
    defer t.allocator.free(image);
    const header = "P6\n100 100\n255\n";
    try t.expect(std.mem.startsWith(u8, image, header));
    const pixels = image[header.len..];
    for ([_]struct { x: usize, y: usize, rgb: [3]u8 }{
        .{ .x = 15, .y = 15, .rgb = .{ 0, 255, 0 } }, // later native path is above mesh
        .{ .x = 25, .y = 20, .rgb = .{ 128, 0, 127 } }, // mesh alpha over earlier native path
        .{ .x = 35, .y = 35, .rgb = .{ 0, 0, 255 } }, // hole exposes earlier path
        .{ .x = 65, .y = 60, .rgb = .{ 0, 0, 255 } }, // outside curved outer clip
    }) |sample| {
        const offset = ((99 - sample.y) * 100 + sample.x) * 3;
        for (sample.rgb, pixels[offset..][0..3]) |expected, actual| try t.expect(@abs(@as(i32, actual) - expected) <= 2);
    }
}

test "mesh import borrows the configured typesetting context instead of replacing it" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngineWithOptions(&.{ .inputs = &.{.{ .key = "configured", .value = "yes" }} });
    defer engine.deinit();
    const context = library.shared_context;
    const configuration = library.shared_options;
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var boundary = try demo.rectangle(t.allocator, .zero, 20, 10);
    defer boundary.deinit();
    var rising: [16]f64 = undefined;
    for (&rising, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index / 4)) / 3;
    try picture.addPath(boundary, .{ .fill = .{ .gradient = &.{ .patches = .{
        .points = &.{flatPatch(.zero, 20)},
        .values = &.{rising},
        .stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1 }, .{ .g = 1 }, .{ .b = 1 } } },
        .tolerance = 1.0 / 256.0,
    } } } }, .{});
    var document = try backend.submit(t.allocator, &library, &picture, 20, 10, .{ .pdf = true });
    defer document.deinit();
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.find(u8, pdf.bytes(), "/ShadingType 7") != null);
    try t.expectEqual(context, library.shared_context);
    try t.expectEqual(configuration, library.shared_options);
}

/// A flat patch over the square from `origin` with side `size`.
fn flatPatch(origin: @import("huak").core.geometry.Point, size: f64) [16]@import("huak").core.geometry.Point {
    var result: [16]@import("huak").core.geometry.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        result[i * 4 + j] = .{ .x = origin.x + size * @as(f64, @floatFromInt(i)) / 3, .y = origin.y + size * @as(f64, @floatFromInt(j)) / 3 };
    };
    return result;
}
