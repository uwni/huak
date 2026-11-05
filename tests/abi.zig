//! Integration assertions for opaque native ownership and copied C scene data.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const binding = @import("typst_binding");
const c = typst.c;
const options = @import("test_options");

fn check(library: *typst.Library, status: c.TypstStatus, report: *?*c.TypstDiagnostics) !void {
    defer {
        library.functions.diagnostics_release(report.*);
        report.* = null;
    }
    try library.check(status, report.*);
}

fn identity() c.TypstTransform {
    return .{ .xx = 1, .yx = 0, .xy = 0, .yy = 1, .dx = 0, .dy = 0 };
}

test "stable native scene copies geometry styles and nested owners before caller storage expires" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    try t.expectEqual(typst.abi_version, library.functions.abi_version());
    var report: ?*c.TypstDiagnostics = null;
    var child: ?*c.TypstScene = null;
    defer library.functions.scene_release(child);
    {
        var segments = [_]c.TypstPathSegment{
            std.mem.zeroes(c.TypstPathSegment), std.mem.zeroes(c.TypstPathSegment),
            std.mem.zeroes(c.TypstPathSegment), std.mem.zeroes(c.TypstPathSegment),
            std.mem.zeroes(c.TypstPathSegment),
        };
        for (&segments, 0..) |*segment, index| {
            segment.kind = if (index == 0) c.TYPST_SEGMENT_MOVE else if (index == 4) c.TYPST_SEGMENT_CLOSE else c.TYPST_SEGMENT_LINE;
        }
        segments[1].p1 = .{ .x = 20, .y = 0 };
        segments[2].p1 = .{ .x = 20, .y = 10 };
        segments[3].p1 = .{ .x = 0, .y = 10 };
        const path: c.TypstPath = .{ .segments = &segments, .segment_count = segments.len };
        var dash = [_]f64{ 3, 1 };
        var style = std.mem.zeroes(c.TypstStyle);
        style.flags = c.TYPST_STYLE_FILL | c.TYPST_STYLE_STROKE;
        style.fill_rule = c.TYPST_FILL_EVENODD;
        style.fill = .{ .r = 20.0 / 255.0, .g = 40.0 / 255.0, .b = 80.0 / 255.0, .a = 200.0 / 255.0 };
        style.stroke = style.fill;
        style.stroke_width_pt = 2.5;
        style.line_cap = c.TYPST_CAP_ROUND;
        style.line_join = c.TYPST_JOIN_BEVEL;
        style.miter_limit = 7;
        style.dashes = &dash;
        style.dash_count = dash.len;
        style.dash_phase_pt = 0.5;
        var item = std.mem.zeroes(c.TypstSceneItem);
        item.kind = c.TYPST_ITEM_PATH;
        item.transform = identity();
        item.transform.dx = 3;
        item.transform.dy = 4;
        item.path = &path;
        item.style = &style;
        var config = std.mem.zeroes(c.TypstSceneOptions);
        config.struct_size = @sizeOf(c.TypstSceneOptions);
        config.width_pt = 50;
        config.height_pt = 30;
        config.items = &item;
        config.item_count = 1;
        try check(&library, library.functions.scene_create(&config, &child, &report), &report);
        dash[0] = 90;
        segments[1].p1.x = 900;
    }
    var item = std.mem.zeroes(c.TypstSceneItem);
    item.kind = c.TYPST_ITEM_SCENE;
    item.transform = identity();
    item.transform.dx = 7;
    item.transform.dy = 11;
    item.scene = child;
    var group_options = std.mem.zeroes(c.TypstSceneItemOptions);
    group_options.struct_size = @sizeOf(c.TypstSceneItemOptions);
    group_options.flags = c.TYPST_SCENE_ITEM_ISOLATE_TRANSFORM;
    item.options = &group_options;
    var config = std.mem.zeroes(c.TypstSceneOptions);
    config.struct_size = @sizeOf(c.TypstSceneOptions);
    config.width_pt = 80;
    config.height_pt = 50;
    config.items = &item;
    config.item_count = 1;
    var parent: ?*c.TypstScene = null;
    defer library.functions.scene_release(parent);
    try check(&library, library.functions.scene_create(&config, &parent, &report), &report);
    group_options.flags = 0; // Scene creation must copy the caller's options.
    library.functions.scene_release(child);
    child = null;
    var metrics: c.TypstMetrics = undefined;
    try check(&library, library.functions.scene_metrics(parent, &metrics), &report);
    try t.expectEqual(@as(f64, 80), metrics.width_pt);
    try t.expectEqual(@as(f64, 50), metrics.height_pt);
    var svg: ?*c.TypstBuffer = null;
    defer library.functions.buffer_release(svg);
    try check(&library, library.functions.scene_export_svg(parent, &svg, &report), &report);
    const output = binding.bytes(library.functions.buffer_data(svg));
    for ([_][]const u8{
        "translate(7 11)",         "#142850",                   "fill-rule=\"evenodd\"",
        "stroke-width=\"2.5\"",    "stroke-linecap=\"round\"",  "stroke-linejoin=\"bevel\"",
        "stroke-miterlimit=\"7\"", "stroke-dashoffset=\"0.5\"", "stroke-dasharray=\"3 1\"",
    }) |marker| {
        if (std.mem.indexOf(u8, output, marker) == null)
            std.debug.print("missing native SVG marker {s}:\n{s}\n", .{ marker, output });
        try t.expect(std.mem.indexOf(u8, output, marker) != null);
    }
    try t.expect(std.mem.indexOf(u8, output, "stroke-dasharray=\"90") == null);
}

