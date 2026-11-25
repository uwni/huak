//! The index of source segments and contours that a crossing query reads: per-contour branches, ownership, and the rays incident at a node.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../Path.zig");
const Allocator = std.mem.Allocator;
const crossings = @import("../crossings.zig");
const Sources = @This();

segments: std.ArrayList(Segment) = .empty,
contours: std.ArrayList(Contour) = .empty,

pub fn deinit(self: *Sources, allocator: Allocator) void {
    self.segments.deinit(allocator);
    self.contours.deinit(allocator);
}

pub fn init(allocator: Allocator, input: []const Path, limit: usize) !Sources {
    var result: Sources = .{};
    errdefer result.deinit(allocator);
    var remaining = limit;
    try crossings.consume(&remaining, input.len);
    for (input, 0..) |path, path_index| {
        try crossings.consume(&remaining, path.segments.items.len);
        var current: g.Point = .zero;
        var start: g.Point = .zero;
        var active: ?usize = null;
        var contour_index: usize = 0;
        var time: f64 = 0;
        for (path.segments.items) |segment| {
            if (segment == .move) {
                if (!segment.move.isFinite()) return error.NonFinite;
                current = segment.move;
                start = current;
                active = result.contours.items.len;
                try result.contours.append(allocator, .{ .path = path_index, .index = contour_index, .first = result.segments.items.len });
                contour_index += 1;
                continue;
            }
            const contour = active orelse return error.InvalidPath;
            if (segment != .close or !current.eql(start)) {
                const curve: g.Cubic = switch (segment) {
                    .line => |point| .line(current, point),
                    .cubic => |curve| .{ .p0 = current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end },
                    .close => .line(current, start),
                    .move => unreachable,
                };
                if (!curve.isFinite()) return error.NonFinite;
                try result.segments.append(allocator, .{ .curve = curve, .contour = contour, .time = time, .cubic = segment == .cubic });
                time += 1;
                result.contours.items[contour].count += 1;
                current = curve.p3;
            }
            if (segment == .close) {
                result.contours.items[contour].closed = true;
                active = null;
            }
        }
    }
    return result;
}

pub fn branch(self: *const Sources, segment: Segment, local: f64) crossings.Branch {
    const contour = self.contours.items[segment.contour];
    return .{ .path = contour.path, .contour = contour.index, .time = segment.time + local };
}

pub fn owns(self: *const Sources, index: usize, local: f64) bool {
    if (local != 1) return true;
    const contour = self.contours.items[self.segments.items[index].contour];
    // Half-open segment domains give a shared node to its outgoing
    // segment at t=0. A closed seam belongs to the first segment; only an
    // open final endpoint retains t=1. No spatial/time epsilon is involved.
    return !contour.closed and index + 1 == contour.first + contour.count;
}

/// The two rays leaving this source position, towards the past/future.
/// At a node they come from its incident segments, including a closed seam.
pub fn rays(self: *const Sources, index: usize, local: f64) ![2]g.Point {
    const segment = self.segments.items[index];
    if (local > 0 and local < 1) {
        const unit = try direction(segment.curve, local);
        return .{ unit.scale(-1), unit };
    }
    const contour = self.contours.items[segment.contour];
    const end = contour.first + contour.count;
    const before = if (local == 1) index else if (index > contour.first) index - 1 else if (contour.closed) end - 1 else return error.NonTransverseCrossing;
    const after = if (local == 0) index else if (index + 1 < end) index + 1 else if (contour.closed) contour.first else return error.NonTransverseCrossing;
    return .{ (try direction(self.segments.items[before].curve, 1)).scale(-1), try direction(self.segments.items[after].curve, 0) };
}

const Contour = struct {
    path: usize,
    index: usize,
    first: usize,
    count: usize = 0,
    closed: bool = false,
};

pub const Segment = struct { curve: g.Cubic, contour: usize, time: f64, cubic: bool };

fn direction(curve: g.Cubic, time: f64) !g.Point {
    return curve.derivative(time).normalized() catch |err| return if (err == error.NonFinite) error.ResolutionLimit else error.NonTransverseCrossing;
}
