// Paper.js v0.16.0 Path.cubicCurveTo, Path.closePath, Path.reduce and
// Curve.remove, adapted to borrowed Huak paths and owned binary64 sources.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
const std = @import("std");
const Path = @import("../../path/Path.zig");
const api = @import("../root.zig");
const geometry = @import("../../geometry.zig");
const types = @import("types.zig");
const curve = @import("curve.zig");
const numeric = @import("numeric.zig");
const Allocator = types.Allocator;
const Point = types.Point;

const Options = api.Options;

pub const Mapping = struct {
    origin: Point = .zero,
    scale: f64,

    pub fn apply(self: Mapping, point: Point) !Point {
        const result: Point = .{
            .x = (point.x - self.origin.x) / self.scale,
            .y = (point.y - self.origin.y) / self.scale,
        };
        if (!result.isFinite()) return error.PrecisionRange;
        return result;
    }

    pub fn restore(self: Mapping, point: Point) !Point {
        const result: Point = .{
            .x = point.x * self.scale + self.origin.x,
            .y = point.y * self.scale + self.origin.y,
        };
        if (!result.isFinite()) return error.PrecisionRange;
        return result;
    }
};

pub const Input = struct {
    sources: []types.Source,
    mapping: Mapping,
    pub fn deinit(self: *Input, allocator: Allocator) void {
        allocator.free(self.sources);
        self.* = undefined;
    }
};

const Node = struct { point: Point, incoming: Point = .zero, outgoing: Point = .zero };
fn noHandles(first: Node, second: Node) bool {
    return numeric.isZero(first.outgoing.x) and numeric.isZero(first.outgoing.y) and
        numeric.isZero(second.incoming.x) and numeric.isZero(second.incoming.y);
}
fn values(first: Node, second: Node) geometry.Cubic {
    return .{
        .p0 = first.point,
        .p1 = .{ .x = first.point.x + first.outgoing.x, .y = first.point.y + first.outgoing.y },
        .p2 = .{ .x = second.point.x + second.incoming.x, .y = second.point.y + second.incoming.y },
        .p3 = second.point,
    };
}

fn reduceNodes(nodes: *std.ArrayList(Node)) void {
    // closePath's join(this, 0) transfers the incoming handle when the final
    // endpoint exactly repeats the first. It does not snap nearby points.
    if (nodes.items.len > 1 and nodes.items[0].point.eql(nodes.items[nodes.items.len - 1].point)) {
        nodes.items[0].incoming = nodes.items[nodes.items.len - 1].incoming;
        _ = nodes.pop();
    }
    // Path.reduce visits the live curve array backwards. Curve.remove deletes
    // its endpoint node and transfers that node's outgoing handle to its start.
    var index = nodes.items.len;
    while (index > 0) {
        index -= 1;
        const next = (index + 1) % nodes.items.len;
        const first = nodes.items[index];
        const second = nodes.items[next];
        if (!noHandles(first, second)) continue;
        const delta = second.point.sub(first.point);
        const short = @sqrt(delta.x * delta.x + delta.y * delta.y) <= 1e-7;
        const after = (next + 1) % nodes.items.len;
        const first_values = values(first, second);
        const second_values = values(second, nodes.items[after]);
        if (short or (curve.isStraight(&first_values) and curve.isStraight(&second_values) and curve.isCollinear(delta.x, delta.y, nodes.items[after].point.x - second.point.x, nodes.items[after].point.y - second.point.y))) {
            nodes.items[index].outgoing = second.outgoing;
            _ = nodes.orderedRemove(next);
        }
    }
}

fn finishContour(nodes: *std.ArrayList(Node), sources: *std.ArrayList(types.Source), contour: *usize, operand: u1) void {
    reduceNodes(nodes);
    if (nodes.items.len != 0) {
        const offset = sources.items.len;
        for (nodes.items, 0..) |node, i| sources.appendAssumeCapacity(.{
            .cubic = values(node, nodes.items[(i + 1) % nodes.items.len]),
            .next = offset + (i + 1) % nodes.items.len,
            .contour = contour.*,
            .operand = operand,
        });
        contour.* += 1;
    }
    nodes.clearRetainingCapacity();
}

// Both callers reserve the contour's node count before converting its segments.
fn appendNode(nodes: *std.ArrayList(Node), segment: Path.Segment, mapping: Mapping) !void {
    switch (segment) {
        .move => |point| nodes.appendAssumeCapacity(.{ .point = try mapping.apply(point) }),
        .line => |point| nodes.appendAssumeCapacity(.{ .point = try mapping.apply(point) }),
        .cubic => |controls| {
            const first = try mapping.apply(controls.c1);
            const second = try mapping.apply(controls.c2);
            const end = try mapping.apply(controls.end);
            const start = &nodes.items[nodes.items.len - 1];
            start.outgoing = first.sub(start.point);
            nodes.appendAssumeCapacity(.{ .point = end, .incoming = second.sub(end) });
        },
        .close => unreachable,
    }
}

