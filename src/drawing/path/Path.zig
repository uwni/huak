//! Allocator-owned native paths. Segment time counts drawable segments,
//! including a nonzero implicit line of a close. Moves and a zero-length close
//! are topology markers and do not consume time.
const std = @import("std");
const g = @import("../geometry.zig");
pub const Point = g.Point;
pub const Cubic = g.Cubic;
pub const KnotTable = @import("KnotTable.zig");
pub const SegmentFrame = @import("SegmentFrame.zig");
pub const CurveReader = @import("CurveReader.zig");
pub const arcs = @import("arcs.zig");
pub const contours = @import("contours.zig");
pub const trim = @import("trim.zig");
pub const intersect = @import("intersect.zig");
pub const cubic_intersect = @import("cubic_intersect.zig");
const place = @import("placement.zig");
const segmentBounds = place.segmentBounds;
const segmentFinite = place.segmentFinite;
const mapSegment = place.mapSegment;
pub const Segment = union(enum) {
    move: Point,
    line: Point,
    cubic: struct { c1: Point, c2: Point, end: Point },
    close: void,
};

pub const PathError = error{ InvalidPath, NonFinite, DisconnectedPath, InvalidParameter };
pub const CurvePosition = struct { curve: Cubic, t: f64 };
const CurveSelection = struct { position: CurvePosition, is_cubic: bool };

const Path = @This();

allocator: std.mem.Allocator,
segments: std.ArrayList(Segment) = .empty,
knots: ?*KnotTable = null,
current: ?Point = null,
start: ?Point = null,
open: bool = false,

pub fn init(allocator: std.mem.Allocator) Path {
    return .{ .allocator = allocator };
}
pub fn deinit(self: *Path) void {
    if (self.knots) |table| {
        table.entries.deinit(self.allocator);
        self.allocator.destroy(table);
    }
    self.segments.deinit(self.allocator);
    self.* = undefined;
}
pub fn moveTo(self: *Path, p: Point) !void {
    if (!p.isFinite()) return error.NonFinite;
    try self.segments.append(self.allocator, .{ .move = p });
    self.current = p;
    self.start = p;
    self.open = true;
}
pub fn lineTo(self: *Path, p: Point) !void {
    if (!p.isFinite()) return error.NonFinite;
    if (!self.open) return error.InvalidPath;
    try self.segments.append(self.allocator, .{ .line = p });
    self.current = p;
}
pub fn cubicTo(self: *Path, c1: Point, c2: Point, end: Point) !void {
    if (!c1.isFinite() or !c2.isFinite() or !end.isFinite()) return error.NonFinite;
    if (!self.open) return error.InvalidPath;
    try self.segments.append(self.allocator, .{ .cubic = .{ .c1 = c1, .c2 = c2, .end = end } });
    self.current = end;
}
pub fn knotRecords(self: *const Path) []const KnotTable.Knot {
    return if (self.knots) |table| table.entries.items else &.{};
}

pub fn reserveKnots(self: *Path, count: usize) !void {
    if (count == 0) return;
    if (self.knots) |table| return table.entries.ensureTotalCapacityPrecise(self.allocator, count);
    const table = try self.allocator.create(KnotTable);
    errdefer self.allocator.destroy(table);
    table.* = .{};
    try table.entries.ensureTotalCapacityPrecise(self.allocator, count);
    self.knots = table;
}
fn growKnots(self: *Path, additional: usize) !void {
    if (additional == 0) return;
    if (self.knots) |table| return table.entries.ensureUnusedCapacity(self.allocator, additional);
    try self.reserveKnots(additional);
}
fn copyKnots(self: *Path, source: *const Path) !void {
    const records = source.knotRecords();
    if (records.len == 0) return;
    try self.reserveKnots(records.len);
    self.knots.?.entries.appendSliceAssumeCapacity(records);
}
pub fn solvedCubicTo(self: *Path, c: Cubic, start: Point, end: Point) !void {
    if (start.eql(.zero) and end.eql(.zero)) return self.cubicTo(c.p1, c.p2, c.p3);
    if (self.segments.items.len >= std.math.maxInt(u32)) return error.InvalidPath;
    const sides = KnotTable.sides(@intCast(self.segments.items.len), c, start, end);
    var extra: usize = @intFromBool(sides[1] != null);
    if (sides[0]) |k| {
        if (self.knots == null or !self.knots.?.mergesStart(k)) extra += 1;
    }
    try self.growKnots(extra);
    try self.cubicTo(c.p1, c.p2, c.p3);
    for (sides) |side| if (side) |k| self.knots.?.push(k);
}
pub fn solvedAt(self: *const Path, index: usize, c: Cubic) [2]Point {
    return if (self.knots) |table| table.directions(self.segments.items, index, c) else .{ .zero, .zero };
}

