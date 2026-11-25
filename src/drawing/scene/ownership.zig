//! The storage as a unit: importing a picture's storage, the page budget for a new leaf, the owners reachable through cross-owner links, and the hand-off.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const Path = @import("../path/Path.zig");
const Allocator = std.mem.Allocator;
const Storage = @import("../Storage.zig");
const Scene = @import("../Scene.zig");
const snapshots = @import("snapshots.zig");
const testing = @import("testing.zig");
const Owners = Scene.Owners;
const Reference = Scene.Reference;
const none = Scene.none;
const Index = Scene.Index;
const TestIds = testing.TestIds;

/// Reserve one leaf node's arrays within a storage budget. Normal ArrayList
/// growth is capped after reserving every other array's minimum. The budget
/// includes existing style data; insertion can subsequently add more.
/// False leaves capacities unchanged. Failure may reserve capacity but
/// never inserts a node or changes geometry, styles, or graph links.
pub fn reserveNode(self: *Scene, path: ?*const Path, budget: usize) !bool {
    const solved_count = if (path) |p| p.knotRecords().len else 0;
    const growths = .{
        .{ &self.nodes, @as(usize, 1) },
        .{ &self.links, @as(usize, 1) },
        .{ &self.storage.segments, if (path) |p| p.segments.items.len else @as(usize, 0) },
        .{ &self.storage.knot_blocks, @as(usize, @intFromBool(solved_count != 0)) },
    };
    // Storage copies only live knot records during insertion.
    var bytes = self.allocatedBytes() +| solved_count *| @sizeOf(Path.KnotTable.Knot);
    inline for (growths) |growth| {
        const list = growth[0];
        const count = list.items.len +| growth[1];
        bytes +|= (count -| list.capacity) *| @sizeOf(@TypeOf(list.items[0]));
    }
    if (bytes > budget) return false;
    var spare = budget - bytes;
    inline for (growths) |growth| {
        const list = growth[0];
        const count = list.items.len +| growth[1];
        if (count > list.capacity) {
            const size = @sizeOf(@TypeOf(list.items[0]));
            const capacity = @min(@TypeOf(list.*).growCapacity(count), count + spare / size);
            spare -= (capacity - count) * size;
            try list.ensureTotalCapacityPrecise(self.storage.allocator, capacity);
        }
    }
    return true;
}

/// Storage moves as a unit: even a detached node may retain cross-owner
/// links. Follow all such links when transferring mutable graph ownership.
pub fn storageClosure(self: *const Scene, allocator: Allocator) !Owners {
    var owners: Owners = .empty;
    errdefer owners.deinit(allocator);
    try owners.put(allocator, self, {});
    var cursor: usize = 0;
    while (cursor < owners.count()) : (cursor += 1) {
        const scene = owners.keys()[cursor];
        for (scene.links.items) |link| {
            for ([_]Reference{ link.parent, link.next }) |reference| {
                if (reference.scene) |owner| try owners.put(allocator, owner, {});
            }
        }
        for (scene.containers.items) |children_| {
            for ([_]Reference{ children_.first, children_.last }) |reference| {
                if (reference.scene) |owner| try owners.put(allocator, owner, {});
            }
        }
    }
    return owners;
}

