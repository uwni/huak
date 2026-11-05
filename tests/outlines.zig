const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const options = @import("test_options");
const outline = @import("huak").text.outline;
const backend = @import("huak").backend;
const g = @import("huak").core.geometry;
const DisplayList = @import("huak").core.DisplayList;
const geometry_outline = @import("huak").core.outline;

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
    try picture.filldraw(combined, .{ .r = 0.8, .g = 0.2, .b = 0.3 }, .{ .width = 0.5 }, .{});
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
    try picture.fill(combined, .{ .r = 0.1, .g = 0.5, .b = 0.8 }, .{ .e = 20, .f = 70 });
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
    try picture.fill(combined, .{ .r = 0.8, .g = 0.2, .b = 0.2 }, .{ .e = 40, .f = 20 });
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

fn fixtureLayout(engine: *typst.Engine, baseline: f64, visible: bool, measured: *[1]typst.Metrics) !typst.Layout {
    // Use public Typst content to construct both contours and an out-of-box
    // baseline. The C boundary no longer exposes mutable native Frames.
    const source = try std.fmt.allocPrint(t.allocator, "#v({d}pt,weak:false)#box(width:16pt,height:25pt,baseline:top)[" ++
        "#place(top+left,dx:3pt,dy:{d}pt,curve(fill:{s},stroke:{s}," ++
        "curve.move((0pt,0pt)),curve.line((10pt,0pt)),curve.line((10pt,10pt)),curve.line((0pt,10pt)),curve.close()," ++
        "curve.move((3pt,3pt)),curve.line((3pt,7pt)),curve.line((7pt,7pt)),curve.line((7pt,3pt)),curve.close()))]#v({d}pt,weak:false)", .{ baseline, 4 - baseline, if (visible) "rgb(20,30,40)" else "none", if (visible) "(paint:rgb(20,30,40),thickness:2pt,cap:\"round\",join:\"miter\",miter-limit:7,dash:(array:(3pt,0pt,2pt),phase:-1pt))" else "none", -baseline });
    defer t.allocator.free(source);
    return engine.layoutContent(&.{.{ .source = source }}, measured, null);
}

fn checkFixture(allocator: std.mem.Allocator, labels: *const typst.Layout, baseline: f64) !void {
    var batch = try outline.extract(allocator, labels);
    defer batch.deinit();
    try t.expectEqual(@as(usize, 1), batch.labels.len);
    try t.expectEqual(@as(usize, 1), batch.labels[0].parts.len);
    const part = &batch.labels[0].parts[0];
    try t.expectEqual(outline.PartKind.shape, part.kind);
    try t.expectEqualSlices(f64, &.{ 3, 0, 2 }, part.style.pen.?.dash);
    try t.expectEqual(@as(f64, 7), part.style.pen.?.miter_limit);
    var combined = try batch.labels[0].combinedPath(allocator);
    defer combined.deinit();
    // Native curve.close emits the final line as well as the close operation.
    try t.expectEqual(@as(usize, 12), combined.segments.items.len);
    const bounds = combined.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 3), bounds.min.x, 1e-10);
    try t.expectApproxEqAbs(baseline - 14, bounds.min.y, 1e-10);
    try t.expectApproxEqAbs(@as(f64, 13), bounds.max.x, 1e-10);
    try t.expectApproxEqAbs(baseline - 4, bounds.max.y, 1e-10);
    var closes: usize = 0;
    for (combined.segments.items) |item| if (item == .close) {
        closes += 1;
    };
    try t.expectEqual(@as(usize, 2), closes);
}

