//! Physical pens: each expanded once, then measured and encoded.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../../drawing/geometry.zig");
const DisplayList = @import("../../../drawing/DisplayList.zig");
const Path = @import("../../../drawing/path/Path.zig");
const pens = @import("../../../drawing/pen/root.zig");
const physical = @import("../pen.zig");
const typst_scene = @import("../scene.zig");
const native_records = @import("native.zig");
const paint_routes = @import("paint.zig");
const NativeSegments = @import("NativeSegments.zig");
const Builder = typst_scene.Builder;
const pathSegment = native_records.pathSegment;

pub fn prepareStrokes(self: *Builder) ![]const ?typst_scene.Builder.Stroke {
    var strokes = strokePass(self);
    defer strokes.workspace.deinit();
    const picture = self.picture;
    for (picture.commands.items) |*command| {
        if (command.* != .path) continue;
        const draw = &command.path;
        const pen = if (draw.style.pen) |*value| value else continue;
        if (!pen.resolvesStroke()) continue;
        _ = try strokes.visitStroke(try picture.geometry().view(picture.storage.allocator, draw.path), draw.style, null);
    }
    return strokes.items.items;
}

pub fn strokePass(self: *Builder) Strokes {
    return .{ .workspace = .init(self.arena.child_allocator), .encoder = self, .options = self.pen_options };
}

pub const Strokes = struct {
    workspace: std.heap.ArenaAllocator,
    encoder: ?*Builder = null,
    options: pens.StrokeOptions = .{},
    items: std.ArrayList(?typst_scene.Builder.Stroke) = .empty,

    // Each physical path is expanded once. A fitted page measures the same
    // outline that is submitted, before releasing the temporary Zig path.
    pub fn visitStroke(self: *Strokes, center: Path, style_: *const DisplayList.Style, transform: ?g.Transform) !?g.BBox {
        // Geometry temporaries end with this stroke; encoded paths live
        // through native submission in the builder's separate arena.
        _ = self.workspace.reset(.retain_capacity);
        const stroke = try physical.resolvePath(self.workspace.allocator(), center, style_, self.options);
        if (self.encoder) |builder| {
            const native = try encodeStroke(builder, &stroke, &style_.pen.?);
            try self.items.append(builder.arena.allocator(), native);
        }
        if (transform) |t| return physical.inkBounds(&stroke, center.segments.items, style_, t);
        return null;
    }
};

pub fn encodeStroke(self: *Builder, stroke: *const pens.Stroke, pen: *const DisplayList.Pen) !?typst_scene.Builder.Stroke {
    if (stroke.transform == null and stroke.path.segments.items.len == 0) return null;
    if (pen.motion) |motion| try physical.checkOutputPrecision(&stroke.path, motion.tolerance);
    const data = try self.arena.allocator().alloc(c.TypstPathSegment, stroke.path.segments.items.len);
    for (stroke.path.segments.items, data) |segment, *out| out.* = pathSegment(segment);
    // The normalized ellipse uses a unit circular stroke. Dashes have
    // already been applied to the centerline by the geometry kernel.
    const style_: DisplayList.Style = if (stroke.transform != null)
        .{ .pen = .{ .paint = pen.paint, .cap = pen.cap, .join = pen.join, .miter_limit = pen.miter_limit } }
    else
        .{ .fill = pen.paint };
    return .{ .path = try native_records.pathData(self, data), .style = style_, .transform = stroke.transform };
}

pub fn resolvedPath(self: *Builder, draw: *const DisplayList.PathCommand, stroke: ?typst_scene.Builder.Stroke, id: u64) !void {
    const grouped = draw.style.fill != null and id != 0;
    if (grouped) try self.group(draw.transform, null, id, 1);
    const placement: g.Transform = if (grouped) .{} else draw.transform;
    const child_id = if (grouped) 0 else id;
    if (draw.style.fill) |fill| try paint_routes.paint(self, try native_records.path(self, draw.path), &.{ .fill = fill, .fill_rule = draw.style.fill_rule }, placement, 0);
    if (stroke) |*value| {
        try paint_routes.paint(self, value.path, &value.style, if (value.transform) |transform| transform.then(placement) else placement, child_id);
    } else if (child_id != 0) {
        try self.group(placement, null, child_id, 1);
        try self.endScope();
    }
    if (grouped) try self.endScope();
}

