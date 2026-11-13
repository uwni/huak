//! Track values at one moment of playback, with the interpolation the SVG
//! encoders ask a browser to perform: linear, discrete steps or one shared
//! cubic timing curve, phases, and a single run frozen on its last keys. Values keep the
//! model's units; colors interpolate per channel before 8-bit SVG encoding.
const std = @import("std");
const animation = @import("root.zig");
const motion = @import("motion.zig");
const g = @import("../drawing/geometry.zig");
const DisplayList = @import("../drawing/DisplayList.zig");
const Path = @import("../drawing/path/Path.zig");

/// Normalized time of a track `seconds` into its timeline. A loop restarts
/// at every whole duration, shifted by the track's phase. A single run shows
/// its first keys until a late start and holds its last keys after it ends.
pub fn time(scene: animation.Animation, track: *const animation.Track, seconds: f64) error{InvalidTiming}!f64 {
    scene.validateTiming() catch return error.InvalidTiming;
    if (!std.math.isFinite(seconds) or seconds < 0) return error.InvalidTiming;
    const cycles = (seconds - track.startSeconds(&scene)) / scene.duration_seconds;
    if (!std.math.isFinite(cycles)) return error.InvalidTiming;
    if (!scene.repeat) return std.math.clamp(cycles, 0, 1);
    return cycles - @floor(cycles);
}

/// The key interval containing `at` and the eased progress through it.
/// Discrete keys hold their value until the next key time.
const Position = struct { from: usize, progress: f64 };

fn position(keys: anytype, easing: animation.Easing, at: f64) Position {
    const last = keys.len - 1;
    if (at >= keys[last].time) return .{ .from = last, .progress = 0 };
    var from: usize = 0;
    while (keys[from + 1].time <= at) from += 1;
    if (easing == .discrete) return .{ .from = from, .progress = 0 };
    const local = (at - keys[from].time) / (keys[from + 1].time - keys[from].time);
    return .{ .from = from, .progress = if (easing == .spline) eased(easing.spline, local) else local };
}

/// Solve the timing curve's monotonic x(s) = x by bisection, then return y(s).
fn eased(curve: animation.Spline, x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    var low: f64 = 0;
    var high: f64 = 1;
    for (0..64) |_| {
        const middle = (low + high) / 2;
        if (bezier(curve.x1, curve.x2, middle) < x) low = middle else high = middle;
    }
    return bezier(curve.y1, curve.y2, (low + high) / 2);
}

fn bezier(first: f64, second: f64, s: f64) f64 {
    const rest = 1 - s;
    return 3 * rest * rest * s * first + 3 * rest * s * s * second + s * s * s;
}

fn mix(from: f64, to: f64, progress: f64) f64 {
    return from + (to - from) * progress;
}

pub fn scalar(keys: []const animation.ScalarKey, easing: animation.Easing, at: f64) f64 {
    const at_key = position(keys, easing, at);
    if (at_key.progress == 0) return keys[at_key.from].value;
    return mix(keys[at_key.from].value, keys[at_key.from + 1].value, at_key.progress);
}

pub fn point(keys: []const animation.PointKey, easing: animation.Easing, at: f64) g.Point {
    const at_key = position(keys, easing, at);
    const from = keys[at_key.from].value;
    if (at_key.progress == 0) return from;
    const to = keys[at_key.from + 1].value;
    return .{ .x = mix(from.x, to.x, at_key.progress), .y = mix(from.y, to.y, at_key.progress) };
}

pub fn color(keys: []const animation.ColorKey, easing: animation.Easing, at: f64) DisplayList.Color {
    const at_key = position(keys, easing, at);
    const from = keys[at_key.from].value;
    if (at_key.progress == 0) return from;
    const to = keys[at_key.from + 1].value;
    return .{
        .r = mix(from.r, to.r, at_key.progress),
        .g = mix(from.g, to.g, at_key.progress),
        .b = mix(from.b, to.b, at_key.progress),
        .a = mix(from.a, to.a, at_key.progress),
    };
}

