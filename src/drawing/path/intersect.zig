//! Whole-path intersections: points, or details with segment times on both paths.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const cubic_intersect = @import("cubic_intersect.zig");
const CurveReader = @import("CurveReader.zig");
const Intersection = cubic_intersect.Intersection;
const intersectCubics = cubic_intersect.intersectCubics;

/// All distinct spatial intersections, visiting each self segment against
/// each other segment in traversal order; points are not globally sorted
/// by self's parameter. The caller owns the result. Residual checks and
/// coincident/unresolved curve diagnostics come from intersectCubics;
/// points within tolerance are merged, including shared segment endpoints.
pub fn intersections(self: Path, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Point {
    return collectIntersections(self, Point, allocator, other, tolerance);
}

/// Intersections ordered by each path's drawable-segment time, a then b.
/// MOVE and zero-length CLOSE consume no time; a nonzero CLOSE consumes
/// one segment. Closed start/end times remain distinct. Spatial tolerance
/// belongs only to intersectCubics, never to parameter deduplication.
/// Only exactly equal parameter pairs and root points are merged, so
/// disconnected endpoints at the same integer time remain distinguishable.
/// The caller owns the result; point retains the underlying solver's value.
pub fn intersectionDetails(self: Path, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Intersection {
    return collectIntersections(self, Intersection, allocator, other, tolerance);
}

fn collectIntersections(self: Path, comptime Result: type, allocator: std.mem.Allocator, other: Path, tolerance: f64) ![]Result {
    if (!std.math.isFinite(tolerance) or tolerance <= 0) return error.NonFinite;
    var result: std.ArrayList(Result) = .empty;
    errdefer result.deinit(allocator);
    const first_count = self.segmentCount();
    const second_count = other.segmentCount();
    var outer: CurveReader = .{ .segments = self.segments.items };
    for (0..first_count) |i| {
        const first = (try outer.read(0)).curve;
        var inner: CurveReader = .{ .segments = other.segments.items };
        for (0..second_count) |j| {
            const second = (try inner.read(0)).curve;
            const hits = try intersectCubics(allocator, first, second, tolerance);
            defer allocator.free(hits);
            for (hits) |hit| {
                const value: Result = if (Result == Point) hit.point else .{ .point = hit.point, .a = @as(f64, @floatFromInt(i)) + hit.a, .b = @as(f64, @floatFromInt(j)) + hit.b };
                var duplicate = false;
                for (result.items) |old| {
                    if (if (Result == Point) old.distance(value) <= tolerance else old.a == value.a and old.b == value.b and old.point.eql(value.point)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try result.append(allocator, value);
            }
        }
    }
    if (Result == Intersection) std.mem.sort(Intersection, result.items, {}, struct {
        fn less(_: void, left: Intersection, right: Intersection) bool {
            return left.a < right.a or (left.a == right.a and left.b < right.b);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}
