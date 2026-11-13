//! SVG group and path attributes, and SMIL animation elements. XML syntax and
//! escaping belong to zig-xml; these routines only format SVG attribute values
//! from validated animation tracks. Numbers follow Typst's SVG policy, and SMIL
//! defaults stay implicit.
const std = @import("std");
const animation = @import("../../animation/root.zig");
const evaluate = @import("../../animation/evaluate.zig");
const Path = @import("../../drawing/path/Path.zig");
const motion_geometry = @import("../../animation/motion.zig");
const values = @import("values.zig");
const XmlWriter = @import("xml_parser").Writer;
const number = values.number;

const SmilEncoder = @This();

xml: XmlWriter,
value: *std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator, out: *std.Io.Writer, value: *std.Io.Writer.Allocating) SmilEncoder {
    // All generated names are unprefixed SVG names. The surrounding static
    // document, including its namespaces, is checked by the XML reader.
    return .{ .xml = .init(allocator, out, .{ .namespace_aware = false }), .value = value };
}

pub fn deinit(self: *SmilEncoder) void {
    self.xml.deinit();
}

pub fn attribute(self: *SmilEncoder, name: []const u8, comptime format: []const u8, args: anytype) !void {
    self.value.clearRetainingCapacity();
    try self.value.writer.print(format, args);
    try self.xml.attribute(name, self.value.written());
}

/// The normalized time at which playback starts a track. Base attributes
/// show this state, as do viewers that do not animate.
pub fn start(track: *const animation.Track, scene: *const animation.Animation) !f64 {
    return evaluate.time(scene.*, track, 0);
}

/// animate and animateTransform default to linear interpolation between
/// evenly spaced keys. animateMotion defaults to paced timing, and its
/// keyPoints require explicit keyTimes.
const Element = enum { animate, motion };

fn common(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation, keys: anytype, element: Element) !void {
    try self.playback(track, scene);
    const linear = element == .animate and track.easing == .linear;
    if (!linear) try self.xml.attribute("calcMode", @tagName(track.easing));
    // Discrete keys end at time 1, while discrete SMIL's implicit spacing ends
    // at (n-1)/n, so only linear keys can match the default.
    if (!linear or !evenlySpaced(keys)) {
        self.value.clearRetainingCapacity();
        for (keys, 0..) |key, i| {
            if (i != 0) try self.value.writer.writeByte(';');
            try self.value.writer.print("{d}", .{number(key.time)});
        }
        try self.xml.attribute("keyTimes", self.value.written());
    }
    if (track.easing == .spline) {
        const spline = track.easing.spline;
        self.value.clearRetainingCapacity();
        for (0..keys.len - 1) |i| {
            if (i != 0) try self.value.writer.writeByte(';');
            try self.value.writer.print("{d} {d} {d} {d}", .{ number(spline.x1), number(spline.y1), number(spline.x2), number(spline.y2) });
        }
        try self.xml.attribute("keySplines", self.value.written());
    }
    try self.xml.elementEndEmpty();
}

/// Animations begin at time 0 by default; a phase moves the begin earlier,
/// or later for a single run. A loop never ends, so only a single run needs
/// `fill="freeze"` to hold its last value.
fn playback(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    const seconds = number(scene.duration_seconds);
    try self.attribute("dur", "{d}s", .{if (seconds > 0) seconds else scene.duration_seconds});
    const begin = number(track.startSeconds(scene));
    if (begin != 0) try self.attribute("begin", "{d}s", .{begin});
    if (scene.repeat) try self.xml.attribute("repeatCount", "indefinite") else try self.xml.attribute("fill", "freeze");
}

/// Opens the group of a transform, opacity or motion track, with its state
/// at playback start.
pub fn wrapper(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    try self.xml.elementStart("g");
    const at = try start(track, scene);
    switch (track.property) {
        .translate, .scale => |keys| {
            const kind = if (track.property == .translate) "translate" else "scale";
            const value = evaluate.point(keys, track.easing, at);
            try self.attribute("transform", "{s}({d} {d})", .{ kind, number(value.x), number(value.y) });
        },
        .rotate => |rotation| {
            const angle = try values.degrees(evaluate.scalar(rotation.keys, track.easing, at));
            try self.attribute("transform", "rotate({d} {d} {d})", .{ number(angle), number(rotation.center.x), number(rotation.center.y) });
        },
        .opacity => |keys| try self.attribute("opacity", "{d}", .{number(evaluate.scalar(keys, track.easing, at))}),
        .motion => |motion| {
            const pose = try motion_geometry.motionPose(self.value.allocator, motion.path, evaluate.scalar(motion.keys, track.easing, at));
            const angle: f64 = switch (motion.rotate) {
                .none => 0,
                .auto => pose.angle,
                .auto_reverse => pose.angle + std.math.pi,
            };
            if (!pose.position.isFinite() or !std.math.isFinite(angle)) return error.NonFinite;
            try self.attribute("transform", "translate({d} {d}) rotate({d})", .{ number(pose.position.x), number(pose.position.y), number(try values.degrees(angle)) });
        },
        else => unreachable,
    }
}