fn validate(input: Path, bounds: *?geometry.BBox) !struct { vertices: usize, max_nodes: usize } {
    var active = false;
    var vertices: usize = 0;
    var nodes: usize = 0;
    var max_nodes: usize = 0;
    for (input.segments.items) |segment| {
        const points: []const Point = switch (segment) {
            .move => |*p| value: {
                if (active) return error.OpenPath;
                active = true;
                nodes = 1;
                break :value @as([*]const Point, @ptrCast(p))[0..1];
            },
            .line => |*p| value: {
                if (!active) return error.InvalidPath;
                nodes += 1;
                break :value @as([*]const Point, @ptrCast(p))[0..1];
            },
            .cubic => |*c| value: {
                if (!active) return error.InvalidPath;
                nodes += 1;
                break :value &.{ c.c1, c.c2, c.end };
            },
            .close => value: {
                if (!active) return error.InvalidPath;
                active = false;
                max_nodes = @max(max_nodes, nodes);
                break :value &.{};
            },
        };
        vertices = std.math.add(usize, vertices, points.len) catch return error.GeometryWorkLimit;
        for (points) |point| {
            if (!point.isFinite()) return error.NonFinite;
            bounds.* = if (bounds.*) |box| box.include(point) else .fromPoint(point);
        }
    }
    if (active) return error.OpenPath;
    return .{ .vertices = vertices, .max_nodes = max_nodes };
}

/// Borrowed inputs are validated, mapped into request-tolerance units and
/// reduced with upstream rules. No input coordinate or segment is modified.
pub fn init(allocator: Allocator, scratch: Allocator, a: Path, b: Path, options: Options) !Input {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.tolerance * 0.25 == 0) return error.PrecisionRange;
    if (options.max_segments == 0 or options.max_vertices == 0 or options.max_depth > 64) return error.GeometryWorkLimit;
    var bounds: ?geometry.BBox = null;
    const first = try validate(a, &bounds);
    const second = try validate(b, &bounds);
    const first_segments = a.segmentCount();
    const second_segments = b.segmentCount();
    if (first_segments > options.max_segments or second_segments > options.max_segments - first_segments) return error.GeometryWorkLimit;
    if (first.vertices > options.max_vertices or second.vertices > options.max_vertices - first.vertices) return error.GeometryWorkLimit;
    var mapping: Mapping = .{ .scale = std.math.ldexp(@as(f64, 1), std.math.frexp(options.tolerance).exponent - 1) };
    if (bounds) |box| {
        const magnitude = @max(@abs(box.min.x), @abs(box.max.x), @abs(box.min.y), @abs(box.max.y));
        if (magnitude * std.math.floatEps(f64) > options.tolerance * 0.25) return error.PrecisionRange;
        mapping.origin = box.min.scale(0.5).add(box.max.scale(0.5));
    }
    var sources: std.ArrayList(types.Source) = .empty;
    errdefer sources.deinit(allocator);
    try sources.ensureTotalCapacityPrecise(allocator, first_segments + second_segments);
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(scratch);
    try nodes.ensureTotalCapacityPrecise(scratch, @max(first.max_nodes, second.max_nodes));
    var contour: usize = 0;
    for ([_]*const Path{ &a, &b }, 0..) |input, operand| for (input.segments.items) |segment| {
        if (segment == .close) {
            finishContour(&nodes, &sources, &contour, @intCast(operand));
        } else try appendNode(&nodes, segment, mapping);
    };
    return .{ .sources = try sources.toOwnedSlice(allocator), .mapping = mapping };
}

/// Paper Path.reduce({ simplify: true }) in the current coordinate space.
/// Reduces an owned output in its existing storage. Each closed contour is
/// read before it is rewritten, and reduction never increases its segment count.
pub fn reduce(allocator: Allocator, output: *Path) !void {
    const segments = output.segments.items;
    output.segments.items.len = 0;
    output.current = null;
    output.start = null;
    output.open = false;
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(allocator);
    var start: usize = 0;
    for (segments, 0..) |segment, end| {
        if (segment != .close) continue;
        const contour = segments[start..end];
        try nodes.ensureTotalCapacityPrecise(allocator, contour.len);
        for (contour) |part| try appendNode(&nodes, part, .{ .scale = 1 });
        start = end + 1;
        reduceNodes(&nodes);
        if (nodes.items.len != 0) {
            try output.moveTo(nodes.items[0].point);
            for (nodes.items, 0..) |first, index| {
                const second = nodes.items[(index + 1) % nodes.items.len];
                const v = values(first, second);
                if (v.p0.x != v.p1.x or v.p0.y != v.p1.y or v.p2.x != v.p3.x or v.p2.y != v.p3.y) {
                    try output.cubicTo(v.p1, v.p2, second.point);
                } else if (index + 1 != nodes.items.len) try output.lineTo(second.point);
            }
            try output.close();
        }
        nodes.clearRetainingCapacity();
    }
}

