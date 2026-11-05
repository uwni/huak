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
pub const Style = Storage.Style;
pub const Metrics = Storage.Metrics;
pub const PathRef = Storage.PathRef;
pub const Geometry = Storage.Geometry;
pub const PathCommand = Storage.PathCommand;
pub const Label = Storage.Label;
pub const Error = Storage.Error;
pub const validateStyle = Storage.validateStyle;
pub const Scope = Storage.Scope;
pub const Command = union(enum) { path: PathCommand, label: Label, push: Scope, pop: void };
/// Leave room for the mathematical coordinate container and one marked
/// filldraw nib expansion. Generic native scenes support 128 nested groups.
pub const max_scope_depth = 126;

const DisplayList = @This();

storage: Storage,
sources: std.ArrayList([]const Path.Segment) = .empty,
commands: std.ArrayList(Command) = .empty,
scope_depth: usize = 0,
maximum_depth: usize = 0,

pub fn init(allocator: std.mem.Allocator) DisplayList {
    return .{ .storage = .init(allocator) };
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
pub fn fill(self: *DisplayList, path: Path, color: Color, transform: g.Transform) Error!void {
    try self.addPath(path, .{ .fill = color }, transform);
}
pub fn filldraw(self: *DisplayList, path: Path, color: Color, pen: Pen, transform: g.Transform) Error!void {
    try self.addPath(path, .{ .fill = color, .pen = pen }, transform);
}
/// clip is in the group's local coordinates. Every contour must close.
/// Alpha belongs to individual paints; groups do not imply compositing.
pub fn beginScope(self: *DisplayList, transform: g.Transform, clip: ?Path) Error!void {
    if (clip) |path| return self.beginScopeView(transform, &path);
    return self.beginScopeView(transform, null);
}
/// Borrow the clipping path. The group snapshot still owns the segments.
/// `clip` must not be a view into this picture's segment store.
pub fn beginScopeView(self: *DisplayList, transform: g.Transform, clip: ?*const Path) Error!void {
    if (self.scope_depth == max_scope_depth) return error.GroupNestingTooDeep;
    try Storage.validateScope(transform, clip);
    try self.commands.ensureUnusedCapacity(self.storage.allocator, 1);
    const scope = try self.storage.scope(transform, clip);
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
    try self.copyCommands(other, transform);
}

/// Own a copy of the command stream, including any borrowed geometry.
pub fn copy(self: *const DisplayList, allocator: std.mem.Allocator) Error!DisplayList {
    var result = DisplayList.init(allocator);
    errdefer result.deinit();
    try result.copyCommands(self, null);
    return result;
}

fn copyCommands(self: *DisplayList, other: *const DisplayList, transform: ?g.Transform) Error!void {
    if (self == other) return error.SelfAppend;
    // A shallow copy of DisplayList shares its arrays. Appending into one and
    // reallocating it would invalidate the source being iterated.
    if (self.commands.items.ptr == other.commands.items.ptr and other.commands.items.len != 0) return error.SelfAppend;
    if (self.storage.segments.items.ptr == other.storage.segments.items.ptr and other.storage.segments.items.len != 0) return error.SelfAppend;
    if (transform) |value| if (!value.isFinite()) return error.NonFinite;
    if (other.scope_depth != 0) return error.UnbalancedGroups;
    const nesting: usize = @intFromBool(transform != null);
    if (self.scope_depth + other.maximum_depth + nesting > max_scope_depth) return error.GroupNestingTooDeep;
    var segment_count: usize = 0;
    for (other.commands.items) |command| {
        const reference = switch (command) {
            .path => |item| item.path,
            .push => |group| group.clip orelse continue,
            else => continue,
        };
        const segments = try other.range(reference);
        const destination = self.storage.segments.items;
        if (segments.len != 0 and destination.len != 0 and
            @intFromPtr(segments.ptr) < @intFromPtr(destination.ptr + destination.len) and
            @intFromPtr(destination.ptr) < @intFromPtr(segments.ptr + segments.len)) return error.SelfAppend;
        segment_count = std.math.add(usize, segment_count, segments.len) catch return error.InvalidPath;
    }
    try self.commands.ensureUnusedCapacity(self.storage.allocator, other.commands.items.len + 2 * nesting);
    try self.storage.segments.ensureUnusedCapacity(self.storage.allocator, segment_count);
    const offset = self.storage.segments.items.len;
    const previous_commands = self.commands.items.len;
    errdefer {
        self.storage.segments.items.len = offset;
        self.truncateCommands(previous_commands);
    }
    if (transform) |value| self.commands.appendAssumeCapacity(.{ .push = .{ .transform = value, .clip = null } });
    for (other.commands.items) |command| self.commands.appendAssumeCapacity(try self.copyCommand(other, command));
    if (transform != null) self.commands.appendAssumeCapacity(.pop);
    self.maximum_depth = @max(self.maximum_depth, self.scope_depth + other.maximum_depth + nesting);
}

/// Roll back owned commands, releasing their retained styles. Geometry and
/// group accounting are restored by the enclosing transaction.
pub fn truncateCommands(self: *DisplayList, count: usize) void {
    for (self.commands.items[count..]) |command| {
        if (command == .path) self.storage.styles.release(command.path.style);
    }
    self.commands.items.len = count;
}
/// Copy a validated command's geometry and paints into reserved storage.
/// The caller validates ranges and reserves their combined segment count
/// before copying; source and destination may share the segment allocation.
pub fn copyCommand(self: *DisplayList, other: *const DisplayList, command: Command) Error!Command {
    return switch (command) {
        .path => |item| .{ .path = try self.storage.copyPath(other.geometry(), item) },
        .push => |scope| .{ .push = self.storage.copyScope(other.geometry(), scope) },
        else => command,
    };
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
                    const clip_box = try segmentBounds(try self.range(clip), state.transform);
                    state.clip = state.clip.intersect(if (clip_box) |b| .{ .box = b } else .empty);
                }
            },
            .pop => {
                if (depth == 0) return error.UnbalancedGroups;
                depth -= 1;
                state = stack[depth];
            },
            .path => |*p| {
                const transform = p.transform.then(state.transform);
                if (!transform.isFinite()) return error.NonFinite;
                box = try segmentBounds(try self.range(p.path), transform);
                if (p.style.pen) |pen| if (box) |b| {
                    if (pen.nib) |nib| {
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
                        const radius = pen.maxWidth() * norm * (if (pen.join == .miter) pen.miter_limit else if (pen.cap == .square) @as(f64, 1) else @as(f64, 0.5));
                        if (!std.math.isFinite(radius)) return error.NonFinite;
                        box = b.expanded(radius);
                    }
                };
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
    return .{ .primary = self.storage.segments.items, .sources = self.sources.items };
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

fn segmentBounds(segments: []const Path.Segment, transform: g.Transform) Error!?g.BBox {
    var current: g.Point = .zero;
    var start: g.Point = .zero;
    var result: ?g.BBox = null;
    for (segments) |segment| {
        const box: g.BBox = switch (segment) {
            .move => |p| {
                current = p;
                start = p;
                continue;
            },
            .line => |p| blk: {
                const b = g.BBox.fromPoints(transform.apply(current), transform.apply(p));
                current = p;
                break :blk b;
            },
            .cubic => |c| blk: {
                const cubic = (g.Cubic{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end }).transformed(transform);
                if (!cubic.isFinite()) return error.NonFinite;
                current = c.end;
                break :blk cubic.bounds();
            },
            .close => blk: {
                const b = g.BBox.fromPoints(transform.apply(current), transform.apply(start));
                current = start;
                break :blk b;
            },
        };
        if (!box.min.isFinite() or !box.max.isFinite()) return error.NonFinite;
        result = if (result) |r| r.unite(box) else box;
    }
    return result;
}

fn rectangle(allocator: std.mem.Allocator, min: g.Point, max: g.Point) !Path {
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.moveTo(min);
    try path.lineTo(.{ .x = max.x, .y = min.y });
    try path.lineTo(max);
    try path.lineTo(.{ .x = min.x, .y = max.y });
    try path.close();
    return path;
}

test "fill bounds use transformed cubic extrema, owned segments and command order" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.fill(path, .{ .r = 1, .a = 0.5 }, g.Transform.scaling(2, 3));
    try path.transform(g.Transform.translation(1000, 0));
    const box = (try picture.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 200), box.max.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 225), box.max.y, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.5), picture.commands.items[0].path.style.fill.?.a);
}

