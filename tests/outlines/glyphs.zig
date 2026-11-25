//! Editable glyph outlines: ownership after release, optional outlining, baselines of fixed-height content, independent frames and RTL clusters.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const options = @import("test_options");
const outline = @import("huak").text.outline;
const backend = @import("huak").backend;
const g = @import("huak").core.geometry;
const DisplayList = @import("huak").core.DisplayList;

fn request(comptime text: []const u8, comptime syntax: typst.Syntax, comptime size: u32) typst.LayoutRequest {
    const content = if (syntax == .math) "$" ++ text ++ "$" else text;
    const source = std.fmt.comptimePrint("#text(size: {d}pt, fill: rgb(40, 80, 120, 230))[{s}]", .{ size, content });
    return .{
        .source = source,
        .syntax = .markup,
    };
}

fn metrics(raw: typst.Metrics) DisplayList.Metrics {
    return .{ .width = raw.width, .height = raw.height, .baseline = raw.baseline };
}

test "native glyph outlines become owned editable huak paths after labels and engine are released" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        request("office é g", .markup, 24),
        request("frac(a, b)", .math, 24),
    };
    var measured: [requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var batch = try outline.extract(t.allocator, &labels);
    defer batch.deinit();
    labels.deinit();
    engine.deinit();
    try t.expectEqual(requests.len, batch.labels.len);
    var saw_cubic = false;
    var glyph_count: usize = 0;
    for (batch.labels[0].parts) |*part| {
        try t.expectEqual(outline.PartKind.glyph, part.kind);
        try t.expect(part.cluster_start <= part.cluster_end and part.cluster_end <= part.run_text.len);
        try t.expect(std.unicode.utf8ValidateSlice(part.clusterText()));
        try t.expect(part.style.fill != null);
        if (part.path.segmentCount() != 0) glyph_count += 1;
        for (part.path.segments.items) |item| if (item == .cubic) {
            saw_cubic = true;
        };
    }
    try t.expect(glyph_count >= 6);
    try t.expect(saw_cubic);
    var combined = try batch.labels[0].combinedPath(t.allocator);
    defer combined.deinit();
    const original_bounds = combined.bounds().?;
    try t.expect(original_bounds.width() > 30);
    try t.expect(original_bounds.max.y > 0 and original_bounds.min.y < 0); // g descender
    try combined.transform(.{ .a = 1.3, .d = 0.8, .e = 20, .f = 40 });
    try t.expectApproxEqAbs(original_bounds.min.x * 1.3 + 20, combined.bounds().?.min.x, 1e-8);
    var shape_count: usize = 0;
    for (batch.labels[1].parts) |part| if (part.kind == .shape) {
        shape_count += 1;
    };
    try t.expect(shape_count > 0); // The fraction bar is geometry, not a glyph.

    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.filldraw(combined, .{ .color = .{ .r = 0.8, .g = 0.2, .b = 0.3 } }, .{ .width = 0.5 }, .{});
    try batch.labels[1].addToPicture(&picture, .{ .e = 30, .f = 100 });
    var document = try backend.submit(t.allocator, &library, &picture, 300, 160, .{});
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<symbol") == null);
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-1.7"));
    // Every visible item is real path geometry. No invisible text overlay.
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") == null);
}

test "optional outlining leaves normal labels selectable in the same PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        request("ART", .markup, 45),
        request("Copy this normal text.", .markup, 15),
    };
    var measured: [requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var batch = try outline.extract(t.allocator, &labels);
    defer batch.deinit();
    var combined = try batch.labels[0].combinedPath(t.allocator);
    defer combined.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.fill(combined, .{ .color = .{ .r = 0.1, .g = 0.5, .b = 0.8 } }, .{ .e = 20, .f = 70 });
    try picture.labelAtBaseline(1, metrics(measured[1]), .{ .x = 20, .y = 30 }, .{});
    var document = try backend.submit(t.allocator, &library, &picture, 250, 140, .{ .frames = &frames });
    defer document.deinit();
    labels.deinit();
    engine.deinit();
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
}

