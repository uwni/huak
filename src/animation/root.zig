//! Borrowed, renderer-independent animation tracks. Times are normalized to
//! [0, 1]; lengths and angles use the geometry core's units and radians.
const std = @import("std");
const g = @import("../drawing/geometry.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const Path = @import("../drawing/path/Path.zig");

pub fn Key(comptime T: type) type {
    return struct { time: f64, value: T };
}
pub const ScalarKey = Key(f64);
pub const PointKey = Key(g.Point);
pub const ColorKey = Key(DisplayList.Color);
pub const PathKey = Key([]const Path.Segment);
pub const Spline = struct { x1: f64, y1: f64, x2: f64, y2: f64 };
pub const Easing = union(enum) { linear, discrete, spline: Spline };
pub const Rotation = struct { center: g.Point = .zero, keys: []const ScalarKey };
pub const Motion = struct {
    path: []const Path.Segment,
    rotate: enum { none, auto, auto_reverse } = .none,
    /// Fractions of motion path length, not Bezier curve parameter values.
    keys: []const ScalarKey = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } },
};
pub const Property = union(enum) {
    translate: []const PointKey,
    rotate: Rotation,
    scale: []const PointKey,
    opacity: []const ScalarKey,
    fill: []const ColorKey,
    stroke: []const ColorKey,
    stroke_width: []const ScalarKey,
    path: []const PathKey,
    motion: Motion,
};
pub const Track = struct {
    target: u64,
    property: Property,
    easing: Easing = .linear,

    /// Validate easing and keyframe values after collection-level target checks.
    pub fn validateProperties(self: *const Track) Error!void {
        if (self.easing == .spline) {
            const s = self.easing.spline;
            for ([_]f64{ s.x1, s.y1, s.x2, s.y2 }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidEasing;
        }
        switch (self.property) {
            .translate, .scale => |keys| {
                try times(g.Point, keys);
                for (keys) |key| if (!key.value.isFinite()) return error.NonFinite;
            },
            .rotate => |rotation| {
                if (!rotation.center.isFinite()) return error.NonFinite;
                try scalars(rotation.keys);
            },
            .opacity => |keys| {
                try scalars(keys);
                for (keys) |key| if (key.value < 0 or key.value > 1) return error.InvalidOpacity;
            },
            .stroke_width => |keys| {
                try scalars(keys);
                for (keys) |key| if (key.value < 0) return error.InvalidWidth;
            },
            .fill, .stroke => |keys| {
                try times(DisplayList.Color, keys);
                for (keys) |key| if (!key.value.valid()) return error.InvalidColor;
            },
            .path => |keys| {
                try times([]const Path.Segment, keys);
                for (keys) |key| {
                    try path(key.value);
                    if (!sameTopology(keys[0].value, key.value)) return error.IncompatiblePaths;
                }
            },
            .motion => |motion| {
                try path(motion.path);
                try scalars(motion.keys);
                for (motion.keys) |key| if (key.value < 0 or key.value > 1) return error.InvalidMotion;
            },
        }
    }
};
pub const Animation = struct {
    duration_seconds: f64,
    repeat: bool = true,
    /// For one target, transform tracks compose from outer to inner in this
    /// array's order. A property may occur only once per target.
    tracks: []const Track,

    pub fn validate(self: Animation) Error!void {
        try self.validateTiming();
        for (self.tracks, 0..) |*track, index| {
            if (track.target == 0) return error.InvalidTarget;
            for (self.tracks[0..index]) |*previous| {
                if (previous.target == track.target and std.meta.activeTag(previous.property) == std.meta.activeTag(track.property))
                    return error.ConflictingTracks;
            }
            try track.validateProperties();
        }
    }

    pub fn validateTiming(self: Animation) Error!void {
        if (!std.math.isFinite(self.duration_seconds) or self.duration_seconds <= 0) return error.InvalidTiming;
    }
};

pub const Error = error{
    InvalidTiming,
    InvalidTarget,
    InvalidKeys,
    InvalidEasing,
    ConflictingTracks,
    NonFinite,
    InvalidOpacity,
    InvalidWidth,
    InvalidColor,
    InvalidMotion,
    InvalidPath,
    IncompatiblePaths,
};

fn times(comptime T: type, keys: []const Key(T)) Error!void {
    if (keys.len < 2 or keys[0].time != 0 or keys[keys.len - 1].time != 1) return error.InvalidKeys;
    for (keys, 0..) |key, index| {
        if (!std.math.isFinite(key.time) or key.time < 0 or key.time > 1) return error.InvalidKeys;
        if (index > 0 and keys[index - 1].time >= key.time) return error.InvalidKeys;
    }
}
fn scalars(keys: []const ScalarKey) Error!void {
    try times(f64, keys);
    for (keys) |key| if (!std.math.isFinite(key.value)) return error.NonFinite;
}
fn path(segments: []const Path.Segment) Error!void {
    if (segments.len == 0 or segments[0] != .move) return error.InvalidPath;
    var active = false;
    for (segments) |segment| switch (segment) {
        .move => |point| {
            if (!point.isFinite()) return error.NonFinite;
            active = true;
        },
        .line => |point| {
            if (!active or !point.isFinite()) return error.InvalidPath;
        },
        .cubic => |curve| {
            if (!active or !curve.c1.isFinite() or !curve.c2.isFinite() or !curve.end.isFinite()) return error.InvalidPath;
        },
        .close => {
            if (!active) return error.InvalidPath;
            active = false;
        },
    };
}
pub fn sameTopology(a: []const Path.Segment, b: []const Path.Segment) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return true;
}

