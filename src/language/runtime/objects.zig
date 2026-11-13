//! Language-owned drawing storage and immutable render selections. Object
//! identity survives placement; selection borrows geometry and animation keys.
const std = @import("std");
const Scene = @import("../../drawing/Scene.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const AnimationState = @import("../AnimationState.zig");
const core_animation = @import("../../animation/root.zig");
const evaluate = @import("../../animation/evaluate.zig");
const Path = @import("../../drawing/path/Path.zig");

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
    try first.animation_state.animate(left, "opacity", keys, .linear, .{}, null);
    try second.animation_state.animate(right, "opacity", keys, .linear, .{}, null);
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

    /// A static, independently owned copy `seconds` into the timeline, as the
    /// SVG export plays it. It keeps the canvas size but no tracks. Typst
    /// groups have no opacity, so an opacity strictly between 0 and 1 needs a
    /// path with one solid paint.
    pub fn still(self: *const View, allocator: std.mem.Allocator, scratch: std.mem.Allocator, seconds: f64) !Scene {
        var copied = try self.snapshot.picture.copy(allocator);
        errdefer copied.deinit();
        // Commands become nodes in order; end markers are not nodes.
        const nodes = try scratch.alloc(Scene.Index, copied.commands.items.len);
        defer scratch.free(nodes);
        var count: Scene.Index = 0;
        for (copied.commands.items, nodes) |command, *node| {
            node.* = count;
            if (command != .pop) count += 1;
        }
        var scene = try Scene.fromDisplayList(&copied);
        errdefer scene.deinit();
        // A root wrapper, when added, precedes every converted command.
        const wrap = @as(Scene.Index, @intCast(scene.nodes.items.len)) - count;
        (try scene.settings(0)).* = .{ .size = self.settings.size };
        const timing = (try self.animation()) orelse return scene;
        try timing.validate();
        // Selection IDs are command positions plus one.
        const Locate = struct {
            fn node(map: []const Scene.Index, offset: Scene.Index, track: *const core_animation.Track) !Scene.Index {
                if (track.target == 0 or track.target > map.len) return error.InvalidAnimationTarget;
                return offset + map[@intCast(track.target - 1)];
            }
        };
        // Wrappers nest outermost first, so the innermost applies first.
        var remaining = self.tracks.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const track = &self.tracks.items[remaining];
            if (try evaluate.transform(scratch, track, try evaluate.time(timing, track, seconds))) |value| try scene.applyTransform(try Locate.node(nodes, wrap, track), value);
        }
        // Paints are set before the opacity that scales them.
        for (self.tracks.items) |*track| switch (track.property) {
            .fill, .stroke, .stroke_width, .path => try paintStill(&scene, scratch, try Locate.node(nodes, wrap, track), track, try evaluate.time(timing, track, seconds)),
            else => {},
        };
        for (self.tracks.items) |*track| if (track.property == .opacity) {
            try opacityStill(&scene, try Locate.node(nodes, wrap, track), evaluate.scalar(track.property.opacity, track.easing, try evaluate.time(timing, track, seconds)));
        };
        return scene;
    }
};

fn paintStill(scene: *Scene, scratch: std.mem.Allocator, index: Scene.Index, track: *const core_animation.Track, at: f64) !void {
    const target = try instancePath(scene, index);
    if (track.property == .path) {
        var shape = Path.init(scratch);
        defer shape.deinit();
        try evaluate.path(&shape, track.property.path, track.easing, at);
        return scene.setPath(target, &shape);
    }
    var style = (try scene.getNode(target)).path.style.*;
    switch (track.property) {
        .fill => |keys| {
            if (style.gradientFor(.fill) != null) style.gradient = null;
            style.fill = evaluate.color(keys, track.easing, at);
        },
        .stroke => |keys| {
            if (style.gradientFor(.stroke) != null) style.gradient = null;
            var pen = style.pen orelse return error.UnsupportedSnapshotStroke;
            pen.color = evaluate.color(keys, track.easing, at);
            style.pen = pen;
        },
        .stroke_width => |keys| {
            var pen = style.pen orelse return error.UnsupportedSnapshotStroke;
            pen.width = evaluate.scalar(keys, track.easing, at);
            style.pen = pen;
        },
        else => unreachable,
    }
    try scene.setStyle(target, &style);
}

/// The one path a paint track addresses: the target itself, or the only
/// drawable inside a target group, as the SVG export requires.
fn instancePath(scene: *const Scene, index: Scene.Index) !Scene.Index {
    if ((try scene.getNode(index)).* == .path) return index;
    var found: ?Scene.Index = null;
    if (!try onlyPath(scene, index, &found)) return error.AmbiguousPathTarget;
    return found orelse error.AmbiguousPathTarget;
}

fn onlyPath(scene: *const Scene, index: Scene.Index, found: *?Scene.Index) !bool {
    var children = try scene.children(index);
    while (children.next()) |child| switch ((try scene.getNode(child.index)).*) {
        .path => {
            if (found.* != null) return false;
            found.* = child.index;
        },
        .label => return false,
        .picture => if (!try onlyPath(scene, child.index, found)) return false,
    };
    return true;
}

/// Opacity 0 hides the object and 1 leaves it unchanged. Any other value
/// scales the single solid paint of a path, which equals group opacity there.
fn opacityStill(scene: *Scene, index: Scene.Index, value: f64) !void {
    if (value >= 1) return;
    if (value <= 0) return scene.setVisible(index, false);
    const node = try scene.getNode(index);
    if (node.* != .path) return error.UnsupportedSnapshotOpacity;
    var style = node.path.style.*;
    if (style.gradient != null or (style.fill == null) == (style.pen == null)) return error.UnsupportedSnapshotOpacity;
    if (style.fill) |fill| {
        style.fill.?.a = fill.a * value;
    } else {
        var pen = style.pen.?;
        pen.color.a *= value;
        style.pen = pen;
    }
    try scene.setStyle(index, &style);
}
