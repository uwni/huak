//! Shared subdivision for polygon operations, pen sweeps and dashes. Both the
//! spatial chord error and total arc-length deficit have explicit budgets.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");
pub const Options = struct {
    tolerance: f64,
    length_tolerance: f64,
    /// Optional bound on same-parameter deviation from a chord. Arc-length
    /// inversion needs this even for a straight, nonuniformly parameterized
    /// cubic; ordinary polygon flattening does not.
    parameter_tolerance: ?f64 = null,
    /// Arc-length motion must retain travel even on tiny loops that fit within a pixel.
    preserve_travel: bool = false,
    /// When progress-dependent placement is absent, a certified monotone
    /// straight cubic sweeps exactly its chord at a fixed orientation.
    straight_as_line: bool = false,
    max_segments: usize,
    max_depth: usize,
};
pub const Error = std.mem.Allocator.Error || error{ InvalidTolerance, InvalidPath, NonFinite, StrokeWorkLimit };
pub const Mark = struct {
    original: bool = true,
    incoming: ?g.Point = null,
    outgoing: ?g.Point = null,
    /// Drawable-segment parameter in the source path. Moves retain the current
    /// value; a nonzero closing edge consumes one segment, as Path.curveAt.
    time: f64 = 0,
};
pub const Detailed = struct {
    path: Path,
    marks: []const Mark,
    pub fn deinit(self: *Detailed) void {
        self.path.allocator.free(self.marks);
        self.path.deinit();
        self.* = undefined;
    }
};

const Builder = struct {
    result: Path,
    options: Options,
    visits: usize = 0,
    segments: usize = 0,
    marks: ?*std.ArrayList(Mark) = null,
    times: ?*std.ArrayList(f64) = null,
    time: f64 = 0,
    fn line(self: *Builder, end: g.Point, mark: Mark) Error!void {
        self.segments += 1;
        if (self.segments > self.options.max_segments) return error.StrokeWorkLimit;
        try self.result.lineTo(end);
        try self.record(mark);
    }
    fn record(self: *Builder, mark: Mark) Error!void {
        if (self.marks) |marks| try marks.append(self.result.allocator, mark);
        if (self.times) |times| try times.append(self.result.allocator, mark.time);
    }
    fn cubic(self: *Builder, curve: g.Cubic, length_budget: f64, depth: usize, last: bool, incoming: g.Point, begin: f64, end: f64) Error!void {
        self.visits += 1;
        if (self.visits > self.options.max_segments *| 4) return error.StrokeWorkLimit;
        if (!curve.isFinite()) return error.NonFinite;
        const chord = curve.p0.distance(curve.p3);
        const upper = curve.p0.distance(curve.p1) + curve.p1.distance(curve.p2) + curve.p2.distance(curve.p3);
        if (!std.math.isFinite(chord) or !std.math.isFinite(upper)) return error.NonFinite;
        const deviation = @max(try distanceToSegment(curve.p1, curve.p0, curve.p3), try distanceToSegment(curve.p2, curve.p0, curve.p3));
        const parameter_ok = if (self.options.parameter_tolerance) |limit|
            @max(curve.p1.distance(curve.p0.lerp(curve.p3, 1.0 / 3.0)), curve.p2.distance(curve.p0.lerp(curve.p3, 2.0 / 3.0))) <= limit
        else
            true;
        if (deviation <= self.options.tolerance and upper - chord <= length_budget and parameter_ok and (!self.options.preserve_travel or chord > 0 or upper == 0)) return self.line(curve.p3, .{ .original = last, .incoming = if (last) incoming else null, .time = end });
        if (depth >= self.options.max_depth) return error.StrokeWorkLimit;
        const halves = curve.split(0.5);
        const middle = begin * 0.5 + end * 0.5;
        if ((self.marks != null or self.times != null) and (middle <= begin or middle >= end)) return error.StrokeWorkLimit;
        try self.cubic(halves.left, length_budget * 0.5, depth + 1, false, incoming, begin, middle);
        try self.cubic(halves.right, length_budget * 0.5, depth + 1, last, incoming, middle, end);
    }
};

fn distanceToSegment(point: g.Point, start: g.Point, end: g.Point) Error!f64 {
    const delta = end.sub(start);
    const relative = point.sub(start);
    if (!delta.isFinite() or !relative.isFinite()) return error.NonFinite;
    const length = delta.norm();
    if (!std.math.isFinite(length)) return error.NonFinite;
    if (length == 0) return relative.norm();
    const direction = delta.scale(1 / length);
    const projection = relative.dot(direction);
    if (!std.math.isFinite(projection)) return error.NonFinite;
    const distance = point.distance(start.add(direction.scale(std.math.clamp(projection, 0, length))));
    if (!std.math.isFinite(distance)) return error.NonFinite;
    return distance;
}

fn endpointDirection(curve: g.Cubic, last: bool) g.Point {
    if (last) {
        for ([_]g.Point{ curve.p2, curve.p1, curve.p0 }) |point| {
            const delta = curve.p3.sub(point);
            if (delta.x != 0 or delta.y != 0) return delta;
        }
    } else {
        for ([_]g.Point{ curve.p1, curve.p2, curve.p3 }) |point| {
            const delta = point.sub(curve.p0);
            if (delta.x != 0 or delta.y != 0) return delta;
        }
    }
    return .zero;
}

