//! Allocator-owned native paths. Segment time counts drawable segments,
//! including a nonzero implicit line of a close. Moves and a zero-length close
//! are topology markers and do not consume time.
const std = @import("std");
const g = @import("../geometry.zig");
pub const Point = g.Point;
pub const Cubic = g.Cubic;
const Direction = @import("Direction.zig");
pub const KnotTable = @import("KnotTable.zig");
/// Local coordinates of a drawable segment. The origin travels on the
/// source curve; the axes follow its tangent and left normal.
pub const SegmentFrame = struct {
    curve: Cubic,
    cubic: bool,
    direction: Direction,
    start: Point = .zero,
    end: Point = .zero,

    pub fn init(curve: Cubic, cubic: bool) !SegmentFrame {
        return .{ .curve = curve, .cubic = cubic, .direction = try Direction.init(curve, cubic) };
    }

    pub fn ray(self: *const SegmentFrame, u: f64) Direction.Ray {
        if (u == 0 and !self.start.eql(.zero)) return .{ self.start.x, self.start.y };
        if (u == 1 and !self.end.eql(.zero)) return .{ self.end.x, self.end.y };
        return self.direction.ray(u);
    }

    pub fn useSolved(self: *SegmentFrame, dirs: [2]Point, max_delta: f64) !void {
        self.start = dirs[0];
        self.end = dirs[1];
        // Interior derivatives still belong to the stored cubic. Charge the
        // endpoint rotation difference to the sweep's spatial error budget.
        inline for (.{ self.start, self.end }, .{ @as(f64, 0), @as(f64, 1) }) |v, u| {
            if (!v.eql(.zero)) {
                const raw = try (try self.direction.at(u)).normalized();
                if (raw.distance(try v.normalized()) > max_delta) return error.PrecisionRange;
            }
        }
    }

    pub fn point(self: *const SegmentFrame, u: f64) Point {
        return if (self.cubic) self.curve.at(u) else self.curve.p0.lerp(self.curve.p3, u);
    }

    pub fn at(self: *const SegmentFrame, u: f64) !g.Transform {
        if (!std.math.isFinite(u) or u < 0 or u > 1) return error.InvalidParameter;
        const origin = self.point(u);
        const basis = try g.Transform.fromXAxis(try Direction.narrow(self.ray(u)));
        return basis.then(.translation(origin.x, origin.y));
    }
};
pub const Segment = union(enum) {
    move: Point,
    line: Point,
    cubic: struct { c1: Point, c2: Point, end: Point },
    close: void,
};

inline fn mapSegment(segment: *Segment, matrix: *const g.Transform) void {
    switch (segment.*) {
        .move, .line => |*point| point.* = matrix.apply(point.*),
        .cubic => |*curve| {
            curve.c1 = matrix.apply(curve.c1);
            curve.c2 = matrix.apply(curve.c2);
            curve.end = matrix.apply(curve.end);
        },
        .close => {},
    }
}

inline fn pointFinite(point: Point, matrix: ?g.Transform) bool {
    return (if (matrix) |mapping| mapping.apply(point) else point).isFinite();
}

inline fn segmentFinite(segment: *const Segment, matrix: ?g.Transform) bool {
    return switch (segment.*) {
        .move, .line => |point| pointFinite(point, matrix),
        .cubic => |curve| pointFinite(curve.c1, matrix) and pointFinite(curve.c2, matrix) and pointFinite(curve.end, matrix),
        .close => true,
    };
}

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
fn solvedAt(self: *const Path, index: usize, c: Cubic) [2]Point {
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

/// An oriented circular arc, approximated by cubic spans of at most 90 degrees.
pub fn arc(allocator: std.mem.Allocator, center: Point, radius: f64, start: f64, sweep: f64) !Path {
    try validateArc(radius, start, sweep);
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.segments.ensureTotalCapacityPrecise(allocator, 1 + arcSpans(sweep));
    try path.moveTo(center.add((Point{ .x = @cos(start), .y = @sin(start) }).scale(radius)));
    try path.appendArc(center, radius, start, sweep);
    return path;
}

/// Cubic spans that `appendArc` uses for `sweep`: at most a quarter turn each.
pub fn arcSpans(sweep: f64) usize {
    return @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 2.0)));
}

/// Continue the current subpath along an oriented circular arc around
/// `center`. The current point is the arc start, at angle `start`; each span
/// uses the standard endpoint-exact kappa, so the curve stays editable cubics.
pub fn appendArc(self: *Path, center: Point, radius: f64, start: f64, sweep: f64) !void {
    try validateArc(radius, start, sweep);
    if (!self.open) return error.InvalidPath;
    const count = arcSpans(sweep);
    const step = sweep / @as(f64, @floatFromInt(count));
    const k = radius * (4.0 / 3.0) * @tan(step / 4);
    var angle = start;
    var radial: Point = .{ .x = @cos(angle), .y = @sin(angle) };
    for (0..count) |_| {
        const c1 = self.current.?.add(.{ .x = -radial.y * k, .y = radial.x * k });
        angle += step;
        radial = .{ .x = @cos(angle), .y = @sin(angle) };
        const end = center.add(radial.scale(radius));
        try self.cubicTo(c1, end.add(.{ .x = radial.y * k, .y = -radial.x * k }), end);
    }
}

fn validateArc(radius: f64, start: f64, sweep: f64) error{InvalidParameter}!void {
    if (!std.math.isFinite(start) or !std.math.isFinite(sweep) or !std.math.isFinite(radius) or
        radius <= 0 or sweep == 0 or @abs(sweep) > 2 * std.math.pi) return error.InvalidParameter;
}
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
pub fn bounds(self: Path) ?g.BBox {
    return segmentBounds(self.segments.items, .{}, .geometry) catch unreachable;
}

/// Bounds of drawable segments after placement. A move alone has no ink.
pub fn paintedBounds(segments: []const Segment, placement: g.Transform) error{NonFinite}!?g.BBox {
    return segmentBounds(segments, placement, .ink);
}

fn segmentBounds(segments: []const Segment, placement: g.Transform, comptime kind: enum { geometry, ink }) error{NonFinite}!?g.BBox {
    var result: ?g.BBox = null;
    var current: Point = if (kind == .ink) placement.apply(.zero) else .zero;
    var start = current;
    for (segments) |raw| {
        var segment = raw;
        if (kind == .ink) mapSegment(&segment, &placement);
        const box: g.BBox = switch (segment) {
            .move => |p| blk: {
                current = p;
                start = p;
                if (kind == .ink) continue;
                break :blk .fromPoint(p);
            },
            .line => |p| blk: {
                const b = g.BBox.fromPoints(current, p);
                current = p;
                break :blk b;
            },
            .cubic => |c| blk: {
                const curve: Cubic = .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end };
                if (kind == .ink and !curve.isFinite()) return error.NonFinite;
                current = c.end;
                break :blk curve.bounds();
            },
            .close => blk: {
                const b = g.BBox.fromPoints(current, start);
                current = start;
                break :blk b;
            },
        };
        if (kind == .ink and (!box.min.isFinite() or !box.max.isFinite())) return error.NonFinite;
        result = if (result) |b| b.unite(box) else box;
    }
    return result;
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
fn prepareKnotAppend(self: *Path, other: Path, offset: usize) !void {
    const records = other.knotRecords();
    if (records.len == 0) return;
    if (offset > std.math.maxInt(u32) - records[records.len - 1].index) return error.InvalidPath;
    try self.growKnots(records.len);
}
fn appendKnots(self: *Path, other: Path, offset: usize, matrix: ?g.Transform) void {
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

test "appendArc continues the current point exactly as arc constructs it" {
    var whole = try Path.arc(std.testing.allocator, .{ .x = 3, .y = -2 }, 5, 0.25, -2.5);
    defer whole.deinit();
    try std.testing.expectEqual(@as(usize, 1 + arcSpans(-2.5)), whole.segments.items.len);
    try std.testing.expectEqual(whole.segments.items.len, whole.segments.capacity);

    var continued = Path.init(std.testing.allocator);
    defer continued.deinit();
    try std.testing.expectError(error.InvalidPath, continued.appendArc(.{ .x = 3, .y = -2 }, 5, 0.25, -2.5));
    try continued.moveTo(whole.segments.items[0].move);
    try continued.appendArc(.{ .x = 3, .y = -2 }, 5, 0.25, -2.5);
    try std.testing.expectEqualSlices(Segment, whole.segments.items, continued.segments.items);
    try std.testing.expectError(error.InvalidParameter, continued.appendArc(.zero, 0, 0, 1));
}

test "contour ranges distinguish CLOSE from an open return to the start" {
    var p = Path.init(std.testing.allocator);
    defer p.deinit();
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 2, .y = 3 });
    try p.lineTo(.zero);
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 4, .y = 1 });
    try p.close();
    try p.moveTo(.zero);
    try p.close();
    const ranges = try p.contourRanges(std.testing.allocator);
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqualSlices(ContourRange, &.{
        .{ .begin = 0, .end = 2 },
        .{ .begin = 2, .end = 4, .closed = true },
        .{ .begin = 4, .end = 4, .closed = true },
    }, ranges);
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

test "a straight cubic admits an arc-length gradient exactly while its direction is monotone" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 3, .y = 3 }, .{ .x = 2, .y = 2 }, .{ .x = 5, .y = 5 });
    try std.testing.expectEqual(Point{ .x = 5, .y = 5 }, curve.linearAxis().?[1]);
    try curve.lineTo(.{ .x = 4, .y = 4 });
    try std.testing.expect(curve.linearAxis() == null);
    curve.segments.items.len = 2;
    curve.segments.items[1].cubic.c2 = .{ .x = -4, .y = -4 };
    try std.testing.expect(curve.linearAxis() == null);
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

fn selectCurveAt(self: Path, time: f64) PathError!CurveSelection {
    const count = self.segmentCount();
    if (count == 0 or !std.math.isFinite(time) or time < 0 or time > @as(f64, @floatFromInt(count))) return error.InvalidParameter;
    const index = @min(@as(usize, @intFromFloat(time)), count - 1);
    var reader: CurveReader = .{ .segments = self.segments.items };
    const selected = try reader.read(index);
    return .{ .position = .{ .curve = selected.curve, .t = time - @as(f64, @floatFromInt(index)) }, .is_cubic = selected.is_cubic };
}

/// Advances in drawable-segment time. Moves and empty closing edges consume no time.
pub const CurveReader = struct {
    segments: []const Segment,
    current: Point = .zero,
    start: Point = .zero,
    open: bool = false,

    pub fn read(self: *CurveReader, skip: usize) PathError!struct { curve: Cubic, is_cubic: bool } {
        var remaining = skip;
        var current = self.current;
        var start = self.start;
        var open = self.open;
        for (self.segments, 0..) |segment, i| {
            if (segment == .move) {
                if (!segment.move.isFinite()) return error.NonFinite;
                current = segment.move;
                start = current;
                open = true;
                continue;
            }
            if (!open) return error.InvalidPath;
            open = segment != .close;
            if (!open and current.eql(start)) continue;
            const curve: Cubic = switch (segment) {
                .line => |point| .line(current, point),
                .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
                .close => .line(current, start),
                .move => unreachable,
            };
            if (!curve.isFinite()) return error.NonFinite;
            current = curve.p3;
            if (remaining == 0) {
                self.* = .{ .segments = self.segments[i + 1 ..], .current = current, .start = start, .open = open };
                return .{ .curve = curve, .is_cubic = segment == .cubic };
            }
            remaining -= 1;
        }
        return error.InvalidPath;
    }
};