test "dash styles are independent snapshots across mutation and picture append" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 20, .y = 0 });
    var pattern = [_]f64{ 3, 0, 2 };
    var source = DisplayList.init(allocator);
    var source_live = true;
    defer if (source_live) source.deinit();
    try source.draw(path, .{ .dash = &pattern, .dash_phase = -2, .miter_limit = 12 }, .{});
    pattern[0] = 99;
    var target = DisplayList.init(allocator);
    defer target.deinit();
    try target.append(&source, .{});
    source.deinit();
    source_live = false;
    const pen = target.commands.items[1].path.style.pen.?;
    try std.testing.expectEqualSlices(f64, &.{ 3, 0, 2 }, pen.dash);
    try std.testing.expectEqual(@as(f64, -2), pen.dash_phase);
    try std.testing.expectEqual(@as(f64, 12), pen.miter_limit);
    const box = (try target.bounds()).?;
    try std.testing.expect(box.min.x <= -12 and box.max.x >= 32);
}

test "stroke patterns reject invalid lengths and miter limits" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 20, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    for ([_]Pen{
        .{ .dash = &.{ 0, 0 } },            .{ .dash = &.{ -1, 2 } },
        .{ .dash = &.{std.math.inf(f64)} }, .{ .dash_phase = std.math.nan(f64) },
        .{ .miter_limit = 0.5 },            .{ .miter_limit = std.math.inf(f64) },
    }) |pen| try std.testing.expectError(error.InvalidPen, picture.draw(path, pen, .{}));
    try std.testing.expectEqual(@as(usize, 0), picture.commands.items.len);
}

