//! Outline geometry from native frames: baseline conversion, cached measurements, unsupported content and clipped geometry.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const options = @import("test_options");
const outline = @import("huak").text.outline;
const DisplayList = @import("huak").core.DisplayList;
const geometry_outline = @import("huak").core.outline;

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