/// Consume a balanced picture without copying geometry or paints. A failed
/// import leaves the caller's picture untouched.
pub fn fromDisplayList(source: *DisplayList) !Scene {
    if (source.sources.items.len != 0) {
        var owned = try source.copy(source.storage.allocator);
        defer owned.deinit();
        const result = try fromDisplayList(&owned);
        source.deinit();
        source.* = .init(result.storage.allocator);
        return result;
    }
    if (source.scope_depth != 0) return error.UnbalancedGroups;
    if (source.commands.items.len >= none - 1) return error.TooManyObjects;
    var depth: usize = 0;
    var maximum: usize = 0;
    var count: usize = 0;
    var containers_count: usize = 0;
    var single = source.commands.items.len > 0 and source.commands.items[0] == .push;
    for (source.commands.items, 0..) |item, i| {
        if (item == .pop) {
            if (depth == 0) return error.UnbalancedGroups;
            depth -= 1;
            if (depth == 0 and i + 1 != source.commands.items.len) single = false;
        } else {
            count += 1;
            if (item == .push) {
                containers_count += 1;
                depth += 1;
                maximum = @max(maximum, depth);
            }
        }
    }
    if (depth != 0) return error.UnbalancedGroups;
    const wrap: usize = @intFromBool(!single and source.commands.items.len != 1);
    if (maximum + wrap > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    var result: Scene = .{ .storage = .initWithMeshes(source.storage.allocator, source.storage.styles.meshes) };
    errdefer result.deinit();
    try result.nodes.ensureTotalCapacityPrecise(result.storage.allocator, count + wrap);
    try result.links.ensureTotalCapacityPrecise(result.storage.allocator, count + wrap);
    try result.containers.ensureTotalCapacityPrecise(result.storage.allocator, containers_count + wrap);
    // Node conversion cannot fail. Geometry and styles move only after the
    // complete tree has been prepared; render end markers are not nodes.
    if (wrap != 0) {
        result.nodes.appendAssumeCapacity(.{ .picture = .{ .transform = .{}, .clip = null } });
        _ = result.commit(null, 0);
    }
    var parent: ?Index = if (wrap != 0) 0 else null;
    for (source.commands.items) |item| {
        if (item == .pop) {
            parent = if (result.object(parent.?).parent()) |node_| node_.index else null;
            continue;
        }
        const index: Index = @intCast(result.nodes.items.len);
        result.nodes.appendAssumeCapacity(switch (item) {
            .path => |value| .{ .path = value },
            .label => |value| .{ .label = value },
            .push => |value| .{ .picture = value },
            .pop => unreachable,
        });
        _ = result.commit(parent, index);
        if (item == .push) parent = index;
    }
    result.storage = source.storage;
    source.commands.deinit(result.storage.allocator);
    source.sources.deinit(result.storage.allocator);
    source.* = .init(result.storage.allocator);
    return result;
}

/// Move geometry and paints after all required snapshots are prepared.
/// The caller keeps this storage alive for every view that references it.
pub fn takeStorage(self: *Scene) Storage {
    self.nodes.deinit(self.storage.allocator);
    self.nodes = .empty;
    const result = self.storage;
    self.storage = .initWithMeshes(result.allocator, result.styles.meshes);
    self.links.deinit(result.allocator);
    self.links = .empty;
    self.containers.deinit(result.allocator);
    self.containers = .empty;
    return result;
}

test "import and handoff retain native labels and move original geometry" {
    const a = std.testing.allocator;
    var original = DisplayList.init(a);
    defer original.deinit();
    try original.beginScope(.translation(7, 8), null);
    try original.addLabel(9, .{ .width = 10, .height = 20, .baseline = 16 }, .{});
    try original.endScope();
    var scene = try fromDisplayList(&original);
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 2), scene.links.items.len);
    var selected = try snapshots.snapshot(&scene, a, 0, TestIds{ .scene = &scene });
    defer selected.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 0 }, selected.ids.items);
    var output = takeStorage(&scene);
    defer output.deinit();
    try std.testing.expectEqual(@as(u32, 9), selected.picture.commands.items[1].label.reference);
    try std.testing.expectEqual(@as(usize, 0), original.commands.items.len);
}

test "importing borrowed banks owns their geometry without adding group depth" {
    const a = std.testing.allocator;
    var path = try Path.circle(a, .zero, 5);
    defer path.deinit();
    var picture = DisplayList.init(a);
    defer picture.deinit();
    try picture.sources.append(a, .{ .segments = path.segments.items });
    for (0..DisplayList.max_scope_depth) |_| try picture.beginScope(.{}, null);
    try picture.commands.append(a, .{ .path = .{
        .path = .{ .first = 0, .count = path.segments.items.len, .source = 1 },
        .style = &.{ .fill = .black },
        .transform = .{},
    } });
    for (0..DisplayList.max_scope_depth) |_| try picture.endScope();
    var scene = try fromDisplayList(&picture);
    defer scene.deinit();
    try std.testing.expect(scene.storage.segments.items.ptr != path.segments.items.ptr);
    var view = try snapshots.snapshot(&scene, a, 0, null);
    defer view.deinit();
    try std.testing.expectEqual(DisplayList.max_scope_depth, view.picture.maximum_depth);
}
