//! Source-parameter crossing events, independent of drawing order and paint.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");
const Intersections = @import("../region/pathops/Intersections.zig");
const native = @import("../region/pathops/curve.zig");
const Allocator = std.mem.Allocator;
const Sources = @import("crossings/Sources.zig");
const self_intersection = @import("crossings/self_intersection.zig");

pub const Branch = struct { path: usize, contour: usize, time: f64 };
pub const Crossing = struct { point: g.Point, first: Branch, second: Branch };
pub const Options = struct {
    tolerance: f64 = 1e-8,
    /// Aggregate path headers and source segments, including MOVE/CLOSE.
    max_source_items: usize = 131073,
    /// Source segment-pair candidates, cubic self queries and event identity
    /// comparisons across the batch, rather than internal solver iterations.
    max_comparisons: usize = 1000000,
    max_events: usize = 65536,
};

pub fn consume(remaining: *usize, count: usize) error{GeometryWorkLimit}!void {
    if (count > remaining.*) return error.GeometryWorkLimit;
    remaining.* -= count;
}

/// The caller owns the result, sorted by first then second source branch.
/// Only transverse double crossings are returned. Ordinary adjacent nodes and
/// closed seams are excluded. Tangency/stationary contacts, overlapping curves
/// and three-or-more branches indistinguishable at tolerance are diagnosed as
/// NonTransverseCrossing, CoincidentCurves and MultipleCrossing respectively.
/// options.tolerance is spatial; source parameter identity is never merged by
/// it. Open terminal contacts are not ordinary double crossings. All limits
/// apply to the whole batch and report GeometryWorkLimit when exhausted.
pub fn find(allocator: Allocator, input: []const Path, options: Options) ![]Crossing {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.max_source_items == 0 or options.max_comparisons == 0 or options.max_events == 0) return error.GeometryWorkLimit;
    var source = try Sources.init(allocator, input, options.max_source_items);
    defer source.deinit(allocator);
    var result: std.ArrayList(Crossing) = .empty;
    errdefer result.deinit(allocator);
    var remaining = options.max_comparisons;
    for (source.segments.items, 0..) |first, index| {
        if (first.cubic) {
            try consume(&remaining, 1);
            if (try self_intersection.selfIntersection(first.curve, options.tolerance)) |hit|
                try append(allocator, &result, &source, index, index, hit, options, &remaining);
        }
        for (source.segments.items[index + 1 ..], index + 1..) |second, second_index| {
            try consume(&remaining, 1);
            const hits = try pairIntersections(allocator, first, second);
            for (0..hits.used) |hit_index| {
                if (hits.isCoincident(hit_index)) try rejectCoincidence(allocator, first, second);
                const a = hits.parameters[0][hit_index];
                const b = hits.parameters[1][hit_index];
                const one = first.curve.at(a);
                const two = second.curve.at(b);
                if (!one.isFinite() or !two.isFinite() or one.distance(two) > options.tolerance) return error.ResolutionLimit;
                try append(allocator, &result, &source, index, second_index, .{ .a = a, .b = b, .point = one.lerp(two, 0.5) }, options, &remaining);
            }
        }
    }
    std.mem.sort(Crossing, result.items, {}, struct {
        fn less(_: void, first: Crossing, second: Crossing) bool {
            return branchLess(first.first, second.first) or
                (sameBranch(first.first, second.first) and branchLess(first.second, second.second));
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

/// Use PathOps' primitive endpoint-seeded solver without its path builder:
/// source segment/contour identities and open endpoints remain unchanged.
/// A common power-of-two scale keeps the primitive's numeric comparisons
/// independent of physical units; the original curves check spatial residuals.
fn pairIntersections(allocator: Allocator, first: Sources.Segment, second: Sources.Segment) !Intersections {
    const controls = [_][4]g.Point{
        .{ first.curve.p0, first.curve.p1, first.curve.p2, first.curve.p3 },
        .{ second.curve.p0, second.curve.p1, second.curve.p2, second.curve.p3 },
    };
    const origin = first.curve.p0;
    var translated: [2][4]g.Point = undefined;
    var magnitude: f64 = 0;
    var finite = true;
    for (controls, &translated) |curve, *out| for (curve, out) |point, *mapped| {
        mapped.* = point.sub(origin);
        finite = finite and mapped.isFinite();
        magnitude = @max(magnitude, @max(@abs(mapped.x), @abs(mapped.y)));
    };
    if (!finite) {
        magnitude = 0;
        for (controls) |curve| {
            for (curve) |point| magnitude = @max(magnitude, @max(@abs(point.x), @abs(point.y)));
        }
    }
    const exponent = if (magnitude > 0) std.math.frexp(magnitude).exponent else 0;
    var curves: [2]native.Curve = undefined;
    for (controls, translated, &curves, [_]bool{ first.cubic, second.cubic }) |curve, relative, *out, is_cubic| {
        var points: [4]native.Point = undefined;
        for (curve, relative, &points) |point, delta, *mapped| mapped.* = if (finite)
            .{ .x = std.math.ldexp(delta.x, -exponent), .y = std.math.ldexp(delta.y, -exponent) }
        else
            .{ .x = std.math.ldexp(point.x, -exponent) - std.math.ldexp(origin.x, -exponent), .y = std.math.ldexp(point.y, -exponent) - std.math.ldexp(origin.y, -exponent) };
        out.* = if (is_cubic) .{ .cubic = .{ .points = points } } else .{ .line = .{ .points = .{ points[0], points[3] } } };
    }
    var hits: Intersections = .{ .allow_near = false };
    _ = try hits.curveCurve(allocator, curves[0], curves[1]);
    if (hits.overflow) return error.IntersectionWorkLimit;
    // A uniqueness certificate excludes two real crossings. Keep unresolved
    // near-end observations out of the incident-branch classifier.
    if (hits.used > 1 and @import("../region/pathops/intersections/separation.zig").atMostOne(curves[0], curves[1])) return error.ResolutionLimit;
    // Near endpoint matches are an upstream geometric equivalence policy,
    // not proof that the source branches share exactly one parameter.
    if (hits.nearly_same[0] or hits.nearly_same[1]) return error.ResolutionLimit;
    return hits;
}

fn rejectCoincidence(allocator: Allocator, first: Sources.Segment, second: Sources.Segment) !void {
    if (std.meta.eql(first.curve, second.curve) or std.meta.eql(first.curve, second.curve.reversed())) return error.CoincidentCurves;
    if (!first.cubic and !second.cubic) {
        // Reuse the source line query's collinear-interval predicate. Native
        // approximate coincidence alone cannot prove overlapping support.
        const proof = Path.cubic_intersect.intersectLineCubic(allocator, first.curve.p0, first.curve.p3, second.curve) catch |err| switch (err) {
            error.CoincidentCurves, error.OutOfMemory => return err,
            else => return error.ResolutionLimit,
        };
        allocator.free(proof);
    }
    return error.ResolutionLimit;
}

fn sameBranch(first: Branch, second: Branch) bool {
    return first.path == second.path and first.contour == second.contour and first.time == second.time;
}
fn branchLess(first: Branch, second: Branch) bool {
    if (first.path != second.path) return first.path < second.path;
    if (first.contour != second.contour) return first.contour < second.contour;
    return first.time < second.time;
}

fn append(allocator: Allocator, result: *std.ArrayList(Crossing), source: *const Sources, first_index: usize, second_index: usize, hit: Path.cubic_intersect.Intersection, options: Options, remaining: *usize) !void {
    if (!source.owns(first_index, hit.a) or !source.owns(second_index, hit.b)) return;
    const first = source.segments.items[first_index];
    const second = source.segments.items[second_index];
    var event: Crossing = .{ .point = hit.point, .first = source.branch(first, hit.a), .second = source.branch(second, hit.b) };
    if (sameBranch(event.first, event.second)) return; // Ordinary node/seam.
    try transverse(try source.rays(first_index, hit.a), try source.rays(second_index, hit.b));
    if (branchLess(event.second, event.first)) std.mem.swap(Branch, &event.first, &event.second);
    for (result.items) |old| {
        try consume(remaining, 1);
        if (sameBranch(old.first, event.first) and sameBranch(old.second, event.second)) {
            if (old.point.distance(event.point) > options.tolerance) return error.ResolutionLimit;
            return;
        }
        if (old.point.distance(event.point) <= options.tolerance) return error.MultipleCrossing;
    }
    if (result.items.len >= options.max_events) return error.GeometryWorkLimit;
    try result.append(allocator, event);
}

fn angleLess(first: g.Point, second: g.Point) bool {
    const a = first.y > 0 or (first.y == 0 and first.x >= 0);
    const b = second.y > 0 or (second.y == 0 and second.x >= 0);
    return if (a != b) a else first.cross(second) > 0;
}

fn transverse(first: [2]g.Point, second: [2]g.Point) !void {
    const uncertainty = 16 * std.math.floatEps(f64);
    for ([_][2]g.Point{ first, second }) |rays| {
        if (@abs(rays[0].cross(rays[1])) <= uncertainty and rays[0].dot(rays[1]) > 0) return error.NonTransverseCrossing;
    }
    // Four incident rays must alternate around the point. Checking only one
    // derivative per segment would misclassify a contact at a sharp corner.
    for (first) |a| for (second) |b| {
        if (@abs(a.cross(b)) <= uncertainty) return error.NonTransverseCrossing;
    };
    const wraps = angleLess(first[1], first[0]);
    var between: [2]bool = undefined;
    for (second, &between) |ray, *inside| {
        const after = angleLess(first[0], ray);
        const before = angleLess(ray, first[1]);
        inside.* = if (wraps) after or before else after and before;
    }
    if (between[0] == between[1]) return error.NonTransverseCrossing;
}

test {
    _ = @import("crossings/self_intersection_test.zig");
    _ = @import("crossings/events_test.zig");
}
