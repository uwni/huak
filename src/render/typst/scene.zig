//! Encodes picture commands directly into immutable native scenes. Only
//! physical-pen geometry needs preparation; ordinary commands are borrowed.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Path = @import("../../drawing/path/Path.zig");
const pens = @import("../../drawing/pen/root.zig");
const mesh_pdf = @import("../pdf/mesh.zig");
const svg_styles = @import("../svg/styles.zig");
const pen_strokes = @import("scene/strokes.zig");
const native_records = @import("scene/native.zig");
const pdf_graphics = @import("scene/pdf_graphics.zig");
const paint_routes = @import("scene/paint.zig");
const NativeSegments = @import("scene/NativeSegments.zig");
const nativeTransform = native_records.nativeTransform;

pub const SubmitOptions = struct {
    origin: g.Point = .zero,
    frames: ?[]const typst.FrameRef = null,
    /// IDs address picture.commands. Zero is unmarked; UINT64_MAX identifies
    /// huak's mathematical root group when animation IDs are present.
    object_ids: ?[]const u64 = null,
    pen_geometry: pens.StrokeOptions = .{},
    /// The document is exported as PDF: meshes and layers, which Typst's
    /// scene cannot hold, become PDF graphics that Typst imports. Otherwise
    /// they take the forms SVG has for them.
    pdf: bool = false,
};

pub const FrameBounds = struct {
    frames: []const typst.FrameRef,
    pub fn resolveBounds(self: FrameBounds, reference: u32) !g.BBox {
        if (reference >= self.frames.len) return error.InvalidFrameReference;
        const frame = self.frames[reference];
        const box = try frame.layout.bounds(frame.index);
        return .{ .min = .{ .x = box[0].x, .y = box[0].y }, .max = .{ .x = box[1].x, .y = box[1].y } };
    }
};

pub fn viewport(picture: *const DisplayList, size: ?g.Point, frames: []const typst.FrameRef) !g.BBox {
    if (size) |fixed| return .{ .min = .zero, .max = fixed };
    var strokes: pen_strokes.Strokes = .{ .workspace = .init(picture.storage.allocator) };
    defer strokes.workspace.deinit();
    return (try picture.measuredBounds(FrameBounds{ .frames = frames }, &strokes)) orelse .{ .min = .zero, .max = .zero };
}

/// Drawing defaults, grouping, IDs and physical-nib expansion belong to huak.
/// Native calls submit complete paths and whole scene-item arrays.
pub fn submit(allocator: std.mem.Allocator, library: *typst.Library, picture: *const DisplayList, width: f64, height: f64, options: SubmitOptions) !typst.Document {
    return submitPicture(allocator, library, picture, .{ .x = width, .y = height }, options);
}

pub fn submitPicture(allocator: std.mem.Allocator, library: *typst.Library, picture: *const DisplayList, size: ?g.Point, options: SubmitOptions) !typst.Document {
    library.clearError();
    if (size) |p| if (!p.isFinite() or p.x <= 0 or p.y <= 0) return error.InvalidCanvas;
    if (options.object_ids) |ids| {
        if (ids.len != picture.commands.items.len) return error.InvalidObjectIds;
        var seen: std.AutoHashMap(u64, void) = .init(allocator);
        defer seen.deinit();
        for (ids, picture.commands.items) |id, *command| {
            if (id == 0) continue;
            if (id == std.math.maxInt(u64) or command.* == .pop or (try seen.getOrPut(id)).found_existing) return error.InvalidObjectIds;
        }
    }
    if (size != null) _ = try picture.bounds();
    return document(allocator, library, picture, size, options);
}

