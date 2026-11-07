//! Retained drawing objects. Identity and storage are independent of parentage:
//! a detached object remains live, and placement never copies its geometry.
//! Explicit cloning owns new geometry and identities.
const std = @import("std");
const DisplayList = @import("DisplayList.zig");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");
const Allocator = std.mem.Allocator;

const Storage = @import("Storage.zig");
const regions = @import("region/root.zig");
const exclusion = @import("exclusion.zig");
/// Retained drawing objects have no render-stream enter/leave markers.
pub const Node = union(enum) { path: Storage.PathCommand, label: Storage.Label, picture: Storage.Scope };
pub const Index = u32;
const none: Index = std.math.maxInt(Index);
pub const Object = struct {
    scene: *Scene,
    index: Index,

    pub fn eql(self: Object, other: Object) bool {
        return self.scene == other.scene and self.index == other.index;
    }
    fn link(self: Object) *Link {
        return &self.scene.links.items[self.index];
    }
    fn parent(self: Object) ?Object {
        return self.link().parent.resolve(self.scene);
    }
    fn container(self: Object) *Container {
        return &self.scene.containers.items[self.link().children];
    }
};

/// Local links are relative, so a detached storage owner may move before it
/// participates in a graph. Cross-owner links require stable Scene addresses.
const Reference = struct {
    scene: ?*Scene = null,
    index: Index = none,

    fn resolve(self: Reference, local: *const Scene) ?Object {
        if (self.index == none) return null;
        return .{ .scene = self.scene orelse @constCast(local), .index = self.index };
    }
    fn to(local: *const Scene, item: Object) Reference {
        return .{ .scene = if (item.scene == local) null else item.scene, .index = item.index };
    }
};
const Link = struct {
    parent: Reference = .{},
    next: Reference = .{},
    // Holes belong to the placement, in its parent's local coordinates.
    excluded: ?DisplayList.PathRef = null,
    children: Index = none,
    visible: bool = true,
};
/// Export properties belong to each composite, independently of storage ownership.
pub const Settings = struct {
    size: ?g.Point = null,
    duration: ?f64 = null,
    repeat: bool = true,
};

const Container = struct {
    settings: Settings = .{},
    first: Reference = .{},
    last: Reference = .{},
};

/// A balanced command view. Commands and IDs belong to this value; geometry
/// and paints borrow every Scene listed in owners. No mutation of those
/// storage owners may overlap the view's use.
pub const Snapshot = struct {
    picture: DisplayList,
    ids: std.ArrayList(u64) = .empty,
    owners: Scene.Owners = .empty,
    exclusions: std.ArrayList(exclusion.Scope) = .empty,
    clip_segments: std.ArrayList(Path.Segment) = .empty,

    pub fn deinit(self: *Snapshot) void {
        self.exclusions.deinit(self.picture.storage.allocator);
        self.clip_segments.deinit(self.picture.storage.allocator);
        self.owners.deinit(self.picture.storage.allocator);
        self.picture.sources.deinit(self.picture.storage.allocator);
        self.picture.commands.deinit(self.picture.storage.allocator);
        self.ids.deinit(self.picture.storage.allocator);
        self.* = undefined;
    }
};

const Scene = @This();

storage: Storage,
nodes: std.ArrayList(Node) = .empty,
links: std.ArrayList(Link) = .empty,
containers: std.ArrayList(Container) = .empty,

/// Identity registry only; entries do not grant mutation or transfer rights.
pub const Owners = std.AutoArrayHashMapUnmanaged(*const Scene, void);

pub fn allocatedBytes(self: *const Scene) usize {
    return self.nodes.capacity * @sizeOf(Node) +
        self.storage.segments.capacity * @sizeOf(@import("path/Path.zig").Segment) +
        self.links.capacity * @sizeOf(Link) + self.containers.capacity * @sizeOf(Container) +
        self.storage.styles.allocatedBytes() + self.storage.knotBytes();
}

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

pub fn init(allocator: Allocator) !Scene {
    var result: Scene = .{ .storage = .init(allocator) };
    errdefer result.deinit();
    _ = try result.addPicture(null, .{}, null);
    return result;
}

