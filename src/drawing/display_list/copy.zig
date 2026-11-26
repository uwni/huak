//! Copying another picture's commands with their geometry and paints as one transaction, behind append and copy.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Storage = @import("../Storage.zig");
const MeshStore = Storage.MeshStore;
const PathRef = Storage.PathRef;
const Error = Storage.Error;
const DisplayList = @import("../DisplayList.zig");
const max_scope_depth = DisplayList.max_scope_depth;
const Command = DisplayList.Command;

pub fn copyCommands(self: *DisplayList, other: *const DisplayList, transform: ?g.Transform) Error!void {
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
        self.storage.truncateGeometry(offset);
        self.truncateCommands(previous_commands);
    }
    if (transform) |value| self.commands.appendAssumeCapacity(.{ .push = .{ .transform = value, .clip = null } });
    for (other.commands.items) |command| self.commands.appendAssumeCapacity(try copyCommand(self, other, command));
    if (transform != null) self.commands.appendAssumeCapacity(.pop);
    self.maximum_depth = @max(self.maximum_depth, self.scope_depth + other.maximum_depth + nesting);
}

/// Copy a validated command's geometry and paints into reserved storage.
/// The caller validates ranges and reserves their combined segment count
/// before copying; source and destination may share the segment allocation.
pub fn copyCommand(self: *DisplayList, other: *const DisplayList, command: Command) Error!Command {
    return switch (command) {
        .path => |item| .{ .path = try self.storage.copyPath(other.geometry(), item, .independent) },
        .push => |scope| .{ .push = self.storage.copyScope(other.geometry(), scope) },
        else => command,
    };
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

test "a layer keeps its opacity through composition, and opacity runs from 0 to 1" {
    var child = DisplayList.init(std.testing.allocator);
    defer child.deinit();
    try child.beginLayer(.translation(5, 7), null, 0.5);
    try child.endScope();
    try std.testing.expectEqual(@as(f64, 0.5), child.commands.items[0].push.opacity);
    var parent = DisplayList.init(std.testing.allocator);
    defer parent.deinit();
    try parent.beginScope(.{}, null);
    try parent.endScope();
    try std.testing.expectEqual(@as(f64, 1), parent.commands.items[0].push.opacity);
    // The group that places the child is no layer; the child's own is.
    try parent.append(&child, .translation(1, 2));
    try std.testing.expectEqual(@as(f64, 1), parent.commands.items[2].push.opacity);
    try std.testing.expectEqual(@as(f64, 0.5), parent.commands.items[3].push.opacity);
    var copied = try parent.copy(std.testing.allocator);
    defer copied.deinit();
    try std.testing.expectEqual(@as(f64, 0.5), copied.commands.items[3].push.opacity);
    for ([_]f64{ 1.5, -0.1, std.math.nan(f64) }) |opacity| {
        try std.testing.expectError(error.InvalidStyle, parent.beginLayer(.{}, null, opacity));
    }
    try std.testing.expectEqual(@as(usize, 6), parent.commands.items.len);
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

test "borrowed geometry remains separate until an explicit picture copy" {
    const a = std.testing.allocator;
    var owner = try Path.circle(a, .{ .x = 10, .y = 20 }, 3);
    defer owner.deinit();
    var view = DisplayList.init(a);
    defer view.deinit();
    try view.sources.append(a, .{ .segments = owner.segments.items });
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
    try view.sources.append(a, .{ .segments = destination.storage.segments.items[1..] });
    try view.commands.append(a, .{ .path = .{
        .path = .{ .first = 0, .count = 1, .source = 1 },
        .style = &.{ .fill = .black },
        .transform = .{},
    } });
    try std.testing.expectError(error.SelfAppend, destination.append(&view, .{}));
    try std.testing.expectEqual(@as(usize, 1), destination.commands.items.len);
    try std.testing.expectEqualDeep(path.segments.items, destination.storage.segments.items);
}

test "pictures attached to one mesh store share patch arrays when appended" {
    const a = std.testing.allocator;
    var store = MeshStore.init(a);
    defer store.deinit();
    var boundary = try Path.circle(a, .zero, 5);
    defer boundary.deinit();
    var points: [16]g.Point = undefined;
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        points[i * 4 + j] = .{ .x = -5 + 10 * @as(f64, @floatFromInt(i)) / 3, .y = -5 + 10 * @as(f64, @floatFromInt(j)) / 3 };
        values[i * 4 + j] = @as(f64, @floatFromInt(j)) / 3;
    };
    var source = DisplayList.initWithMeshes(a, &store);
    defer source.deinit();
    try source.addPath(boundary, .{ .fill = .{ .gradient = &.{ .patches = .{
        .points = &.{points},
        .values = &.{values},
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .b = 1 } } },
        .tolerance = 0.01,
    } } } }, .{});
    var shared = DisplayList.initWithMeshes(a, &store);
    defer shared.deinit();
    try shared.append(&source, .{});
    var separate = DisplayList.init(a);
    defer separate.deinit();
    try separate.append(&source, .{});
    const arraysOf = struct {
        // Appending wraps the copied commands in a group.
        fn first(picture: *const DisplayList) ![*]const [16]g.Point {
            for (picture.commands.items) |command| if (command == .path) return command.path.style.gradientFor(.fill).?.patches.points.ptr;
            return error.MissingPath;
        }
    }.first;
    const original = try arraysOf(&source);
    try std.testing.expectEqual(original, try arraysOf(&shared));
    var cloned = try source.copy(a);
    defer cloned.deinit();
    try std.testing.expectEqual(original, try arraysOf(&cloned));
    try std.testing.expect(try arraysOf(&separate) != original);
    try std.testing.expectEqual(@as(usize, 1), store.count());
}
