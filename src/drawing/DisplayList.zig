//! Flat rendering commands and their geometry; retained object identity lives in Scene.
//! Geometry uses y-up coordinates. Label transforms map measured y-down frame
//! coordinates into this space; baseline helpers perform that conversion.
const std = @import("std");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");

const Storage = @import("Storage.zig");
pub const Color = Storage.Color;
pub const Cap = Storage.Cap;
pub const Join = Storage.Join;
pub const FillRule = Storage.FillRule;
pub const Pen = Storage.Pen;
pub const Paint = Storage.Paint;
pub const Style = Storage.Style;
pub const Gradient = @import("style.zig").Gradient;
pub const MeshStore = Storage.MeshStore;
pub const Metrics = Storage.Metrics;
pub const PathRef = Storage.PathRef;
pub const Geometry = Storage.Geometry;
pub const PathCommand = Storage.PathCommand;
pub const Label = Storage.Label;
pub const Error = Storage.Error;
pub const validateStyle = Storage.validateStyle;
pub const Scope = Storage.Scope;
const copying = @import("display_list/copy.zig");
pub const Command = union(enum) { path: PathCommand, label: Label, push: Scope, pop: void };
/// Leave room for the mathematical coordinate container and one marked
/// filldraw nib expansion. Generic native scenes support 128 nested groups.
pub const max_scope_depth = 126;

const DisplayList = @This();

storage: Storage,
sources: std.ArrayList(Storage.Bank) = .empty,
commands: std.ArrayList(Command) = .empty,
scope_depth: usize = 0,
maximum_depth: usize = 0,

pub fn init(allocator: std.mem.Allocator) DisplayList {
    return .{ .storage = .init(allocator) };
}
/// Pictures attached to the same store share mesh arrays when copied.
pub fn initWithMeshes(allocator: std.mem.Allocator, meshes: ?*MeshStore) DisplayList {
    return .{ .storage = .initWithMeshes(allocator, meshes) };
}
pub fn deinit(self: *DisplayList) void {
    self.sources.deinit(self.storage.allocator);
    self.commands.deinit(self.storage.allocator);
    self.storage.deinit();
    self.* = undefined;
}
/// Copies path segments. The caller may release or mutate the input path.
pub fn addPath(self: *DisplayList, path: Path, style: Style, transform: g.Transform) Error!void {
    return self.addPathView(&path, &style, transform);
}
/// Borrow the path and style for the duration of the call. The picture
/// still takes its required snapshot of both segments and style data.
/// `path` must not be a view into this picture's segment store.
pub fn addPathView(self: *DisplayList, path: *const Path, style: *const Style, transform: g.Transform) Error!void {
    try Storage.validateDrawing(path, style, transform);
    try self.commands.ensureUnusedCapacity(self.storage.allocator, 1);
    const item = try self.storage.path(path, style, transform);
    self.commands.appendAssumeCapacity(.{ .path = item });
}
pub fn draw(self: *DisplayList, path: Path, pen: Pen, transform: g.Transform) Error!void {
    try self.addPath(path, .{ .pen = pen }, transform);
}
pub fn fill(self: *DisplayList, path: Path, paint: Paint, transform: g.Transform) Error!void {
    try self.addPath(path, .{ .fill = paint }, transform);
}
pub fn filldraw(self: *DisplayList, path: Path, paint: Paint, pen: Pen, transform: g.Transform) Error!void {
    try self.addPath(path, .{ .fill = paint, .pen = pen }, transform);
}
/// clip is in the group's local coordinates. Every contour must close.
/// Alpha belongs to individual paints; a group blends as one layer only
/// when it has an opacity (`beginLayer`).
pub fn beginScope(self: *DisplayList, transform: g.Transform, clip: ?Path) Error!void {
    if (clip) |path| return self.beginScopeView(transform, &path);
    return self.beginScopeView(transform, null);
}
/// Borrow the clipping path. The group snapshot still owns the segments.
/// `clip` must not be a view into this picture's segment store.
pub fn beginScopeView(self: *DisplayList, transform: g.Transform, clip: ?*const Path) Error!void {
    return self.beginLayer(transform, clip, 1);
}
/// A group whose finished content is blended at `opacity`, from 0 to 1. Its
/// commands paint over one another first, so paints inside that overlap do
/// not show through each other. The clip is borrowed like `beginScopeView`'s.
pub fn beginLayer(self: *DisplayList, transform: g.Transform, clip: ?*const Path, opacity: f64) Error!void {
    if (self.scope_depth == max_scope_depth) return error.GroupNestingTooDeep;
    try Storage.validateScope(transform, clip);
    try Storage.validateOpacity(opacity);
    try self.commands.ensureUnusedCapacity(self.storage.allocator, 1);
    var scope = try self.storage.scope(transform, clip);
    scope.opacity = opacity;
    self.commands.appendAssumeCapacity(.{ .push = scope });
    self.scope_depth += 1;
    self.maximum_depth = @max(self.maximum_depth, self.scope_depth);
}
pub fn endScope(self: *DisplayList) Error!void {
    if (self.scope_depth == 0) return error.UnbalancedGroups;
    try self.commands.append(self.storage.allocator, .pop);
    self.scope_depth -= 1;
}
/// transform maps the original measured frame's top-left, x-right/y-down
/// coordinates into the picture's mathematical coordinates.
pub fn addLabel(self: *DisplayList, reference: u32, metrics: Metrics, transform: g.Transform) Error!void {
    const item = try Storage.label(reference, metrics, transform);
    try self.commands.append(self.storage.allocator, .{ .label = item });
}
pub fn labelAtBaseline(self: *DisplayList, reference: u32, metrics: Metrics, at: g.Point, transform: g.Transform) Error!void {
    const item = try Storage.baseline(reference, metrics, at, transform);
    try self.commands.append(self.storage.allocator, .{ .label = item });
}
/// Position baseline left at at+normal*offset; text's x axis follows tangent.
/// The left normal points above an upright label on a rightward path.
pub fn labelAlong(self: *DisplayList, reference: u32, metrics: Metrics, at: g.Point, tangent: g.Point, normal_offset: f64) Error!void {
    if (!at.isFinite() or !std.math.isFinite(normal_offset)) return error.NonFinite;
    const direction = try tangent.normalized();
    const normal = g.Point{ .x = -direction.y, .y = direction.x };
    const origin = at.add(normal.scale(normal_offset + metrics.baseline));
    try self.addLabel(reference, metrics, .{ .a = direction.x, .b = direction.y, .c = -normal.x, .d = -normal.y, .e = origin.x, .f = origin.y });
}
/// Compose a balanced picture as a group, retaining its command order and
/// copying both arrays. Label references address the caller's shared batch.
pub fn append(self: *DisplayList, other: *const DisplayList, transform: g.Transform) Error!void {
    try copying.copyCommands(self, other, transform);
}