pub fn deinit(self: *Scene) void {
    self.containers.deinit(self.storage.allocator);
    self.links.deinit(self.storage.allocator);
    self.nodes.deinit(self.storage.allocator);
    self.storage.deinit();
    self.* = undefined;
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
    var result: Scene = .{ .storage = .init(source.storage.allocator) };
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

pub fn getNode(self: *const Scene, index: Index) !*const Node {
    if (index >= self.links.items.len) return error.InvalidObject;
    return &self.nodes.items[index];
}

pub fn object(self: *const Scene, index: Index) Object {
    return .{ .scene = @constCast(self), .index = index };
}

fn reserve(self: *Scene, parent: ?Index) !Index {
    if (parent) |index| if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    if (self.links.items.len >= none) return error.TooManyObjects;
    try self.links.ensureUnusedCapacity(self.storage.allocator, 1);
    return @intCast(self.links.items.len);
}

fn commit(self: *Scene, parent: ?Index, index: Index) Index {
    std.debug.assert(self.nodes.items.len == self.links.items.len + 1);
    self.links.appendAssumeCapacity(.{});
    if (self.nodes.items[index] == .picture) {
        self.links.items[index].children = @intCast(self.containers.items.len);
        self.containers.appendAssumeCapacity(.{});
    }
    if (parent) |group_| attach(self.object(group_), self.object(index));
    return index;
}

pub fn addPath(self: *Scene, parent: ?Index, path: *const Path, style: *const DisplayList.Style, transform: g.Transform) !Index {
    const index = try self.reserve(parent);
    try Storage.validateDrawing(path, style, transform);
    try self.nodes.ensureUnusedCapacity(self.storage.allocator, 1);
    self.nodes.appendAssumeCapacity(.{ .path = try self.storage.path(path, style, transform) });
    return self.commit(parent, index);
}

pub fn label(self: *Scene, parent: ?Index, reference: u32, metrics: DisplayList.Metrics, at: g.Point, transform: g.Transform) !Index {
    const index = try self.reserve(parent);
    const value = try Storage.baseline(reference, metrics, at, transform);
    try self.nodes.append(self.storage.allocator, .{ .label = value });
    return self.commit(parent, index);
}

pub fn addPicture(self: *Scene, parent: ?Index, transform: g.Transform, clip: ?*const Path) !Index {
    const index = try self.reserve(parent);
    if (self.ancestorDepth(parent) >= DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
    try Storage.validateScope(transform, clip);
    try self.containers.ensureUnusedCapacity(self.storage.allocator, 1);
    try self.nodes.ensureUnusedCapacity(self.storage.allocator, 1);
    self.nodes.appendAssumeCapacity(.{ .picture = try self.storage.scope(transform, clip) });
    return self.commit(parent, index);
}

pub fn copy(self: *const Scene, allocator: Allocator, index: Index) !Scene {
    var result: Scene = .{ .storage = .init(allocator) };
    errdefer result.deinit();
    _ = try result.clone(null, self, index, .{});
    return result;
}

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
    return self.cloneInto(parent, source, index, old_count, if (std.meta.eql(transform_, g.Transform{})) null else transform_);
}

const SubtreeSize = struct { nodes: usize = 1, groups: usize = 0, segments: usize = 0, depth: usize = 0 };

fn subtreeSize(self: *const Scene, index: Index, depth: usize) anyerror!SubtreeSize {
    const item = self.nodes.items[index];
    var size: SubtreeSize = .{};
    const reference: ?DisplayList.PathRef = switch (item) {
        .path => |draw| draw.path,
        .picture => |group_| group_.clip,
        else => null,
    };
    if (reference) |ref| size.segments = (try self.storage.range(ref)).len;
    if (item == .picture) {
        if (depth >= DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
        size.depth = 1;
        size.groups = 1;
        var children_ = try self.children(index);
        while (children_.next()) |child| {
            const masked: usize = @intFromBool(child.link().excluded != null);
            const nested = try child.scene.subtreeSize(child.index, depth + 1 + masked);
            size.nodes += nested.nodes;
            size.groups += nested.groups;
            size.segments = try std.math.add(usize, size.segments, nested.segments);
            if (child.link().excluded) |ref| size.segments = try std.math.add(usize, size.segments, ref.count);
            size.depth = @max(size.depth, 1 + masked + nested.depth);
        }
    }
    return size;
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
        const cloned = try self.cloneInto(node, child.scene, child.index, limit, null);
        if (child.link().excluded) |ref| {
            self.links.items[cloned].excluded = self.storage.copyRange(source.storage.asGeometry(), ref);
        }
    }
    return node;
}

pub fn contains(self: *const Scene, ancestor: Index, object_: Object) bool {
    if (ancestor >= self.links.items.len or object_.index >= object_.scene.links.items.len) return false;
    var cursor: ?Object = object_;
    while (cursor) |node| : (cursor = node.parent()) if (self.object(ancestor).eql(node)) return true;
    return false;
}

pub fn parentObject(self: *const Scene, index: Index) !?Object {
    _ = try self.getNode(index);
    return self.object(index).parent();
}

pub const Children = struct {
    cursor: ?Object,
    pub fn next(self: *Children) ?Object {
        const object_ = self.cursor orelse return null;
        self.cursor = object_.link().next.resolve(object_.scene);
        return object_;
    }
};

pub fn settings(self: *const Scene, index: Index) !*Settings {
    if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    return &self.object(index).container().settings;
}

pub fn children(self: *const Scene, index: Index) !Children {
    _ = try self.getNode(index);
    return .{ .cursor = if (self.links.items[index].children == none) null else self.object(index).container().first.resolve(self) };
}

pub fn setVisible(self: *Scene, index: Index, visible: bool) !void {
    _ = try self.getNode(index);
    self.links.items[index].visible = visible;
}

pub fn isVisible(self: *const Scene, index: Index) !bool {
    _ = try self.getNode(index);
    var cursor: ?Object = self.object(index);
    while (cursor) |node| : (cursor = node.parent()) if (!node.link().visible) return false;
    return true;
}

pub fn setClip(self: *Scene, index: Index, clip: ?*const Path) !void {
    if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    try Storage.validateScope(.{}, clip);
    const scope = try self.storage.scope(.{}, clip);
    self.nodes.items[index].picture.clip = scope.clip;
}

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

pub fn setStyle(self: *Scene, index: Index, style: *const DisplayList.Style) !void {
    if ((try self.getNode(index)).* != .path) return error.ExpectedPathObject;
    try DisplayList.validateStyle(style);
    const target = &self.nodes.items[index].path.style;
    target.* = try self.storage.styles.replace(target.*, style);
}

/// Mutate only this instance's local transform. Parent transforms continue
/// to apply to its descendants; source paths and other instances stay intact.
pub fn applyTransform(self: *Scene, index: Index, value: g.Transform) !void {
    const current = nodeTransform(@constCast(try self.getNode(index)));
    current.* = try composeTransform(current.*, value);
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
        object_.scene.unlink(object_.index);
        attach(self.object(parent), object_);
    }
}