test "mixed nib and ordinary paths convert only referenced intervals" {
    const t = std.testing;
    const nibs = @import("../../../drawing/pen/root.zig");
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
            const draw: DisplayList.PathCommand = .{ .path = nib_range, .style = &.{ .pen = pen, .fill = if (filled) DisplayList.Paint.black else null }, .transform = .{} };
            try picture.commands.append(picture.storage.allocator, .{ .path = draw });
            try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = ordinary, .style = &.{ .pen = .{} }, .transform = .{} } });
            var library: typst.Library = undefined;
            var builder: Builder = .{ .arena = .init(t.allocator), .library = &library, .picture = &picture, .size = .{ .x = 10, .y = 10 } };
            defer builder.arena.deinit();
            const strokes = try prepareStrokes(&builder);
            try t.expectEqual(@as(usize, 1), strokes.len);
            var resolved = try resolveCopy(t.allocator, source[0..2], draw.style);
            defer resolved.path.deinit();
            const stroke = strokes[0].?;
            // The normalized ellipse is a unit stroke with the dashes
            // already applied; a polygon's outline is a fill.
            if (nib == .ellipse) {
                const unit = stroke.style.pen.?;
                try t.expect(stroke.style.fill == null);
                try t.expectEqual(@as(f64, 1), unit.width);
                try t.expectEqual(@as(usize, 0), unit.dash.len);
                try t.expectEqual(@as(f64, 0), unit.dash_phase);
            } else try t.expect(stroke.style.fill != null and stroke.style.pen == null);
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
    var measure: Strokes = .{ .workspace = .init(outer.allocator()) };
    defer measure.workspace.deinit();
    for (0..2) |_| _ = try measure.visitStroke(path, &.{ .pen = paint }, .{});
    const capacity = outer.queryCapacity();
    for (0..32) |_| _ = try measure.visitStroke(path, &.{ .pen = paint }, .{});
    try std.testing.expectEqual(capacity, outer.queryCapacity());
}

/// The stroke of an owned copy of `segments`.
fn resolveCopy(allocator: std.mem.Allocator, segments: []const Path.Segment, style: *const DisplayList.Style) !pens.Stroke {
    var center = Path.init(allocator);
    defer center.deinit();
    try center.segments.appendSlice(allocator, segments);
    return physical.resolvePath(allocator, center, style, .{});
}

fn prepareStrokeExercise(allocator: std.mem.Allocator) !void {
    const source = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 40, .y = 20 } }, .{ .line = .{ .x = 40, .y = 40 } }, .close };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    for ([_]pens.Nib{ pens.Nib.square(), .{ .ellipse = .{ .a = 4, .d = 2 } } }) |nib| {
        for ([_][]const f64{ &.{}, &.{ 4, 2 } }) |dash| {
            const style = try picture.storage.styles.intern(&.{ .pen = .{ .nib = nib, .cap = .round, .join = .round, .dash = dash, .dash_phase = 1 } });
            var first = try resolveCopy(allocator, &source, style);
            defer first.path.deinit();
            var second = try resolveCopy(allocator, &source, style);
            defer second.path.deinit();
            try std.testing.expect(first.path.segments.items.ptr != second.path.segments.items.ptr);
            try std.testing.expectEqualDeep(first.path.segments.items, second.path.segments.items);
            try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = .{ .first = 0, .count = source.len, .source = 1 }, .style = style, .transform = .{} } });
        }
    }
    var library: typst.Library = undefined;
    var builder: Builder = .{ .arena = .init(allocator), .library = &library, .picture = &picture, .size = .{ .x = 10, .y = 10 } };
    defer builder.arena.deinit();
    const strokes = try prepareStrokes(&builder);
    try std.testing.expectEqual(picture.commands.items.len, strokes.len);
    for (strokes, picture.commands.items) |stroke, command| {
        try std.testing.expect(stroke.?.path.segment_count != 0);
        const outlined = command.path.style.pen.?.nib.? != .ellipse;
        try std.testing.expectEqual(outlined, stroke.?.style.fill != null);
        try std.testing.expectEqual(!outlined, stroke.?.style.pen != null);
    }
}

test "native stroke preparation releases every failed allocation" {
    try prepareStrokeExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), prepareStrokeExercise, .{});
}