/// Own a copy of the command stream, including any borrowed geometry.
pub fn copy(self: *const DisplayList, allocator: std.mem.Allocator) Error!DisplayList {
    var result = DisplayList.init(allocator);
    errdefer result.deinit();
    try copying.copyCommands(&result, self, null);
    return result;
}

/// Roll back owned commands, releasing their retained styles. Geometry and
/// group accounting are restored by the enclosing transaction.
pub fn truncateCommands(self: *DisplayList, count: usize) void {
    for (self.commands.items[count..]) |command| {
        if (command == .path) self.storage.styles.release(command.path.style);
    }
    self.commands.items.len = count;
}
/// Tight transformed cubic centerline/fill bounds; stroke bounds are
/// conservative, including square caps and the configured miter limit.
/// Nonrectangular clips intersect bounding boxes conservatively. An empty
/// intersection remains empty through all nested groups.
pub fn bounds(self: *const DisplayList) Error!?g.BBox {
    // Without a resolver the traversal can only return geometry errors.
    return self.boundsWith(null) catch |err| return @errorCast(err);
}

/// Resolve native label extents when available. The standalone geometry
/// API uses logical metrics; hosts can include ink outside those metrics.
/// The borrowed provider implements `resolveBounds(reference) !BBox`; null
/// uses logical metrics. Its concrete type is preserved through traversal.
pub fn boundsWith(self: *const DisplayList, labels: anytype) anyerror!?g.BBox {
    return self.measuredBounds(labels, null);
}

/// A stroke provider can measure the realized physical pen in the current
/// coordinate system. Clipping and label placement use the same traversal.
pub fn measuredBounds(self: *const DisplayList, labels: anytype, strokes: anytype) anyerror!?g.BBox {
    if (self.scope_depth != 0) return error.UnbalancedGroups;
    var stack: [max_scope_depth]State = undefined;
    var depth: usize = 0;
    var state: State = .{};
    var result: ?g.BBox = null;
    for (self.commands.items) |*command| {
        var box: ?g.BBox = null;
        switch (command.*) {
            .push => |*group| {
                if (depth == max_scope_depth) return error.GroupNestingTooDeep;
                stack[depth] = state;
                depth += 1;
                state.transform = group.transform.then(state.transform);
                if (!state.transform.isFinite()) return error.NonFinite;
                if (group.clip) |clip| {
                    const clip_box = try Path.paintedBounds(try self.range(clip), state.transform);
                    state.clip = state.clip.intersect(if (clip_box) |b| .{ .box = b } else .empty);
                }
            },
            .pop => {
                if (depth == 0) return error.UnbalancedGroups;
                depth -= 1;
                state = stack[depth];
            },
            .path => |*p| bounds: {
                const transform = p.transform.then(state.transform);
                if (!transform.isFinite()) return error.NonFinite;
                if (comptime @TypeOf(strokes) != @TypeOf(null)) {
                    if (p.style.pen) |*pen| if (pen.resolvesStroke()) {
                        box = try strokes.visitStroke(try self.geometry().view(self.storage.allocator, p.path), p.style, transform);
                        break :bounds;
                    };
                }
                box = try pathBounds(try self.range(p.path), p.style.pen, transform);
            },
            .label => |label| {
                const transform = label.transform.then(state.transform);
                if (!transform.isFinite()) return error.NonFinite;
                const local = if (comptime @TypeOf(labels) != @TypeOf(null))
                    try labels.resolveBounds(label.reference)
                else
                    g.BBox{ .min = .zero, .max = .{ .x = label.metrics.width, .y = label.metrics.height } };
                box = local.transformed(transform);
            },
        }
        if (box) |b| {
            if (!b.min.isFinite() or !b.max.isFinite()) return error.NonFinite;
            const clipped = state.clip.intersect(.{ .box = b });
            if (clipped == .box) result = if (result) |r| r.unite(clipped.box) else clipped.box;
        }
    }
    if (depth != 0) return error.UnbalancedGroups;
    return result;
}
/// Borrowed command geometry, valid until the picture is mutated.
pub fn geometry(self: *const DisplayList) Geometry {
    return .{ .primary = self.storage.bank(), .sources = self.sources.items };
}

