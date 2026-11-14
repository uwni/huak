//! Encodes picture commands directly into immutable native scenes. Only
//! physical-pen geometry needs preparation; ordinary commands are borrowed.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Gradient = @import("../../drawing/style.zig").Gradient;
const Path = @import("../../drawing/path/Path.zig");
const pens = @import("../../drawing/pen/root.zig");
const physical = @import("pen.zig");
const mesh_pdf = @import("../pdf/mesh.zig");

pub const SubmitOptions = struct {
    origin: g.Point = .zero,
    frames: ?[]const typst.FrameRef = null,
    /// IDs address picture.commands. Zero is unmarked; UINT64_MAX identifies
    /// huak's mathematical root group when animation IDs are present.
    object_ids: ?[]const u64 = null,
    pen_geometry: pens.StrokeOptions = .{},
    pdf_mesh: bool = false,
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
    var strokes: Builder.Strokes = .{ .workspace = .init(picture.storage.allocator) };
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
    var builder: Builder = .{ .arena = .init(allocator), .library = library, .size = undefined, .pdf_mesh = options.pdf_mesh };
    defer builder.deinit();
    const memory = builder.arena.allocator();
    // Resolve all physical pens before native submission, preserving geometry
    // diagnostics ahead of frame-reference or native scene errors.
    const labels = options.frames orelse &.{};
    var origin = options.origin;
    const strokes = if (size) |page| fixed: {
        builder.size = .{ .x = page.x, .y = page.y };
        break :fixed try builder.prepareStrokes(picture, options.pen_geometry);
    } else fitted: {
        var strokes = builder.strokePass(options.pen_geometry);
        defer strokes.workspace.deinit();
        const box = (try picture.measuredBounds(FrameBounds{ .frames = labels }, &strokes)) orelse return error.InvalidCanvas;
        const page = box.max.sub(box.min);
        if (!page.isFinite() or page.x <= 0 or page.y <= 0) return error.InvalidCanvas;
        builder.size = .{ .x = page.x, .y = page.y };
        origin = box.min;
        break :fitted strokes.items.items;
    };
    builder.segments = try NativeSegments.init(memory, picture);
    try builder.levels.append(memory, .{});
    var stroke_index: usize = 0;
    for (picture.commands.items, 0..) |*command, index| {
        const id = if (options.object_ids) |ids| ids[index] else 0;
        switch (command.*) {
            .push => |*group| try builder.group(group.transform, group.clip, id),
            .pop => try builder.endScope(),
            .path => |*draw| {
                if (draw.style.pen) |*pen| if (pen.needsGeometry()) {
                    try builder.resolvedPath(draw, strokes[stroke_index], id);
                    stroke_index += 1;
                    continue;
                };
                try builder.paint(try builder.path(draw.path), try builder.style(draw.style), draw.style.gradient, draw.transform, id);
            },
            .label => |*label| {
                if (label.reference >= labels.len) return error.InvalidFrameReference;
                var raw = try builder.item(label.transform, null, id, null);
                raw.kind = c.TYPST_ITEM_LAYOUT;
                raw.layout = try labels[label.reference].nativeLayout(library);
                try builder.append(raw);
            },
        }
    }
    if (builder.levels.items.len != 1) return error.UnbalancedGroup;
    const child = try builder.childScene(builder.levels.items[0].items.items);
    var root_item = try builder.item(.{ .d = -1, .e = -origin.x, .f = builder.size.y + origin.y }, null, if (options.object_ids != null) std.math.maxInt(u64) else 0, null);
    root_item.kind = c.TYPST_ITEM_SCENE;
    root_item.scene = child;
    const root = try builder.scene(&.{root_item});
    return typst.Document.fromSceneOwned(library, root);
}

const Level = struct {
    transform: g.Transform = .{},
    clip: ?DisplayList.PathRef = null,
    id: u64 = 0,
    items: std.ArrayList(c.TypstSceneItem) = .empty,
};

