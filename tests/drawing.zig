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
    try picture.fill(box, .{ .b = 1 }, .{});
    var plain = try backend.submit(t.allocator, &library, &picture, 100, 100, .{});
    defer plain.deinit();
    var normal_pdf = try plain.exportPdf();
    defer normal_pdf.deinit();
    var enabled = try backend.submit(t.allocator, &library, &picture, 100, 100, .{ .pdf_mesh = true });
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
    try picture.addPath(boundary, .{ .fill = .black, .fill_rule = .evenodd, .gradient = &.{ .mesh_fill = .{
        .vertices = &.{
            .{ .x = 0, .y = 0, .r = 1, .g = 0, .b = 0, .a = 0.5 },
            .{ .x = 60, .y = 0, .r = 1, .g = 0, .b = 0, .a = 0.5 },
            .{ .x = 60, .y = 60, .r = 1, .g = 0, .b = 0, .a = 0.5 },
            .{ .x = 0, .y = 60, .r = 1, .g = 0, .b = 0, .a = 0.5 },
        },
        .triangles = &.{ .{ 0, 1, 2 }, .{ 0, 2, 3 } },
    } } }, .{ .e = 10, .f = 10 });
    try picture.endScope();
    var foreground = try demo.rectangle(t.allocator, .{ .x = 12, .y = 12 }, 6, 6);
    defer foreground.deinit();
    try picture.fill(foreground, .{ .g = 1 }, .{});
    try picture.labelAtBaseline(0, demo.metrics(metrics[0]), .{ .x = 4, .y = 85 }, .{});
    const frames = [_]typst.FrameRef{try text.frame(0)};
    const scene: @import("huak").render.Scene = .{ .picture = &picture, .size = .{ .x = 100, .y = 100 }, .frames = &frames };
    try t.expectError(error.MeshRequiresPdf, scene.validate(.svg));
    try scene.validate(.pdf);
    {
        const capabilities = library.capabilities.?;
        defer library.capabilities = capabilities;
        library.capabilities = capabilities & ~@as(u64, typst.c.TYPST_CAP_PDF_IMPORT);
        try t.expectError(error.Unsupported, backend.submit(t.allocator, &library, &picture, 100, 100, .{ .frames = &frames, .pdf_mesh = true }));
    }
    var document = try backend.submit(t.allocator, &library, &picture, 100, 100, .{ .frames = &frames, .pdf_mesh = true });
    defer document.deinit();
    text.deinit();
    engine.deinit();
    var pdf = try document.exportPdf();
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ShadingType 4") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/Subtype /Image") == null);
    const words = try @import("support/pdf.zig").text(pdf.bytes(), .{});
    defer t.allocator.free(words);
    try t.expect(std.mem.indexOf(u8, words, "Native mesh") != null);
    try t.expect(std.mem.indexOf(u8, words, "𝑥") != null);
    try t.expect(std.mem.indexOf(u8, words, "2") != null);
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(t.io, .{ .sub_path = "mesh.pdf", .data = pdf.bytes() });
    const raster = try std.process.run(t.allocator, t.io, .{ .argv = &.{ "pdftoppm", "-r", "72", "-singlefile", "mesh.pdf" }, .cwd = .{ .dir = temporary.dir } });
    defer t.allocator.free(raster.stdout);
    defer t.allocator.free(raster.stderr);
    try t.expect(raster.term.success());
    const header = "P6\n100 100\n255\n";
    try t.expect(std.mem.startsWith(u8, raster.stdout, header));
    const pixels = raster.stdout[header.len..];
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
    try picture.filldraw(square, .{ .r = 0.2, .g = 0.4 }, .{ .nib = nib.nib, .color = .{ .b = 1 }, .cap = .round, .join = .round }, .{});
    try picture.draw(line, .{ .nib = .{ .ellipse = .{ .a = 0, .d = 6 } }, .color = .{ .r = 1 }, .cap = .round, .join = .round }, g.Transform.translation(0, 35));
    try picture.draw(line, .{ .nib = .{ .ellipse = ellipse }, .dash = &.{ 10, 5 }, .dash_phase = -2, .cap = .round, .join = .round }, g.Transform.translation(0, 55));
    // The centre of the square keeps its solid fill. The nib's footprint
    // receives the gradient, in the coordinates of the original path.
    try picture.addPath(square, .{
        .fill = .{ .g = 1 },
        .pen = .{ .nib = .{ .ellipse = ellipse } },
        .gradient = &.{ .linear_stroke = .{ .start = .zero, .end = .{ .x = 40, .y = 10 }, .colors = &.{ .black, .{ .r = 1 } } } },
    }, .{});
    const ids = [_]u64{ 10, 20, 30, 40, 50 };
    var document = try backend.submit(t.allocator, &library, &picture, 120, 110, .{ .object_ids = &ids });
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    for (ids) |id| {
        var storage: [96]u8 = undefined;
        const marker = try std.fmt.bufPrint(&storage, "data-typst-label=\"libtypst-object-{d}\"", .{id});
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), marker));
    }
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "stroke-width=\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#0000ff\"") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#ff0000\"") != null);
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
        try picture.draw(curve, .{ .nib = nib.nib, .dash = dash, .color = .{ .r = 1, .a = 0.5 }, .cap = .round, .join = .round }, .{});
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
            const end = std.mem.indexOfScalar(u8, attribute, '"') orelse return error.InvalidSvg;
            found_curve = found_curve or std.mem.indexOfAny(u8, attribute[0..end], "cCsS") != null;
        }
        try t.expect(found_curve);
        var pdf = try document.exportPdf();
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    }
}

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
        try t.expect(std.mem.indexOf(u8, svg.bytes(), expected) != null);
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
            try picture.fill(square, .{ .r = 0.2, .g = 0.45, .b = 0.7, .a = 0.7 }, .{ .e = @as(f64, @floatFromInt(index % 32)) * 4, .f = @as(f64, @floatFromInt(index / 32)) * 4 });
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

