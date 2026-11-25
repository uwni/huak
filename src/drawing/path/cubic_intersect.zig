//! Line/cubic and cubic/cubic intersection with parameters on both curves; no path involved.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const cubic_roots = @import("cubic_roots.zig");
const cubicRootsUnit = cubic_roots.cubicRootsUnit;
const bezierPolynomial = cubic_roots.bezierPolynomial;

pub const Intersection = struct { point: Point, a: f64, b: f64 };

/// Intersections with a finite line segment. a is line parameter; b is cubic
/// parameter. A line-point is rejected explicitly. Collinear overlap is an
/// explicit error, since it has infinitely many intersections.
pub fn intersectLineCubic(allocator: std.mem.Allocator, start: Point, end: Point, curve: Cubic) ![]Intersection {
    return intersectLineCubicTolerance(allocator, start, end, curve, null);
}

fn intersectLineCubicTolerance(allocator: std.mem.Allocator, start: Point, end: Point, curve: Cubic, tolerance: ?f64) ![]Intersection {
    if (!start.isFinite() or !end.isFinite() or !curve.isFinite()) return error.NonFinite;
    const direction = end.sub(start);
    const unit = direction.normalized() catch |err| return switch (err) {
        error.ZeroVector => error.DegenerateLine,
        error.NonFinite => error.NonFinite,
    };
    const length = direction.norm();
    if (!std.math.isFinite(length)) return error.NonFinite;
    if (pointCurve(curve)) {
        const u = lineParameter(curve.p0, start, direction);
        if (u >= 0 and u <= 1 and curve.p0.distance(start.lerp(end, u)) <= (tolerance orelse 1e-12)) {
            return allocator.dupe(Intersection, &.{.{ .point = curve.p0, .a = u, .b = 0 }});
        }
        return allocator.alloc(Intersection, 0);
    }
    const relative = [_]Point{ curve.p0.sub(start), curve.p1.sub(start), curve.p2.sub(start), curve.p3.sub(start) };
    var relative_scale: f64 = 0;
    for (relative) |p| {
        if (!p.isFinite()) return error.NonFinite;
        relative_scale = @max(relative_scale, @max(@abs(p.x), @abs(p.y)));
    }
    const product_scale = @max(@abs(direction.x), @abs(direction.y)) * relative_scale;
    // Keep exact cancellation in ordinary collinear coordinates: normalizing
    // (3,4) to (0.6,0.8) first can introduce a spurious nonzero cross product.
    // Change the common scale only when raw cross products risk range loss.
    const cross_direction = if (std.math.isFinite(product_scale) and product_scale >= 4 * std.math.floatMin(f64) and product_scale <= std.math.floatMax(f64) / 4) direction else unit;
    const z0 = relative[0].cross(cross_direction);
    const z1 = relative[1].cross(cross_direction);
    const z2 = relative[2].cross(cross_direction);
    const z3 = relative[3].cross(cross_direction);
    for ([_]f64{ z0, z1, z2, z3 }) |z| if (!std.math.isFinite(z)) return error.NonFinite;
    var endpoint: ?f64 = null;
    // Cubic.line's rounded thirds still represent a line, as in the linear
    // shortcut below; translation can otherwise perturb their cross products.
    const collinear = z0 == 0 and z3 == 0 and ((z1 == 0 and z2 == 0) or linearCurve(curve));
    const roots = if (collinear) blk: {
        // Collinearity alone does not imply an overlapping interval. Project
        // onto line time and distinguish disjoint, endpoint-only and overlap.
        const projection: Cubic = .{
            .p0 = .{ .x = lineParameter(curve.p0, start, direction), .y = 0 },
            .p1 = .{ .x = lineParameter(curve.p1, start, direction), .y = 0 },
            .p2 = .{ .x = lineParameter(curve.p2, start, direction), .y = 0 },
            .p3 = .{ .x = lineParameter(curve.p3, start, direction), .y = 0 },
        };
        if (!projection.isFinite()) return error.NonFinite;
        const box = projection.bounds();
        const lo = @max(0, box.min.x);
        const hi = @min(1, box.max.x);
        if (lo > hi) return allocator.alloc(Intersection, 0);
        if (lo < hi) return error.CoincidentCurves;
        endpoint = lo;
        break :blk try cubicRootsUnit(allocator, bezierPolynomial(projection.p0.x, projection.p1.x, projection.p2.x, projection.p3.x, lo));
    } else try cubicRootsUnit(allocator, bezierPolynomial(z0, z1, z2, z3, 0));
    defer allocator.free(roots);
    var result: std.ArrayList(Intersection) = .empty;
    errdefer result.deinit(allocator);
    for (roots) |root| {
        var t = root;
        var point = curve.at(t);
        var u = lineParameter(point, start, direction);
        if (u < -1e-10 or u > 1 + 1e-10) continue;
        if (tolerance) |limit| {
            var iteration: usize = 0;
            while (point.distance(start.lerp(end, std.math.clamp(u, 0, 1))) > limit and iteration < 20) : (iteration += 1) {
                const derivative = curve.derivative(t);
                const value = if (endpoint) |e| point.sub(start.lerp(end, e)).dot(unit) else point.sub(start).cross(unit);
                const slope = if (endpoint != null) derivative.dot(unit) else derivative.cross(unit);
                if (slope == 0 or !std.math.isFinite(slope)) break;
                const next = std.math.clamp(t - value / slope, 0, 1);
                if (next == t or !std.math.isFinite(next)) break;
                t = next;
                point = curve.at(t);
                u = lineParameter(point, start, direction);
            }
            // A normalized polynomial residual is not a spatial guarantee.
            // Ill-conditioned contacts that cannot meet the requested bound
            // are reported instead of returning an out-of-tolerance point.
            if (!point.isFinite() or !std.math.isFinite(u) or point.distance(start.lerp(end, std.math.clamp(u, 0, 1))) > limit) return error.ResolutionLimit;
        }
        try result.append(allocator, .{ .point = point, .a = std.math.clamp(u, 0, 1), .b = t });
    }
    return result.toOwnedSlice(allocator);
}

