//! Tests of patch triangulation: a sphere's patches near the contour, nodes shared with finer neighbours, flat patches and limits, allocation failure.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const t = std.testing;
const patches = @import("../patches.zig");
const Builder = @import("Builder.zig");

/// Bézier coefficients of the bicubic through `samples` at u, v in
/// {0, 1/3, 2/3, 1}, row-major like the coefficients.
fn interpolate(comptime T: type, samples: [16]T) [16]T {
    // Inverse of the cubic Bernstein basis at 0, 1/3, 2/3 and 1.
    const inverse = [4][4]f64{ .{ 1, 0, 0, 0 }, .{ -5.0 / 6.0, 3, -1.5, 1.0 / 3.0 }, .{ 1.0 / 3.0, -1.5, 3, -5.0 / 6.0 }, .{ 0, 0, 0, 1 } };
    var rows: [16]T = undefined;
    for (0..4) |i| for (0..4) |j| {
        var sum = std.mem.zeroes(T);
        for (0..4) |k| sum = add(T, sum, samples[k * 4 + j], inverse[i][k]);
        rows[i * 4 + j] = sum;
    };
    var result: [16]T = undefined;
    for (0..4) |i| for (0..4) |j| {
        var sum = std.mem.zeroes(T);
        for (0..4) |k| sum = add(T, sum, rows[i * 4 + k], inverse[j][k]);
        result[i * 4 + j] = sum;
    };
    return result;
}

fn add(comptime T: type, sum: T, value: T, weight: f64) T {
    return if (T == f64) sum + value * weight else sum.add(value.scale(weight));
}

/// A patch of the front of a sphere of radius 20 seen along z, lit from
/// above: polar angle a in [a0, a1] from the view axis, azimuth b in
/// [b0, b1]. The field is n·l with l = (0, 0.6, 0.8).
fn spherePatch(a0: f64, a1: f64, b0: f64, b1: f64) struct { points: [16]g.Point, values: [16]f64 } {
    var points: [16]g.Point = undefined;
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        const a = a0 + (a1 - a0) * @as(f64, @floatFromInt(i)) / 3;
        const b = b0 + (b1 - b0) * @as(f64, @floatFromInt(j)) / 3;
        const normal = [3]f64{ @sin(a) * @cos(b), @sin(a) * @sin(b), @cos(a) };
        points[i * 4 + j] = .{ .x = 20 * normal[0], .y = 20 * normal[1] };
        values[i * 4 + j] = 0.6 * normal[1] + 0.8 * normal[2];
    };
    return .{ .points = interpolate(g.Point, points), .values = interpolate(f64, values) };
}

/// Linear interpolation of the triangulation at `point`, or null outside it.
fn shade(result: patches.Triangulated, point: g.Point) ?f64 {
    for (result.triangles) |triangle| {
        const plane = Builder.Plane.through(
            .{ .point = result.points[triangle[0]], .value = result.values[triangle[0]] },
            .{ .point = result.points[triangle[1]], .value = result.values[triangle[1]] },
            .{ .point = result.points[triangle[2]], .value = result.values[triangle[2]] },
        ) orelse continue;
        if (plane.contains(point)) return plane.at(point);
    }
    return null;
}

test "triangles of a sphere's patches follow the field near its contour" {
    // Two rings of patches running into the contour at a = pi / 2.
    var points: [8][16]g.Point = undefined;
    var values: [8][16]f64 = undefined;
    for (0..2) |ring| for (0..4) |k| {
        const a0 = std.math.pi / 2.0 - 0.25 * @as(f64, @floatFromInt(2 - ring));
        const b0 = 0.2 + 0.125 * @as(f64, @floatFromInt(k));
        const patch = spherePatch(a0, a0 + 0.25, b0, b0 + 0.125);
        points[ring * 4 + k] = patch.points;
        values[ring * 4 + k] = patch.values;
    };
    // The contour's outline, a circle of radius 20, traced within 0.01.
    const margin = 0.01;
    var outline_segments: [201]Path.Segment = undefined;
    for (&outline_segments, 0..) |*segment, k| {
        const angle = 0.1 + 0.8 * @as(f64, @floatFromInt(k)) / 200;
        const point: g.Point = .{ .x = 20 * @cos(angle), .y = 20 * @sin(angle) };
        segment.* = if (k == 0) .{ .move = point } else .{ .line = point };
    }
    var outline = try patches.Outline.init(t.allocator, &outline_segments, margin);
    defer outline.deinit(t.allocator);
    try t.expect(outline.near(.{ .x = 20 * @cos(0.5) + 0.009, .y = 20 * @sin(0.5) }));
    try t.expect(!outline.near(.{ .x = 20 * @cos(0.5) - 0.02, .y = 20 * @sin(0.5) }));
    const tolerance = 1.0 / 256.0;
    const strict = try patches.triangulate(t.allocator, &points, &values, .{ .tolerance = tolerance, .max_triangles = 100_000 });
    defer strict.deinit(t.allocator);
    const banded = try patches.triangulate(t.allocator, &points, &values, .{ .tolerance = tolerance, .free = &outline, .max_triangles = 100_000 });
    defer banded.deinit(t.allocator);
    // Contour cells split; the band near the outline needs fewer.
    try t.expect(banded.triangles.len > 16 and banded.triangles.len < strict.triangles.len);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for ([_]patches.Triangulated{ strict, banded }, [_]f64{ 0, 2 * margin }) |result, clear| {
        var worst: f64 = 0;
        for (0..2000) |_| {
            const patch = random.uintLessThan(usize, 8);
            const sample = patches.evaluate(&points[patch], &values[patch], random.float(f64), random.float(f64));
            if (20 - @sqrt(sample.point.dot(sample.point)) < clear) continue;
            const value = shade(result, sample.point) orelse continue;
            worst = @max(worst, @abs(value - sample.value));
        }
        try t.expect(worst <= 1.5 * tolerance);
    }
}

