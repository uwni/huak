//! Tests of conic paints lowered to patches and triangles: the field along chords and rays, both within the tolerance, patches shared by paints on the same rays, and rays that cannot be drawn.
const std = @import("std");
const g = @import("../geometry.zig");
const Conic = @import("../style.zig").Gradient.Conic;
const testing = std.testing;
const style = @import("../style.zig");
const conic_mesh = @import("../conic.zig");
const evaluate = conic_mesh.evaluate;
const triangulate = conic_mesh.triangulate;
const margin = conic_mesh.margin;
const patches = conic_mesh.patches;
const sharedPatches = conic_mesh.sharedPatches;

fn testConic(points: []const g.Point, values: []const f64, tolerance: f64) Conic {
    const levels = [_]f64{ 0, 1 };
    const colors = [_]style.Color{ .black, .{ .r = 1, .g = 1, .b = 1 } };
    return .{ .center = .{ .x = 1, .y = 2 }, .points = points, .values = values, .stops = .{ .levels = &levels, .colors = &colors }, .tolerance = tolerance };
}

test "the field is linear along each chord and constant along each ray" {
    const center: g.Point = .{ .x = 1, .y = 2 };
    const points = [_]g.Point{ center.add(.{ .x = 1, .y = 0 }), center.add(.{ .x = 0, .y = 1 }) };
    const conic = testConic(&points, &.{ 0, 1 }, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0.5), evaluate(conic, center.add(.{ .x = 3, .y = 3 })).?, 1e-12);
    // The ray through (2, 1) crosses the chord a third of the way along.
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), evaluate(conic, center.add(.{ .x = 2, .y = 1 })).?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), evaluate(conic, center.add(.{ .x = 0.02, .y = 0.01 })).?, 1e-12);
    try testing.expectEqual(@as(?f64, null), evaluate(conic, center.add(.{ .x = -1, .y = 1 })));
    try testing.expectEqual(@as(?f64, null), evaluate(conic, center));
}

test "triangles stay within the tolerance of the field" {
    const center: g.Point = .{ .x = 1, .y = 2 };
    // Unequal radii and a step on the third ray, turning either way.
    const stepped: g.Point = .{ .x = -0.5, .y = 1 };
    const counterclockwise = [_]g.Point{
        center.add(.{ .x = 3, .y = -1 }),
        center.add(.{ .x = 2, .y = 2 }),
        center.add(stepped),
        center.add(stepped.scale(2)),
        center.add(.{ .x = -3, .y = -1 }),
    };
    var clockwise = counterclockwise;
    std.mem.reverse(g.Point, &clockwise);
    const values = [_]f64{ -0.2, 0.9, 0.35, 0.1, 0.6 };
    const tolerance = 0.01;
    const cover: g.BBox = .{ .min = .{ .x = -6, .y = -4 }, .max = .{ .x = 8, .y = 9 } };
    for ([_][]const g.Point{ &counterclockwise, &clockwise }, [_]usize{ 2, 1 }) |points, step_index| {
        const conic = testConic(points, &values, tolerance);
        const mesh = try triangulate(testing.allocator, conic, cover, 10_000);
        defer mesh.deinit(testing.allocator);
        // Each wedge splits until its parts differ by at most twice the tolerance.
        var expected: usize = 0;
        for (values[0 .. values.len - 1], values[1..], 0..) |a, b, k| {
            if (k == step_index) continue;
            expected += @max(1, @as(usize, @intFromFloat(@ceil(@abs(b - a) / (2 * tolerance)))));
        }
        try testing.expectEqual(expected, mesh.triangles.len);
        var checked: usize = 0;
        var worst: f64 = 0;
        const grid = 200;
        for (0..grid + 1) |j| for (0..grid + 1) |i| {
            const p: g.Point = .{ .x = cover.min.x + cover.width() * @as(f64, @floatFromInt(i)) / grid, .y = cover.min.y + cover.height() * @as(f64, @floatFromInt(j)) / grid };
            // The field jumps across the step's ray: either side is right on it.
            const ray = p.sub(center);
            if (@abs(ray.cross(stepped)) <= 1e-9 * ray.norm() and ray.dot(stepped) > 0) continue;
            const exact = evaluate(conic, p) orelse continue;
            var found: ?f64 = null;
            for (mesh.triangles) |t| {
                const a = mesh.points[t[0]];
                const b = mesh.points[t[1]];
                const c = mesh.points[t[2]];
                const area = b.sub(a).cross(c.sub(a));
                const wa = b.sub(p).cross(c.sub(p)) / area;
                const wb = c.sub(p).cross(a.sub(p)) / area;
                const wc = 1 - wa - wb;
                if (wa < -1e-12 or wb < -1e-12 or wc < -1e-12) continue;
                found = wa * mesh.values[t[0]] + wb * mesh.values[t[1]] + wc * mesh.values[t[2]];
            }
            worst = @max(worst, @abs(found.? - exact));
            checked += 1;
        };
        try testing.expect(checked > 10_000);
        try testing.expect(worst <= tolerance + 1e-12);
        // The bound is nearly reached beside the center.
        try testing.expect(worst > 0.9 * tolerance);
        try testing.expectError(error.GeometryWorkLimit, triangulate(testing.allocator, conic, cover, expected - 1));
    }
}

