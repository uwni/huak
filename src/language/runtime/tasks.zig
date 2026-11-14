//! Coordinator-side task snapshots and result ownership transfer. Workers see
//! independent metadata; all borrowed input storage remains live until join.
const std = @import("std");
const typst = @import("libtypst");
const Runtime = @import("../Runtime.zig");
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
    for (parent.layouts.items[marker.layouts..]) |layout| Runtime.releaseLayout(parent.gpa, layout);
    for (parent.texts.items[marker.texts..]) |*text| Runtime.releaseText(parent.gpa, text);
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
    var owners = try source.scene.storageClosure(child.gpa);
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

/// These builtins return handles, so nothing lands in the result allocator.
fn invoke(owner: *Runtime, id: @import("../builtin.zig").Id, arguments: []const types.Value) !types.Value {
    const host = owner.host();
    return host.callBuiltin(owner.gpa, id, arguments, null);
}

test "task snapshots isolate metadata and prohibit writes through borrowed owners" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{ .inputs = &.{.{ .key = "title", .value = "retained" }} });
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const picture = try invoke(&parent, .picture, &.{});
    _ = try invoke(&parent, .append, &.{ picture, try invoke(&parent, .draw, &.{curve}) });
    const solver = try invoke(&parent, .solver, &.{});
    try parent.prepareTasks(false);
    var child = try parent.forkTask();
    defer child.deinit();
    try std.testing.expect(child.host().vtable.typst_batch == null);
    try std.testing.expect(parent.host().vtable.typst_batch != null);
    try std.testing.expect(child.path_values.items.ptr != parent.path_values.items.ptr);
    try std.testing.expectEqual(parent.path_values.items[0].segments.items.ptr, child.path_values.items[0].segments.items.ptr);
    try std.testing.expectEqual(parent.scene_values.items[0], child.scene_values.items[0]);
    try std.testing.expectEqual(parent.options.inputs.ptr, child.options.inputs.ptr);
    try std.testing.expectError(error.TaskCannotMutateBorrowedPicture, invoke(&child, .append, &.{ picture, try invoke(&child, .draw, &.{curve}) }));
    try std.testing.expectError(error.TaskCannotMutateBorrowedSolver, invoke(&child, .unknown, &.{solver}));
    try std.testing.expectError(error.TaskSideEffect, invoke(&child, .print, &.{.{ .string = "not observable" }}));
    try std.testing.expectError(error.InvalidTaskResult, parent.adoptTask(&child, picture));
    const child_host = child.host();
    try std.testing.expectError(error.TaskTypographyNotPrepared, child_host.typeset(child.gpa, .{ .source = "hello" }));
    var original = try parent.scene_values.items[0].scene.snapshot(a, 0, null);
    defer original.deinit();
    try std.testing.expectEqual(@as(usize, 3), original.picture.commands.items.len);
    try std.testing.expectEqualStrings("", parent.nativeDiagnostic());
}

test "task picture adoption moves geometry and supports continued drawing" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const earlier = try invoke(&parent, .picture, &.{});
    _ = try invoke(&parent, .append, &.{ earlier, try invoke(&parent, .draw, &.{curve}) });
    var child = try parent.forkTask();
    var child_alive = true;
    defer if (child_alive) child.deinit();
    const result = try invoke(&child, .picture, &.{});
    const object = try invoke(&child, .append, &.{ result, try invoke(&child, .draw, &.{curve}) });
    _ = try invoke(&child, .picture, &.{}); // Unreturned child scratch owner.
    const source = testOwner(result);
    const object_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(object.object.owner)));
    const segments = object_owner.scene.storage.segments.items.ptr;
    const adopted = try parent.adoptTask(&child, result);
    try std.testing.expectEqual(source, testOwner(adopted));
    try std.testing.expectEqual(segments, object_owner.scene.storage.segments.items.ptr);
    try std.testing.expectError(error.InvalidTaskRuntime, parent.adoptTask(&child, result));
    child.deinit();
    child_alive = false;
    _ = try invoke(&parent, .append, &.{ adopted, try invoke(&parent, .draw, &.{curve}) });
    _ = try invoke(&parent, .append, &.{ earlier, adopted });
    const keys = types.listView(&.{
        types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }),
    });
    _ = try invoke(&parent, .animate, &.{ object, .{ .string = "opacity" }, keys });
    var tracks = object_owner.animation_state.iterator();
    try std.testing.expectEqual(@as(u64, object.object.index + 1), tracks.next().?.target);
    var selected = try testOwner(earlier).view(a, earlier.object.index);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 7), selected.snapshot.picture.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), selected.tracks.items.len);
}

test "task checkpoint rollback releases unpublished owners without changing serial identity" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const marker = parent.checkpointTasks();
    var child = try parent.forkTask();
    defer child.deinit();
    const result = try invoke(&child, .picture, &.{});
    _ = try invoke(&child, .append, &.{ result, try invoke(&child, .draw, &.{curve}) });
    _ = try parent.adoptTask(&child, result);
    parent.rollbackTasks(marker);
    try std.testing.expectEqual(marker, parent.checkpointTasks());
    const fallback = try invoke(&parent, .picture, &.{});
    const object = try invoke(&parent, .append, &.{ fallback, try invoke(&parent, .draw, &.{curve}) });
    const object_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(object.object.owner)));
    try std.testing.expectEqual(marker.scenes, testOwner(fallback).owner_index);
    try std.testing.expectEqual(marker.scenes + 1, object_owner.owner_index);
    try std.testing.expectEqual(@as(u32, 0), fallback.object.index);
    try std.testing.expectEqual(@as(u32, 0), object.object.index);
}

