//! Source-parameter crossing events, independent of drawing order and paint.
//! Cubic self-intersections eliminate the trivial u=v solution in the power
//! basis, then use the shared stable quadratic solver; see
//! https://math.stackexchange.com/questions/3776840 (Parcly Taxel, 2021).
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");
const Intersections = @import("../region/pathops/Intersections.zig");
const native = @import("../region/pathops/curve.zig");
const Allocator = std.mem.Allocator;

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

const Contour = struct {
    path: usize,
    index: usize,
    first: usize,
    count: usize = 0,
    closed: bool = false,
};
const Segment = struct { curve: g.Cubic, contour: usize, time: f64, cubic: bool };
const Sources = struct {
    segments: std.ArrayList(Segment) = .empty,
    contours: std.ArrayList(Contour) = .empty,

    fn deinit(self: *Sources, allocator: Allocator) void {
        self.segments.deinit(allocator);
        self.contours.deinit(allocator);
    }

    fn init(allocator: Allocator, input: []const Path, limit: usize) !Sources {
        var result: Sources = .{};
        errdefer result.deinit(allocator);
        var remaining = limit;
        try consume(&remaining, input.len);
        for (input, 0..) |path, path_index| {
            try consume(&remaining, path.segments.items.len);
            var current: g.Point = .zero;
            var start: g.Point = .zero;
            var active: ?usize = null;
            var contour_index: usize = 0;
            var time: f64 = 0;
            for (path.segments.items) |segment| {
                if (segment == .move) {
                    if (!segment.move.isFinite()) return error.NonFinite;
                    current = segment.move;
                    start = current;
                    active = result.contours.items.len;
                    try result.contours.append(allocator, .{ .path = path_index, .index = contour_index, .first = result.segments.items.len });
                    contour_index += 1;
                    continue;
                }
                const contour = active orelse return error.InvalidPath;
                if (segment != .close or !current.eql(start)) {
                    const curve: g.Cubic = switch (segment) {
                        .line => |point| .line(current, point),
                        .cubic => |curve| .{ .p0 = current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end },
                        .close => .line(current, start),
                        .move => unreachable,
                    };
                    if (!curve.isFinite()) return error.NonFinite;
                    try result.segments.append(allocator, .{ .curve = curve, .contour = contour, .time = time, .cubic = segment == .cubic });
                    time += 1;
                    result.contours.items[contour].count += 1;
                    current = curve.p3;
                }
                if (segment == .close) {
                    result.contours.items[contour].closed = true;
                    active = null;
                }
            }
        }
        return result;
    }

    fn branch(self: *const Sources, segment: Segment, local: f64) Branch {
        const contour = self.contours.items[segment.contour];
        return .{ .path = contour.path, .contour = contour.index, .time = segment.time + local };
    }

    fn owns(self: *const Sources, index: usize, local: f64) bool {
        if (local != 1) return true;
        const contour = self.contours.items[self.segments.items[index].contour];
        // Half-open segment domains give a shared node to its outgoing
        // segment at t=0. A closed seam belongs to the first segment; only an
        // open final endpoint retains t=1. No spatial/time epsilon is involved.
        return !contour.closed and index + 1 == contour.first + contour.count;
    }

    /// The two rays leaving this source position, towards the past/future.
    /// At a node they come from its incident segments, including a closed seam.
    fn rays(self: *const Sources, index: usize, local: f64) ![2]g.Point {
        const segment = self.segments.items[index];
        if (local > 0 and local < 1) {
            const unit = try direction(segment.curve, local);
            return .{ unit.scale(-1), unit };
        }
        const contour = self.contours.items[segment.contour];
        const end = contour.first + contour.count;
        const before = if (local == 1) index else if (index > contour.first) index - 1 else if (contour.closed) end - 1 else return error.NonTransverseCrossing;
        const after = if (local == 0) index else if (index + 1 < end) index + 1 else if (contour.closed) contour.first else return error.NonTransverseCrossing;
        return .{ (try direction(self.segments.items[before].curve, 1)).scale(-1), try direction(self.segments.items[after].curve, 0) };
    }
};

