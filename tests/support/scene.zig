//! Inspect an exported canvas or object through the same scene traversal used
//! by rendering. The returned view borrows geometry until the runtime dies.
const std = @import("std");
const huak = @import("huak");
const Runtime = huak.language.Runtime;
const Value = huak.language.types.Value;

pub fn canvases(runtime: *const Runtime) usize {
    var result: usize = 0;
    for (runtime.scene_values.items) |storage| for (storage.scene.nodes.items) |command| {
        if (command == .picture) result += 1;
    };
    return result;
}

pub fn childCount(value: Value) !usize {
    var children = try owner(value).scene.children(value.object.index);
    var result: usize = 0;
    while (children.next() != null) result += 1;
    return result;
}

pub fn view(value: Value) !huak.core.Scene.Snapshot {
    return owner(value).scene.snapshot(std.testing.allocator, value.object.index, null);
}

pub fn count(snapshot: *const huak.core.Scene.Snapshot, kind: std.meta.Tag(huak.core.DisplayList.Command)) usize {
    var n: usize = 0;
    for (snapshot.picture.commands.items) |command| if (command == kind) {
        n += 1;
    };
    return n;
}

pub fn owner(value: Value) *huak.language.Runtime.SceneOwner {
    return @ptrCast(@alignCast(@constCast(value.object.owner)));
}
pub fn object(value: Value) huak.core.Scene.Object {
    return owner(value).scene.object(value.object.index);
}