/// Remove only the parent relationship. The object and all of its children
/// remain usable through their existing handles.
pub fn remove(self: *Scene, index: Index) !void {
    _ = try self.getNode(index);
    self.unlink(index);
}

fn ancestorDepth(self: *const Scene, parent: ?Index) usize {
    var cursor: ?Object = if (parent) |index| self.object(index) else null;
    var depth: usize = 0;
    while (cursor) |node| : (cursor = node.parent()) depth += 1 + @as(usize, @intFromBool(node.link().excluded != null));
    return depth;
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
    self.unlink(index);
    item.link().excluded = mask;
    var previous: ?Object = null;
    var cursor = parent.container().first.resolve(parent.scene);
    while (cursor) |current| {
        if (current.eql(sibling)) break;
        previous = current;
        cursor = current.link().next.resolve(current.scene);
    }
    item.link().parent = Reference.to(self, parent);
    item.link().next = Reference.to(self, sibling);
    if (previous) |node| node.link().next = Reference.to(node.scene, item) else parent.container().first = Reference.to(parent.scene, item);
}

fn unlink(self: *Scene, index: Index) void {
    const item = self.object(index);
    const parent = item.parent() orelse return;
    var previous: ?Object = null;
    var cursor = parent.container().first.resolve(parent.scene);
    while (cursor) |current| {
        if (current.eql(item)) break;
        previous = current;
        cursor = current.link().next.resolve(current.scene);
    }
    const next = item.link().next.resolve(self);
    if (previous) |node| node.link().next = if (next) |value| Reference.to(node.scene, value) else .{} else parent.container().first = if (next) |value| Reference.to(parent.scene, value) else .{};
    if (parent.container().last.resolve(parent.scene).?.eql(item)) parent.container().last = if (previous) |node| Reference.to(parent.scene, node) else .{};
    item.link().parent = .{};
    item.link().next = .{};
    item.link().excluded = null;
}

