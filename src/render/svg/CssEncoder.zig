//! CSS animations of SVG groups and paths. Tracks with the same keys share one
//! @keyframes and elements with the same animations share one class, so an
//! element writes inline only what is its own: the tracks' phases as its
//! `animation-delay`, and a motion's start distance. The classes apply only
//! to readers without a reduced motion preference; others see each element's
//! start state, which the base attributes record. A page that pauses or
//! removes the animations sees the same state. Numbers follow Typst's SVG
//! policy.
const std = @import("std");
const animation = @import("../../animation/root.zig");
const evaluate = @import("../../animation/evaluate.zig");
const values = @import("values.zig");
const number = values.number;

const CssEncoder = @This();

/// A keyframes or class name: a prefix and a 64-bit hash of the CSS text it
/// names, in base36. Like Typst's glyph and clip IDs, a name repeats only
/// with its text, so SVG files inlined into one page, whose stylesheets all
/// apply page-wide, cannot redefine each other's names.
pub const Name = struct {
    kind: Kind,
    hash: u64,

    pub const Kind = enum { keyframes, class };

    /// The name of a keyframes body or a class rule.
    pub fn of(kind: Kind, text: []const u8) Name {
        return .{ .kind = kind, .hash = std.hash.XxHash64.hash(0, text) };
    }

    pub fn format(self: Name, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll(switch (self.kind) {
            .keyframes => "huak-k",
            .class => "huak-a",
        });
        try out.printInt(self.hash, 36, .lower, .{});
    }
};

/// Owns the keyframe and rule texts in insertion order, with their names.
arena: std.heap.ArenaAllocator,
keyframes: std.StringArrayHashMapUnmanaged(Name) = .empty,
rules: std.StringArrayHashMapUnmanaged(Name) = .empty,
keyframe: std.Io.Writer.Allocating,
rule: std.Io.Writer.Allocating,
delays: std.Io.Writer.Allocating,
/// The last element's style attribute.
declarations: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator) CssEncoder {
    return .{ .arena = .init(allocator), .keyframe = .init(allocator), .rule = .init(allocator), .delays = .init(allocator), .declarations = .init(allocator) };
}

pub fn deinit(self: *CssEncoder) void {
    self.keyframe.deinit();
    self.rule.deinit();
    self.delays.deinit();
    self.declarations.deinit();
    self.arena.deinit();
}

/// The class of an element's CSS animations, or null when every track is
/// constant. Until the next call, style() holds the element's own declarations.
pub fn element(self: *CssEncoder, tracks: []const *const animation.Track, scene: *const animation.Animation) !?Name {
    const arena = self.arena.allocator();
    self.rule.clearRetainingCapacity();
    self.delays.clearRetainingCapacity();
    self.declarations.clearRetainingCapacity();
    var delayed = false;
    var distance: f64 = 0;
    var count: usize = 0;
    for (tracks) |track| {
        self.keyframe.clearRetainingCapacity();
        if (!try writeKeyframes(&self.keyframe.writer, track)) continue;
        const keyframes = try self.keyframes.getOrPut(arena, self.keyframe.written());
        if (!keyframes.found_existing) {
            keyframes.key_ptr.* = try arena.dupe(u8, self.keyframe.written());
            keyframes.value_ptr.* = .of(.keyframes, keyframes.key_ptr.*);
        }
        if (count == 0) {
            if (track.property == .motion) {
                const motion = track.property.motion;
                try motionDeclarations(&self.rule.writer, motion);
                distance = percent(evaluate.scalar(motion.keys, track.easing, try evaluate.time(scene.*, track, 0)));
            }
            try self.rule.writer.writeAll("animation:");
        } else {
            try self.rule.writer.writeByte(',');
            try self.delays.writer.writeByte(',');
        }
        const seconds = number(scene.duration_seconds);
        try self.rule.writer.print("{f} {d}s ", .{ keyframes.value_ptr.*, if (seconds > 0) seconds else scene.duration_seconds });
        try timing(&self.rule.writer, track.easing);
        // A single run holds its first keys until a late start, then its last.
        try self.rule.writer.writeAll(if (scene.repeat) " infinite" else " both");
        const begin = number(track.startSeconds(scene));
        delayed = delayed or begin != 0;
        try self.delays.writer.print("{d}s", .{begin});
        count += 1;
    }
    if (count == 0) return null;
    if (delayed) try self.declarations.writer.print("animation-delay:{s}", .{self.delays.written()});
    // The class places a motion on its path, at the default distance 0 while
    // no animation runs; this keeps it at its start pose.
    if (distance != 0) {
        if (delayed) try self.declarations.writer.writeByte(';');
        try self.declarations.writer.print("offset-distance:{d}%", .{distance});
    }
    const class = try self.rules.getOrPut(arena, self.rule.written());
    if (!class.found_existing) {
        class.key_ptr.* = try arena.dupe(u8, self.rule.written());
        class.value_ptr.* = .of(.class, class.key_ptr.*);
    }
    return class.value_ptr.*;
}