const NativeSegments = struct {
    const Interval = struct {
        source: u32,
        first: usize,
        end: usize,
        native_first: usize = 0,

        fn tryMerge(self: *Interval, other: *const Interval) bool {
            if (self.source != other.source or other.first > self.end or self.first > other.end) return false;
            self.first = @min(self.first, other.first);
            self.end = @max(self.end, other.end);
            return true;
        }
        fn less(_: void, a: Interval, b: Interval) bool {
            if (a.source != b.source) return a.source < b.source;
            return a.first < b.first;
        }
        fn startsAtOrBefore(range: DisplayList.PathRef, interval: Interval) bool {
            if (interval.source != range.source) return interval.source < range.source;
            return interval.first <= range.first;
        }
    };

    geometry: DisplayList.Geometry,
    data: []const c.TypstPathSegment,
    intervals: []const Interval,

    fn init(allocator: std.mem.Allocator, picture: *const DisplayList) !NativeSegments {
        var intervals: std.ArrayList(Interval) = .empty;
        defer intervals.deinit(allocator);
        for (picture.commands.items) |*command| {
            const range = switch (command.*) {
                .path => |*draw| range: {
                    if (draw.style.fill == null) if (draw.style.pen) |pen| if (pen.needsGeometry()) continue;
                    break :range draw.path;
                },
                .push => |*group| group.clip orelse continue,
                else => continue,
            };
            if (range.count == 0) continue;
            // Report invalid ranges only where their path or clip is submitted.
            // In particular, an unmatched group must retain its earlier error.
            _ = picture.range(range) catch continue;
            const interval: Interval = .{ .source = range.source, .first = range.first, .end = range.first + range.count };
            if (intervals.items.len != 0 and intervals.items[intervals.items.len - 1].tryMerge(&interval)) continue;
            try intervals.append(allocator, interval);
        }
        std.mem.sort(Interval, intervals.items, {}, Interval.less);
        var count: usize = 0;
        for (intervals.items) |*interval| {
            if (count != 0 and intervals.items[count - 1].tryMerge(interval)) continue;
            intervals.items[count] = interval.*;
            count += 1;
        }
        intervals.items.len = count;
        const retained = try intervals.toOwnedSlice(allocator);
        errdefer allocator.free(retained);
        var segment_count: usize = 0;
        for (retained) |*interval| {
            interval.native_first = segment_count;
            segment_count = std.math.add(usize, segment_count, interval.end - interval.first) catch return error.OutOfMemory;
        }
        const data = try allocator.alloc(c.TypstPathSegment, segment_count);
        for (retained) |interval| {
            const source = try picture.geometry().source(interval.source);
            const input = source[interval.first..interval.end];
            for (input, data[interval.native_first..][0..input.len]) |segment, *out| out.* = pathSegment(segment);
        }
        return .{ .geometry = picture.geometry(), .data = data, .intervals = retained };
    }

    fn deinit(self: NativeSegments, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.intervals);
    }

    fn slice(self: *const NativeSegments, range: DisplayList.PathRef) ![]const c.TypstPathSegment {
        _ = try self.geometry.range(range);
        if (range.count == 0) return &.{};
        const stop = std.sort.partitionPoint(Interval, self.intervals, range, Interval.startsAtOrBefore);
        if (stop == 0) return error.InvalidPath;
        const interval = self.intervals[stop - 1];
        if (interval.source != range.source or range.first >= interval.end or range.count > interval.end - range.first) return error.InvalidPath;
        const first = interval.native_first + (range.first - interval.first);
        return self.data[first..][0..range.count];
    }
};