fn lineParameter(point: Point, start: Point, direction: Point) f64 {
    // The dominant coordinate avoids squared-length overflow/underflow and
    // retains exact endpoint times, including oblique integer-valued lines.
    return if (@abs(direction.x) >= @abs(direction.y)) (point.x - start.x) / direction.x else (point.y - start.y) / direction.y;
}

fn sameCurve(a: Cubic, b: Cubic) bool {
    return a.p0.eql(b.p0) and a.p1.eql(b.p1) and a.p2.eql(b.p2) and a.p3.eql(b.p3);
}

fn pointCurve(curve: Cubic) bool {
    return curve.p0.eql(curve.p1) and curve.p0.eql(curve.p2) and curve.p0.eql(curve.p3);
}

fn linearCurve(curve: Cubic) bool {
    const line = Cubic.line(curve.p0, curve.p3);
    return curve.p1.eql(line.p1) and curve.p2.eql(line.p2);
}

fn appendIntersection(result: *std.ArrayList(Intersection), allocator: std.mem.Allocator, hit: Intersection, tolerance: f64) !void {
    for (result.items) |*old| {
        if (@abs(old.a - hit.a) < 2e-8 and @abs(old.b - hit.b) < 2e-8 and old.point.distance(hit.point) <= 4 * tolerance) {
            if (hit.point.isFinite()) old.* = hit;
            return;
        }
    }
    try result.append(allocator, hit);
}