pub fn pointAt(self: Path, time: f64) PathError!Point {
    const selected = try self.curveAt(time);
    const point = selected.curve.at(selected.t);
    if (!point.isFinite()) return error.NonFinite;
    return point;
}

/// The parameter derivative, without normalization. A stationary point has
/// a zero derivative; callers requiring a unit direction must handle it.
pub fn tangentAt(self: Path, time: f64) PathError!Point {
    const selected = try self.curveAt(time);
    const tangent = selected.curve.derivative(selected.t);
    if (!tangent.isFinite()) return error.NonFinite;
    return tangent;
}

/// All distinct spatial intersections, visiting each self segment against
/// each other segment in traversal order; points are not globally sorted
/// by self's parameter. The caller owns the result. Residual checks and
/// coincident/unresolved curve diagnostics come from intersectCubics;
/// points within tolerance are merged, including shared segment endpoints.
pub fn intersections(self: Path, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Point {
    return self.collectIntersections(Point, allocator, other, tolerance);
}

/// Intersections ordered by each path's drawable-segment time, a then b.
/// MOVE and zero-length CLOSE consume no time; a nonzero CLOSE consumes
/// one segment. Closed start/end times remain distinct. Spatial tolerance
/// belongs only to intersectCubics, never to parameter deduplication.
/// Only exactly equal parameter pairs and root points are merged, so
/// disconnected endpoints at the same integer time remain distinguishable.
/// The caller owns the result; point retains the underlying solver's value.
pub fn intersectionDetails(self: Path, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Intersection {
    return self.collectIntersections(Intersection, allocator, other, tolerance);
}

fn collectIntersections(self: Path, comptime Result: type, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Result {
    if (!std.math.isFinite(tolerance) or tolerance <= 0) return error.NonFinite;
    var result: std.ArrayList(Result) = .empty;
    errdefer result.deinit(allocator);
    const first_count = self.segmentCount();
    const second_count = other.segmentCount();
    var outer: CurveReader = .{ .segments = self.segments.items };
    for (0..first_count) |i| {
        const first = (try outer.read(0)).curve;
        var inner: CurveReader = .{ .segments = other.segments.items };
        for (0..second_count) |j| {
            const second = (try inner.read(0)).curve;
            const hits = try intersectCubics(allocator, first, second, tolerance);
            defer allocator.free(hits);
            for (hits) |hit| {
                const value: Result = if (Result == Point) hit.point else .{ .point = hit.point, .a = @as(f64, @floatFromInt(i)) + hit.a, .b = @as(f64, @floatFromInt(j)) + hit.b };
                var duplicate = false;
                for (result.items) |old| {
                    if (if (Result == Point) old.distance(value) <= tolerance else old.a == value.a and old.b == value.b and old.point.eql(value.point)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try result.append(allocator, value);
            }
        }
    }
    if (Result == Intersection) std.mem.sort(Intersection, result.items, {}, struct {
        fn less(_: void, left: Intersection, right: Intersection) bool {
            return left.a < right.a or (left.a == right.a and left.b < right.b);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}
/// Cut by drawable-segment parameter, preserving exact cubic geometry and
/// pen-up discontinuities. A reversed interval returns the reversed cut.
/// A zero-width cut selects the same segment boundary as curveAt.
pub fn trimmed(self: Path, allocator: std.mem.Allocator, begin: f64, end: f64) anyerror!Path {
    const count: f64 = @floatFromInt(self.segmentCount());
    if (!std.math.isFinite(begin) or !std.math.isFinite(end) or begin < 0 or end < 0 or begin > count or end > count) return error.InvalidParameter;
    if (begin > end) {
        var forward = try self.trimmed(allocator, end, begin);
        defer forward.deinit();
        return forward.reverse(allocator);
    }
    if (begin == 0 and end == count) return self.clone(allocator);
    var result = Path.init(allocator);
    errdefer result.deinit();
    if (begin == end) {
        const selected = try self.selectCurveAt(begin);
        const point = selected.position.curve.at(selected.position.t);
        try result.moveTo(point);
        if (selected.is_cubic) try result.cubicTo(point, point, point) else try result.lineTo(point);
        return result;
    }
    var time: f64 = 0;
    var current: Point = .zero;
    var start: Point = .zero;
    var need_move = true;
    var subpath_time: f64 = 0;
    for (self.segments.items, 0..) |segment, index| {
        if (segment == .move) {
            current = segment.move;
            start = current;
            need_move = true;
            subpath_time = time;
            continue;
        }
        if (segment == .close and current.eql(start)) {
            if (begin <= subpath_time and end >= time and result.open) try result.close();
            current = start;
            continue;
        }
        const curve: Cubic = switch (segment) {
            .line => |p| .line(current, p),
            .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
            .close => .line(current, start),
            .move => unreachable,
        };
        const lo = @max(0, begin - time);
        const hi = @min(1, end - time);
        if (lo <= hi and hi >= 0 and lo <= 1 and time <= end and time + 1 >= begin) {
            // Skip boundary-only fragments when a nonempty interval exists.
            if (hi > lo) {
                const cut = try curve.trimmed(lo, hi);
                if (need_move or result.current == null) try result.moveTo(cut.p0);
                if (segment == .cubic) {
                    const dirs = self.solvedAt(index, curve);
                    try result.solvedCubicTo(cut, if (lo == 0) dirs[0] else .zero, if (hi == 1) dirs[1] else .zero);
                } else if (segment == .close and begin <= subpath_time and hi == 1) {
                    try result.close();
                } else try result.lineTo(cut.p3);
                need_move = false;
            }
        }
        current = curve.p3;
        time += 1;
    }
    return result;
}

/// Exact centerline clipping to a rectangle. Intersections split native
/// cubics using de Casteljau; retained fragments keep their controls.
/// This operation clips drawn paths. Filled pictures use a scene clip group
/// so the renderer can preserve the fill rule and boundary edges.
pub fn clippedToRect(self: Path, allocator: std.mem.Allocator, rect: g.BBox) !Path {
    if (!rect.min.isFinite() or !rect.max.isFinite() or rect.min.x > rect.max.x or rect.min.y > rect.max.y) return error.InvalidParameter;
    var result = Path.init(allocator);
    errdefer result.deinit();
    var current: Point = .zero;
    var start: Point = .zero;
    var need_move = true;
    var contour_kept = true;
    for (self.segments.items, 0..) |segment, index| {
        if (segment == .move) {
            current = segment.move;
            start = current;
            need_move = true;
            contour_kept = true;
            continue;
        }
        const curve: Cubic = switch (segment) {
            .line => |p| .line(current, p),
            .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
            .close => .line(current, start),
            .move => unreachable,
        };
        var cuts: std.ArrayList(f64) = .empty;
        defer cuts.deinit(allocator);
        try cuts.appendSlice(allocator, &.{ 0, 1 });
        inline for (.{ "x", "y" }) |axis| {
            const v0 = @field(curve.p0, axis);
            const v1 = @field(curve.p1, axis);
            const v2 = @field(curve.p2, axis);
            const v3 = @field(curve.p3, axis);
            for ([_]f64{ @field(rect.min, axis), @field(rect.max, axis) }) |boundary| {
                const roots = cubicRootsUnit(allocator, bezierPolynomial(v0, v1, v2, v3, boundary)) catch |err| switch (err) {
                    error.CoincidentCurves => continue,
                    else => return err,
                };
                defer allocator.free(roots);
                // Distinct rectangle crossings may be very close in
                // parameter space while far apart in path coordinates.
                // Keep their event identities; exact duplicates are
                // discarded by the interval loop below.
                try cuts.appendSlice(allocator, roots);
            }
        }
        std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
        for (0..cuts.items.len - 1) |i| {
            const lo = cuts.items[i];
            const hi = cuts.items[i + 1];
            if (hi <= lo) continue;
            if (!rect.contains(curve.at((lo + hi) * 0.5))) {
                need_move = true;
                contour_kept = false;
                continue;
            }
            var fragment = try curve.trimmed(lo, hi);
            // Both adjoining fragments use the same source event point,
            // rather than comparing coordinates with an origin-dependent
            // relative tolerance.
            fragment.p0 = curve.at(lo);
            fragment.p3 = curve.at(hi);
            if (need_move or result.current == null or !result.current.?.eql(fragment.p0)) try result.moveTo(fragment.p0);
            if (segment == .cubic) {
                const dirs = self.solvedAt(index, curve);
                try result.solvedCubicTo(fragment, if (lo == 0) dirs[0] else .zero, if (hi == 1) dirs[1] else .zero);
            } else try result.lineTo(fragment.p3);
            need_move = false;
        }
        // A fully retained contour must keep its closed stroke join. Only
        // the final retained line is replaced; partially cut contours stay
        // open and retain their clipping endpoints and cap semantics.
        if (segment == .close and contour_kept and result.open and result.segments.items.len != 0 and result.segments.items[result.segments.items.len - 1] == .line) {
            _ = result.segments.pop();
            try result.close();
        }
        current = curve.p3;
    }
    return result;
}

pub const Intersection = struct { point: Point, a: f64, b: f64 };
pub const IntersectionError = error{ NonFinite, DegenerateLine, CoincidentCurves, ResolutionLimit };

fn polynomial(coeff: [4]f64, t: f64) f64 {
    return ((coeff[0] * t + coeff[1]) * t + coeff[2]) * t + coeff[3];
}
/// A common scale does not change roots. Apply it before differences and
/// factors of three so finite Bezier values do not overflow the power basis.
fn bezierPolynomial(v0: f64, v1: f64, v2: f64, v3: f64, value: f64) [4]f64 {
    const magnitude = @max(@max(@max(@abs(v0), @abs(v1)), @max(@abs(v2), @abs(v3))), @abs(value));
    const scale = if (magnitude == 0) 1 else magnitude;
    const a = v0 / scale;
    const ab = v1 / scale - a;
    const bc = v2 / scale - v1 / scale;
    const cd = v3 / scale - v2 / scale;
    return .{ ab - 2 * bc + cd, 3 * (bc - ab), 3 * ab, a - value / scale };
}
fn insertRoot(roots: *std.ArrayList(f64), allocator: std.mem.Allocator, t: f64) !void {
    const value = std.math.clamp(t, 0, 1);
    for (roots.items) |old| if (@abs(old - value) < 16 * std.math.floatEps(f64)) return;
    try roots.append(allocator, value);
}

/// All roots in [0,1], including double roots at derivative extrema. The
/// derivative partitions the cubic into monotone intervals, then bisection
/// isolates crossings; no flatness approximation is used.
fn cubicRootsUnit(allocator: std.mem.Allocator, coeff: [4]f64) ![]f64 {
    var roots: std.ArrayList(f64) = .empty;
    errdefer roots.deinit(allocator);
    var scale: f64 = 0;
    for (coeff) |c| {
        if (!std.math.isFinite(c)) return error.NonFinite;
        scale = @max(scale, @abs(c));
    }
    if (scale == 0) return error.CoincidentCurves;
    var normalized: [4]f64 = undefined;
    for (coeff, 0..) |c, i| normalized[i] = c / scale;
    var critical: [2]f64 = undefined;
    const n = g.quadraticRoots(3 * normalized[0], 2 * normalized[1], normalized[2], &critical);
    var divisions: [4]f64 = undefined;
    var length: usize = 1;
    divisions[0] = 0;
    for (critical[0..n]) |t| if (t > 0 and t < 1) {
        divisions[length] = t;
        length += 1;
    };
    divisions[length] = 1;
    length += 1;
    var crossing: [3]bool = @splat(false);
    for (0..length - 1) |i| {
        var lo = divisions[i];
        var hi = divisions[i + 1];
        var flo = polynomial(normalized, lo);
        const fhi = polynomial(normalized, hi);
        if (flo == 0 or fhi == 0 or (flo > 0) == (fhi > 0)) continue;
        crossing[i] = true;
        var step: usize = 0;
        while (step < 64 and hi - lo > 2e-15) : (step += 1) {
            const mid = (lo + hi) * 0.5;
            const fmid = polynomial(normalized, mid);
            if (fmid == 0) {
                lo = mid;
                hi = mid;
                break;
            }
            if ((fmid > 0) == (flo > 0)) {
                lo = mid;
                flo = fmid;
            } else hi = mid;
        }
        try insertRoot(&roots, allocator, (lo + hi) * 0.5);
    }
    const epsilon = 64 * std.math.floatEps(f64);
    for (divisions[0..length], 0..) |t, i| {
        const value = polynomial(normalized, t);
        const adjacent_crossing = (i > 0 and crossing[i - 1]) or (i + 1 < length and crossing[i]);
        // A near-zero extremum between two crossings is not a third root.
        // Retain approximate tangencies only when neither neighboring interval
        // already supplies a crossing; strict callers verify spatial residuals.
        if (value == 0 or (@abs(value) <= epsilon and !adjacent_crossing)) try insertRoot(&roots, allocator, t);
    }
    std.mem.sort(f64, roots.items, {}, std.sort.asc(f64));
    return roots.toOwnedSlice(allocator);
}

/// Intersections with a finite line segment. a is line parameter; b is cubic
/// parameter. A line-point is rejected explicitly. Collinear overlap is an
/// explicit error, since it has infinitely many intersections.
pub fn intersectLineCubic(allocator: std.mem.Allocator, start: Point, end: Point, curve: Cubic) ![]Intersection {
    return intersectLineCubicTolerance(allocator, start, end, curve, null);
}

fn intersectLineCubicTolerance(allocator: std.mem.Allocator, start: Point, end: Point, curve: Cubic, tolerance: ?f64) ![]Intersection {
    if (!start.isFinite() or !end.isFinite() or !curve.isFinite()) return error.NonFinite;
    const direction = end.sub(start);
    const unit = direction.normalized() catch |err| return switch (err) {
        error.ZeroVector => error.DegenerateLine,
        error.NonFinite => error.NonFinite,
    };
    const length = direction.norm();
    if (!std.math.isFinite(length)) return error.NonFinite;
    if (pointCurve(curve)) {
        const u = lineParameter(curve.p0, start, direction);
        if (u >= 0 and u <= 1 and curve.p0.distance(start.lerp(end, u)) <= (tolerance orelse 1e-12)) {
            return allocator.dupe(Intersection, &.{.{ .point = curve.p0, .a = u, .b = 0 }});
        }
        return allocator.alloc(Intersection, 0);
    }
    const relative = [_]Point{ curve.p0.sub(start), curve.p1.sub(start), curve.p2.sub(start), curve.p3.sub(start) };
    var relative_scale: f64 = 0;
    for (relative) |p| {
        if (!p.isFinite()) return error.NonFinite;
        relative_scale = @max(relative_scale, @max(@abs(p.x), @abs(p.y)));
    }
    const product_scale = @max(@abs(direction.x), @abs(direction.y)) * relative_scale;
    // Keep exact cancellation in ordinary collinear coordinates: normalizing
    // (3,4) to (0.6,0.8) first can introduce a spurious nonzero cross product.
    // Change the common scale only when raw cross products risk range loss.
    const cross_direction = if (std.math.isFinite(product_scale) and product_scale >= 4 * std.math.floatMin(f64) and product_scale <= std.math.floatMax(f64) / 4) direction else unit;
    const z0 = relative[0].cross(cross_direction);
    const z1 = relative[1].cross(cross_direction);
    const z2 = relative[2].cross(cross_direction);
    const z3 = relative[3].cross(cross_direction);
    for ([_]f64{ z0, z1, z2, z3 }) |z| if (!std.math.isFinite(z)) return error.NonFinite;
    var endpoint: ?f64 = null;
    // Cubic.line's rounded thirds still represent a line, as in the linear
    // shortcut below; translation can otherwise perturb their cross products.
    const collinear = z0 == 0 and z3 == 0 and ((z1 == 0 and z2 == 0) or linearCurve(curve));
    const roots = if (collinear) blk: {
        // Collinearity alone does not imply an overlapping interval. Project
        // onto line time and distinguish disjoint, endpoint-only and overlap.
        const projection: Cubic = .{
            .p0 = .{ .x = lineParameter(curve.p0, start, direction), .y = 0 },
            .p1 = .{ .x = lineParameter(curve.p1, start, direction), .y = 0 },
            .p2 = .{ .x = lineParameter(curve.p2, start, direction), .y = 0 },
            .p3 = .{ .x = lineParameter(curve.p3, start, direction), .y = 0 },
        };
        if (!projection.isFinite()) return error.NonFinite;
        const box = projection.bounds();
        const lo = @max(0, box.min.x);
        const hi = @min(1, box.max.x);
        if (lo > hi) return allocator.alloc(Intersection, 0);
        if (lo < hi) return error.CoincidentCurves;
        endpoint = lo;
        break :blk try cubicRootsUnit(allocator, bezierPolynomial(projection.p0.x, projection.p1.x, projection.p2.x, projection.p3.x, lo));
    } else try cubicRootsUnit(allocator, bezierPolynomial(z0, z1, z2, z3, 0));
    defer allocator.free(roots);
    var result: std.ArrayList(Intersection) = .empty;
    errdefer result.deinit(allocator);
    for (roots) |root| {
        var t = root;
        var point = curve.at(t);
        var u = lineParameter(point, start, direction);
        if (u < -1e-10 or u > 1 + 1e-10) continue;
        if (tolerance) |limit| {
            var iteration: usize = 0;
            while (point.distance(start.lerp(end, std.math.clamp(u, 0, 1))) > limit and iteration < 20) : (iteration += 1) {
                const derivative = curve.derivative(t);
                const value = if (endpoint) |e| point.sub(start.lerp(end, e)).dot(unit) else point.sub(start).cross(unit);
                const slope = if (endpoint != null) derivative.dot(unit) else derivative.cross(unit);
                if (slope == 0 or !std.math.isFinite(slope)) break;
                const next = std.math.clamp(t - value / slope, 0, 1);
                if (next == t or !std.math.isFinite(next)) break;
                t = next;
                point = curve.at(t);
                u = lineParameter(point, start, direction);
            }
            // A normalized polynomial residual is not a spatial guarantee.
            // Ill-conditioned contacts that cannot meet the requested bound
            // are reported instead of returning an out-of-tolerance point.
            if (!point.isFinite() or !std.math.isFinite(u) or point.distance(start.lerp(end, std.math.clamp(u, 0, 1))) > limit) return error.ResolutionLimit;
        }
        try result.append(allocator, .{ .point = point, .a = std.math.clamp(u, 0, 1), .b = t });
    }
    return result.toOwnedSlice(allocator);
}

fn lineParameter(point: Point, start: Point, direction: Point) f64 {
    // The dominant coordinate avoids squared-length overflow/underflow and
    // retains exact endpoint times, including oblique integer-valued lines.
    return if (@abs(direction.x) >= @abs(direction.y)) (point.x - start.x) / direction.x else (point.y - start.y) / direction.y;
}

fn sameCurve(a: Cubic, b: Cubic) bool {
    return a.p0.eql(b.p0) and a.p1.eql(b.p1) and a.p2.eql(b.p2) and a.p3.eql(b.p3);
}
fn pointCurve(curve: Cubic) bool {
    return curve.p0.eql(curve.p1) and curve.p0.eql(curve.p2) and curve.p0.eql(curve.p3);
}
fn linearCurve(curve: Cubic) bool {
    const line = Cubic.line(curve.p0, curve.p3);
    return curve.p1.eql(line.p1) and curve.p2.eql(line.p2);
}
fn appendIntersection(result: *std.ArrayList(Intersection), allocator: std.mem.Allocator, hit: Intersection, tolerance: f64) !void {
    for (result.items) |*old| {
        if (@abs(old.a - hit.a) < 2e-8 and @abs(old.b - hit.b) < 2e-8 and old.point.distance(hit.point) <= 4 * tolerance) {
            if (hit.point.isFinite()) old.* = hit;
            return;
        }
    }
    try result.append(allocator, hit);
}

/// Bounded subdivision of exact control hulls followed by Newton refinement.
/// tolerance is a spatial residual bound; it must be positive and finite.
/// The explicit work limit diagnoses unresolved/coincident configurations.
pub fn intersectCubics(allocator: std.mem.Allocator, a: Cubic, b: Cubic, tolerance: f64) ![]Intersection {
    if (!a.isFinite() or !b.isFinite() or !std.math.isFinite(tolerance) or tolerance <= 0) return error.NonFinite;
    if (pointCurve(a) and pointCurve(b)) {
        if (a.p0.distance(b.p0) > tolerance) return allocator.alloc(Intersection, 0);
        return allocator.dupe(Intersection, &.{.{ .point = a.p0.lerp(b.p0, 0.5), .a = 0, .b = 0 }});
    }
    if (sameCurve(a, b) or sameCurve(a, b.reversed())) return error.CoincidentCurves;
    if (linearCurve(a) and a.p0.distance(a.p3) != 0) return intersectLineCubicTolerance(allocator, a.p0, a.p3, b, tolerance);
    if (linearCurve(b) and b.p0.distance(b.p3) != 0) {
        const hits = try intersectLineCubicTolerance(allocator, b.p0, b.p3, a, tolerance);
        for (hits) |*hit| std.mem.swap(f64, &hit.a, &hit.b);
        return hits;
    }
    const Node = struct { a: Cubic, b: Cubic, a0: f64 = 0, a1: f64 = 1, b0: f64 = 0, b1: f64 = 1, depth: usize = 0 };
    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .a = a, .b = b });
    var result: std.ArrayList(Intersection) = .empty;
    errdefer result.deinit(allocator);
    var work: usize = 0;
    while (stack.pop()) |node| {
        work += 1;
        if (work > 200000) return error.ResolutionLimit;
        const ab = node.a.controlBounds();
        const bb = node.b.controlBounds();
        if (!ab.overlaps(bb, tolerance * 0.01)) continue;
        const extent_a = @max(ab.width(), ab.height());
        const extent_b = @max(bb.width(), bb.height());
        if ((extent_a <= tolerance * 0.1 and extent_b <= tolerance * 0.1) or node.depth >= 72) {
            var u = (node.a0 + node.a1) * 0.5;
            var v = (node.b0 + node.b1) * 0.5;
            var iteration: usize = 0;
            while (iteration < 40) : (iteration += 1) {
                const difference = a.at(u).sub(b.at(v));
                const da = a.derivative(u);
                const db = b.derivative(v);
                const det = da.cross(db);
                if (@abs(det) < 1e-24) break;
                const du = difference.cross(db) / det;
                const dv = difference.cross(da) / det;
                var damping: f64 = 1;
                var next_u = std.math.clamp(u - du, 0, 1);
                var next_v = std.math.clamp(v - dv, 0, 1);
                while (damping > 1e-8 and a.at(next_u).distance(b.at(next_v)) > difference.norm()) {
                    damping *= 0.5;
                    next_u = std.math.clamp(u - damping * du, 0, 1);
                    next_v = std.math.clamp(v - damping * dv, 0, 1);
                }
                if (a.at(next_u).distance(b.at(next_v)) > difference.norm()) break;
                if (@abs(next_u - u) + @abs(next_v - v) < 1e-15) break;
                u = next_u;
                v = next_v;
            }
            const pa = a.at(u);
            const pb = b.at(v);
            if (pa.distance(pb) <= tolerance) {
                try appendIntersection(&result, allocator, .{ .point = pa.lerp(pb, 0.5), .a = u, .b = v }, tolerance);
            } else if (node.depth >= 72) return error.ResolutionLimit;
            continue;
        }
        if (extent_a >= extent_b) {
            const split = node.a.split(0.5);
            const mid = (node.a0 + node.a1) * 0.5;
            try stack.append(allocator, .{ .a = split.right, .b = node.b, .a0 = mid, .a1 = node.a1, .b0 = node.b0, .b1 = node.b1, .depth = node.depth + 1 });
            try stack.append(allocator, .{ .a = split.left, .b = node.b, .a0 = node.a0, .a1 = mid, .b0 = node.b0, .b1 = node.b1, .depth = node.depth + 1 });
        } else {
            const split = node.b.split(0.5);
            const mid = (node.b0 + node.b1) * 0.5;
            try stack.append(allocator, .{ .a = node.a, .b = split.right, .a0 = node.a0, .a1 = node.a1, .b0 = mid, .b1 = node.b1, .depth = node.depth + 1 });
            try stack.append(allocator, .{ .a = node.a, .b = split.left, .a0 = node.a0, .a1 = node.a1, .b0 = node.b0, .b1 = mid, .depth = node.depth + 1 });
        }
    }
    const Sort = struct {
        fn less(_: void, x: Intersection, y: Intersection) bool {
            return x.a < y.a;
        }
    };
    std.mem.sort(Intersection, result.items, {}, Sort.less);
    return result.toOwnedSlice(allocator);
}

test "subpaths round trip exact mixed contours and own independent paths" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = -0.0, .y = 1 });
    try source.cubicTo(.{ .x = 1, .y = 4 }, .{ .x = 3, .y = 2 }, .{ .x = 2, .y = 1 });
    try source.lineTo(.{ .x = -0.0, .y = 1 });
    try source.close();
    try source.moveTo(.{ .x = 10, .y = 1 });
    try source.lineTo(.{ .x = 11, .y = 3 });
    try source.moveTo(.{ .x = 20, .y = 5 });
    try source.moveTo(.{ .x = 20, .y = 5 });
    try source.close();
    const parts = try source.subpaths(allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expect(!parts[0].open);
    try std.testing.expectEqual(Point{ .x = -0.0, .y = 1 }, parts[0].current.?);
    try std.testing.expect(parts[1].open);
    try std.testing.expectEqual(Point{ .x = 10, .y = 1 }, parts[1].start.?);
    try std.testing.expectEqual(Point{ .x = 11, .y = 3 }, parts[1].current.?);
    try std.testing.expect(parts[2].open);
    try std.testing.expectEqual(@as(usize, 1), parts[2].segments.items.len);
    try std.testing.expect(!parts[3].open);
    try std.testing.expectEqual(@as(usize, 2), parts[3].segments.items.len);
    var joined = Path.init(allocator);
    defer joined.deinit();
    for (parts) |part| try joined.append(part);
    try std.testing.expectEqualDeep(source.segments.items, joined.segments.items);
    try std.testing.expect(std.math.signbit(parts[0].segments.items[0].move.x));
    try std.testing.expectEqual(source.current, joined.current);
    try std.testing.expectEqual(source.start, joined.start);
    try std.testing.expectEqual(source.open, joined.open);
    try source.transform(g.Transform.translation(100, 200));
    try std.testing.expectError(error.InvalidPath, parts[0].lineTo(.zero));
    try parts[1].lineTo(.{ .x = 12, .y = 4 });
    try std.testing.expectEqual(Point{ .x = -0.0, .y = 1 }, parts[0].segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 20, .y = 5 }, parts[2].current.?);
    try std.testing.expectEqual(Point{ .x = 120, .y = 205 }, source.current.?);
    try std.testing.expectEqual(@as(usize, 9), source.segments.items.len);
}

test "subpaths retain separate hole winding and handle empty and single paths" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    const empty = try source.subpaths(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();
    const single = try source.subpaths(allocator);
    defer {
        for (single) |*part| part.deinit();
        allocator.free(single);
    }
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualDeep(source.segments.items, single[0].segments.items);
    try source.moveTo(.{ .x = 2, .y = 2 });
    try source.lineTo(.{ .x = 2, .y = 8 });
    try source.lineTo(.{ .x = 8, .y = 8 });
    try source.lineTo(.{ .x = 8, .y = 2 });
    try source.close();
    const parts = try source.subpaths(allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqual(@as(f64, 100), parts[0].signedArea());
    try std.testing.expectEqual(@as(f64, -36), parts[1].signedArea());
    try std.testing.expectEqual(source.signedArea(), parts[0].signedArea() + parts[1].signedArea());
}

test "subpaths diagnose malformed topology and nonfinite coordinates" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, source.subpaths(allocator));
    source.segments.clearRetainingCapacity();
    try source.moveTo(.zero);
    try source.close();
    try source.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, source.subpaths(allocator));
    source.segments.items[2] = .close;
    try std.testing.expectError(error.InvalidPath, source.subpaths(allocator));
    source.segments.clearRetainingCapacity();
    try source.segments.append(allocator, .{ .move = .{ .x = std.math.nan(f64), .y = 0 } });
    try std.testing.expectError(error.NonFinite, source.subpaths(allocator));
    source.segments.clearRetainingCapacity();
    try source.moveTo(.zero);
    try source.segments.append(allocator, .{ .cubic = .{ .c1 = .zero, .c2 = .{ .x = 0, .y = std.math.inf(f64) }, .end = .zero } });
    try std.testing.expectError(error.NonFinite, source.subpaths(allocator));
}

fn exerciseSubpaths(allocator: std.mem.Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    try source.close();
    try source.moveTo(.{ .x = 8, .y = 9 });
    try source.lineTo(.{ .x = 10, .y = 11 });
    try source.moveTo(.{ .x = 12, .y = 13 });
    const parts = try source.subpaths(allocator);
    defer {
        for (parts) |*part| part.deinit();
        allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 3), parts.len);
}