pub fn range(self: *const DisplayList, reference: PathRef) Error![]const Path.Segment {
    return self.geometry().range(reference);
}

const Clip = union(enum) {
    unbounded,
    empty,
    box: g.BBox,
    fn intersect(a: Clip, b: Clip) Clip {
        if (a == .empty or b == .empty) return .empty;
        if (a == .unbounded) return b;
        if (b == .unbounded) return a;
        const box = g.BBox{ .min = .{ .x = @max(a.box.min.x, b.box.min.x), .y = @max(a.box.min.y, b.box.min.y) }, .max = .{ .x = @min(a.box.max.x, b.box.max.x), .y = @min(a.box.max.y, b.box.max.y) } };
        return if (box.min.x > box.max.x or box.min.y > box.max.y) .empty else .{ .box = box };
    }
};
const State = struct { transform: g.Transform = .{}, clip: Clip = .unbounded };

pub fn pathBounds(segments: []const Path.Segment, stroke: ?Pen, transform: g.Transform) Error!?g.BBox {
    var box = try Path.paintedBounds(segments, transform);
    if (stroke) |pen| if (box) |b| {
        if (pen.motion) |motion| {
            const nib = pen.nib orelse @import("pen/nib.zig").Nib{ .ellipse = .scaling(pen.width, pen.width) };
            const extent = @import("pen/sweep.zig").radius(nib) catch return error.InvalidPen;
            const norm = std.math.hypot(std.math.hypot(transform.a, transform.b), std.math.hypot(transform.c, transform.d));
            const padding = extent * motion.bounds().scale * norm;
            if (!std.math.isFinite(padding)) return error.NonFinite;
            box = b.expanded(padding);
        } else if (pen.nib) |nib| {
            const nib_box = nib.bounds() catch return error.InvalidPen;
            var linear = transform;
            linear.e = 0;
            linear.f = 0;
            var offset = nib_box.transformed(linear);
            if (nib == .ellipse and (pen.join == .miter or pen.cap == .square)) {
                const combined = nib.ellipse.then(linear);
                const norm = std.math.hypot(std.math.hypot(combined.a, combined.b), std.math.hypot(combined.c, combined.d));
                const radius = norm * (if (pen.join == .miter) pen.miter_limit else @as(f64, 1));
                if (!std.math.isFinite(radius)) return error.NonFinite;
                const center: g.Point = .{ .x = combined.e, .y = combined.f };
                offset = .{ .min = center.sub(.{ .x = radius, .y = radius }), .max = center.add(.{ .x = radius, .y = radius }) };
            } else if (nib == .polygon and (pen.join == .miter or pen.cap == .square)) {
                const diameter = offset.max.sub(offset.min).norm();
                const extension = diameter * (if (pen.join == .miter) pen.miter_limit else @as(f64, 1));
                if (!std.math.isFinite(extension)) return error.NonFinite;
                offset = offset.expanded(extension);
            }
            box = .{ .min = b.min.add(offset.min), .max = b.max.add(offset.max) };
        } else {
            const norm = std.math.hypot(std.math.hypot(transform.a, transform.b), std.math.hypot(transform.c, transform.d));
            const radius = pen.width * norm * (if (pen.join == .miter) pen.miter_limit else if (pen.cap == .square) @as(f64, 1) else @as(f64, 0.5));
            if (!std.math.isFinite(radius)) return error.NonFinite;
            box = b.expanded(radius);
        }
    };
    return box;
}

test {
    _ = @import("display_list/copy.zig");
    _ = @import("display_list/commands_test.zig");
}
