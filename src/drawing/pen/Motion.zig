//! Ordered scale and rotation tracks. Keys interpolate in normalized contour
//! arc length. Polynomial tracks store Bernstein ordinates at degree indices.
//! Rotation angles are unwrapped radians. All slices are borrowed.
const std = @import("std");
const g = @import("../geometry.zig");
const Motion = @This();

pub const Kind = enum { scale, scale_x, scale_y, rotate, path_frame };
pub const Corner = enum { strict, rotate, overlap };
pub const max_degree = 12;
pub const Track = struct { kind: Kind, first: usize, len: usize, polynomial: bool = false, uncertainty: f64 = 0 };
pub const Key = struct { t: f64, value: f64 };
tracks: []const Track,
keys: []const Key,
tolerance: f64 = 0.001,
corner: Corner = .strict,

pub fn validate(self: *const Motion) !void {
    if (!std.math.isFinite(self.tolerance) or self.tolerance <= 0 or self.tracks.len == 0) return error.InvalidMotion;
    var first: usize = 0;
    for (self.tracks) |track| {
        if (!std.math.isFinite(track.uncertainty) or track.uncertainty < 0) return error.InvalidMotion;
        if (track.first != first) return error.InvalidMotion;
        if (track.kind == .path_frame) {
            if (track.len != 0 or track.polynomial or track.uncertainty != 0) return error.InvalidMotion;
            continue;
        }
        if (track.len < 2 or track.len > self.keys.len - first) return error.InvalidMotion;
        if (track.polynomial and track.len > max_degree + 1) return error.InvalidMotion;
        const keys = self.keys[first..][0..track.len];
        if (keys[0].t != 0 or keys[keys.len - 1].t != 1) return error.InvalidMotion;
        for (keys, 0..) |key, i| {
            if (track.kind != .rotate and key.value < 0) return error.InvalidMotion;
            if (!std.math.isFinite(key.t) or !std.math.isFinite(key.value)) return error.InvalidMotion;
            if (i > 0 and (key.t <= keys[i - 1].t or !std.math.isFinite((key.value - keys[i - 1].value) / (key.t - keys[i - 1].t)))) return error.InvalidMotion;
        }
        first += track.len;
    }
    if (first != self.keys.len) return error.InvalidMotion;
}

pub fn clone(self: *const Motion, a: std.mem.Allocator) !*const Motion {
    const copy = try a.create(Motion);
    errdefer a.destroy(copy);
    const tracks = try a.dupe(Track, self.tracks);
    errdefer a.free(tracks);
    copy.* = .{ .tracks = tracks, .keys = try a.dupe(Key, self.keys), .tolerance = self.tolerance, .corner = self.corner };
    return copy;
}

pub fn destroy(self: *const Motion, a: std.mem.Allocator) void {
    a.free(self.tracks);
    a.free(self.keys);
    a.destroy(self);
}

pub fn eql(self: *const Motion, other: *const Motion) bool {
    if (self.tolerance != other.tolerance or self.corner != other.corner or self.tracks.len != other.tracks.len) return false;
    for (self.tracks, other.tracks) |a, b| if (a.kind != b.kind or a.len != b.len or a.polynomial != b.polynomial or a.uncertainty != b.uncertainty) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(self.keys), std.mem.sliceAsBytes(other.keys));
}

pub fn hash(self: *const Motion, seed: u64) u64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&self.tolerance));
    h.update(&.{@backingInt(self.corner)});
    for (self.tracks) |track| {
        h.update(&.{ @backingInt(track.kind), @intFromBool(track.polynomial) });
        h.update(std.mem.asBytes(&track.len));
        const uncertainty = if (track.uncertainty == 0) @as(f64, 0) else track.uncertainty;
        h.update(std.mem.asBytes(&uncertainty));
    }
    h.update(std.mem.sliceAsBytes(self.keys));
    return h.final();
}

fn interval(keys: []const Key, t: f64) usize {
    var lo: usize = 0;
    var hi = keys.len - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (t < keys[mid].t) hi = mid else lo = mid;
    }
    return lo;
}

fn value(keys: []const Key, polynomial: bool, t: f64) f64 {
    if (polynomial) {
        var c: [max_degree + 1]f64 = undefined;
        for (keys, 0..) |k, i| c[i] = k.value;
        var n = keys.len - 1;
        while (n > 0) : (n -= 1) {
            for (0..n) |i| c[i] = (1 - t) * c[i] + t * c[i + 1];
        }
        return c[0];
    }
    const i = interval(keys, t);
    const a = keys[i];
    const b = keys[i + 1];
    const u = (t - a.t) / (b.t - a.t);
    return (1 - u) * a.value + u * b.value;
}

pub fn nextKey(self: *const Motion, t: f64) f64 {
    var next: f64 = 1;
    for (self.tracks) |op| {
        if (op.kind == .path_frame) continue;
        const keys = self.keys[op.first..][0..op.len];
        if (!op.polynomial) next = @min(next, keys[interval(keys, t) + 1].t);
    }
    return next;
}

pub fn usesPathFrame(self: *const Motion) bool {
    for (self.tracks) |op| if (op.kind == .path_frame) return true;
    return false;
}

pub fn constantInProgress(self: *const Motion) bool {
    for (self.tracks) |op| {
        if (op.kind == .path_frame) continue;
        const keys = self.keys[op.first..][0..op.len];
        for (keys[1..]) |key| if (key.value != keys[0].value) return false;
    }
    return true;
}