fn allocationFailureAdoption(allocator: std.mem.Allocator, object_result: bool) !void {
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(allocator, allocator, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    var child = try parent.forkTask();
    defer child.deinit();
    const result = try invoke(&child, .picture, &.{});
    const group = result;
    const item = try invoke(&child, .append, &.{ group, try invoke(&child, .draw, &.{curve}) });
    const extra = try invoke(&child, .picture, &.{});
    _ = try invoke(&child, .append, &.{ extra, try invoke(&child, .draw, &.{curve}) });
    const destination: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(group.object.owner)));
    const extra_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(extra.object.owner)));
    try destination.scene.place(group.object.index, extra_owner.scene.object(extra.object.index), null);
    const adopted = try parent.adoptTask(&child, if (object_result) item else result);
    if (object_result) {
        try std.testing.expectEqual(item.object, adopted.object);
        const host = parent.host();
        try std.testing.expectEqual(group.object, (try host.field(parent.gpa, adopted, "parent")).object);
    }
}

test "task adoption moves the connected storage graph and preserves foreign handles" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    var child = try parent.forkTask();
    var child_alive = true;
    defer if (child_alive) child.deinit();
    const output = try invoke(&child, .picture, &.{});
    const group = try invoke(&child, .picture, &.{});
    const item = try invoke(&child, .append, &.{ group, try invoke(&child, .draw, &.{curve}) });
    const canvas = testOwner(output);
    const owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(group.object.owner)));
    const item_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(item.object.owner)));
    const geometry = item_owner.scene.storage.segments.items.ptr;
    try canvas.scene.place(output.object.index, owner.scene.object(group.object.index), null);
    const unused = try invoke(&child, .picture, &.{});
    const unused_owner = testOwner(unused);
    var expected = try canvas.scene.storageClosure(a);
    defer expected.deinit(a);
    const result = try parent.adoptTask(&child, output);
    try std.testing.expectEqual(expected.count(), parent.scene_values.items.len);
    for (parent.scene_values.items) |retained| {
        try std.testing.expect(retained != unused_owner);
        try std.testing.expect(expected.contains(&retained.scene));
    }
    child.deinit();
    child_alive = false;
    try std.testing.expectEqual(geometry, item_owner.scene.storage.segments.items.ptr);
    try std.testing.expectEqual(canvas, testOwner(result));
    const host = parent.host();
    try std.testing.expectEqual(group.object, (try host.field(parent.gpa, item, "parent")).object);
    var view = try canvas.scene.snapshot(a, output.object.index, null);
    defer view.deinit();
    try std.testing.expectEqual(expected.count(), view.owners.count());
    try std.testing.expectEqual(geometry, (try view.picture.range(view.picture.commands.items[2].path.path)).ptr);
}

test "task adoption rejects animation tracks without moving owners" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    var child = try parent.forkTask();
    defer child.deinit();
    const picture = try invoke(&child, .picture, &.{});
    const token = try invoke(&child, .append, &.{ picture, try invoke(&child, .draw, &.{curve}) });
    const marker = parent.checkpointTasks();
    const keys = types.listView(&.{
        types.listView(&.{ .{ .int = 0 }, .{ .number = 0.25 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }),
    });
    _ = try invoke(&child, .animate, &.{ token, .{ .string = "opacity" }, keys });
    try std.testing.expectError(error.TaskAnimationNotSupported, parent.adoptTask(&child, picture));
    try std.testing.expectEqual(marker, parent.checkpointTasks());
    try std.testing.expect(child.task_borrow.?.adopted == null);
}

test "task fork and adoption preserve ownership on allocation failure" {
    for ([_]bool{ false, true }) |object_result|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureAdoption, .{object_result});
}

test "aggregate runtime task adoption rejects containers wrapping pictures" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(a, a, &unused_library, .{});
    defer parent.deinit();
    var child = try parent.forkTask();
    defer child.deinit();
    const picture = try invoke(&child, .picture, &.{});
    var dict: types.Dict = .{};
    defer dict.entries.deinit(a);
    try dict.entries.put(a, "picture", picture);
    var fields = [_]types.Value{picture};
    var record_value: types.Record = .{ .kind = types.Type.record(0), .fields = &fields };
    const marker = parent.checkpointTasks();
    for ([_]types.Value{ .{ .dict = &dict }, .{ .record = &record_value }, types.listView(&.{picture}) }) |value| {
        try std.testing.expectError(error.InvalidTaskResult, parent.adoptTask(&child, value));
        try std.testing.expectEqual(marker, parent.checkpointTasks());
        try std.testing.expect(child.task_borrow.?.adopted == null);
    }
}

fn testOwner(value: types.Value) *Runtime.SceneOwner {
    return @ptrCast(@alignCast(@constCast(value.object.owner)));
}
