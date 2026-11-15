//! Colors a scalar field given on a triangle mesh with color stops. The field
//! is linear on each triangle and the colors are linear between stops, so the
//! color is linear in position wherever the field stays between two adjacent
//! stop levels. Each triangle is cut along the isolines of the levels it
//! spans; every piece then has the vertex colors that a Gouraud mesh shading
//! interpolates exactly. Values beyond the first or last level keep its color.
//!
//! A cut point on an edge is computed from the edge's endpoints in index
//! order and shared by both triangles on that edge, so the pieces meet
//! without gaps. Pieces transparent at all three corners paint nothing and
//! are left out.
const std = @import("std");
const g = @import("geometry.zig");
const style = @import("style.zig");
const Color = style.Color;
const Stops = style.Gradient.Stops;

pub const Error = error{ InvalidMesh, InvalidStyle, InvalidColor, GeometryWorkLimit, OutOfMemory };

/// A corner of the colored triangles.
pub const Vertex = struct { point: g.Point, color: Color };

/// Arrays owned by the allocator given to `colorMesh`.
pub const Colored = struct {
    vertices: []Vertex,
    triangles: [][3]u32,

    pub fn deinit(self: Colored, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.triangles);
    }
};

/// At most `max_triangles` triangles result; more report GeometryWorkLimit.
pub fn colorMesh(allocator: std.mem.Allocator, points: []const g.Point, values: []const f64, triangles: []const [3]u32, stops: Stops, max_triangles: usize) Error!Colored {
    try stops.validate();
    if (points.len != values.len or points.len > std.math.maxInt(u32)) return error.InvalidMesh;
    for (points, values) |point, value| if (!point.isFinite() or !std.math.isFinite(value)) return error.InvalidMesh;
    for (triangles) |triangle| for (triangle) |index| if (index >= points.len) return error.InvalidMesh;

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(allocator);
    var pieces: std.ArrayList([3]u32) = .empty;
    errdefer pieces.deinit(allocator);
    try vertices.ensureTotalCapacity(allocator, points.len);
    for (points, values) |point, value| vertices.appendAssumeCapacity(vertex(point, stops.at(value)));
    var cuts: std.AutoHashMapUnmanaged(Cut, u32) = .empty;
    defer cuts.deinit(allocator);

    for (triangles) |triangle| {
        const low = @min(values[triangle[0]], values[triangle[1]], values[triangle[2]]);
        const high = @max(values[triangle[0]], values[triangle[1]], values[triangle[2]]);
        const first = levelAbove(stops.levels, low);
        const last = levelBelow(stops.levels, high);
        if (first >= last) {
            if (!paints(vertices.items, triangle)) continue;
            if (pieces.items.len == max_triangles) return error.GeometryWorkLimit;
            try pieces.append(allocator, triangle);
            continue;
        }
        // Boundary ring: each corner, then the cut points on its outgoing edge
        // in order along the edge. Spanned levels are first..last-1.
        var ring: std.ArrayList(Node) = .empty;
        defer ring.deinit(allocator);
        for (0..3) |side| {
            const from = triangle[side];
            const to = triangle[(side + 1) % 3];
            try ring.append(allocator, .{ .vertex = from, .value = values[from] });
            const rising = values[from] < values[to];
            const lower = levelAbove(stops.levels, @min(values[from], values[to]));
            const upper = levelBelow(stops.levels, @max(values[from], values[to]));
            if (lower >= upper) continue;
            for (0..upper - lower) |step| {
                const level: u32 = @intCast(if (rising) lower + step else upper - 1 - step);
                const key: Cut = .{ .low = @min(from, to), .high = @max(from, to), .level = level };
                const entry = try cuts.getOrPut(allocator, key);
                if (!entry.found_existing) {
                    const fraction = (stops.levels[level] - values[key.low]) / (values[key.high] - values[key.low]);
                    const point = points[key.low].lerp(points[key.high], fraction);
                    entry.value_ptr.* = @intCast(vertices.items.len);
                    try vertices.append(allocator, vertex(point, stops.colors[level]));
                }
                try ring.append(allocator, .{ .vertex = entry.value_ptr.*, .value = stops.levels[level] });
            }
        }
        // One convex piece per band between consecutive levels, from the
        // ring nodes with values inside the band, fanned from its first node.
        var polygon: std.ArrayList(u32) = .empty;
        defer polygon.deinit(allocator);
        for (first..last + 1) |band| {
            const floor = if (band == first) -std.math.inf(f64) else stops.levels[band - 1];
            const ceiling = if (band == last) std.math.inf(f64) else stops.levels[band];
            polygon.clearRetainingCapacity();
            for (ring.items) |node| {
                if (node.value >= floor and node.value <= ceiling) try polygon.append(allocator, node.vertex);
            }
            if (polygon.items.len < 3) continue;
            for (1..polygon.items.len - 1) |corner| {
                const piece = [3]u32{ polygon.items[0], polygon.items[corner], polygon.items[corner + 1] };
                if (!paints(vertices.items, piece)) continue;
                if (pieces.items.len == max_triangles) return error.GeometryWorkLimit;
                try pieces.append(allocator, piece);
            }
        }
    }
    const vertex_slice = try vertices.toOwnedSlice(allocator);
    errdefer allocator.free(vertex_slice);
    return .{ .vertices = vertex_slice, .triangles = try pieces.toOwnedSlice(allocator) };
}

const Cut = struct { low: u32, high: u32, level: u32 };
const Node = struct { vertex: u32, value: f64 };

/// A piece transparent at all three corners is transparent throughout.
fn paints(vertices: []const Vertex, piece: [3]u32) bool {
    for (piece) |index| if (vertices[index].color.a > 0) return true;
    return false;
}