test "subpaths release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSubpaths, .{});
}

test "signed area integrates cubic boundaries and implicit closure" {
    const allocator = std.testing.allocator;
    var arch = Path.init(allocator);
    defer arch.deinit();
    try arch.moveTo(.zero);
    try arch.cubicTo(.{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), arch.signedArea(), 1e-14);
    var reversed = try arch.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), reversed.signedArea(), 1e-14);
    try arch.close();
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), arch.signedArea(), 1e-14);
}

test "signed area removes a large contour origin before curve integration" {
    const allocator = std.testing.allocator;
    const origin: Point = .{ .x = 1e16, .y = -1e16 };
    var arch = Path.init(allocator);
    defer arch.deinit();
    try arch.moveTo(origin);
    try arch.cubicTo(origin.add(.{ .x = 0, .y = 16 }), origin.add(.{ .x = 16, .y = 16 }), origin.add(.{ .x = 16, .y = 0 }));
    try std.testing.expectApproxEqAbs(@as(f64, -153.6), arch.signedArea(), 1e-11);
    var reversed = try arch.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 153.6), reversed.signedArea(), 1e-11);
}

test "signed area combines separate contours with hole winding" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try std.testing.expectEqual(@as(f64, 0), path.signedArea());
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 10, .y = 10 });
    try path.lineTo(.{ .x = 0, .y = 10 });
    // The next move implicitly closes the outer contour.
    try path.moveTo(.{ .x = 3, .y = 3 });
    try path.lineTo(.{ .x = 3, .y = 7 });
    try path.lineTo(.{ .x = 7, .y = 7 });
    try path.lineTo(.{ .x = 7, .y = 3 });
    try path.close();
    try path.moveTo(.{ .x = 1e16, .y = 1e16 });
    try std.testing.expectEqual(@as(f64, 84), path.signedArea());
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(f64, -84), reversed.signedArea());
}