/// Interpolate every coordinate of keys that share one topology, as the
/// track validator requires for path morphs.
pub fn path(out: *Path, keys: []const animation.PathKey, easing: animation.Easing, at: f64) !void {
    const at_key = position(keys, easing, at);
    const from = keys[at_key.from].value;
    if (at_key.progress == 0) return out.segments.appendSlice(out.allocator, from);
    const to = keys[at_key.from + 1].value;
    try out.segments.ensureUnusedCapacity(out.allocator, from.len);
    for (from, to) |start, end| out.segments.appendAssumeCapacity(switch (start) {
        .move => |p| .{ .move = mixPoint(p, end.move, at_key.progress) },
        .line => |p| .{ .line = mixPoint(p, end.line, at_key.progress) },
        .cubic => |curve| .{ .cubic = .{
            .c1 = mixPoint(curve.c1, end.cubic.c1, at_key.progress),
            .c2 = mixPoint(curve.c2, end.cubic.c2, at_key.progress),
            .end = mixPoint(curve.end, end.cubic.end, at_key.progress),
        } },
        .close => .close,
    });
}

fn mixPoint(from: g.Point, to: g.Point, progress: f64) g.Point {
    return .{ .x = mix(from.x, to.x, progress), .y = mix(from.y, to.y, progress) };
}

/// The wrapper transform of a translate, rotate, scale or motion track at
/// `at`, in its parent's coordinates. Other properties return null.
pub fn transform(allocator: std.mem.Allocator, track: *const animation.Track, at: f64) motion.Error!?g.Transform {
    switch (track.property) {
        .translate => |keys| {
            const offset = point(keys, track.easing, at);
            return g.Transform.translation(offset.x, offset.y);
        },
        .scale => |keys| {
            const factor = point(keys, track.easing, at);
            return g.Transform.scaling(factor.x, factor.y);
        },
        .rotate => |rotation| {
            const center = rotation.center;
            const angle = scalar(rotation.keys, track.easing, at);
            return g.Transform.translation(-center.x, -center.y).then(g.Transform.rotation(angle)).then(g.Transform.translation(center.x, center.y));
        },
        .motion => |route| {
            const pose = try motion.motionPose(allocator, route.path, scalar(route.keys, track.easing, at));
            const angle: f64 = switch (route.rotate) {
                .none => 0,
                .auto => pose.angle,
                .auto_reverse => pose.angle + std.math.pi,
            };
            return g.Transform.rotation(angle).then(g.Transform.translation(pose.position.x, pose.position.y));
        },
        else => return null,
    }
}

const t = std.testing;

test "time loops at whole durations, follows phases and freezes a single run" {
    const keys = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } };
    var track: animation.Track = .{ .target = 1, .property = .{ .opacity = &keys } };
    const loop: animation.Animation = .{ .duration_seconds = 4, .tracks = &.{} };
    try t.expectEqual(@as(f64, 0.25), try time(loop, &track, 1));
    try t.expectEqual(@as(f64, 0), try time(loop, &track, 8));
    try t.expectEqual(@as(f64, 0.5), try time(loop, &track, 10));
    const once: animation.Animation = .{ .duration_seconds = 4, .repeat = false, .tracks = &.{} };
    try t.expectEqual(@as(f64, 0.5), try time(once, &track, 2));
    try t.expectEqual(@as(f64, 1), try time(once, &track, 9));
    // A loop runs ahead cyclically; a negative phase delays a single run.
    track.phase = 0.5;
    try t.expectEqual(@as(f64, 0.75), try time(loop, &track, 1));
    try t.expectEqual(@as(f64, 0.75), try time(once, &track, 1));
    track.phase = -0.25;
    try t.expectEqual(@as(f64, 0.75), try time(loop, &track, 0));
    try t.expectEqual(@as(f64, 0), try time(once, &track, 0.5));
    try t.expectEqual(@as(f64, 0.25), try time(once, &track, 2));
    try t.expectError(error.InvalidTiming, time(loop, &track, -1));
    try t.expectError(error.InvalidTiming, time(loop, &track, std.math.inf(f64)));
    try t.expectError(error.InvalidTiming, time(.{ .duration_seconds = 0, .tracks = &.{} }, &track, 1));
}

