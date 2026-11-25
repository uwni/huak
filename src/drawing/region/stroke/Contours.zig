//! A path parsed into stroke spans and contours under the segment and vertex budgets.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
const stroke = @import("../stroke.zig");
const Contours = @This();
const Options = stroke.Options;

allocator: Allocator,
spans: std.ArrayList(Span) = .empty,
items: std.ArrayList(Contour) = .empty,

pub fn init(allocator: Allocator, path: Path, options: Options) !Contours {
    var result: Contours = .{ .allocator = allocator };
    errdefer result.deinit();
    var current: ?Point = null;
    var start: Point = .zero;
    var first: usize = 0;
    var count: usize = 0;
    var vertices: usize = 0;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (!point.isFinite()) return error.NonFinite;
            if (vertices >= options.max_vertices) return error.GeometryWorkLimit;
            vertices += 1;
            if (current != null) try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = false });
            first = result.spans.items.len;
            current = point;
            start = point;
        },
        .line => |point| {
            const previous = current orelse return error.InvalidPath;
            if (!point.isFinite()) return error.NonFinite;
            if (vertices >= options.max_vertices) return error.GeometryWorkLimit;
            vertices += 1;
            count += 1;
            if (count > options.max_segments) return error.GeometryWorkLimit;
            try result.line(previous, point);
            current = point;
        },
        .cubic => |value| {
            const curve: g.Cubic = .{ .p0 = current orelse return error.InvalidPath, .p1 = value.c1, .p2 = value.c2, .p3 = value.end };
            if (!curve.isFinite()) return error.NonFinite;
            if (3 > options.max_vertices - vertices) return error.GeometryWorkLimit;
            vertices += 3;
            count += 1;
            if (count > options.max_segments) return error.GeometryWorkLimit;
            if (try direction(curve, false)) |incoming| try result.spans.append(allocator, .{ .curve = curve, .first = incoming, .last = (try direction(curve, true)).?, .cubic = true });
            current = curve.p3;
        },
        .close => {
            const previous = current orelse return error.InvalidPath;
            if (!previous.eql(start)) {
                count += 1;
                if (count > options.max_segments) return error.GeometryWorkLimit;
                try result.line(previous, start);
            }
            try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = true });
            current = null;
        },
    };
    if (current != null) try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = false });
    // A line/cubic span is charged by its input coordinates, and an
    // implicit closing span by its contour's move. Both temporary arrays
    // are therefore bounded while parsing, before any envelope expansion.
    return result;
}
pub fn line(self: *Contours, a: Point, b: Point) !void {
    if (a.eql(b)) return;
    const tangent = try b.sub(a).normalized();
    try self.spans.append(self.allocator, .{ .curve = .{ .p0 = a, .p1 = a, .p2 = b, .p3 = b }, .first = tangent, .last = tangent, .cubic = false });
}
pub fn deinit(self: *Contours) void {
    self.spans.deinit(self.allocator);
    self.items.deinit(self.allocator);
}

const Span = struct { curve: g.Cubic, first: Point, last: Point, cubic: bool };

const Contour = struct { start: Point, first: usize, count: usize, closed: bool };

fn direction(curve: g.Cubic, last: bool) !?Point {
    const points = if (last) [_]Point{ curve.p2, curve.p1, curve.p0 } else [_]Point{ curve.p1, curve.p2, curve.p3 };
    for (points) |point| {
        const delta = if (last) curve.p3.sub(point) else point.sub(curve.p0);
        if (delta.x != 0 or delta.y != 0) return try delta.normalized();
    }
    return null;
}
