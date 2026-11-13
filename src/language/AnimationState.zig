//! DSL values adapted to the existing typed animation engine. This module
//! retains key geometry and object identities; it never renders frame samples.
const std = @import("std");
const core = @import("../animation/root.zig");
const geometry = @import("../drawing/geometry.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const Path = @import("../drawing/path/Path.zig");
const types = @import("types.zig");
const Value = types.Value;
const units = @import("../drawing/units.zig");

const AnimationState = @This();

/// Tracks and keys are immutable and share their owner's lifetime.
arena: std.heap.ArenaAllocator,
tracks: std.SinglyLinkedList = .{},
last: ?*std.SinglyLinkedList.Node = null,
/// Membership of completed tracks, for constant-time export selection.
/// Object validity and identity belong to the caller's Scene.
targets: std.ArrayList(bool) = .empty,

const Entry = struct {
    node: std.SinglyLinkedList.Node = .{},
    track: core.Track,
};

pub const Iterator = struct {
    node: ?*const std.SinglyLinkedList.Node,

    pub fn next(self: *Iterator) ?*const core.Track {
        const node = self.node orelse return null;
        self.node = node.next;
        const entry: *const Entry = @alignCast(@fieldParentPtr("node", node));
        return &entry.track;
    }
};

pub fn iterator(self: *const AnimationState) Iterator {
    return .{ .node = self.tracks.first };
}

pub fn init(allocator: std.mem.Allocator) AnimationState {
    return .{ .arena = .init(allocator) };
}
pub fn deinit(self: *AnimationState) void {
    self.targets.deinit(self.arena.child_allocator);
    self.arena.deinit();
    self.* = undefined;
}

pub fn allocatedBytes(self: *const AnimationState) usize {
    return self.arena.queryCapacity() + self.targets.capacity * @sizeOf(bool);
}

/// index must already be validated by its Scene. Key times are normalized
/// to [0,1], exactly as in the native engine.
/// Values are immutable copies, so subsequent script objects cannot alter
/// an already declared animation track.
/// Per-track timing and SVG encoding beyond the keys and easing.
pub const Options = struct { phase: f64 = 0, smil: bool = false };

pub fn animate(self: *AnimationState, index: u32, property: []const u8, keys: []const Value, curve: core.Easing, options: Options, resolver: anytype) !void {
    try self.reserveTarget(index);
    const name = std.meta.stringToEnum(std.meta.Tag(core.Property), property) orelse return error.UnknownAnimationProperty;
    const typed: core.Property = switch (name) {
        .translate => .{ .translate = try self.parseKeys(geometry.Point, keys, resolver, .distance) },
        .scale => .{ .scale = try self.parseKeys(geometry.Point, keys, resolver, .scalar) },
        .rotate => .{ .rotate = .{ .keys = try self.parseKeys(f64, keys, resolver, .rotation) } },
        .opacity => .{ .opacity = try self.parseKeys(f64, keys, resolver, .scalar) },
        .stroke_width => .{ .stroke_width = try self.parseKeys(f64, keys, resolver, .distance) },
        .fill => .{ .fill = try self.parseKeys(DisplayList.Color, keys, resolver, .scalar) },
        .stroke => .{ .stroke = try self.parseKeys(DisplayList.Color, keys, resolver, .scalar) },
        .path => .{ .path = try self.parseKeys([]const Path.Segment, keys, resolver, .scalar) },
        .motion => return error.UseMotionBuiltin,
    };
    try self.add(index, typed, curve, options);
}

/// "linear", "discrete", or the four control values [x1, y1, x2, y2] of one
/// cubic easing curve shared by every key interval. The track validator
/// checks that each control value is finite and within [0, 1].
pub fn easing(value: Value) !core.Easing {
    if (value == .string) {
        if (std.mem.eql(u8, value.string, "linear")) return .linear;
        if (std.mem.eql(u8, value.string, "discrete")) return .discrete;
        return error.UnknownAnimationEasing;
    }
    const controls = types.sequence(value) orelse return error.UnknownAnimationEasing;
    if (controls.len != 4) return error.InvalidEasing;
    var spline: [4]f64 = undefined;
    for (controls, &spline) |control, *component| component.* = try numeric(control);
    return .{ .spline = .{ .x1 = spline[0], .y1 = spline[1], .x2 = spline[2], .y2 = spline[3] } };
}

pub fn motion(self: *AnimationState, index: u32, path: Value, keys: []const Value, rotate: []const u8, options: Options, resolver: anytype) !void {
    try self.reserveTarget(index);
    if (comptime @TypeOf(resolver) == @TypeOf(null)) return error.PathResolverRequired;
    const segments = try self.arena.allocator().dupe(Path.Segment, try resolver.animationPath(path));
    const rotation = std.meta.stringToEnum(@FieldType(core.Motion, "rotate"), rotate) orelse return error.UnknownMotionRotation;
    try self.add(index, .{ .motion = .{ .path = segments, .keys = try self.parseKeys(f64, keys, resolver, .scalar), .rotate = rotation } }, .linear, options);
}

fn reserveTarget(self: *AnimationState, index: u32) !void {
    if (index >= self.targets.items.len) try self.targets.appendNTimes(self.arena.child_allocator, false, @as(usize, index) + 1 - self.targets.items.len);
}

fn add(self: *AnimationState, index: u32, property: core.Property, curve: core.Easing, options: Options) !void {
    const track: core.Track = .{ .target = @as(u64, index) + 1, .property = property, .easing = curve, .phase = options.phase, .smil = options.smil };
    // Reuse the native validator for all timing, ranges, path grammar and
    // morph topology. Check the new track against already retained tracks
    // without revalidating their geometry on every declaration.
    try track.validateProperties();
    var previous_tracks = self.iterator();
    while (previous_tracks.next()) |previous| {
        if (previous.target == track.target and std.meta.activeTag(previous.property) == std.meta.activeTag(track.property)) return error.ConflictingTracks;
    }
    const entry = try self.arena.allocator().create(Entry);
    entry.* = .{ .track = track };
    if (self.last) |last| last.insertAfter(&entry.node) else self.tracks.prepend(&entry.node);
    self.last = &entry.node;
    self.targets.items[index] = true;
}
fn parseKeys(self: *AnimationState, comptime T: type, input: []const Value, resolver: anytype, comptime dimension: units.Dimension) ![]const core.Key(T) {
    const result = try self.arena.allocator().alloc(core.Key(T), input.len);
    for (input, result) |entry, *key| {
        const values = @import("types.zig").sequence(entry) orelse return error.InvalidAnimationKey;
        if (values.len != 2) return error.InvalidAnimationKey;
        const time = try numeric(values[0]);
        const raw = values[1];
        const value: T = if (T == f64) try dimensioned(raw, dimension) else if (T == geometry.Point) blk: {
            if (raw != .vec2) return error.AnimationKeyRequiresPair;
            if (dimension.eql(.distance)) break :blk try raw.vec2.nativePoint();
            if (!raw.vec2.dimension.eql(.scalar)) return error.DimensionMismatch;
            break :blk .{ .x = raw.vec2.x, .y = raw.vec2.y };
        } else if (T == DisplayList.Color) blk: {
            if (comptime @TypeOf(resolver) == @TypeOf(null)) return error.ColorResolverRequired;
            break :blk try resolver.animationColor(raw);
        } else if (T == []const Path.Segment) blk: {
            if (comptime @TypeOf(resolver) == @TypeOf(null)) return error.PathResolverRequired;
            break :blk try self.arena.allocator().dupe(Path.Segment, try resolver.animationPath(raw));
        } else @compileError("unsupported animation key type");
        key.* = .{ .time = time, .value = value };
    }
    return result;
}

fn numeric(value: Value) !f64 {
    const result = switch (value) {
        .int => |integer| @as(f64, @floatFromInt(integer)),
        .number => |number| number,
        else => return error.AnimationKeyRequiresNumber,
    };
    if (!std.math.isFinite(result)) return error.NonFinite;
    return result;
}
fn dimensioned(value: Value, dimension: units.Dimension) !f64 {
    if (value == .quantity) {
        if (!value.quantity.dimension.eql(dimension)) return error.DimensionMismatch;
        _ = try value.quantity.checked();
        return if (dimension.eql(.distance)) units.toPoints(value.quantity) else value.quantity.value;
    }
    return numeric(value);
}

test "animation adapter retains object indices and continuous keys" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const keys = [_]Value{
        types.listView(&.{ .{ .int = 0 }, .{ .vec2 = .zero } }),
        types.listView(&.{ .{ .number = 0.37 }, .{ .vec2 = .{ .x = 10, .y = 20 } } }),
        types.listView(&.{ .{ .int = 1 }, .{ .vec2 = .{ .x = 30, .y = 40 } } }),
    };
    try state.animate(0, "translate", &keys, .linear, .{}, null);
    const tracks = try testTracks(&state, 1);
    const animation: core.Animation = .{ .duration_seconds = 2.5, .repeat = false, .tracks = &tracks };
    try animation.validate();
    try std.testing.expectEqual(@as(f64, 2.5), animation.duration_seconds);
    try std.testing.expect(!animation.repeat);
    try std.testing.expectEqual(@as(f64, 0.37), animation.tracks[0].property.translate[1].time);
}