fn consume(remaining: *usize, count: usize) error{GeometryWorkLimit}!void {
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
            if (try selfIntersection(first.curve, options.tolerance)) |hit|
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
fn pairIntersections(allocator: Allocator, first: Segment, second: Segment) !Intersections {
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

fn rejectCoincidence(allocator: Allocator, first: Segment, second: Segment) !void {
    if (std.meta.eql(first.curve, second.curve) or std.meta.eql(first.curve, second.curve.reversed())) return error.CoincidentCurves;
    if (!first.cubic and !second.cubic) {
        // Reuse the source line query's collinear-interval predicate. Native
        // approximate coincidence alone cannot prove overlapping support.
        const proof = Path.intersectLineCubic(allocator, first.curve.p0, first.curve.p3, second.curve) catch |err| switch (err) {
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

const endpoint_roundoff = 16 * std.math.floatEps(f64);
fn canonicalTime(time: f64) f64 {
    if (@abs(time) <= endpoint_roundoff) return 0;
    if (@abs(1 - time) <= endpoint_roundoff) return 1;
    return time;
}

/// Endpoint ownership uses a machine-rounding convention, never the user's
/// spatial tolerance as a parameter epsilon. Snapping is allowed only when
/// the two curves still meet the original spatial residual bound. Distinct
/// roots that this convention would collapse are diagnosed by the callers.
fn canonicalHit(first: g.Cubic, second: g.Cubic, hit: Path.Intersection, tolerance: f64) Path.Intersection {
    const a = canonicalTime(hit.a);
    const b = canonicalTime(hit.b);
    if (a == hit.a and b == hit.b) return hit;
    const one = first.at(a);
    const two = second.at(b);
    if (!one.isFinite() or !two.isFinite() or one.distance(two) > tolerance) return hit;
    return .{ .point = one.lerp(two, 0.5), .a = a, .b = b };
}

fn append(allocator: Allocator, result: *std.ArrayList(Crossing), source: *const Sources, first_index: usize, second_index: usize, hit: Path.Intersection, options: Options, remaining: *usize) !void {
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

fn direction(curve: g.Cubic, time: f64) !g.Point {
    return curve.derivative(time).normalized() catch |err| return if (err == error.NonFinite) error.ResolutionLimit else error.NonTransverseCrossing;
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

/// Translate before normalizing so a large common origin does not erase the
/// polynomial's small differences. The scaled fallback also handles opposite
/// finite controls whose direct subtraction would overflow.
fn relativeCurve(curve: g.Cubic) struct { curve: g.Cubic, scale: f64 } {
    const controls = [_]g.Point{ curve.p0, curve.p1, curve.p2, curve.p3 };
    var points: [4]g.Point = undefined;
    var finite = true;
    for (controls, &points) |point, *out| {
        out.* = point.sub(curve.p0);
        finite = finite and out.isFinite();
    }
    var scale: f64 = 0;
    if (!finite) {
        for (controls) |point| scale = @max(scale, @max(@abs(point.x), @abs(point.y)));
        const origin: g.Point = .{ .x = curve.p0.x / scale, .y = curve.p0.y / scale };
        for (controls, &points) |point, *out| out.* = (g.Point{ .x = point.x / scale, .y = point.y / scale }).sub(origin);
    } else {
        for (points) |point| scale = @max(scale, @max(@abs(point.x), @abs(point.y)));
        if (scale != 0) {
            for (&points) |*point| point.* = .{ .x = point.x / scale, .y = point.y / scale };
        }
    }
    return .{ .curve = .{ .p0 = points[0], .p1 = points[1], .p2 = points[2], .p3 = points[3] }, .scale = scale };
}

/// For C(t)=A*t^3+B*t^2+C*t+D, divide C(u)-C(v) by u-v.
/// Solve A*Q+B*S=-C, where S=u+v and Q=u²+uv+v², then uv=S²-Q.
fn selfIntersection(curve: g.Cubic, tolerance: f64) !?Path.Intersection {
    const normalized = relativeCurve(curve);
    if (normalized.scale == 0) return null;
    const p = normalized.curve;
    const c = p.p1.scale(3);
    const b = p.p2.sub(p.p1.scale(2)).scale(3);
    const a = p.p3.sub(p.p2.scale(3)).add(c);
    const determinant = a.cross(b);
    if (determinant == 0) {
        if (a.cross(c) != 0 or b.cross(c) != 0) return null;
        // A collinear cubic may retrace an interval. Detect derivative sign
        // changes with the same quadratic helper rather than sampling geometry.
        const x = @max(@abs(a.x), @max(@abs(b.x), @abs(c.x))) >= @max(@abs(a.y), @max(@abs(b.y), @abs(c.y)));
        const aa = if (x) a.x else a.y;
        const bb = if (x) b.x else b.y;
        const cc = if (x) c.x else c.y;
        var critical: [2]f64 = undefined;
        const count = g.quadraticRoots(3 * aa, 2 * bb, cc, &critical);
        var previous: f64 = 0;
        var previous_direction: f64 = 0;
        for (0..count + 1) |index| {
            const end = if (index == count) @as(f64, 1) else critical[index];
            if (end <= previous or end > 1) continue;
            const t = (previous + end) / 2;
            const value = (3 * aa * t + 2 * bb) * t + cc;
            if (value * previous_direction < 0) return error.CoincidentCurves;
            if (value != 0) previous_direction = value;
            previous = end;
        }
        return null;
    }
    const uncertainty = 8 * std.math.floatEps(f64) * (@abs(a.x * b.y) + @abs(a.y * b.x));
    if (@abs(determinant) <= uncertainty) return error.ResolutionLimit;
    const sum = c.cross(a) / determinant;
    const q = b.cross(c) / determinant;
    if (!std.math.isFinite(sum) or !std.math.isFinite(q)) return error.ResolutionLimit;
    if (sum < 0 or sum > 2) return null;
    var roots: [2]f64 = undefined;
    const count = g.quadraticRoots(1, -sum, sum * sum - q, &roots);
    if (count == 0) return null;
    if (count == 1) {
        if (roots[0] >= 0 and roots[0] <= 1) return error.NonTransverseCrossing;
        return null;
    }
    if (roots[0] < -endpoint_roundoff or roots[1] > 1 + endpoint_roundoff) return null;
    const one = curve.at(roots[0]);
    const two = curve.at(roots[1]);
    if (!one.isFinite() or !two.isFinite() or one.distance(two) > tolerance) return error.ResolutionLimit;
    const hit = canonicalHit(curve, curve, .{ .point = one.lerp(two, 0.5), .a = roots[0], .b = roots[1] }, tolerance);
    if (hit.a == hit.b) return error.ResolutionLimit;
    if (hit.a < 0 or hit.b > 1) return null;
    if (p.at(hit.a).distance(p.at(hit.b)) > tolerance / normalized.scale) return error.ResolutionLimit;
    return hit;
}

const loop: g.Cubic = .{
    .p0 = .zero,
    .p1 = .{ .x = -13, .y = -16 },
    .p2 = .{ .x = -26, .y = -16 },
    .p3 = .{ .x = 9, .y = 0 },
};

test "crossings power-basis cubic self intersection has independently known roots" {
    // C(t)=(48t³-39t,48t²-48t). Distinct parameters 1/4 and 3/4
    // both give (-9,-9); neither is a curve endpoint or midpoint.
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{loop}, false);
    defer path.deinit();
    const events = try find(allocator, &.{path}, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const event = events[0];
    try std.testing.expectEqual(@as(usize, 0), event.first.path);
    try std.testing.expectEqual(@as(usize, 0), event.first.contour);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), event.first.time, 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), event.second.time, 1e-13);
    try std.testing.expect(event.point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);
    try std.testing.expect((try path.pointAt(event.first.time)).distance(event.point) <= 1e-9);
    try std.testing.expect((try path.pointAt(event.second.time)).distance(event.point) <= 1e-9);
}

test "crossings retain adjacent-segment interior roots after a cubic split" {
    const allocator = std.testing.allocator;
    const halves = loop.split(0.5);
    var path = try Path.fromCubics(allocator, &.{ halves.left, halves.right }, false);
    defer path.deinit();
    const events = try find(allocator, &.{path}, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), events[0].first.time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), events[0].second.time, 1e-9);
    try std.testing.expect(events[0].point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);

    // Put each crossing passage exactly on an internal source node. A node's
    // outgoing segment owns it, so no duplicated incident-segment roots leak.
    const first = loop.split(0.25);
    const rest = first.right.split(2.0 / 3.0);
    var nodes = try Path.fromCubics(allocator, &.{ first.left, rest.left, rest.right }, false);
    defer nodes.deinit();
    const at_nodes = try find(allocator, &.{nodes}, .{ .tolerance = 1e-9 });
    defer allocator.free(at_nodes);
    try std.testing.expectEqual(@as(usize, 1), at_nodes.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), at_nodes[0].first.time, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), at_nodes[0].second.time, 1e-9);
    try std.testing.expect(at_nodes[0].point.distance(.{ .x = -9, .y = -9 }) <= 1e-9);
}

