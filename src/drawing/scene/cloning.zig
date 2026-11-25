//! Copying a subtree's nodes, geometry and paints into this storage.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Allocator = std.mem.Allocator;
const Scene = @import("../Scene.zig");
const snapshots = @import("snapshots.zig");
const Index = Scene.Index;
const none = Scene.none;
const nodeTransform = Scene.nodeTransform;
const composeTransform = Scene.composeTransform;

/// Clone a local subtree into a group, or leave the new object detached.
/// Geometry is copied once, including
/// when both objects live in this scene. Source identities never escape.
pub fn clone(self: *Scene, parent: ?Index, source: *const Scene, index: Index, transform_: g.Transform) !Index {
    _ = try self.reserve(parent);
    if (!transform_.isFinite()) return error.NonFinite;
    _ = try source.getNode(index);
    const size = try source.subtreeSize(index, 0);
    if (self.ancestorDepth(parent) + size.depth > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    if (size.nodes >= none - self.links.items.len) return error.TooManyObjects;
    try self.links.ensureUnusedCapacity(self.storage.allocator, size.nodes);
    try self.containers.ensureUnusedCapacity(self.storage.allocator, size.groups);
    try self.nodes.ensureUnusedCapacity(self.storage.allocator, size.nodes);
    const old_geometry = self.storage.segments.items.len;
    try self.storage.segments.ensureUnusedCapacity(self.storage.allocator, size.segments);
    const old_count = self.links.items.len;
    const old_groups = self.containers.items.len;
    const old_parent = if (parent) |group_| self.object(group_).container().* else null;
    errdefer {
        for (self.nodes.items[old_count..]) |node_| if (node_ == .path) self.storage.styles.release(node_.path.style);
        self.nodes.items.len = old_count;
        self.storage.truncateGeometry(old_geometry);
        self.links.items.len = old_count;
        self.containers.items.len = old_groups;
        if (old_parent) |link| {
            self.object(parent.?).container().* = link;
            if (link.last.resolve(self)) |last| last.link().next = .{};
        }
    }
    return cloneInto(self, parent, source, index, old_count, if (std.meta.eql(transform_, g.Transform{})) null else transform_);
}

fn cloneInto(self: *Scene, parent: ?Index, source: *const Scene, index: Index, limit: usize, extra: ?g.Transform) anyerror!Index {
    const node: Index = @intCast(self.links.items.len);
    var item = source.nodes.items[index];
    if (extra) |t| {
        const transform = nodeTransform(&item);
        transform.* = try composeTransform(transform.*, t);
    }
    const geometry = source.storage.asGeometry();
    self.nodes.appendAssumeCapacity(switch (item) {
        .path => |value| .{ .path = try self.storage.copyPath(geometry, value, if (self == source) .same_storage else .independent) },
        .label => item,
        .picture => |value| .{ .picture = self.storage.copyScope(geometry, value) },
    });
    _ = self.commit(parent, node);
    self.links.items[node].visible = source.links.items[index].visible;
    if (item == .picture) (try self.settings(node)).* = (try source.settings(index)).*;
    // Appending into this same subtree can change its child links. Only
    // visit nodes that existed before copying; newly appended nodes stop
    // the sibling chain, including when the destination is a descendant.
    var children_ = try source.children(index);
    while (children_.next()) |child| {
        if (child.scene == self and child.index >= limit) break;
        const cloned = try cloneInto(self, node, child.scene, child.index, limit, null);
        if (child.link().excluded) |ref| {
            self.links.items[cloned].excluded = self.storage.copyRange(source.storage.asGeometry(), ref);
        }
    }
    return node;
}

fn cloneExercise(allocator: Allocator) !void {
    var scene = try Scene.init(allocator);
    defer scene.deinit();
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 10 });
    try path.close();
    const group = try scene.addPicture(0, .translation(20, 30), &path);
    const item = try scene.addPath(group, &path, &.{ .pen = .{ .dash = &.{ 2, 3 } } }, .{});
    const label_object = try scene.label(group, 7, .{ .width = 10, .height = 12, .baseline = 9 }, .zero, .{});
    try scene.setVisible(label_object, false);
    const source_segments = scene.storage.segments.items.len;
    const leaf_copy = try clone(&scene, 0, &scene, item, .translation(1, 2));
    try std.testing.expect((try scene.getNode(leaf_copy)).* == .path);
    try std.testing.expectEqual(@as(f64, 1), (try scene.getNode(leaf_copy)).path.transform.e);
    try std.testing.expectEqual(source_segments + path.segments.items.len, scene.storage.segments.items.len);
    const group_copy = try clone(&scene, 0, &scene, group, .{});
    var children_ = try scene.children(group_copy);
    const copied_path = children_.next().?.index;
    const copied_label = children_.next().?.index;
    try std.testing.expectEqualSlices(f64, &.{ 2, 3 }, (try scene.getNode(copied_path)).path.style.pen.?.dash);
    try std.testing.expectEqual(@as(u32, 7), (try scene.getNode(copied_label)).label.reference);
    try std.testing.expect(!try scene.isVisible(copied_label));
    try scene.setVisible(copied_label, true);
    try std.testing.expect(!try scene.isVisible(label_object));
    try scene.setStyle(copied_path, &.{ .fill = .black });
    try std.testing.expect((try scene.getNode(item)).path.style.pen != null);
    const destination = try scene.addPicture(group, .{}, null);
    const previous_nodes = scene.links.items.len;
    const previous_segments = scene.storage.segments.items.len;
    const nested = clone(&scene, destination, &scene, group, .{}) catch |err| {
        try std.testing.expectEqual(previous_nodes, scene.links.items.len);
        try std.testing.expectEqual(previous_nodes, scene.nodes.items.len);
        try std.testing.expectEqual(previous_segments, scene.storage.segments.items.len);
        try std.testing.expectEqual(none, scene.object(destination).container().first.index);
        try std.testing.expectEqual(none, scene.object(destination).container().last.index);
        return err;
    };
    // A copy into a descendant must contain the original four nodes exactly
    // once, including the destination as it was before the insertion.
    try std.testing.expectEqual(previous_nodes + 4, scene.links.items.len);
    var nested_children = try scene.children(nested);
    _ = nested_children.next().?.index;
    _ = nested_children.next().?.index;
    const empty = nested_children.next().?.index;
    try std.testing.expectEqual(none, scene.object(empty).container().first.index);
    const before_root_copy = scene.links.items.len;
    const root_copy = try clone(&scene, 0, &scene, 0, .{});
    try std.testing.expectEqual(before_root_copy * 2, scene.links.items.len);
    try std.testing.expectEqual(@as(Index, @intCast(before_root_copy)), root_copy);
    var selected = try snapshots.snapshot(&scene, allocator, copied_path, null);
    defer selected.deinit();
    try std.testing.expectEqual(@as(f64, 20), (try selected.picture.bounds()).?.min.x);
    try std.testing.expectError(error.InvalidObject, scene.getNode(none));
}

