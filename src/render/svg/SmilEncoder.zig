//! SVG animation elements. XML syntax and escaping belong to zig-xml; these
//! routines only format SVG attribute values from validated animation tracks.
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

fn common(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation, keys: anytype) !void {
    try self.xml.attribute("begin", "0s");
    try self.attribute("dur", "{d}s", .{scene.duration_seconds});
    try self.xml.attribute("repeatCount", if (scene.repeat) "indefinite" else "1");
    try self.xml.attribute("fill", "freeze");
    try self.xml.attribute("calcMode", switch (track.easing) {
        .linear => "linear",
        .discrete => "discrete",
        .spline => "spline",
    });
    self.value.clearRetainingCapacity();
    for (keys, 0..) |key, i| {
        if (i != 0) try self.value.writer.writeByte(';');
        try self.value.writer.print("{d}", .{key.time});
    }
    try self.xml.attribute("keyTimes", self.value.written());
    if (track.easing == .spline) {
        const spline = track.easing.spline;
        self.value.clearRetainingCapacity();
        for (0..keys.len - 1) |i| {
            if (i != 0) try self.value.writer.writeByte(';');
            try self.value.writer.print("{d} {d} {d} {d}", .{ spline.x1, spline.y1, spline.x2, spline.y2 });
        }
        try self.xml.attribute("keySplines", self.value.written());
    }
    try self.xml.elementEndEmpty();
}

pub fn wrapper(self: *SmilEncoder, track: *const animation.Track, scene: *const animation.Animation) !void {
    try self.xml.elementStart("g");
    switch (track.property) {
        .translate, .scale => |keys| {
            const kind = if (track.property == .translate) "translate" else "scale";
            try self.attribute("transform", "{s}({d} {d})", .{ kind, keys[0].value.x, keys[0].value.y });
            if (constant(keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", kind);
            self.value.clearRetainingCapacity();
            for (keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d}", .{ key.value.x, key.value.y });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, keys);
        },
        .rotate => |rotation| {
            try self.attribute("transform", "rotate({d} {d} {d})", .{ try degrees(rotation.keys[0].value), rotation.center.x, rotation.center.y });
            if (constant(rotation.keys)) return;
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "rotate");
            self.value.clearRetainingCapacity();
            for (rotation.keys, 0..) |key, i| {
                if (i != 0) try self.value.writer.writeByte(';');
                try self.value.writer.print("{d} {d} {d}", .{ try degrees(key.value), rotation.center.x, rotation.center.y });
            }
            try self.xml.attribute("values", self.value.written());
            try self.common(track, scene, rotation.keys);
        },
        .opacity => |keys| {
            try self.attribute("opacity", "{d}", .{keys[0].value});
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
            try self.attribute("transform", "translate({d} {d}) rotate({d})", .{ pose.position.x, pose.position.y, try degrees(angle) });
            if (constant(motion.keys)) return;
            // Motion is supplemental; replace only our fallback transform
            // during playback, preserving the marked object's transform.
            try self.xml.elementStart("animateTransform");
            try self.xml.attribute("attributeName", "transform");
            try self.xml.attribute("type", "translate");
            try self.xml.attribute("additive", "replace");
            try self.xml.attribute("values", "0 0;0 0");
            try self.xml.attribute("calcMode", "discrete");
            try self.xml.attribute("begin", "0s");
            try self.attribute("dur", "{d}s", .{scene.duration_seconds});
            try self.xml.attribute("repeatCount", if (scene.repeat) "indefinite" else "1");
            try self.xml.attribute("fill", "freeze");
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
                try self.value.writer.print("{d}", .{key.value});
            }
            try self.xml.attribute("keyPoints", self.value.written());
            try self.common(track, scene, motion.keys);
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
        try self.value.writer.print("{d}", .{key.value});
    }
    try self.xml.attribute("values", self.value.written());
    try self.common(track, scene, keys);
}

pub fn basePaint(self: *SmilEncoder, property: *const animation.Property) !void {
    switch (property.*) {
        .fill, .stroke => |keys| {
            const name = if (property.* == .fill) "fill" else "stroke";
            self.value.clearRetainingCapacity();
            try color(&self.value.writer, keys[0].value);
            try self.xml.attribute(name, self.value.written());
            try self.attribute(if (property.* == .fill) "fill-opacity" else "stroke-opacity", "{d}", .{keys[0].value.a});
        },
        .stroke_width => |keys| try self.attribute("stroke-width", "{d}", .{keys[0].value}),
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
                try self.common(track, scene, keys);
            }
            if (!alpha_constant) {
                try self.xml.elementStart("animate");
                try self.xml.attribute("attributeName", if (track.property == .fill) "fill-opacity" else "stroke-opacity");
                self.value.clearRetainingCapacity();
                for (keys, 0..) |key, i| {
                    if (i != 0) try self.value.writer.writeByte(';');
                    try self.value.writer.print("{d}", .{key.value.a});
                }
                try self.xml.attribute("values", self.value.written());
                try self.common(track, scene, keys);
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
            try self.common(track, scene, keys);
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
        .move => |point| try out.print("M {d} {d} ", .{ point.x, point.y }),
        .line => |point| try out.print("L {d} {d} ", .{ point.x, point.y }),
        .cubic => |curve| try out.print("C {d} {d} {d} {d} {d} {d} ", .{ curve.c1.x, curve.c1.y, curve.c2.x, curve.c2.y, curve.end.x, curve.end.y }),
        .close => try out.writeAll("Z "),
    };
}