test "native frame baseline conversion preserves compound counters dash ownership and allocation cleanup" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    for ([_]f64{ -3, 20, 30 }) |baseline| {
        var measured: [1]typst.Metrics = undefined;
        var labels = try fixtureLayout(&engine, baseline, true, &measured);
        defer labels.deinit();
        try t.expectApproxEqAbs(baseline, measured[0].baseline, 1e-9);
        try checkFixture(t.allocator, &labels, baseline);
        if (baseline == 20) try t.checkAllAllocationFailures(t.allocator, checkFixture, .{ &labels, baseline });
    }
    var measured: [1]typst.Metrics = undefined;
    var invisible = try fixtureLayout(&engine, 20, false, &measured);
    defer invisible.deinit();
    var batch = try outline.extract(t.allocator, &invisible);
    defer batch.deinit();
    const part = batch.labels[0].parts[0];
    try t.expect(part.style.fill == null and part.style.pen == null);
    var silhouette = try batch.labels[0].combinedPath(t.allocator);
    defer silhouette.deinit();
    try t.expectEqual(@as(usize, 0), silhouette.segmentCount());
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try batch.labels[0].addToPicture(&picture, .{});
    try t.expectEqual(@as(usize, 0), picture.commands.items.len);
}

test "huak rejects invalid cached measurements and native layout rejects invalid regions" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [1]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&.{.{ .source = "" }}, &measured, null);
    defer labels.deinit();
    const valid = labels.handle.?.measurements[0];
    inline for (.{ "width", "height", "baseline" }) |field| {
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
            labels.handle.?.measurements[0] = valid;
            @field(labels.handle.?.measurements[0], field) = value;
            try t.expectError(error.InvalidResult, outline.extract(t.allocator, &labels));
        }
    }
    inline for (.{ "width", "height" }) |field| {
        labels.handle.?.measurements[0] = valid;
        @field(labels.handle.?.measurements[0], field) = -1;
        try t.expectError(error.InvalidResult, outline.extract(t.allocator, &labels));
    }
    labels.handle.?.measurements[0] = valid;
    for ([_]typst.Region{
        .{ .width = std.math.nan(f64) },                   .{ .height = std.math.nan(f64) },
        .{ .width = -1 },                                  .{ .height = -1 },
        .{ .width = std.math.inf(f64), .expand_x = true }, .{ .height = std.math.inf(f64), .expand_y = true },
    }) |region| try t.expectError(error.InvalidArgument, engine.layoutContent(&.{.{ .source = "Invalid region", .region = region }}, &measured, null));
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

test "unsupported content rejects the whole editable batch with a retained diagnostic" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    for ([_][]const u8{
        "#text(fill: gradient.linear(red, blue))[O]",
    }) |source| {
        const requests = [_]typst.LayoutRequest{ .{ .source = "Valid" }, .{ .source = source } };
        var measured: [2]typst.Metrics = undefined;
        var layout = try engine.layoutContent(&requests, &measured, null);
        defer layout.deinit();
        try t.expectError(error.Unsupported, outline.extract(t.allocator, &layout));
        var diagnostic = try library.lastError();
        defer diagnostic.deinit();
        try t.expect(std.mem.indexOf(u8, diagnostic.bytes(), "do not support") != null);
    }
    var measured: [1]typst.Metrics = undefined;
    var good = try engine.layoutContent(&.{.{ .source = "Still works" }}, &measured, null);
    defer good.deinit();
    var batch = try outline.extract(t.allocator, &good);
    defer batch.deinit();
    try t.expect(batch.labels[0].parts.len > 0);
}

fn checkClippedGeometry(allocator: std.mem.Allocator, label: *const outline.Label) !void {
    var picture = DisplayList.init(allocator);
    defer picture.deinit();
    try label.addToPicture(&picture, .{});
    var extracted = try geometry_outline.extract(allocator, .{ .picture = &picture }, null);
    defer extracted.deinit();
    var region = try @import("huak").core.region.coverage.extract(allocator, &extracted, .{});
    defer region.deinit();
    const box = region.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 0), box.min.x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 20), box.max.x, 0.001);
    try t.expectApproxEqAbs(label.metrics.baseline - 12, box.min.y, 0.001);
    try t.expectApproxEqAbs(label.metrics.baseline, box.max.y, 0.001);
}

