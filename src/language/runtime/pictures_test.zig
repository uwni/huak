//! Tests of pictures: dimensions, children and aliases, placement across canvases, clips and allocation failure.
const std = @import("std");
const typst = @import("libtypst");
const types = @import("../types.zig");
const testOwner = @import("testing.zig").testOwner;
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const builtin_calls = @import("builtin_calls.zig");
const object_handles = @import("object_handles.zig");
const transforms = @import("transforms.zig");
const conversions = @import("conversions.zig");
const lengthPoints = conversions.lengthPoints;

test "pictures keep dimensions children and stable aliases independent" {
    const a = std.testing.allocator;
    // These operations use only the Zig engine and never access native code.
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const first = try builtin_calls.invoke(&runtime, a, .picture, &.{ .{ .int = 640 }, .{ .int = 480 } });
    const second = try builtin_calls.invoke(&runtime, a, .picture, &.{ .{ .int = 200 }, .{ .int = 100 } });
    const host_value = runtime.host();
    try std.testing.expectEqual(@as(f64, 640), try lengthPoints(try host_value.field(a, first, "width")));
    try std.testing.expectEqual(@as(f64, 480), try lengthPoints(try host_value.field(a, first, "height")));
    _ = try builtin_calls.invoke(&runtime, a, .timeline, &.{ first, .{ .number = 2 } });
    try std.testing.expect(!(try host_value.field(a, first, "animated")).boolean);
    try std.testing.expectError(error.UnknownField, host_value.field(a, first, "baseline"));
    try std.testing.expectError(error.UnknownField, host_value.field(a, first, "root"));
    try std.testing.expect(runtime.engine == null);
    const first_target = testOwner(first);
    try std.testing.expectEqual(@as(f64, 640), (try first_target.scene.settings(first.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 480), (try first_target.scene.settings(first.object.index)).size.?.y);
    _ = try builtin_calls.invoke(&runtime, a, .canvas, &.{ second, .{ .int = 300 }, .{ .int = 150 } });
    try std.testing.expectEqual(@as(f64, 300), (try testOwner(second).scene.settings(second.object.index)).size.?.x);
    try std.testing.expectEqual(@as(f64, 640), (try first_target.scene.settings(first.object.index)).size.?.x);
    const curve = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    // Opacity belongs to a picture and makes it one layer.
    _ = try builtin_calls.invoke(&runtime, a, .object_opacity, &.{ second, .{ .number = 0.25 } });
    try std.testing.expectEqual(@as(f64, 0.25), (try testOwner(second).scene.getNode(second.object.index)).picture.opacity);
    try std.testing.expectEqual(@as(f64, 1), (try first_target.scene.getNode(first.object.index)).picture.opacity);
    try std.testing.expectError(error.InvalidStyle, builtin_calls.invoke(&runtime, a, .object_opacity, &.{ second, .{ .number = 1.5 } }));
    try std.testing.expectEqualStrings("a picture's opacity runs from 0 to 1", runtime.native_message);
    try std.testing.expectError(error.ExpectedPicture, builtin_calls.invoke(&runtime, a, .object_opacity, &.{ try builtin_calls.invoke(&runtime, a, .draw, &.{curve}), .{ .number = 0.5 } }));
    const first_object = try builtin_calls.invoke(&runtime, a, .append, &.{ first, try builtin_calls.invoke(&runtime, a, .draw, &.{curve}) });
    const alias = first;
    const second_object = try builtin_calls.invoke(&runtime, a, .append, &.{ alias, try builtin_calls.invoke(&runtime, a, .draw, &.{curve}) });
    try std.testing.expect(!std.meta.eql(first_object.object, second_object.object));
    try std.testing.expectEqual(@as(usize, 0), first_target.animation_state.targets.items.len);
    try std.testing.expectEqual(@as(usize, 3), try testChildCount(first) + 1);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(second));
    // Growing the owner table cannot move a target that is already borrowed.
    for (0..100) |_| _ = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    try std.testing.expectEqual(first_target, testOwner(first));
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ first, try builtin_calls.invoke(&runtime, a, .draw, &.{curve}) });
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ first_object, .{ .string = "opacity" }, keys });
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ second_object, .{ .string = "opacity" }, keys });
    const state = &(try object_handles.objectValue(&runtime, first_object, false)).owner.animation_state;
    var tracks = state.iterator();
    try std.testing.expectEqual(@as(u64, first_object.object.index + 1), tracks.next().?.target);
    try std.testing.expectEqual(@as(u64, second_object.object.index + 1), tracks.next().?.target);
    try std.testing.expectError(error.ConflictingTracks, builtin_calls.invoke(&runtime, a, .animate, &.{ first_object, .{ .string = "opacity" }, keys }));
    const invalid: Value = .{ .object = .{ .owner = first_target, .index = 999 } };
    // Target validation precedes malformed property/path and key diagnostics.
    try std.testing.expectError(error.InvalidObject, builtin_calls.invoke(&runtime, a, .animate, &.{ invalid, .{ .int = 0 }, .{ .int = 0 } }));
    try std.testing.expectError(error.InvalidObject, builtin_calls.invoke(&runtime, a, .motion, &.{ invalid, .{ .int = 0 }, .{ .int = 0 } }));
    try std.testing.expectEqual(@as(usize, 4), try testChildCount(first) + 1);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(second));
    try std.testing.expectError(error.InvalidCanvas, builtin_calls.invoke(&runtime, a, .picture, &.{.{ .int = 0 }}));
    try std.testing.expectError(error.TypeMismatch, builtin_calls.invoke(&runtime, a, .append, &.{ curve, try builtin_calls.invoke(&runtime, a, .draw, &.{curve}) }));
    try std.testing.expectError(error.ExpectedPicture, builtin_calls.invoke(&runtime, a, .append, &.{ first_object, second_object }));
    try std.testing.expectError(error.TypeMismatch, runtime.render(curve, .svg));
    try std.testing.expectError(error.ExpectedPicture, runtime.render(first_object, .svg));
}