test "animation retains typed object tracks with continuous times and radian angles" {
    const tracks = [_]Track{
        .{ .target = 1, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 100, .y = 30 } } } } },
        .{ .target = 1, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } }, .easing = .{ .spline = .{ .x1 = 0.4, .y1 = 0, .x2 = 0.6, .y2 = 1 } } },
    };
    try (Animation{ .duration_seconds = 2, .tracks = &tracks }).validate();
}

test "invalid keys conflicts opacity easing and path topology fail explicitly" {
    var track: Track = .{ .target = 1, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } };
    var animation: Animation = .{ .duration_seconds = 2, .tracks = &.{track} };
    try animation.validate();
    animation.tracks = &.{ track, track };
    try std.testing.expectError(error.ConflictingTracks, animation.validate());
    track.property.opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 } };
    animation.tracks = &.{track};
    try std.testing.expectError(error.InvalidKeys, animation.validate());
    track.property.opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 2 } };
    animation.tracks = &.{track};
    try std.testing.expectError(error.InvalidOpacity, animation.validate());
    const a = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 5, .y = 5 } } };
    const b = [_]Path.Segment{ .{ .move = .zero }, .{ .cubic = .{ .c1 = .zero, .c2 = .zero, .end = .{ .x = 5, .y = 5 } } } };
    animation.tracks = &.{.{ .target = 2, .property = .{ .path = &.{ .{ .time = 0, .value = &a }, .{ .time = 1, .value = &b } } } }};
    try std.testing.expectError(error.IncompatiblePaths, animation.validate());
}

fn expectValidationError(expected: Error, animation: Animation) !void {
    try std.testing.expectError(expected, animation.validate());
}

test "animation validation preserves diagnostic source order" {
    const valid: Track = .{ .target = 1, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } };
    const invalid_keys: Track = .{ .target = 2, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 } } } };
    try expectValidationError(error.InvalidTiming, .{ .duration_seconds = 0, .tracks = &.{invalid_keys} });
    try expectValidationError(error.InvalidTiming, .{ .duration_seconds = std.math.nan(f64), .tracks = &.{valid} });
    var invalid = invalid_keys;
    invalid.target = 0;
    try expectValidationError(error.InvalidTarget, .{ .duration_seconds = 1, .tracks = &.{invalid} });
    try expectValidationError(error.InvalidKeys, .{ .duration_seconds = 1, .tracks = &.{ valid, invalid_keys } });
    invalid.target = 1;
    try expectValidationError(error.ConflictingTracks, .{ .duration_seconds = 1, .tracks = &.{ valid, invalid } });
    try expectValidationError(error.InvalidKeys, .{ .duration_seconds = 1, .tracks = &.{ invalid_keys, invalid_keys } });
    invalid.easing = .{ .spline = .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 1 } };
    try expectValidationError(error.InvalidEasing, .{ .duration_seconds = 1, .tracks = &.{invalid} });
    const cases = [_]struct { property: Property, expected: Error }{
        .{ .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = std.math.inf(f64), .y = 0 } } } }, .expected = error.NonFinite },
        .{ .property = .{ .scale = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 0, .y = std.math.nan(f64) } } } }, .expected = error.NonFinite },
        .{ .property = .{ .rotate = .{ .center = .{ .x = std.math.nan(f64), .y = 0 }, .keys = &.{} } }, .expected = error.NonFinite },
        .{ .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 2 } } }, .expected = error.InvalidOpacity },
        .{ .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = -1 } } }, .expected = error.InvalidWidth },
        .{ .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 2 } } } }, .expected = error.InvalidColor },
        .{ .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .a = std.math.nan(f64) } } } }, .expected = error.InvalidColor },
        .{ .property = .{ .path = &.{ .{ .time = 0, .value = &.{} }, .{ .time = 1, .value = &.{} } } }, .expected = error.InvalidPath },
        .{ .property = .{ .path = &.{ .{ .time = 0, .value = &.{.{ .move = .zero }} }, .{ .time = 1, .value = &.{ .{ .move = .zero }, .close } } } }, .expected = error.IncompatiblePaths },
        .{ .property = .{ .motion = .{ .path = &.{} } }, .expected = error.InvalidPath },
        .{ .property = .{ .motion = .{ .path = &.{.{ .move = .zero }}, .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 2 } } } }, .expected = error.InvalidMotion },
    };
    for (cases) |case| try expectValidationError(case.expected, .{ .duration_seconds = 1, .tracks = &.{.{ .target = 1, .property = case.property }} });
}
