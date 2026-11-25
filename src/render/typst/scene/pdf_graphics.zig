//! Layers and mesh paints as one-page PDFs that Typst imports.
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../../drawing/geometry.zig");
const DisplayList = @import("../../../drawing/DisplayList.zig");
const Gradient = @import("../../../drawing/style.zig").Gradient;
const mesh_pdf = @import("../../pdf/mesh.zig");
const fan_mesh = @import("../../../drawing/conic.zig");
const color_patches = @import("../../../drawing/color_patches.zig");
/// Triangles one patch paint may become for SVG, before and after its
/// cuts at the stop levels: the bound on other generated geometry.
const geometry_limit = @import("../../../drawing/outline.zig").max_items;
const typst_scene = @import("../scene.zig");
const native_records = @import("native.zig");
const paint_routes = @import("paint.zig");
const Builder = typst_scene.Builder;
const Painted = paint_routes.Painted;
const controlBounds = paint_routes.controlBounds;

/// Typst's groups have no opacity. For PDF a layer's contents become a
/// page of their own that Typst exports, libtypst draws that page inside
/// one transparency group at the layer's opacity, and Typst imports the
/// result over the document's page. The layer's page is the document's
/// page, with the same size and coordinates, and lies over it without
/// any offset: Quartz paints a gradient pattern of an imported page in
/// the coordinates of the page that imports it. `first` is the command
/// that opens the layer; the result is the one that closes it.
pub fn pdfLayer(self: *Builder, first: usize) anyerror!usize {
    const commands = self.picture.commands.items;
    const last = try closing(commands, first);
    const layer = commands[first].push;
    // Where the current level is drawn, in the picture's coordinates.
    var drawn: g.Transform = .{};
    var index = self.levels.items.len;
    while (index > self.page_base) {
        index -= 1;
        drawn = drawn.then(self.levels.items[index].transform);
    }
    // A layer drawn through a singular transform shows nothing.
    const undrawn = drawn.inverse() catch |err| return if (err == error.SingularTransform) skip(self, commands[first + 1 .. last], last) else err;
    if (!try self.library.supports(c.TYPST_CAP_PDF_PAGE_OPACITY)) return error.Unsupported;
    try preparePdf(self);
    const base = self.page_base;
    defer self.page_base = base;
    self.page_base = self.levels.items.len;
    try self.levels.append(self.arena.allocator(), .{ .transform = layer.transform.then(drawn), .clip = layer.clip });
    try self.emit(first + 1, last);
    const level = self.levels.pop().?;
    var contents = try native_records.item(self, level.transform, level.clip, 0, null);
    contents.kind = c.TYPST_ITEM_SCENE;
    contents.scene = try native_records.childScene(self, level.items.items);
    var root = try native_records.item(self, self.page_transform, null, 0, null);
    root.kind = c.TYPST_ITEM_SCENE;
    root.scene = try native_records.childScene(self, &.{contents});
    const page = try native_records.scene(self, &.{root}, self.size);
    defer self.library.functions.scene_release(page);
    var exported: ?*c.TypstBuffer = null;
    defer self.library.functions.buffer_release(exported);
    var export_report: ?*c.TypstDiagnostics = null;
    defer self.library.functions.diagnostics_release(export_report);
    try self.library.check(self.library.functions.scene_export_pdf(page, null, &exported, &export_report), export_report);
    var wrapped: ?*c.TypstBuffer = null;
    defer self.library.functions.buffer_release(wrapped);
    var wrap_report: ?*c.TypstDiagnostics = null;
    defer self.library.functions.diagnostics_release(wrap_report);
    const contents_pdf = self.library.functions.buffer_data(exported orelse return error.InvalidResult);
    try self.library.check(self.library.functions.pdf_page_with_opacity(contents_pdf, 0, layer.opacity, &wrapped, &wrap_report), wrap_report);
    const imported = try importPdf(self, self.library.functions.buffer_data(wrapped orelse return error.InvalidResult));
    // From the page back to the picture's coordinates, then to the
    // current level's.
    try placePdf(self, imported, try self.page_transform.inverse(), undrawn, 0);
    return last;
}

/// Passes over `contents` of a layer that shows nothing, and the pens of
/// their paths. Returns `last`, the command that closes the layer.
pub fn skip(self: *Builder, contents: []const DisplayList.Command, last: usize) usize {
    for (contents) |*command| if (command.* == .path) if (command.path.style.pen) |*pen| {
        if (pen.resolvesStroke()) self.stroke_index += 1;
    };
    return last;
}

/// What every PDF graphic needs, before any is encoded: the deflate
/// state and a context to import with.
pub fn preparePdf(self: *Builder) !void {
    if (!try self.library.supports(c.TYPST_CAP_PDF_IMPORT)) return error.Unsupported;
    if (self.pdf_workspace == null) self.pdf_workspace = try self.arena.allocator().create(mesh_pdf.Workspace);
    // The import does not depend on fonts, files or inputs; borrowing
    // the current context keeps the typesetter's configuration cached.
    if (self.image_context == null) self.image_context = try typst.Engine.initAny(self.library);
}