test "crossings retain cubic source roots under a large common origin" {
    const allocator = std.testing.allocator;
    const origin: g.Point = .{ .x = 1e9, .y = -1e9 };
    var path = try Path.fromCubics(allocator, &.{loop.transformed(.translation(origin.x, origin.y))}, false);
    defer path.deinit();
    const events = try find(allocator, &.{path}, .{ .tolerance = 1e-6 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), events[0].first.time, 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), events[0].second.time, 1e-13);
    try std.testing.expect(events[0].point.distance(origin.add(.{ .x = -9, .y = -9 })) <= 1e-6);
}

test "crossings preserve source parameters under spatial scaling and reflection" {
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{loop}, false);
    defer path.deinit();
    for ([_]f64{ 1e-12, 1e12 }) |scale| for ([_]f64{ -1, 1 }) |sign| {
        const transform = g.Transform.scaling(sign * scale, scale);
        var mapped = try path.transformed(allocator, transform);
        defer mapped.deinit();
        const tolerance = scale * 1e-9;
        const events = try find(allocator, &.{mapped}, .{ .tolerance = tolerance });
        defer allocator.free(events);
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectApproxEqAbs(@as(f64, 0.25), events[0].first.time, 1e-13);
        try std.testing.expectApproxEqAbs(@as(f64, 0.75), events[0].second.time, 1e-13);
        try std.testing.expect(events[0].point.distance(transform.apply(.{ .x = -9, .y = -9 })) <= tolerance);
    };
}