test "only completed tracks select sparse targets for export" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const keys = &.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) };
    try std.testing.expectError(error.UnknownAnimationProperty, state.animate(256, "unknown", keys, .linear, .{}, null));
    for (state.targets.items) |target| try std.testing.expect(!target);
    try state.animate(0, "opacity", keys, .linear, .{}, null);
    try state.animate(256, "opacity", keys, .linear, .{}, null);
    const tracks = try testTracks(&state, 2);
    try std.testing.expectEqual(@as(u64, 1), tracks[0].target);
    try std.testing.expectEqual(@as(u64, 257), tracks[1].target);
    try std.testing.expect(state.targets.items[0] and state.targets.items[256]);
    for (state.targets.items[1..256]) |target| try std.testing.expect(!target);
    try std.testing.expectError(error.ConflictingTracks, state.animate(0, "opacity", keys, .linear, .{}, null));
    try std.testing.expectEqual(@as(usize, 2), state.tracks.len());
}

test "animation keys convert geometry units and reject dimensions on scale and time" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const id: u32 = 0;
    const translated: Value = .{ .vec2 = .{ .x = 10, .y = 0, .dimension = .distance } };
    const points = [_]Value{
        types.listView(&.{ .{ .int = 0 }, .{ .vec2 = .zero } }),
        types.listView(&.{ .{ .int = 1 }, translated }),
    };
    try state.animate(id, "translate", &points, .linear, .{}, null);
    try std.testing.expectApproxEqAbs(@as(f64, 720.0 / 25.4), (try testTracks(&state, 1))[0].property.translate[1].value.x, 1e-12);
    const turn: Value = .{ .quantity = try units.applyUnit(360, .deg) };
    try state.animate(id, "rotate", &.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, turn }) }, .linear, .{}, null);
    try std.testing.expectEqual(@as(f64, 2 * std.math.pi), (try testTracks(&state, 2))[1].property.rotate.keys[1].value);
    const width: Value = .{ .quantity = try units.applyUnit(2, .mm) };
    try state.animate(id, "stroke_width", &.{ types.listView(&.{ .{ .int = 0 }, width }), types.listView(&.{ .{ .int = 1 }, width }) }, .linear, .{}, null);
    try std.testing.expectApproxEqAbs(@as(f64, 144.0 / 25.4), (try testTracks(&state, 3))[2].property.stroke_width[0].value, 1e-12);
    try std.testing.expectError(error.DimensionMismatch, state.animate(id, "scale", &points, .linear, .{}, null));
    try std.testing.expectError(error.AnimationKeyRequiresNumber, state.animate(id, "opacity", &.{types.listView(&.{ width, .{ .int = 0 } })}, .linear, .{}, null));
}