test "appendTransformed matches a transformed temporary without copying it" {
    const allocator = std.testing.allocator;
    var prefix = Path.init(allocator);
    defer prefix.deinit();
    try prefix.moveTo(.{ .x = 1, .y = 2 });
    try prefix.lineTo(.{ .x = 3, .y = 4 });
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = -0.0, .y = 5 });
    try source.cubicTo(.{ .x = 6, .y = 7 }, .{ .x = 8, .y = 9 }, .{ .x = 10, .y = 11 });
    try source.close();
    const matrix = g.Transform{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 12, .f = -3 };
    var direct = Path.init(allocator);
    defer direct.deinit();
    try direct.append(prefix);
    try direct.appendTransformed(source, matrix);

    var expected_source = try source.transformed(allocator, matrix);
    defer expected_source.deinit();
    var expected = Path.init(allocator);
    defer expected.deinit();
    try expected.append(prefix);
    try expected.append(expected_source);
    try std.testing.expectEqualDeep(expected.segments.items, direct.segments.items);
    try std.testing.expectEqual(expected.current, direct.current);
    try std.testing.expectEqual(expected.start, direct.start);
    try std.testing.expectEqual(expected.open, direct.open);

    var unchanged = Path.init(allocator);
    defer unchanged.deinit();
    try unchanged.append(prefix);
    const before = unchanged.segments.items.len;
    try std.testing.expectError(error.NonFinite, unchanged.appendTransformed(source, .{ .a = std.math.nan(f64) }));
    try std.testing.expectEqual(before, unchanged.segments.items.len);
}