/// Include ancestor transforms and clips, but never siblings. The borrowed
/// stream is shared by bounds, outlines, regions, copying and rendering.
pub fn snapshot(self: *const Scene, allocator: Allocator, index: Index, ids: anytype) !Snapshot {
    return self.snapshotWithBounds(allocator, index, ids, null);
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
    const length = 2 * depth + try self.visit(null, self.object(index), ids, depth);
    try result.picture.commands.ensureTotalCapacityPrecise(allocator, length);
    var remaining = count;
    while (remaining != 0) {
        remaining -= 1;
        openings[remaining] = try beginExclusion(&result, ancestors[remaining]);
        try self.emit(&result, ancestors[remaining], ids);
    }
    _ = try self.visit(&result, self.object(index), ids, depth);
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
    if (result) |output| try self.emit(output, node, ids);
    var count: usize = 1 + 2 * masked;
    if (group_) {
        var children_ = try node.scene.children(node.index);
        while (children_.next()) |child| count += try self.visit(result, child, ids, depth + masked + 1);
        count += 1;
        if (result) |output| try end(output);
    }
    if (result) |output| try endExclusion(output, node, opening);
    return count;
}

/// Move geometry and paints after all required snapshots are prepared.
/// The caller keeps this storage alive for every view that references it.
pub fn takeStorage(self: *Scene) Storage {
    self.nodes.deinit(self.storage.allocator);
    self.nodes = .empty;
    const result = self.storage;
    self.storage = .init(result.allocator);
    self.links.deinit(result.allocator);
    self.links = .empty;
    self.containers.deinit(result.allocator);
    self.containers = .empty;
    return result;
}

fn nodeTransform(command: *Node) *g.Transform {
    return switch (command.*) {
        .path => |*draw| &draw.transform,
        .label => |*label_| &label_.transform,
        .picture => |*group_| &group_.transform,
    };
}

fn composeTransform(current: g.Transform, value: g.Transform) !g.Transform {
    if (!value.isFinite()) return error.NonFinite;
    const result = current.then(value);
    if (!result.isFinite()) return error.NonFinite;
    return result;
}

fn attach(parent: Object, item: Object) void {
    if (parent.container().last.resolve(parent.scene)) |last| last.link().next = Reference.to(last.scene, item) else parent.container().first = Reference.to(parent.scene, item);
    parent.container().last = Reference.to(parent.scene, item);
    item.link().parent = Reference.to(item.scene, parent);
}

fn end(result: *Snapshot) !void {
    try result.picture.endScope();
    if (result.ids.items.len != 0) try result.ids.append(result.picture.storage.allocator, 0);
}

const TestIds = struct {
    scene: *const Scene,
    pub fn identifier(self: @This(), object_: Object) u64 {
        return if (self.scene == object_.scene) @as(u64, object_.index) + 1 else 0;
    }
};