const Builder = struct {
    const Stroke = struct { path: *const c.TypstPath, style: *const c.TypstStyle, transform: ?g.Transform };
    arena: std.heap.ArenaAllocator,
    library: *typst.Library,
    size: c.TypstPoint,
    segments: NativeSegments = undefined,
    children: std.ArrayList(*c.TypstScene) = .empty,
    levels: std.ArrayList(Level) = .empty,
    pdf_mesh: bool = false,
    image_context: ?typst.Engine = null,
    /// Created on the first mesh paint; every mesh of the document reuses it.
    mesh_workspace: ?*mesh_pdf.Workspace = null,

    fn deinit(self: *Builder) void {
        for (self.children.items) |child| self.library.functions.scene_release(child);
        if (self.image_context) |*engine| engine.deinit();
        self.arena.deinit();
    }

    fn prepareStrokes(self: *Builder, picture: *const DisplayList, options: pens.StrokeOptions) ![]const ?Stroke {
        var strokes = self.strokePass(options);
        defer strokes.workspace.deinit();
        for (picture.commands.items) |*command| {
            if (command.* != .path) continue;
            const draw = &command.path;
            const pen = if (draw.style.pen) |*value| value else continue;
            if (!pen.needsGeometry()) continue;
            _ = try strokes.visitStroke(try picture.geometry().view(picture.storage.allocator, draw.path), draw.style, null);
        }
        return strokes.items.items;
    }

    fn strokePass(self: *Builder, options: pens.StrokeOptions) Strokes {
        return .{ .workspace = .init(self.arena.child_allocator), .encoder = self, .options = options };
    }

    const Strokes = struct {
        workspace: std.heap.ArenaAllocator,
        encoder: ?*Builder = null,
        options: pens.StrokeOptions = .{},
        items: std.ArrayList(?Stroke) = .empty,

        // Each physical path is expanded once. A fitted page measures the same
        // outline that is submitted, before releasing the temporary Zig path.
        pub fn visitStroke(self: *Strokes, center: Path, style_: *const DisplayList.Style, transform: ?g.Transform) !?g.BBox {
            // Geometry temporaries end with this stroke; encoded paths live
            // through native submission in the builder's separate arena.
            _ = self.workspace.reset(.retain_capacity);
            const stroke = try physical.resolvePath(self.workspace.allocator(), center, style_, self.options);
            if (self.encoder) |builder| {
                const native = try builder.encodeStroke(&stroke, &style_.pen.?);
                try self.items.append(builder.arena.allocator(), native);
            }
            if (transform) |t| return physical.inkBounds(&stroke, center.segments.items, style_, t);
            return null;
        }
    };

    fn encodeStroke(self: *Builder, stroke: *const pens.Stroke, pen: *const DisplayList.Pen) !?Stroke {
        if (stroke.transform == null and stroke.path.segments.items.len == 0) return null;
        if (pen.motion) |motion| try physical.checkOutputPrecision(&stroke.path, motion.tolerance);
        const data = try self.arena.allocator().alloc(c.TypstPathSegment, stroke.path.segments.items.len);
        for (stroke.path.segments.items, data) |segment, *out| out.* = pathSegment(segment);
        // The normalized ellipse uses a unit circular stroke. Dashes have
        // already been applied to the centerline by the geometry kernel.
        const native_style: DisplayList.Style = if (stroke.transform != null)
            .{ .pen = .{ .color = pen.color, .cap = pen.cap, .join = pen.join, .miter_limit = pen.miter_limit } }
        else
            .{ .fill = pen.color };
        return .{ .path = try self.pathData(data), .style = try self.style(&native_style), .transform = stroke.transform };
    }

    fn append(self: *Builder, item_: c.TypstSceneItem) !void {
        try self.levels.items[self.levels.items.len - 1].items.append(self.arena.allocator(), item_);
    }

    fn group(self: *Builder, transform: g.Transform, clip: ?DisplayList.PathRef, id: u64) !void {
        // The native limit includes the mathematical coordinate group. The
        // public picture limit also reserves a group for marked nib filldraw.
        if (self.levels.items.len >= 128) return error.GroupNestingLimit;
        try self.levels.append(self.arena.allocator(), .{ .transform = transform, .clip = clip, .id = id });
    }

    fn endScope(self: *Builder) !void {
        if (self.levels.items.len <= 1) return error.UnbalancedGroup;
        const level = self.levels.pop().?;
        const child_ = try self.childScene(level.items.items);
        var raw = try self.item(level.transform, level.clip, level.id, null);
        raw.kind = c.TYPST_ITEM_SCENE;
        raw.scene = child_;
        try self.append(raw);
    }

    fn paint(self: *Builder, path_: *const c.TypstPath, style_: *const c.TypstStyle, gradient: ?*const Gradient, transform: g.Transform, id: u64) !void {
        if (gradient) |value| if (value.* == .mesh_fill) {
            if (!self.pdf_mesh) return error.MeshRequiresPdf;
            if (!try self.library.supports(c.TYPST_CAP_PDF_IMPORT)) return error.Unsupported;
            const workspace = self.mesh_workspace orelse workspace: {
                const created = try self.arena.allocator().create(mesh_pdf.Workspace);
                self.mesh_workspace = created;
                break :workspace created;
            };
            // The import does not depend on fonts, files or inputs; borrowing
            // the current context keeps the typesetter's configuration cached.
            if (self.image_context == null) self.image_context = try typst.Engine.initAny(self.library);
            const scratch = self.arena.child_allocator;
            const encoded = try mesh_pdf.encode(scratch, workspace, value.mesh_fill, path_.segments[0..path_.segment_count], style_.fill_rule == c.TYPST_FILL_EVENODD);
            var image: ?*c.TypstScene = null;
            var diagnostics: ?*c.TypstDiagnostics = null;
            defer self.library.functions.diagnostics_release(diagnostics);
            const status = self.library.functions.scene_from_pdf(self.image_context.?.handle, .{ .data = encoded.pdf.ptr, .len = encoded.pdf.len }, 0, &image, &diagnostics);
            // libtypst copied the bytes. Releasing them while they are still
            // the most recent allocation lets an arena reuse the space.
            scratch.free(encoded.pdf);
            try self.library.check(status, diagnostics);
            const scene_ = image orelse return error.InvalidResult;
            self.children.append(self.arena.allocator(), scene_) catch |err| {
                self.library.functions.scene_release(scene_);
                return err;
            };
            const box = encoded.bounds;
            // Imported PDF images use downward y; mesh coordinates use upward y.
            const placement = g.Transform{ .a = box.max.x - box.min.x, .d = box.min.y - box.max.y, .e = box.min.x, .f = box.max.y };
            var item_ = try self.item(placement.then(transform), null, id, null);
            item_.kind = c.TYPST_ITEM_SCENE;
            item_.scene = scene_;
            try self.append(item_);
            if (style_.flags & c.TYPST_STYLE_STROKE != 0) {
                const stroke = try self.arena.allocator().create(c.TypstStyle);
                stroke.* = style_.*;
                stroke.flags &= ~@as(u32, c.TYPST_STYLE_FILL);
                try self.paint(path_, stroke, null, transform, 0);
            }
            return;
        };
        var raw = try self.item(transform, null, id, gradient);
        raw.kind = c.TYPST_ITEM_PATH;
        raw.path = path_;
        raw.style = style_;
        try self.append(raw);
    }

    fn resolvedPath(self: *Builder, draw: *const DisplayList.PathCommand, stroke: ?Stroke, id: u64) !void {
        const grouped = draw.style.fill != null and id != 0;
        if (grouped) try self.group(draw.transform, null, id);
        const placement: g.Transform = if (grouped) .{} else draw.transform;
        const child_id = if (grouped) 0 else id;
        if (draw.style.fill) |fill| try self.paint(try self.path(draw.path), try self.style(&.{ .fill = fill, .fill_rule = draw.style.fill_rule }), draw.style.gradientFor(.fill), placement, 0);
        if (stroke) |value| {
            var footprint_paint: ?Gradient = null;
            if (draw.style.gradientFor(.stroke)) |paint_| {
                footprint_paint = .{ .linear_fill = paint_.linear_stroke };
            }
            try self.paint(value.path, value.style, if (footprint_paint) |*fill| fill else null, if (value.transform) |transform| transform.then(placement) else placement, child_id);
        } else if (child_id != 0) {
            try self.group(placement, null, child_id);
            try self.endScope();
        }
        if (grouped) try self.endScope();
    }

    fn childScene(self: *Builder, items: []const c.TypstSceneItem) !*c.TypstScene {
        const result = try self.scene(items);
        errdefer self.library.functions.scene_release(result);
        try self.children.append(self.arena.allocator(), result);
        return result;
    }

    fn scene(self: *Builder, items: []const c.TypstSceneItem) !*c.TypstScene {
        const options: c.TypstSceneOptions = .{
            .struct_size = @sizeOf(c.TypstSceneOptions),
            .flags = 0,
            .width_pt = self.size.x,
            .height_pt = self.size.y,
            .items = items.ptr,
            .item_count = items.len,
        };
        var result: ?*c.TypstScene = null;
        var diagnostic: ?*c.TypstDiagnostics = null;
        defer self.library.functions.diagnostics_release(diagnostic);
        const status = self.library.functions.scene_create(&options, &result, &diagnostic);
        errdefer self.library.functions.scene_release(result);
        try self.library.check(status, diagnostic);
        return result orelse error.InvalidResult;
    }

    fn path(self: *Builder, range: DisplayList.PathRef) !*const c.TypstPath {
        return self.pathData(try self.segments.slice(range));
    }

    fn pathData(self: *Builder, segments: []const c.TypstPathSegment) !*const c.TypstPath {
        const result = try self.arena.allocator().create(c.TypstPath);
        result.* = .{ .segments = segments.ptr, .segment_count = segments.len };
        return result;
    }

    fn item(self: *Builder, transform: g.Transform, clip: ?DisplayList.PathRef, id: u64, gradient: ?*const Gradient) !c.TypstSceneItem {
        var result = std.mem.zeroes(c.TypstSceneItem);
        result.transform = nativeTransform(transform);
        if (clip) |range| result.clip = try self.path(range);
        if (id == 0 and gradient == null) return result;
        const memory = self.arena.allocator();
        const options = try memory.create(c.TypstSceneItemOptions);
        options.* = std.mem.zeroes(c.TypstSceneItemOptions);
        options.struct_size = @sizeOf(c.TypstSceneItemOptions);
        if (id != 0) {
            const tag = try std.fmt.allocPrint(memory, "libtypst-object-{d}", .{id});
            options.flags = c.TYPST_SCENE_ITEM_ISOLATE_TRANSFORM;
            options.tag = .{ .data = tag.ptr, .len = tag.len };
        }
        if (gradient) |paint_| {
            const ramp = switch (paint_.*) {
                .mesh_fill => return error.MeshRequiresPdf,
                inline else => |value| value,
            };
            const colors = try memory.alloc(c.TypstColor, ramp.colors.len);
            for (ramp.colors, colors) |value, *dest| dest.* = nativeColor(value);
            const native = try memory.create(c.TypstGradient);
            native.* = .{
                .kind = if (paint_.* == .radial_fill) c.TYPST_GRADIENT_RADIAL else c.TYPST_GRADIENT_LINEAR,
                .reserved = 0,
                .start = .{ .x = ramp.start.x, .y = ramp.start.y },
                .end = .{ .x = ramp.end.x, .y = ramp.end.y },
                .colors = colors.ptr,
                .count = colors.len,
            };
            if (paint_.* == .linear_stroke) options.stroke_gradient = native else options.fill_gradient = native;
        }
        result.options = options;
        return result;
    }

    fn style(self: *Builder, value: *const DisplayList.Style) !*const c.TypstStyle {
        const result = try self.arena.allocator().create(c.TypstStyle);
        result.* = std.mem.zeroes(c.TypstStyle);
        result.fill_rule = switch (value.fill_rule) {
            .nonzero => c.TYPST_FILL_NONZERO,
            .evenodd => c.TYPST_FILL_EVENODD,
        };
        if (value.fill) |fill| {
            result.flags |= c.TYPST_STYLE_FILL;
            result.fill = nativeColor(fill);
        }
        if (value.pen) |pen| {
            result.flags |= c.TYPST_STYLE_STROKE;
            result.stroke = nativeColor(pen.color);
            result.stroke_width_pt = pen.width;
            result.line_cap = switch (pen.cap) {
                .butt => c.TYPST_CAP_BUTT,
                .round => c.TYPST_CAP_ROUND,
                .square => c.TYPST_CAP_SQUARE,
            };
            result.line_join = switch (pen.join) {
                .miter => c.TYPST_JOIN_MITER,
                .round => c.TYPST_JOIN_ROUND,
                .bevel => c.TYPST_JOIN_BEVEL,
            };
            result.miter_limit = pen.miter_limit;
            result.dashes = pen.dash.ptr;
            result.dash_count = pen.dash.len;
            result.dash_phase_pt = pen.dash_phase;
        }
        return result;
    }
};