fn document(allocator: std.mem.Allocator, library: *typst.Library, picture: *const DisplayList, size: ?g.Point, options: SubmitOptions) !typst.Document {
    var builder: Builder = .{
        .arena = .init(allocator),
        .library = library,
        .picture = picture,
        .labels = options.frames orelse &.{},
        .object_ids = options.object_ids,
        .pen_options = options.pen_geometry,
        .size = undefined,
        .pdf = options.pdf,
    };
    defer builder.deinit();
    const memory = builder.arena.allocator();
    // Resolve all physical pens before native submission, preserving geometry
    // diagnostics ahead of frame-reference or native scene errors.
    var origin = options.origin;
    builder.strokes = if (size) |page| fixed: {
        builder.size = .{ .x = page.x, .y = page.y };
        break :fixed try pen_strokes.prepareStrokes(&builder);
    } else fitted: {
        var strokes = pen_strokes.strokePass(&builder);
        defer strokes.workspace.deinit();
        const box = (try picture.measuredBounds(FrameBounds{ .frames = builder.labels }, &strokes)) orelse return error.InvalidCanvas;
        const page = box.max.sub(box.min);
        if (!page.isFinite() or page.x <= 0 or page.y <= 0) return error.InvalidCanvas;
        builder.size = .{ .x = page.x, .y = page.y };
        origin = box.min;
        break :fitted strokes.items.items;
    };
    builder.segments = try NativeSegments.init(memory, picture);
    builder.page_transform = .{ .d = -1, .e = -origin.x, .f = builder.size.y + origin.y };
    try builder.levels.append(memory, .{});
    try builder.emit(0, picture.commands.items.len);
    if (builder.levels.items.len != 1) return error.UnbalancedGroup;
    const child = try native_records.childScene(&builder, builder.levels.items[0].items.items);
    var root_item = try native_records.item(&builder, builder.page_transform, null, if (options.object_ids != null) std.math.maxInt(u64) else 0, null);
    root_item.kind = c.TYPST_ITEM_SCENE;
    root_item.scene = child;
    const root = try native_records.scene(&builder, &.{root_item}, builder.size);
    return typst.Document.fromSceneOwned(library, root);
}

const Level = struct {
    transform: g.Transform = .{},
    clip: ?DisplayList.PathRef = null,
    id: u64 = 0,
    opacity: f64 = 1,
    items: std.ArrayList(c.TypstSceneItem) = .empty,
};

pub const Builder = struct {
    /// A resolved stroke: a native stroke of the normalized ellipse, or its
    /// footprint filled with the pen's paint.
    pub const Stroke = struct { path: *const c.TypstPath, style: DisplayList.Style, transform: ?g.Transform };
    arena: std.heap.ArenaAllocator,
    library: *typst.Library,
    picture: *const DisplayList,
    /// Typeset labels, by the picture's label references.
    labels: []const typst.FrameRef = &.{},
    /// Animation targets, by command.
    object_ids: ?[]const u64 = null,
    pen_options: pens.StrokeOptions = .{},
    /// Physical pens, resolved in the order of their paths, and the next one
    /// to submit.
    strokes: []const ?Stroke = &.{},
    stroke_index: usize = 0,
    size: c.TypstPoint,
    /// From the picture's coordinates, upward, to the page's, downward from
    /// its corner.
    page_transform: g.Transform = .{},
    /// The level each page submitted for PDF layers starts at.
    page_base: usize = 0,
    segments: NativeSegments = undefined,
    children: std.ArrayList(*c.TypstScene) = .empty,
    levels: std.ArrayList(Level) = .empty,
    pdf: bool = false,
    image_context: ?typst.Engine = null,
    /// Created on the first PDF graphic; every mesh and layer of the
    /// document reuses it.
    pdf_workspace: ?*mesh_pdf.Workspace = null,

    pub fn deinit(self: *Builder) void {
        for (self.children.items) |child| self.library.functions.scene_release(child);
        if (self.image_context) |*engine| engine.deinit();
        self.arena.deinit();
    }

    /// Submits `picture.commands[first..end]`, a balanced run, at the
    /// current level.
    pub fn emit(self: *Builder, first: usize, end: usize) !void {
        const commands = self.picture.commands.items;
        var index = first;
        while (index < end) : (index += 1) {
            const id = if (self.object_ids) |ids| ids[index] else 0;
            switch (commands[index]) {
                .push => |*scope| {
                    if (scope.opacity < 1 and self.pdf) {
                        index = try pdf_graphics.pdfLayer(self, index);
                        continue;
                    }
                    try self.group(scope.transform, scope.clip, id, scope.opacity);
                },
                .pop => try self.endScope(),
                .path => |*draw| {
                    if (draw.style.pen) |*pen| if (pen.resolvesStroke()) {
                        try pen_strokes.resolvedPath(self, draw, self.strokes[self.stroke_index], id);
                        self.stroke_index += 1;
                        continue;
                    };
                    try paint_routes.paint(self, try native_records.path(self, draw.path), draw.style, draw.transform, id);
                },
                .label => |*label| {
                    if (label.reference >= self.labels.len) return error.InvalidFrameReference;
                    var raw = try native_records.item(self, label.transform, null, id, null);
                    raw.kind = c.TYPST_ITEM_LAYOUT;
                    raw.layout = try self.labels[label.reference].nativeLayout(self.library);
                    try self.append(raw);
                },
            }
        }
    }

    pub fn append(self: *Builder, item_: c.TypstSceneItem) !void {
        try self.levels.items[self.levels.items.len - 1].items.append(self.arena.allocator(), item_);
    }

    pub fn group(self: *Builder, transform: g.Transform, clip: ?DisplayList.PathRef, id: u64, opacity: f64) !void {
        // The native limit includes the mathematical coordinate group. The
        // public picture limit also reserves a group for marked nib filldraw.
        if (self.levels.items.len >= 128) return error.GroupNestingLimit;
        try self.levels.append(self.arena.allocator(), .{ .transform = transform, .clip = clip, .id = id, .opacity = opacity });
    }

    pub fn endScope(self: *Builder) !void {
        if (self.levels.items.len <= 1) return error.UnbalancedGroup;
        const level = self.levels.pop().?;
        var child_ = try native_records.childScene(self, level.items.items);
        var raw = try native_records.item(self, level.transform, level.clip, level.id, null);
        // SVG blends a group as one layer through its `opacity` property;
        // the label names the rule that huak's stylesheet gives it.
        if (level.opacity < 1) {
            const memory = self.arena.allocator();
            var buffer: [32]u8 = undefined;
            const tag = try memory.dupe(u8, svg_styles.layerLabel(&buffer, level.opacity));
            const options = try memory.create(c.TypstSceneItemOptions);
            options.* = std.mem.zeroes(c.TypstSceneItemOptions);
            options.struct_size = @sizeOf(c.TypstSceneItemOptions);
            options.tag = .{ .data = tag.ptr, .len = tag.len };
            if (level.id == 0) {
                raw.options = options;
            } else {
                // The group's own label names it as an animation target, so
                // the layer is a group of its own inside it.
                var layer = std.mem.zeroes(c.TypstSceneItem);
                layer.transform = nativeTransform(.{});
                layer.kind = c.TYPST_ITEM_SCENE;
                layer.scene = child_;
                layer.options = options;
                child_ = try native_records.childScene(self, &.{layer});
            }
        }
        raw.kind = c.TYPST_ITEM_SCENE;
        raw.scene = child_;
        try self.append(raw);
    }
};