/// Hands a one-page PDF graphic to Typst, which copies the bytes. The
/// scene belongs to the builder. Call `preparePdf` first.
pub fn importPdf(self: *Builder, pdf: c.TypstBytes) !*c.TypstScene {
    var image: ?*c.TypstScene = null;
    var diagnostics: ?*c.TypstDiagnostics = null;
    defer self.library.functions.diagnostics_release(diagnostics);
    try self.library.check(self.library.functions.scene_from_pdf(self.image_context.?.handle, pdf, 0, &image, &diagnostics), diagnostics);
    const scene_ = image orelse return error.InvalidResult;
    self.children.append(self.arena.allocator(), scene_) catch |err| {
        self.library.functions.scene_release(scene_);
        return err;
    };
    return scene_;
}

/// Typst has no patch paint. The patches and their exact clip become a
/// one-page PDF graphic that Typst imports and its PDF exporter embeds.
/// Opaque stops become colors at the patches' corners, so the page holds
/// nothing translucent; other stops apply through soft masks.
pub fn pdfPatches(self: *Builder, path_: *const c.TypstPath, evenodd: bool, patches: Gradient.Patches, transform: g.Transform, id: u64) !void {
    const scratch = self.arena.child_allocator;
    if (patches.stops.isOpaque()) {
        const colored = try color_patches.fromField(scratch, patches, DisplayList.Color.tolerance, geometry_limit);
        defer colored.deinit(scratch);
        return pdfColors(self, path_, evenodd, colored.view(), transform, id);
    }
    var shown = try Painted.of(scratch, patches) orelse return;
    defer shown.deinit(scratch);
    try preparePdf(self);
    const encoded = try mesh_pdf.encode(scratch, self.pdf_workspace.?, shown.patches, path_.segments[0..path_.segment_count], evenodd);
    try placeMesh(self, encoded.pdf, encoded.bounds, transform, id);
}

/// Colors at patch corners become a one-page PDF graphic of one mesh.
pub fn pdfColors(self: *Builder, path_: *const c.TypstPath, evenodd: bool, patches: Gradient.ColorPatches, transform: g.Transform, id: u64) !void {
    try preparePdf(self);
    const encoded = try mesh_pdf.encodeColors(self.arena.child_allocator, self.pdf_workspace.?, patches, path_.segments[0..path_.segment_count], evenodd);
    try placeMesh(self, encoded.pdf, encoded.bounds, transform, id);
}

/// Places a mesh page from pdf/mesh.zig, of the unit square, over `box`
/// and frees it.
pub fn placeMesh(self: *Builder, pdf: []u8, box: g.BBox, transform: g.Transform, id: u64) !void {
    // libtypst copies the bytes, and releasing them while they are still
    // the most recent allocation lets an arena reuse the space.
    const imported = imported: {
        defer self.arena.child_allocator.free(pdf);
        break :imported try importPdf(self, .{ .data = pdf.ptr, .len = pdf.len });
    };
    // Imported PDF pages use downward y; the scene's coordinates use
    // upward y.
    try placePdf(self, imported, .{ .a = box.width(), .d = -box.height(), .e = box.min.x, .f = box.max.y }, transform, id);
}

/// Places an imported PDF page, which `page` maps into the coordinates
/// that `transform` maps further.
pub fn placePdf(self: *Builder, imported: *c.TypstScene, page: g.Transform, transform: g.Transform, id: u64) !void {
    var item_ = try native_records.item(self, page.then(transform), null, id, null);
    item_.kind = c.TYPST_ITEM_SCENE;
    item_.scene = imported;
    try self.append(item_);
}

/// A PDF patch mesh draws a fan as patches from its center that reach
/// past the path it fills, within the paint's tolerance.
pub fn pdfFan(self: *Builder, path_: *const c.TypstPath, evenodd: bool, conic: Gradient.Conic, transform: g.Transform, id: u64) !void {
    const scratch = self.arena.child_allocator;
    const lowered = try fan_mesh.patches(scratch, conic, try controlBounds(path_), geometry_limit);
    defer lowered.deinit(scratch);
    try pdfPatches(self, path_, evenodd, .{ .points = lowered.points, .values = lowered.values, .stops = conic.stops, .tolerance = conic.tolerance }, transform, id);
}

/// The index of the `pop` that closes the group `commands[first]` opens.
fn closing(commands: []const DisplayList.Command, first: usize) !usize {
    var depth: usize = 0;
    for (commands[first..], first..) |command, index| switch (command) {
        .push => depth += 1,
        .pop => {
            depth -= 1;
            if (depth == 0) return index;
        },
        else => {},
    };
    return error.UnbalancedGroup;
}
