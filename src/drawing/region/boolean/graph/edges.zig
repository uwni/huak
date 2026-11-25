// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see ../LICENSE.
//! Edges from cuts: one edge per piece, merged into an existing edge by adding the signed windings.
const std = @import("std");
const geometry = @import("../../../geometry.zig");
const curves = @import("../curve.zig");
const Cubic = geometry.Cubic;
const graph = @import("../graph.zig");
const short_edges = @import("short_edges.zig");

/// Turns the cuts of every source into edges with winding weights.
pub fn createEdges(self: *graph.Builder, edge_capacity: usize) !void {
    const allocator = self.allocator;
    const sources = self.graph.sources;
    const epsilon = self.epsilon;
    try self.graph.edges.ensureTotalCapacityPrecise(self.storage, edge_capacity);
    const by_vertex = try allocator.alloc(std.ArrayList(usize), self.graph.vertices.items.len);
    @memset(by_vertex, .empty);
    const vertices = self.graph.vertices.items;
    for (self.cuts, sources, 0..) |cuts, *source, i| {
        const handles = curves.hasHandles(&source.cubic);
        for (cuts.items[1..], cuts.items[0 .. cuts.items.len - 1]) |last, first| {
            const from = self.vertexIndex(first.sample);
            const to = self.vertexIndex(last.sample);
            const part = graph.snappedPart(&source.cubic, handles, first.time, last.time, vertices[from].point, vertices[to].point);
            if (from == to and short_edges.shortLength(&part, 4 * epsilon)) continue;
            var weights: [2]i32 = .{ 0, 0 };
            weights[source.operand] = 1;
            try addEdge(self, by_vertex, .{ .cubic = part, .from = from, .to = to, .windings = weights, .curve = i, .time1 = first.time, .time2 = last.time, .straight = !handles });
        }
    }
}

fn addEdge(self: *graph.Builder, by_vertex: []std.ArrayList(usize), edge: graph.Edge) !void {
    const first = @min(edge.from, edge.to);
    const last = @max(edge.from, edge.to);
    for (by_vertex[first].items) |other_index| {
        const other = &self.graph.edges.items[other_index];
        if (@max(other.from, other.to) != last) continue;
        const direction = if (other.straight and edge.straight) blk: {
            if (other.cubic.p0.eql(edge.cubic.p0)) break :blk 1;
            if (other.cubic.p0.eql(edge.cubic.p3)) break :blk -1;
            break :blk coincidence(self, other, &edge);
        } else coincidence(self, other, &edge);
        if (direction != 0) {
            for (0..2) |j| other.windings[j] = try std.math.add(i32, other.windings[j], direction * edge.windings[j]);
            return;
        }
    }
    try by_vertex[first].append(self.allocator, self.graph.edges.items.len);
    self.graph.edges.appendAssumeCapacity(edge);
}

fn coincidence(self: *graph.Builder, a: *const graph.Edge, b: *const graph.Edge) i32 {
    var times: [3]f64 = undefined;
    for (&times, 1..) |*time, i| {
        const p = curves.getPoint(&b.cubic, @as(f64, @floatFromInt(i)) / 4);
        // The verified adapter uses the upstream tolerance-aware on-curve
        // query; nearest-point search has a different accuracy contract.
        time.* = curves.getTimeOf(&a.cubic, p, self.epsilon) orelse return 0;
    }
    // On short edges, two samples can both snap to time zero. Distinct
    // endpoint vertices give the exact orientation even in that case.
    if (a.from != a.to) return if (a.from == b.from) 1 else -1;
    return if (times[0] < times[2]) 1 else -1;
}

test "coincident short curves add winding forward and subtract winding in reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var g: graph.Graph = .{ .sources = &.{} };
    var builder: graph.Builder = .{ .graph = &g, .allocator = allocator, .storage = allocator, .epsilon = 1, .cuts = &.{} };
    var by_vertex: [2]std.ArrayList(usize) = @splat(.empty);
    try g.edges.ensureTotalCapacity(allocator, 3);
    // The endpoints are farther apart than epsilon, yet all three interior
    // membership probes lie in the snapping neighborhood of the start.
    const curve: Cubic = .{ .p0 = .zero, .p1 = .{ .x = 0.4, .y = 0.1 }, .p2 = .{ .x = 0.8, .y = 0.1 }, .p3 = .{ .x = 1.25, .y = 0 } };
    var edge: graph.Edge = .{ .cubic = curve, .from = 0, .to = 1, .curve = 0, .time1 = 0, .time2 = 1, .windings = .{ 1, 0 }, .straight = false };
    try addEdge(&builder, &by_vertex, edge);
    try addEdge(&builder, &by_vertex, edge);
    try std.testing.expectEqual([2]i32{ 2, 0 }, g.edges.items[0].windings);
    edge.cubic = curve.reversed();
    std.mem.swap(usize, &edge.from, &edge.to);
    try addEdge(&builder, &by_vertex, edge);
    try std.testing.expectEqual(@as(usize, 1), g.edges.items.len);
    try std.testing.expectEqual([2]i32{ 1, 0 }, g.edges.items[0].windings);
}