/// The last element's style attribute; empty when it needs none.
pub fn style(self: *CssEncoder) []const u8 {
    return self.declarations.written();
}

pub fn empty(self: *const CssEncoder) bool {
    return self.rules.count() == 0;
}

/// The stylesheet text for every element() so far.
pub fn stylesheet(self: *const CssEncoder, out: *std.Io.Writer) !void {
    for (self.keyframes.keys(), self.keyframes.values()) |body, name| try out.print("@keyframes {f}{{{s}}}", .{ name, body });
    try out.writeAll("@media (prefers-reduced-motion:no-preference){");
    for (self.rules.keys(), self.rules.values()) |body, name| try out.print(".{f}{{{s}}}", .{ name, body });
    try out.writeByte('}');
}

fn percent(time: f64) f64 {
    return number(time * 100);
}

/// The keyframes of a track; false, writing nothing, when its keys are constant.
/// Rotation centers and motion follow SVG: the group's own coordinates.
fn writeKeyframes(out: *std.Io.Writer, track: *const animation.Track) !bool {
    switch (track.property) {
        .translate, .scale => |keys| {
            if (values.constant(keys)) return false;
            for (keys) |key| {
                if (track.property == .translate)
                    try out.print("{d}%{{transform:translate({d}px,{d}px)}}", .{ percent(key.time), number(key.value.x), number(key.value.y) })
                else
                    try out.print("{d}%{{transform:scale({d},{d})}}", .{ percent(key.time), number(key.value.x), number(key.value.y) });
            }
        },
        .rotate => |rotation| {
            if (values.constant(rotation.keys)) return false;
            const center = rotation.center;
            for (rotation.keys) |key| {
                const angle = number(try values.degrees(key.value));
                if (center.x == 0 and center.y == 0)
                    try out.print("{d}%{{transform:rotate({d}deg)}}", .{ percent(key.time), angle })
                else
                    try out.print("{d}%{{transform:translate({d}px,{d}px) rotate({d}deg) translate({d}px,{d}px)}}", .{ percent(key.time), number(center.x), number(center.y), angle, number(-center.x), number(-center.y) });
            }
        },
        .opacity => |keys| {
            if (values.constant(keys)) return false;
            for (keys) |key| try out.print("{d}%{{opacity:{d}}}", .{ percent(key.time), number(key.value) });
        },
        .motion => |motion| {
            if (values.constant(motion.keys)) return false;
            for (motion.keys) |key| try out.print("{d}%{{offset-distance:{d}%}}", .{ percent(key.time), percent(key.value) });
        },
        .fill, .stroke => |keys| {
            const changes = values.colorChanges(keys);
            if (!changes.rgb and !changes.alpha) return false;
            const name = if (track.property == .fill) "fill" else "stroke";
            for (keys) |key| {
                try out.print("{d}%{{", .{percent(key.time)});
                if (changes.rgb) {
                    try out.print("{s}:", .{name});
                    try values.color(out, key.value);
                    if (changes.alpha) try out.writeByte(';');
                }
                if (changes.alpha) try out.print("{s}-opacity:{d}", .{ name, number(key.value.a) });
                try out.writeByte('}');
            }
        },
        .stroke_width => |keys| {
            if (values.constant(keys)) return false;
            for (keys) |key| try out.print("{d}%{{stroke-width:{d}px}}", .{ percent(key.time), number(key.value) });
        },
        .path => |keys| {
            if (values.pathConstant(keys)) return false;
            for (keys) |key| {
                try out.print("{d}%{{d:path(\"", .{percent(key.time)});
                try values.pathData(out, key.value);
                try out.writeAll("\")}");
            }
        },
    }
    return true;
}

/// Motion replaces the group's start pose, its base transform, with a place
/// on the path while it plays.
fn motionDeclarations(out: *std.Io.Writer, motion: animation.Motion) !void {
    try out.writeAll("transform:none;offset-path:path(\"");
    try values.pathData(out, motion.path);
    try out.print("\");offset-rotate:{s};", .{switch (motion.rotate) {
        .none => "0deg",
        .auto => "auto",
        .auto_reverse => "reverse",
    }});
}

/// The timing function of every key interval, as in SMIL.
fn timing(out: *std.Io.Writer, easing: animation.Easing) !void {
    switch (easing) {
        .linear => try out.writeAll("linear"),
        .discrete => try out.writeAll("steps(1,end)"),
        .spline => |s| try out.print("cubic-bezier({d},{d},{d},{d})", .{ number(s.x1), number(s.y1), number(s.x2), number(s.y2) }),
    }
}

