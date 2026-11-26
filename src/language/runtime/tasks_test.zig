//! Tests of task snapshots, picture adoption, checkpoints and rollback.
const std = @import("std");
const typst = @import("libtypst");
const Runtime = @import("../Runtime.zig");
const types = @import("../types.zig");
const Scene = @import("../../drawing/Scene.zig");
const testing = @import("testing.zig");

/// These builtins return handles, so nothing lands in the result allocator.
fn invoke(owner: *Runtime, id: @import("../builtin.zig").Id, arguments: []const types.Value) !types.Value {
    const host = owner.host();
    return host.callBuiltin(owner.gpa, id, arguments, null);
}

test "task snapshots isolate metadata and prohibit writes through borrowed owners" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.initWithBackends(a, a, .{ .typst = &unused_library, .workers = .init(std.testing.io, 4) }, .{ .inputs = &.{.{ .key = "title", .value = "retained" }} });
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    const picture = try invoke(&parent, .picture, &.{});
    _ = try invoke(&parent, .append, &.{ picture, try invoke(&parent, .draw, &.{curve}) });
    const solver = try invoke(&parent, .solver, &.{});
    try parent.prepareTasks(false);
    var child = try parent.forkTask(parent.backends.workers.nested(4));
    defer child.deinit();
    try std.testing.expectEqual(@as(?std.Io, null), child.backends.workers.io);
    try std.testing.expect(parent.backends.workers.io != null);
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
    var original = try Scene.snapshots.snapshot(&parent.scene_values.items[0].scene, a, 0, null);
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
    var child = try parent.forkTask(.serial);
    var child_alive = true;
    defer if (child_alive) child.deinit();
    const result = try invoke(&child, .picture, &.{});
    const object = try invoke(&child, .append, &.{ result, try invoke(&child, .draw, &.{curve}) });
    _ = try invoke(&child, .picture, &.{}); // Unreturned child scratch owner.
    const source = testing.testOwner(result);
    const object_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(object.object.owner)));
    const segments = object_owner.scene.storage.segments.items.ptr;
    const adopted = try parent.adoptTask(&child, result);
    try std.testing.expectEqual(source, testing.testOwner(adopted));
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
    var selected = try testing.testOwner(earlier).view(a, earlier.object.index);
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
    var child = try parent.forkTask(.serial);
    defer child.deinit();
    const result = try invoke(&child, .picture, &.{});
    _ = try invoke(&child, .append, &.{ result, try invoke(&child, .draw, &.{curve}) });
    _ = try parent.adoptTask(&child, result);
    parent.rollbackTasks(marker);
    try std.testing.expectEqual(marker, parent.checkpointTasks());
    const fallback = try invoke(&parent, .picture, &.{});
    const object = try invoke(&parent, .append, &.{ fallback, try invoke(&parent, .draw, &.{curve}) });
    const object_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(object.object.owner)));
    try std.testing.expectEqual(marker.scenes, testing.testOwner(fallback).owner_index);
    try std.testing.expectEqual(marker.scenes + 1, object_owner.owner_index);
    try std.testing.expectEqual(@as(u32, 0), fallback.object.index);
    try std.testing.expectEqual(@as(u32, 0), object.object.index);
}

fn allocationFailureAdoption(allocator: std.mem.Allocator, object_result: bool) !void {
    var unused_library: typst.Library = undefined;
    var parent = try Runtime.init(allocator, allocator, &unused_library, .{});
    defer parent.deinit();
    const curve = try invoke(&parent, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    var child = try parent.forkTask(.serial);
    defer child.deinit();
    const result = try invoke(&child, .picture, &.{});
    const group = result;
    const item = try invoke(&child, .append, &.{ group, try invoke(&child, .draw, &.{curve}) });
    const extra = try invoke(&child, .picture, &.{});
    _ = try invoke(&child, .append, &.{ extra, try invoke(&child, .draw, &.{curve}) });
    const destination: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(group.object.owner)));
    const extra_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(extra.object.owner)));
    try Scene.placement.place(&destination.scene, group.object.index, extra_owner.scene.object(extra.object.index), null);
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
    var child = try parent.forkTask(.serial);
    var child_alive = true;
    defer if (child_alive) child.deinit();
    const output = try invoke(&child, .picture, &.{});
    const group = try invoke(&child, .picture, &.{});
    const item = try invoke(&child, .append, &.{ group, try invoke(&child, .draw, &.{curve}) });
    const canvas = testing.testOwner(output);
    const owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(group.object.owner)));
    const item_owner: *Runtime.SceneOwner = @ptrCast(@alignCast(@constCast(item.object.owner)));
    const geometry = item_owner.scene.storage.segments.items.ptr;
    try Scene.placement.place(&canvas.scene, output.object.index, owner.scene.object(group.object.index), null);
    const unused = try invoke(&child, .picture, &.{});
    const unused_owner = testing.testOwner(unused);
    var expected = try Scene.ownership.storageClosure(&canvas.scene, a);
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
    try std.testing.expectEqual(canvas, testing.testOwner(result));
    const host = parent.host();
    try std.testing.expectEqual(group.object, (try host.field(parent.gpa, item, "parent")).object);
    var view = try Scene.snapshots.snapshot(&canvas.scene, a, output.object.index, null);
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
    var child = try parent.forkTask(.serial);
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
    var child = try parent.forkTask(.serial);
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
