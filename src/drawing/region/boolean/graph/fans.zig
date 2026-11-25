// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see ../LICENSE.
//! Half-edges and vertex fans: half-edge pairs, outgoing ranges per vertex, twin links, and the cyclic order of edges around each vertex.
const std = @import("std");
const types = @import("../types.zig");
const geometry = @import("../../../geometry.zig");
const curves = @import("../curve.zig");
const Point = types.Point;
const Cubic = geometry.Cubic;
const graph = @import("../graph.zig");

const Directions = struct { start: f64, width: f64 };

const SortEntry = struct { index: usize, directions: Directions = undefined, angle: f64 = undefined };

/// Links every edge's two half-edges into the cyclic fan around its vertices.
pub fn linkHalfEdges(self: *graph.Builder) !void {
    const allocator = self.allocator;
    // Edges are complete before their values are borrowed. Both orientations
    // stay stable for the operation arena's lifetime.
    const half_edge_count = try std.math.mul(usize, self.graph.edges.items.len, 2);
    try self.graph.half_edges.ensureTotalCapacityPrecise(self.storage, half_edge_count);
    const offsets = try allocator.alloc(usize, self.graph.vertices.items.len + 1);
    @memset(offsets, 0);
    for (self.graph.edges.items) |edge| {
        offsets[edge.from + 1] += 1;
        offsets[edge.to + 1] += 1;
    }
    for (offsets[1..], 0..) |*end, i| end.* += offsets[i];
    const outgoing_edges = try allocator.alloc(usize, half_edge_count);
    const cursors = try allocator.dupe(usize, offsets[0..self.graph.vertices.items.len]);
    const reversed = try self.storage.alloc(Cubic, self.graph.edges.items.len);
    for (self.graph.edges.items, reversed, 0..) |*edge, *back, i| {
        back.* = edge.cubic.reversed();
        self.graph.half_edges.appendAssumeCapacity(.{ .edge = i, .cubic = &edge.cubic, .from = edge.from, .to = edge.to });
        self.graph.half_edges.appendAssumeCapacity(.{ .edge = i, .cubic = back, .from = edge.to, .to = edge.from });
        outgoing_edges[cursors[edge.from]] = 2 * i;
        cursors[edge.from] += 1;
        outgoing_edges[cursors[edge.to]] = 2 * i + 1;
        cursors[edge.to] += 1;
    }
    var sort: std.ArrayList(SortEntry) = .empty;
    defer sort.deinit(allocator);
    for (0..self.graph.vertices.items.len) |i| {
        const outgoing = outgoing_edges[offsets[i]..offsets[i + 1]];
        if (outgoing.len > 2) {
            try sort.resize(allocator, outgoing.len);
            if (!sortByDirections(self, outgoing, sort.items)) try sortByExit(self, outgoing, sort.items);
        }
        for (outgoing, 0..) |index, position| {
            self.graph.half_edges.items[index ^ 1].next = outgoing[(if (position == 0) outgoing.len else position) - 1];
        }
    }
}

fn sortByDirections(self: *graph.Builder, outgoing: []usize, sorted: []SortEntry) bool {
    var distance = std.math.inf(f64);
    for (outgoing, sorted) |index, *entry| {
        const half = &self.graph.half_edges.items[index];
        entry.* = .{ .index = index, .directions = directions(half.cubic) orelse return false };
        const delta = half.cubic.p0.sub(half.cubic.p3);
        distance = @min(distance, @sqrt(delta.dot(delta)) / 2);
    }
    std.mem.sort(SortEntry, sorted, {}, struct {
        fn less(_: void, a: SortEntry, b: SortEntry) bool {
            return a.directions.start < b.directions.start;
        }
    }.less);
    var gap = std.math.inf(f64);
    var width: f64 = 0;
    for (sorted, 0..) |entry, i| {
        const first = entry.directions;
        const second = sorted[(i + 1) % sorted.len].directions;
        gap = @min(gap, second.start - first.start - first.width + (if (i + 1 < sorted.len) @as(f64, 0) else std.math.tau));
        width = @max(width, first.width);
    }
    if (gap > 0 and distance * @cos(width / 2) * @sin(@min(gap, std.math.pi / 2.0)) > 2 * self.epsilon) {
        for (outgoing, sorted) |*index, entry| index.* = entry.index;
        return true;
    }
    return false;
}

// Incident edges begin at the same vertex and do not cross again before
// their ends. Their first contacts with one surrounding square give the
// cyclic order, including edges leaving with the same tangent.
fn sortByExit(self: *graph.Builder, outgoing: []usize, sorted: []SortEntry) !void {
    var radius = std.math.inf(f64);
    for (outgoing) |index| {
        const v = self.graph.half_edges.items[index].cubic;
        const box = v.bounds();
        const lo = v.p0.sub(box.min);
        const hi = box.max.sub(v.p0);
        radius = @min(radius, @max(lo.x, lo.y, hi.x, hi.y) / 2);
    }
    if (!(radius > 0)) return error.PrecisionRange;
    for (outgoing, sorted) |index, *entry| {
        const v = self.graph.half_edges.items[index].cubic;
        // Work relative to the vertex so small exit displacements retain
        // their precision when the vertex is far from the coordinate origin.
        const local: Cubic = .{ .p0 = .zero, .p1 = v.p1.sub(v.p0), .p2 = v.p2.sub(v.p0), .p3 = v.p3.sub(v.p0) };
        var first = std.math.inf(f64);
        inline for (0..2) |axis| {
            for ([_]f64{ -radius, radius }) |wall| {
                var roots: [3]f64 = undefined;
                const count = curves.solveCubic(&local, axis, wall, &roots, 0, 1);
                if (count > 0) for (roots[0..@intCast(count)]) |t| {
                    if (t > 0) first = @min(first, t);
                };
            }
        }
        if (!std.math.isFinite(first)) return error.PrecisionRange;
        const p = local.at(first);
        entry.* = .{ .index = index, .angle = std.math.atan2(p.y, p.x) };
    }
    std.mem.sort(SortEntry, sorted, {}, struct {
        fn less(_: void, a: SortEntry, b: SortEntry) bool {
            return a.angle < b.angle;
        }
    }.less);
    for (outgoing, sorted) |*index, entry| index.* = entry.index;
}

fn directions(v: *const Cubic) ?Directions {
    var angles: [3]f64 = undefined;
    var count: usize = 0;
    inline for ([_]struct { a: Point, b: Point }{
        .{ .a = v.p0, .b = v.p1 },
        .{ .a = v.p1, .b = v.p2 },
        .{ .a = v.p2, .b = v.p3 },
    }) |pair| {
        const dx = pair.b.x - pair.a.x;
        const dy = pair.b.y - pair.a.y;
        if (dx != 0 or dy != 0) {
            angles[count] = std.math.atan2(dy, dx);
            count += 1;
        }
    }
    if (count == 0) return null;
    var from: f64 = 0;
    var to: f64 = 0;
    for (angles[1..count]) |angle| {
        const difference = @mod(angle - angles[0] + 3 * std.math.pi, std.math.tau) - std.math.pi;
        from = @min(from, difference);
        to = @max(to, difference);
    }
    return if (to - from < std.math.pi) .{ .start = @mod(angles[0] + from + std.math.tau, std.math.tau), .width = to - from } else null;
}
