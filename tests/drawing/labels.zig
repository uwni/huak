//! Labels from real text metrics: mixed SVG and PDF, repeated layouts, functions and batches from several engines, and layout regions.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const backend = @import("huak").backend;
const DisplayList = @import("huak").core.DisplayList;
const options = @import("test_options");

test "real text metrics drive native mixed SVG and PDF after engine and labels are released" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [demo.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&demo.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var warnings = try labels.warnings();
    defer warnings.deinit();
    try t.expectEqual(@as(usize, 0), warnings.bytes().len);
    for (measured) |m| {
        try t.expect(m.width > 0 and m.height > 0 and m.baseline > 0);
        try t.expect(m.baseline <= m.height);
    }
    const nodes = try demo.layoutNodes(t.allocator, &measured, 0);
    try t.expectApproxEqAbs((measured[0].width + measured[1].width) / 2 + 115, nodes[1].x - nodes[0].x, 1e-9);
    var wider = measured;
    wider[1].width += 40;
    const moved = try demo.layoutNodes(t.allocator, &wider, 0);
    try t.expectApproxEqAbs(nodes[1].x + 20, moved[1].x, 1e-9);
    try t.expectApproxEqAbs(nodes[2].x + 40, moved[2].x, 1e-9);
    var picture = (try demo.build(t.allocator, &measured, 0)).picture;
    defer picture.deinit();
    const box = (try picture.bounds()).?;
    try t.expect(box.min.x >= -1e-9 and box.max.x <= demo.width + 1e-9);
    var document = try backend.submit(t.allocator, &library, &picture, demo.width, demo.height, .{ .frames = &frames });
    defer document.deinit();
    try t.expectEqual(@as(u32, 1), try document.pageCount());
    labels.deinit();
    engine.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    for ([_][]const u8{ "<symbol ", "<use ", "<clipPath", "stroke-width=\"2.5\"", "stroke=\"#216bb3\"" }) |expected| {
        try t.expect(std.mem.find(u8, svg.bytes(), expected) != null);
    }
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try expectPdfTextResources(pdf.bytes());
    pdf.deinit();
    try t.expectEqual(@as(usize, 0), pdf.bytes().len);
    pdf.deinit();
    try t.expectEqualSlices(u8, &.{}, pdf.bytes());
}

test "repeated label layouts retain identical metrics and independent native scene ownership" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [demo.requests.len]typst.Metrics = undefined;
    var first = try engine.layoutContent(&demo.requests, &measured, null);
    defer first.deinit();
    const expected_metrics = measured;
    var expected_svg: ?[]u8 = null;
    defer if (expected_svg) |bytes| t.allocator.free(bytes);
    for (0..3) |iteration| {
        var labels = try engine.layoutContent(&demo.requests, &measured, null);
        defer labels.deinit();
        var frames: [measured.len]typst.FrameRef = undefined;
        for (&frames, 0..) |*frame, index| frame.* = try (if (iteration == 2) &first else &labels).frame(index);
        for (expected_metrics, measured) |expected, actual| {
            try t.expectApproxEqAbs(expected.width, actual.width, 1e-9);
            try t.expectApproxEqAbs(expected.height, actual.height, 1e-9);
            try t.expectApproxEqAbs(expected.baseline, actual.baseline, 1e-9);
        }
        var picture = DisplayList.init(t.allocator);
        defer picture.deinit();
        var square = try demo.rectangle(t.allocator, .{ .x = 0, .y = 0 }, 2, 2);
        defer square.deinit();
        for (0..1024) |index| {
            try picture.fill(square, .{ .color = .{ .r = 0.2, .g = 0.45, .b = 0.7, .a = 0.7 } }, .{ .e = @as(f64, @floatFromInt(index % 32)) * 4, .f = @as(f64, @floatFromInt(index / 32)) * 4 });
        }
        try picture.labelAtBaseline(0, demo.metrics(measured[0]), .{ .x = 5, .y = 140 }, .{});
        var document = try backend.submit(t.allocator, &library, &picture, 200, 180, .{ .frames = &frames });
        defer document.deinit();
        labels.deinit();
        if (iteration == 2) {
            first.deinit();
            engine.deinit();
        }
        var svg = try document.exportSvg(0);
        defer svg.deinit();
        try t.expect(std.mem.count(u8, svg.bytes(), "fill=\"#3373b3b3\"") == 1024);
        if (expected_svg) |bytes| {
            try t.expectEqualStrings(bytes, svg.bytes());
        } else expected_svg = try t.allocator.dupe(u8, svg.bytes());
        var pdf = try document.exportPdf();
        defer pdf.deinit();
        try expectPdfTextResources(pdf.bytes());
    }
}

