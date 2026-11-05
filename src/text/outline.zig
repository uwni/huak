//! Optional editable outlines for already typeset labels. This adapter owns
//! ordinary huak paths; neither the mathematical core nor a returned Batch
//! depends on the lifetime of Typst frames, engines, or outline snapshots.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../drawing/geometry.zig");
const Path = @import("../drawing/path/Path.zig");
const DisplayList = @import("../drawing/DisplayList.zig");

pub const PartKind = enum { glyph, shape, clip_begin, clip_end };

pub const Part = struct {
    /// Glyph-local geometry in points, with x right and y up. It is editable
    /// using the same Path operations and control points as any other path.
    path: Path,
    /// Maps local geometry to a label whose baseline-left is (0, 0), y up.
    /// Keeping placement separate also preserves transformed pen semantics.
    transform: g.Transform,
    style: DisplayList.Style,
    kind: PartKind,
    glyph_id: u32,
    run_index: usize,
    /// The shaped run's UTF-8 text, borrowed from the owning Batch. This is
    /// layout text, not a byte range in the original Typst markup/math source.
    run_text: []const u8,
    cluster_start: usize,
    cluster_end: usize,
    /// Shaping advance expressed in baseline-relative label coordinates.
    advance: g.Point,

    pub fn clusterText(self: *const Part) []const u8 {
        return self.run_text[self.cluster_start..self.cluster_end];
    }

    /// Obtain independent geometry with placement already applied. The caller
    /// chooses paints when combining this with other geometry.
    pub fn transformedPath(self: *const Part, allocator: std.mem.Allocator) !Path {
        return self.path.transformed(allocator, self.transform);
    }
};

pub const Label = struct {
    metrics: DisplayList.Metrics,
    parts: []Part,

    /// Compound outlines retain all contours and holes. Paints, glyph identity,
    /// and per-part pen transforms intentionally remain on parts rather than
    /// being encoded in a geometric Path; choose a style for the combined path.
    /// A bare Path cannot carry clipping. Use addToPicture for clipped native
    /// contents and an explicit region operation when materializing the clip.
    pub fn combinedPath(self: *const Label, allocator: std.mem.Allocator) !Path {
        for (self.parts) |part| if (part.kind == .clip_begin or part.kind == .clip_end) return error.ClippedOutline;
        var result = Path.init(allocator);
        errdefer result.deinit();
        for (self.parts) |*part| {
            if (part.style.fill == null and part.style.pen == null) continue;
            try result.appendTransformed(part.path, part.transform);
        }
        return result;
    }

    /// Copy independently editable parts to a picture with their original
    /// fill/stroke styles. Position is an ordinary mathematical transform.
    pub fn addToPicture(self: *const Label, target: *DisplayList, position: g.Transform) !void {
        const previous_commands = target.commands.items.len;
        const previous_segments = target.storage.segments.items.len;
        const previous_depth = target.scope_depth;
        const previous_maximum = target.maximum_depth;
        errdefer {
            target.truncateCommands(previous_commands);
            target.storage.segments.items.len = previous_segments;
            target.scope_depth = previous_depth;
            target.maximum_depth = previous_maximum;
        }
        var depth: usize = 0;
        // An empty native clip hides its complete subtree, then restores the
        // previous scope. Avoid replacing it with an invented geometric path.
        var hidden_at: ?usize = null;
        for (self.parts) |*part| {
            switch (part.kind) {
                .clip_begin => {
                    depth += 1;
                    if (hidden_at != null) continue;
                    if (part.path.segmentCount() == 0) {
                        hidden_at = depth;
                        continue;
                    }
                    var clip = try part.transformedPath(target.storage.allocator);
                    defer clip.deinit();
                    try clip.transform(position);
                    try target.beginScopeView(.{}, &clip);
                    continue;
                },
                .clip_end => {
                    if (depth == 0) return error.InvalidResult;
                    if (hidden_at) |hidden| {
                        if (hidden == depth) hidden_at = null;
                    } else try target.endScope();
                    depth -= 1;
                    continue;
                },
                .glyph, .shape => {},
            }
            if (hidden_at != null) continue;
            // Spaces may have a shaping item and advance but no outline.
            if (part.path.segmentCount() == 0 or (part.style.fill == null and part.style.pen == null)) continue;
            try target.addPathView(&part.path, &part.style, part.transform.then(position));
        }
        if (depth != 0) return error.InvalidResult;
    }
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    style_arena: std.heap.ArenaAllocator,
    labels: []Label,

    pub fn deinit(self: *Batch) void {
        for (self.labels) |label| {
            for (label.parts) |*part| part.path.deinit();
            self.allocator.free(label.parts);
        }
        self.allocator.free(self.labels);
        self.style_arena.deinit();
        self.* = undefined;
    }
};