fn nativeColor(value: DisplayList.Color) c.TypstColor {
    // Keep huak's existing RGBA8 output policy at the host boundary. libtypst's
    // generic scene interface continues to accept full native float channels.
    return .{ .r = channel(value.r), .g = channel(value.g), .b = channel(value.b), .a = channel(value.a) };
}
fn channel(value: f64) f64 {
    return @round(value * 255) / 255;
}
fn nativeTransform(value: g.Transform) c.TypstTransform {
    return .{ .xx = value.a, .yx = value.b, .xy = value.c, .yy = value.d, .dx = value.e, .dy = value.f };
}
fn pathSegment(segment: Path.Segment) c.TypstPathSegment {
    var raw = std.mem.zeroes(c.TypstPathSegment);
    switch (segment) {
        .move => |point| {
            raw.kind = c.TYPST_SEGMENT_MOVE;
            raw.p1 = .{ .x = point.x, .y = point.y };
        },
        .line => |point| {
            raw.kind = c.TYPST_SEGMENT_LINE;
            raw.p1 = .{ .x = point.x, .y = point.y };
        },
        .cubic => |curve| {
            raw.kind = c.TYPST_SEGMENT_CUBIC;
            raw.p1 = .{ .x = curve.c1.x, .y = curve.c1.y };
            raw.p2 = .{ .x = curve.c2.x, .y = curve.c2.y };
            raw.p3 = .{ .x = curve.end.x, .y = curve.end.y };
        },
        .close => raw.kind = c.TYPST_SEGMENT_CLOSE,
    }
    return raw;
}