test "the maximum supported picture nesting submits through the real native backend" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    for (0..DisplayList.max_scope_depth) |_| try picture.beginScope(.{}, null);
    try t.expectError(error.GroupNestingTooDeep, picture.beginScope(.{}, null));
    var square = try demo.rectangle(t.allocator, .{ .x = 1, .y = 1 }, 2, 2);
    defer square.deinit();
    try picture.fill(square, .{ .g = 1 }, .{});
    for (0..DisplayList.max_scope_depth) |_| try picture.endScope();
    var document = try backend.submit(t.allocator, &library, &picture, 10, 10, .{});
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#00ff00\"") != null);
    var nib_picture = DisplayList.init(t.allocator);
    defer nib_picture.deinit();
    for (0..DisplayList.max_scope_depth) |_| try nib_picture.beginScope(.{}, null);
    try nib_picture.filldraw(square, .{ .g = 1 }, .{ .nib = .{ .ellipse = .{ .a = 2, .d = 1 } }, .cap = .round, .join = .round }, .{});
    for (0..DisplayList.max_scope_depth) |_| try nib_picture.endScope();
    const nib_ids = try t.allocator.alloc(u64, nib_picture.commands.items.len);
    defer t.allocator.free(nib_ids);
    @memset(nib_ids, 0);
    nib_ids[DisplayList.max_scope_depth] = 77;
    var nib_document = try backend.submit(t.allocator, &library, &nib_picture, 10, 10, .{ .object_ids = nib_ids });
    defer nib_document.deinit();
    var nib_svg = try nib_document.exportSvg(0);
    defer nib_svg.deinit();
    try t.expect(std.mem.indexOf(u8, nib_svg.bytes(), "data-typst-label=\"libtypst-object-77\"") != null);
    const ids = try t.allocator.alloc(u64, picture.commands.items.len);
    defer t.allocator.free(ids);
    @memset(ids, 0);
    ids[DisplayList.max_scope_depth] = 1;
    var identified = try backend.submit(t.allocator, &library, &picture, 10, 10, .{ .object_ids = ids });
    defer identified.deinit();
    var identified_svg = try identified.exportSvg(0);
    defer identified_svg.deinit();
    try t.expect(std.mem.indexOf(u8, identified_svg.bytes(), "libtypst-object-1") != null);
}

// These structural checks verify that fonts and Unicode mappings survive the
// native FFI path. Poppler extraction tests in libtypst/tests/pdf.rs verify the
// actual copied text; finding these markers alone does not prove copy fidelity.
fn expectPdfTextResources(bytes: []const u8) !void {
    try t.expect(std.mem.startsWith(u8, bytes, "%PDF-1.7"));
    for ([_][]const u8{ "/FontFile", "/ToUnicode", "%%EOF" }) |expected| {
        try t.expect(std.mem.indexOf(u8, bytes, expected) != null);
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
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#c02030\"") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#2040c0\"") != null);
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

test "native backend validates frame references and accepts two wrappers for one library instance" {
    const source = "Owned content";
    const requests = [_]typst.LayoutRequest{.{
        .source = source,
        .syntax = .markup,
        .region = null,
    }};
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var other = try typst.Library.open(options.library_path);
    defer other.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &measured, null);
    defer layout.deinit();
    const frames = [_]typst.FrameRef{try layout.frame(0)};
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.labelAtBaseline(0, demo.metrics(measured[0]), .{ .x = 5, .y = 20 }, .{});
    try t.expectError(error.InvalidFrameReference, backend.submit(t.allocator, &library, &picture, 160, 40, .{}));
    try t.expectError(error.InvalidFrameReference, backend.submit(t.allocator, &library, &picture, 160, 40, .{ .frames = &.{} }));
    var document = try backend.submit(t.allocator, &other, &picture, 160, 40, .{ .frames = &frames });
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<use ") != null);
}