pub fn close(self: *Path) !void {
    if (!self.open) return error.InvalidPath;
    try self.segments.append(self.allocator, .close);
    if (self.knots) |table| table.close(self.segments.items);
    self.current = self.start;
    self.open = false;
}
pub fn fromCubics(allocator: std.mem.Allocator, curves: []const Cubic, closed: bool) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    if (curves.len == 0) {
        if (closed) return error.InvalidPath;
        return result;
    }
    try result.moveTo(curves[0].p0);
    for (curves) |curve| {
        if (!g.tolerance.points(result.current.?, curve.p0)) return error.DisconnectedPath;
        try result.cubicTo(curve.p1, curve.p2, curve.p3);
    }
    if (closed) try result.close();
    return result;
}
/// Four cubic quarter-arcs, with the usual kappa approximation. This is
/// editable geometry, not an exact rational representation of a circle.
/// A closed rectangle from `origin` across `width` and `height`.
pub fn rectangle(allocator: std.mem.Allocator, origin: Point, width: f64, height: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(origin);
    try result.lineTo(origin.add(.{ .x = width, .y = 0 }));
    try result.lineTo(origin.add(.{ .x = width, .y = height }));
    try result.lineTo(origin.add(.{ .x = 0, .y = height }));
    try result.close();
    return result;
}

pub fn circle(allocator: std.mem.Allocator, center: Point, radius: f64) !Path {
    if (!center.isFinite() or !std.math.isFinite(radius)) return error.NonFinite;
    if (radius <= 0) return error.InvalidParameter;
    var result = Path.init(allocator);
    errdefer result.deinit();
    const kappa = (4.0 / 3.0) * @tan(std.math.pi / 8.0);
    const k = radius * kappa;
    try result.moveTo(center.add(.{ .x = radius, .y = 0 }));
    try result.cubicTo(center.add(.{ .x = radius, .y = k }), center.add(.{ .x = k, .y = radius }), center.add(.{ .x = 0, .y = radius }));
    try result.cubicTo(center.add(.{ .x = -k, .y = radius }), center.add(.{ .x = -radius, .y = k }), center.add(.{ .x = -radius, .y = 0 }));
    try result.cubicTo(center.add(.{ .x = -radius, .y = -k }), center.add(.{ .x = -k, .y = -radius }), center.add(.{ .x = 0, .y = -radius }));
    try result.cubicTo(center.add(.{ .x = k, .y = -radius }), center.add(.{ .x = radius, .y = -k }), center.add(.{ .x = radius, .y = 0 }));
    try result.close();
    return result;
}
pub fn clone(self: Path, allocator: std.mem.Allocator) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    result.segments = .fromOwnedSlice(try allocator.dupe(Segment, self.segments.items));
    try result.copyKnots(&self);
    result.current = self.current;
    result.start = self.start;
    result.open = self.open;
    return result;
}

/// Materialize a borrowed segment bank with validated topology and current
/// point, retaining the construction directions under the new owner.
pub fn copyView(self: *const Path, a: std.mem.Allocator) !Path {
    var out = Path.init(a);
    errdefer out.deinit();
    try out.segments.ensureTotalCapacityPrecise(a, self.segments.items.len);
    for (self.segments.items) |seg| switch (seg) {
        .move => |p| try out.moveTo(p),
        .line => |p| try out.lineTo(p),
        .cubic => |c| try out.cubicTo(c.c1, c.c2, c.end),
        .close => try out.close(),
    };
    try out.copyKnots(self);
    return out;
}

pub fn bounds(self: Path) ?g.BBox {
    return segmentBounds(self.segments.items, .{}, .geometry) catch unreachable;
}

/// Bounds of drawable segments after placement. A move alone has no ink.
pub fn paintedBounds(segments: []const Segment, placement: g.Transform) error{NonFinite}!?g.BBox {
    return segmentBounds(segments, placement, .ink);
}

