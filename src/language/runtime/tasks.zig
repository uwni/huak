//! Coordinator-side task snapshots and result ownership transfer. Workers see
//! independent metadata; all borrowed input storage remains live until join.
const std = @import("std");
const typst = @import("libtypst");
const Runtime = @import("../Runtime.zig");
const typesetting = @import("typesetting.zig");
const typeset_text = @import("typeset_text.zig");
const types = @import("../types.zig");
const Scene = @import("../../drawing/Scene.zig");

/// Each registry's length when a child was forked, named like the Runtime
/// field. The child shares those entries with its parent and owns only the
/// entries it appends.
pub const Lengths = struct {
    path_values: usize = 0,
    measures: usize = 0,
    colors: usize = 0,
    pens: usize = 0,
    gradients: usize = 0,
    transforms: usize = 0,
    models: usize = 0,
    solvers: usize = 0,
    variables: usize = 0,
    expressions: usize = 0,
    solutions: usize = 0,
    texts: usize = 0,
    anchors: usize = 0,
    typst_modules: usize = 0,
    layouts: usize = 0,
    frames: usize = 0,
    scene_values: usize = 0,
};

pub const Borrowed = struct {
    parent: *Runtime,
    lengths: Lengths,
    /// Storage owners moved to the parent, allocated with the child's
    /// allocator and released with the child.
    adopted: ?Scene.Owners = null,
};

/// Only coordinator-side ownership additions are rolled back. Native
/// read-only caches may remain until the parent runtime is freed.
pub const Checkpoint = struct {
    scenes: usize,
    layouts: usize,
    frames: usize,
    texts: usize,
};

pub fn checkpoint(parent: *const Runtime) Checkpoint {
    return .{
        .scenes = parent.scene_values.items.len,
        .layouts = parent.layouts.items.len,
        .frames = parent.frames.items.len,
        .texts = parent.texts.items.len,
    };
}

pub fn rollback(parent: *Runtime, marker: Checkpoint) void {
    std.debug.assert(parent.task_borrow == null);
    if (parent.object_storage) |index| if (index >= marker.scenes) {
        parent.object_storage = null;
    };
    for (parent.scene_values.items[marker.scenes..]) |target| {
        target.scene.deinit();
        target.animation_state.deinit();
        parent.gpa.destroy(target);
    }
    for (parent.layouts.items[marker.layouts..]) |layout| typesetting.releaseLayout(parent.gpa, layout);
    for (parent.texts.items[marker.texts..]) |*text| typeset_text.releaseText(parent.gpa, text);
    parent.scene_values.shrinkRetainingCapacity(marker.scenes);
    parent.layouts.shrinkRetainingCapacity(marker.layouts);
    parent.frames.shrinkRetainingCapacity(marker.frames);
    parent.texts.shrinkRetainingCapacity(marker.texts);
}

pub fn fork(parent: *Runtime) !Runtime {
    if (parent.outputs_taken or parent.task_borrow != null) return error.InvalidState;
    var lengths: Lengths = .{};
    inline for (@typeInfo(Lengths).@"struct".field_names) |name| @field(lengths, name) = @field(parent, name).items.len;
    // The borrow is recorded first, so a failed copy releases only the
    // child's own list buffers.
    var child: Runtime = .{
        .gpa = parent.gpa,
        .scene_allocator = parent.scene_allocator,
        .backends = parent.backends,
        .options = parent.options,
        .shared_engine = if (parent.engine) |*engine| engine else null,
        .task_borrow = .{ .parent = parent, .lengths = lengths },
    };
    errdefer child.deinit();
    inline for (@typeInfo(Lengths).@"struct".field_names) |name| {
        try @field(child, name).appendSlice(child.gpa, @field(parent, name).items);
    }
    // Cached anchors belong to the runtime that made them.
    for (child.texts.items) |*text| text.anchors = null;
    return child;
}

