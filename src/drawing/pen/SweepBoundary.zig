//! Adjacent parameter cells traverse internal straight edges in opposite
//! directions. Cancel these before asking the curve Boolean kernel to trim
//! overlaps. Winding (including multiplicity and holes) is preserved.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Point = g.Point;
const Boundary = @This();
const PointKey = [2]u64;
const Line = [2]PointKey;
allocator: std.mem.Allocator,
lines: std.AutoHashMapUnmanaged(Line, i32) = .empty,
curves: std.ArrayList(g.Cubic) = .empty,
limit: usize,

fn key(p: Point) PointKey {
    return .{ @bitCast(if (p.x == 0) @as(f64, 0) else p.x), @bitCast(if (p.y == 0) @as(f64, 0) else p.y) };
}
fn point(k: PointKey) Point {
    return .{ .x = @bitCast(k[0]), .y = @bitCast(k[1]) };
}

pub fn deinit(self: *Boundary) void {
    self.lines.deinit(self.allocator);
    self.curves.deinit(self.allocator);
}

pub fn line(self: *Boundary, a: Point, b: Point) !void {
    if (a.eql(b)) return;
    const forward = a.x < b.x or (a.x == b.x and a.y < b.y);
    const pair: Line = if (forward) .{ key(a), key(b) } else .{ key(b), key(a) };
    const entry = try self.lines.getOrPut(self.allocator, pair);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    entry.value_ptr.* = try std.math.add(i32, entry.value_ptr.*, if (forward) @as(i32, 1) else -1);
    if (entry.value_ptr.* == 0) self.lines.removeByPtr(entry.key_ptr);
    if (self.lines.count() + self.curves.items.len > self.limit) return error.GeometryWorkLimit;
}

const Edge = struct { to: Point, curve: ?usize, next: ?usize };
const Graph = struct {
    a: std.mem.Allocator,
    heads: std.AutoHashMapUnmanaged(PointKey, ?usize) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    fn add(self: *Graph, from: Point, to: Point, curve: ?usize) !void {
        const slot = try self.heads.getOrPut(self.a, key(from));
        const next = if (slot.found_existing) slot.value_ptr.* else null;
        try self.edges.append(self.a, .{ .to = to, .curve = curve, .next = next });
        slot.value_ptr.* = self.edges.items.len - 1;
    }
};

pub fn contours(self: *Boundary) !Path {
    var graph: Graph = .{ .a = self.allocator };
    defer graph.heads.deinit(self.allocator);
    defer graph.edges.deinit(self.allocator);
    var it = self.lines.iterator();
    while (it.next()) |entry| {
        const pts = entry.key_ptr.*;
        const forwards = entry.value_ptr.* > 0;
        const n = @abs(entry.value_ptr.*);
        if (n > self.limit -| graph.edges.items.len) return error.GeometryWorkLimit;
        for (0..n) |_| try graph.add(point(pts[@intFromBool(!forwards)]), point(pts[@intFromBool(forwards)]), null);
    }
    for (self.curves.items, 0..) |c, i| try graph.add(c.p0, c.p3, i);
    var path = Path.init(self.allocator);
    errdefer path.deinit();
    var heads = graph.heads.iterator();
    while (heads.next()) |entry| {
        const start = point(entry.key_ptr.*);
        while (entry.value_ptr.* != null) {
            try path.moveTo(start);
            var current = start;
            while (true) {
                const head = graph.heads.getPtr(key(current)) orelse return error.InvalidSweepBoundary;
                const edge = graph.edges.items[head.* orelse return error.InvalidSweepBoundary];
                head.* = edge.next;
                if (edge.curve) |i| {
                    const c = self.curves.items[i];
                    try path.cubicTo(c.p1, c.p2, c.p3);
                } else if (!edge.to.eql(start)) try path.lineTo(edge.to);
                current = edge.to;
                if (current.eql(start)) break;
            }
            try path.close();
        }
    }
    return path;
}