test "patches stay within the tolerance of the field" {
    const patch_mesh = @import("../patches.zig");
    const center: g.Point = .{ .x = 1, .y = 2 };
    const cover: g.BBox = .{ .min = .{ .x = -4, .y = -3 }, .max = .{ .x = 6, .y = 7 } };
    const reach_ = margin * std.math.sqrt2 * cover.max.sub(center).norm();

    // Rays of one length: the far chords are the wedges' own, scaled, and
    // the patches are the field. The step on the second ray makes none.
    const even = [_]g.Point{ center.add(.{ .x = 2, .y = 0 }), center.add(.{ .x = 1, .y = @sqrt(3.0) }), center.add(.{ .x = 1, .y = @sqrt(3.0) }), center.add(.{ .x = -1, .y = @sqrt(3.0) }) };
    const exact = testConic(&even, &.{ 0.1, 0.8, 0.3, 0.6 }, 0.01);
    const whole = try patches(testing.allocator, exact, cover, 100);
    defer whole.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), whole.points.len);
    try testing.expectEqual([4]f64{ 0.1, 0.1, 0.8, 0.8 }, [4]f64{ whole.values[0][0], whole.values[0][3], whole.values[0][12], whole.values[0][15] });
    try testing.expectEqual([4]f64{ 0.3, 0.3, 0.6, 0.6 }, [4]f64{ whole.values[1][0], whole.values[1][3], whole.values[1][12], whole.values[1][15] });
    // Two corners at the center, two at the far distance on the rays; the
    // patches meet along the ray between them.
    try testing.expectEqual(center, whole.points[0][0]);
    try testing.expectEqual(center, whole.points[0][12]);
    try testing.expectApproxEqAbs(reach_, whole.points[0][3].sub(center).norm(), 1e-12);
    try testing.expectEqual(whole.points[0][12..16].*, whole.points[1][0..4].*);
    for (whole.points, whole.values) |*patch, *field| for (1..10) |i| for (1..10) |j| {
        const at = patch_mesh.evaluate(patch, field, @as(f64, @floatFromInt(i)) / 10, @as(f64, @floatFromInt(j)) / 10);
        try testing.expectApproxEqAbs(evaluate(exact, at.point).?, at.value, 1e-12);
    };

    // Ends at distances 1 and 4 from the center skew a single patch by a
    // third of the change across it, so the wedge is cut into parts.
    const uneven = [_]g.Point{ center.add(.{ .x = 1, .y = 0 }), center.add(.{ .x = 0, .y = 4 }) };
    const skewed = testConic(&uneven, &.{ 0, 1 }, 0.01);
    const cut = try patches(testing.allocator, skewed, cover, 100);
    defer cut.deinit(testing.allocator);
    try testing.expect(cut.points.len > 1);
    var worst: f64 = 0;
    for (cut.points, cut.values) |*patch, *field| for (1..20) |i| for (1..10) |j| {
        const at = patch_mesh.evaluate(patch, field, @as(f64, @floatFromInt(i)) / 20, @as(f64, @floatFromInt(j)) / 10);
        worst = @max(worst, @abs(evaluate(skewed, at.point).? - at.value));
    };
    try testing.expect(worst <= skewed.tolerance);
    try testing.expect(worst > skewed.tolerance / 8);
    try testing.expectError(error.GeometryWorkLimit, patches(testing.allocator, skewed, cover, cut.points.len - 1));
}

