//! Pens through the native backend: elliptical, polygonal and singular pens, and polygon and dashed envelopes.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const backend = @import("huak").backend;
const DisplayList = @import("huak").core.DisplayList;
const options = @import("test_options");

test "independent elliptical polygonal and singular pens render through the native backend" {
    const g = @import("huak").core.geometry;
    const Path = @import("huak").core.Path;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = 16, .y = 20 });
    try line.lineTo(.{ .x = 80, .y = 20 });
    var square = try demo.rectangle(t.allocator, .{ .x = 20, .y = 30 }, 25, 15);
    defer square.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    const ellipse: g.Transform = .{ .a = 8, .d = 2, .e = 3, .f = 4 };
    try picture.draw(line, .{ .nib = .{ .ellipse = ellipse }, .cap = .round, .join = .round }, .{});
    var nib = try @import("huak").core.pen.Nib.square().transformed(t.allocator, g.Transform.scaling(4, 3));
    defer nib.deinit();
    try picture.filldraw(square, .{ .color = .{ .r = 0.2, .g = 0.4 } }, .{ .nib = nib.nib, .paint = .{ .color = .{ .b = 1 } }, .cap = .round, .join = .round }, .{});
    try picture.draw(line, .{ .nib = .{ .ellipse = .{ .a = 0, .d = 6 } }, .paint = .{ .color = .{ .r = 1 } }, .cap = .round, .join = .round }, g.Transform.translation(0, 35));
    try picture.draw(line, .{ .nib = .{ .ellipse = ellipse }, .dash = &.{ 10, 5 }, .dash_phase = -2, .cap = .round, .join = .round }, g.Transform.translation(0, 55));
    // The centre of the square keeps its solid fill. The nib's footprint
    // receives the gradient, in the coordinates of the original path.
    try picture.addPath(square, .{
        .fill = .{ .color = .{ .g = 1 } },
        .pen = .{ .nib = .{ .ellipse = ellipse }, .paint = .{ .gradient = &.{ .linear = .{ .start = .zero, .end = .{ .x = 40, .y = 10 }, .colors = &.{ .black, .{ .r = 1 } } } } } },
    }, .{});
    const ids = [_]u64{ 10, 20, 30, 40, 50 };
    var document = try backend.submit(t.allocator, &library, &picture, 120, 110, .{ .object_ids = &ids });
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    for (ids) |id| {
        var storage: [96]u8 = undefined;
        const marker = try std.mem.print(&storage, "data-typst-label=\"libtypst-object-{d}\"", .{id});
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), marker));
    }
    try t.expect(std.mem.find(u8, svg.bytes(), "stroke-width=\"1\"") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "fill=\"#0000ff\"") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "fill=\"#ff0000\"") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "fill=\"#00ff00\""));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "fill=\"url("));
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "polygon pen envelopes and dashed envelopes reach SVG as curves with one transparent fill" {
    const core = @import("huak").core;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var curve = core.Path.init(t.allocator);
    defer curve.deinit();
    try curve.moveTo(.{ .x = 10, .y = 30 });
    try curve.cubicTo(.{ .x = 35, .y = 65 }, .{ .x = 65, .y = -5 }, .{ .x = 90, .y = 30 });
    var nib = try core.pen.Nib.square().transformed(t.allocator, core.geometry.Transform.scaling(6, 3));
    defer nib.deinit();
    for ([_][]const f64{ &.{}, &.{ 8, 4 } }) |dash| {
        var picture = DisplayList.init(t.allocator);
        defer picture.deinit();
        try picture.draw(curve, .{ .nib = nib.nib, .dash = dash, .paint = .{ .color = .{ .r = 1, .a = 0.5 } }, .cap = .round, .join = .round }, .{});
        var document = try backend.submit(t.allocator, &library, &picture, 100, 70, .{});
        defer document.deinit();
        var svg = try document.exportSvg(0);
        defer svg.deinit();
        // All contour overlaps are painted once with nonzero winding: each
        // stroke is one native fill even when it contains many dash contours.
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "fill=\"#ff000080\""));
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "fill-rule=\"nonzero\""));
        var attributes = std.mem.splitSequence(u8, svg.bytes(), " d=\"");
        _ = attributes.next();
        var found_curve = false;
        while (attributes.next()) |attribute| {
            const end = std.mem.findScalar(u8, attribute, '"') orelse return error.InvalidSvg;
            found_curve = found_curve or std.mem.findAny(u8, attribute[0..end], "cCsS") != null;
        }
        try t.expect(found_curve);
        var pdf = try document.exportPdf();
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    }
}