/// Bounded subdivision of exact control hulls followed by Newton refinement.
/// tolerance is a spatial residual bound; it must be positive and finite.
/// The explicit work limit diagnoses unresolved/coincident configurations.
pub fn intersectCubics(allocator: std.mem.Allocator, a: Cubic, b: Cubic, tolerance: f64) ![]Intersection {
    if (!a.isFinite() or !b.isFinite() or !std.math.isFinite(tolerance) or tolerance <= 0) return error.NonFinite;
    if (pointCurve(a) and pointCurve(b)) {
        if (a.p0.distance(b.p0) > tolerance) return allocator.alloc(Intersection, 0);
        return allocator.dupe(Intersection, &.{.{ .point = a.p0.lerp(b.p0, 0.5), .a = 0, .b = 0 }});
    }
    if (sameCurve(a, b) or sameCurve(a, b.reversed())) return error.CoincidentCurves;
    if (linearCurve(a) and a.p0.distance(a.p3) != 0) return intersectLineCubicTolerance(allocator, a.p0, a.p3, b, tolerance);
    if (linearCurve(b) and b.p0.distance(b.p3) != 0) {
        const hits = try intersectLineCubicTolerance(allocator, b.p0, b.p3, a, tolerance);
        for (hits) |*hit| std.mem.swap(f64, &hit.a, &hit.b);
        return hits;
    }
    const Node = struct { a: Cubic, b: Cubic, a0: f64 = 0, a1: f64 = 1, b0: f64 = 0, b1: f64 = 1, depth: usize = 0 };
    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .a = a, .b = b });
    var result: std.ArrayList(Intersection) = .empty;
    errdefer result.deinit(allocator);
    var work: usize = 0;
    while (stack.pop()) |node| {
        work += 1;
        if (work > 200000) return error.ResolutionLimit;
        const ab = node.a.controlBounds();
        const bb = node.b.controlBounds();
        if (!ab.overlaps(bb, tolerance * 0.01)) continue;
        const extent_a = @max(ab.width(), ab.height());
        const extent_b = @max(bb.width(), bb.height());
        if ((extent_a <= tolerance * 0.1 and extent_b <= tolerance * 0.1) or node.depth >= 72) {
            var u = (node.a0 + node.a1) * 0.5;
            var v = (node.b0 + node.b1) * 0.5;
            var iteration: usize = 0;
            while (iteration < 40) : (iteration += 1) {
                const difference = a.at(u).sub(b.at(v));
                const da = a.derivative(u);
                const db = b.derivative(v);
                const det = da.cross(db);
                if (@abs(det) < 1e-24) break;
                const du = difference.cross(db) / det;
                const dv = difference.cross(da) / det;
                var damping: f64 = 1;
                var next_u = std.math.clamp(u - du, 0, 1);
                var next_v = std.math.clamp(v - dv, 0, 1);
                while (damping > 1e-8 and a.at(next_u).distance(b.at(next_v)) > difference.norm()) {
                    damping *= 0.5;
                    next_u = std.math.clamp(u - damping * du, 0, 1);
                    next_v = std.math.clamp(v - damping * dv, 0, 1);
                }
                if (a.at(next_u).distance(b.at(next_v)) > difference.norm()) break;
                if (@abs(next_u - u) + @abs(next_v - v) < 1e-15) break;
                u = next_u;
                v = next_v;
            }
            const pa = a.at(u);
            const pb = b.at(v);
            if (pa.distance(pb) <= tolerance) {
                try appendIntersection(&result, allocator, .{ .point = pa.lerp(pb, 0.5), .a = u, .b = v }, tolerance);
            } else if (node.depth >= 72) return error.ResolutionLimit;
            continue;
        }
        if (extent_a >= extent_b) {
            const split = node.a.split(0.5);
            const mid = (node.a0 + node.a1) * 0.5;
            try stack.append(allocator, .{ .a = split.right, .b = node.b, .a0 = mid, .a1 = node.a1, .b0 = node.b0, .b1 = node.b1, .depth = node.depth + 1 });
            try stack.append(allocator, .{ .a = split.left, .b = node.b, .a0 = node.a0, .a1 = mid, .b0 = node.b0, .b1 = node.b1, .depth = node.depth + 1 });
        } else {
            const split = node.b.split(0.5);
            const mid = (node.b0 + node.b1) * 0.5;
            try stack.append(allocator, .{ .a = node.a, .b = split.right, .a0 = node.a0, .a1 = node.a1, .b0 = mid, .b1 = node.b1, .depth = node.depth + 1 });
            try stack.append(allocator, .{ .a = node.a, .b = split.left, .a0 = node.a0, .a1 = node.a1, .b0 = node.b0, .b1 = mid, .depth = node.depth + 1 });
        }
    }
    const Sort = struct {
        fn less(_: void, x: Intersection, y: Intersection) bool {
            return x.a < y.a;
        }
    };
    std.mem.sort(Intersection, result.items, {}, Sort.less);
    return result.toOwnedSlice(allocator);
}