test "mixed nib and ordinary paths convert only referenced intervals" {
    const t = std.testing;
    const nibs = @import("../../drawing/pen/root.zig");
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 50, .y = 20 } },
        .{ .move = .{ .x = 10, .y = 40 } }, .{ .line = .{ .x = 50, .y = 40 } },
    };
    for ([_]nibs.Nib{ nibs.Nib.square(), .{ .ellipse = .{ .a = 8, .d = 2 } } }) |nib| {
        for ([_]bool{ false, true }) |filled| {
            var picture = DisplayList.init(t.allocator);
            defer picture.deinit();
            try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
            const nib_range: DisplayList.PathRef = .{ .first = 0, .count = 2, .source = 1 };
            const ordinary: DisplayList.PathRef = .{ .first = 2, .count = 2, .source = 1 };
            const pen: DisplayList.Pen = .{ .nib = nib, .cap = .round, .join = .round, .dash = &.{ 4, 2 }, .dash_phase = 1 };
            const draw: DisplayList.PathCommand = .{ .path = nib_range, .style = &.{ .pen = pen, .fill = if (filled) DisplayList.Color.black else null }, .transform = .{} };
            try picture.commands.append(picture.storage.allocator, .{ .path = draw });
            try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = ordinary, .style = &.{ .pen = .{} }, .transform = .{} } });
            var library: typst.Library = undefined;
            var builder: Builder = .{ .arena = .init(t.allocator), .library = &library, .size = .{ .x = 10, .y = 10 } };
            defer builder.arena.deinit();
            const strokes = try builder.prepareStrokes(&picture, .{});
            try t.expectEqual(@as(usize, 1), strokes.len);
            var resolved = try physical.resolve(t.allocator, source[0..2], draw.style, .{});
            defer resolved.path.deinit();
            const stroke = strokes[0].?;
            if (nib == .ellipse) {
                try t.expectEqual(@as(u32, c.TYPST_STYLE_STROKE), stroke.style.flags);
                try t.expectEqual(@as(f64, 1), stroke.style.stroke_width_pt);
                try t.expectEqual(@as(usize, 0), stroke.style.dash_count);
                try t.expectEqual(@as(f64, 0), stroke.style.dash_phase_pt);
            } else try t.expectEqual(@as(u32, c.TYPST_STYLE_FILL), stroke.style.flags);
            for (resolved.path.segments.items, stroke.path.segments[0..stroke.path.segment_count]) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
            var counter = t.FailingAllocator.init(t.allocator, .{});
            {
                const native = try NativeSegments.init(counter.allocator(), &picture);
                defer native.deinit(counter.allocator());
                const needed: usize = if (filled) 4 else 2;
                try t.expectEqual(needed, native.data.len);
                try t.expectEqual(needed * @sizeOf(c.TypstPathSegment) + native.intervals.len * @sizeOf(NativeSegments.Interval), counter.allocated_bytes - counter.freed_bytes);
                for (source[2..], try native.slice(ordinary)) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
                if (!filled) try t.expectError(error.InvalidPath, native.slice(nib_range));
            }
            try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = nib_range } });
            try picture.commands.append(picture.storage.allocator, .pop);
            const clipped = try NativeSegments.init(t.allocator, &picture);
            defer clipped.deinit(t.allocator);
            try t.expectEqual(source.len, clipped.data.len);
            for (source[0..2], try clipped.slice(nib_range)) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
        }
    }
}

