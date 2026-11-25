//! Object handles: validating them, snapshots, registering new owners, and leaf objects on storage pages.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Scene = @import("../../drawing/Scene.zig");
const types = @import("../types.zig");
const renderer = @import("../../render/root.zig");
const Value = types.Value;
const SceneOwner = @import("objects.zig").Owner;
const Runtime = @import("../Runtime.zig");

pub const Instance = struct { owner: *SceneOwner, index: Scene.Index };

pub fn objectValue(self: *Runtime, value: Value, mutable: bool) !Instance {
    if (value != .object) return error.TypeMismatch;
    // Object values are unforgeable in the language and live only for this
    // execution. Validate ownership before accessing scene storage.
    const owner: *SceneOwner = @ptrCast(@alignCast(@constCast(value.object.owner)));
    const index = owner.owner_index;
    if (index >= self.scene_values.items.len or self.scene_values.items[index] != owner) return error.InvalidObject;
    if (mutable and index < self.firstOwned("scene_values")) return error.TaskCannotMutateBorrowedPicture;
    _ = try owner.scene.getNode(value.object.index);
    return .{ .owner = owner, .index = value.object.index };
}

pub fn objectHandle(object_: Scene.Object) Value {
    const owner: *SceneOwner = @fieldParentPtr("scene", object_.scene);
    return .{ .object = .{ .owner = owner, .index = object_.index, .kind = if (owner.scene.nodes.items[object_.index] == .picture) .picture else .object } };
}

pub fn hasAnimation(self: *Runtime, object: Instance) bool {
    for (self.scene_values.items) |owner| {
        var tracks = owner.animation_state.iterator();
        while (tracks.next()) |track| {
            const index = std.math.cast(Scene.Index, track.target - 1) orelse continue;
            if (owner.scene.contains(index, object.owner.scene.object(object.index)) or object.owner.scene.contains(object.index, owner.scene.object(index))) {
                return true;
            }
        }
    }
    return false;
}

pub fn requireStatic(self: *Runtime, object: Instance) !void {
    if (hasAnimation(self, object)) {
        self.native_message = "operation requires a static object (including its ancestors and descendants)";
        return error.AnimatedPicture;
    }
}

pub fn objectSnapshot(self: *Runtime, value: Value, static: bool) !Scene.Snapshot {
    const object = try objectValue(self, value, false);
    if (static) try requireStatic(self, object);
    return Scene.snapshots.snapshotWithBounds(&object.owner.scene, self.gpa, object.index, null, renderer.FrameBounds{ .frames = self.frames.items });
}

/// Both helpers consume their input, including allocation-failure paths.
pub fn objectResult(self: *Runtime, value: DisplayList) !Value {
    var result = value;
    errdefer result.deinit();
    return sceneResult(self, try Scene.ownership.fromDisplayList(&result), 0);
}

pub fn sceneResult(self: *Runtime, value: Scene, index: Scene.Index) !Value {
    const target = try storeScene(self, value);
    return objectHandle(target.scene.object(index));
}

pub fn storeScene(self: *Runtime, value: Scene) !*SceneOwner {
    var scene = value;
    errdefer scene.deinit();
    const target = try self.gpa.create(SceneOwner);
    errdefer self.gpa.destroy(target);
    target.* = .{ .scene = scene, .owner_index = try nextOwnerIndex(self), .animation_state = .init(self.gpa) };
    try self.scene_values.append(self.gpa, target);
    return target;
}

fn objectStorage(self: *Runtime, curve: ?*const Path) !*SceneOwner {
    const page_budget = 64 * 1024;
    if (self.object_storage) |index| {
        const owner = self.scene_values.items[index];
        // Bound array growth before insertion consumes the page budget.
        // An oversized object occupies a fresh page of its own. Styles and
        // tracks added later count toward the next insertion's budget.
        if (try Scene.ownership.reserveNode(&owner.scene, curve, page_budget -| owner.animation_state.allocatedBytes())) return owner;
    }
    var fresh: Scene = .{ .storage = .initWithMeshes(self.scene_allocator, self.backends.meshes) };
    // Apply the same bounded growth to the first object. A path larger than
    // the entire page may still be stored alone.
    _ = Scene.ownership.reserveNode(&fresh, curve, page_budget) catch |err| {
        fresh.deinit();
        return err;
    };
    const owner = try storeScene(self, fresh);
    self.object_storage = owner.owner_index;
    return owner;
}

pub fn pathObject(self: *Runtime, curve: *const Path, style: *const DisplayList.Style, transform: g.Transform) !Value {
    const owner = try objectStorage(self, curve);
    return .{ .object = .{ .owner = owner, .index = try owner.scene.addPath(null, curve, style, transform) } };
}

pub fn labelObject(self: *Runtime, reference: u32, position: g.Point, transform: g.Transform) !Value {
    const owner = try objectStorage(self, null);
    return .{ .object = .{ .owner = owner, .index = try owner.scene.label(null, reference, self.texts.items[reference].metrics, position, transform) } };
}

pub fn nextOwnerIndex(self: *Runtime) !u32 {
    if (self.scene_values.items.len >= std.math.maxInt(u32)) return error.TooManyObjects;
    return @intCast(self.scene_values.items.len);
}