/// Copy optional native outlines into independently editable huak geometry.
pub fn extract(allocator: std.mem.Allocator, labels: *const typst.Layout) !Batch {
    labels.library.clearError();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const result = try allocator.alloc(Label, labels.frameCount());
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |label| {
            for (label.parts) |*part| part.path.deinit();
            allocator.free(label.parts);
        }
        allocator.free(result);
    }
    var builder: Extractor = .{ .allocator = allocator, .arena = &arena, .library = labels.library };
    defer builder.run_texts.deinit(allocator);
    for (result, 0..) |*label, index| {
        const metrics = try labels.metrics(index);
        if (!std.math.isFinite(metrics.width) or !std.math.isFinite(metrics.height) or !std.math.isFinite(metrics.baseline) or metrics.width < 0 or metrics.height < 0) return error.InvalidResult;
        builder.parts = .empty;
        errdefer {
            for (builder.parts.items) |*part| part.path.deinit();
            builder.parts.deinit(allocator);
        }
        const native = try (try labels.frame(index)).nativeLayout(labels.library);
        try builder.layout(native, metrics.baseline);
        label.* = .{ .metrics = .{ .width = metrics.width, .height = metrics.height, .baseline = metrics.baseline }, .parts = try builder.parts.toOwnedSlice(allocator) };
        initialized += 1;
    }
    return .{ .allocator = allocator, .style_arena = arena, .labels = result };
}

const Extractor = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    library: *typst.Library,
    parts: std.ArrayList(Part) = .empty,
    run_base: usize = 0,
    run_texts: std.AutoHashMapUnmanaged(usize, []const u8) = .empty,

    fn layout(self: *Extractor, native: *const c.TypstLayout, baseline: f64) !void {
        var owner: ?*c.TypstOutline = null;
        defer self.library.functions.outline_release(owner);
        var diagnostic: ?*c.TypstDiagnostics = null;
        defer self.library.functions.diagnostics_release(diagnostic);
        const status = self.library.functions.layout_outline(native, &owner, &diagnostic);
        try self.library.check(status, diagnostic);
        var view: c.TypstOutlineView = undefined;
        try self.library.check(self.library.functions.outline_view(owner, &view), null);
        const entries = try nativeSlice(c.TypstOutlinedPath, view.paths, view.path_count);
        const segments = try nativeSlice(c.TypstPathSegment, view.segments, view.segment_count);
        const borrowed_dashes = try nativeSlice(f64, view.dashes, view.dash_count);
        const dashes = try self.arena.allocator().dupe(f64, borrowed_dashes);
        for (entries) |*entry| {
            if (entry.segment_offset > segments.len or entry.segment_count > segments.len - entry.segment_offset) return error.InvalidResult;
            try self.part(entry, segments[entry.segment_offset..][0..entry.segment_count], dashes, view.run_count, baseline);
        }
        self.run_base = std.math.add(usize, self.run_base, view.run_count) catch return error.InvalidResult;
    }

    fn part(self: *Extractor, value: *const c.TypstOutlinedPath, segments: []const c.TypstPathSegment, dashes: []const f64, run_count: usize, baseline: f64) !void {
        const kind: PartKind = switch (value.kind) {
            c.TYPST_OUTLINE_GLYPH => .glyph,
            c.TYPST_OUTLINE_SHAPE => .shape,
            c.TYPST_OUTLINE_BEGIN_CLIP => .clip_begin,
            c.TYPST_OUTLINE_END_CLIP => .clip_end,
            else => return error.InvalidResult,
        };
        const glyph = kind == .glyph;
        var path = Path.init(self.allocator);
        errdefer path.deinit();
        try path.segments.ensureTotalCapacity(self.allocator, segments.len);
        try copySegments(&path, segments, !glyph);
        const native_transform = fromTransform(value.transform);
        const to_label: g.Transform = .{ .d = -1, .f = baseline };
        const placement = if (glyph) native_transform.then(to_label) else (g.Transform{ .d = -1 }).then(native_transform).then(to_label);
        const advance: g.Point = .{ .x = value.advance.x, .y = -value.advance.y };
        if (!placement.isFinite() or !advance.isFinite()) return error.InvalidResult;
        var run_index: usize = std.math.maxInt(usize);
        var run_text: []const u8 = "";
        var start: usize = 0;
        var end: usize = 0;
        if (glyph) {
            if (value.run_index >= run_count) return error.InvalidResult;
            run_index = std.math.add(usize, self.run_base, value.run_index) catch return error.InvalidResult;
            if (self.run_texts.get(run_index)) |text| {
                run_text = text;
            } else {
                const text = try nativeSlice(u8, value.run_text.data, value.run_text.len);
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidResult;
                run_text = try self.arena.allocator().dupe(u8, text);
                try self.run_texts.put(self.allocator, run_index, run_text);
            }
            start = value.cluster_start;
            end = value.cluster_end;
            if (start > end or end > run_text.len or !boundary(run_text, start) or !boundary(run_text, end)) return error.InvalidResult;
        }
        const resolved_style = if (kind == .clip_begin or kind == .clip_end) DisplayList.Style{} else try self.style(value, dashes);
        try self.parts.append(self.allocator, .{ .path = path, .transform = placement, .style = resolved_style, .kind = kind, .glyph_id = if (glyph) value.glyph_id else std.math.maxInt(u32), .run_index = run_index, .run_text = run_text, .cluster_start = start, .cluster_end = end, .advance = advance });
    }

    fn style(self: *Extractor, value: *const c.TypstOutlinedPath, dashes: []const f64) !DisplayList.Style {
        _ = self;
        if (value.flags & ~@as(u32, c.TYPST_STYLE_FILL | c.TYPST_STYLE_STROKE) != 0) return error.InvalidResult;
        const rule: DisplayList.FillRule = switch (value.fill_rule) {
            c.TYPST_FILL_NONZERO => .nonzero,
            c.TYPST_FILL_EVENODD => .evenodd,
            else => return error.InvalidResult,
        };
        var result: DisplayList.Style = .{ .fill_rule = rule };
        if (value.flags & c.TYPST_STYLE_FILL != 0) result.fill = try color(value.fill);
        if (value.flags & c.TYPST_STYLE_STROKE != 0) {
            if (!std.math.isFinite(value.stroke_width_pt) or value.stroke_width_pt < 0 or !std.math.isFinite(value.miter_limit) or value.miter_limit < 1 or !std.math.isFinite(value.dash_phase_pt)) return error.InvalidResult;
            if (value.dash_offset > dashes.len or value.dash_count > dashes.len - value.dash_offset) return error.InvalidResult;
            const dash = dashes[value.dash_offset..][0..value.dash_count];
            for (dash) |length| if (!std.math.isFinite(length) or length < 0) return error.InvalidResult;
            result.pen = .{ .color = try color(value.stroke), .width = value.stroke_width_pt, .miter_limit = value.miter_limit, .cap = switch (value.line_cap) {
                c.TYPST_CAP_BUTT => .butt,
                c.TYPST_CAP_ROUND => .round,
                c.TYPST_CAP_SQUARE => .square,
                else => return error.InvalidResult,
            }, .join = switch (value.line_join) {
                c.TYPST_JOIN_MITER => .miter,
                c.TYPST_JOIN_ROUND => .round,
                c.TYPST_JOIN_BEVEL => .bevel,
                else => return error.InvalidResult,
            }, .dash = dash, .dash_phase = value.dash_phase_pt };
        }
        return result;
    }
};