/// Algebraic area with every subpath implicitly closed. Counterclockwise
/// contours contribute positively in y-up coordinates; holes and self
/// intersections contribute according to their winding.
pub fn signedArea(self: Path) f64 {
    var sum: f64 = 0;
    var origin: Point = .zero;
    var current: Point = .zero;
    for (self.segments.items) |segment| switch (segment) {
        .move => |point| {
            origin = point;
            current = .zero;
        },
        .line => |point| {
            const local = point.sub(origin);
            sum += current.cross(local);
            current = local;
        },
        .cubic => |curve| {
            const local: Cubic = .{
                .p0 = current,
                .p1 = curve.c1.sub(origin),
                .p2 = curve.c2.sub(origin),
                .p3 = curve.end.sub(origin),
            };
            // The integrand x*y'-y*x' has degree at most five. Three-point
            // Gauss-Legendre integrates it exactly before f64 rounding.
            const offset = @sqrt(@as(f64, 3.0 / 5.0)) * 0.5;
            for ([_]f64{ 0.5 - offset, 0.5, 0.5 + offset }, [_]f64{ 5.0 / 18.0, 4.0 / 9.0, 5.0 / 18.0 }) |time, weight| {
                sum += local.at(time).cross(local.derivative(time)) * weight;
            }
            current = local.p3;
        },
        // A closing line to this contour's local origin contributes zero.
        .close => current = .zero,
    };
    return sum * 0.5;
}
pub fn transform(self: *Path, t: g.Transform) !void {
    if (!t.isFinite()) return error.NonFinite;
    // Validate every resulting coordinate before changing the path.
    for (self.segments.items) |*segment| {
        if (!segmentFinite(segment, t)) return error.NonFinite;
    }
    for (self.knotRecords()) |k| _ = try k.mapped(self.segments.items, t);
    if (self.knots) |table| {
        const original = table.entries.items;
        table.entries.items.len = 0;
        for (original) |k| {
            const mapped = k.mapped(self.segments.items, t) catch unreachable;
            if (mapped.incoming != 0 or mapped.outgoing != 0) table.entries.appendAssumeCapacity(mapped);
        }
    }
    for (self.segments.items) |*segment| mapSegment(segment, &t);
    if (self.current) |p| self.current = t.apply(p);
    if (self.start) |p| self.start = t.apply(p);
}
pub fn transformed(self: Path, allocator: std.mem.Allocator, t: g.Transform) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.segments.ensureTotalCapacityPrecise(allocator, self.segments.items.len);
    if (!t.isFinite()) return error.NonFinite;
    try result.reserveKnots(self.knotRecords().len);
    for (self.knotRecords()) |k| {
        const mapped = try k.mapped(self.segments.items, t);
        if (mapped.incoming != 0 or mapped.outgoing != 0) result.knots.?.entries.appendAssumeCapacity(mapped);
    }
    // A fresh result can discard partial work instead of recomputing each
    // coordinate to keep an existing path unchanged on failure.
    for (self.segments.items) |*segment| {
        var mapped = segment.*;
        mapSegment(&mapped, &t);
        if (!segmentFinite(&mapped, null)) return error.NonFinite;
        result.segments.appendAssumeCapacity(mapped);
    }
    result.current = if (self.current) |point| t.apply(point) else null;
    result.start = if (self.start) |point| t.apply(point) else null;
    result.open = self.open;
    return result;
}
pub fn prepareKnotAppend(self: *Path, other: Path, offset: usize) !void {
    const records = other.knotRecords();
    if (records.len == 0) return;
    if (offset > std.math.maxInt(u32) - records[records.len - 1].index) return error.InvalidPath;
    try self.growKnots(records.len);
}
pub fn appendKnots(self: *Path, other: Path, offset: usize, matrix: ?g.Transform) void {
    for (other.knotRecords()) |k| {
        var placed = if (matrix) |t| k.mapped(other.segments.items, t) catch unreachable else k;
        if (placed.incoming == 0 and placed.outgoing == 0) continue;
        placed.index += @intCast(offset);
        self.knots.?.push(placed);
    }
}
/// Append subpaths, preserving moves and drawing order.
pub fn append(self: *Path, other: Path) !void {
    if (self.segments.items.ptr == other.segments.items.ptr and other.segments.items.len != 0) return error.InvalidPath;
    const offset = self.segments.items.len;
    try self.prepareKnotAppend(other, offset);
    try self.segments.appendSlice(self.allocator, other.segments.items);
    self.appendKnots(other, offset, null);
    if (other.current != null) {
        self.current = other.current;
        self.start = other.start;
        self.open = other.open;
    }
}
pub fn reverse(self: Path, allocator: std.mem.Allocator) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    var subpath_end = self.segments.items.len;
    while (subpath_end != 0) {
        var subpath_begin = subpath_end - 1;
        while (self.segments.items[subpath_begin] != .move) {
            if (subpath_begin == 0) return error.InvalidPath;
            subpath_begin -= 1;
        }
        const first = switch (self.segments.items[subpath_begin]) {
            .move => |p| p,
            else => return error.InvalidPath,
        };
        var last = first;
        for (self.segments.items[subpath_begin + 1 .. subpath_end], subpath_begin + 1..) |segment, index| {
            switch (segment) {
                .move => return error.InvalidPath,
                .line => |p| last = p,
                .cubic => |c| last = c.end,
                .close => {
                    if (index + 1 != subpath_end) return error.InvalidPath;
                },
            }
        }
        const closed = subpath_end > subpath_begin + 1 and self.segments.items[subpath_end - 1] == .close;
        try result.moveTo(if (closed) first else last);
        // Reverse the implicit closing edge first, retaining the original
        // final point as time zero. A final zero-length CLOSE below marks
        // topology without adding another drawable segment time.
        if (closed and !last.eql(first)) try result.lineTo(last);
        var i = if (closed) subpath_end - 1 else subpath_end;
        while (i > subpath_begin + 1) {
            i -= 1;
            const previous = switch (self.segments.items[i - 1]) {
                .move, .line => |p| p,
                .cubic => |c| c.end,
                .close => return error.InvalidPath,
            };
            switch (self.segments.items[i]) {
                .line => try result.lineTo(previous),
                .cubic => |c| {
                    const src: Cubic = .{ .p0 = previous, .p1 = c.c1, .p2 = c.c2, .p3 = c.end };
                    const dirs = self.solvedAt(i, src);
                    try result.solvedCubicTo(src.reversed(), dirs[1].scale(-1), dirs[0].scale(-1));
                },
                else => return error.InvalidPath,
            }
        }
        if (closed) try result.close();
        subpath_end = subpath_begin;
    }
    return result;
}