test "crossings endpoint convention diagnoses collapsed roots and leaves later roots intact" {
    const allocator = std.testing.allocator;
    const Fixture = struct {
        fn curve(first: f64, second: f64) g.Cubic {
            // A=(1,0), B=(0,1), C=(-Q,-S): both coordinates agree at
            // the prescribed distinct roots, without relying on find itself.
            const s = first + second;
            const q = first * first + first * second + second * second;
            return .{ .p0 = .zero, .p1 = .{ .x = -q / 3, .y = -s / 3 }, .p2 = .{ .x = -2 * q / 3, .y = (1 - 2 * s) / 3 }, .p3 = .{ .x = 1 - q, .y = 1 - s } };
        }
    };
    const close = Fixture.curve(1e-16, 2e-16);
    try std.testing.expect(close.at(1e-16).distance(close.at(2e-16)) < 1e-45);
    var unresolved = try Path.fromCubics(allocator, &.{close}, false);
    defer unresolved.deinit();
    try std.testing.expectError(error.ResolutionLimit, find(allocator, &.{unresolved}, .{ .tolerance = 1e-25 }));
    const first: f64 = 1e-9;
    const second: f64 = 0.75;
    var resolved = try Path.fromCubics(allocator, &.{Fixture.curve(first, second)}, false);
    defer resolved.deinit();
    const events = try find(allocator, &.{resolved}, .{ .tolerance = 1e-12 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].first.time > endpoint_roundoff);
    try std.testing.expectApproxEqAbs(first, events[0].first.time, 1e-16);
    try std.testing.expectApproxEqAbs(second, events[0].second.time, 1e-14);
}