test "open and closed reversal, joins and transformed bounds" {
    const allocator = std.testing.allocator;
    var p = Path.init(allocator);
    defer p.deinit();
    try p.moveTo(.{ .x = 0, .y = 0 });
    try p.cubicTo(.{ .x = 0, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 0 });
    var next = Path.init(allocator);
    defer next.deinit();
    try next.moveTo(.{ .x = 4, .y = 0 });
    try next.lineTo(.{ .x = 8, .y = 0 });
    try p.join(next);
    var reversed = try p.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expect(g.tolerance.points(reversed.current.?, Point.zero));
    try std.testing.expectEqual(@as(usize, 2), reversed.segmentCount());
    try p.close();
    var closed = try p.reverse(allocator);
    defer closed.deinit();
    try std.testing.expect(!closed.open);
    try std.testing.expectEqual(p.bounds().?, closed.bounds().?);
    var rotated = try p.transformed(allocator, g.Transform.rotation(std.math.pi / 4.0));
    defer rotated.deinit();
    try std.testing.expect(rotated.bounds().?.height() > p.bounds().?.height());
    var mismatch = Path.init(allocator);
    defer mismatch.deinit();
    try mismatch.moveTo(.{ .x = 99, .y = 0 });
    try std.testing.expectError(error.InvalidPath, p.join(mismatch));
}

test "exact trimming preserves curves and pen-up subpaths" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .zero, .p1 = .{ .x = 0, .y = 4 }, .p2 = .{ .x = 4, .y = 4 }, .p3 = .{ .x = 4, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    try p.moveTo(.{ .x = 9, .y = 0 });
    try p.lineTo(.{ .x = 10, .y = 0 });
    var cut = try p.trimmed(allocator, 0.25, 1.5);
    defer cut.deinit();
    try std.testing.expectEqual(@as(usize, 4), cut.segments.items.len);
    try std.testing.expect(g.tolerance.points(cut.segments.items[0].move, c.at(0.25)));
    try std.testing.expect(g.tolerance.points(cut.current.?, .{ .x = 9.5, .y = 0 }));
    var backward = try p.trimmed(allocator, 0.75, 0.25);
    defer backward.deinit();
    try std.testing.expect(g.tolerance.points(backward.current.?, c.at(0.25)));
    try std.testing.expectError(error.InvalidParameter, p.trimmed(allocator, -1, 0));
}

test "zero-width trimming follows query boundaries across pen-up moves" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 11, .y = 0 });
    for ([_]f64{ 0, 0.5, 1, 1.5, 2 }) |time| {
        var point = try path.trimmed(allocator, time, time);
        defer point.deinit();
        try std.testing.expect(g.tolerance.points(try path.pointAt(time), try point.pointAt(0)));
        try std.testing.expectEqual(@as(usize, 2), point.segments.items.len);
        try std.testing.expect(point.segments.items[1] == .line);
    }
    var before = try path.trimmed(allocator, 0.5, 1);
    defer before.deinit();
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, before.current.?);
    var after = try path.trimmed(allocator, 1, 1.5);
    defer after.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, try after.pointAt(0));
    var backward = try path.trimmed(allocator, 1.5, 1);
    defer backward.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, backward.current.?);
}

test "zero-width trimming preserves segment kinds across closes reversal and final endpoints" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |zero_close| {
        var path = Path.init(allocator);
        defer path.deinit();
        try path.moveTo(.{ .x = -2, .y = -3 });
        try path.lineTo(.{ .x = -1, .y = -3 });
        if (zero_close) try path.lineTo(.{ .x = -2, .y = -3 });
        try path.close();
        try path.moveTo(.{ .x = 10, .y = 5 });
        try path.cubicTo(.{ .x = 10, .y = 6 }, .{ .x = 11, .y = 6 }, .{ .x = 11, .y = 5 });
        try path.close();
        try path.moveTo(.{ .x = 100, .y = 100 });
        try std.testing.expectEqual(@as(usize, 4), path.segmentCount());
        var reversed = try path.reverse(allocator);
        defer reversed.deinit();
        for ([_]f64{ 0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4 }) |time| {
            var point = try path.trimmed(allocator, time, time);
            defer point.deinit();
            try std.testing.expect(g.tolerance.points(try path.pointAt(time), try point.pointAt(0)));
            try std.testing.expectEqual(@as(usize, 2), point.segments.items.len);
            if (time >= 2 and time < 3) {
                try std.testing.expect(point.segments.items[1] == .cubic);
                const controls = point.segments.items[1].cubic;
                try std.testing.expectEqual(point.current.?, controls.c1);
                try std.testing.expectEqual(point.current.?, controls.c2);
            } else try std.testing.expect(point.segments.items[1] == .line);
            var reverse_point = try reversed.trimmed(allocator, time, time);
            defer reverse_point.deinit();
            try std.testing.expect(g.tolerance.points(try reversed.pointAt(time), try reverse_point.pointAt(0)));
        }
        var complete = try path.trimmed(allocator, 0, 2);
        defer complete.deinit();
        try std.testing.expect(!complete.open);
        try std.testing.expect(complete.segments.items[complete.segments.items.len - 1] == .close);
    }
}

test "closed reversal retains the time origin and reverses implicit closing edges" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 3, .y = 1 });
    try path.close();
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 3), path.segmentCount());
    try std.testing.expectEqual(path.segmentCount(), reversed.segmentCount());
    try std.testing.expectEqual(Point.zero, reversed.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 3, .y = 1 }, reversed.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 2, .y = 2 }, reversed.segments.items[3].cubic.c1);
    try std.testing.expectEqual(Point{ .x = 0, .y = 2 }, reversed.segments.items[3].cubic.c2);
    for ([_]f64{ 0, 0.25, 0.5, 1, 1.5, 2, 2.5, 3 }) |time| {
        var original_point = try path.trimmed(allocator, 3 - time, 3 - time);
        defer original_point.deinit();
        var reverse_point = try reversed.trimmed(allocator, time, time);
        defer reverse_point.deinit();
        try std.testing.expect(g.tolerance.points(original_point.current.?, reverse_point.current.?));
    }
    var backward = try path.trimmed(allocator, 3, 0);
    defer backward.deinit();
    try std.testing.expectEqual(Point.zero, backward.segments.items[0].move);
    try std.testing.expectEqual(@as(usize, 3), backward.segmentCount());
}

test "zero-length closes mark topology without consuming segment time" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.lineTo(.zero);
    try path.close();
    try path.moveTo(.{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 3, .y = 0 });
    try std.testing.expectEqual(@as(usize, 3), path.segmentCount());
    var first = try path.trimmed(allocator, 0, 2);
    defer first.deinit();
    try std.testing.expect(!first.open);
    try std.testing.expect(first.segments.items[first.segments.items.len - 1] == .close);
    try std.testing.expectEqual(@as(usize, 2), first.segmentCount());
    var partial = try path.trimmed(allocator, 0.5, 2);
    defer partial.deinit();
    try std.testing.expect(partial.open);
    var second = try path.trimmed(allocator, 2, 3);
    defer second.deinit();
    try std.testing.expectEqual(Point{ .x = 2, .y = 0 }, second.segments.items[0].move);
    try std.testing.expectEqual(@as(usize, 1), second.segmentCount());
}

test "reversal and backward trimming reverse subpath order across pen-up jumps" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 1, .y = 0 });
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 11, .y = 0 });
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 4), reversed.segments.items.len);
    try std.testing.expectEqual(Point{ .x = 11, .y = 0 }, reversed.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, reversed.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, reversed.segments.items[2].move);
    try std.testing.expectEqual(Point.zero, reversed.segments.items[3].line);
    var backward = try path.trimmed(allocator, 1.75, 0.25);
    defer backward.deinit();
    try std.testing.expectEqual(Point{ .x = 10.75, .y = 0 }, backward.segments.items[0].move);
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, backward.segments.items[1].line);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, backward.segments.items[2].move);
    try std.testing.expectEqual(Point{ .x = 0.25, .y = 0 }, backward.current.?);
    try path.close();
    var mixed = try path.reverse(allocator);
    defer mixed.deinit();
    try std.testing.expectEqual(Point{ .x = 10, .y = 0 }, mixed.segments.items[0].move);
    try std.testing.expect(mixed.segments.items[3] == .close);
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, mixed.segments.items[4].move);
}

test "line-cubic intersections include tangency and endpoints once" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 2.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } };
    const hits = try intersectLineCubic(allocator, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, c);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].b, 1e-10);
    const endpoints = try intersectLineCubic(allocator, .{ .x = -1, .y = 1 }, .{ .x = 2, .y = 1 }, c);
    defer allocator.free(endpoints);
    try std.testing.expectEqual(@as(usize, 2), endpoints.len);
    try std.testing.expectError(error.DegenerateLine, intersectLineCubic(allocator, .zero, .zero, c));
    try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.zero, .{ .x = 1, .y = 0 })));
    const isolated = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 0.5, .y = 0 }, .{ .x = 0.5, .y = 0 }));
    defer allocator.free(isolated);
    try std.testing.expectEqual(@as(usize, 1), isolated.len);
    const disjoint = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }));
    defer allocator.free(disjoint);
    try std.testing.expectEqual(@as(usize, 0), disjoint.len);
}

test "collinear endpoint contacts are finite and overlap still diagnoses coincidence" {
    const allocator = std.testing.allocator;
    const adjoining = Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 });
    const hits = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, adjoining);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(f64, 1), hits[0].a);
    try std.testing.expectEqual(@as(f64, 0), hits[0].b);
    const backwards = try intersectLineCubic(allocator, .{ .x = 1, .y = 0 }, .zero, adjoining);
    defer allocator.free(backwards);
    try std.testing.expectEqual(@as(usize, 1), backwards.len);
    try std.testing.expectEqual(@as(f64, 0), backwards[0].a);
    const touch: Cubic = .{ .p0 = .{ .x = 2, .y = 0 }, .p1 = .{ .x = 2.0 / 3.0, .y = 0 }, .p2 = .{ .x = 2.0 / 3.0, .y = 0 }, .p3 = .{ .x = 2, .y = 0 } };
    const interior = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, touch);
    defer allocator.free(interior);
    try std.testing.expectEqual(@as(usize, 1), interior.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), interior[0].b, 1e-12);
    try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, .zero, .{ .x = 1.5, .y = 0 }, adjoining));
    const point = Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 });
    const points = try intersectCubics(allocator, point, point, 1e-12);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    for ([_]Point{ .{ .x = 3, .y = 4 }, .{ .x = 4, .y = 3 }, .{ .x = -3, .y = 4 }, .{ .x = 3, .y = -4 } }) |direction| {
        const start: Point = .{ .x = 7, .y = -11 };
        const end = start.add(direction);
        try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, start, end, Cubic.line(start, end)));
        const contact = try intersectLineCubic(allocator, start, end, Cubic.line(end, end.add(direction)));
        defer allocator.free(contact);
        try std.testing.expectEqual(@as(usize, 1), contact.len);
        try std.testing.expectEqual(@as(f64, 1), contact[0].a);
        try std.testing.expectEqual(@as(f64, 0), contact[0].b);
    }
}

