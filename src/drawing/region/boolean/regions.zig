// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 face winding propagation and tracePaths.
const std = @import("std");
const Path = @import("../../path/Path.zig");
const api = @import("../root.zig");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const curves = @import("curve.zig");
const graph = @import("graph.zig");
const collisions = @import("collisions.zig");
const Point = types.Point;

const none = std.math.maxInt(usize);
const Face = struct { edge: usize, area: f64 = 0, windings: ?[2]i32 = null, component: usize = none, inside: bool = false };
const Component = struct { edge_start: usize = 0, edge_len: usize = 0, outside: usize };

/// Borrows a face cycle validated during discovery. The graph owns its links.
const FaceEdges = struct {
    edges: []const graph.HalfEdge,
    start: usize,
    current: ?usize,

    fn init(g: *const graph.Graph, face: Face) FaceEdges {
        return .{ .edges = g.half_edges.items, .start = face.edge, .current = face.edge };
    }
    fn next(self: *FaceEdges) ?usize {
        const index = self.current orelse return null;
        const following = self.edges[index].next;
        self.current = if (following == self.start) null else following;
        return index;
    }
};

pub fn trace(g: *graph.Graph, result_allocator: types.Allocator, operation: api.Operation, rule: api.FillRule) !Path {
    var arena = std.heap.ArenaAllocator.init(result_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var faces: std.ArrayList(Face) = .empty;
    for (g.half_edges.items, 0..) |half, i| {
        if (half.face != none) continue;
        const face_index = faces.items.len;
        var face: Face = .{ .edge = i };
        var index = i;
        while (true) {
            const edge = &g.half_edges.items[index];
            if (edge.face != none) return error.GeometryFailed;
            edge.face = face_index;
            face.area += curves.getArea(edge.cubic);
            index = edge.next;
            if (index == i) break;
        }
        try faces.append(allocator, face);
    }
    var components: std.ArrayList(Component) = .empty;
    var queue: std.ArrayList(usize) = .empty;
    for (0..faces.items.len) |i| {
        if (faces.items[i].component != none) continue;
        const component = components.items.len;
        var outside = i;
        queue.clearRetainingCapacity();
        try queue.append(allocator, i);
        faces.items[i].component = component;
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const face_index = queue.items[cursor];
            const face = &faces.items[face_index];
            if (face.area < faces.items[outside].area) outside = face_index;
            var edges = FaceEdges.init(g, face.*);
            while (edges.next()) |index| {
                const other = &faces.items[g.half_edges.items[index ^ 1].face];
                if (other.component == none) {
                    other.component = component;
                    try queue.append(allocator, g.half_edges.items[index ^ 1].face);
                }
            }
        }
        try components.append(allocator, .{ .outside = outside });
    }
    const bounds = try allocator.alloc(geometry.BBox, components.items.len);
    for (g.edges.items, 0..) |*edge, i| {
        const index = faces.items[g.half_edges.items[2 * i].face].component;
        const component = &components.items[index];
        const box = edge.cubic.controlBounds();
        bounds[index] = if (component.edge_len == 0) box else bounds[index].unite(box);
        component.edge_len += 1;
    }
    var total_edges: usize = 0;
    for (components.items) |*component| {
        component.edge_start = total_edges;
        total_edges += component.edge_len;
    }
    const component_edges = try allocator.alloc(usize, total_edges);
    const cursors = try allocator.alloc(usize, components.items.len);
    const rays = try allocator.alloc(geometry.BBox, components.items.len);
    for (components.items, cursors, rays) |component, *cursor, *ray| {
        cursor.* = component.edge_start;
        const vertex = g.vertices.items[g.half_edges.items[faces.items[component.outside].edge].from].point;
        ray.* = .{ .min = vertex, .max = .{ .x = std.math.inf(f64), .y = vertex.y } };
    }
    for (g.edges.items, 0..) |_, i| {
        const component_index = faces.items[g.half_edges.items[2 * i].face].component;
        component_edges[cursors[component_index]] = i;
        cursors[component_index] += 1;
    }
    const candidates = try collisions.boundsCandidates(allocator, rays, bounds, 0, true);
    for (components.items, 0..) |component, i| {
        const p: Point = rays[i].min;
        var windings: [2]i32 = .{ 0, 0 };
        for (candidates[i].items) |other| {
            if (other == i) continue;
            for (component_edges[components.items[other].edge_start..][0..components.items[other].edge_len]) |index| {
                const edge = &g.edges.items[index];
                const winding = rayWinding(p, &edge.cubic);
                for (0..2) |operand| windings[operand] = try std.math.add(i32, windings[operand], try std.math.mul(i32, winding, edge.windings[operand]));
            }
        }
        faces.items[component.outside].windings = windings;
        queue.clearRetainingCapacity();
        try queue.append(allocator, component.outside);
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const face = &faces.items[queue.items[cursor]];
            var edges = FaceEdges.init(g, face.*);
            while (edges.next()) |index| {
                const other_index = g.half_edges.items[index ^ 1].face;
                const other = &faces.items[other_index];
                if (other.windings != null) continue;
                const weights = g.edges.items[g.half_edges.items[index].edge].windings;
                const sign: i32 = if (index & 1 != 0) -1 else 1;
                var value: [2]i32 = undefined;
                for (0..2) |operand| value[operand] = try std.math.sub(i32, face.windings.?[operand], try std.math.mul(i32, sign, weights[operand]));
                other.windings = value;
                try queue.append(allocator, other_index);
            }
        }
    }
    for (faces.items) |*face| {
        const w = face.windings orelse return error.GeometryFailed;
        const a = filled(w[0], rule);
        const b = filled(w[1], rule);
        face.inside = switch (operation) {
            .unite => a or b,
            .intersect => a and b,
            .difference => a and !b,
            .xor => a != b,
        };
    }
    const visited = try allocator.alloc(bool, g.half_edges.items.len);
    @memset(visited, false);
    // Winding propagation is complete. Reuse its queue for each boundary walk.
    const contour = &queue;
    var result = Path.init(result_allocator);
    errdefer result.deinit();
    for (0..g.half_edges.items.len) |i| {
        if (visited[i] or !boundary(g, faces.items, i)) continue;
        contour.clearRetainingCapacity();
        var index = i;
        while (true) {
            if (visited[index]) return error.GeometryFailed;
            visited[index] = true;
            try contour.append(allocator, index);
            index = g.half_edges.items[index].next;
            var steps: usize = 0;
            while (!boundary(g, faces.items, index)) {
                index = g.half_edges.items[index ^ 1].next;
                steps += 1;
                if (steps > g.half_edges.items.len) return error.GeometryFailed;
            }
            if (index == i) break;
        }
        const length = contour.items.len;
        var start: usize = 0;
        while (start < length and continued(g, contour.items[(if (start == 0) length else start) - 1], contour.items[start])) start += 1;
        const begin = result.segments.items.len;
        var area: f64 = 0;
        var j: usize = 0;
        while (j < length) {
            const first = contour.items[(start + j) % length];
            var last = first;
            j += 1;
            while (j < length and continued(g, last, contour.items[(start + j) % length])) : (j += 1) last = contour.items[(start + j) % length];
            const half = &g.half_edges.items[first];
            const edge = &g.edges.items[half.edge];
            const values = if (first == last) half.cubic.* else graph.snappedPart(&g.sources[edge.curve].cubic, !edge.straight, times(g, first)[0], times(g, last)[1], g.vertices.items[half.from].point, g.vertices.items[g.half_edges.items[last].to].point);
            if (result.segments.items.len == begin) try result.moveTo(values.p0);
            if (edge.straight) {
                // CLOSE carries the exact final straight endpoint itself.
                if (j < length) try result.lineTo(values.p3);
            } else try result.cubicTo(values.p1, values.p2, values.p3);
            area += curves.getArea(&values);
        }
        try result.close();
        if (area == 0) result.segments.items.len = begin;
    }
    return result;
}