const TestResolver = struct {
    segments: []const Path.Segment,
    pub fn animationPath(self: *TestResolver, value: Value) ![]const Path.Segment {
        if (value != .handle or value.handle.kind != .path) return error.InvalidPathHandle;
        return self.segments;
    }
    pub fn animationColor(_: *TestResolver, value: Value) !DisplayList.Color {
        if (value != .handle or value.handle.kind != .color) return error.InvalidColorHandle;
        return if (value.handle.index == 0) .{ .r = 1 } else .{ .b = 1 };
    }
};

test "native paths and colors are copied into the animation owner" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const id: u32 = 0;
    var segments = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    var context: TestResolver = .{ .segments = &segments };
    const path: Value = .{ .handle = .{ .kind = .path, .index = 0 } };
    try state.animate(id, "path", &.{ types.listView(&.{ .{ .int = 0 }, path }), types.listView(&.{ .{ .int = 1 }, path }) }, .linear, .{}, &context);
    try state.animate(id, "fill", &.{
        types.listView(&.{ .{ .int = 0 }, .{ .handle = .{ .kind = .color, .index = 0 } } }),
        types.listView(&.{ .{ .int = 1 }, .{ .handle = .{ .kind = .color, .index = 1 } } }),
    }, .discrete, .{ .phase = -0.5, .smil = true }, &context);
    segments[1].line.x = 99;
    const tracks = try testTracks(&state, 2);
    const animation: core.Animation = .{ .duration_seconds = 1, .repeat = true, .tracks = &tracks };
    try animation.validate();
    try std.testing.expectEqual(@as(f64, 10), animation.tracks[0].property.path[0].value[1].line.x);
    try std.testing.expectEqual(@as(f64, 1), animation.tracks[1].property.fill[0].value.r);
    try std.testing.expectEqual(@as(f64, 1), animation.tracks[1].property.fill[1].value.b);
    try std.testing.expectEqual(@as(f64, -0.5), animation.tracks[1].phase);
    try std.testing.expect(animation.tracks[1].smil and !animation.tracks[0].smil);
}

