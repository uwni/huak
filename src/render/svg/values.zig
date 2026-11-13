//! Values shared by the SVG animation encoders: Typst's number policy, 8-bit
//! colors, path data and the checks that let constant keys stay static.
const std = @import("std");
const animation = @import("../../animation/root.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Path = @import("../../drawing/path/Path.zig");

/// Typst's SVG number policy: round to nine decimal places and print the
/// shortest form, with -0 as 0. Values too large to scale keep their digits.
pub fn number(value: f64) f64 {
    const scaled = @round(value * 1e9) / 1e9;
    const rounded = if (std.math.isFinite(scaled)) scaled else value;
    return if (rounded == 0) 0 else rounded;
}

pub fn degrees(value: f64) !f64 {
    const result = value * (180.0 / std.math.pi);
    if (!std.math.isFinite(result)) return error.NonFinite;
    return result;
}

pub fn channel(value: f64) u8 {
    return @intFromFloat(@round(value * 255));
}

pub fn color(out: *std.Io.Writer, value: DisplayList.Color) !void {
    try out.print("rgb({d},{d},{d})", .{ channel(value.r), channel(value.g), channel(value.b) });
}

pub fn pathData(out: *std.Io.Writer, segments: []const Path.Segment) !void {
    for (segments) |segment| switch (segment) {
        .move => |point| try out.print("M {d} {d} ", .{ number(point.x), number(point.y) }),
        .line => |point| try out.print("L {d} {d} ", .{ number(point.x), number(point.y) }),
        .cubic => |curve| try out.print("C {d} {d} {d} {d} {d} {d} ", .{ number(curve.c1.x), number(curve.c1.y), number(curve.c2.x), number(curve.c2.y), number(curve.end.x), number(curve.end.y) }),
        .close => try out.writeAll("Z "),
    };
}

pub fn constant(keys: anytype) bool {
    for (keys[1..]) |key| if (!std.meta.eql(keys[0].value, key.value)) return false;
    return true;
}

pub fn pathConstant(keys: []const animation.PathKey) bool {
    for (keys[1..]) |key| {
        for (keys[0].value, key.value) |left, right| if (!std.meta.eql(left, right)) return false;
    }
    return true;
}

/// Which written parts of color keys vary: the 8-bit RGB channels, the alpha.
pub const ColorChanges = struct { rgb: bool, alpha: bool };

pub fn colorChanges(keys: []const animation.ColorKey) ColorChanges {
    const first = keys[0].value;
    var changes: ColorChanges = .{ .rgb = false, .alpha = false };
    for (keys[1..]) |key| {
        changes.rgb = changes.rgb or channel(key.value.r) != channel(first.r) or channel(key.value.g) != channel(first.g) or channel(key.value.b) != channel(first.b);
        changes.alpha = changes.alpha or key.value.a != first.a;
        if (changes.rgb and changes.alpha) break;
    }
    return changes;
}

test "numbers follow Typst's SVG precision" {
    try std.testing.expectEqual(@as(f64, 0.309740584), number(0.30974058379240427));
    try std.testing.expectEqual(@as(f64, 0), number(-0.0000000001));
    try std.testing.expect(!std.math.signbit(number(-0.0)));
    try std.testing.expectEqual(@as(f64, 1e300), number(1e300));
}