test "native intervals share repeated and overlapping ranges without duplicating geometry" {
    const t = std.testing;
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 1, .y = 1 } },
        .{ .move = .{ .x = 2, .y = 2 } }, .{ .line = .{ .x = 3, .y = 3 } },
        .{ .line = .{ .x = 4, .y = 4 } }, .{ .line = .{ .x = 5, .y = 5 } },
        .{ .line = .{ .x = 6, .y = 6 } }, .{ .line = .{ .x = 7, .y = 7 } },
        .{ .line = .{ .x = 8, .y = 8 } }, .{ .line = .{ .x = 9, .y = 9 } },
    };
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    const first: DisplayList.PathRef = .{ .first = 2, .count = 5, .source = 1 };
    const overlap: DisplayList.PathRef = .{ .first = 5, .count = 4, .source = 1 };
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = first, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = overlap } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = first, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .pop);
    const native = try NativeSegments.init(t.allocator, &picture);
    defer native.deinit(t.allocator);
    try t.expectEqual(@as(usize, 7), native.data.len);
    try t.expectEqual(@as(usize, 1), native.intervals.len);
    var library: typst.Library = undefined;
    var builder: Builder = .{ .arena = .init(t.allocator), .library = &library, .size = .{ .x = 10, .y = 10 }, .segments = native };
    defer builder.arena.deinit();
    const a = try builder.path(first);
    const b = try builder.path(overlap);
    const repeated = try builder.path(first);
    try t.expect(a.segments == repeated.segments);
    try t.expect(a.segments + 3 == b.segments);
    for (source[2..7], a.segments[0..a.segment_count]) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
    for (source[5..9], b.segments[0..b.segment_count]) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
}

