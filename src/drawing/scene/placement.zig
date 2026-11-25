//! Where an instance sits: its parent, its place in the paint order, and the hole cut from its placement.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Storage = @import("../Storage.zig");
const regions = @import("../region/root.zig");
const exclusion = @import("../exclusion.zig");
const Scene = @import("../Scene.zig");
const Index = Scene.Index;
const Object = Scene.Object;
const composeTransform = Scene.composeTransform;
const nodeTransform = Scene.nodeTransform;
const attach = Scene.attach;
const Reference = Scene.Reference;

/// Exclude a region from selected direct child placements. Prepare every
/// union before committing any links; identical masks share geometry.
pub fn exclude(self: *Scene, parent: Index, targets: []const Object, hole: Path) !void {
    _ = try self.settings(parent);
    for (targets) |target| {
        const owner = (try target.scene.parentObject(target.index)) orelse return error.DifferentParents;
        if (!owner.eql(self.object(parent))) return error.DifferentParents;
    }
    if (targets.len == 0 or hole.segments.items.len == 0) return;
    try Storage.validateScope(.{}, &hole);
    const depth = self.ancestorDepth(parent);
    for (targets) |target| {
        if (target.link().excluded == null and depth + 1 + (try target.scene.subtreeSize(target.index, 0)).depth > DisplayList.max_scope_depth)
            return error.GroupNestingTooDeep;
    }
    const allocator = self.storage.allocator;
    var replacements: std.AutoHashMapUnmanaged(?DisplayList.PathRef, DisplayList.PathRef) = .empty;
    defer replacements.deinit(allocator);
    const previous_len = self.storage.segments.items.len;
    errdefer self.storage.segments.shrinkRetainingCapacity(previous_len);
    for (targets) |target| {
        const previous = target.link().excluded;
        const entry = try replacements.getOrPut(allocator, previous);
        if (entry.found_existing) continue;
        const segments = if (previous) |ref| try self.storage.range(ref) else &.{};
        var combined = try regions.combine(allocator, exclusion.borrowed(allocator, segments), hole, .unite, .{});
        defer combined.deinit();
        entry.value_ptr.* = (try self.storage.scope(.{}, &combined)).clip.?;
    }
    // Duplicate target handles never apply the same stroke twice.
    for (targets) |target| {
        if (replacements.get(target.link().excluded)) |ref| target.link().excluded = if (ref.count == 0) null else ref;
    }
}

/// Attach the same object at the end of a group's paint order. Repeating
/// placement in its current parent leaves order unchanged. Reparenting
/// preserves local transforms; callers explicitly convert coordinates if
/// world-space placement must remain unchanged. An optional transform and
/// the parent relationship commit together, after all validation succeeds.
pub fn place(self: *Scene, parent: Index, object_: Object, transform: ?g.Transform) !void {
    // Preserve transform diagnostics before placement diagnostics, without
    // mutating the command or keeping a rollback copy of its payload.
    const mapped = if (transform) |value|
        try composeTransform(nodeTransform(@constCast(try object_.scene.getNode(object_.index))).*, value)
    else
        null;
    if ((try self.getNode(parent)).* != .picture) return error.ExpectedPicture;
    _ = try object_.scene.getNode(object_.index);
    if (object_.scene.contains(object_.index, self.object(parent))) return error.ObjectCycle;
    const reparent = if (object_.parent()) |current| !current.eql(self.object(parent)) else true;
    if (reparent) {
        const size = try object_.scene.subtreeSize(object_.index, 0);
        if (self.ancestorDepth(parent) + size.depth > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    }
    if (mapped) |value| nodeTransform(&object_.scene.nodes.items[object_.index]).* = value;
    if (reparent) {
        unlink(object_.scene, object_.index);
        attach(self.object(parent), object_);
    }
}

/// Remove only the parent relationship. The object and all of its children
/// remain usable through their existing handles.
pub fn remove(self: *Scene, index: Index) !void {
    _ = try self.getNode(index);
    unlink(self, index);
}

/// Move within the same parent's paint order. This cannot create cycles or
/// silently change the coordinate system of the moved instance.
pub fn before(self: *Scene, index: Index, sibling: Object) !void {
    _ = try self.getNode(index);
    _ = try sibling.scene.getNode(sibling.index);
    const item = self.object(index);
    const parent = item.parent() orelse return error.NoParent;
    if (!(sibling.parent() orelse return error.DifferentParents).eql(parent)) return error.DifferentParents;
    if (item.eql(sibling)) return;
    const mask = item.link().excluded;
    unlink(self, index);
    item.link().excluded = mask;
    const previous = predecessor(parent, sibling);
    item.link().parent = Reference.to(self, parent);
    item.link().next = Reference.to(self, sibling);
    if (previous) |node| node.link().next = Reference.to(node.scene, item) else parent.container().first = Reference.to(parent.scene, item);
}

/// Put the object in a new picture that takes its place: its position in the
/// parent's paint order and its placement hole. The picture has no transform
/// or clip, so nothing moves. Returns the picture.
pub fn enclose(self: *Scene, index: Index) !Index {
    _ = try self.getNode(index);
    const item = self.object(index);
    const parent = item.parent() orelse return error.NoParent;
    const hole = item.link().excluded;
    // The object goes one level deeper; its hole moves to the picture.
    const depth = parent.scene.ancestorDepth(parent.index) + @as(usize, @intFromBool(hole != null)) + 1 + (try self.subtreeSize(index, 0)).depth;
    if (depth > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    const box = self.object(try self.addPicture(null, .{}, null));
    const previous = predecessor(parent, item);
    box.link().parent = Reference.to(self, parent);
    box.link().next = item.link().next;
    box.link().excluded = hole;
    if (previous) |node| node.link().next = Reference.to(node.scene, box) else parent.container().first = Reference.to(parent.scene, box);
    if (parent.container().last.resolve(parent.scene).?.eql(item)) parent.container().last = Reference.to(parent.scene, box);
    item.link().next = .{};
    item.link().excluded = null;
    attach(box, item);
    return box.index;
}

/// The child just before `item` in `parent`'s paint order, if any.
fn predecessor(parent: Object, item: Object) ?Object {
    var previous: ?Object = null;
    var cursor = parent.container().first.resolve(parent.scene);
    while (cursor) |current| : (cursor = current.link().next.resolve(current.scene)) {
        if (current.eql(item)) break;
        previous = current;
    }
    return previous;
}

fn unlink(self: *Scene, index: Index) void {
    const item = self.object(index);
    const parent = item.parent() orelse return;
    const previous = predecessor(parent, item);
    const next = item.link().next.resolve(self);
    if (previous) |node| node.link().next = if (next) |value| Reference.to(node.scene, value) else .{} else parent.container().first = if (next) |value| Reference.to(parent.scene, value) else .{};
    if (parent.container().last.resolve(parent.scene).?.eql(item)) parent.container().last = if (previous) |node| Reference.to(parent.scene, node) else .{};
    item.link().parent = .{};
    item.link().next = .{};
    item.link().excluded = null;
}