test "subtree cloning copies only selected geometry and owns paint and visibility across OOM" {
    try cloneExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), cloneExercise, .{});
}

test "clones share only solver records already owned by the destination scene" {
    const t = std.testing;
    const a = t.allocator;
    var path = try @import("../path/construct.zig").construct(a, &.{ .zero, .{ .x = 10, .y = 8 }, .{ .x = 20, .y = 0 } }, &.{ .smooth, .smooth }, .{});
    defer path.deinit();
    var scene = try Scene.init(a);
    defer scene.deinit();
    {
        var foreign = try Scene.init(a);
        defer foreign.deinit();
        const external = try foreign.addPath(null, &path, &.{ .fill = .black }, .{});
        const foreign_solved = (try foreign.storage.asGeometry().view(a, (try foreign.getNode(external)).path.path)).knotRecords();
        const local = try clone(&scene, 0, &foreign, external, .{});
        const local_solved = (try scene.storage.asGeometry().view(a, (try scene.getNode(local)).path.path)).knotRecords();
        try t.expectEqualDeep(foreign_solved, local_solved);
        try t.expect(local_solved.ptr != foreign_solved.ptr);
    }
    const original = (try scene.getNode(1)).path;
    for (0..32) |_| {
        const id = try clone(&scene, 0, &scene, 1, .translation(5, 0));
        const cloned = (try scene.getNode(id)).path;
        try t.expectEqual(original.path.knot_table, cloned.path.knot_table);
        try t.expect(cloned.path.first != original.path.first);
    }
    try t.expectEqual(@as(usize, 1), scene.storage.knot_blocks.items.len);
    try t.expectEqual(path.knotRecords().len * @sizeOf(Path.KnotTable.Knot), scene.storage.knot_bytes);
}