test "linear discrete and spline keys follow SMIL interpolation" {
    const keys = [_]animation.ScalarKey{ .{ .time = 0, .value = 0 }, .{ .time = 0.25, .value = 1 }, .{ .time = 1, .value = 4 } };
    try t.expectEqual(@as(f64, 0.5), scalar(&keys, .linear, 0.125));
    try t.expectEqual(@as(f64, 2.5), scalar(&keys, .linear, 0.625));
    try t.expectEqual(@as(f64, 4), scalar(&keys, .linear, 1));
    // A discrete key holds until the next key time, which shows its own value.
    try t.expectEqual(@as(f64, 0), scalar(&keys, .discrete, 0.2));
    try t.expectEqual(@as(f64, 1), scalar(&keys, .discrete, 0.25));
    try t.expectEqual(@as(f64, 4), scalar(&keys, .discrete, 1));
    // The identity curve and its mirror image bracket linear progress.
    const identity: animation.Spline = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };
    try t.expectApproxEqAbs(@as(f64, 0.37), eased(identity, 0.37), 1e-12);
    const ease_in: animation.Spline = .{ .x1 = 0.42, .y1 = 0, .x2 = 1, .y2 = 1 };
    const ease_out: animation.Spline = .{ .x1 = 0, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    try t.expect(eased(ease_in, 0.5) < 0.5 and eased(ease_out, 0.5) > 0.5);
    try t.expectApproxEqAbs(eased(ease_in, 0.3), 1 - eased(ease_out, 0.7), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.5) + 0.5 * eased(ease_in, 0.5), scalar(&.{ .{ .time = 0, .value = 0.5 }, .{ .time = 1, .value = 1 } }, .{ .spline = ease_in }, 0.5), 1e-12);
}

test "colors paths and transforms interpolate their components" {
    const colors = [_]animation.ColorKey{ .{ .time = 0, .value = .{ .r = 1, .a = 0.2 } }, .{ .time = 1, .value = .{ .b = 1, .a = 0.6 } } };
    const mixed = color(&colors, .linear, 0.25);
    inline for (.{ "r", "g", "b", "a" }, .{ 0.75, 0, 0.25, 0.3 }) |channel, expected|
        try t.expectApproxEqAbs(@as(f64, expected), @field(mixed, channel), 1e-15);
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .cubic = .{ .c1 = .{ .x = 0, .y = 4 }, .c2 = .{ .x = 4, .y = 4 }, .end = .{ .x = 4, .y = 0 } } }, .close };
    const last = [_]Path.Segment{ .{ .move = .{ .x = 2, .y = 2 } }, .{ .cubic = .{ .c1 = .{ .x = 2, .y = 8 }, .c2 = .{ .x = 8, .y = 8 }, .end = .{ .x = 8, .y = 2 } } }, .close };
    var shape = Path.init(t.allocator);
    defer shape.deinit();
    try path(&shape, &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } }, .linear, 0.5);
    try t.expectEqual(g.Point{ .x = 1, .y = 1 }, shape.segments.items[0].move);
    try t.expectEqual(g.Point{ .x = 6, .y = 1 }, shape.segments.items[1].cubic.end);
    try t.expect(shape.segments.items[2] == .close);
    const rotate: animation.Track = .{ .target = 1, .property = .{ .rotate = .{ .center = .{ .x = 10, .y = 0 }, .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } };
    const turned = (try transform(t.allocator, &rotate, 0.5)).?.apply(.{ .x = 20, .y = 0 });
    try t.expectApproxEqAbs(@as(f64, 10), turned.x, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 10), turned.y, 1e-12);
    const route = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 0, .y = 8 } } };
    const moving: animation.Track = .{ .target = 1, .property = .{ .motion = .{ .path = &route, .rotate = .auto } } };
    const placed = (try transform(t.allocator, &moving, 0.25)).?;
    try t.expectApproxEqAbs(@as(f64, 2), placed.apply(.zero).y, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 2), placed.apply(.{ .x = 1, .y = 0 }).y - 1, 1e-12);
    const opacity: animation.Track = .{ .target = 1, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } };
    try t.expect(try transform(t.allocator, &opacity, 0.5) == null);
}