pub const Context = struct { progress: f64, tangent: ?g.Point = null };

/// Convenience for context-independent motions.
pub fn at(self: *const Motion, t: f64) g.Transform {
    return self.atContext(.{ .progress = t }) catch unreachable;
}

pub fn atContext(self: *const Motion, context: Context) !g.Transform {
    var result: g.Transform = .{};
    for (self.tracks) |op| {
        if (op.kind == .path_frame) {
            result = result.then(try g.Transform.fromXAxis(context.tangent orelse return error.UndefinedPathFrame));
            continue;
        }
        const v = value(self.keys[op.first..][0..op.len], op.polynomial, context.progress);
        result = result.then(switch (op.kind) {
            .scale => g.Transform.scaling(v, v),
            .scale_x => g.Transform.scaling(v, 1),
            .scale_y => g.Transform.scaling(1, v),
            .rotate => g.Transform.rotation(v),
            .path_frame => unreachable,
        });
    }
    return result;
}

/// Build an ordinary motion for a turn in place. Freeze every progress
/// operand at the knot and replace each local frame, in composition order,
/// with a linear rotation track. Storage belongs to the sweep.
pub fn cornerTurn(self: *const Motion, progress: f64, start: f64, angle: f64, tracks: []Track, keys: []Key) Motion {
    for (self.tracks, tracks, 0..) |op, *out, i| {
        const frame = op.kind == .path_frame;
        const first = if (frame) start else value(self.keys[op.first..][0..op.len], op.polynomial, progress);
        keys[2 * i] = .{ .t = 0, .value = first };
        keys[2 * i + 1] = .{ .t = 1, .value = if (frame) start + angle else first };
        out.* = .{ .kind = if (frame) .rotate else op.kind, .first = 2 * i, .len = 2 };
    }
    return .{ .tracks = tracks, .keys = keys, .tolerance = self.tolerance };
}

// Operator norm bounds for a product M(t), M'(t), M''(t).
pub const Bounds = struct {
    scale: f64 = 1,
    speed: f64 = 0,
    acceleration: f64 = 0,
    uncertainty: f64 = 0,
    fn then(self: Bounds, kind: Kind, amplitude: f64, delta: f64, curvature: f64, uncertainty: f64) Bounds {
        const n: f64 = switch (kind) {
            .rotate, .path_frame => 1,
            .scale => amplitude,
            .scale_x, .scale_y => @max(1, amplitude),
        };
        const d2 = curvature + (if (kind == .rotate or kind == .path_frame) delta * delta else 0);
        return .{ .uncertainty = (n + uncertainty) * self.uncertainty + uncertainty * self.scale, .scale = n * self.scale, .speed = delta * self.scale + n * self.speed, .acceleration = d2 * self.scale + 2 * delta * self.speed + n * self.acceleration };
    }
};

// Bernstein convex hulls bound the value and both derivatives on [0,1].
// Multiplication by the interval length reparameterizes derivatives to a slab.
fn trackBounds(keys: []const Key, polynomial: bool) Bounds {
    var b: Bounds = .{ .scale = @abs(keys[0].value) };
    const n: f64 = @floatFromInt(keys.len - 1);
    for (keys[1..], keys[0 .. keys.len - 1], 1..) |k, prev, i| {
        b.scale = @max(b.scale, @abs(k.value));
        const diff = k.value - prev.value;
        const slope = if (polynomial) diff * n else diff / (k.t - prev.t);
        b.speed = @max(b.speed, @abs(slope));
        if (polynomial and i >= 2) b.acceleration = @max(b.acceleration, @abs(diff - (prev.value - keys[i - 2].value)) * n * (n - 1));
    }
    return b;
}

/// Bounds with the path frame held fixed (including progress sensitivity).
pub fn bounds(self: *const Motion) Bounds {
    var b: Bounds = .{};
    for (self.tracks) |op| {
        if (op.kind == .path_frame) continue;
        const k = trackBounds(self.keys[op.first..][0..op.len], op.polynomial);
        b = b.then(op.kind, k.scale, k.speed, k.acceleration, op.uncertainty);
    }
    return b;
}

// Caller splits at every key. Derivatives here are with respect to [0,1]
// on this interval, so the chord interpolation error is bounded by M''/8.
pub fn chordError(self: *const Motion, t0: f64, t1: f64, radius: f64) f64 {
    std.debug.assert(!self.usesPathFrame());
    return self.intervalError(t0, t1, radius, .{});
}

/// Bounds on the frame angle's derivatives in the interval's unit parameter.
pub const AngularBounds = @import("../path/Direction.zig").AngularBounds;

pub fn intervalError(self: *const Motion, t0: f64, t1: f64, radius: f64, frame: AngularBounds) f64 {
    var b: Bounds = .{};
    const dt = t1 - t0;
    for (self.tracks) |op| {
        if (op.kind == .path_frame) {
            b = b.then(op.kind, 1, frame.speed, frame.acceleration, 0);
            continue;
        }
        const keys = self.keys[op.first..][0..op.len];
        if (op.polynomial) {
            const k = trackBounds(keys, true);
            b = b.then(op.kind, k.scale, k.speed * dt, k.acceleration * dt * dt, 0);
        } else {
            const v0 = value(keys, false, t0);
            const v1 = value(keys, false, t1);
            b = b.then(op.kind, @max(@abs(v0), @abs(v1)), @abs(v1 - v0), 0, 0);
        }
    }
    return radius * b.acceleration / 8;
}