test "physical nib snapshots own polygon vertices and bounds follow nib transforms" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 20, .y = 0 });
    var vertices = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.draw(path, .{ .nib = .{ .polygon = &vertices }, .cap = .round, .join = .round }, .{});
    vertices[0].x = -100;
    const nib = picture.commands.items[0].path.style.pen.?.nib.?;
    try std.testing.expectEqual(@as(f64, -2), nib.polygon[0].x);
    const box = (try picture.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = -2, .y = -1 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 22, .y = 1 }, box.max);
}

test "nested transforms clipping and composition preserve draw order" {
    var shape = try rectangle(std.testing.allocator, .zero, .{ .x = 100, .y = 100 });
    defer shape.deinit();
    var clip = try rectangle(std.testing.allocator, .{ .x = 10, .y = 20 }, .{ .x = 40, .y = 50 });
    defer clip.deinit();
    var child = DisplayList.init(std.testing.allocator);
    defer child.deinit();
    try child.beginScope(g.Transform.translation(5, 7), clip);
    try child.fill(shape, .{ .g = 1 }, .{});
    try child.endScope();
    var parent = DisplayList.init(std.testing.allocator);
    defer parent.deinit();
    try parent.append(&child, g.Transform.scaling(2, 3));
    const box = (try parent.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 81 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 90, .y = 171 }, box.max);
    try std.testing.expect(parent.commands.items[0] == .push);
    try std.testing.expect(parent.commands.items[2] == .path);
    try std.testing.expect(parent.commands.items[4] == .pop);
}

test "disjoint clips stay empty and stroke bounds cover transformed square caps" {
    var shape = try rectangle(std.testing.allocator, .zero, .{ .x = 1, .y = 1 });
    defer shape.deinit();
    var a = try rectangle(std.testing.allocator, .zero, .{ .x = 5, .y = 5 });
    defer a.deinit();
    var b = try rectangle(std.testing.allocator, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer b.deinit();
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.beginScope(.{}, a);
    try picture.beginScope(.{}, b);
    try picture.fill(shape, .black, .{});
    try picture.endScope();
    try picture.endScope();
    try std.testing.expect((try picture.bounds()) == null);
    try picture.draw(shape, .{ .width = 2, .cap = .square, .join = .bevel }, g.Transform.scaling(2, 3));
    const box = (try picture.bounds()).?;
    try std.testing.expect(box.contains(.{ .x = -3, .y = -4 }));
    try std.testing.expect(box.contains(.{ .x = 5, .y = 7 }));
}

test "baseline and tangent label placement convert y-down frames to y-up" {
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    const metrics = Metrics{ .width = 20, .height = 10, .baseline = 7 };
    try picture.labelAtBaseline(0, metrics, .{ .x = 10, .y = 30 }, .{});
    const first = picture.commands.items[0].label;
    try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 }, first.transform.apply(.{ .x = 0, .y = 7 }));
    const box = (try picture.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 27 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 37 }, box.max);
    try picture.labelAlong(1, metrics, .{ .x = 50, .y = 60 }, .{ .x = 0, .y = 2 }, 3);
    const second = picture.commands.items[1].label;
    try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 60 }, second.transform.apply(.{ .x = 0, .y = 7 }));
    try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 80 }, second.transform.apply(.{ .x = 20, .y = 7 }));
}