/// SMIL children animating an open wrapper. A constant track needs none.
pub fn wrapperAnimation(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    switch (track.property) {
        .translate, .scale => |keys| {
            if (values.constant(keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", if (track.property == .translate) "translate" else "scale");
            self.value.clearRetainingCapacity();
            for (keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d}", .{ number(key.value.x), number(key.value.y) });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, keys, .animate);
        },
        .rotate => |rotation| {
            if (values.constant(rotation.keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "rotate");
            self.value.clearRetainingCapacity();
            for (rotation.keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d} {d}", .{ number(try values.degrees(key.value)), number(rotation.center.x), number(rotation.center.y) });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, rotation.keys, .animate);
        },
        .opacity => |keys| if (!values.constant(keys)) try self.scalar(track, scene, "opacity", keys),
        .motion => |motion| {
            if (values.constant(motion.keys)) return;
            // Motion is supplemental; replace only our fallback transform
            // during playback, preserving the marked object's transform.
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "translate");
            try self.xml.attribute("additive", "replace");
            try self.xml.attribute("values", "0 0;0 0");
            try self.xml.attribute("calcMode", "discrete");
            try self.playback(track, scene);
            try self.xml.elementEndEmpty();
            try self.xml.elementStart("animateMotion");
            self.value.clearRetainingCapacity();
            try values.pathData(&self.value.writer, motion.path);
            try self.xml.attribute("path", self.value.written());
            try self.xml.attribute("rotate", switch (motion.rotate) {
                .none => "0",
                .auto => "auto",
                .auto_reverse => "auto-reverse",
            });
            self.value.clearRetainingCapacity();
            for (motion.keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d}", .{number(key.value)});
            }
            try self.xml.attribute("keyPoints", self.value.written());
            try self.common(track, scene, motion.keys, .motion);
        },
        else => unreachable,
    }
}

fn scalar(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation, name: []const u8, keys: []const animation.ScalarKey) !void {
    try self.xml.elementStart("animate");
    try self.xml.attribute("attributeName", name);
    self.value.clearRetainingCapacity();
    for (keys, 0..) |key, i| {
        if (i != 0) try self.value.writer.writeByte(';');
        try self.value.writer.print("{d}", .{number(key.value)});
    }
    try self.xml.attribute("values", self.value.written());
    try self.common(track, scene, keys, .animate);
}

/// The path's paint or geometry attributes at playback start.
pub fn basePaint(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    const at = try start(track, scene);
    switch (track.property) {
        .fill, .stroke => |keys| {
            const value = evaluate.color(keys, track.easing, at);
            self.value.clearRetainingCapacity();
            try values.color(&self.value.writer, value);
            try self.xml.attribute(if (track.property == .fill) "fill" else "stroke", self.value.written());
            try self.attribute(if (track.property == .fill) "fill-opacity" else "stroke-opacity", "{d}", .{number(value.a)});
        },
        .stroke_width => |keys| try self.attribute("stroke-width", "{d}", .{number(evaluate.scalar(keys, track.easing, at))}),
        .path => |keys| {
            var shape = Path.init(self.value.allocator);
            defer shape.deinit();
            try evaluate.path(&shape, keys, track.easing, at);
            self.value.clearRetainingCapacity();
            try values.pathData(&self.value.writer, shape.segments.items);
            try self.xml.attribute("d", self.value.written());
        },
        else => unreachable,
    }
}

/// SMIL children animating the path's paint or geometry.
pub fn paintAnimation(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    switch (track.property) {
        .fill, .stroke => |keys| {
            const changes = values.colorChanges(keys);
            if (changes.rgb) {
                try self.xml.elementStart("animate");
                try self.xml.attribute("attributeName", if (track.property == .fill) "fill" else "stroke");
                self.value.clearRetainingCapacity();
                for (keys, 0..) |key, i| {
                    if (i != 0) try self.value.writer.writeByte(';');
                    try values.color(&self.value.writer, key.value);
                }
                try self.xml.attribute("values", self.value.written());
                try self.common(track, scene, keys, .animate);
            }
            if (changes.alpha) {
                try self.xml.elementStart("animate");
                try self.xml.attribute("attributeName", if (track.property == .fill) "fill-opacity" else "stroke-opacity");
                self.value.clearRetainingCapacity();
                for (keys, 0..) |key, i| {
                    if (i != 0) try self.value.writer.writeByte(';');
                    try self.value.writer.print("{d}", .{number(key.value.a)});
                }
                try self.xml.attribute("values", self.value.written());
                try self.common(track, scene, keys, .animate);
            }
        },
        .stroke_width => |keys| if (!values.constant(keys)) try self.scalar(track, scene, "stroke-width", keys),
        .path => |keys| {
            if (values.pathConstant(keys)) return;
            try self.xml.elementStart("animate");
            try self.xml.attribute("attributeName", "d");
            self.value.clearRetainingCapacity();
            for (keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try values.pathData(&self.value.writer, key.value);
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, keys, .animate);
        },
        else => unreachable,
    }
}

/// Whether the written key times equal linear SMIL's implicit i/(n-1) spacing.
fn evenlySpaced(keys: anytype) bool {
    if (keys.len < 2) return false;
    const intervals: f64 = @floatFromInt(keys.len - 1);
    for (keys, 0..) |key, index| {
        if (number(key.time) != number(@as(f64, @floatFromInt(index)) / intervals)) return false;
    }
    return true;
}

test "evenly spaced key times stay implicit in SMIL" {
    const even = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 1.0 / 3.0, .value = 1 }, .{ .time = 2.0 / 3.0, .value = 0 }, .{ .time = 1, .value = 1 } };
    try std.testing.expect(evenlySpaced(&even));
    // An accumulated 0.6000000000000001 writes the same digits as 3/5.
    var accumulated: [6]animation.ScalarKey = undefined;
    var time: f64 = 0;
    for (&accumulated, 0..) |*key, index| {
        key.* = .{ .time = if (index == accumulated.len - 1) 1 else time, .value = 0 };
        time += 0.2;
    }
    try std.testing.expect(accumulated[3].time != 3.0 / 5.0);
    try std.testing.expect(evenlySpaced(&accumulated));
    const shifted = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 0.37, .value = 1 }, .{ .time = 1, .value = 0 } };
    try std.testing.expect(!evenlySpaced(&shifted));
}
