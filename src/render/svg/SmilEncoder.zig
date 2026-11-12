//! SVG animation elements. XML syntax and escaping belong to zig-xml; these
//! routines only format SVG attribute values from validated animation tracks.
//! Numbers follow Typst's SVG policy, and SMIL defaults stay implicit.
const std = @import("std");
const animation = @import("../../animation/root.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Path = @import("../../drawing/path/Path.zig");
const motion_geometry = @import("../../animation/motion.zig");
const XmlWriter = @import("xml_parser").Writer;

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

pub fn object(self: *SmilEncoder, id: u64) !void {
    try self.xml.elementStart("g");
    try self.attribute("id", "huak-object-{d}", .{id});
}

fn attribute(self: *SmilEncoder, name: []const u8, comptime format: []const u8, args: anytype) !void {
    self.value.clearRetainingCapacity();
    try self.value.writer.print(format, args);
    try self.xml.attribute(name, self.value.written());
}

/// animate and animateTransform default to linear interpolation between
/// evenly spaced keys. animateMotion defaults to paced timing, and its
/// keyPoints require explicit keyTimes.
const Element = enum { animate, motion };

fn common(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation, keys: anytype, element: Element) !void {
    try self.playback(scene);
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

/// Animations begin at time 0 by default. A loop never ends, so only a single
/// run needs `fill="freeze"` to hold its last value.
fn playback(self: *SmilEncoder, scene: *const animation.Animation) !void {
    const seconds = number(scene.duration_seconds);
    try self.attribute("dur", "{d}s", .{if (seconds > 0) seconds else scene.duration_seconds});
    if (scene.repeat) try self.xml.attribute("repeatCount", "indefinite") else try self.xml.attribute("fill", "freeze");
}

pub fn wrapper(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    try self.xml.elementStart("g");
    switch (track.property) {
        .translate, .scale => |keys| {
            const kind = if (track.property == .translate) "translate" else "scale";
            try self.attribute("transform", "{s}({d} {d})", .{ kind, number(keys[0].value.x), number(keys[0].value.y) });
            if (constant(keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", kind);
            self.value.clearRetainingCapacity();
            for (keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d}", .{ number(key.value.x), number(key.value.y) });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, keys, .animate);
        },
        .rotate => |rotation| {
            try self.attribute("transform", "rotate({d} {d} {d})", .{ number(try degrees(rotation.keys[0].value)), number(rotation.center.x), number(rotation.center.y) });
            if (constant(rotation.keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "rotate");
            self.value.clearRetainingCapacity();
            for (rotation.keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d} {d}", .{ number(try degrees(key.value)), number(rotation.center.x), number(rotation.center.y) });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, rotation.keys, .animate);
        },
        .opacity => |keys| {
            try self.attribute("opacity", "{d}", .{number(keys[0].value)});
            if (!constant(keys)) try self.scalar(track, scene, "opacity", keys);
        },
        .motion => |motion| {
            const pose = try motion_geometry.motionPose(self.value.allocator, motion.path, motion.keys[0].value);
            const angle: f64 = switch (motion.rotate) {
                .none => 0,
                .auto => pose.angle,
                .auto_reverse => pose.angle + std.math.pi,
            };
            if (!pose.position.isFinite() or !std.math.isFinite(angle)) return error.NonFinite;
            try self.attribute("transform", "translate({d} {d}) rotate({d})", .{ number(pose.position.x), number(pose.position.y), number(try degrees(angle)) });
            if (constant(motion.keys)) return;
            // Motion is supplemental; replace only our fallback transform
            // during playback, preserving the marked object's transform.
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "translate");
            try self.xml.attribute("additive", "replace");
            try self.xml.attribute("values", "0 0;0 0");
            try self.xml.attribute("calcMode", "discrete");
            try self.playback(scene);
            try self.xml.elementEndEmpty();
            try self.xml.elementStart("animateMotion");
            self.value.clearRetainingCapacity();
            try pathData(&self.value.writer, motion.path);
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

pub fn basePaint(self: *SmilEncoder, property: *const animation.Property) !void {
    switch (property.*) {
        .fill, .stroke => |keys| {
            const name = if (property.* == .fill) "fill" else "stroke";
            self.value.clearRetainingCapacity();
            try color(&self.value.writer, keys[0].value);
            try self.xml.attribute(name, self.value.written());
            try self.attribute(if (property.* == .fill) "fill-opacity" else "stroke-opacity", "{d}", .{number(keys[0].value.a)});
        },
        .stroke_width => |keys| try self.attribute("stroke-width", "{d}", .{number(keys[0].value)}),
        .path => |keys| {
            self.value.clearRetainingCapacity();
            try pathData(&self.value.writer, keys[0].value);
            try self.xml.attribute("d", self.value.written());
        },
        else => unreachable,
    }
}

pub fn paintAnimation(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    switch (track.property) {
        .fill, .stroke => |keys| {
            const name = if (track.property == .fill) "fill" else "stroke";
            const first = keys[0].value;
            var rgb_constant = true;
            var alpha_constant = true;
            for (keys[1..]) |key| {
                rgb_constant = rgb_constant and channel(key.value.r) == channel(first.r) and channel(key.value.g) == channel(first.g) and channel(key.value.b) == channel(first.b);
                alpha_constant = alpha_constant and key.value.a == first.a;
                if (!rgb_constant and !alpha_constant) break;
            }
            if (!rgb_constant) {
                try self.xml.elementStart("animate");
                try self.xml.attribute("attributeName", name);
                self.value.clearRetainingCapacity();
                for (keys, 0..) |key, i| {
                    if (i != 0) try self.value.writer.writeByte(';');
                    try color(&self.value.writer, key.value);
                }
                try self.xml.attribute("values", self.value.written());
                try self.common(track, scene, keys, .animate);
            }
            if (!alpha_constant) {
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
        .stroke_width => |keys| if (!constant(keys)) try self.scalar(track, scene, "stroke-width", keys),
        .path => |keys| {
            if (pathConstant(keys)) return;
            try self.xml.elementStart("animate");
            try self.xml.attribute("attributeName", "d");
            self.value.clearRetainingCapacity();
            for (keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try pathData(&self.value.writer, key.value);
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, keys, .animate);
        },
        else => unreachable,
    }
}
fn constant(keys: anytype) bool {
    for (keys[1..]) |key| if (!std.meta.eql(keys[0].value, key.value)) return false;
    return true;
}
fn pathConstant(keys: []const animation.PathKey) bool {
    for (keys[1..]) |key| {
        for (keys[0].value, key.value) |left, right| if (!std.meta.eql(left, right)) return false;
    }
    return true;
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
/// Typst's SVG number policy: round to nine decimal places and print the
/// shortest form, with -0 as 0. Values too large to scale keep their digits.
fn number(value: f64) f64 {
    const scaled = @round(value * 1e9) / 1e9;
    const rounded = if (std.math.isFinite(scaled)) scaled else value;
    return if (rounded == 0) 0 else rounded;
}
fn degrees(value: f64) !f64 {
    const result = value * (180.0 / std.math.pi);
    if (!std.math.isFinite(result)) return error.NonFinite;
    return result;
}
fn channel(value: f64) u8 {
    return @intFromFloat(@round(value * 255));
}
fn color(out: *std.Io.Writer, value: DisplayList.Color) !void {
    try out.print("rgb({d},{d},{d})", .{ channel(value.r), channel(value.g), channel(value.b) });
}
fn pathData(out: *std.Io.Writer, segments: []const Path.Segment) !void {
    for (segments) |segment| switch (segment) {
        .move => |point| try out.print("M {d} {d} ", .{ number(point.x), number(point.y) }),
        .line => |point| try out.print("L {d} {d} ", .{ number(point.x), number(point.y) }),
        .cubic => |curve| try out.print("C {d} {d} {d} {d} {d} {d} ", .{ number(curve.c1.x), number(curve.c1.y), number(curve.c2.x), number(curve.c2.y), number(curve.end.x), number(curve.end.y) }),
        .close => try out.writeAll("Z "),
    };
}

test "numbers follow Typst's SVG precision and SMIL defaults stay implicit" {
    try std.testing.expectEqual(@as(f64, 0.309740584), number(0.30974058379240427));
    try std.testing.expectEqual(@as(f64, 0), number(-0.0000000001));
    try std.testing.expect(!std.math.signbit(number(-0.0)));
    try std.testing.expectEqual(@as(f64, 1e300), number(1e300));
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
