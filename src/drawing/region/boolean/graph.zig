// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see LICENSE.
const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const curves = @import("curve.zig");
const intersection = @import("intersections.zig");
const Point = types.Point;
const Cubic = geometry.Cubic;
const Allocator = types.Allocator;
const samples = @import("graph/samples.zig");
const snapping = @import("graph/snapping.zig");
const short_edges = @import("graph/short_edges.zig");
const edges = @import("graph/edges.zig");
const fans = @import("graph/fans.zig");
pub const none = std.math.maxInt(usize);

pub const Cut = struct { time: f64, sample: usize };
const Sample = struct { point: Point, parent: usize, vertex: usize = none };
pub const Vertex = struct { point: Point, sample: usize };
pub const Edge = struct {
    cubic: Cubic,
    from: usize,
    to: usize,
    windings: [2]i32,
    curve: usize,
    time1: f64,
    time2: f64,
    straight: bool,
};
pub const HalfEdge = struct {
    edge: usize,
    cubic: *const Cubic,
    from: usize,
    to: usize,
    next: usize = 0,
    face: usize = none,
};

/// Arrangement stored in the caller's arena; sources stay borrowed through tracing.
/// Completed edges and vertices do not borrow the construction workspace.
pub const Graph = struct {
    sources: []const types.Source,
    vertices: std.ArrayList(Vertex) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    half_edges: std.ArrayList(HalfEdge) = .empty,

    pub fn init(allocator: Allocator, scratch: Allocator, sources: []const types.Source, candidates: []const std.ArrayList(usize), intersections: []const intersection.Event, epsilon: f64) !Graph {
        var result: Graph = .{ .sources = sources };
        var builder: Builder = .{ .graph = &result, .allocator = scratch, .storage = allocator, .epsilon = epsilon, .cuts = try scratch.alloc(std.ArrayList(Cut), sources.len) };
        try builder.build(candidates, intersections);
        return result;
    }
};

/// Private construction state, owned by the caller's short-lived workspace.
pub const Builder = struct {
    graph: *Graph,
    allocator: Allocator,
    storage: Allocator,
    epsilon: f64,
    cuts: []std.ArrayList(Cut),
    samples: std.ArrayList(Sample) = .empty,

    fn build(self: *Builder, candidates: []const std.ArrayList(usize), intersections: []const intersection.Event) !void {
        try samples.createSamples(self, intersections);
        try samples.createVertices(self);
        const marks = try self.allocator.alloc(usize, self.graph.vertices.items.len);
        @memset(marks, none);
        try snapping.snapVertices(self, candidates, marks);
        const edge_capacity = try short_edges.mergeShortEdges(self, marks);
        try edges.createEdges(self, edge_capacity);
        try fans.linkHalfEdges(self);
    }

    pub fn root(self: *Builder, index: usize) usize {
        var i = index;
        while (self.samples.items[i].parent != i) {
            const parent = self.samples.items[i].parent;
            self.samples.items[i].parent = self.samples.items[parent].parent;
            i = self.samples.items[i].parent;
        }
        return i;
    }
    pub fn vertexIndex(self: *Builder, index: usize) usize {
        return self.samples.items[index].vertex;
    }
};

pub fn snappedPart(v: *const Cubic, handles: bool, first: f64, last: f64, a: Point, b: Point) Cubic {
    if (!handles) return .{ .p0 = a, .p1 = a, .p2 = b, .p3 = b };
    var part = curves.getPart(v, first, last);
    const da = a.sub(part.p0);
    const db = b.sub(part.p3);
    part.p0 = part.p0.add(da);
    part.p1 = part.p1.add(da);
    part.p2 = part.p2.add(db);
    part.p3 = part.p3.add(db);
    return part;
}

fn checkConstructionLifetime(allocator: Allocator) !void {
    const t = std.testing;
    const contours = [_][4]Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } },
        .{ .{ .x = 2, .y = -1 }, .{ .x = 6, .y = -1 }, .{ .x = 6, .y = 3 }, .{ .x = 2, .y = 3 } },
    };
    var sources: [12]types.Source = undefined;
    for (contours, 0..) |points, contour| for (points, 0..) |point, i| {
        const end = points[(i + 1) % 4];
        sources[4 * contour + i] = .{
            .cubic = .{ .p0 = point, .p1 = point, .p2 = end, .p3 = end },
            .next = 4 * contour + (i + 1) % 4,
            .contour = contour,
            .operand = if (contour < 2) 0 else 1,
        };
    };
    var result = traced: {
        var storage = std.heap.ArenaAllocator.init(allocator);
        defer storage.deinit();
        var g = built: {
            var workspace = std.heap.ArenaAllocator.init(allocator);
            defer workspace.deinit();
            const scratch = workspace.allocator();
            const candidates = try @import("collisions.zig").curveCandidates(scratch, &sources, 2e-8);
            const events = try intersection.collect(scratch, scratch, &sources, candidates, 1e-8);
            break :built try Graph.init(storage.allocator(), scratch, &sources, candidates, events.items, 1e-8);
        };
        try t.expectEqual(@as(usize, 10), g.vertices.items.len);
        try t.expectEqual(@as(usize, 12), g.edges.items.len);
        var incoming: [24]usize = @splat(0);
        for (g.half_edges.items) |half| {
            try t.expect(half.cubic.isFinite());
            try t.expectEqual(g.vertices.items[half.from].point, half.cubic.p0);
            try t.expectEqual(g.vertices.items[half.to].point, half.cubic.p3);
            try t.expect(half.next < g.half_edges.items.len);
            try t.expectEqual(half.to, g.half_edges.items[half.next].from);
            incoming[half.next] += 1;
        }
        for (incoming) |count| try t.expectEqual(@as(usize, 1), count);
        // Repeated contours retain their winding even when sharing cuts.
        for (g.edges.items) |edge| try t.expectEqual(if (edge.curve < 8) @as(i32, 2) else 0, edge.windings[0]);
        break :traced try @import("regions.zig").trace(&g, allocator, .unite, .nonzero);
    };
    defer result.deinit();
    try t.expectEqual(@as(f64, 26), result.signedArea());
}

test "graph and output outlive construction workspaces with duplicate intersections" {
    try checkConstructionLifetime(std.testing.allocator);
    // Remapping can change the number of allocations across failure-injection
    // runs. Force growth to allocate so every failure point is exercised.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), checkConstructionLifetime, .{});
}

test {
    _ = @import("graph/snapping.zig");
    _ = @import("graph/edges.zig");
}