test "near tangent crossings are distinct and linear shortcuts enforce spatial residuals" {
    const allocator = std.testing.allocator;
    const line = Cubic.line(.zero, .{ .x = 1, .y = 0 });
    for ([_]f64{ 1, 1e6 }) |scale| {
        const e = 1e-15 * scale;
        const curve: Cubic = .{
            .p0 = .{ .x = 0, .y = 0.25 * scale - e },
            .p1 = .{ .x = 1.0 / 3.0, .y = -scale / 12 - e },
            .p2 = .{ .x = 2.0 / 3.0, .y = -scale / 12 - e },
            .p3 = .{ .x = 1, .y = 0.25 * scale - e },
        };
        const raw = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, curve);
        defer allocator.free(raw);
        try std.testing.expectEqual(@as(usize, 2), raw.len);
        try std.testing.expect(raw[0].b < 0.5 and raw[1].b > 0.5);
        const limit = 1e-12;
        const hits = try intersectCubics(allocator, line, curve, limit);
        defer allocator.free(hits);
        const swapped = try intersectCubics(allocator, curve, line, limit);
        defer allocator.free(swapped);
        try std.testing.expectEqual(@as(usize, 2), hits.len);
        try std.testing.expectEqual(hits.len, swapped.len);
        for (hits, swapped) |hit, other| {
            try std.testing.expect(line.at(hit.a).distance(curve.at(hit.b)) <= limit);
            try std.testing.expect(curve.at(other.a).distance(line.at(other.b)) <= limit);
        }
    }
    // A tiny but nonzero line is not a point; do not square its length into 0.
    const tiny = try intersectLineCubic(allocator, .zero, .{ .x = 1e-250, .y = 0 }, Cubic.line(.{ .x = 1e-250, .y = 0 }, .{ .x = 2e-250, .y = 0 }));
    defer allocator.free(tiny);
    try std.testing.expectEqual(@as(usize, 1), tiny.len);
}

test "bounded cubic intersection refinement and coincident diagnostics" {
    const allocator = std.testing.allocator;
    const a = Cubic.line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 });
    const b: Cubic = .{ .p0 = .{ .x = 0, .y = 10 }, .p1 = .{ .x = 4, .y = 10 }, .p2 = .{ .x = 6, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    const hits = try intersectCubics(allocator, a, b, 1e-8);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].a, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].b, 1e-8);
    try std.testing.expectError(error.CoincidentCurves, intersectCubics(allocator, b, b.reversed(), 1e-8));
    const tangent: Cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 2.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } };
    const touching = try intersectCubics(allocator, tangent, Cubic.line(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }), 1e-8);
    defer allocator.free(touching);
    try std.testing.expectEqual(@as(usize, 1), touching.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), touching[0].a, 2e-5);
    const lower = tangent.transformed(g.Transform.scaling(1, -1));
    const curved_touch = try intersectCubics(allocator, tangent, lower, 1e-8);
    defer allocator.free(curved_touch);
    try std.testing.expectEqual(@as(usize, 1), curved_touch.len);
}

test "rectangle clipping retains exact cubic pieces and handles boundary segments" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    const rect = g.BBox.fromPoints(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 });
    var clipped = try p.clippedToRect(allocator, rect);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(usize, 2), clipped.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), clipped.segments.items[0].move.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), clipped.current.?.x, 1e-12);
    try std.testing.expect(clipped.segments.items[1] == .cubic);
    try std.testing.expect(clipped.bounds().?.max.y <= 2);
    var edge = Path.init(allocator);
    defer edge.deinit();
    try edge.moveTo(.{ .x = -1, .y = 0 });
    try edge.lineTo(.{ .x = 3, .y = 0 });
    var on_boundary = try edge.clippedToRect(allocator, rect);
    defer on_boundary.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 2), on_boundary.bounds().?.width(), 1e-12);
}

test "rectangle clipping preserves fully retained closed contours and opens cut ones" {
    const allocator = std.testing.allocator;
    var triangle = Path.init(allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 1, .y = 0 });
    try triangle.lineTo(.{ .x = 1, .y = 1 });
    try triangle.close();
    var whole = try triangle.clippedToRect(allocator, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer whole.deinit();
    try std.testing.expect(!whole.open);
    try std.testing.expect(whole.segments.items[whole.segments.items.len - 1] == .close);
    try std.testing.expectEqual(triangle.segmentCount(), whole.segmentCount());
    var cut = try triangle.clippedToRect(allocator, .fromPoints(.{ .x = 0.5, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer cut.deinit();
    try std.testing.expect(cut.open);
    for (cut.segments.items) |segment| try std.testing.expect(segment != .close);
    var returned = Path.init(allocator);
    defer returned.deinit();
    try returned.moveTo(.zero);
    try returned.cubicTo(.{ .x = 0, .y = 1 }, .{ .x = 1, .y = 0 }, .zero);
    try returned.close();
    var returned_clip = try returned.clippedToRect(allocator, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 2, .y = 2 }));
    defer returned_clip.deinit();
    try std.testing.expect(!returned_clip.open);
    try std.testing.expectEqual(@as(usize, 1), returned_clip.segmentCount());
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    const c: Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } };
    var p = try Path.fromCubics(allocator, &.{c}, false);
    defer p.deinit();
    var reversed = try p.reverse(allocator);
    defer reversed.deinit();
    var cut = try p.trimmed(allocator, 0.1, 0.9);
    defer cut.deinit();
    var clipped = try p.clippedToRect(allocator, .fromPoints(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }));
    defer clipped.deinit();
    const hits = try intersectLineCubic(allocator, .{ .x = -2, .y = 1 }, .{ .x = 4, .y = 1 }, c);
    defer allocator.free(hits);
    const endpoint = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }));
    defer allocator.free(endpoint);
    const bounded = try intersectCubics(allocator, Cubic.line(.{ .x = -2, .y = 1 }, .{ .x = 4, .y = 1 }), c, 1e-10);
    defer allocator.free(bounded);
    var point_curve = try p.trimmed(allocator, 0.5, 0.5);
    defer point_curve.deinit();
    try p.moveTo(.zero);
    try p.lineTo(.{ .x = 1, .y = 0 });
    var point_line = try p.trimmed(allocator, 1, 1);
    defer point_line.deinit();
}

test "owned path operations release resources on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{});
}

test "circle construction keeps four cubic quarters and finite exact axis bounds" {
    var p = try Path.circle(std.testing.allocator, .{ .x = 3, .y = 4 }, 2);
    defer p.deinit();
    const box = p.bounds().?;
    try std.testing.expectEqual(@as(usize, 4), p.segmentCount());
    try std.testing.expectEqual(@as(f64, 1), box.min.x);
    try std.testing.expectEqual(@as(f64, 6), box.max.y);
    try std.testing.expect(!p.open);
    try p.moveTo(.{ .x = 50, .y = -20 });
    try std.testing.expectEqual(@as(f64, 50), p.bounds().?.max.x);
    try std.testing.expectEqual(box, (try paintedBounds(p.segments.items, .{})).?);
    try std.testing.expectError(error.InvalidParameter, Path.circle(std.testing.allocator, .zero, 0));
    try std.testing.expectError(error.NonFinite, Path.circle(std.testing.allocator, .zero, std.math.inf(f64)));
    var huge = try Path.circle(std.testing.allocator, .zero, 1.7e308);
    defer huge.deinit();
    const huge_bounds = huge.bounds().?;
    try std.testing.expect(huge_bounds.min.isFinite() and huge_bounds.max.isFinite());
    try std.testing.expectEqual(@as(f64, -1.7e308), huge_bounds.min.x);
    try std.testing.expectEqual(@as(f64, 1.7e308), huge_bounds.max.y);
}

test "path queries preserve exact segment boundaries and cubic point derivatives" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.cubicTo(.{ .x = 10, .y = 5 }, .{ .x = 15, .y = 5 }, .{ .x = 20, .y = 0 });
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 0 }, try path.pointAt(0.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 10, .y = 0 }, try path.tangentAt(0.5)));
    const boundary = try path.curveAt(1);
    try std.testing.expectEqual(@as(f64, 0), boundary.t);
    try std.testing.expect(g.tolerance.points(.{ .x = 10, .y = 0 }, boundary.curve.p0));
    try std.testing.expect(g.tolerance.points(.{ .x = 0, .y = 15 }, try path.tangentAt(1)));
    try std.testing.expect(g.tolerance.points(.{ .x = 13.125, .y = 3.75 }, try path.pointAt(1.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 11.25, .y = 0 }, try path.tangentAt(1.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 20, .y = 0 }, try path.pointAt(2)));
    try std.testing.expectEqual(@as(f64, 1), (try path.curveAt(2)).t);
    try std.testing.expectError(error.InvalidParameter, path.pointAt(-1));
    try std.testing.expectError(error.InvalidParameter, path.curveAt(2.1));
    try std.testing.expectError(error.InvalidParameter, path.tangentAt(std.math.nan(f64)));
}

test "path query time skips pen up moves and zero closes while retaining implicit close edges" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.zero);
    try path.close(); // Zero-length topology marker, not a third segment.
    try path.moveTo(.{ .x = 100, .y = 100 });
    try path.lineTo(.{ .x = 110, .y = 100 });
    try path.close(); // Nonzero closing line is the fourth drawable segment.
    try path.moveTo(.{ .x = 999, .y = 999 }); // No extra drawable time.
    try std.testing.expectEqual(@as(usize, 4), path.segmentCount());
    try std.testing.expect(g.tolerance.points(.{ .x = 100, .y = 100 }, try path.pointAt(2)));
    try std.testing.expect(g.tolerance.points(.{ .x = 105, .y = 100 }, try path.pointAt(2.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 110, .y = 100 }, try path.pointAt(3)));
    try std.testing.expect(g.tolerance.points(.{ .x = -10, .y = 0 }, try path.tangentAt(3)));
    try std.testing.expect(g.tolerance.points(.{ .x = 100, .y = 100 }, try path.pointAt(4)));
    var empty = Path.init(std.testing.allocator);
    defer empty.deinit();
    try empty.moveTo(.{ .x = 3, .y = 4 });
    try empty.close();
    try std.testing.expectError(error.InvalidParameter, empty.pointAt(0));
    try empty.moveTo(.{ .x = 3, .y = 4 });
    try empty.lineTo(.{ .x = 3, .y = 4 });
    try std.testing.expect(g.tolerance.points(.{ .x = 3, .y = 4 }, try empty.pointAt(0)));
    try std.testing.expect(g.tolerance.points(.zero, try empty.tangentAt(0)));
}

test "path queries reject invalid topology and nonfinite derivatives without trapping" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = -1e308, .y = 0 });
    try path.lineTo(.{ .x = 1e308, .y = 0 });
    try std.testing.expect((try path.pointAt(0.5)).isFinite());
    try std.testing.expectError(error.NonFinite, path.tangentAt(0.5));
    try path.close();
    // Deliberately malformed raw input: a drawing command after CLOSE needs a
    // new MOVE. Public constructors prohibit it; the query must still reject.
    try path.segments.append(std.testing.allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, path.curveAt(2.5));
}