pub fn segmentCount(self: Path) usize {
    var count: usize = 0;
    var current: Point = .zero;
    var start: Point = .zero;
    for (self.segments.items) |segment| switch (segment) {
        .move => |p| {
            current = p;
            start = p;
        },
        .line => |p| {
            current = p;
            count += 1;
        },
        .cubic => |c| {
            current = c.end;
            count += 1;
        },
        .close => {
            if (!current.eql(start)) count += 1;
            current = start;
        },
    };
    return count;
}
/// Select a drawable segment and its local Bezier parameter. An integer
/// boundary selects the following segment, including after a pen-up move;
/// the final endpoint selects the last segment at t=1. Zero-length CLOSE
/// markers do not consume time. A path without drawable segments has no
/// valid segment parameter.
pub fn curveAt(self: Path, time: f64) PathError!CurvePosition {
    return (try self.selectCurveAt(time)).position;
}

pub fn selectCurveAt(self: Path, time: f64) PathError!CurveSelection {
    const count = self.segmentCount();
    if (count == 0 or !std.math.isFinite(time) or time < 0 or time > @as(f64, @floatFromInt(count))) return error.InvalidParameter;
    const index = @min(@as(usize, @intFromFloat(time)), count - 1);
    var reader: CurveReader = .{ .segments = self.segments.items };
    const selected = try reader.read(index);
    return .{ .position = .{ .curve = selected.curve, .t = time - @as(f64, @floatFromInt(index)) }, .is_cubic = selected.is_cubic };
}

pub fn pointAt(self: Path, time: f64) PathError!Point {
    const selected = try self.curveAt(time);
    const point = selected.curve.at(selected.t);
    if (!point.isFinite()) return error.NonFinite;
    return point;
}

test {
    _ = @import("SegmentFrame.zig");
    _ = @import("arcs.zig");
    _ = @import("trim_test.zig");
    _ = @import("cubic_intersect_test.zig");
    _ = @import("intersect_test.zig");
    _ = @import("contours_test.zig");
    _ = @import("edit_test.zig");
    _ = @import("knots_test.zig");
    _ = @import("queries_test.zig");
}