test "excluded child placements validate atomically and copy with their parent" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var hole = try Path.circle(a, .zero, 5);
    defer hole.deinit();
    const layer = try scene.addPath(0, &hole, &.{ .fill = .black }, .{});
    const outside = try scene.addPicture(null, .{}, null);
    try std.testing.expectError(error.DifferentParents, scene.exclude(0, &.{ scene.object(layer), scene.object(outside) }, hole));
    try std.testing.expect(scene.object(layer).link().excluded == null);
    try scene.exclude(0, &.{ scene.object(layer), scene.object(layer) }, hole);
    var clipped = try scene.snapshot(a, 0, null);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(usize, 5), clipped.picture.commands.items.len);
    var cloned = try scene.copy(a, 0);
    defer cloned.deinit();
    var copy_view = try cloned.snapshot(a, 0, null);
    defer copy_view.deinit();
    try std.testing.expectEqualDeep(clipped.picture.commands.items[1].push.clip, copy_view.picture.commands.items[1].push.clip);
    try scene.place(outside, scene.object(layer), null);
    try std.testing.expect(scene.object(layer).link().excluded == null);
}

test "instances keep identity through growth order changes and removal" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 10 });
    const group = try scene.addPicture(0, .translation(20, 30), null);
    const first = try scene.addPath(null, &path, &.{ .fill = .black }, .{});
    try scene.place(group, scene.object(first), null);
    try scene.place(group, scene.object(first), null);
    const second = try scene.addPath(group, &path, &.{ .pen = .{} }, .{});
    for (0..100) |_| _ = try scene.addPath(0, &path, &.{ .fill = .black }, .{});
    try scene.before(second, scene.object(first));
    try std.testing.expectEqual(second, scene.object(group).container().first.index);
    try scene.applyTransform(first, .translation(3, 4));
    try std.testing.expectEqual(@as(f64, 3), (try scene.getNode(first)).path.transform.e);
    try std.testing.expectEqual(@as(f64, 0), (try scene.getNode(second)).path.transform.e);
    var selected = try scene.snapshot(a, first, null);
    defer selected.deinit();
    const box = (try selected.picture.bounds()).?;
    try std.testing.expectEqual(@as(f64, 23), box.min.x);
    try std.testing.expectEqual(@as(f64, 33), box.max.x);
    try std.testing.expectEqual(@as(usize, 5), selected.picture.commands.items.len);
    try scene.remove(group);
    try std.testing.expectEqual(group, (try scene.parentObject(first)).?.index);
    try std.testing.expectEqual(null, try scene.parentObject(group));
    try std.testing.expect((try scene.getNode(first)).* == .path);
    try scene.place(0, scene.object(group), null);
    try std.testing.expectEqual(@as(Index, 0), (try scene.parentObject(group)).?.index);
    const later = try scene.addPath(0, &path, &.{ .fill = .black }, .{});
    try std.testing.expect(later > second);
}

test "import and handoff retain native labels and move original geometry" {
    const a = std.testing.allocator;
    var original = DisplayList.init(a);
    defer original.deinit();
    try original.beginScope(.translation(7, 8), null);
    try original.addLabel(9, .{ .width = 10, .height = 20, .baseline = 16 }, .{});
    try original.endScope();
    var scene = try Scene.fromDisplayList(&original);
    defer scene.deinit();
    try std.testing.expectEqual(@as(usize, 2), scene.links.items.len);
    var selected = try scene.snapshot(a, 0, TestIds{ .scene = &scene });
    defer selected.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 0 }, selected.ids.items);
    var output = scene.takeStorage();
    defer output.deinit();
    try std.testing.expectEqual(@as(u32, 9), selected.picture.commands.items[1].label.reference);
    try std.testing.expectEqual(@as(usize, 0), original.commands.items.len);
}