test "paints on the same rays share patches cut for the one that needs most" {
    const patch_mesh = @import("../patches.zig");
    const center: g.Point = .{ .x = 1, .y = 2 };
    const cover: g.BBox = .{ .min = .{ .x = -4, .y = -3 }, .max = .{ .x = 6, .y = 7 } };
    const uneven = [_]g.Point{ center.add(.{ .x = 1, .y = 0 }), center.add(.{ .x = 0, .y = 4 }) };
    // The same change, and a flat field that alone needs one patch.
    const steep = testConic(&uneven, &.{ 0, 1 }, 0.01);
    const flat = testConic(&uneven, &.{ 0.5, 0.5 }, 0.01);
    const alone = try patches(testing.allocator, steep, cover, 100);
    defer alone.deinit(testing.allocator);
    const shared = try sharedPatches(testing.allocator, &.{ flat, steep }, cover, 100);
    defer shared.deinit(testing.allocator);
    try testing.expectEqual(alone.points.len, shared.points.len);
    try testing.expectEqualSlices([16]g.Point, alone.points, shared.points);
    try testing.expectEqualSlices([16]f64, alone.values, shared.field(1));
    for (shared.points, shared.field(0)) |*patch, *field| {
        try testing.expectApproxEqAbs(@as(f64, 0.5), patch_mesh.evaluate(patch, field, 0.3, 0.6).value, 1e-12);
    }
    const elsewhere = testConic(&.{ uneven[0], uneven[1].add(.{ .x = 1, .y = 0 }) }, &.{ 0, 1 }, 0.01);
    try testing.expectError(error.InvalidStyle, sharedPatches(testing.allocator, &.{ steep, elsewhere }, cover, 100));
}

test "a chord along its rays is drawn no farther than the others" {
    // Where a projection folds, neighbouring rays nearly coincide and their
    // chord runs along them.
    const center: g.Point = .{ .x = 1, .y = 2 };
    const points = [_]g.Point{ center.add(.{ .x = 1, .y = 0 }), center.add(.{ .x = 3, .y = 0.001 }), center.add(.{ .x = 0, .y = 2 }) };
    const conic = testConic(&points, &.{ 0, 0.01, 0.4 }, 0.005);
    const cover: g.BBox = .{ .min = .{ .x = -3, .y = -2 }, .max = .{ .x = 5, .y = 6 } };
    const reach_ = margin * std.math.sqrt2 * cover.max.sub(center).norm();
    const lowered = try patches(testing.allocator, conic, cover, 100);
    defer lowered.deinit(testing.allocator);
    for (lowered.points) |patch| for (patch) |point| try testing.expect(point.sub(center).norm() <= reach_ * (1 + 1e-12));
    const mesh = try triangulate(testing.allocator, conic, cover, 1000);
    defer mesh.deinit(testing.allocator);
    for (mesh.points) |point| try testing.expect(point.sub(center).norm() <= reach_ * (1 + 1e-12));
    // Every far chord lies past the cover.
    for (mesh.triangles) |corners| {
        const from = mesh.points[corners[1]].sub(center);
        const to = mesh.points[corners[2]].sub(center);
        try testing.expect(@abs(from.cross(to)) / to.sub(from).norm() > cover.max.sub(center).norm());
    }
}

test "rays half a turn apart are rejected" {
    const center: g.Point = .{ .x = 1, .y = 2 };
    const points = [_]g.Point{ center.add(.{ .x = 1, .y = 0 }), center.add(.{ .x = -2, .y = 0 }) };
    try testing.expectError(error.InvalidStyle, triangulate(testing.allocator, testConic(&points, &.{ 0, 1 }, 0.01), .{ .min = .zero, .max = .{ .x = 1, .y = 1 } }, 100));
    const on_center = [_]g.Point{ center, center.add(.{ .x = 0, .y = 1 }) };
    try testing.expectError(error.InvalidStyle, patches(testing.allocator, testConic(&on_center, &.{ 0, 1 }, 0.01), .{ .min = .zero, .max = .{ .x = 1, .y = 1 } }, 100));
}
