//! Curve comparison shared by the pen tests: control tolerances, sampled deviation, coverage mismatches, redundant traces and winding.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const g = core.geometry;
const Path = core.Path;
const Point = g.Point;
const Cubic = g.Cubic;

pub const control_tolerance = 1e-7;

pub const geometry_tolerance = 2e-5;

pub fn curves(a: std.mem.Allocator, path: Path) ![]Cubic {
    const result = try a.alloc(Cubic, path.segmentCount());
    errdefer a.free(result);
    for (result, 0..) |*curve, index| curve.* = (try path.curveAt(@floatFromInt(index))).curve;
    return result;
}

fn segmentDistance(point: Point, from: Point, to: Point) f64 {
    const delta = to.sub(from);
    const square = delta.dot(delta);
    return if (square == 0) point.distance(from) else point.distance(from.add(delta.scale(std.math.clamp(point.sub(from).dot(delta) / square, 0, 1))));
}

pub fn straight(curve: Cubic) bool {
    var direction = curve.p3.sub(curve.p0);
    if (direction.norm() <= control_tolerance) direction = curve.p1.sub(curve.p0);
    if (direction.norm() <= control_tolerance) direction = curve.p2.sub(curve.p0);
    if (direction.norm() <= control_tolerance) return true;
    const unit = direction.scale(1 / direction.norm());
    return @max(@abs(curve.p1.sub(curve.p0).cross(unit)), @abs(curve.p2.sub(curve.p0).cross(unit))) <= control_tolerance;
}

pub fn sameControls(first: Cubic, second: Cubic, tolerance: f64) bool {
    return first.p0.distance(second.p0) <= tolerance and first.p1.distance(second.p1) <= tolerance and
        first.p2.distance(second.p2) <= tolerance and first.p3.distance(second.p3) <= tolerance;
}

// Reuse the core's de Casteljau split. This test-only distance bound accepts
// arbitrary contour starts and MP's nonuniform parameterization of straight
// connectors; it does not flatten the candidate before checking its controls.
fn nearest(point: Point, curve: Cubic, best: *f64, depth: usize) void {
    const box = curve.controlBounds();
    const closest: Point = .{ .x = std.math.clamp(point.x, box.min.x, box.max.x), .y = std.math.clamp(point.y, box.min.y, box.max.y) };
    if (point.distance(closest) > best.*) return;
    const flatness = @max(segmentDistance(curve.p1, curve.p0, curve.p3), segmentDistance(curve.p2, curve.p0, curve.p3));
    if (flatness <= geometry_tolerance * 0.05 or depth == 24) {
        best.* = @min(best.*, segmentDistance(point, curve.p0, curve.p3));
        return;
    }
    const halves = curve.split(0.5);
    nearest(point, halves.left, best, depth + 1);
    nearest(point, halves.right, best, depth + 1);
}

/// Geometric deviation after excluding ONLY redundant straight retracing
/// whose local nonzero coverage is constant and equal on both results.
pub fn visibleSampledDeviation(first: []const Cubic, second: []const Cubic) !f64 {
    if (first.len == 0 or second.len == 0) return if (first.len == second.len) 0 else std.math.inf(f64);
    var maximum: f64 = 0;
    for ([_]struct { from: []const Cubic, to: []const Cubic }{ .{ .from = first, .to = second }, .{ .from = second, .to = first } }) |direction| {
        for (direction.from) |curve| for (0..17) |index| {
            const point = curve.at(@as(f64, @floatFromInt(index)) / 16);
            var distance = std.math.inf(f64);
            for (direction.to) |candidate| nearest(point, candidate, &distance, 0);
            if (distance > geometry_tolerance and straight(curve) and try redundantTrace(direction.from, direction.to, point)) continue;
            maximum = @max(maximum, distance);
        };
    }
    return maximum;
}

/// Independent paint samples: identical curve sets can still have different
/// nonzero fill when a hole's traversal direction changes.
pub fn coverageSampleMismatches(first: []const Cubic, second: []const Cubic) !usize {
    if (first.len == 0 or second.len == 0) return if (first.len == second.len) 0 else 1;
    var box = first[0].bounds();
    for (first[1..]) |curve| box = box.unite(curve.bounds());
    for (second) |curve| box = box.unite(curve.bounds());
    box = box.expanded(1);
    var mismatches: usize = 0;
    for (0..23) |y| for (0..27) |x| {
        const point: Point = .{
            .x = box.min.x + (box.max.x - box.min.x) * (@as(f64, @floatFromInt(x)) + 0.371) / 27,
            .y = box.min.y + (box.max.y - box.min.y) * (@as(f64, @floatFromInt(y)) + 0.613) / 23,
        };
        if ((try winding(first, point) != 0) != (try winding(second, point) != 0)) mismatches += 1;
    };
    return mismatches;
}

