//! Builtins for timelines, animation tracks and snapshots.
const std = @import("std");
const typst = @import("libtypst");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const AnimationState = @import("../AnimationState.zig");
const renderer = @import("../../render/root.zig");
const testOwner = @import("testing.zig").testOwner;
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const object_handles = @import("object_handles.zig");
const builtin_calls = @import("builtin_calls.zig");
const conversions = @import("conversions.zig");
const numeric = conversions.numeric;
const boolean = conversions.boolean;
const string = conversions.string;
const sequence = conversions.sequence;

/// Timelines, animation tracks and snapshots.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .timeline => {
            const target = try object_handles.objectValue(self, arg.target, true);
            const settings = try target.owner.scene.settings(target.index);
            const duration = try numeric(arg.duration);
            const repeat = if (arg.repeat) |value| try boolean(value) else true;
            try (@import("../../animation/root.zig").Animation{ .duration_seconds = duration, .repeat = repeat, .tracks = &.{} }).validate();
            settings.duration = duration;
            settings.repeat = repeat;
            return .unit;
        },
        .animate, .motion => {
            const instance = try object_handles.objectValue(self, arg.object, true);
            const target = instance.owner;
            const options: AnimationState.Options = .{
                .phase = if (arg.phase) |value| try numeric(value) else 0,
                .smil = if (arg.smil) |value| try boolean(value) else false,
            };
            if (id == .animate) {
                const property = try string(arg.property);
                if ((std.mem.eql(u8, property, "path") or std.mem.eql(u8, property, "stroke_width") or std.mem.eql(u8, property, "stroke") or std.mem.eql(u8, property, "fill")) and target.hasResolvedStroke(instance.index)) return error.UnsupportedResolvedStrokeAnimation;
                const curve: @import("../../animation/root.zig").Easing = if (arg.easing) |value| try AnimationState.easing(value) else .linear;
                try target.animation_state.animate(instance.index, property, try sequence(arg.keys), curve, options, self);
            } else {
                try target.animation_state.motion(instance.index, arg.curve, try sequence(arg.keys), if (arg.rotate) |value| try string(value) else "auto", options, self);
            }
            return .unit;
        },
        .animation_snapshot => {
            const target = try object_handles.objectValue(self, arg.target, false);
            var selected = try target.owner.viewWithBounds(self.gpa, target.index, renderer.FrameBounds{ .frames = self.frames.items });
            defer selected.deinit();
            const still = selected.still(self.scene_allocator, self.gpa, try numeric(arg.time)) catch |err| {
                self.native_message = switch (err) {
                    error.UnsupportedSnapshotStroke => "a snapshot of a stroke or stroke width animation needs a path that already has a stroke",
                    else => return err,
                };
                return err;
            };
            return object_handles.sceneResult(self, still, 0);
        },
        else => comptime unreachable,
    }
}

test "explicit nib animations preserve transform tracks and reject unnormalized stroke tracks" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const path_value = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const nib = try builtin_calls.invoke(&runtime, a, .pencircle, &.{.{ .int = 3 }});
    const id = try builtin_calls.invoke(&runtime, a, .append, &.{ picture, try builtin_calls.invoke(&runtime, a, .draw, &.{ path_value, nib }) });
    const scalar_keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) });
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .animate, &.{ id, .{ .string = "stroke_width" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .animate, &.{ id, .{ .string = "path" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .animate, &.{ id, .{ .string = "stroke" }, scalar_keys }));
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .animate, &.{ id, .{ .string = "fill" }, scalar_keys }));
    const target = (try object_handles.objectValue(&runtime, id, false)).owner;
    try std.testing.expectEqual(@as(usize, 0), target.animation_state.tracks.len());
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ id, .{ .string = "opacity" }, scalar_keys });
    try std.testing.expectEqual(@as(usize, 1), target.animation_state.tracks.len());
    const group = try builtin_calls.invoke(&runtime, a, .append, &.{ picture, try builtin_calls.invoke(&runtime, a, .picture, &.{}), try builtin_calls.invoke(&runtime, a, .scale, &.{.{ .int = 1 }}) });
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ group, try builtin_calls.invoke(&runtime, a, .draw, &.{ path_value, nib }) });

    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .animate, &.{ group, .{ .string = "stroke_width" }, scalar_keys }));
}

test "animated ancestors constrain placed subtrees and style changes without rejecting transform tracks" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const picture = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    const transform = try builtin_calls.invoke(&runtime, a, .scale, &.{.{ .int = 1 }});
    const group = try builtin_calls.invoke(&runtime, a, .append, &.{ picture, try builtin_calls.invoke(&runtime, a, .picture, &.{}), transform });
    const keys = types.listView(&.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 1 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 2 } }) });
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ group, .{ .string = "stroke_width" }, keys });
    const path_value = try builtin_calls.invoke(&runtime, a, .path, &.{ .{ .vec2 = .zero }, .{ .vec2 = .{ .x = 10, .y = 10 } } });
    const nib = try builtin_calls.invoke(&runtime, a, .pensquare, &.{.{ .int = 3 }});
    const ordinary = try builtin_calls.invoke(&runtime, a, .append, &.{ group, try builtin_calls.invoke(&runtime, a, .draw, &.{path_value}) });
    const scene = &(try object_handles.objectValue(&runtime, ordinary, false)).owner.scene;
    const previous = (try scene.getNode(ordinary.object.index)).path.style;
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .object_style, &.{ ordinary, .omitted, nib }));
    try std.testing.expectEqualDeep(previous, (try scene.getNode(ordinary.object.index)).path.style);
    const rejected = try builtin_calls.invoke(&runtime, a, .draw, &.{ path_value, nib });
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .append, &.{ group, rejected }));
    const target = (try object_handles.objectValue(&runtime, group, false)).owner;
    try std.testing.expectEqual(@as(usize, 1), target.animation_state.tracks.len());

    try std.testing.expect((try (try object_handles.objectValue(&runtime, rejected, false)).owner.scene.parentObject(rejected.object.index)) == null);
    const nested = try builtin_calls.invoke(&runtime, a, .append, &.{ group, try builtin_calls.invoke(&runtime, a, .picture, &.{}) });
    const source = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ source, rejected });
    try std.testing.expectError(error.UnsupportedResolvedStrokeAnimation, builtin_calls.invoke(&runtime, a, .append, &.{ nested, source }));
    try std.testing.expect((try testOwner(source).scene.parentObject(source.object.index)) == null);
    try std.testing.expect((try testOwner(rejected).scene.parentObject(rejected.object.index)).?.eql(testOwner(source).scene.object(source.object.index)));
    const moving = try builtin_calls.invoke(&runtime, a, .picture, &.{});
    _ = try builtin_calls.invoke(&runtime, a, .animate, &.{ moving, .{ .string = "rotate" }, keys });
    _ = try builtin_calls.invoke(&runtime, a, .append, &.{ moving, source });
    try std.testing.expect((try testOwner(source).scene.parentObject(source.object.index)).?.eql(testOwner(moving).scene.object(moving.object.index)));
    try std.testing.expect(testOwner(source).hasResolvedStroke(source.object.index));
    var selected = try target.view(a, group.object.index);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 1), selected.tracks.items.len);
}