test "crossings batch order and same-position branches retain path and contour provenance" {
    const allocator = std.testing.allocator;
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -3, .y = 0 });
    try horizontal.lineTo(.{ .x = 3, .y = 0 });
    var later = Path.init(allocator);
    defer later.deinit();
    try later.moveTo(.{ .x = 1, .y = -2 });
    try later.lineTo(.{ .x = 1, .y = 2 });
    var earlier = Path.init(allocator);
    defer earlier.deinit();
    try earlier.moveTo(.{ .x = -1, .y = -2 });
    try earlier.lineTo(.{ .x = -1, .y = 2 });
    const events = try find(allocator, &.{ horizontal, later, earlier }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(usize, 2), events[0].second.path);
    try std.testing.expectEqual(@as(usize, 1), events[1].second.path);
    try std.testing.expect(events[0].first.time < events[1].first.time);
    for (events) |event| {
        try std.testing.expectEqual(@as(usize, 0), event.first.path);
        try std.testing.expectEqual(@as(usize, 0), event.first.contour);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), event.second.time, 1e-14);
    }
    var crossed = Path.init(allocator);
    defer crossed.deinit();
    try crossed.moveTo(.{ .x = 100, .y = 100 });
    try crossed.moveTo(.{ .x = -1, .y = -1 });
    try crossed.lineTo(.{ .x = 1, .y = 1 });
    try crossed.moveTo(.{ .x = -1, .y = 1 });
    try crossed.lineTo(.{ .x = 1, .y = -1 });
    const self = try find(allocator, &.{crossed}, .{ .tolerance = 1e-9 });
    defer allocator.free(self);
    try std.testing.expectEqual(@as(usize, 1), self.len);
    try std.testing.expectEqual(@as(usize, 1), self[0].first.contour);
    try std.testing.expectEqual(@as(usize, 2), self[0].second.contour);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), self[0].first.time, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), self[0].second.time, 1e-14);
}

test "crossings exclude only ordinary closed nodes and canonicalize a queried seam" {
    const allocator = std.testing.allocator;
    var square = Path.init(allocator);
    defer square.deinit();
    try square.moveTo(.zero);
    try square.lineTo(.{ .x = 4, .y = 0 });
    try square.lineTo(.{ .x = 4, .y = 4 });
    try square.lineTo(.{ .x = 0, .y = 4 });
    try square.close();
    const none = try find(allocator, &.{square}, .{ .tolerance = 1e-9 });
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var circle = try Path.circle(allocator, .zero, 4);
    defer circle.deinit();
    const rounded = try find(allocator, &.{circle}, .{ .tolerance = 1e-9 });
    defer allocator.free(rounded);
    try std.testing.expectEqual(@as(usize, 0), rounded.len);
    var seam = Path.init(allocator);
    defer seam.deinit();
    try seam.moveTo(.{ .x = -1, .y = -1 });
    try seam.lineTo(.{ .x = 1, .y = 1 });
    const events = try find(allocator, &.{ square, seam }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(f64, 0), events[0].first.time);
    try std.testing.expectEqual(@as(f64, 0.5), events[0].second.time);
}

test "crossings closed three cubic trefoil excludes its ordinary smooth nodes" {
    const allocator = std.testing.allocator;
    const root_three = @sqrt(@as(f64, 3));
    for ([_]f64{ 1, 72.0 / 25.4 }) |scale| {
        const p0: g.Point = .{ .x = 0, .y = 40 * scale };
        const p1: g.Point = .{ .x = -root_three * 20 * scale, .y = -20 * scale };
        const p2: g.Point = .{ .x = root_three * 20 * scale, .y = -20 * scale };
        const x = 22 * scale;
        const y = root_three * 22 * scale;
        var path = try Path.fromCubics(allocator, &.{
            .{ .p0 = p0, .p1 = p0.add(.{ .x = 44 * scale, .y = 0 }), .p2 = p1.add(.{ .x = x, .y = -y }), .p3 = p1 },
            .{ .p0 = p1, .p1 = p1.add(.{ .x = -x, .y = y }), .p2 = p2.add(.{ .x = x, .y = y }), .p3 = p2 },
            .{ .p0 = p2, .p1 = p2.add(.{ .x = -x, .y = -y }), .p2 = p0.add(.{ .x = -44 * scale, .y = 0 }), .p3 = p0 },
        }, true);
        defer path.deinit();
        const events = try find(allocator, &.{path}, .{});
        defer allocator.free(events);
        try std.testing.expectEqual(@as(usize, 3), events.len);
        const Visit = struct { time: f64, id: usize };
        var visits: [6]Visit = undefined;
        for (events, 0..) |event, index| {
            visits[2 * index] = .{ .time = event.first.time, .id = index + 1 };
            visits[2 * index + 1] = .{ .time = event.second.time, .id = index + 1 };
        }
        std.mem.sort(Visit, &visits, {}, struct {
            fn less(_: void, first: Visit, second: Visit) bool {
                return first.time < second.time;
            }
        }.less);
        for (visits, [_]usize{ 1, 2, 3, 1, 2, 3 }) |visit, id| try std.testing.expectEqual(id, visit.id);
        for (events) |event| {
            try std.testing.expect(event.first.time != @floor(event.first.time));
            try std.testing.expect(event.second.time != @floor(event.second.time));
        }
    }
}