test "identical keys share keyframes and classes while phases stay inline" {
    var css: CssEncoder = .init(std.testing.allocator);
    defer css.deinit();
    const keys = [_]animation.ScalarKey{ .{ .time = 0, .value = 0.2 }, .{ .time = 0.5, .value = 1 }, .{ .time = 1, .value = 0.2 } };
    const scene: animation.Animation = .{ .duration_seconds = 4, .tracks = &.{} };
    var first: animation.Track = .{ .target = 1, .property = .{ .opacity = &keys } };
    var second = first;
    second.phase = 0.25;
    const class = (try css.element(&.{&first}, &scene)).?;
    try std.testing.expectEqualStrings("", css.style());
    try std.testing.expectEqual(class, (try css.element(&.{&second}, &scene)).?);
    try std.testing.expectEqualStrings("animation-delay:-1s", css.style());
    const constant = [_]animation.ScalarKey{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 1 } };
    first.property = .{ .opacity = &constant };
    try std.testing.expectEqual(@as(?Name, null), try css.element(&.{&first}, &scene));
    try std.testing.expectEqualStrings("", css.style());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try css.stylesheet(&out.writer);
    // Each name is the hash of the text it names.
    const body = "0%{opacity:0.2}50%{opacity:1}100%{opacity:0.2}";
    const keyframes: Name = .of(.keyframes, body);
    var rule: [64]u8 = undefined;
    const rule_text = try std.fmt.bufPrint(&rule, "animation:{f} 4s linear infinite", .{keyframes});
    try std.testing.expectEqual(Name.of(.class, rule_text), class);
    var expected: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "@keyframes {f}{{{s}}}@media (prefers-reduced-motion:no-preference){{.{f}{{{s}}}}}", .{ keyframes, body, class, rule_text }), out.written());
}

test "names follow the rules they name, not the document or its order" {
    const scene: animation.Animation = .{ .duration_seconds = 4, .tracks = &.{} };
    const rising = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } };
    const falling = [_]animation.ScalarKey{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 0 } };
    const up: animation.Track = .{ .target = 1, .property = .{ .opacity = &rising } };
    const down: animation.Track = .{ .target = 2, .property = .{ .opacity = &falling } };
    // Two documents meet the same rules in opposite orders.
    var one: CssEncoder = .init(std.testing.allocator);
    defer one.deinit();
    const up_one = (try one.element(&.{&up}, &scene)).?;
    const down_one = (try one.element(&.{&down}, &scene)).?;
    var two: CssEncoder = .init(std.testing.allocator);
    defer two.deinit();
    const down_two = (try two.element(&.{&down}, &scene)).?;
    const up_two = (try two.element(&.{&up}, &scene)).?;
    try std.testing.expectEqual(up_one, up_two);
    try std.testing.expectEqual(down_one, down_two);
    try std.testing.expect(up_one.hash != down_one.hash);
    var text: [32]u8 = undefined;
    const small: Name = .{ .kind = .class, .hash = 35 };
    try std.testing.expectEqualStrings("huak-az", try std.fmt.bufPrint(&text, "{f}", .{small}));
    const large: Name = .{ .kind = .keyframes, .hash = std.math.maxInt(u64) };
    try std.testing.expectEqualStrings("huak-k3w5e11264sgsf", try std.fmt.bufPrint(&text, "{f}", .{large}));
}

test "a motion keeps its start distance inline for pages that stop the animation" {
    var css: CssEncoder = .init(std.testing.allocator);
    defer css.deinit();
    const line = [_]@import("../../drawing/path/Path.zig").Segment{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 100, .y = 0 } } };
    const scene: animation.Animation = .{ .duration_seconds = 4, .tracks = &.{} };
    const from_start = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } };
    var track: animation.Track = .{ .target = 1, .property = .{ .motion = .{ .path = &line, .keys = &from_start, .rotate = .none } } };
    _ = try css.element(&.{&track}, &scene);
    try std.testing.expectEqualStrings("", css.style());
    track.phase = 0.5;
    _ = try css.element(&.{&track}, &scene);
    try std.testing.expectEqualStrings("animation-delay:-2s;offset-distance:50%", css.style());
    const late = [_]animation.ScalarKey{ .{ .time = 0, .value = 0.25 }, .{ .time = 1, .value = 0.75 } };
    track = .{ .target = 1, .property = .{ .motion = .{ .path = &line, .keys = &late, .rotate = .none } } };
    _ = try css.element(&.{&track}, &scene);
    try std.testing.expectEqualStrings("offset-distance:25%", css.style());
}