test "retained opaque layouts keep Unicode outlines and selectable PDF fonts after context release" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var retained: ?*c.TypstLayout = null;
    defer library.functions.layout_release(retained);
    {
        var engine = try library.createEngine();
        defer engine.deinit();
        var measured: [1]typst.Metrics = undefined;
        var labels = try engine.layoutContent(&.{.{ .source = "#text(size:17pt)[café Ω office]" }}, &measured, null);
        defer labels.deinit();
        retained = @constCast(try (try labels.frame(0)).nativeLayout(&library));
        library.functions.layout_retain(retained);
    }
    var report: ?*c.TypstDiagnostics = null;
    var outline: ?*c.TypstOutline = null;
    defer library.functions.outline_release(outline);
    try check(&library, library.functions.layout_outline(retained, &outline, &report), &report);
    var view: c.TypstOutlineView = undefined;
    try check(&library, library.functions.outline_view(outline, &view), &report);
    try t.expect(view.path_count > 6 and view.segment_count > 6);
    for (view.paths[0..view.path_count]) |path| {
        try t.expect(path.segment_offset <= view.segment_count);
        try t.expect(path.segment_count <= view.segment_count - path.segment_offset);
    }
    var pdf: ?*c.TypstBuffer = null;
    defer library.functions.buffer_release(pdf);
    try check(&library, library.functions.layout_export_pdf(retained, null, &pdf, &report), &report);
    const output = binding.bytes(library.functions.buffer_data(pdf));
    try t.expect(std.mem.indexOf(u8, output, "/FontFile") != null);
    try t.expect(std.mem.indexOf(u8, output, "/ToUnicode") != null);
}

test "invalid native path tags produce owned diagnostics and a later scene succeeds" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var segment = std.mem.zeroes(c.TypstPathSegment);
    segment.kind = std.math.maxInt(u32);
    const path: c.TypstPath = .{ .segments = &segment, .segment_count = 1 };
    var style = std.mem.zeroes(c.TypstStyle);
    style.flags = c.TYPST_STYLE_FILL;
    style.fill.a = 1;
    var item = std.mem.zeroes(c.TypstSceneItem);
    item.kind = c.TYPST_ITEM_PATH;
    item.transform = identity();
    item.path = &path;
    item.style = &style;
    var config = std.mem.zeroes(c.TypstSceneOptions);
    config.struct_size = @sizeOf(c.TypstSceneOptions);
    config.width_pt = 20;
    config.height_pt = 10;
    config.items = &item;
    config.item_count = 1;
    var report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(report);
    var scene: ?*c.TypstScene = null;
    defer library.functions.scene_release(scene);
    try t.expectError(error.InvalidArgument, library.check(library.functions.scene_create(&config, &scene, &report), report));
    try t.expect(scene == null);
    try t.expect(library.functions.diagnostics_count(report) != 0);
    library.functions.diagnostics_release(report);
    report = null;
    segment.kind = c.TYPST_SEGMENT_MOVE;
    try check(&library, library.functions.scene_create(&config, &scene, &report), &report);
}

test "Zig block queries use native Typst syntax and preserve following host code" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const block = "[\n```typ\n]\nend\n```\n#box[Inner]\n]";
    try t.expectEqual(block.len, try library.sourceBlock(block ++ ".width; fn outer() -> int\nend"));
    try t.expectEqual(@as(usize, 2), try library.sourceBlock("{}\nnot Typst"));
    try t.expectError(error.InvalidArgument, library.sourceBlock("text"));
    try t.expectError(error.CompileFailed, library.sourceBlock("[open"));
    try t.expectError(error.CompileFailed, library.sourceBlock("{let text=\"open}"));
    try t.expectError(error.InvalidUtf8, library.sourceBlock("[\xff]"));
}

test "host engine inputs are copied and available to native code evaluation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var value = "literal data".*;
    const input: typst.Input = .{ .key = "message", .value = &value };
    var engine = try library.createEngineWithOptions(&.{ .inputs = &.{input} });
    defer engine.deinit();
    @memset(&value, 'x');
    var measured: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{ .source = "assert(sys.inputs.message == \"literal data\"); text(sys.inputs.message)", .syntax = .code }}, &measured, null);
    defer layout.deinit();
    try t.expect(measured[0].width > 0 and measured[0].height > 0);
}