test "a coarse patch takes the nodes its finer neighbour puts on their edge" {
    // Two unit squares sharing the edge x = 1. Both fields are 0.02 y^2 there,
    // within the tolerance of linear; the left one adds 4 x (1 - x) y^2, which
    // splits the left square along y.
    var left: [16]g.Point = undefined;
    var right: [16]g.Point = undefined;
    var left_field: [16]f64 = undefined;
    var right_field: [16]f64 = undefined;
    // Bézier coefficients of 4 u (1 - u) and of v^2.
    const across = [4]f64{ 0, 4.0 / 3.0, 4.0 / 3.0, 0 };
    const along = [4]f64{ 0, 0, 1.0 / 3.0, 1 };
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        const v = @as(f64, @floatFromInt(j)) / 3;
        left[i * 4 + j] = .{ .x = u, .y = v };
        right[i * 4 + j] = .{ .x = 1 + u, .y = v };
        left_field[i * 4 + j] = across[i] * along[j] + 0.02 * along[j];
        right_field[i * 4 + j] = 0.02 * along[j];
    };
    const result = try patches.triangulate(t.allocator, &.{ left, right }, &.{ left_field, right_field }, .{ .tolerance = 0.01, .max_triangles = 100_000 });
    defer result.deinit(t.allocator);
    // Edges used once lie on the outline of the union, never along x = 1.
    var uses: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    defer uses.deinit(t.allocator);
    for (result.triangles) |triangle| for (0..3) |k| {
        const a = triangle[k];
        const b = triangle[(k + 1) % 3];
        const entry = try uses.getOrPut(t.allocator, .{ @min(a, b), @max(a, b) });
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    var shared: usize = 0;
    var iterator = uses.iterator();
    while (iterator.next()) |entry| {
        const a = result.points[entry.key_ptr[0]];
        const b = result.points[entry.key_ptr[1]];
        const on_edge = a.x == 1 and b.x == 1;
        if (on_edge) shared += 1;
        if (on_edge and ((a.y > 0 and a.y < 1) or (b.y > 0 and b.y < 1))) try t.expectEqual(@as(u32, 2), entry.value_ptr.*);
    }
    // The left patch split, so the shared edge holds more than one segment.
    try t.expect(shared > 1);
}

test "flat patches with linear fields need two triangles, and limits hold" {
    var patch: [16]g.Point = undefined;
    var field: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        patch[i * 4 + j] = .{ .x = 3 * @as(f64, @floatFromInt(i)), .y = 2 * @as(f64, @floatFromInt(j)) + @as(f64, @floatFromInt(i)) };
        field[i * 4 + j] = @as(f64, @floatFromInt(i)) - 0.5 * @as(f64, @floatFromInt(j));
    };
    const result = try patches.triangulate(t.allocator, &.{patch}, &.{field}, .{ .tolerance = 1e-9, .max_triangles = 100 });
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), result.triangles.len);
    try t.expectEqual(@as(usize, 4), result.points.len);
    const curved = spherePatch(std.math.pi / 2.0 - 0.25, std.math.pi / 2.0, 0, 0.5);
    try t.expectError(error.GeometryWorkLimit, patches.triangulate(t.allocator, &.{curved.points}, &.{curved.values}, .{ .tolerance = 1e-6, .max_triangles = 20 }));
    try t.expectError(error.InvalidPatches, patches.triangulate(t.allocator, &.{patch}, &.{field}, .{ .tolerance = 0, .max_triangles = 100 }));
    var far = patch;
    far[5].x = std.math.inf(f64);
    try t.expectError(error.InvalidPatches, patches.triangulate(t.allocator, &.{far}, &.{field}, .{ .tolerance = 0.1, .max_triangles = 100 }));
}

