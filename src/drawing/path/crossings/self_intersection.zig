//! Cubic self-intersections eliminate the trivial u=v solution in the power
//! basis, then use the shared stable quadratic solver; see
//! https://math.stackexchange.com/questions/3776840 (Parcly Taxel, 2021).
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../Path.zig");

pub const endpoint_roundoff = 16 * std.math.floatEps(f64);

fn canonicalTime(time: f64) f64 {
    if (@abs(time) <= endpoint_roundoff) return 0;
    if (@abs(1 - time) <= endpoint_roundoff) return 1;
    return time;
}

/// Endpoint ownership uses a machine-rounding convention, never the user's
/// spatial tolerance as a parameter epsilon. Snapping is allowed only when
/// the two curves still meet the original spatial residual bound. Distinct
/// roots that this convention would collapse are diagnosed by the callers.
fn canonicalHit(first: g.Cubic, second: g.Cubic, hit: Path.cubic_intersect.Intersection, tolerance: f64) Path.cubic_intersect.Intersection {
    const a = canonicalTime(hit.a);
    const b = canonicalTime(hit.b);
    if (a == hit.a and b == hit.b) return hit;
    const one = first.at(a);
    const two = second.at(b);
    if (!one.isFinite() or !two.isFinite() or one.distance(two) > tolerance) return hit;
    return .{ .point = one.lerp(two, 0.5), .a = a, .b = b };
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
pub fn selfIntersection(curve: g.Cubic, tolerance: f64) !?Path.cubic_intersect.Intersection {
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
