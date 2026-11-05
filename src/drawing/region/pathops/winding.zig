// Copyright 2018 Google LLC. BSD-style license: LICENSE.
//! Read-only winding query retained for stroke-section regression probes.
//! Curve roots determine ray crossings; no topology or output is constructed.
const Path = @import("../../path/Path.zig");
const g = @import("../../geometry.zig");
const curves = @import("curve.zig");

fn equal(a: g.Point, b: g.Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn cubic(points: [4]g.Point) curves.Cubic {
    return .{ .points = .{
        .{ .x = points[0].x, .y = points[0].y },
        .{ .x = points[1].x, .y = points[1].y },
        .{ .x = points[2].x, .y = points[2].y },
        .{ .x = points[3].x, .y = points[3].y },
    } };
}

const Edge = union(enum) {
    line: [2]g.Point,
    cubic: [4]g.Point,

    fn first(self: Edge) g.Point {
        return switch (self) {
            .line => |p| p[0],
            .cubic => |p| p[0],
        };
    }
    fn last(self: Edge) g.Point {
        return switch (self) {
            .line => |p| p[1],
            .cubic => |p| p[3],
        };
    }
    fn bounds(self: Edge) g.BBox {
        return switch (self) {
            .line => |p| .fromPoints(p[0], p[1]),
            .cubic => |p| g.BBox.fromPoints(p[0], p[3]).include(p[1]).include(p[2]),
        };
    }
    fn horizontal(self: Edge) bool {
        return switch (self) {
            .line => |p| p[0].y == p[1].y,
            .cubic => |p| p[0].y == p[1].y and p[0].y == p[2].y and p[0].y == p[3].y,
        };
    }
    fn at(self: Edge, time: f64) g.Point {
        return switch (self) {
            .line => |p| p[0].lerp(p[1], time),
            .cubic => |p| blk: {
                const point = cubic(p).ptAtT(time);
                break :blk .{ .x = point.x, .y = point.y };
            },
        };
    }
    fn slopeY(self: Edge, time: f64) f64 {
        return switch (self) {
            .line => |p| p[1].y - p[0].y,
            .cubic => |p| cubic(p).dxdyAtT(time).y,
        };
    }
    fn intercept(self: Edge, y: f64, roots: *[3]f64) usize {
        return switch (self) {
            .line => |p| blk: {
                const line: curves.Line = .{ .points = .{ .{ .x = p[0].x, .y = p[0].y }, .{ .x = p[1].x, .y = p[1].y } } };
                var times: [1]f64 = undefined;
                const count = line.horizontalIntersect(y, &times);
                if (count != 0) roots[0] = times[0];
                break :blk count;
            },
            .cubic => |p| cubic(p).horizontalIntersect(y, roots),
        };
    }
};

/// Half-open horizontal ray to the left, matching Skia's to_direction sign.
/// Contributions are negative for increasing Y; zero/nonzero determines ink.
fn containsEdge(edge: Edge, point: g.Point) i32 {
    const box = edge.bounds();
    if (box.min.y > point.y or box.max.y <= point.y or box.min.x >= point.x) return 0;
    if (box.max.x < point.x) {
        // Control-hull quickaccept has the same sign as the exact root path.
        // Interior crossings cancel; only endpoint transitions remain.
        return @as(i32, @intFromBool(edge.first().y > point.y)) - @as(i32, @intFromBool(edge.last().y > point.y));
    }
    var times: [3]f64 = undefined;
    const count = edge.intercept(point.y, &times);
    var winding: i32 = 0;
    for (times[0..count]) |time| {
        const x = edge.at(time).x;
        if (x > point.x) continue;
        if (x == point.x and !(edge.first().x < point.x and edge.last().x < point.x)) continue;
        const dy = edge.slopeY(time);
        const sign: i32 = if (dy > 0) -1 else if (dy < 0) 1 else 0;
        if (time == 0 and point.y == edge.first().y and sign != -1) continue;
        if (time == 1 and point.y == edge.last().y and sign != 1) continue;
        winding += sign;
    }
    return winding;
}

const EdgeIterator = struct {
    segments: []const Path.Segment,
    index: usize = 1,
    current: g.Point,
    start: g.Point,
    closed: bool = false,

    fn init(segments: []const Path.Segment) !EdgeIterator {
        const start = if (segments.len == 0) return error.InvalidPath else switch (segments[0]) {
            .move => |point| point,
            else => return error.InvalidPath,
        };
        if (!start.isFinite()) return error.NonFinite;
        return .{ .segments = segments, .current = start, .start = start };
    }
    fn next(self: *EdgeIterator) !?Edge {
        while (self.index < self.segments.len) {
            const segment = self.segments[self.index];
            self.index += 1;
            const from = self.current;
            switch (segment) {
                .line => |point| {
                    if (!point.isFinite()) return error.NonFinite;
                    self.current = point;
                    return .{ .line = .{ from, point } };
                },
                .cubic => |curve| {
                    if (!curve.c1.isFinite() or !curve.c2.isFinite() or !curve.end.isFinite()) return error.NonFinite;
                    self.current = curve.end;
                    return .{ .cubic = .{ from, curve.c1, curve.c2, curve.end } };
                },
                .close => {
                    if (self.index != self.segments.len) return error.InvalidPath;
                    self.closed = true;
                    self.current = self.start;
                    if (!equal(from, self.start)) return .{ .line = .{ from, self.start } };
                },
                .move => return error.InvalidPath,
            }
        }
        if (!self.closed) {
            self.closed = true;
            if (!equal(self.current, self.start)) return .{ .line = .{ self.current, self.start } };
        }
        return null;
    }
};

fn contourWinding(segments: []const Path.Segment, point: g.Point) !i32 {
    var iterator = try EdgeIterator.init(segments);
    var winding: i32 = 0;
    while (try iterator.next()) |edge| if (!edge.horizontal()) {
        winding += containsEdge(edge, point);
    };
    return winding;
}

pub fn windingAt(source: Path, point: g.Point) !i32 {
    if (!point.isFinite()) return error.NonFinite;
    var winding: i32 = 0;
    var first: ?usize = null;
    for (source.segments.items, 0..) |segment, index| {
        if (segment == .move) {
            if (first) |start| winding += try contourWinding(source.segments.items[start..index], point);
            first = index;
        } else if (first == null) return error.InvalidPath;
    }
    if (first) |start| winding += try contourWinding(source.segments.items[start..], point);
    return winding;
}