test "input preparation preserves closed links, cubic handles and borrowed controls" {
    const t = std.testing;
    var a = Path.init(t.allocator);
    defer a.deinit();
    try a.moveTo(.{ .x = 0, .y = 0 });
    try a.cubicTo(.{ .x = 3, .y = 4 }, .{ .x = -3, .y = 4 }, .{ .x = 0, .y = 0 });
    try a.close();
    var b = try Path.circle(t.allocator, .{ .x = 20, .y = 20 }, 5);
    defer b.deinit();
    var input = prepared: {
        var workspace = std.heap.ArenaAllocator.init(t.allocator);
        defer workspace.deinit();
        break :prepared try init(t.allocator, workspace.allocator(), a, b, .{});
    };
    defer input.deinit(t.allocator);
    try t.expectEqual(@as(usize, 5), input.sources.len);
    try t.expectEqual(@as(usize, 0), input.sources[0].next);
    try t.expectEqual(@as(usize, 0), input.sources[0].contour);
    try t.expectEqual(@as(usize, 1), input.sources[1].contour);
    try t.expectEqual(@as(u1, 1), input.sources[1].operand);
    for (input.sources) |source| {
        const next = input.sources[source.next];
        try t.expectEqual(source.contour, next.contour);
        try t.expectEqual(source.operand, next.operand);
        try t.expectEqual(@as(u64, @bitCast(source.cubic.p3.x)), @as(u64, @bitCast(next.cubic.p0.x)));
        try t.expectEqual(@as(u64, @bitCast(source.cubic.p3.y)), @as(u64, @bitCast(next.cubic.p0.y)));
    }
    const v = input.sources[0].cubic;
    try t.expectEqual(Point{ .x = 3, .y = 4 }, try input.mapping.restore(v.p1));
    try t.expectEqual(Point{ .x = 3, .y = 4 }, a.segments.items[1].cubic.c1);
}

test "input preparation preserves original invalid input and resource diagnostics" {
    const t = std.testing;
    var a = Path.init(t.allocator);
    defer a.deinit();
    const empty = Path.init(t.allocator);
    try a.moveTo(.zero);
    try a.lineTo(.{ .x = 10, .y = 0 });
    try t.expectError(error.OpenPath, init(t.allocator, t.allocator, a, empty, .{}));
    try a.close();
    try t.expectError(error.InvalidTolerance, init(t.allocator, t.allocator, a, empty, .{ .tolerance = 0 }));
    try t.expectError(error.GeometryWorkLimit, init(t.allocator, t.allocator, a, empty, .{ .max_vertices = 1 }));
    var input = try init(t.allocator, t.allocator, a, empty, .{});
    defer input.deinit(t.allocator);
    try t.expectEqual(@as(usize, 0), input.sources.len);
}

test "input preparation preserves zero and releases every partial allocation" {
    const t = std.testing;
    var a = try Path.circle(t.allocator, .zero, 1e-24);
    defer a.deinit();
    const b = Path.init(t.allocator);
    const Exercise = struct {
        fn run(allocator: Allocator, first: Path, second: Path) !void {
            var prepared = try init(allocator, allocator, first, second, .{ .tolerance = 1e-30 });
            defer prepared.deinit(allocator);
            try t.expectEqual(@as(f64, 0), prepared.sources[0].cubic.p0.y);
            try t.expectEqual(Point.zero, try prepared.mapping.restore(.zero));
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Exercise.run, .{ a, b });
}

test "output reduction merges the six edges of adjacent rectangles and preserves curves" {
    const t = std.testing;
    var joined = Path.init(t.allocator);
    defer joined.deinit();
    try joined.moveTo(.zero);
    for ([_]Point{ .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } }) |point| try joined.lineTo(point);
    try joined.close();
    try t.expectEqual(@as(usize, 6), joined.segmentCount());
    var reduced = try joined.clone(t.allocator);
    defer reduced.deinit();
    try reduce(t.allocator, &reduced);
    try t.expectEqual(@as(usize, 4), reduced.segmentCount());
    try t.expectEqual(@as(usize, 5), reduced.segments.items.len);
    try t.expectEqual(@as(f64, 200), reduced.signedArea());
    try t.expectEqual(@as(usize, 6), joined.segmentCount());

    var loop = Path.init(t.allocator);
    defer loop.deinit();
    try loop.moveTo(.zero);
    try loop.cubicTo(.{ .x = 3, .y = 4 }, .{ .x = -3, .y = 4 }, .zero);
    try loop.close();
    var retained = try loop.clone(t.allocator);
    defer retained.deinit();
    try reduce(t.allocator, &retained);
    try t.expectEqualSlices(Path.Segment, loop.segments.items, retained.segments.items);
}

test "output reduction releases every partial allocation" {
    const t = std.testing;
    var input = try Path.circle(t.allocator, .zero, 10);
    defer input.deinit();
    const Exercise = struct {
        fn run(allocator: Allocator, path: Path) !void {
            var output = try path.clone(allocator);
            defer output.deinit();
            try reduce(allocator, &output);
            try t.expectEqual(@as(usize, 4), output.segmentCount());
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Exercise.run, .{input});
}