test "placement across storage owners preserves identity geometry order and ancestry" {
    const a = std.testing.allocator;
    var source = try Scene.init(a);
    defer source.deinit();
    var first = try Scene.init(a);
    defer first.deinit();
    var second = try Scene.init(a);
    defer second.deinit();
    var curve = try Path.circle(a, .zero, 5);
    defer curve.deinit();
    const group_ = try source.addPicture(0, .translation(10, 20), &curve);
    const path = try source.addPath(group_, &curve, &.{ .fill = .black }, .{});
    const text = try source.label(group_, 7, .{ .width = 2, .height = 3, .baseline = 2 }, .zero, .{});
    const own = try first.addPath(0, &curve, &.{ .fill = .black }, .translation(30, 0));
    const geometry = source.storage.segments.items;
    const count = source.links.items.len;

    try first.place(0, source.object(group_), null);
    try first.place(0, source.object(group_), null);
    try source.before(group_, first.object(own));
    var children_ = try first.children(0);
    try std.testing.expect(children_.next().?.eql(source.object(group_)));
    try std.testing.expect(children_.next().?.eql(first.object(own)));
    try std.testing.expectEqual(null, children_.next());
    try std.testing.expect((try source.parentObject(group_)).?.eql(first.object(0)));
    try std.testing.expectError(error.ObjectCycle, source.place(group_, first.object(0), null));
    try std.testing.expect(first.contains(0, source.object(text)));

    {
        var view = try first.snapshot(a, 0, TestIds{ .scene = &first });
        defer view.deinit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 0, 0, 0, 0, 2, 0 }, view.ids.items);
        try std.testing.expectEqual(@as(usize, 2), view.owners.count());
        const borrowed = try view.picture.range(view.picture.commands.items[2].path.path);
        const original = try source.storage.range((try source.getNode(path)).path.path);
        try std.testing.expectEqual(original.ptr, borrowed.ptr);
        try std.testing.expectEqualDeep(try first.storage.range((try first.getNode(own)).path.path), try view.picture.range(view.picture.commands.items[5].path.path));
        var independent = try first.copy(a, 0);
        defer independent.deinit();
        var copied = try independent.snapshot(a, 0, null);
        defer copied.deinit();
        try std.testing.expectEqualDeep(try view.picture.bounds(), try copied.picture.bounds());
        try std.testing.expect((try copied.picture.range(copied.picture.commands.items[2].path.path)).ptr != borrowed.ptr);
    }
    try second.place(0, source.object(group_), null);
    try std.testing.expect(!first.contains(0, source.object(path)));
    try source.remove(group_);
    try std.testing.expectEqual(null, try source.parentObject(group_));
    try std.testing.expect((try source.parentObject(text)).?.eql(source.object(group_)));
    try std.testing.expectEqual(geometry.ptr, source.storage.segments.items.ptr);
    try std.testing.expectEqual(geometry.len, source.storage.segments.items.len);
    try std.testing.expectEqual(count, source.links.items.len);
}