test "whole path intersections deduplicate shared vertices and respect caller tolerance" {
    var first = Path.init(std.testing.allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.zero);
    try first.lineTo(.{ .x = 10, .y = 0 });
    var other = Path.init(std.testing.allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 0, .y = -10 });
    try other.lineTo(.{ .x = 0, .y = 10 });
    const shared = try first.intersections(std.testing.allocator, other, 1e-9);
    defer std.testing.allocator.free(shared);
    try std.testing.expectEqual(@as(usize, 1), shared.len);
    try std.testing.expect(g.tolerance.points(.zero, shared[0]));
    var nearby = Path.init(std.testing.allocator);
    defer nearby.deinit();
    try nearby.moveTo(.{ .x = -1, .y = 0 });
    try nearby.lineTo(.{ .x = 1, .y = 0 });
    try nearby.moveTo(.{ .x = -1, .y = 5e-8 });
    try nearby.lineTo(.{ .x = 1, .y = 5e-8 });
    const separate = try nearby.intersections(std.testing.allocator, other, 1e-9);
    defer std.testing.allocator.free(separate);
    try std.testing.expectEqual(@as(usize, 2), separate.len);
    try std.testing.expectApproxEqAbs(@as(f64, 5e-8), separate[1].y, 1e-12);
    const merged = try nearby.intersections(std.testing.allocator, other, 1e-6);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectError(error.NonFinite, first.intersections(std.testing.allocator, other, 0));
    try std.testing.expectError(error.CoincidentCurves, first.intersections(std.testing.allocator, first, 1e-9));
    var partly_coincident = Path.init(std.testing.allocator);
    defer partly_coincident.deinit();
    try partly_coincident.moveTo(.{ .x = -1, .y = 0 });
    try partly_coincident.lineTo(.{ .x = 1, .y = 0 });
    try partly_coincident.moveTo(.{ .x = 0, .y = -10 });
    try partly_coincident.lineTo(.{ .x = 0, .y = 10 });
    // The first pair already produced an owned hit before a later pair reports
    // coincidence. The partially accumulated output must also be released.
    try std.testing.expectError(error.CoincidentCurves, partly_coincident.intersections(std.testing.allocator, other, 1e-9));
}

test "whole path intersections include cubic roots and nonzero closing segments" {
    var triangle = Path.init(std.testing.allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 10, .y = 10 });
    try triangle.close();
    var vertical = Path.init(std.testing.allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 5, .y = -1 });
    try vertical.lineTo(.{ .x = 5, .y = 11 });
    const closed_hits = try triangle.intersections(std.testing.allocator, vertical, 1e-9);
    defer std.testing.allocator.free(closed_hits);
    try std.testing.expectEqual(@as(usize, 2), closed_hits.len);
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 0 }, closed_hits[0]));
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 5 }, closed_hits[1]));
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = 2, .y = -3 }, .{ .x = 3, .y = 0 });
    var horizontal = Path.init(std.testing.allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -1, .y = 0 });
    try horizontal.lineTo(.{ .x = 4, .y = 0 });
    const roots = try curve.intersections(std.testing.allocator, horizontal, 1e-9);
    defer std.testing.allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len);
}

fn exerciseWholeIntersections(allocator: std.mem.Allocator) !void {
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    try first.moveTo(.{ .x = -1, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var other = Path.init(allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 0, .y = -1 });
    try other.lineTo(.{ .x = 0, .y = 3 });
    const hits = try first.intersections(allocator, other, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "whole path intersection allocation failures release temporary hits and output points" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseWholeIntersections, .{});
}

test "whole path intersection details retain cubic root parameters and shared endpoint identity" {
    const allocator = std.testing.allocator;
    var curve = Path.init(allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = 2, .y = -3 }, .{ .x = 3, .y = 0 });
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -1, .y = 0 });
    try horizontal.lineTo(.{ .x = 4, .y = 0 });
    const roots = try curve.intersectionDetails(allocator, horizontal, 1e-9);
    defer allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len);
    for (roots, [_]f64{ 0, 0.5, 1 }, [_]f64{ 0.2, 0.5, 0.8 }) |hit, a, b| {
        try std.testing.expectApproxEqAbs(a, hit.a, 1e-12);
        try std.testing.expectApproxEqAbs(b, hit.b, 1e-12);
        try std.testing.expect((try curve.pointAt(hit.a)).distance(hit.point) <= 1e-9);
        try std.testing.expect((try horizontal.pointAt(hit.b)).distance(hit.point) <= 1e-9);
    }
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.zero);
    try first.lineTo(.{ .x = 10, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -10 });
    try second.lineTo(.zero);
    try second.lineTo(.{ .x = 0, .y = 10 });
    const shared = try first.intersectionDetails(allocator, second, 1e-9);
    defer allocator.free(shared);
    try std.testing.expectEqual(@as(usize, 1), shared.len);
    try std.testing.expectEqualDeep(Intersection{ .point = .zero, .a = 1, .b = 1 }, shared[0]);
}

test "whole path intersection details preserve branches at one spatial coordinate" {
    const allocator = std.testing.allocator;
    var crossed = Path.init(allocator);
    defer crossed.deinit();
    try crossed.moveTo(.{ .x = 50, .y = 50 }); // Empty contour consumes no time.
    try crossed.moveTo(.{ .x = -2, .y = -2 });
    try crossed.lineTo(.{ .x = 2, .y = 2 });
    try crossed.moveTo(.{ .x = -2, .y = 2 });
    try crossed.lineTo(.{ .x = 2, .y = -2 });
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 0, .y = -3 });
    try vertical.lineTo(.{ .x = 0, .y = 3 });
    const hits = try crossed.intersectionDetails(allocator, vertical, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    for (hits, [_]f64{ 0.5, 1.5 }) |hit, time| {
        try std.testing.expectApproxEqAbs(time, hit.a, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), hit.b, 1e-12);
        try std.testing.expect(hit.point.distance(.zero) <= 1e-9);
    }
    const reversed = try vertical.intersectionDetails(allocator, crossed, 1e-9);
    defer allocator.free(reversed);
    try std.testing.expectEqual(@as(usize, 2), reversed.len);
    try std.testing.expect(reversed[0].b < reversed[1].b);
    const points = try crossed.intersections(allocator, vertical, 1e-9);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
}

test "whole path intersection details count closing edges and preserve closed seam times" {
    const allocator = std.testing.allocator;
    var triangle = Path.init(allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 10, .y = 10 });
    try triangle.close();
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 5, .y = -1 });
    try vertical.lineTo(.{ .x = 5, .y = 11 });
    const hits = try triangle.intersectionDetails(allocator, vertical, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), hits[1].a, 1e-12);
    var seam = Path.init(allocator);
    defer seam.deinit();
    try seam.moveTo(.{ .x = -1, .y = 1 });
    try seam.lineTo(.{ .x = 1, .y = -1 });
    const endpoints = try triangle.intersectionDetails(allocator, seam, 1e-9);
    defer allocator.free(endpoints);
    try std.testing.expectEqual(@as(usize, 2), endpoints.len);
    try std.testing.expectEqual(@as(f64, 0), endpoints[0].a);
    try std.testing.expectEqual(@as(f64, 3), endpoints[1].a);
    // Explicitly returning to the start makes CLOSE a zero-time marker.
    var returned = Path.init(allocator);
    defer returned.deinit();
    try returned.moveTo(.zero);
    try returned.lineTo(.{ .x = 10, .y = 0 });
    try returned.lineTo(.zero);
    try returned.close();
    const zero_close = try returned.intersectionDetails(allocator, seam, 1e-9);
    defer allocator.free(zero_close);
    try std.testing.expectEqual(@as(usize, 2), zero_close.len);
    try std.testing.expectEqual(@as(f64, 0), zero_close[0].a);
    try std.testing.expectEqual(@as(f64, 2), zero_close[1].a);
}

test "whole path intersection details do not merge parameters by spatial tolerance" {
    const allocator = std.testing.allocator;
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.{ .x = 10, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = -10, .y = -3 });
    try second.cubicTo(.{ .x = -10, .y = 3 }, .{ .x = 10, .y = 3 }, .{ .x = 10, .y = -3 });
    const hits = try first.intersectionDetails(allocator, second, 2);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(hits[0].a < hits[1].a and hits[0].b < hits[1].b);
    try std.testing.expect(hits[1].a - hits[0].a < 2 and hits[1].b - hits[0].b < 2);
    try std.testing.expect(hits[0].point.distance(hits[1].point) > 2);
}