fn checkAppendRollback(allocator: std.mem.Allocator, label: *const outline.Label) !void {
    var target = DisplayList.init(allocator);
    defer target.deinit();
    var circle = try @import("huak").core.Path.circle(allocator, .zero, 3);
    defer circle.deinit();
    try target.fill(circle, .black, .{});
    try target.beginScope(.{}, null);
    const commands = target.commands.items.len;
    const segments = target.storage.segments.items.len;
    const depth = target.scope_depth;
    const maximum = target.maximum_depth;
    const styles = target.storage.styles.entries.count();
    const first_command = target.commands.items[0];
    const first_segment = target.storage.segments.items[0];
    label.addToPicture(&target, .{}) catch |err| {
        try t.expectEqual(commands, target.commands.items.len);
        try t.expectEqual(segments, target.storage.segments.items.len);
        try t.expectEqual(depth, target.scope_depth);
        try t.expectEqual(maximum, target.maximum_depth);
        try t.expectEqual(styles, target.storage.styles.entries.count());
        try t.expectEqualDeep(first_command, target.commands.items[0]);
        try t.expectEqualDeep(first_segment, target.storage.segments.items[0]);
        return err;
    };
    try t.expectEqual(depth, target.scope_depth);
    try target.endScope();
}

test "native clipped geometry survives layout release and shares unified extraction and allocation cleanup" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{
        .source = "#box(width:20pt,height:12pt,clip:true)[" ++
            "#place(top+left,dx:-4pt,dy:-3pt,rect(width:32pt,height:20pt,stroke:none,fill:black))]",
    }}, &measured, null);
    defer layout.deinit();
    var batch = try outline.extract(t.allocator, &layout);
    defer batch.deinit();
    layout.deinit();
    engine.deinit();
    var clips: usize = 0;
    var ends: usize = 0;
    for (batch.labels[0].parts) |part| switch (part.kind) {
        .clip_begin => clips += 1,
        .clip_end => ends += 1,
        else => {},
    };
    try t.expect(clips > 0);
    try t.expectEqual(clips, ends);
    try checkClippedGeometry(t.allocator, &batch.labels[0]);
    // Pin the allocation sequence: the backing allocator can otherwise grow
    // an array in place on one iteration and allocate on another. Force the
    // ordinary reallocation path so every allocation can be failed in turn.
    var moving = std.testing.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(moving.allocator(), checkClippedGeometry, .{&batch.labels[0]});
    try t.expectError(error.ClippedOutline, batch.labels[0].combinedPath(t.allocator));

    var begin: outline.Part = undefined;
    var shape: outline.Part = undefined;
    var end: outline.Part = undefined;
    for (batch.labels[0].parts) |part| switch (part.kind) {
        .clip_begin => begin = part,
        .clip_end => end = part,
        .shape => shape = part,
        else => {},
    };
    // A native Curve may be completely empty. Its scope must hide even
    // nested content, then restore the following sibling's visibility.
    var empty_begin = begin;
    empty_begin.path = .init(t.allocator);
    var hidden_parts = [_]outline.Part{ empty_begin, begin, shape, end, end, shape };
    const hidden: outline.Label = .{ .metrics = batch.labels[0].metrics, .parts = &hidden_parts };
    var restored = DisplayList.init(t.allocator);
    defer restored.deinit();
    try hidden.addToPicture(&restored, .{});
    try t.expectEqual(@as(usize, 1), restored.commands.items.len);
    try t.expectEqual(@as(usize, 0), restored.scope_depth);
    try t.expectEqualDeep(shape.style, restored.commands.items[0].path.style.*);
    try t.expectEqualDeep(shape.transform, restored.commands.items[0].path.transform);
    // Inject failure after at least one native clip was appended, against a
    // target that already contains both geometry and an enclosing group.
    var nested_parts = [_]outline.Part{ begin, begin, shape, end, end };
    const nested: outline.Label = .{ .metrics = batch.labels[0].metrics, .parts = &nested_parts };
    try checkAppendRollback(t.allocator, &nested);
    try t.checkAllAllocationFailures(t.allocator, checkAppendRollback, .{&nested});
    const malformed: outline.Label = .{ .metrics = batch.labels[0].metrics, .parts = nested_parts[0..1] };
    try t.expectError(error.InvalidResult, checkAppendRollback(t.allocator, &malformed));
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