test "placement commits transform and parent together and preserves failure order" {
    const t = std.testing;
    var source = try Scene.init(t.allocator);
    defer source.deinit();
    var destination = try Scene.init(t.allocator);
    defer destination.deinit();
    const group_ = try source.addPicture(0, .translation(2, 3), null);
    const label_ = try source.label(group_, 0, .{ .width = 1, .height = 1, .baseline = 1 }, .zero, .{});
    const original = (try source.getNode(group_)).*;
    const invalid: g.Transform = .{ .a = std.math.inf(f64) };
    try t.expectError(error.NonFinite, source.place(label_, source.object(group_), invalid));
    try t.expectError(error.ExpectedPicture, source.place(label_, source.object(group_), .translation(4, 5)));
    try t.expectError(error.ObjectCycle, source.place(group_, source.object(group_), .translation(4, 5)));
    try t.expectEqualDeep(original, (try source.getNode(group_)).*);
    try t.expect((try source.parentObject(group_)).?.eql(source.object(0)));
    var deepest: Index = 0;
    for (1..DisplayList.max_scope_depth) |_| deepest = try destination.addPicture(deepest, .{}, null);
    try t.expectError(error.GroupNestingTooDeep, destination.place(deepest, source.object(group_), .translation(4, 5)));
    try t.expectEqualDeep(original, (try source.getNode(group_)).*);
    try t.expect((try source.parentObject(group_)).?.eql(source.object(0)));
    try destination.place(0, source.object(group_), .translation(4, 5));
    try t.expectEqualDeep(g.Transform.translation(6, 8), (try source.getNode(group_)).picture.transform);
    try destination.place(0, source.object(group_), .translation(4, 5));
    try t.expectEqualDeep(g.Transform.translation(10, 13), (try source.getNode(group_)).picture.transform);
    try t.expect((try source.parentObject(group_)).?.eql(destination.object(0)));
    const overflow: g.Transform = .{ .a = std.math.floatMax(f64), .e = std.math.floatMax(f64) };
    const before_value = (try source.getNode(group_)).*;
    try t.expectError(error.NonFinite, source.place(group_, source.object(group_), overflow));
    try t.expectEqualDeep(before_value, (try source.getNode(group_)).*);
    var children_ = try destination.children(0);
    _ = children_.next(); // Existing nested group remains first.
    try t.expect(children_.next().?.eql(source.object(group_)));
    try t.expectEqual(null, children_.next());
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
    var scene = try Scene.fromDisplayList(&picture);
    defer scene.deinit();
    try std.testing.expect(scene.storage.segments.items.ptr != path.segments.items.ptr);
    var view = try scene.snapshot(a, 0, null);
    defer view.deinit();
    try std.testing.expectEqual(DisplayList.max_scope_depth, view.picture.maximum_depth);
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
    const leaf_copy = try scene.clone(0, &scene, item, .translation(1, 2));
    try std.testing.expect((try scene.getNode(leaf_copy)).* == .path);
    try std.testing.expectEqual(@as(f64, 1), (try scene.getNode(leaf_copy)).path.transform.e);
    try std.testing.expectEqual(source_segments + path.segments.items.len, scene.storage.segments.items.len);
    const group_copy = try scene.clone(0, &scene, group, .{});
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
    const nested = scene.clone(destination, &scene, group, .{}) catch |err| {
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
    const root_copy = try scene.clone(0, &scene, 0, .{});
    try std.testing.expectEqual(before_root_copy * 2, scene.links.items.len);
    try std.testing.expectEqual(@as(Index, @intCast(before_root_copy)), root_copy);
    var selected = try scene.snapshot(allocator, copied_path, null);
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
    var path = try @import("path/construct.zig").construct(a, &.{ .zero, .{ .x = 10, .y = 8 }, .{ .x = 20, .y = 0 } }, &.{ .smooth, .smooth }, .{});
    defer path.deinit();
    var scene = try Scene.init(a);
    defer scene.deinit();
    {
        var foreign = try Scene.init(a);
        defer foreign.deinit();
        const external = try foreign.addPath(null, &path, &.{ .fill = .black }, .{});
        const foreign_solved = (try foreign.storage.asGeometry().view(a, (try foreign.getNode(external)).path.path)).knotRecords();
        const local = try scene.clone(0, &foreign, external, .{});
        const local_solved = (try scene.storage.asGeometry().view(a, (try scene.getNode(local)).path.path)).knotRecords();
        try t.expectEqualDeep(foreign_solved, local_solved);
        try t.expect(local_solved.ptr != foreign_solved.ptr);
    }
    const original = (try scene.getNode(1)).path;
    for (0..32) |_| {
        const id = try scene.clone(0, &scene, 1, .translation(5, 0));
        const cloned = (try scene.getNode(id)).path;
        try t.expectEqual(original.path.knot_table, cloned.path.knot_table);
        try t.expect(cloned.path.first != original.path.first);
    }
    try t.expectEqual(@as(usize, 1), scene.storage.knot_blocks.items.len);
    try t.expectEqual(path.knotRecords().len * @sizeOf(Path.KnotTable.Knot), scene.storage.knot_bytes);
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
        var curve = try @import("path/construct.zig").construct(a, &.{ .zero, .{ .x = 5, .y = 8 }, .{ .x = 9, .y = 0 } }, &.{ .smooth, .smooth }, .{});
        defer curve.deinit();
        const local = try primary.addPath(0, &curve, &.{ .fill = .black }, .{});
        try curve.transform(.{ .a = 0, .b = 1, .c = -1, .d = 0 });
        const placed = try foreign.addPath(null, &curve, &.{ .fill = .black }, .{});
        try primary.place(0, foreign.object(placed), null);
        var snap = try primary.snapshot(a, 0, null);
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