fn nativeSlice(comptime T: type, pointer: [*c]const T, length: usize) ![]const T {
    if (length == 0) return &.{};
    if (pointer == null or @intFromPtr(pointer) % @alignOf(T) != 0 or length > @as(usize, std.math.maxInt(isize)) / @sizeOf(T)) return error.InvalidResult;
    return pointer[0..length];
}
fn boundary(text: []const u8, index: usize) bool {
    if (index == text.len) return true;
    _ = std.unicode.utf8ByteSequenceLength(text[index]) catch return false;
    return true;
}
fn copySegments(path: *Path, segments: []const c.TypstPathSegment, flip_y: bool) !void {
    for (segments) |segment| switch (segment.kind) {
        c.TYPST_SEGMENT_MOVE => try path.moveTo(point(segment.p1, flip_y)),
        c.TYPST_SEGMENT_LINE => try path.lineTo(point(segment.p1, flip_y)),
        c.TYPST_SEGMENT_CUBIC => try path.cubicTo(point(segment.p1, flip_y), point(segment.p2, flip_y), point(segment.p3, flip_y)),
        c.TYPST_SEGMENT_CLOSE => try path.close(),
        else => return error.InvalidResult,
    };
}
fn point(value: c.TypstPoint, flip_y: bool) g.Point {
    return .{ .x = value.x, .y = if (flip_y) -value.y else value.y };
}
fn fromTransform(value: c.TypstTransform) g.Transform {
    return .{ .a = value.xx, .b = value.yx, .c = value.xy, .d = value.yy, .e = value.dx, .f = value.dy };
}
fn color(value: c.TypstColor) !DisplayList.Color {
    for ([_]f64{ value.r, value.g, value.b, value.a }) |channel| if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return error.InvalidResult;
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
}
