const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const huak = @import("huak");
const regions = huak.core.region;
const Path = huak.core.Path;
const DisplayList = huak.core.DisplayList;
const options = @import("test_options");
const pdf_text = @import("support/pdf.zig");

fn rectangle(x: f64, y: f64, width: f64, height: f64) !Path {
    var result = Path.init(t.allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y + height });
    try result.lineTo(.{ .x = x, .y = y + height });
    try result.close();
    return result;
}

test "static polygon operations and retained text produce real native SVG and copyable PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const source = "Polygon operations $x^2$ Ω";
    const requests = [_]typst.LayoutRequest{.{
        .source = source,
        .syntax = .markup,
        .region = null,
    }};
    var measured: [1]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    const frames = [_]typst.FrameRef{try labels.frame(0)};

    var outer = try rectangle(0, 0, 40, 40);
    defer outer.deinit();
    var inner = try rectangle(10, 10, 20, 20);
    defer inner.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    for ([_]regions.Operation{ .unite, .intersect, .difference, .xor }, 0..) |operation, index| {
        var result = try regions.combine(t.allocator, outer, inner, operation, .{});
        defer result.deinit();
        try picture.filldraw(result, .{ .r = 0.2, .g = 0.4, .b = 0.8 }, .{ .width = 0.3 }, .translation(20 + @as(f64, @floatFromInt(index)) * 65, 30));
    }
    var expanded = try regions.offset(t.allocator, outer, 4, .{ .join = .round });
    defer expanded.deinit();
    try picture.fill(expanded, .{ .r = 0.8, .g = 0.2 }, .translation(20, 105));
    var center = Path.init(t.allocator);
    defer center.deinit();
    try center.moveTo(.zero);
    try center.cubicTo(.{ .x = 10, .y = 30 }, .{ .x = 20, .y = -20 }, .{ .x = 40, .y = 0 });
    var stroke = try regions.stroke(t.allocator, center, 5, .{ .cap = .round });
    defer stroke.deinit();
    try picture.fill(stroke, .{ .r = 0.8, .g = 0.2 }, .translation(100, 125));
    var region = try regions.clipRegion(t.allocator, outer, .fromPoints(.{ .x = 15, .y = 15 }, .{ .x = 50, .y = 50 }), .{});
    defer region.deinit();
    try picture.fill(region, .{ .r = 0.8, .g = 0.2 }, .translation(150, 100));
    var lines = try regions.clipLines(t.allocator, center, .fromPoints(.{ .x = 10, .y = -30 }, .{ .x = 30, .y = 30 }), .{});
    defer lines.deinit();
    try picture.draw(lines, .{ .width = 1, .color = .{ .r = 0.8, .g = 0.2 } }, .translation(220, 125));
    const metrics = measured[0];
    try picture.labelAtBaseline(0, .{ .width = metrics.width, .height = metrics.height, .baseline = metrics.baseline }, .{ .x = 20, .y = 170 }, .{});
    var document = try huak.backend.submit(t.allocator, &library, &picture, 300, 190, .{ .frames = &frames });
    defer document.deinit();
    labels.deinit();
    engine.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    for ([_][]const u8{ "<path", "<use", "fill=\"#3366cc\"", "fill=\"#cc3300\"" }) |expected| {
        try t.expect(std.mem.indexOf(u8, svg.bytes(), expected) != null);
    }
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    const text = try pdf_text.text(pdf.bytes(), .{});
    defer t.allocator.free(text);
    for ([_][]const u8{ "Polygon operations", "Ω" }) |expected| try t.expect(std.mem.indexOf(u8, text, expected) != null);
}