test "empty and invalid ranges retain bounds and submission error order" {
    const t = std.testing;
    const source = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 3, .y = 4 } } };
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    const bad: DisplayList.PathRef = .{ .first = 2, .count = 1, .source = 1 };
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = .{ .first = 1, .count = 0, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = bad, .style = &.{ .fill = .black }, .transform = .{} } });
    const native = try NativeSegments.init(t.allocator, &picture);
    defer native.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), native.data.len);
    try t.expectEqual(@as(usize, 0), (try native.slice(.{ .first = 2, .count = 0, .source = 1 })).len);
    try t.expectError(error.InvalidPath, native.slice(bad));
    try t.expectError(error.InvalidPath, native.slice(.{ .first = 3, .count = 0, .source = 1 }));
    try t.expectError(error.InvalidPath, native.slice(.{ .first = std.math.maxInt(usize), .count = 1 }));
    var library: typst.Library = undefined;
    // Neither invalid picture reaches a native operation. Exercise document's
    // real traversal, so preprocessing cannot replace its first diagnostic.
    picture.commands.clearRetainingCapacity();
    try picture.commands.append(picture.storage.allocator, .pop);
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = bad, .style = &.{ .fill = .black }, .transform = .{} } });
    try t.expectError(error.UnbalancedGroup, document(t.allocator, &library, &picture, .{ .x = 10, .y = 10 }, .{}));
    picture.commands.clearRetainingCapacity();
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = bad } });
    try picture.commands.append(t.allocator, .{ .label = .{ .reference = 0, .metrics = .{ .width = 1, .height = 1, .baseline = 1 }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .pop);
    try t.expectError(error.InvalidFrameReference, document(t.allocator, &library, &picture, .{ .x = 10, .y = 10 }, .{}));
    // Physical geometry is still prepared before labels are submitted, even
    // when the bad label precedes that geometry in the drawing order.
    picture.commands.clearRetainingCapacity();
    try picture.commands.append(t.allocator, .{ .label = .{ .reference = 0, .metrics = .{ .width = 1, .height = 1, .baseline = 1 }, .transform = .{} } });
    try picture.commands.append(t.allocator, .{ .path = .{ .path = bad, .style = &.{ .pen = .{ .nib = pens.Nib.square() } }, .transform = .{} } });
    try t.expectError(error.InvalidPath, document(t.allocator, &library, &picture, .{ .x = 10, .y = 10 }, .{}));
}

test {
    _ = @import("scene/NativeSegments.zig");
    _ = @import("scene/strokes.zig");
}