/// Shortest nonstationary contour of a flattened path.
pub fn minimumContourLength(path: Path) !f64 {
    var current: ?g.Point = null;
    var start: g.Point = .zero;
    var length: f64 = 0;
    var minimum = std.math.inf(f64);
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (length > 0) minimum = @min(minimum, length);
            current = point;
            start = point;
            length = 0;
        },
        .line, .close => {
            const point = if (segment == .line) segment.line else start;
            length += (current orelse return error.InvalidPath).distance(point);
            if (!std.math.isFinite(length)) return error.NonFinite;
            current = point;
            if (segment == .close) {
                if (length > 0) minimum = @min(minimum, length);
                length = 0;
                current = null;
            }
        },
        .cubic => return error.InvalidPath,
    };
    if (length > 0) minimum = @min(minimum, length);
    return minimum;
}

pub fn flatten(allocator: std.mem.Allocator, path: Path, options: Options) Error!Path {
    return flattenImpl(allocator, path, options, null, null);
}
pub fn detailed(allocator: std.mem.Allocator, path: Path, options: Options) Error!Detailed {
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(allocator);
    var result = try flattenImpl(allocator, path, options, &marks, null);
    errdefer result.deinit();
    return .{ .path = result, .marks = try marks.toOwnedSlice(allocator) };
}
/// Record just the source parameter for each output command.
pub fn withTimes(allocator: std.mem.Allocator, path: Path, options: Options, times: *std.ArrayList(f64)) Error!Path {
    const before = times.items.len;
    errdefer times.items.len = before;
    return flattenImpl(allocator, path, options, null, times);
}
fn flattenImpl(allocator: std.mem.Allocator, path: Path, options: Options, marks: ?*std.ArrayList(Mark), times: ?*std.ArrayList(f64)) Error!Path {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0 or !std.math.isFinite(options.length_tolerance) or options.length_tolerance <= 0) return error.InvalidTolerance;
    if (options.max_segments == 0 or options.max_depth > 64) return error.StrokeWorkLimit;
    if (options.parameter_tolerance) |limit| if (!std.math.isFinite(limit) or limit <= 0) return error.InvalidTolerance;
    var builder: Builder = .{ .result = Path.init(allocator), .options = options, .marks = marks, .times = times };
    errdefer builder.result.deinit();
    const budget = options.length_tolerance / @as(f64, @floatFromInt(@max(@as(usize, 1), path.segmentCount())));
    var current: ?g.Point = null;
    var start: ?g.Point = null;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            try builder.result.moveTo(point);
            try builder.record(.{ .time = builder.time });
            current = point;
            start = point;
        },
        .line => |point| {
            if (current == null) return error.InvalidPath;
            const delta = point.sub(current.?);
            if (marks) |metadata| metadata.items[metadata.items.len - 1].outgoing = delta;
            builder.time += 1;
            try builder.line(point, .{ .incoming = delta, .time = builder.time });
            current = point;
        },
        .cubic => |curve| {
            const previous = current orelse return error.InvalidPath;
            const cubic = g.Cubic{ .p0 = previous, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end };
            if (marks) |metadata| metadata.items[metadata.items.len - 1].outgoing = endpointDirection(cubic, false);
            const incoming = if (marks != null) endpointDirection(cubic, true) else g.Point.zero;
            if (options.straight_as_line and @import("Direction.zig").monotoneLine(cubic)) {
                try builder.line(cubic.p3, .{ .time = builder.time + 1, .incoming = incoming });
            } else try builder.cubic(cubic, budget, 0, true, incoming, builder.time, builder.time + 1);
            builder.time += 1;
            current = curve.end;
        },
        .close => {
            if (current == null) return error.InvalidPath;
            builder.segments += 1;
            if (builder.segments > options.max_segments) return error.StrokeWorkLimit;
            const delta = start.?.sub(current.?);
            if (marks) |metadata| metadata.items[metadata.items.len - 1].outgoing = delta;
            try builder.result.close();
            if (delta.x != 0 or delta.y != 0) builder.time += 1;
            try builder.record(.{ .incoming = delta, .time = builder.time });
            current = null;
            start = null;
        },
    };
    return builder.result;
}

test "adaptive flatten bounds total cubic arc deficit as well as spatial error" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    var flat = try flatten(std.testing.allocator, curve, .{ .tolerance = 0.001, .length_tolerance = 0.001, .max_segments = 65536, .max_depth = 24 });
    defer flat.deinit();
    var length: f64 = 0;
    var current: g.Point = .zero;
    for (flat.segments.items) |segment| switch (segment) {
        .move => |point| current = point,
        .line => |point| {
            length += current.distance(point);
            current = point;
        },
        else => unreachable,
    };
    try std.testing.expect(length <= 200);
    try std.testing.expectApproxEqAbs(@as(f64, 200), length, 0.001);
}

test "time-only marks match detailed subdivision at lifts, cubics and closes" {
    const a = std.testing.allocator;
    var p = Path.init(a);
    defer p.deinit();
    try p.moveTo(.zero);
    try p.cubicTo(.{ .x = 3, .y = 6 }, .{ .x = 7, .y = -5 }, .{ .x = 9, .y = 2 });
    try p.close();
    try p.moveTo(.{ .x = 1, .y = 1 });
    try p.lineTo(.{ .x = 1, .y = 1 });
    try p.close();
    const opts: Options = .{ .tolerance = 0.005, .length_tolerance = 0.005, .max_segments = 8192, .max_depth = 24 };
    var full = try detailed(a, p, opts);
    defer full.deinit();
    var times: std.ArrayList(f64) = .empty;
    defer times.deinit(a);
    var thin = try withTimes(a, p, opts, &times);
    defer thin.deinit();
    try std.testing.expectEqualDeep(full.path.segments.items, thin.segments.items);
    try std.testing.expectEqual(full.marks.len, times.items.len);
    for (full.marks, times.items) |mark, time| try std.testing.expectEqual(mark.time, time);
}