test "label ink bounds share transforms clipping and diagnostic order with logical bounds" {
    const t = std.testing;
    const Resolver = struct {
        calls: usize = 0,
        fail: bool = false,
        pub fn resolveBounds(self: *@This(), reference: u32) anyerror!g.BBox {
            self.calls += 1;
            try t.expectEqual(@as(u32, 7), reference);
            if (self.fail) return error.MissingTestFrame;
            return .{ .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 4, .y = 8 } };
        }
    };
    var resolver: Resolver = .{};
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var clip = try rectangle(t.allocator, .zero, .{ .x = 10, .y = 10 });
    defer clip.deinit();
    try picture.beginScope(.translation(10, 20), clip);
    try picture.addLabel(7, .{ .width = 2, .height = 3, .baseline = 2 }, .translation(1, 1));
    try picture.endScope();
    try t.expectEqualDeep(g.BBox{ .min = .{ .x = 11, .y = 21 }, .max = .{ .x = 13, .y = 24 } }, (try picture.bounds()).?);
    try t.expectEqualDeep(g.BBox{ .min = .{ .x = 10, .y = 20 }, .max = .{ .x = 15, .y = 29 } }, (try picture.boundsWith(&resolver)).?);
    resolver.fail = true;
    try t.expectError(error.MissingTestFrame, picture.boundsWith(&resolver));
    picture.commands.items[0].push.transform.a = std.math.inf(f64);
    try t.expectError(error.NonFinite, picture.boundsWith(&resolver));
    try t.expectError(error.NonFinite, picture.bounds());
    try t.expectEqual(@as(usize, 2), resolver.calls);
}

test "baselines outside the frame preserve baseline and tangent label placement" {
    for ([_]f64{ -3, 12 }) |baseline| {
        var picture = DisplayList.init(std.testing.allocator);
        defer picture.deinit();
        const metrics = Metrics{ .width = 20, .height = 10, .baseline = baseline };
        try picture.labelAtBaseline(0, metrics, .{ .x = 10, .y = 30 }, .{});
        const first = picture.commands.items[0].label;
        try std.testing.expectEqual(baseline, first.metrics.baseline);
        try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 }, first.transform.apply(.{ .x = 0, .y = baseline }));
        const box = (try picture.bounds()).?;
        try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 + baseline - 10 }, box.min);
        try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 30 + baseline }, box.max);
        try picture.labelAlong(1, metrics, .{ .x = 50, .y = 60 }, .{ .x = 0, .y = 2 }, 3);
        const second = picture.commands.items[1].label;
        try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 60 }, second.transform.apply(.{ .x = 0, .y = baseline }));
        try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 80 }, second.transform.apply(.{ .x = 20, .y = baseline }));
    }
}

test "invalid styles metrics open clips and groups are rejected" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try std.testing.expectError(error.InvalidStyle, picture.addPath(path, .{}, .{}));
    try std.testing.expectError(error.InvalidColor, picture.fill(path, .{ .a = 2 }, .{}));
    try std.testing.expectError(error.InvalidPen, picture.draw(path, .{ .width = -1 }, .{}));
    try std.testing.expectError(error.InvalidPath, picture.beginScope(.{}, path));
    try std.testing.expectError(error.NonFinite, picture.fill(path, .black, .{ .a = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidMetrics, picture.addLabel(0, .{ .width = -1, .height = 1, .baseline = 2 }, .{}));
    try std.testing.expectError(error.InvalidMetrics, picture.addLabel(0, .{ .width = 1, .height = -1, .baseline = 0 }, .{}));
    inline for (.{ "width", "height", "baseline" }) |field| {
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
            var invalid = Metrics{ .width = 1, .height = 1, .baseline = 0 };
            @field(invalid, field) = value;
            try std.testing.expectError(error.NonFinite, picture.addLabel(0, invalid, .{}));
        }
    }
    try std.testing.expectError(error.UnbalancedGroups, picture.endScope());
    try std.testing.expectError(error.SelfAppend, picture.append(&picture, .{}));
    try picture.beginScope(.{}, null);
    try std.testing.expectError(error.UnbalancedGroups, picture.bounds());
    try picture.endScope();
}