test "discontinuous field across a shared geometric edge stays free of T-junctions" {
    // Two unit squares sharing the geometric edge x = 1, with a jump in the
    // field across x = 1: left is 1.0 on x = 1 (and nonlinear inside so it
    // splits along y), while right is flat 0.0 everywhere.
    var left: [16]g.Point = undefined;
    var right: [16]g.Point = undefined;
    var left_field: [16]f64 = undefined;
    var right_field: [16]f64 = undefined;
    const across = [4]f64{ 0, 4.0 / 3.0, 4.0 / 3.0, 0 };
    const along = [4]f64{ 0, 0, 1.0 / 3.0, 1 };
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        const v = @as(f64, @floatFromInt(j)) / 3;
        left[i * 4 + j] = .{ .x = u, .y = v };
        right[i * 4 + j] = .{ .x = 1 + u, .y = v };
        left_field[i * 4 + j] = 1.0 + across[i] * along[j];
        right_field[i * 4 + j] = 0.0;
    };
    const result = try patches.triangulate(t.allocator, &.{ left, right }, &.{ left_field, right_field }, .{ .tolerance = 0.01, .max_triangles = 100_000 });
    defer result.deinit(t.allocator);
    // Count geometric edges along x = 1 by bit-exact coordinates.
    const GeoEdge = [4]u64;
    var uses: std.AutoHashMapUnmanaged(GeoEdge, u32) = .empty;
    defer uses.deinit(t.allocator);
    for (result.triangles) |triangle| {
        var on_left = true;
        var on_right = true;
        for (triangle) |idx| {
            const p = result.points[idx];
            if (p.x > 1) on_left = false;
            if (p.x < 1) on_right = false;
        }
        try t.expect(on_left != on_right);
        for (triangle) |idx| {
            if (on_left) {
                try t.expect(result.values[idx] >= 1.0 - 1e-12);
            } else {
                try t.expectEqual(@as(f64, 0.0), result.values[idx]);
            }
        }
        for (0..3) |k| {
            const a = result.points[triangle[k]];
            const b = result.points[triangle[(k + 1) % 3]];
            if (a.x != 1 or b.x != 1) continue;
            const lo = if (a.y <= b.y) a else b;
            const hi = if (a.y <= b.y) b else a;
            const key: GeoEdge = .{ @bitCast(lo.x), @bitCast(lo.y), @bitCast(hi.x), @bitCast(hi.y) };
            const entry = try uses.getOrPut(t.allocator, key);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        }
    }
    try t.expect(uses.count() > 1);
    var it = uses.valueIterator();
    while (it.next()) |count| try t.expectEqual(@as(u32, 2), count.*);
}

test "collapsed point-degenerate edges do not fan flat neighbours" {
    // Two wedge patches whose u = 0 side is collapsed to the origin (0, 0).
    // Patch A has a nonlinear field in v so it splits finely along its
    // collapsed side; Patch B is flat and must remain at 2 triangles.
    var fine: [16]g.Point = undefined;
    var flat: [16]g.Point = undefined;
    var fine_field: [16]f64 = undefined;
    var flat_field: [16]f64 = undefined;
    const along = [4]f64{ 0, 0, 1.0 / 3.0, 1 };
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        const v = @as(f64, @floatFromInt(j)) / 3;
        fine[i * 4 + j] = .{ .x = u, .y = u * v };
        flat[i * 4 + j] = .{ .x = -u * v, .y = u };
        fine_field[i * 4 + j] = along[j];
        flat_field[i * 4 + j] = 0.0;
    };
    const result = try patches.triangulate(t.allocator, &.{ fine, flat }, &.{ fine_field, flat_field }, .{ .tolerance = 0.005, .max_triangles = 100_000 });
    defer result.deinit(t.allocator);
    var fine_triangles: usize = 0;
    var flat_triangles: usize = 0;
    for (result.triangles) |triangle| {
        var is_flat = false;
        for (triangle) |idx| if (result.points[idx].x < 0) {
            is_flat = true;
        };
        if (is_flat) flat_triangles += 1 else fine_triangles += 1;
    }
    try t.expect(fine_triangles > 2);
    try t.expectEqual(@as(usize, 2), flat_triangles);
}

test "triangulation releases everything on allocation failure" {
    const curved = spherePatch(std.math.pi / 2.0 - 0.25, std.math.pi / 2.0, 0, 0.25);
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(allocator: std.mem.Allocator, points: [16]g.Point, values: [16]f64) !void {
            const result = try patches.triangulate(allocator, &.{points}, &.{values}, .{ .tolerance = 1.0 / 64.0, .max_triangles = 10_000 });
            result.deinit(allocator);
        }
    }.run, .{ curved.points, curved.values });
}
