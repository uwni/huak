//! C records in the builder's arena and the value conversions they need: items, styles, paths, child scenes, colors with the RGBA8 output policy, points, transforms and path segments.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../../drawing/geometry.zig");
const DisplayList = @import("../../../drawing/DisplayList.zig");
const Gradient = @import("../../../drawing/style.zig").Gradient;
const Path = @import("../../../drawing/path/Path.zig");
const svg_animation = @import("../../svg/animation.zig");
const typst_scene = @import("../scene.zig");
const Builder = typst_scene.Builder;

pub fn childScene(self: *Builder, items: []const c.TypstSceneItem) !*c.TypstScene {
    const result = try scene(self, items, self.size);
    errdefer self.library.functions.scene_release(result);
    try self.children.append(self.arena.allocator(), result);
    return result;
}

pub fn scene(self: *Builder, items: []const c.TypstSceneItem, size: c.TypstPoint) !*c.TypstScene {
    const options: c.TypstSceneOptions = .{
        .struct_size = @sizeOf(c.TypstSceneOptions),
        .flags = 0,
        .width_pt = size.x,
        .height_pt = size.y,
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

pub fn path(self: *Builder, range: DisplayList.PathRef) !*const c.TypstPath {
    return pathData(self, try self.segments.slice(range));
}

pub fn pathData(self: *Builder, segments: []const c.TypstPathSegment) !*const c.TypstPath {
    return pathDataIn(self.arena.allocator(), segments);
}

pub fn pathDataIn(memory: std.mem.Allocator, segments: []const c.TypstPathSegment) !*const c.TypstPath {
    const result = try memory.create(c.TypstPath);
    result.* = .{ .segments = segments.ptr, .segment_count = segments.len };
    return result;
}

/// An item placed by `transform`, clipped by `clip`, labeled by `id`, with
/// the gradients of `paints`: of its fill and of its stroke.
pub fn item(self: *Builder, transform: g.Transform, clip: ?DisplayList.PathRef, id: u64, paints: ?*const DisplayList.Style) !c.TypstSceneItem {
    return itemIn(self, self.arena.allocator(), transform, clip, id, paints);
}

pub fn itemIn(self: *Builder, memory: std.mem.Allocator, transform: g.Transform, clip: ?DisplayList.PathRef, id: u64, paints: ?*const DisplayList.Style) !c.TypstSceneItem {
    var result = std.mem.zeroes(c.TypstSceneItem);
    result.transform = nativeTransform(transform);
    if (clip) |range| result.clip = try path(self, range);
    const fill_gradient = if (paints) |style_| style_.gradientFor(.fill) else null;
    const stroke_gradient = if (paints) |style_| style_.gradientFor(.stroke) else null;
    if (id == 0 and fill_gradient == null and stroke_gradient == null) return result;
    const options = try memory.create(c.TypstSceneItemOptions);
    options.* = std.mem.zeroes(c.TypstSceneItemOptions);
    options.struct_size = @sizeOf(c.TypstSceneItemOptions);
    if (id != 0) {
        const tag = try memory.print(svg_animation.object_label ++ "{d}", .{id});
        options.flags = c.TYPST_SCENE_ITEM_ISOLATE_TRANSFORM;
        options.tag = .{ .data = tag.ptr, .len = tag.len };
    }
    if (fill_gradient) |gradient| options.fill_gradient = try nativeGradientIn(self, memory, gradient);
    if (stroke_gradient) |gradient| options.stroke_gradient = try nativeGradientIn(self, memory, gradient);
    result.options = options;
    return result;
}

fn nativeGradientIn(self: *Builder, memory: std.mem.Allocator, gradient: *const Gradient) !*const c.TypstGradient {
    const ramp = switch (gradient.*) {
        // `paint` encodes mesh fills before any native item exists, and a
        // stroke painted with a mesh is drawn as its footprint.
        .patches, .fan, .color_patches => unreachable,
        .linear, .radial => |value| value,
    };
    const colors = try memory.alloc(c.TypstColor, ramp.colors.len);
    for (ramp.colors, colors) |value, *dest| dest.* = nativeColor(value);
    const placed = ramp.offsets.len != 0;
    if (placed and !try self.library.supports(c.TYPST_CAP_GRADIENT_STOPS)) return error.Unsupported;
    const native = try memory.create(c.TypstGradient);
    native.* = .{
        .kind = if (gradient.* == .radial) c.TYPST_GRADIENT_RADIAL else c.TYPST_GRADIENT_LINEAR,
        .flags = if (placed) c.TYPST_GRADIENT_STOP_OFFSETS else 0,
        .start = .{ .x = ramp.start.x, .y = ramp.start.y },
        .end = .{ .x = ramp.end.x, .y = ramp.end.y },
        .colors = colors.ptr,
        .count = colors.len,
        .offsets = if (placed) ramp.offsets.ptr else null,
    };
    return native;
}

pub fn style(self: *Builder, value: *const DisplayList.Style) !*const c.TypstStyle {
    return styleIn(self.arena.allocator(), value);
}

pub fn styleIn(memory: std.mem.Allocator, value: *const DisplayList.Style) !*const c.TypstStyle {
    const result = try memory.create(c.TypstStyle);
    result.* = std.mem.zeroes(c.TypstStyle);
    result.fill_rule = switch (value.fill_rule) {
        .nonzero => c.TYPST_FILL_NONZERO,
        .evenodd => c.TYPST_FILL_EVENODD,
    };
    if (value.fill) |*fill| {
        result.flags |= c.TYPST_STYLE_FILL;
        result.fill = nativeColor(fill.fallback());
    }
    if (value.pen) |*pen| {
        result.flags |= c.TYPST_STYLE_STROKE;
        result.stroke = nativeColor(pen.paint.fallback());
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

fn nativeColor(value: DisplayList.Color) c.TypstColor {
    // Keep huak's existing RGBA8 output policy at the host boundary. libtypst's
    // generic scene interface continues to accept full native float channels.
    return .{ .r = channel(value.r), .g = channel(value.g), .b = channel(value.b), .a = channel(value.a) };
}

fn channel(value: f64) f64 {
    return DisplayList.Color.level(value) / DisplayList.Color.max_level;
}

pub fn pointOf(value: c.TypstPoint) g.Point {
    return .{ .x = value.x, .y = value.y };
}

pub fn nativeTransform(value: g.Transform) c.TypstTransform {
    return .{ .xx = value.a, .yx = value.b, .xy = value.c, .yy = value.d, .dx = value.e, .dy = value.f };
}

pub fn pathSegment(segment: Path.Segment) c.TypstPathSegment {
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
