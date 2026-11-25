// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see ../LICENSE.
//! Contracting short spans: vertex degrees and edge capacity, short pieces, and clusters of ordinary subdivisions merged into one vertex.
const std = @import("std");
const geometry = @import("../../../geometry.zig");
const curves = @import("../curve.zig");
const Cubic = geometry.Cubic;
const graph = @import("../graph.zig");
const samples = @import("samples.zig");

/// Contracts clusters of short ordinary subdivisions into one vertex and
/// returns the number of edges the cuts can produce.
pub fn mergeShortEdges(self: *graph.Builder, marks: []usize) !usize {
    const allocator = self.allocator;
    const sources = self.graph.sources;
    const epsilon = self.epsilon;
    var short: std.ArrayList([2]usize) = .empty;
    var edge_capacity: usize = 0;
    const degree = marks;
    @memset(degree, 0);
    for (self.cuts, sources) |*cuts, *source| {
        edge_capacity = try std.math.add(usize, edge_capacity, cuts.items.len - 1);
        samples.sortCuts(cuts.items);
        for (cuts.items[1..], cuts.items[0 .. cuts.items.len - 1]) |last, first| {
            const first_vertex = self.vertexIndex(first.sample);
            const last_vertex = self.vertexIndex(last.sample);
            if (first.time != last.time) {
                degree[first_vertex] += 1;
                degree[last_vertex] += 1;
            }
            if (first_vertex == last_vertex) continue;
            const first_point = self.graph.vertices.items[first_vertex].point;
            const last_point = self.graph.vertices.items[last_vertex].point;
            const delta = last_point.sub(first_point);
            // The vertex chord lower-bounds the piece length. Pieces at
            // least the threshold apart cannot be merged as short.
            if (delta.dot(delta) >= 16 * epsilon * epsilon) continue;
            const part = graph.snappedPart(&source.cubic, curves.hasHandles(&source.cubic), first.time, last.time, first_point, last_point);
            if (shortLength(&part, 4 * epsilon)) try short.append(allocator, .{ first.sample, last.sample });
        }
    }
    if (short.items.len != 0) {
        // A chain of individually short spans can enclose a large feature.
        // Bound the whole cluster in the same spatial budget as a single span.
        const boxes = try allocator.alloc(geometry.BBox, self.graph.vertices.items.len);
        for (self.graph.vertices.items, boxes) |vertex, *box| box.* = geometry.BBox.fromPoint(vertex.point);
        for (short.items) |pair| {
            // Moving a junction changes the cyclic order of the edges that
            // wind around it. Only contract ordinary subdivisions of a run.
            if (degree[self.vertexIndex(pair[0])] != 2 or degree[self.vertexIndex(pair[1])] != 2) continue;
            const first = self.root(pair[0]);
            const last = self.root(pair[1]);
            if (first == last) continue;
            const destination = self.vertexIndex(last);
            const box = boxes[self.vertexIndex(first)].unite(boxes[destination]);
            const diagonal = box.max.sub(box.min);
            if (diagonal.dot(diagonal) >= 16 * epsilon * epsilon) continue;
            self.samples.items[first].parent = last;
            boxes[destination] = box;
        }
        try samples.createVertices(self);
    }
    return edge_capacity;
}

/// The chord is a lower bound on arc length, so a chord at least the length
/// threshold already proves the threshold cannot match. Only pieces with a
/// short chord run the length integration.
pub fn shortLength(v: *const Cubic, threshold: f64) bool {
    const dx = v.p3.x - v.p0.x;
    const dy = v.p3.y - v.p0.y;
    if (dx * dx + dy * dy >= threshold * threshold) return false;
    return curves.getLength(v, 0, 1) < threshold;
}