test "whole path intersection details retain disconnected endpoints at identical times" {
    const allocator = std.testing.allocator;
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.zero);
    try first.moveTo(.{ .x = 0, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.zero);
    try second.moveTo(.{ .x = 0, .y = 2 });
    try second.lineTo(.{ .x = 0, .y = 3 });
    const hits = try first.intersectionDetails(allocator, second, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    for (hits) |hit| {
        try std.testing.expectEqual(@as(f64, 1), hit.a);
        try std.testing.expectEqual(@as(f64, 1), hit.b);
    }
    try std.testing.expectEqual(@as(f64, 0), hits[0].point.y);
    try std.testing.expectEqual(@as(f64, 2), hits[1].point.y);
}

fn exerciseWholeIntersectionDetails(allocator: std.mem.Allocator) !void {
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    try first.moveTo(.{ .x = -1, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.{ .x = 0, .y = 3 });
    const hits = try first.intersectionDetails(allocator, second, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "whole path intersection details preserve diagnostics and release every failed allocation" {
    const allocator = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(allocator, exerciseWholeIntersectionDetails, .{});
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.{ .x = 0, .y = 1 });
    try first.moveTo(.{ .x = 0, .y = -1 });
    try first.lineTo(.{ .x = 0, .y = 1 });
    try std.testing.expectError(error.CoincidentCurves, first.intersectionDetails(allocator, second, 1e-9));
    try std.testing.expectError(error.NonFinite, first.intersectionDetails(allocator, second, 0));
    try std.testing.expectError(error.NonFinite, first.intersectionDetails(allocator, second, std.math.nan(f64)));
    var invalid = Path.init(allocator);
    defer invalid.deinit();
    try invalid.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, invalid.intersectionDetails(allocator, second, 1e-9));
}

test "fresh transforms preserve clone then transform bits and source state" {
    const Check = struct {
        fn point(expected: Point, actual: Point) !void {
            try std.testing.expectEqual(@as(u64, @bitCast(expected.x)), @as(u64, @bitCast(actual.x)));
            try std.testing.expectEqual(@as(u64, @bitCast(expected.y)), @as(u64, @bitCast(actual.y)));
        }
        fn optional(expected: ?Point, actual: ?Point) !void {
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |value| try point(value, actual.?);
        }
        fn path(expected: Path, actual: Path) !void {
            try std.testing.expectEqual(expected.segments.items.len, actual.segments.items.len);
            for (expected.segments.items, actual.segments.items) |left, right| {
                try std.testing.expectEqual(std.meta.activeTag(left), std.meta.activeTag(right));
                switch (left) {
                    .move, .line => |value| try point(value, if (right == .move) right.move else right.line),
                    .cubic => |curve| {
                        try point(curve.c1, right.cubic.c1);
                        try point(curve.c2, right.cubic.c2);
                        try point(curve.end, right.cubic.end);
                    },
                    .close => {},
                }
            }
            try optional(expected.current, actual.current);
            try optional(expected.start, actual.start);
            try std.testing.expectEqual(expected.open, actual.open);
        }
    };
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |closed| {
        var source = Path.init(allocator);
        defer source.deinit();
        try source.moveTo(.{ .x = -0.0, .y = 0.0 });
        try source.cubicTo(.{ .x = 1e140, .y = -1e140 }, .{ .x = -2e140, .y = 3e140 }, .{ .x = 2, .y = -3 });
        try source.close();
        try source.moveTo(.{ .x = 0.0, .y = -0.0 });
        try source.cubicTo(.{ .x = -1e-140, .y = 1e-140 }, .{ .x = 2e-140, .y = -3e-140 }, .{ .x = -0.0, .y = 0.0 });
        try source.lineTo(.{ .x = 1e-140, .y = -1e-140 });
        if (closed) try source.close();
        var snapshot = try source.clone(allocator);
        defer snapshot.deinit();
        for ([_]g.Transform{
            .{},
            .{ .a = -0.0, .b = 0.0, .c = -0.0, .d = -0.0, .e = -0.0, .f = 0.0 },
            .{ .a = 1.25, .b = -0.5, .c = 0.25, .d = 2, .e = 10, .f = -30 },
            .{ .a = 1e140, .b = -1e140, .c = 1e140, .d = 1e140 },
            .{ .a = 1e-140, .b = -1e-140, .c = 1e-140, .d = 1e-140 },
        }) |placement| {
            var reference = try source.clone(allocator);
            defer reference.deinit();
            try reference.transform(placement);
            var actual = try source.transformed(allocator, placement);
            defer actual.deinit();
            try Check.path(reference, actual);
            try Check.path(snapshot, source);
        }
        try std.testing.expectError(error.NonFinite, source.transformed(allocator, .{ .a = std.math.nan(f64) }));
        try std.testing.expectError(error.NonFinite, source.transformed(allocator, .scaling(std.math.floatMax(f64), 1)));
        try std.testing.expectError(error.NonFinite, source.transform(.scaling(std.math.floatMax(f64), 1)));
        try Check.path(snapshot, source);
    }
    var empty = Path.init(allocator);
    defer empty.deinit();
    var transformed_empty = try empty.transformed(allocator, .{});
    defer transformed_empty.deinit();
    try Check.path(empty, transformed_empty);
}

fn exerciseFreshTransform(allocator: std.mem.Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = -2, .y = 4 }, .{ .x = 5, .y = -1 });
    var output = try source.transformed(allocator, .{ .a = 2, .d = -1, .e = 3 });
    defer output.deinit();
    try std.testing.expectEqual(@as(f64, 0), source.segments.items[0].move.x);
    try std.testing.expectEqual(@as(f64, 3), output.segments.items[0].move.x);
}

test "fresh transform releases every failed result allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFreshTransform, .{});
}

test "segment-local basis retains the derivative through cancellation" {
    const e = 0x1p-54;
    const curve: Cubic = .{
        .p0 = .{ .x = -1, .y = 0 },
        .p1 = .{ .x = e, .y = e },
        .p2 = .{ .x = -1, .y = 2 * e },
        .p3 = .{ .x = 2 * e, .y = 3 * e },
    };
    const frame = try SegmentFrame.init(curve, true);
    const basis = try frame.at(0.5);
    // At u=1/2 the Bernstein derivative is proportional to (1,4).
    // Rounding the control-point differences to f64 first loses its x part.
    try std.testing.expectEqual(curve.at(0.5), basis.apply(.zero));
    try std.testing.expectApproxEqAbs(1 / @sqrt(@as(f64, 17)), basis.a, 1e-15);
    try std.testing.expectEqual(4 * basis.a, basis.b);
    try std.testing.expectEqual(-basis.b, basis.c);
    try std.testing.expectEqual(basis.a, basis.d);
    try std.testing.expectError(error.InvalidParameter, frame.at(1.1));
}

// These fixtures start with a move and contain only cubics, so drawable
// time i-1/2 identifies the cubic at command i.
fn expectSolved(path: Path, index: usize, start: Point, end: Point) !void {
    const pos = try path.curveAt(@as(f64, @floatFromInt(index)) - 0.5);
    try std.testing.expectEqual([2]Point{ start, end }, path.solvedAt(index, pos.curve));
}

test "shared Hobby knot validates edits on each side before a rounding transform" {
    const a = std.testing.allocator;
    var path = try @import("construct.zig").construct(a, &.{ .zero, .{ .x = 5, .y = 8 }, .{ .x = 11, .y = 0 } }, &.{ .smooth, .smooth }, .{});
    defer path.deinit();
    try std.testing.expectEqual(1, path.knotRecords().len);
    const dir = path.knotRecords()[0].tangent;
    const left = &path.segments.items[1].cubic;
    const right = &path.segments.items[2].cubic;
    left.c1.x += 1;
    right.c2.y += 1;
    try expectSolved(path, 1, .zero, dir);
    try expectSolved(path, 2, dir, .zero);
    const original = left.c2;
    left.c2.y = std.math.nextAfter(f64, original.y, std.math.inf(f64));
    try expectSolved(path, 1, .zero, .zero);
    try expectSolved(path, 2, dir, .zero);
    const shift = g.Transform.translation(0, 0x1p40);
    try std.testing.expectEqual(shift.apply(left.c2), shift.apply(original));
    var placed = try path.transformed(a, shift);
    defer placed.deinit();
    try expectSolved(placed, 1, .zero, .zero);
    try expectSolved(placed, 2, dir, .zero);
    var in_place = try path.clone(a);
    defer in_place.deinit();
    try in_place.transform(shift);
    var appended = Path.init(a);
    defer appended.deinit();
    try appended.appendTransformed(path, shift);
    for ([_]Path{ in_place, appended }) |p| try std.testing.expectEqualDeep(placed.knotRecords(), p.knotRecords());
    left.c2 = original;
    const departing = right.c1;
    right.c1.x += 1;
    try expectSolved(path, 1, .zero, dir);
    try expectSolved(path, 2, .zero, .zero);
    left.end.x += 1;
    try expectSolved(path, 1, .zero, .zero);
    right.c1 = departing;
    try expectSolved(path, 2, .zero, .zero);
}

test "coincident endpoint controls validate the first noncoincident handle and its order" {
    const a = std.testing.allocator;
    const x: Point = .{ .x = 1, .y = 0 };
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    // The departure uses the chord (order three), the arrival its nearest handle.
    try path.solvedCubicTo(.{ .p0 = .zero, .p1 = .zero, .p2 = .zero, .p3 = x }, x, x);
    try expectSolved(path, 1, x, x);
    const c = &path.segments.items[1].cubic;
    c.end.y = 1;
    try expectSolved(path, 1, .zero, .zero);
    c.end = x;
    c.c2 = x; // Same departure witness point, different derivative order.
    try expectSolved(path, 1, .zero, .zero);

    var second = Path.init(a);
    defer second.deinit();
    try second.moveTo(.zero);
    try second.solvedCubicTo(.{ .p0 = .zero, .p1 = .zero, .p2 = x, .p3 = x.scale(2) }, x, .zero);
    second.segments.items[1].cubic.end.y = 1;
    try expectSolved(second, 1, x, .zero);
    second.segments.items[1].cubic.c2.y = 1;
    try expectSolved(second, 1, .zero, .zero);
}

test "shared Hobby knots survive reversal and cuts only at retained endpoints" {
    const a = std.testing.allocator;
    const points = [_]Point{ .zero, .{ .x = 10, .y = 2 }, .{ .x = 20, .y = 3 }, .{ .x = 30, .y = 1 } };
    var path = try @import("construct.zig").construct(a, &points, &.{ .smooth, .smooth, .smooth }, .{});
    defer path.deinit();
    const left = path.knotRecords()[0].tangent;
    const right = path.knotRecords()[1].tangent;
    try std.testing.expect(!left.eql(right));
    var rev = try path.reverse(a);
    defer rev.deinit();
    var back_cut = try path.trimmed(a, 2.75, 0.25);
    defer back_cut.deinit();
    for ([_]Path{ rev, back_cut }) |p| {
        try std.testing.expectEqual(2, p.knotRecords().len);
        try expectSolved(p, 1, .zero, right.scale(-1));
        try expectSolved(p, 2, right.scale(-1), left.scale(-1));
        try expectSolved(p, 3, left.scale(-1), .zero);
    }
    var cut = try path.clippedToRect(a, .fromPoints(.{ .x = 5, .y = -100 }, .{ .x = 25, .y = 100 }));
    defer cut.deinit();
    try std.testing.expectEqual(2, cut.knotRecords().len);
    try expectSolved(cut, 1, .zero, left);
    try expectSolved(cut, 2, left, right);
    try expectSolved(cut, 3, right, .zero);
    var half = try path.trimmed(a, 1, 1.75);
    defer half.deinit();
    try std.testing.expectEqual(1, half.knotRecords().len);
    try expectSolved(half, 1, left, .zero);
}

test "closed Hobby seam is stored once and independent directions at a corner survive" {
    const a = std.testing.allocator;
    var loop = try @import("construct.zig").construct(a, &.{ .zero, .{ .x = 8, .y = 0 }, .{ .x = 2, .y = 7 } }, &.{ .smooth, .smooth, .smooth }, .{ .closed = true });
    defer loop.deinit();
    const records = loop.knotRecords();
    try std.testing.expectEqual(3, records.len);
    try std.testing.expect(records[0].seam);
    try expectSolved(loop, 1, records[0].tangent, records[1].tangent);
    try expectSolved(loop, 3, records[2].tangent, records[0].tangent);
    loop.segments.items[1].cubic.c1.y += 1;
    try expectSolved(loop, 1, .zero, records[1].tangent);
    try expectSolved(loop, 3, records[2].tangent, records[0].tangent);
    var shifted = try loop.transformed(a, .translation(4, 2));
    defer shifted.deinit();
    try expectSolved(shifted, 1, .zero, records[1].tangent);
    try expectSolved(shifted, 3, records[2].tangent, records[0].tangent);
    var rev = try loop.reverse(a);
    defer rev.deinit();
    try expectSolved(rev, 1, records[0].tangent.scale(-1), records[2].tangent.scale(-1));
    try expectSolved(rev, 3, records[1].tangent.scale(-1), .zero);

    const x: Point = .{ .x = 1, .y = 0 };
    const y: Point = .{ .x = 0, .y = 1 };
    var corner = Path.init(a);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.solvedCubicTo(.line(.zero, x), .zero, x);
    try corner.solvedCubicTo(.line(x, x.add(y)), y, .zero);
    try std.testing.expectEqual(2, corner.knotRecords().len);
    try expectSolved(corner, 1, .zero, x);
    try expectSolved(corner, 2, y, .zero);
}