test "crossings retain a real crossing close to an adjacent source node" {
    const allocator = std.testing.allocator;
    const split_time = 0.25 + 1e-9;
    const pieces = loop.split(split_time);
    var path = try Path.fromCubics(allocator, &.{ pieces.left, pieces.right }, false);
    defer path.deinit();
    const events = try find(allocator, &.{path}, .{ .tolerance = 1e-12 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].first.time < 1);
    try std.testing.expectApproxEqAbs(0.25 / split_time, events[0].first.time, 1e-13);
    try std.testing.expectApproxEqAbs(1 + (0.75 - split_time) / (1 - split_time), events[0].second.time, 1e-13);
}

test "crossings diagnose unresolved unique near-end observations" {
    const a = std.testing.allocator;
    var first = try Path.fromCubics(a, &.{.{
        .p0 = .{ .x = 0.6855028164095287, .y = -0.052920675614067214 },
        .p1 = .{ .x = 0.68511706257494875, .y = -0.057912611829187721 },
        .p2 = .{ .x = 0.68468439187328545, .y = -0.062891398462162851 },
        .p3 = .{ .x = 0.68420524464335863, .y = -0.067856595174174528 },
    }}, false);
    defer first.deinit();
    var second = try Path.fromCubics(a, &.{.{
        .p0 = .{ .x = 0.68430475604368124, .y = -0.066845930293522704 },
        .p1 = .{ .x = 0.68375286442238825, .y = -0.072488543101240532 },
        .p2 = .{ .x = 0.68314094325928587, .y = -0.078113553109506295 },
        .p3 = .{ .x = 0.68246963955255446, .y = -0.083720313320140294 },
    }}, false);
    defer second.deinit();
    try std.testing.expectError(error.ResolutionLimit, find(a, &.{ first, second }, .{}));
}

test "crossings distinguish a small loop crossing from its shared source node" {
    const allocator = std.testing.allocator;
    const delta: f64 = 1e-6;
    const q = 0.75 + delta * delta;
    const curve: g.Cubic = .{ .p0 = .zero, .p1 = .{ .x = -q / 3, .y = -1.0 / 3.0 }, .p2 = .{ .x = -2 * q / 3, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1 - q, .y = 0 } };
    const pieces = curve.split(0.5);
    var path = try Path.fromCubics(allocator, &.{ pieces.left, pieces.right }, false);
    defer path.deinit();
    try std.testing.expectError(error.ResolutionLimit, find(allocator, &.{path}, .{ .tolerance = 1e-18 }));
}

test "crossings diagnose tangency multiway contacts and exact overlapping support" {
    const allocator = std.testing.allocator;
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -2, .y = 0 });
    try horizontal.lineTo(.{ .x = 2, .y = 0 });
    var tangent = try Path.fromCubics(allocator, &.{.{ .p0 = .{ .x = -1, .y = 1 }, .p1 = .{ .x = -1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } }}, false);
    defer tangent.deinit();
    try std.testing.expectError(error.NonTransverseCrossing, find(allocator, &.{ horizontal, tangent }, .{ .tolerance = 1e-9 }));
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 0, .y = -2 });
    try vertical.lineTo(.{ .x = 0, .y = 2 });
    var diagonal = Path.init(allocator);
    defer diagonal.deinit();
    try diagonal.moveTo(.{ .x = -2, .y = -2 });
    try diagonal.lineTo(.{ .x = 2, .y = 2 });
    try std.testing.expectError(error.MultipleCrossing, find(allocator, &.{ horizontal, vertical, diagonal }, .{ .tolerance = 1e-9 }));
    try std.testing.expectError(error.CoincidentCurves, find(allocator, &.{ horizontal, horizontal }, .{ .tolerance = 1e-9 }));
    const retraced: g.Cubic = .{ .p0 = .{ .x = -1, .y = 0 }, .p1 = .{ .x = 2, .y = 0 }, .p2 = .{ .x = -2, .y = 0 }, .p3 = .{ .x = 1, .y = 0 } };
    var folded = try Path.fromCubics(allocator, &.{retraced}, false);
    defer folded.deinit();
    try std.testing.expectError(error.CoincidentCurves, find(allocator, &.{folded}, .{ .tolerance = 1e-9 }));
}