pub fn compareCurves(expected: []const Cubic, actual: []const Cubic, oracle_tolerance: f64) !usize {
    // Every genuinely curved piece must retain the independent oracle's full
    // controls (up to traversal direction), not merely endpoint/bbox/area.
    const used = try t.allocator.alloc(bool, actual.len);
    defer t.allocator.free(used);
    @memset(used, false);
    var count: usize = 0;
    for (expected) |curve| {
        if (straight(curve)) continue;
        var matched = false;
        for (actual, 0..) |candidate, index| {
            if (used[index] or straight(candidate)) continue;
            if (sameControls(curve, candidate, oracle_tolerance) or sameControls(curve, candidate.reversed(), oracle_tolerance)) {
                used[index] = true;
                matched = true;
                break;
            }
        }
        if (!matched) std.debug.print("missing cubic controls: {any}\nactual: {any}\n", .{ curve, actual });
        try t.expect(matched);
        count += 1;
    }
    var actual_count: usize = 0;
    for (actual) |curve| if (!straight(curve)) {
        actual_count += 1;
    };
    try t.expectEqual(count, actual_count);
    var redundant_samples: usize = 0;
    for ([_]struct { from: []const Cubic, to: []const Cubic }{ .{ .from = expected, .to = actual }, .{ .from = actual, .to = expected } }) |direction| {
        for (direction.from) |curve| for (0..17) |sample| {
            const point = curve.at(@as(f64, @floatFromInt(sample)) / 16);
            var distance = std.math.inf(f64);
            for (direction.to) |candidate| nearest(point, candidate, &distance, 0);
            if (distance > geometry_tolerance) {
                // MP can select either endpoint of a flat support face and
                // retain a different interior retracing. Permit this only for
                // straight pieces whose entire local neighborhood has the
                // SAME constant coverage on BOTH paths. A visible boundary,
                // missing hole or extra filled region cannot use this escape.
                const redundant = straight(curve) and try redundantTrace(direction.from, direction.to, point);
                if (!redundant) std.debug.print("visible boundary sample {any}: distance={d}\n", .{ point, distance });
                try t.expect(redundant);
                redundant_samples += 1;
            }
        };
    }
    return redundant_samples;
}

fn redundantTrace(first: []const Cubic, second: []const Cubic, point: Point) !bool {
    var occupied: ?bool = null;
    // Every offset is shorter than the rejected distance and non-axis-aligned.
    // Requiring constant occupancy also rejects nearby shifted boundaries.
    const epsilon = geometry_tolerance * 0.25;
    for (0..8) |index| {
        const angle = (@as(f64, @floatFromInt(index)) + 0.173) * std.math.pi / 4;
        const sample = point.add(.{ .x = epsilon * @cos(angle), .y = epsilon * @sin(angle) });
        const a = try winding(first, sample) != 0;
        const b = try winding(second, sample) != 0;
        if (a != b or (occupied != null and occupied.? != a)) return false;
        occupied = a;
    }
    return true;
}

pub fn winding(curves_: []const Cubic, point: Point) !i32 {
    var result: i32 = 0;
    for (curves_) |curve| {
        if (straight(curve)) {
            const first = curve.p0;
            const last = curve.p3;
            if ((first.y <= point.y and last.y > point.y) or (last.y <= point.y and first.y > point.y)) {
                const x = first.x + (point.y - first.y) * (last.x - first.x) / (last.y - first.y);
                if (x > point.x) result += if (last.y > first.y) @as(i32, 1) else -1;
            }
            continue;
        }
        const hits = try Path.cubic_intersect.intersectLineCubic(t.allocator, point, .{ .x = 1000, .y = point.y }, curve);
        defer t.allocator.free(hits);
        for (hits) |hit| {
            if (hit.b >= 1 or hit.a <= 0) continue;
            const derivative = curve.derivative(hit.b).y;
            if (@abs(derivative) > 1e-8) result += if (derivative > 0) @as(i32, 1) else -1;
        }
    }
    return result;
}

test "interior trace allowance rejects shifted boundaries missing holes and added ink" {
    const Fixture = struct {
        fn box(min: Point, max: Point) !Path {
            var path: Path = .init(t.allocator);
            errdefer path.deinit();
            try path.moveTo(min);
            try path.lineTo(.{ .x = max.x, .y = min.y });
            try path.lineTo(max);
            try path.lineTo(.{ .x = min.x, .y = max.y });
            try path.close();
            return path;
        }
    };
    var solid = try Fixture.box(.zero, .{ .x = 10, .y = 10 });
    defer solid.deinit();
    const original = try curves(t.allocator, solid);
    defer t.allocator.free(original);
    try t.expect(try redundantTrace(original, original, .{ .x = 5, .y = 5 }));
    var shifted = try solid.transformed(t.allocator, .translation(1, 0));
    defer shifted.deinit();
    const moved = try curves(t.allocator, shifted);
    defer t.allocator.free(moved);
    try t.expect(!try redundantTrace(original, moved, .{ .x = 0, .y = 5 }));
    var inner = try Fixture.box(.{ .x = 3, .y = 3 }, .{ .x = 7, .y = 7 });
    defer inner.deinit();
    var reverse = try inner.reverse(t.allocator);
    defer reverse.deinit();
    var ring = try solid.clone(t.allocator);
    defer ring.deinit();
    try ring.append(reverse);
    const hole = try curves(t.allocator, ring);
    defer t.allocator.free(hole);
    try t.expectEqual(@as(i32, 0), try winding(hole, .{ .x = 5, .y = 5 }));
    try t.expect(!try redundantTrace(hole, original, .{ .x = 5, .y = 5 }));
    try t.expect(!try redundantTrace(hole, original, .{ .x = 3, .y = 5 }));
    var covered = try solid.clone(t.allocator);
    defer covered.deinit();
    try covered.append(inner);
    const no_hole = try curves(t.allocator, covered);
    defer t.allocator.free(no_hole);
    // The geometric curve sets agree exactly even though the hole is filled.
    try t.expect(try visibleSampledDeviation(hole, no_hole) < geometry_tolerance);
    try t.expect(try coverageSampleMismatches(hole, no_hole) > 0);
    try t.expectEqual(@as(usize, 0), try coverageSampleMismatches(hole, hole));
    var island = try Fixture.box(.{ .x = 12, .y = 0 }, .{ .x = 14, .y = 2 });
    defer island.deinit();
    var extra = try solid.clone(t.allocator);
    defer extra.deinit();
    try extra.append(island);
    const added = try curves(t.allocator, extra);
    defer t.allocator.free(added);
    try t.expect(!try redundantTrace(original, added, .{ .x = 13, .y = 1 }));
}