/// A newly created static scene can escape as a picture or object. Geometry and
/// styles move intact, preserving object handles. Layout owner structs
/// are recreated in the parent; animation identity stays on the serial path.
/// Every allocation and validation precedes the ownership commit.
pub fn adopt(parent: *Runtime, child: *Runtime, value: types.Value) !types.Value {
    if (parent.outputs_taken or parent.task_borrow != null) return error.InvalidState;
    const borrowed = child.task_borrow orelse return error.InvalidTaskRuntime;
    if (borrowed.parent != parent or borrowed.adopted != null or child.outputs_taken) return error.InvalidTaskRuntime;
    if (value != .object) return error.InvalidTaskResult;
    const object: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(value.object.owner)));
    const index = object.owner_index;
    if (index < borrowed.lengths.scene_values or index >= child.scene_values.items.len) return error.InvalidTaskResult;
    const source = child.scene_values.items[index];
    if (source != object) return error.InvalidTaskResult;
    if ((value.object.kind == .picture) != ((try source.scene.getNode(value.object.index)).* == .picture)) return error.InvalidTaskResult;
    var owners = try Scene.ownership.storageClosure(&source.scene, child.gpa);
    var owners_moved = false;
    defer if (!owners_moved) owners.deinit(child.gpa);
    for (owners.keys()) |scene| {
        const owner = Runtime.SceneOwner.fromScene(scene);
        if (owner.owner_index < borrowed.lengths.scene_values or owner.owner_index >= child.scene_values.items.len or child.scene_values.items[owner.owner_index] != owner) return error.InvalidTaskResult;
        if (owner.animation_state.tracks.first != null) return error.TaskAnimationNotSupported;
    }
    var temporary: std.heap.ArenaAllocator = .init(parent.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var references: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var layouts: std.AutoArrayHashMapUnmanaged(*const typst.Layout, ?*typst.Layout) = .empty;
    var frame_count: usize = 0;

    // The storage owner moves intact, including detached objects. Parentage
    // does not determine whether a text reference still needs its layout.
    for (owners.keys()) |scene| for (scene.nodes.items) |*command| {
        if (command.* != .label) continue;
        const reference = command.label.reference;
        if (reference >= child.frames.items.len) return error.InvalidFrameReference;
        if (references.contains(reference)) continue;
        const frame = child.frames.items[reference];
        if (reference < borrowed.lengths.frames) {
            // Snapshot prefixes retain their parent indices even when other
            // completed tasks have since appended their own metadata.
            if (reference >= parent.frames.items.len) return error.InvalidFrameReference;
            const original = parent.frames.items[reference];
            if (original.layout != frame.layout or original.index != frame.index) return error.InvalidFrameReference;
            try references.put(scratch, reference, reference);
            continue;
        }
        if (reference >= child.texts.items.len) return error.InvalidFrameReference;
        const text = child.texts.items[reference];
        if (text.layout != frame.layout or text.frame != frame.index) return error.InvalidFrameReference;
        const destination = std.math.add(usize, parent.frames.items.len, frame_count) catch return error.TooManyLabels;
        if (destination > std.math.maxInt(u32)) return error.TooManyLabels;
        try layouts.put(scratch, frame.layout, null);
        try references.put(scratch, reference, @intCast(destination));
        frame_count += 1;
    };

    if (owners.count() > std.math.maxInt(u32) - parent.scene_values.items.len) return error.TooManyObjects;
    const own = parent.gpa;
    var moved: usize = 0;
    var resolved: usize = 0;
    // Layout owners created for the parent are released if any later step
    // fails; borrowed layouts map to themselves.
    errdefer for (layouts.keys(), layouts.values()) |source_layout, destination| {
        if (destination) |target| if (target != source_layout) own.destroy(target);
    };
    // Resolve the requested layout owners in one pass. Geometry-only results
    // have no layouts to resolve and retain no typography index.
    if (layouts.count() != 0) {
        for (child.layouts.items, 0..) |source_layout, layout_index| {
            const target = layouts.getPtr(source_layout) orelse continue;
            if (layout_index < borrowed.lengths.layouts) {
                target.* = source_layout;
            } else {
                if (source_layout.handle == null) return error.InvalidFrameReference;
                const destination = try own.create(typst.Layout);
                destination.* = .{ .library = parent.backends.typst, .handle = null };
                target.* = destination;
                moved += 1;
            }
            resolved += 1;
            if (resolved == layouts.count()) break;
        }
    }
    if (resolved != layouts.count()) return error.InvalidFrameReference;
    try parent.scene_values.ensureUnusedCapacity(own, owners.count());
    try parent.layouts.ensureUnusedCapacity(own, moved);
    try parent.frames.ensureUnusedCapacity(own, frame_count);
    try parent.texts.ensureUnusedCapacity(own, frame_count);

    // No failures after this commit. Other child layouts and scratch objects
    // remain child-owned and are released by its immediately following deinit.
    for (layouts.keys(), layouts.values()) |source_layout, destination| {
        const target = destination.?;
        if (source_layout == target) continue;
        target.* = source_layout.*;
        @constCast(source_layout).handle = null;
        parent.layouts.appendAssumeCapacity(target);
    }
    // The reference map already records each destination slot. Copy directly
    // from the child instead of staging a second array of frames and metrics.
    parent.frames.items.len += frame_count;
    parent.texts.items.len += frame_count;
    var iterator = references.iterator();
    while (iterator.next()) |entry| {
        const reference = entry.key_ptr.*;
        if (reference < borrowed.lengths.frames) continue;
        const text = child.texts.items[reference];
        const layout = layouts.get(text.layout).?.?;
        parent.frames.items[entry.value_ptr.*] = .{ .layout = layout, .index = text.frame };
        parent.texts.items[entry.value_ptr.*] = .{ .layout = layout, .frame = text.frame, .metrics = text.metrics };
    }
    for (owners.keys()) |scene| {
        const owner = Runtime.SceneOwner.fromScene(scene);
        for (owner.scene.nodes.items) |*command| {
            if (command.* == .label) command.label.reference = references.get(command.label.reference).?;
        }
        owner.owner_index = @intCast(parent.scene_values.items.len);
        parent.scene_values.appendAssumeCapacity(owner);
    }
    child.task_borrow.?.adopted = owners;
    owners_moved = true;
    return value;
}

test {
    _ = @import("tasks_test.zig");
}