test "fixed-height Typst content retains its external baseline in native labels and editable outlines" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{request("#block(height: 1pt)[X]", .markup, 11)};
    var measured: [1]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    try t.expectApproxEqAbs(@as(f64, 1), measured[0].height, 1e-9);
    try t.expect(measured[0].baseline > measured[0].height);
    const native_metrics = try labels.metrics(0);
    try t.expectEqual(measured[0].width, native_metrics.width);
    try t.expectEqual(measured[0].height, native_metrics.height);
    try t.expectEqual(measured[0].baseline, native_metrics.baseline);
    var batch = try outline.extract(t.allocator, &labels);
    defer batch.deinit();
    try t.expectEqualDeep(metrics(native_metrics), batch.labels[0].metrics);
    var combined = try batch.labels[0].combinedPath(t.allocator);
    defer combined.deinit();
    const original_bounds = combined.bounds().?;
    try t.expect(original_bounds.width() > 0 and original_bounds.height() > 0);
    try combined.transform(g.Transform.scaling(2, 1));
    try t.expectApproxEqAbs(2 * original_bounds.width(), combined.bounds().?.width(), 1e-9);
    const frames = [_]typst.FrameRef{try labels.frame(0)};
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.labelAtBaseline(0, metrics(measured[0]), .{ .x = 10, .y = 20 }, .{});
    try picture.fill(combined, .{ .color = .{ .r = 0.8, .g = 0.2, .b = 0.2 } }, .{ .e = 40, .f = 20 });
    var document = try backend.submit(t.allocator, &library, &picture, 100, 50, .{ .frames = &frames });
    defer document.deinit();
    labels.deinit();
    engine.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<use ") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path ") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#cc3333\"") != null);
}

test "independent native frames produce separately owned editable glyph paths" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{ request("A", .markup, 18), request("B", .markup, 27) };
    var measured: [requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var batch = try outline.extract(t.allocator, &labels);
    defer batch.deinit();
    labels.deinit();
    engine.deinit();
    try t.expectEqual(@as(usize, 2), batch.labels.len);
    try t.expectEqualStrings("A", batch.labels[0].parts[0].clusterText());
    try t.expectEqualStrings("B", batch.labels[1].parts[0].clusterText());
    try t.expect(batch.labels[0].parts[0].glyph_id != batch.labels[1].parts[0].glyph_id);
    for (batch.labels, measured) |label, metric| {
        try t.expectApproxEqAbs(metric.width, label.metrics.width, 1e-9);
        try t.expectApproxEqAbs(metric.baseline, label.metrics.baseline, 1e-9);
    }
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try batch.labels[0].addToPicture(&picture, .{ .e = 10, .f = 40 });
    try batch.labels[1].addToPicture(&picture, .{ .e = 60, .f = 40 });
    var document = try backend.submit(t.allocator, &library, &picture, 120, 70, .{});
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.count(u8, svg.bytes(), "<path ") >= 2);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<symbol ") == null);
}

test "editable glyphs retain combining RTL clusters and scale with their native font size" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        request("a\u{301}o\u{308}", .markup, 18),
        request("שלום", .markup, 18),
        request("Scale g", .markup, 18),
        request("Scale g", .markup, 36),
    };
    var measured: [requests.len]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &measured, null);
    defer layout.deinit();
    var batch = try outline.extract(t.allocator, &layout);
    defer batch.deinit();
    for (batch.labels[0..2]) |label| {
        try t.expect(label.parts.len > 0);
        for (label.parts) |part| {
            try t.expect(part.clusterText().len > 0);
            try t.expect(std.unicode.utf8ValidateSlice(part.clusterText()));
            try t.expect(part.transform.isFinite() and part.advance.isFinite());
        }
    }
    var small = try batch.labels[2].combinedPath(t.allocator);
    defer small.deinit();
    var large = try batch.labels[3].combinedPath(t.allocator);
    defer large.deinit();
    try t.expectApproxEqAbs(small.bounds().?.width() * 2, large.bounds().?.width(), 1e-8);
    try t.expectApproxEqAbs(small.bounds().?.height() * 2, large.bounds().?.height(), 1e-8);
}