test "picture nesting limits are checked before mutating groups or composition" {
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    for (0..max_scope_depth) |_| try picture.beginScope(.{}, null);
    const count = picture.commands.items.len;
    try std.testing.expectError(error.GroupNestingTooDeep, picture.beginScope(.{}, null));
    try std.testing.expectEqual(count, picture.commands.items.len);
    for (0..max_scope_depth) |_| try picture.endScope();
    try std.testing.expect((try picture.bounds()) == null);

    var child = DisplayList.init(std.testing.allocator);
    defer child.deinit();
    for (0..max_scope_depth - 1) |_| try child.beginScope(.{}, null);
    for (0..max_scope_depth - 1) |_| try child.endScope();
    var parent = DisplayList.init(std.testing.allocator);
    defer parent.deinit();
    try parent.append(&child, .{});
    try std.testing.expectEqual(max_scope_depth, parent.maximum_depth);
    try parent.beginScope(.{}, null);
    try std.testing.expectError(error.GroupNestingTooDeep, parent.append(&child, .{}));
    try parent.endScope();
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var path = try rectangle(allocator, .zero, .{ .x = 10, .y = 10 });
    defer path.deinit();
    var child = DisplayList.init(allocator);
    defer child.deinit();
    try child.beginScope(.{}, path);
    try child.filldraw(path, .{ .b = 1 }, .{}, .{});
    try child.labelAtBaseline(0, .{ .width = 2, .height = 3, .baseline = 2 }, .{ .x = 5, .y = 5 }, .{});
    try child.endScope();
    var parent = DisplayList.init(allocator);
    defer parent.deinit();
    try parent.append(&child, .{});
    _ = try parent.bounds();
}
test "all picture allocation failures release owned arrays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "borrowed style survives command array growth" {
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 30, .y = 40 });
    const dashes = [_]f64{ 1, 2 };
    const style: Style = .{ .fill = .{ .r = 0.25, .g = 0.5, .b = 0.75 }, .pen = .{ .width = 3, .dash = &dashes } };
    try picture.addPath(path, style, .{});
    while (picture.commands.items.len < picture.commands.capacity) try picture.addPath(path, style, .{});
    const borrowed = picture.commands.items[0].path.style;
    try picture.addPathView(&path, borrowed, .{});
    const stored = picture.commands.items[picture.commands.items.len - 1].path.style;
    try std.testing.expectEqualDeep(style, stored.*);
    try std.testing.expectEqualSlices(f64, &dashes, stored.pen.?.dash);
}

test "borrowed geometry remains separate until an explicit picture copy" {
    const a = std.testing.allocator;
    var owner = try Path.circle(a, .{ .x = 10, .y = 20 }, 3);
    defer owner.deinit();
    var view = DisplayList.init(a);
    defer view.deinit();
    try view.sources.append(a, owner.segments.items);
    const reference: PathRef = .{ .first = 0, .count = owner.segments.items.len, .source = 1 };
    try view.commands.append(a, .{ .path = .{ .path = reference, .style = &.{ .fill = .black }, .transform = .{} } });
    try std.testing.expectEqual(owner.segments.items.ptr, (try view.range(reference)).ptr);
    var copied = DisplayList.init(a);
    defer copied.deinit();
    try copied.append(&view, .{});
    const independent = try copied.range(copied.commands.items[1].path.path);
    try std.testing.expect(independent.ptr != owner.segments.items.ptr);
    try std.testing.expectEqualDeep(owner.segments.items, independent);
    try std.testing.expectEqualDeep(try view.bounds(), try copied.bounds());
    try std.testing.expectError(error.InvalidPath, view.range(.{ .source = 2, .first = 0, .count = 1 }));
}

test "append rejects borrowed subranges of its own allocation before mutation" {
    const a = std.testing.allocator;
    var path = try Path.circle(a, .zero, 5);
    defer path.deinit();
    var destination = DisplayList.init(a);
    defer destination.deinit();
    try destination.fill(path, .black, .{});
    var view = DisplayList.init(a);
    defer view.deinit();
    try view.sources.append(a, destination.storage.segments.items[1..]);
    try view.commands.append(a, .{ .path = .{
        .path = .{ .first = 0, .count = 1, .source = 1 },
        .style = &.{ .fill = .black },
        .transform = .{},
    } });
    try std.testing.expectError(error.SelfAppend, destination.append(&view, .{}));
    try std.testing.expectEqual(@as(usize, 1), destination.commands.items.len);
    try std.testing.expectEqualDeep(path.segments.items, destination.storage.segments.items);
}
