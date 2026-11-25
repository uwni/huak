//! Contours: owned subpaths, contour ranges, the axis of one straight contour, joining, and appending a transformed path.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Path = @import("Path.zig");
const place = @import("placement.zig");
const segmentFinite = place.segmentFinite;
const mapSegment = place.mapSegment;

/// Split at every move, preserving contour order, exact geometry, winding
/// and open/closed state, including move-only contours. This does not group
/// holes with their enclosing contours or resolve intersections. The caller
/// owns each returned path and the slice, all allocated with allocator.
pub fn subpaths(self: Path, allocator: std.mem.Allocator) ![]Path {
    var count: usize = 0;
    for (self.segments.items) |segment| {
        if (segment == .move) count += 1;
    }
    const result = try allocator.alloc(Path, count);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*part| part.deinit();
        allocator.free(result);
    }
    var begin: usize = 0;
    while (begin < self.segments.items.len) {
        if (self.segments.items[begin] != .move) return error.InvalidPath;
        var end = begin + 1;
        while (end < self.segments.items.len and self.segments.items[end] != .move) : (end += 1) {}
        const part = &result[initialized];
        part.* = Path.init(allocator);
        initialized += 1;
        try part.segments.ensureTotalCapacityPrecise(allocator, end - begin);
        for (self.segments.items[begin..end], begin..) |segment, index| switch (segment) {
            .move => |point| try part.moveTo(point),
            .line => |point| try part.lineTo(point),
            .cubic => |curve| {
                const c: Cubic = .{ .p0 = part.current orelse return error.InvalidPath, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end };
                const dirs = self.solvedAt(index, c);
                try part.solvedCubicTo(c, dirs[0], dirs[1]);
            },
            .close => try part.close(),
        };
        begin = end;
    }
    return result;
}

/// Append another path with a transform applied to every point. This
/// avoids materializing a transformed temporary and then appending it.
pub fn appendTransformed(self: *Path, other: Path, t: g.Transform) !void {
    if (self.segments.items.ptr == other.segments.items.ptr and other.segments.items.len != 0) return error.InvalidPath;
    if (!t.isFinite()) return error.NonFinite;
    const offset = self.segments.items.len;
    for (other.knotRecords()) |k| _ = try k.mapped(other.segments.items, t);
    try self.prepareKnotAppend(other, offset);
    // Validate every result before changing this path.
    for (other.segments.items) |*segment| {
        if (!segmentFinite(segment, t)) return error.NonFinite;
    }
    try self.segments.ensureUnusedCapacity(self.allocator, other.segments.items.len);
    for (other.segments.items) |*segment| {
        var mapped = segment.*;
        mapSegment(&mapped, &t);
        self.segments.appendAssumeCapacity(mapped);
    }
    self.appendKnots(other, offset, t);
    if (other.current) |current| {
        self.current = t.apply(current);
        if (other.start) |start| self.start = t.apply(start);
        self.open = other.open;
    }
}

/// Connect a single open subpath whose first point matches this endpoint.
/// A mismatch is diagnosed instead of silently inserting a connector.
pub fn join(self: *Path, other: Path) !void {
    if (!self.open or !other.open or other.segments.items.len == 0) return error.InvalidPath;
    if (self.segments.items.ptr == other.segments.items.ptr) return error.InvalidPath;
    const first = switch (other.segments.items[0]) {
        .move => |p| p,
        else => return error.InvalidPath,
    };
    if (!g.tolerance.points(self.current.?, first)) return error.DisconnectedPath;
    for (other.segments.items[1..]) |segment| switch (segment) {
        .move => return error.InvalidPath,
        else => {},
    };
    const offset = self.segments.items.len - 1;
    try self.prepareKnotAppend(other, offset);
    try self.segments.appendSlice(self.allocator, other.segments.items[1..]);
    self.appendKnots(other, offset, null);
    self.current = other.current;
    self.open = other.open;
}

pub const ContourRange = struct { begin: f64, end: f64, closed: bool = false };

/// Global drawable-segment times for each contour, including move-only contours.
/// Closure records the explicit CLOSE command. The caller owns the result.
pub fn contourRanges(self: Path, allocator: std.mem.Allocator) ![]ContourRange {
    var contours: std.ArrayList(ContourRange) = .empty;
    errdefer contours.deinit(allocator);
    var time: f64 = 0;
    var current: ?Point = null;
    var start: ?Point = null;
    for (self.segments.items) |segment| {
        switch (segment) {
            .move => |point| {
                if (!point.isFinite()) return error.NonFinite;
                try contours.append(allocator, .{ .begin = time, .end = time });
                current = point;
                start = point;
            },
            .line, .cubic => {
                if (current == null) return error.InvalidPath;
                if (segment == .line) {
                    if (!segment.line.isFinite()) return error.NonFinite;
                    current = segment.line;
                } else {
                    const controls = segment.cubic;
                    if (!controls.c1.isFinite() or !controls.c2.isFinite() or !controls.end.isFinite()) return error.NonFinite;
                    current = controls.end;
                }
                time += 1;
                contours.items[contours.items.len - 1].end = time;
            },
            .close => {
                if (current == null or start == null) return error.InvalidPath;
                if (!current.?.eql(start.?)) time += 1;
                contours.items[contours.items.len - 1].end = time;
                contours.items[contours.items.len - 1].closed = true;
                current = null;
                start = null;
            },
        }
    }
    return contours.toOwnedSlice(allocator);
}

/// A spatial linear gradient equals an arc-length gradient on a single
/// straight contour traversed in one direction. Retracing it breaks equality.
pub fn linearAxis(self: Path) ?[2]Point {
    const segments = self.segments.items;
    if (segments.len < 2 or segments[0] != .move) return null;
    const first = segments[0].move;
    const last = switch (segments[segments.len - 1]) {
        .line => |p| p,
        .cubic => |c| c.end,
        else => return null,
    };
    if (first.eql(last)) return null;
    const dx = @as(f128, last.x) - first.x;
    const dy = @as(f128, last.y) - first.y;
    const horizontal = @abs(dx) >= @abs(dy);
    const sign: f128 = if ((if (horizontal) dx else dy) > 0) 1 else -1;
    var previous: f128 = if (horizontal) first.x else first.y;
    for (segments[1..]) |segment| {
        const control: [3]Point = switch (segment) {
            .line => |p| @splat(p),
            .cubic => |c| .{ c.c1, c.c2, c.end },
            else => return null,
        };
        var delta: [3]f128 = undefined;
        for (control, &delta) |p, *d| {
            if (dx * (@as(f128, p.y) - first.y) != dy * (@as(f128, p.x) - first.x)) return null;
            const coordinate: f128 = if (horizontal) p.x else p.y;
            d.* = (coordinate - previous) * sign;
            previous = coordinate;
        }
        // The derivative is a quadratic in Bernstein form. Its middle
        // coefficient may be negative even when the whole curve is monotone.
        if (delta[0] < 0 or delta[2] < 0 or
            (delta[1] < 0 and delta[1] * delta[1] > delta[0] * delta[2])) return null;
    }
    return .{ first, last };
}
