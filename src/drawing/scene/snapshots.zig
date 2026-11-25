//! Selecting a subtree, with its ancestors' transforms, clips and placement holes, into a balanced command view.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Allocator = std.mem.Allocator;
const exclusion = @import("../exclusion.zig");
const Scene = @import("../Scene.zig");
const placement = @import("placement.zig");
const Index = Scene.Index;
const Snapshot = Scene.Snapshot;
const Object = Scene.Object;

/// Include ancestor transforms and clips, but never siblings. The borrowed
/// stream is shared by bounds, outlines, regions, copying and rendering.
pub fn snapshot(self: *const Scene, allocator: Allocator, index: Index, ids: anytype) !Snapshot {
    return snapshotWithBounds(self, allocator, index, ids, null);
}

pub fn snapshotWithBounds(self: *const Scene, allocator: Allocator, index: Index, ids: anytype, labels: anytype) !Snapshot {
    _ = try self.getNode(index);
    var result: Snapshot = .{ .picture = .init(allocator) };
    errdefer result.deinit();
    result.picture.storage.borrowBank(&self.storage);
    try result.owners.put(allocator, self, {});
    if (!try self.isVisible(index)) return result;
    var ancestors: [DisplayList.max_scope_depth]Object = undefined;
    var openings: [DisplayList.max_scope_depth]?usize = undefined;
    var count: usize = 0;
    var depth: usize = 0;
    var cursor = try self.parentObject(index);
    while (cursor) |node| {
        depth += 1 + @as(usize, @intFromBool(node.link().excluded != null));
        if (depth > ancestors.len) return error.GroupNestingTooDeep;
        ancestors[count] = node;
        count += 1;
        cursor = node.parent();
    }
    // Count the selected traversal before allocating its command stream.
    // This avoids repeated bulk copies and does not reserve unrelated nodes.
    const length = 2 * depth + try visit(self, null, self.object(index), ids, depth);
    try result.picture.commands.ensureTotalCapacityPrecise(allocator, length);
    var remaining = count;
    while (remaining != 0) {
        remaining -= 1;
        openings[remaining] = try beginExclusion(&result, ancestors[remaining]);
        try emit(self, &result, ancestors[remaining], ids);
    }
    _ = try visit(self, &result, self.object(index), ids, depth);
    for (ancestors[0..count], openings[0..count]) |ancestor, opening| {
        try end(&result);
        try endExclusion(&result, ancestor, opening);
    }
    try exclusion.resolve(&result.picture, result.ids.items, result.exclusions.items, &result.clip_segments, labels);
    result.exclusions.clearAndFree(allocator);
    return result;
}

fn beginExclusion(result: *Snapshot, node: Object) !?usize {
    if (node.link().excluded == null) return null;
    const start = result.picture.commands.items.len;
    try result.picture.beginScope(.{}, null);
    if (result.ids.items.len != 0) try result.ids.append(result.picture.storage.allocator, 0);
    return start;
}

fn endExclusion(result: *Snapshot, node: Object, opening: ?usize) !void {
    const start = opening orelse return;
    const segments = try node.parent().?.scene.storage.range(node.link().excluded.?);
    try result.exclusions.append(result.picture.storage.allocator, .{ .start = start, .stop = result.picture.commands.items.len, .hole = segments });
    try end(result);
}

fn emit(_: *const Scene, result: *Snapshot, object_: Object, ids: anytype) !void {
    const source = try result.owners.getOrPut(result.picture.storage.allocator, object_.scene);
    if (!source.found_existing and source.index != 0) try result.picture.sources.append(result.picture.storage.allocator, object_.scene.storage.bank());
    const value = result.picture.commands.addOneAssumeCapacity();
    value.* = switch (object_.scene.nodes.items[object_.index]) {
        .path => |item| .{ .path = item },
        .label => |item| .{ .label = item },
        .picture => |item| .{ .push = item },
    };
    const reference: ?*DisplayList.PathRef = switch (value.*) {
        .path => |*draw| &draw.path,
        .push => |*group_| if (group_.clip) |*clip| clip else null,
        else => null,
    };
    if (reference) |range| {
        std.debug.assert(range.source == 0);
        range.source = std.math.cast(u32, source.index) orelse return error.TooManyObjects;
    }
    const id = if (comptime @TypeOf(ids) != @TypeOf(null)) ids.identifier(object_) else 0;
    if (id != 0 or result.ids.items.len != 0) {
        const previous = result.ids.items.len;
        try result.ids.ensureTotalCapacityPrecise(result.picture.storage.allocator, result.picture.commands.capacity);
        result.ids.items.len = result.picture.commands.items.len;
        @memset(result.ids.items[previous..], 0);
        result.ids.items[result.ids.items.len - 1] = id;
    }
    if (value.* == .push) {
        result.picture.scope_depth += 1;
        result.picture.maximum_depth = @max(result.picture.maximum_depth, result.picture.scope_depth);
    }
}