// These structural checks verify that fonts and Unicode mappings survive the
// native FFI path. Poppler extraction tests in libtypst/tests/pdf.rs verify the
// actual copied text; finding these markers alone does not prove copy fidelity.
fn expectPdfTextResources(bytes: []const u8) !void {
    try t.expect(std.mem.startsWith(u8, bytes, "%PDF-1.7"));
    for ([_][]const u8{ "/FontFile", "/ToUnicode", "%%EOF" }) |expected| {
        try t.expect(std.mem.find(u8, bytes, expected) != null);
    }
}

test "independent Typst functions and layout batches from different engines combine in one native scene" {
    const first_source =
        \\#let caption(body) = text(font: "Libertinus Serif", size: 18pt, weight: "bold", fill: rgb("#c02030"), body)
        \\#caption[Fixed α]
    ;
    const second_source =
        \\{
        \\  let formula(body) = text(font: "New Computer Modern", size: 20pt, style: "italic", fill: rgb("#2040c0"), body)
        \\  formula[$a^2 + b^2$]
        \\}
    ;
    const first_request = [_]typst.LayoutRequest{.{
        .source = first_source,
        .syntax = .markup,
        .region = null,
    }};
    const second_request = [_]typst.LayoutRequest{.{
        .source = second_source,
        .syntax = .code,
        .region = null,
    }};
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var first_engine = try library.createEngine();
    defer first_engine.deinit();
    var second_engine = try library.createEngine();
    defer second_engine.deinit();
    var first_metrics: [1]typst.Metrics = undefined;
    var second_metrics: [1]typst.Metrics = undefined;
    var first = try first_engine.layoutContent(&first_request, &first_metrics, null);
    defer first.deinit();
    var second = try second_engine.layoutContent(&second_request, &second_metrics, null);
    defer second.deinit();
    const frames = [_]typst.FrameRef{ try first.frame(0), try second.frame(0), try first.frame(0) };
    const measurements = [_]typst.Metrics{ first_metrics[0], second_metrics[0], first_metrics[0] };
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    for (measurements, 0..) |metric, index| {
        try picture.labelAtBaseline(@intCast(index), demo.metrics(metric), .{ .x = 12, .y = 35 + @as(f64, @floatFromInt(index)) * 40 }, .{});
    }
    var document = try backend.submit(t.allocator, &library, &picture, 240, 150, .{ .frames = &frames });
    defer document.deinit();
    first.deinit();
    second.deinit();
    first_engine.deinit();
    second_engine.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.find(u8, svg.bytes(), "fill=\"#c02030\"") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "fill=\"#2040c0\"") != null);
    try t.expect(std.mem.count(u8, svg.bytes(), "<use ") > 10);
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try expectPdfTextResources(pdf.bytes());
}

test "layout regions wrap user content and independently expand finite axes" {
    const source = "#text(size: 12pt)[One two three four five six seven eight nine ten.]";
    const narrow: typst.Region = .{ .width = 90, .height = std.math.inf(f64), .expand_x = false, .expand_y = false };
    const expanded: typst.Region = .{ .width = 120, .height = 96, .expand_x = true, .expand_y = true };
    const requests = [_]typst.LayoutRequest{
        .{
            .source = source,
            .syntax = .markup,
            .region = null,
        },
        .{
            .source = source,
            .syntax = .markup,
            .region = narrow,
        },
        .{
            .source = source,
            .syntax = .markup,
            .region = expanded,
        },
    };
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [requests.len]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &measured, null);
    defer layout.deinit();
    try t.expect(measured[0].width > narrow.width);
    try t.expect(measured[1].width <= narrow.width + 1e-9);
    try t.expect(measured[1].height > measured[0].height);
    try t.expectApproxEqAbs(expanded.width, measured[2].width, 1e-9);
    try t.expectApproxEqAbs(expanded.height, measured[2].height, 1e-9);
}