test "native animation validation diagnoses malformed keys ranges and conflicts" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const id: u32 = 0;
    const keys = &.{ types.listView(&.{ .{ .int = 0 }, .{ .number = 0.25 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) };
    try std.testing.expectError(error.UnknownAnimationProperty, state.animate(id, "unknown", keys, .linear, .{}, null));
    try std.testing.expectError(error.UnknownAnimationEasing, easing(.{ .string = "cubic" }));
    try std.testing.expectError(error.InvalidEasing, easing(types.listView(&.{ .{ .number = 0.3 }, .{ .int = 0 }, .{ .number = 0.7 } })));
    try std.testing.expectError(error.NonFinite, easing(types.listView(&.{ .{ .number = std.math.nan(f64) }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } })));
    // Out-of-range control values are rejected by the shared track validator.
    try std.testing.expectError(error.InvalidEasing, state.animate(id, "opacity", keys, try easing(types.listView(&.{ .{ .number = 1.5 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } })), .{}, null));
    const spline = try easing(types.listView(&.{ .{ .number = 0.25 }, .{ .number = 0.1 }, .{ .number = 0.25 }, .{ .int = 1 } }));
    try std.testing.expectEqual(core.Spline{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1 }, spline.spline);
    try std.testing.expectError(error.InvalidAnimationKey, state.animate(id, "opacity", &.{.{ .int = 1 }}, .linear, .{}, null));
    try std.testing.expectError(error.InvalidOpacity, state.animate(id, "opacity", &.{ types.listView(&.{ .{ .int = 0 }, .{ .int = -1 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) }, .linear, .{}, null));
    try state.animate(id, "opacity", keys, .linear, .{}, null);
    try std.testing.expectError(error.ConflictingTracks, state.animate(id, "opacity", keys, .linear, .{}, null));
    const tracks = try testTracks(&state, 1);
    try std.testing.expectError(error.InvalidTiming, (core.Animation{ .duration_seconds = 0, .tracks = &tracks }).validate());
}

test "motion uses the existing path and arc length motion representation" {
    var state = AnimationState.init(std.testing.allocator);
    defer state.deinit();
    const id: u32 = 0;
    const segments = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 100, .y = 20 } } };
    var context: TestResolver = .{ .segments = &segments };
    try state.motion(id, .{ .handle = .{ .kind = .path, .index = 0 } }, &.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) }, "auto_reverse", .{ .phase = 0.25 }, &context);
    const tracks = try testTracks(&state, 1);
    const animation: core.Animation = .{ .duration_seconds = 3, .repeat = true, .tracks = &tracks };
    try animation.validate();
    try std.testing.expectEqual(@as(@FieldType(core.Motion, "rotate"), .auto_reverse), animation.tracks[0].property.motion.rotate);
    try std.testing.expectEqual(@as(f64, 0.25), animation.tracks[0].phase);
    try std.testing.expectError(error.InvalidPhase, state.motion(1, .{ .handle = .{ .kind = .path, .index = 0 } }, &.{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) }, "auto", .{ .phase = 1.5 }, &context));
}

fn growingState(allocator: std.mem.Allocator) !void {
    var state = AnimationState.init(allocator);
    defer state.deinit();
    const count = 257;
    const keys = [_]Value{ types.listView(&.{ .{ .int = 0 }, .{ .int = 0 } }), types.listView(&.{ .{ .int = 1 }, .{ .int = 1 } }) };
    for (0..count) |i| {
        state.animate(@intCast(i), "opacity", &keys, .linear, .{}, null) catch |err| {
            try std.testing.expectEqual(i, state.tracks.len());
            if (i < state.targets.items.len) try std.testing.expect(!state.targets.items[i]);
            var completed = state.iterator();
            while (completed.next()) |track| try (core.Animation{ .duration_seconds = 2, .tracks = &.{track.*} }).validate();
            return err;
        };
    }
    const tracks = try testTracks(&state, count);
    const animation: core.Animation = .{ .duration_seconds = 2, .tracks = &tracks };
    try animation.validate();
    try std.testing.expectEqual(count, animation.tracks.len);
    for (animation.tracks, 0..) |track, i| {
        try std.testing.expectEqual(@as(u64, i + 1), track.target);
        try std.testing.expectEqual(@as(f64, 1), track.property.opacity[1].value);
    }
}

test "growing animation tables preserve completed tracks and release every partial allocation" {
    try growingState(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), growingState, .{});
}

fn testTracks(state: *const AnimationState, comptime count: usize) ![count]core.Track {
    var result: [count]core.Track = undefined;
    var tracks = state.iterator();
    for (&result) |*track| track.* = (tracks.next() orelse return error.TestUnexpectedResult).*;
    try std.testing.expect(tracks.next() == null);
    return result;
}
