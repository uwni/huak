// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see ../LICENSE.
//! Snapping vertices onto pieces: per source, index the eligible vertices along the wider axis and split a piece at each vertex it passes through.
const std = @import("std");
const curves = @import("../curve.zig");
const graph = @import("../graph.zig");
const samples = @import("samples.zig");

const Interval = struct { first: graph.Cut, last: graph.Cut };

const Candidate = struct {
    coordinate: f64,
    vertex: usize,

    fn less(_: void, a: Candidate, b: Candidate) bool {
        return a.coordinate < b.coordinate;
    }
    fn compare(coordinate: f64, candidate: Candidate) std.math.Order {
        return std.math.order(coordinate, candidate.coordinate);
    }
    fn inRange(sorted: []const Candidate, low: f64, high: f64) []const Candidate {
        const start = std.sort.lowerBound(Candidate, sorted, low, compare);
        const tail = sorted[start..];
        return tail[0..std.sort.upperBound(Candidate, tail, high, compare)];
    }
};

/// Splits each source's pieces at the vertices they pass through, after
/// snapping, so that every crossing is a shared cut.
pub fn snapVertices(self: *graph.Builder, candidates: []const std.ArrayList(usize), marks: []usize) !void {
    const allocator = self.allocator;
    const sources = self.graph.sources;
    const epsilon = self.epsilon;
    var pixels: std.ArrayList(Candidate) = .empty;
    var nearby: std.ArrayList(usize) = .empty;
    var pieces: std.ArrayList(Interval) = .empty;
    for (sources, 0..) |*source, i| {
        pixels.clearRetainingCapacity();
        const bounds = source.cubic.controlBounds().expanded(2 * epsilon);
        // Build one index per source along its larger spatial extent.
        const axis: usize = @intFromBool(bounds.height() > bounds.width());
        for (candidates[i].items) |other| for (self.cuts[other].items) |cut| {
            const vertex = self.vertexIndex(cut.sample);
            if (marks[vertex] == i) continue;
            marks[vertex] = i;
            const point = self.graph.vertices.items[vertex].point;
            if (bounds.contains(point)) try pixels.append(allocator, .{ .vertex = vertex, .coordinate = if (axis == 0) point.x else point.y });
        };
        std.mem.sort(Candidate, pixels.items, {}, Candidate.less);
        if (pixels.items.len == 0) continue;
        const handles = curves.hasHandles(&source.cubic);
        samples.sortCuts(self.cuts[i].items);
        pieces.clearRetainingCapacity();
        const list = self.cuts[i].items;
        for (list[1..], list[0 .. list.len - 1]) |last, first| try pieces.append(allocator, .{ .first = first, .last = last });
        while (pieces.pop()) |interval| {
            const first = self.vertexIndex(interval.first.sample);
            const last = self.vertexIndex(interval.last.sample);
            // Endpoints cannot split their own interval. Peel them before
            // constructing its Bézier, retaining a sorted search range.
            var candidates_left = pixels.items;
            while (candidates_left.len > 0 and (candidates_left[0].vertex == first or candidates_left[0].vertex == last))
                candidates_left = candidates_left[1..];
            if (candidates_left.len == 0) continue;
            const piece = graph.snappedPart(&source.cubic, handles, interval.first.time, interval.last.time, self.graph.vertices.items[first].point, self.graph.vertices.items[last].point);
            // Snapping moves controls. Query the new piece's own bounds.
            const box = piece.controlBounds().expanded(epsilon);
            nearby.clearRetainingCapacity();
            for (Candidate.inRange(candidates_left, box.low(axis), box.high(axis))) |candidate| {
                if (candidate.vertex == first or candidate.vertex == last) continue;
                const point = self.graph.vertices.items[candidate.vertex].point;
                if (box.contains(point) and !curves.outsideChordStrip(&piece, point, epsilon))
                    try nearby.append(allocator, candidate.vertex);
            }
            // The first accepted vertex determines how subsequent splits snap.
            std.mem.sort(usize, nearby.items, {}, std.sort.asc(usize));
            for (nearby.items) |vertex_index| {
                const vertex = self.graph.vertices.items[vertex_index];
                const time = curves.getNearestTime(&piece, vertex.point) orelse continue;
                if (time > 0 and time < 1 and curves.withinDistance(vertex.point, curves.getPoint(&piece, time), epsilon)) {
                    const original_time = if (handles) interval.first.time + (interval.last.time - interval.first.time) * time else curves.getNearestTime(&source.cubic, vertex.point) orelse return error.GeometryFailed;
                    // An interior time on the snapped piece can round to a
                    // source endpoint. Splitting there repeats this interval.
                    if (!(original_time > interval.first.time and original_time < interval.last.time)) continue;
                    const cut: graph.Cut = .{ .time = original_time, .sample = vertex.sample };
                    try self.cuts[i].append(allocator, cut);
                    try pieces.append(allocator, .{ .first = interval.first, .last = cut });
                    try pieces.append(allocator, .{ .first = cut, .last = interval.last });
                    break;
                }
            }
        }
    }
}

test "piece lookup retains all vertices on either bound, including zero-width ranges" {
    const vertices = [_]Candidate{
        .{ .coordinate = -1, .vertex = 4 },
        .{ .coordinate = 0, .vertex = 3 },
        .{ .coordinate = 0, .vertex = 2 },
        .{ .coordinate = 1, .vertex = 1 },
        .{ .coordinate = 1, .vertex = 0 },
    };
    try std.testing.expectEqualSlices(Candidate, vertices[1..], Candidate.inRange(&vertices, 0, 1));
    try std.testing.expectEqualSlices(Candidate, vertices[1..3], Candidate.inRange(&vertices, 0, 0));
    try std.testing.expectEqual(0, Candidate.inRange(&vertices, 0.25, 0.75).len);
}