fn filled(winding: i32, rule: api.FillRule) bool {
    return switch (rule) {
        .nonzero => winding != 0,
        .evenodd => winding & 1 != 0,
        .positive => winding > 0,
        .negative => winding < 0,
    };
}
fn boundary(g: *const graph.Graph, faces: []const Face, index: usize) bool {
    return faces[g.half_edges.items[index].face].inside and !faces[g.half_edges.items[index ^ 1].face].inside;
}
fn times(g: *const graph.Graph, index: usize) [2]f64 {
    const edge = &g.edges.items[g.half_edges.items[index].edge];
    return if (index & 1 != 0) .{ edge.time2, edge.time1 } else .{ edge.time1, edge.time2 };
}
fn continued(g: *const graph.Graph, first: usize, second: usize) bool {
    return g.edges.items[g.half_edges.items[first].edge].curve == g.edges.items[g.half_edges.items[second].edge].curve and times(g, first)[1] == times(g, second)[0];
}
fn rayWinding(p: Point, v: *const geometry.Cubic) i32 {
    var winding: i32 = 0;
    const bounds = v.controlBounds();
    if (p.y < bounds.min.y or p.y > bounds.max.y or p.x >= bounds.max.x) return 0;
    const mono = curves.yMonotoneParts(v);
    for (mono.items[0..mono.len]) |*curve| {
        const y0 = curve.p0.y;
        const y3 = curve.p3.y;
        const direction: i32 = if (y0 < y3) 1 else if (y0 > y3) -1 else 0;
        if (direction == 0 or p.y < @min(y0, y3) or p.y >= @max(y0, y3)) continue;
        var roots: [3]f64 = undefined;
        const count = curves.solveCubic(curve, 1, p.y, &roots, 0, 1);
        const x = if (count > 0) curves.getPoint(curve, roots[0]).x else if (@abs(p.y - y0) < @abs(p.y - y3)) curve.p0.x else curve.p3.x;
        if (x > p.x) winding += direction;
    }
    return winding;
}
