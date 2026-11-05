//! Language-owned drawing storage and immutable render selections. Object
//! identity survives placement; selection borrows geometry and animation keys.
const std = @import("std");
const Scene = @import("../../drawing/Scene.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const AnimationState = @import("../AnimationState.zig");
const core_animation = @import("../../animation/root.zig");

pub const Owner = struct {
    scene: Scene,
    owner_index: u32,
    animation_state: AnimationState,

    pub fn fromScene(scene: *const Scene) *Owner {
        return @fieldParentPtr("scene", @constCast(scene));
    }

    pub fn takeStorage(self: *Owner) Storage {
        const result: Storage = .{ .picture = self.scene.takeStorage(), .animation_state = self.animation_state };
        self.animation_state = .init(result.animation_state.arena.child_allocator);
        return result;
    }

    /// IDs are generated only for animated objects and are unique across stores.
    /// Worker adoption updates owner_index before any output is selected.
    pub fn identity(self: *const Owner, index: u32) u64 {
        return (@as(u64, self.owner_index) << 32) | (@as(u64, index) + 1);
    }

    pub fn hasGeometricStroke(self: *const Owner, index: Scene.Index) bool {
        return hasGeometricStrokeInSubtree(self.scene.object(index));
    }

    fn hasGeometricStrokeInSubtree(object_: Scene.Object) bool {
        const command = object_.scene.getNode(object_.index) catch return false;
        if (command.* == .path) {
            if (command.path.style.pen) |pen| if (pen.needsGeometry()) return true;
        }
        var children = object_.scene.children(object_.index) catch return false;
        while (children.next()) |child| if (hasGeometricStrokeInSubtree(child)) return true;
        return false;
    }

    pub fn validateTrack(self: *const Owner, track: core_animation.Track) !void {
        switch (track.property) {
            .path, .stroke_width, .stroke, .fill => {
                const index = std.math.cast(Scene.Index, track.target - 1) orelse return error.InvalidAnimationTarget;
                if (self.hasGeometricStroke(index)) return error.UnsupportedNibAnimation;
            },
            else => {},
        }
    }

    pub fn identifier(_: *const Owner, object_: Scene.Object) u64 {
        const owner = fromScene(object_.scene);
        const targets = owner.animation_state.targets.items;
        return if (object_.index < targets.len and targets[object_.index]) owner.identity(object_.index) else 0;
    }

    pub fn view(self: *Owner, allocator: std.mem.Allocator, index: Scene.Index) !View {
        return self.viewWithBounds(allocator, index, null);
    }

    pub fn viewWithBounds(self: *Owner, allocator: std.mem.Allocator, index: Scene.Index, labels: anytype) !View {
        const settings = (try self.scene.settings(index)).*;
        var result: View = .{
            .snapshot = try self.scene.snapshotWithBounds(allocator, index, self, labels),
            .settings = settings,
        };
        errdefer result.deinit();
        // Export IDs follow drawing order, independently of worker allocation
        // and storage pages. Object handles retain their own stable identity.
        var ids: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer ids.deinit(allocator);
        for (result.snapshot.ids.items, 0..) |*id, position| {
            if (id.* == 0) continue;
            const exported = position + 1;
            try ids.put(allocator, id.*, exported);
            id.* = exported;
        }
        for (result.snapshot.owners.keys()) |scene| {
            const owner = fromScene(scene);
            var tracks = owner.animation_state.iterator();
            while (tracks.next()) |track| {
                const local = std.math.cast(Scene.Index, track.target - 1) orelse return error.InvalidAnimationTarget;
                const target = ids.get(owner.identity(local)) orelse continue;
                try owner.validateTrack(track.*);
                var mapped = track.*;
                mapped.target = target;
                try result.tracks.append(allocator, mapped);
            }
        }
        return result;
    }
};

test "animation follows object placement across stores without ID collisions" {
    const t = std.testing;
    const types = @import("../types.zig");
    const Path = @import("../../drawing/path/Path.zig");
    var first: Owner = .{ .scene = try Scene.init(t.allocator), .owner_index = 0, .animation_state = .init(t.allocator) };
    defer first.scene.deinit();
    defer first.animation_state.deinit();
    var second: Owner = .{ .scene = try Scene.init(t.allocator), .owner_index = 1, .animation_state = .init(t.allocator) };
    defer second.scene.deinit();
    defer second.animation_state.deinit();
    var curve = try Path.circle(t.allocator, .zero, 5);
    defer curve.deinit();
    const left = try first.scene.addPath(0, &curve, &.{ .fill = .black }, .{});
    const right = try second.scene.addPath(0, &curve, &.{ .fill = .black }, .{});
    const keys: []const types.Value = &.{
        types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }),
    };
    try first.animation_state.animate(left, "opacity", keys, "linear", null);
    try second.animation_state.animate(right, "opacity", keys, "linear", null);
    (try first.scene.settings(0)).duration = 2;
    (try second.scene.settings(0)).* = .{ .duration = 3, .repeat = false };
    try first.scene.place(0, second.scene.object(right), null);
    {
        var selected = try first.view(t.allocator, 0);
        defer selected.deinit();
        const tracks = (try selected.animation()).?;
        try t.expectEqual(@as(usize, 2), tracks.tracks.len);
        try t.expect(tracks.tracks[0].target != tracks.tracks[1].target);
        try t.expectEqualSlices(u64, &.{ 0, 2, 3, 0 }, selected.snapshot.ids.items);
        try t.expectEqual(@as(f64, 2), tracks.duration_seconds);
    }
    try second.scene.remove(right);
    try second.scene.place(0, second.scene.object(right), null);
    var selected = try second.view(t.allocator, 0);
    defer selected.deinit();
    const tracks = (try selected.animation()).?;
    try t.expectEqual(@as(usize, 1), tracks.tracks.len);
    try t.expectEqual(@as(u64, 2), tracks.tracks[0].target);
    try t.expectEqual(@as(f64, 3), tracks.duration_seconds);
    try t.expect(!tracks.repeat);
}

/// A rendering job owns references to these allocations, never a mutable VM.
pub const Storage = struct {
    picture: @import("../../drawing/Storage.zig"),
    animation_state: AnimationState,

    pub fn deinit(self: *Storage) void {
        self.picture.deinit();
        self.animation_state.deinit();
        self.* = undefined;
    }
};

pub const View = struct {
    snapshot: Scene.Snapshot,
    tracks: std.ArrayList(core_animation.Track) = .empty,
    settings: Scene.Settings,

    pub fn deinit(self: *View) void {
        self.tracks.deinit(self.snapshot.picture.storage.allocator);
        self.snapshot.deinit();
        self.* = undefined;
    }

    /// Borrow the selected tracks. Validate them when preparing an output,
    /// before publication; reading an immutable view does not revalidate it.
    pub fn animation(self: *const View) !?core_animation.Animation {
        if (self.tracks.items.len == 0) return null;
        return .{
            .duration_seconds = self.settings.duration orelse return error.MissingTimeline,
            .repeat = self.settings.repeat,
            .tracks = self.tracks.items,
        };
    }
};