test "consecutive native ranges allocate the same interval storage as one range" {
    const t = std.testing;
    var source: [1600]Path.Segment = undefined;
    for (&source, 0..) |*segment, index| segment.* = if (index % 2 == 0)
        .{ .move = .{ .x = @floatFromInt(index), .y = 0 } }
    else
        .{ .line = .{ .x = @floatFromInt(index), .y = 1 } };
    var whole = DisplayList.init(t.allocator);
    defer whole.deinit();
    try whole.sources.append(whole.storage.allocator, .{ .segments = &source });
    try whole.commands.append(whole.storage.allocator, .{ .path = .{ .path = .{ .first = 0, .count = source.len, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    var separate = DisplayList.init(t.allocator);
    defer separate.deinit();
    try separate.sources.append(separate.storage.allocator, .{ .segments = &source });
    for (0..800) |index| try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = .{ .first = index * 2, .count = 2, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    // Repeating the final reference must not grow its interval storage either.
    try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = .{ .first = source.len - 2, .count = 2, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    var whole_counter = t.FailingAllocator.init(t.allocator, .{});
    const one = try NativeSegments.init(whole_counter.allocator(), &whole);
    defer one.deinit(whole_counter.allocator());
    var separate_counter = t.FailingAllocator.init(t.allocator, .{});
    const many = try NativeSegments.init(separate_counter.allocator(), &separate);
    defer many.deinit(separate_counter.allocator());
    try t.expectEqual(@as(usize, 1), many.intervals.len);
    try t.expectEqual(source.len, many.data.len);
    try t.expectEqualDeep(one.data, many.data);
    try t.expectEqual(whole_counter.allocations, separate_counter.allocations);
    try t.expectEqual(whole_counter.allocated_bytes, separate_counter.allocated_bytes);
    try t.expectEqual(whole_counter.freed_bytes, separate_counter.freed_bytes);
    try t.expectEqual(source.len * @sizeOf(c.TypstPathSegment) + @sizeOf(NativeSegments.Interval), separate_counter.allocated_bytes - separate_counter.freed_bytes);

    separate.commands.clearRetainingCapacity();
    for ([_]DisplayList.PathRef{
        .{ .first = 8, .count = 2, .source = 1 },
        .{ .first = 0, .count = 2, .source = 1 },
        .{ .first = 4, .count = 4, .source = 1 },
        .{ .first = 2, .count = 3, .source = 1 },
    }) |range| try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = range, .style = &.{ .fill = .black }, .transform = .{} } });
    const unordered = try NativeSegments.init(t.allocator, &separate);
    defer unordered.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), unordered.intervals.len);
    try t.expectEqual(@as(usize, 10), unordered.data.len);
    for (source[0..10], unordered.data) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
}

fn nativeIntervalExercise(allocator: std.mem.Allocator) !void {
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 8, .y = 0 } }, .{ .line = .{ .x = 8, .y = 8 } }, .{ .line = .{ .x = 0, .y = 8 } }, .close,
        .{ .move = .{ .x = 2, .y = 2 } }, .{ .line = .{ .x = 2, .y = 6 } }, .{ .line = .{ .x = 6, .y = 2 } }, .close,
    };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    const clip: DisplayList.PathRef = .{ .first = 0, .count = source.len, .source = 1 };
    const hole: DisplayList.PathRef = .{ .first = 5, .count = 4, .source = 1 };
    const owned: DisplayList.PathRef = .{ .first = 0, .count = source.len };
    try picture.storage.segments.appendSlice(picture.storage.allocator, &source);
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = clip } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = owned, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = hole } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = clip, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .pop);
    try picture.commands.append(picture.storage.allocator, .pop);
    const native = try NativeSegments.init(allocator, &picture);
    defer native.deinit(allocator);
    try std.testing.expectEqual(source.len * 2, native.data.len);
    // Actual path/inner-clip/outer-clip submission order differs from sorted
    // storage. The original controls and contour/hole order must stay intact.
    for ([_]DisplayList.PathRef{ owned, clip, hole, clip }) |range| {
        for (try picture.range(range), try native.slice(range)) |segment, converted| try std.testing.expectEqualDeep(pathSegment(segment), converted);
    }
}

test "nested compound clips preserve contour order and release every failed interval allocation" {
    try nativeIntervalExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), nativeIntervalExercise, .{});
}

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