/// Index of the first level greater than `value`.
fn levelAbove(levels: []const f64, value: f64) usize {
    return std.sort.partitionPoint(f64, levels, value, struct {
        fn below(target: f64, level: f64) bool {
            return level <= target;
        }
    }.below);
}

/// One past the index of the last level less than `value`.
fn levelBelow(levels: []const f64, value: f64) usize {
    return std.sort.partitionPoint(f64, levels, value, struct {
        fn below(target: f64, level: f64) bool {
            return level < target;
        }
    }.below);
}

fn vertex(point: g.Point, color: Color) Vertex {
    return .{ .point = point, .color = color };
}

const t = std.testing;

fn vector(value: Vertex) @Vector(4, f64) {
    return .{ value.color.r, value.color.g, value.color.b, value.color.a };
}

/// Color of the mesh at `point` by linear interpolation in the piece that
/// contains it, or null outside every piece.
fn shade(colored: Colored, point: g.Point) ?@Vector(4, f64) {
    for (colored.triangles) |piece| {
        const a = colored.vertices[piece[0]].point;
        const b = colored.vertices[piece[1]].point;
        const c = colored.vertices[piece[2]].point;
        const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (area == 0) continue;
        const wb = ((point.x - a.x) * (c.y - a.y) - (point.y - a.y) * (c.x - a.x)) / area;
        const wc = ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)) / area;
        const wa = 1 - wb - wc;
        if (wa < -1e-12 or wb < -1e-12 or wc < -1e-12) continue;
        const corners = [3]@Vector(4, f64){ vector(colored.vertices[piece[0]]), vector(colored.vertices[piece[1]]), vector(colored.vertices[piece[2]]) };
        return corners[0] * @as(@Vector(4, f64), @splat(wa)) + corners[1] * @as(@Vector(4, f64), @splat(wb)) + corners[2] * @as(@Vector(4, f64), @splat(wc));
    }
    return null;
}

test "pieces reproduce the stop colors of the interpolated field" {
    const points = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const values = [_]f64{ -0.4, 1.3, 0.9, 0.2 };
    const triangles = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    const stops: Stops = .{
        .levels = &.{ 0, 0.5, 1 },
        .colors = &.{ .{ .r = 0.1, .g = 0.2, .b = 0.3 }, .{ .r = 0.9, .g = 0.1, .b = 0.5, .a = 0.5 }, .{ .r = 0.4, .g = 1, .b = 0 } },
    };
    const colored = try colorMesh(t.allocator, &points, &values, &triangles, stops, 100);
    defer colored.deinit(t.allocator);
    for (0..21) |i| for (0..21) |j| {
        const point: g.Point = .{ .x = @as(f64, @floatFromInt(i)) / 2, .y = @as(f64, @floatFromInt(j)) / 2 };
        // The field interpolated over the source triangle holding the point.
        const lower = point.y <= point.x;
        const source = if (lower) triangles[0] else triangles[1];
        const a = points[source[0]];
        const b = points[source[1]];
        const c = points[source[2]];
        const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        const wb = ((point.x - a.x) * (c.y - a.y) - (point.y - a.y) * (c.x - a.x)) / area;
        const wc = ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)) / area;
        const value = values[source[0]] * (1 - wb - wc) + values[source[1]] * wb + values[source[2]] * wc;
        const expected = stops.at(value);
        const actual = shade(colored, point).?;
        try t.expect(@reduce(.Max, @abs(actual - @Vector(4, f64){ expected.r, expected.g, expected.b, expected.a })) < 1e-12);
    };
}

test "both triangles on an edge share its cut points and the budget bounds the pieces" {
    const points = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    const values = [_]f64{ 0, 3, 3, 0 };
    const triangles = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    const stops: Stops = .{ .levels = &.{ 1, 2 }, .colors = &.{ .black, .{ .r = 1 } } };
    const colored = try colorMesh(t.allocator, &points, &values, &triangles, stops, 100);
    defer colored.deinit(t.allocator);
    // Two cuts on each of the three edges crossing both levels: bottom,
    // diagonal (shared) and top.
    try t.expectEqual(@as(usize, 4 + 6), colored.vertices.len);
    try t.expectError(error.GeometryWorkLimit, colorMesh(t.allocator, &points, &values, &triangles, stops, 3));
    try t.expectError(error.InvalidStyle, colorMesh(t.allocator, &points, &values, &triangles, .{ .levels = &.{ 2, 1 }, .colors = &.{ .black, .black } }, 100));
    try t.expectError(error.InvalidMesh, colorMesh(t.allocator, &points, &values, &.{.{ 0, 1, 4 }}, stops, 100));
}

test "transparent pieces are left out" {
    const points = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    // A glow: transparent below level 1, then fading in.
    const stops: Stops = .{ .levels = &.{ 1, 2 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 } } };
    const dark = try colorMesh(t.allocator, &points, &.{ 0, 0.5, 0.9, 0 }, &.{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }, stops, 100);
    defer dark.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), dark.triangles.len);
    // Only the band above level 1 of the first triangle paints.
    const lit = try colorMesh(t.allocator, &points, &.{ 0, 3, 0.5, 0 }, &.{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }, stops, 100);
    defer lit.deinit(t.allocator);
    try t.expect(lit.triangles.len > 0);
    for (lit.triangles) |piece| try t.expect(paints(lit.vertices, piece));
}

test "coloring rolls back every allocation failure" {
    const points = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    const values = [_]f64{ 0, 3, 3, 0 };
    const triangles = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const colored = try colorMesh(allocator, &points, &values, &triangles, .{ .levels = &.{ 1, 2 }, .colors = &.{ .black, .{ .r = 1 } } }, 100);
            colored.deinit(allocator);
        }
    }.run, .{});
}