test "crossings classify all incident rays at a corner and reject terminal contacts" {
    const allocator = std.testing.allocator;
    var corner = Path.init(allocator);
    defer corner.deinit();
    try corner.moveTo(.{ .x = -2, .y = 0 });
    try corner.lineTo(.zero);
    try corner.lineTo(.{ .x = 0, .y = 2 });
    var touching = Path.init(allocator);
    defer touching.deinit();
    try touching.moveTo(.{ .x = -2, .y = -2 });
    try touching.lineTo(.{ .x = 2, .y = 2 });
    try std.testing.expectError(error.NonTransverseCrossing, find(allocator, &.{ corner, touching }, .{}));
    var passing = Path.init(allocator);
    defer passing.deinit();
    try passing.moveTo(.{ .x = -2, .y = 2 });
    try passing.lineTo(.{ .x = 2, .y = -2 });
    const events = try find(allocator, &.{ corner, passing }, .{});
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(f64, 1), events[0].first.time);
    var terminal = Path.init(allocator);
    defer terminal.deinit();
    try terminal.moveTo(.zero);
    try terminal.lineTo(.{ .x = 2, .y = 0 });
    try std.testing.expectError(error.NonTransverseCrossing, find(allocator, &.{ terminal, passing }, .{}));
}

test "crossings budgets are aggregate and retain their exact boundaries" {
    const allocator = std.testing.allocator;
    var path = try Path.fromCubics(allocator, &.{loop}, false);
    defer path.deinit();
    const events = try find(allocator, &.{path}, .{ .max_source_items = 3, .max_comparisons = 1, .max_events = 1 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{path}, .{ .max_source_items = 2 }));
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{path}, .{ .max_comparisons = 0 }));
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{path}, .{ .max_events = 0 }));
    var second = try Path.fromCubics(allocator, &.{.{ .p0 = .{ .x = 100, .y = 0 }, .p1 = .{ .x = 87, .y = -16 }, .p2 = .{ .x = 74, .y = -16 }, .p3 = .{ .x = 109, .y = 0 } }}, false);
    defer second.deinit();
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{ path, second }, .{ .max_source_items = 5 }));
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{ path, second }, .{ .max_comparisons = 2 }));
    try std.testing.expectError(error.GeometryWorkLimit, find(allocator, &.{ path, second }, .{ .max_events = 1 }));
    const pair = try find(allocator, &.{ path, second }, .{ .max_source_items = 6, .max_comparisons = 4, .max_events = 2 });
    defer allocator.free(pair);
    try std.testing.expectEqual(@as(usize, 2), pair.len);
}

test "crossings keep injective quadratic and straight cubic inputs empty" {
    const allocator = std.testing.allocator;
    var arc = try Path.fromCubics(allocator, &.{.{ .p0 = .zero, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 2, .y = 0 } }}, false);
    defer arc.deinit();
    const none = try find(allocator, &.{arc}, .{ .tolerance = 1e-9 });
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    var line = try Path.fromCubics(allocator, &.{g.Cubic.line(.{ .x = -1, .y = -1 }, .{ .x = 1, .y = 1 })}, false);
    defer line.deinit();
    const straight = try find(allocator, &.{line}, .{ .tolerance = 1e-9 });
    defer allocator.free(straight);
    try std.testing.expectEqual(@as(usize, 0), straight.len);
    try std.testing.expectError(error.InvalidTolerance, find(allocator, &.{line}, .{ .tolerance = 0 }));
}

fn allocationExercise(allocator: Allocator) !void {
    var path = try Path.fromCubics(allocator, &.{loop}, false);
    defer path.deinit();
    var other = Path.init(allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 20, .y = -2 });
    try other.lineTo(.{ .x = 20, .y = 2 });
    const events = try find(allocator, &.{ path, other }, .{ .tolerance = 1e-9 });
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
}
test "crossings release source indexes root hits and events at every allocation failure" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}