test "object placement preserves handles geometry and animation across canvases" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const first = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const second = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const curve = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const item = try builtin_calls.invoke(&runtime, a, .draw, &.{curve});
    const instance = try object_handles.objectValue(&runtime, item, false);
    const geometry = instance.owner.scene.storage.segments.items.ptr;
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ item, .{ .string = "opacity" }, keys });
    _ = try builtin_calls.invoke(&runtime, a, .timeline, &.{ first, .{ .int = 2 } });
    _ = try builtin_calls.invoke(&runtime, a, .timeline, &.{ second, .{ .int = 3 } });
    try std.testing.expectEqualDeep(item, try builtin_calls.invoke(&runtime, a, .append, &.{ first, item }));
    try std.testing.expectEqualDeep(item, try builtin_calls.invoke(&runtime, a, .append, &.{ first, item }));
    try std.testing.expectEqual(@as(usize, 1), try testChildCount(first));
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ second, item });
    try std.testing.expectEqual(geometry, instance.owner.scene.storage.segments.items.ptr);
    try std.testing.expectEqual(@as(usize, 0), try testChildCount(first));
    var old = try testOwner(first).view(a, first.object.index);
    defer old.deinit();
    var moved = try testOwner(second).view(a, second.object.index);
    defer moved.deinit();
    try std.testing.expectEqual(@as(usize, 0), old.tracks.items.len);
    try std.testing.expectEqual(@as(usize, 1), moved.tracks.items.len);
    try std.testing.expectEqual(@as(f64, 3), (try moved.animation()).?.duration_seconds);
}

fn testChildCount(value: Value) !usize {
    var children = try testOwner(value).scene.children(value.object.index);
    var count: usize = 0;
    while (children.next() != null) count += 1;
    return count;
}

fn pictureAllocationScenario(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var scene_allocator = std.testing.FailingAllocator.init(a, .{});
    defer std.debug.assert(scene_allocator.allocated_bytes == scene_allocator.freed_bytes);
    var runtime = try Runtime.init(a, scene_allocator.allocator(), &unused_library, .{});
    defer runtime.deinit();
    const first = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const second = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const curve = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 20, .y = 10 } } });
    for (0..5) |_| {
        _ = try builtin_calls.invoke(&runtime, a, .append, &.{ first, try builtin_calls.invoke(&runtime, a, .draw, &.{curve}) });
    }
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ second, first });
    const transform = try transforms.transformResult(&runtime, .translation(4, 7), 1);
    _ = try builtin_calls.invoke(&runtime, a, .transformed, &.{ first, transform });
    _ = try builtin_calls.invoke(&runtime, a, .snapshot, &.{first});
    const clip = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 10 }, .{ .int = 10 } });
    _ = try builtin_calls.invoke(&runtime, a, .object_clip, &.{ first, clip });
    _ = try builtin_calls.invoke(&runtime, a, .object_reset_clip, &.{first});
    try std.testing.expectEqual(@as(usize, 5), try testChildCount(first));
}

test "clip intersects the root scope and reset clears every accumulated path" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const left = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 10 }, .{ .int = 20 } });
    const top = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .int = 20 }, .{ .int = 10 } });
    const outside = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .{ .x = 100, .y = 100 } }, .{ .int = 10 }, .{ .int = 10 } });
    const owner = testOwner(picture);
    const node = try owner.scene.getNode(picture.object.index);

    _ = try builtin_calls.invoke(&runtime, a, .object_clip, &.{ picture, left });
    try std.testing.expect(node.picture.clip != null);
    const first_count = node.picture.clip.?.count;
    try std.testing.expect(first_count != 0);

    _ = try builtin_calls.invoke(&runtime, a, .object_clip, &.{ picture, top });
    try std.testing.expect(node.picture.clip != null);
    try std.testing.expect(node.picture.clip.?.count != 0);

    _ = try builtin_calls.invoke(&runtime, a, .object_reset_clip, &.{picture});
    try std.testing.expect(node.picture.clip == null);

    _ = try builtin_calls.invoke(&runtime, a, .object_clip, &.{ picture, outside });
    _ = try builtin_calls.invoke(&runtime, a, .object_clip, &.{ picture, left });
    try std.testing.expect(node.picture.clip != null);
    try std.testing.expectEqual(@as(usize, 0), node.picture.clip.?.count);

    _ = try builtin_calls.invoke(&runtime, a, .object_reset_clip, &.{picture});
    try std.testing.expect(node.picture.clip == null);
}

test "picture owners release all resources when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pictureAllocationScenario, .{});
}
