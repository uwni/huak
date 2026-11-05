//! Curve-region Boolean operations; see README.md for source and numerical contracts.
const std = @import("std");
const Path = @import("../../path/Path.zig");
const api = @import("../root.zig");
const geometry = @import("../../geometry.zig");
const input = @import("path.zig");
const numeric = @import("numeric.zig");
const collision = @import("collisions.zig");
const intersections = @import("intersections.zig");
const graph = @import("graph.zig");
const regions = @import("regions.zig");

pub fn combine(allocator: std.mem.Allocator, a: Path, b: Path, operation: api.Operation, options: api.Options) !Path {
    var mapping: input.Mapping = undefined;
    var result = rendered: {
        var storage = std.heap.ArenaAllocator.init(allocator);
        defer storage.deinit();
        const permanent = storage.allocator();
        var arrangement = built: {
            var workspace = std.heap.ArenaAllocator.init(allocator);
            defer workspace.deinit();
            const scratch = workspace.allocator();
            const source = try input.init(permanent, allocator, a, b, options);
            mapping = source.mapping;
            var bounds = geometry.BBox.fromPoint(.zero);
            for (source.sources) |*curve| bounds = bounds.unite(curve.cubic.bounds());
            const magnitude = @max(@abs(bounds.min.x), @abs(bounds.min.y), @abs(bounds.max.x), @abs(bounds.max.y));
            const diagonal = bounds.max.sub(bounds.min);
            // The graph merges spans shorter than 4*epsilon. Reserve half of the
            // spatial budget for each boundary, so tolerance-sized gaps survive.
            const epsilon = numeric.getEpsilon(magnitude, @min(@sqrt(diagonal.dot(diagonal)) * numeric.GEOMETRIC_EPSILON, options.tolerance / mapping.scale / 8));
            const candidates = try collision.curveCandidates(scratch, source.sources, 2 * epsilon);
            var events = try intersections.collect(allocator, scratch, source.sources, candidates, epsilon);
            defer events.deinit(allocator);
            break :built try graph.Graph.init(permanent, scratch, source.sources, candidates, events.items, epsilon);
        };
        break :rendered try regions.trace(&arrangement, allocator, operation, options.fill_rule);
    };
    errdefer result.deinit();
    try input.reduce(allocator, &result);
    var vertices: usize = 0;
    for (result.segments.items) |*segment| switch (segment.*) {
        .move => |point| {
            segment.* = .{ .move = try mapping.restore(point) };
            vertices += 1;
        },
        .line => |point| {
            segment.* = .{ .line = try mapping.restore(point) };
            vertices += 1;
        },
        .cubic => |curve| {
            segment.* = .{ .cubic = .{ .c1 = try mapping.restore(curve.c1), .c2 = try mapping.restore(curve.c2), .end = try mapping.restore(curve.end) } };
            vertices += 3;
        },
        .close => {},
    };
    if (vertices > options.max_vertices) return error.GeometryWorkLimit;
    if (result.start) |point| result.start = try mapping.restore(point);
    if (result.current) |point| result.current = try mapping.restore(point);
    return result;
}

test "native region smoke" {
    const t = std.testing;
    var a = Path.init(t.allocator);
    defer a.deinit();
    try a.moveTo(.zero);
    try a.lineTo(.{ .x = 10, .y = 0 });
    try a.lineTo(.{ .x = 10, .y = 10 });
    try a.lineTo(.{ .x = 0, .y = 10 });
    try a.close();
    var result = try combine(t.allocator, a, Path.init(t.allocator), .unite, .{});
    defer result.deinit();
    try t.expectApproxEqAbs(@as(f64, 100), result.signedArea(), 1e-9);
}