/// A null output measures the same selection without materializing it.
fn visit(self: *const Scene, result: ?*Snapshot, node: Object, ids: anytype, depth: usize) anyerror!usize {
    if (!node.link().visible) return 0;
    const group_ = node.scene.nodes.items[node.index] == .picture;
    const masked: usize = @intFromBool(node.link().excluded != null);
    if (depth + masked + @intFromBool(group_) > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    const opening = if (result) |output| try beginExclusion(output, node) else null;
    if (result) |output| try emit(self, output, node, ids);
    var count: usize = 1 + 2 * masked;
    if (group_) {
        var children_ = try node.scene.children(node.index);
        while (children_.next()) |child| count += try visit(self, result, child, ids, depth + masked + 1);
        count += 1;
        if (result) |output| try end(output);
    }
    if (result) |output| try endExclusion(output, node, opening);
    return count;
}

fn end(result: *Snapshot) !void {
    try result.picture.endScope();
    if (result.ids.items.len != 0) try result.ids.append(result.picture.storage.allocator, 0);
}

test "a picture's opacity reaches its snapshot and its copy, and only a picture has one" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 10 });
    const group = try scene.addPicture(0, .translation(20, 30), null);
    const stroke = try scene.addPath(group, &path, &.{ .pen = .{} }, .{});
    try scene.setOpacity(group, 0.25);
    try std.testing.expectError(error.ExpectedPicture, scene.setOpacity(stroke, 0.5));
    try std.testing.expectError(error.InvalidStyle, scene.setOpacity(group, 2));
    var selected = try snapshot(&scene, a, 0, null);
    defer selected.deinit();
    // The root, the layer, its path and the two ends.
    try std.testing.expectEqual(@as(usize, 5), selected.picture.commands.items.len);
    try std.testing.expectEqual(@as(f64, 1), selected.picture.commands.items[0].push.opacity);
    try std.testing.expectEqual(@as(f64, 0.25), selected.picture.commands.items[1].push.opacity);
    var copied = try scene.copy(a, null, group);
    defer copied.deinit();
    try std.testing.expectEqual(@as(f64, 0.25), (try copied.getNode(0)).picture.opacity);
    try scene.setOpacity(group, 1);
    try std.testing.expectEqual(@as(f64, 1), (try scene.getNode(group)).picture.opacity);
}

test "snapshot selects each owner's knot table and its independent copy outlives both owners" {
    const t = std.testing;
    const a = t.allocator;
    var expected: [2]g.Point = undefined;
    var independent = copy: {
        var primary = try Scene.init(a);
        defer primary.deinit();
        var foreign = try Scene.init(a);
        defer foreign.deinit();
        var curve = try @import("../path/construct.zig").construct(a, &.{ .zero, .{ .x = 5, .y = 8 }, .{ .x = 9, .y = 0 } }, &.{ .smooth, .smooth }, .{});
        defer curve.deinit();
        const local = try primary.addPath(0, &curve, &.{ .fill = .black }, .{});
        try curve.transform(.{ .a = 0, .b = 1, .c = -1, .d = 0 });
        const placed = try foreign.addPath(null, &curve, &.{ .fill = .black }, .{});
        try placement.place(&primary, 0, foreign.object(placed), null);
        var snap = try snapshot(&primary, a, 0, null);
        defer snap.deinit();
        const paths = snap.picture.commands.items[1..3];
        try t.expectEqual(paths[0].path.path.knot_table, paths[1].path.path.knot_table);
        try t.expect(paths[0].path.path.source != paths[1].path.path.source);
        for (paths, [_]*const Scene{ &primary, &foreign }, [_]Index{ local, placed }, 0..) |cmd, owner, id, i| {
            const stored = try owner.storage.asGeometry().view(a, (try owner.getNode(id)).path.path);
            const viewed = try snap.picture.geometry().view(a, cmd.path.path);
            try t.expectEqual(stored.knotRecords().ptr, viewed.knotRecords().ptr);
            expected[i] = stored.knotRecords()[0].tangent;
        }
        try t.expect(!expected[0].eql(expected[1]));
        break :copy try snap.picture.copy(a);
    };
    defer independent.deinit();
    for (independent.commands.items[1..3], expected) |cmd, dir| {
        try t.expectEqual(0, cmd.path.path.source);
        const view = try independent.geometry().view(a, cmd.path.path);
        try t.expectEqual(dir, view.knotRecords()[0].tangent);
    }
}