test "moving pen workspace is reused and encoded coordinates retain their precision budget" {
    const a = std.testing.allocator;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.{ .x = 100, .y = 0 });
    try path.lineTo(.{ .x = 110, .y = 0 });
    const motion: pens.Motion = .{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 2 }}, .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 1, .value = 2 } } };
    const paint: DisplayList.Pen = .{ .nib = pens.Nib.square(), .motion = &motion };
    var geometric = try pens.resolveStroke(a, path, &paint, .{ .tolerance = 1e-7 }, .outline);
    defer geometric.path.deinit();
    try std.testing.expect(geometric.path.segments.items.len > 0);
    try std.testing.expectError(error.OutputPrecisionRange, physical.checkOutputPrecision(&geometric.path, 1e-7));
    try physical.checkOutputPrecision(&geometric.path, 0.001);

    var outer = std.heap.ArenaAllocator.init(a);
    defer outer.deinit();
    var measure: Builder.Strokes = .{ .workspace = .init(outer.allocator()) };
    defer measure.workspace.deinit();
    for (0..2) |_| _ = try measure.visitStroke(path, &.{ .pen = paint }, .{});
    const capacity = outer.queryCapacity();
    for (0..32) |_| _ = try measure.visitStroke(path, &.{ .pen = paint }, .{});
    try std.testing.expectEqual(capacity, outer.queryCapacity());
}

fn prepareStrokeExercise(allocator: std.mem.Allocator) !void {
    const source = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 40, .y = 20 } }, .{ .line = .{ .x = 40, .y = 40 } }, .close };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    for ([_]pens.Nib{ pens.Nib.square(), .{ .ellipse = .{ .a = 4, .d = 2 } } }) |nib| {
        for ([_][]const f64{ &.{}, &.{ 4, 2 } }) |dash| {
            const style = try picture.storage.styles.intern(&.{ .pen = .{ .nib = nib, .cap = .round, .join = .round, .dash = dash, .dash_phase = 1 } });
            var first = try physical.resolve(allocator, &source, style, .{});
            defer first.path.deinit();
            var second = try physical.resolve(allocator, &source, style, .{});
            defer second.path.deinit();
            try std.testing.expect(first.path.segments.items.ptr != second.path.segments.items.ptr);
            try std.testing.expectEqualDeep(first.path.segments.items, second.path.segments.items);
            try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = .{ .first = 0, .count = source.len, .source = 1 }, .style = style, .transform = .{} } });
        }
    }
    var library: typst.Library = undefined;
    var builder: Builder = .{ .arena = .init(allocator), .library = &library, .size = .{ .x = 10, .y = 10 } };
    defer builder.arena.deinit();
    const strokes = try builder.prepareStrokes(&picture, .{});
    try std.testing.expectEqual(picture.commands.items.len, strokes.len);
    for (strokes, picture.commands.items) |stroke, command| {
        try std.testing.expect(stroke.?.path.segment_count != 0);
        const flags: u32 = if (command.path.style.pen.?.nib.? == .ellipse) c.TYPST_STYLE_STROKE else c.TYPST_STYLE_FILL;
        try std.testing.expectEqual(flags, stroke.?.style.flags);
    }
}

test "native stroke preparation releases every failed allocation" {
    try prepareStrokeExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), prepareStrokeExercise, .{});
}

test "independent geometry banks preserve source identity and convert each used range once" {
    const t = std.testing;
    const first = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 3, .y = 4 } } };
    const second = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 30, .y = 40 } } };
    var picture = DisplayList.init(t.allocator);
    try picture.sources.appendSlice(t.allocator, &.{ .{ .segments = &first }, .{ .segments = &second } });
    defer picture.deinit();
    const one: DisplayList.PathRef = .{ .first = 0, .count = first.len, .source = 1 };
    const two: DisplayList.PathRef = .{ .first = 0, .count = second.len, .source = 2 };
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = two, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = one, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = two } });
    try picture.commands.append(picture.storage.allocator, .pop);
    try t.expectEqual(first[0..].ptr, (try picture.range(one)).ptr);
    try t.expectEqual(second[0..].ptr, (try picture.range(two)).ptr);
    const native = try NativeSegments.init(t.allocator, &picture);
    defer native.deinit(t.allocator);
    try t.expectEqual(first.len + second.len, native.data.len);
    for ([_]DisplayList.PathRef{ one, two }) |range| {
        for (try picture.range(range), try native.slice(range)) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
    }
    try t.expectError(error.InvalidPath, native.slice(.{ .source = 3, .first = 0, .count = 1 }));
}
