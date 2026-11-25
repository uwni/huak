//! Retained drawing objects. Identity and storage are independent of parentage:
//! a detached object remains live, and placement never copies its geometry.
//! Explicit cloning owns new geometry and identities.
const std = @import("std");
const DisplayList = @import("DisplayList.zig");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");
const Allocator = std.mem.Allocator;

const Storage = @import("Storage.zig");
const exclusion = @import("exclusion.zig");

/// Subtree selection into a balanced command view.
pub const snapshots = @import("scene/snapshots.zig");
/// Parentage, paint order and placement holes.
pub const placement = @import("scene/placement.zig");
/// Subtree copies with new identities.
pub const cloning = @import("scene/cloning.zig");
/// Storage import, leaf budgets, cross-owner closure and hand-off.
pub const ownership = @import("scene/ownership.zig");

/// Retained drawing objects have no render-stream enter/leave markers.
pub const Node = union(enum) { path: Storage.PathCommand, label: Storage.Label, picture: Storage.Scope };
pub const Index = u32;
pub const none: Index = std.math.maxInt(Index);
pub const Object = struct {
    scene: *Scene,
    index: Index,

    pub fn eql(self: Object, other: Object) bool {
        return self.scene == other.scene and self.index == other.index;
    }
    pub fn link(self: Object) *Link {
        return &self.scene.links.items[self.index];
    }
    pub fn parent(self: Object) ?Object {
        return self.link().parent.resolve(self.scene);
    }
    pub fn container(self: Object) *Container {
        return &self.scene.containers.items[self.link().children];
    }
};

/// Local links are relative, so a detached storage owner may move before it
/// participates in a graph. Cross-owner links require stable Scene addresses.
pub const Reference = struct {
    scene: ?*Scene = null,
    index: Index = none,

    pub fn resolve(self: Reference, local: *const Scene) ?Object {
        if (self.index == none) return null;
        return .{ .scene = self.scene orelse @constCast(local), .index = self.index };
    }
    pub fn to(local: *const Scene, item: Object) Reference {
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

pub fn getNode(self: *const Scene, index: Index) !*const Node {
    if (index >= self.links.items.len) return error.InvalidObject;
    return &self.nodes.items[index];
}

pub fn object(self: *const Scene, index: Index) Object {
    return .{ .scene = @constCast(self), .index = index };
}

pub fn reserve(self: *Scene, parent: ?Index) !Index {
    if (parent) |index| if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    if (self.links.items.len >= none) return error.TooManyObjects;
    try self.links.ensureUnusedCapacity(self.storage.allocator, 1);
    return @intCast(self.links.items.len);
}

pub fn commit(self: *Scene, parent: ?Index, index: Index) Index {
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

/// The copy shares mesh arrays already held by `meshes`; null copies them.
pub fn copy(self: *const Scene, allocator: Allocator, meshes: ?*Storage.MeshStore, index: Index) !Scene {
    var result: Scene = .{ .storage = .initWithMeshes(allocator, meshes) };
    errdefer result.deinit();
    _ = try cloning.clone(&result, null, self, index, .{});
    return result;
}

const SubtreeSize = struct { nodes: usize = 1, groups: usize = 0, segments: usize = 0, depth: usize = 0 };

pub fn subtreeSize(self: *const Scene, index: Index, depth: usize) anyerror!SubtreeSize {
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
    try validateClip(clip);
    const scope = try self.storage.scope(.{}, clip);
    self.nodes.items[index].picture.clip = scope.clip;
}

/// Blend the picture's finished content at `opacity`, from 0 to 1, as one
/// layer. At 1 its paints go to the page one by one.
pub fn setOpacity(self: *Scene, index: Index, opacity: f64) !void {
    if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    try Storage.validateOpacity(opacity);
    self.nodes.items[index].picture.opacity = opacity;
}

pub fn validateClip(path: ?*const Path) !void {
    try Storage.validateScope(.{}, path);
}

/// Copy of the picture's root clip. An accumulated clip can intersect to
/// nothing; count zero is that hidden state and is distinct from no clip.
pub fn currentClip(self: *const Scene, index: Index) !?Path {
    const command = try self.getNode(index);
    if (command.* != .picture) return error.ExpectedPicture;
    const reference = command.picture.clip orelse return null;
    var result = Path.init(self.storage.allocator);
    errdefer result.deinit();
    for (try self.storage.range(reference)) |segment| switch (segment) {
        .move => |point| try result.moveTo(point),
        .line => |point| try result.lineTo(point),
        .cubic => |curve| try result.cubicTo(curve.c1, curve.c2, curve.end),
        .close => try result.close(),
    };
    return result;
}

/// Hide the complete subtree without confusing it with an absent clip.
pub fn setEmptyClip(self: *Scene, index: Index) !void {
    if ((try self.getNode(index)).* != .picture) return error.ExpectedPicture;
    self.nodes.items[index].picture.clip = .{ .first = 0, .count = 0 };
}

pub fn setStyle(self: *Scene, index: Index, style: *const DisplayList.Style) !void {
    if ((try self.getNode(index)).* != .path) return error.ExpectedPathObject;
    try DisplayList.validateStyle(style);
    const target = &self.nodes.items[index].path.style;
    target.* = try self.storage.styles.replace(target.*, style);
}

/// Replace only this instance's geometry; its style and transform remain.
pub fn setPath(self: *Scene, index: Index, path: *const Path) !void {
    const current = (try self.getNode(index)).*;
    if (current != .path) return error.ExpectedPathObject;
    try Storage.validateDrawing(path, current.path.style, current.path.transform);
    const replacement = try self.storage.path(path, current.path.style, current.path.transform);
    self.storage.styles.release(current.path.style);
    self.nodes.items[index].path = replacement;
}

/// Mutate only this instance's local transform. Parent transforms continue
/// to apply to its descendants; source paths and other instances stay intact.
pub fn applyTransform(self: *Scene, index: Index, value: g.Transform) !void {
    const current = nodeTransform(@constCast(try self.getNode(index)));
    current.* = try composeTransform(current.*, value);
}

pub fn ancestorDepth(self: *const Scene, parent: ?Index) usize {
    var cursor: ?Object = if (parent) |index| self.object(index) else null;
    var depth: usize = 0;
    while (cursor) |node| : (cursor = node.parent()) depth += 1 + @as(usize, @intFromBool(node.link().excluded != null));
    return depth;
}

pub fn nodeTransform(command: *Node) *g.Transform {
    return switch (command.*) {
        .path => |*draw| &draw.transform,
        .label => |*label_| &label_.transform,
        .picture => |*group_| &group_.transform,
    };
}

pub fn composeTransform(current: g.Transform, value: g.Transform) !g.Transform {
    if (!value.isFinite()) return error.NonFinite;
    const result = current.then(value);
    if (!result.isFinite()) return error.NonFinite;
    return result;
}

pub fn attach(parent: Object, item: Object) void {
    if (parent.container().last.resolve(parent.scene)) |last| last.link().next = Reference.to(last.scene, item) else parent.container().first = Reference.to(parent.scene, item);
    parent.container().last = Reference.to(parent.scene, item);
    item.link().parent = Reference.to(item.scene, parent);
}

test {
    _ = @import("scene/snapshots.zig");
    _ = @import("scene/placement_test.zig");
    _ = @import("scene/cloning.zig");
    _ = @import("scene/ownership.zig");
}
