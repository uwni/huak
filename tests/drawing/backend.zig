//! The native backend's limits: maximum picture nesting and frame-reference validation.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const backend = @import("huak").backend;
const DisplayList = @import("huak").core.DisplayList;
const options = @import("test_options");

test "the maximum supported picture nesting submits through the real native backend" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    for (0..DisplayList.max_scope_depth) |_| try picture.beginScope(.{}, null);
    try t.expectError(error.GroupNestingTooDeep, picture.beginScope(.{}, null));
    var square = try demo.rectangle(t.allocator, .{ .x = 1, .y = 1 }, 2, 2);
    defer square.deinit();
    try picture.fill(square, .{ .color = .{ .g = 1 } }, .{});
    for (0..DisplayList.max_scope_depth) |_| try picture.endScope();
    var document = try backend.submit(t.allocator, &library, &picture, 10, 10, .{});
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.find(u8, svg.bytes(), "fill=\"#00ff00\"") != null);
    var nib_picture = DisplayList.init(t.allocator);
    defer nib_picture.deinit();
    for (0..DisplayList.max_scope_depth) |_| try nib_picture.beginScope(.{}, null);
    try nib_picture.filldraw(square, .{ .color = .{ .g = 1 } }, .{ .nib = .{ .ellipse = .{ .a = 2, .d = 1 } }, .cap = .round, .join = .round }, .{});
    for (0..DisplayList.max_scope_depth) |_| try nib_picture.endScope();
    const nib_ids = try t.allocator.alloc(u64, nib_picture.commands.items.len);
    defer t.allocator.free(nib_ids);
    @memset(nib_ids, 0);
    nib_ids[DisplayList.max_scope_depth] = 77;
    var nib_document = try backend.submit(t.allocator, &library, &nib_picture, 10, 10, .{ .object_ids = nib_ids });
    defer nib_document.deinit();
    var nib_svg = try nib_document.exportSvg(0);
    defer nib_svg.deinit();
    try t.expect(std.mem.find(u8, nib_svg.bytes(), "data-typst-label=\"libtypst-object-77\"") != null);
    const ids = try t.allocator.alloc(u64, picture.commands.items.len);
    defer t.allocator.free(ids);
    @memset(ids, 0);
    ids[DisplayList.max_scope_depth] = 1;
    var identified = try backend.submit(t.allocator, &library, &picture, 10, 10, .{ .object_ids = ids });
    defer identified.deinit();
    var identified_svg = try identified.exportSvg(0);
    defer identified_svg.deinit();
    try t.expect(std.mem.find(u8, identified_svg.bytes(), "libtypst-object-1") != null);
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
    try t.expect(std.mem.find(u8, svg.bytes(), "<use ") != null);
}
