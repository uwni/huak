// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
//! Fat-line clipping: the recursive search of a curve pair by clipping each against the other's fat line, within call and depth limits.
const std = @import("std");
const types = @import("../types.zig");
const geometry = @import("../../../geometry.zig");
const curve = @import("../curve.zig");
const Cubic = geometry.Cubic;
const Point = types.Point;
const Source = types.Source;
const intersections = @import("../intersections.zig");
const implicit_form = @import("implicit.zig");
const lines = @import("lines.zig");
const Builder = intersections.Builder;
const BaselineDistance = lines.BaselineDistance;

const CurveError = std.mem.Allocator.Error || error{GeometryWorkLimit};

/// Fat-line clipping stops after this many calls in all, or this deep in one
/// branch, as upstream does to avoid massive call trees (paper.js #904).
/// Upstream then keeps what it found; here incomplete work is an error.
const max_clipping_calls = 4096;

const max_clipping_depth = 40;

/// The curve-time precision at which fat-line clipping stops: upstream's
/// fatLineEpsilon, smaller than CURVETIME_EPSILON.
const fat_line_epsilon = 1e-9;

/// A clip that keeps more than this share of a curve's interval has made too
/// little progress. As upstream, the neighbouring-end and implicit-form cases
/// are tried, and otherwise the curve that has converged least is split.
const slow_clip = 0.8;

pub fn addCurveIntersections(self: *Builder, first: Cubic, second: Cubic, c1: usize, c2: usize, flip: bool, depth: usize, calls: *usize, t_min: f64, t_max: f64, u_min_input: f64, u_max_input: f64) CurveError!void {
    calls.* += 1;
    const recursion = depth + 1;
    if (calls.* >= max_clipping_calls or recursion >= max_clipping_depth) return error.GeometryWorkLimit;
    var a = first;
    var b = second;
    var u_min = u_min_input;
    var u_max = u_max_input;
    const baseline: BaselineDistance = .init(b.p0.x, b.p0.y, b.p3.x - b.p0.x, b.p3.y - b.p0.y);
    const d1 = baseline.at(b.p1.x, b.p1.y);
    const d2 = baseline.at(b.p2.x, b.p2.y);
    const factor: f64 = if (d1 * d2 > 0) 3.0 / 4.0 else 4.0 / 9.0;
    const d_min = factor * @min(0, d1, d2);
    const d_max = factor * @max(0, d1, d2);
    var dp: [4]f64 = undefined;
    inline for ([_]Point{ a.p0, a.p1, a.p2, a.p3 }, 0..) |p, i| {
        dp[i] = baseline.at(p.x, p.y);
    }
    if (d1 == 0 and d2 == 0 and dp[0] == 0 and dp[1] == 0 and dp[2] == 0 and dp[3] == 0) return;
    var hull = convexHull(dp);
    const min_clip = clipHull(hull[0], hull[1], d_min, d_max) orelse return;
    hull[0].reverse();
    hull[1].reverse();
    const max_clip = clipHull(hull[0], hull[1], d_min, d_max) orelse return;
    var t_min_new = t_min + (t_max - t_min) * min_clip;
    var t_max_new = t_min + (t_max - t_min) * max_clip;
    if (@max(u_max - u_min, t_max_new - t_min_new) < fat_line_epsilon) {
        const t = (t_min_new + t_max_new) / 2;
        const u = (u_min + u_max) / 2;
        try self.addLocation(if (flip) c2 else c1, if (flip) u else t, if (flip) c1 else c2, if (flip) t else u, false);
        return;
    }
    a = curve.getPart(&a, min_clip, max_clip);
    const u_difference = u_max - u_min;
    if (max_clip - min_clip > slow_clip) {
        const is_next = t_max_new == 1 and u_min == 0 and self.sources[c1].next == c2;
        const is_previous = !is_next and t_min_new == 0 and u_max == 1 and self.sources[c2].next == c1;
        if (is_next or is_previous) {
            const offset = if (is_next) self.epsilon else -self.epsilon;
            const s1 = curve.getTimeAt(&a, -offset, null);
            const s2 = curve.getTimeAt(&b, offset, null);
            if (s1 != null and s2 != null) {
                const t = t_min_new + (t_max_new - t_min_new) * s1.?;
                const u = u_min + (u_max - u_min) * s2.?;
                if (is_next) {
                    a = curve.getPart(&a, 0, s1.?);
                    b = curve.getPart(&b, s2.?, 1);
                    t_max_new = t;
                    u_min = u;
                } else {
                    a = curve.getPart(&a, s1.?, 1);
                    b = curve.getPart(&b, 0, s2.?);
                    t_min_new = t;
                    u_max = u;
                }
                try addCurveIntersections(self, a, b, c1, c2, flip, recursion, calls, t_min_new, t_max_new, u_min, u_max);
            }
        } else if (!try implicit_form.addImplicitIntersections(self, a, b, c1, c2, flip, t_min_new, t_max_new, u_min, u_max)) {
            if (t_max_new - t_min_new > u_difference) {
                const parts = a.split(0.5);
                const t = (t_min_new + t_max_new) / 2;
                try addCurveIntersections(self, b, parts.left, c2, c1, !flip, recursion, calls, u_min, u_max, t_min_new, t);
                try addCurveIntersections(self, b, parts.right, c2, c1, !flip, recursion, calls, u_min, u_max, t, t_max_new);
            } else {
                const parts = b.split(0.5);
                const u = (u_min + u_max) / 2;
                try addCurveIntersections(self, parts.left, a, c2, c1, !flip, recursion, calls, u_min, u, t_min_new, t_max_new);
                try addCurveIntersections(self, parts.right, a, c2, c1, !flip, recursion, calls, u, u_max, t_min_new, t_max_new);
            }
        }
    } else if (u_difference == 0 or u_difference >= fat_line_epsilon) {
        try addCurveIntersections(self, b, a, c2, c1, !flip, recursion, calls, u_min, u_max, t_min_new, t_max_new);
    } else try addCurveIntersections(self, a, b, c1, c2, flip, recursion, calls, t_min_new, t_max_new, u_min, u_max);
}

const Hull = struct {
    points: [4]Point = undefined,
    len: usize,
    pub fn init(points: []const Point) Hull {
        var result: Hull = .{ .len = points.len };
        @memcpy(result.points[0..points.len], points);
        return result;
    }
    fn reverse(self: *Hull) void {
        std.mem.reverse(Point, self.points[0..self.len]);
    }
};

fn convexHull(d: [4]f64) [2]Hull {
    const p0: Point = .{ .x = 0, .y = d[0] };
    const p1: Point = .{ .x = 1.0 / 3.0, .y = d[1] };
    const p2: Point = .{ .x = 2.0 / 3.0, .y = d[2] };
    const p3: Point = .{ .x = 1, .y = d[3] };
    const dist1 = d[1] - (2 * d[0] + d[3]) / 3;
    const dist2 = d[2] - (d[0] + 2 * d[3]) / 3;
    var result: [2]Hull = undefined;
    if (dist1 * dist2 < 0) {
        result = .{ Hull.init(&.{ p0, p1, p3 }), Hull.init(&.{ p0, p2, p3 }) };
    } else {
        const ratio = dist1 / dist2;
        result = .{ if (ratio >= 2) Hull.init(&.{ p0, p1, p3 }) else if (ratio <= 0.5) Hull.init(&.{ p0, p2, p3 }) else Hull.init(&.{ p0, p1, p2, p3 }), Hull.init(&.{ p0, p3 }) };
    }
    if ((if (dist1 != 0) dist1 else dist2) < 0) std.mem.swap(Hull, &result[0], &result[1]);
    return result;
}

fn clipHull(top: Hull, bottom: Hull, minimum: f64, maximum: f64) ?f64 {
    return if (top.points[0].y < minimum) clipHullPart(top, true, minimum) else if (bottom.points[0].y > maximum) clipHullPart(bottom, false, maximum) else top.points[0].x;
}

fn clipHullPart(part: Hull, top: bool, threshold: f64) ?f64 {
    var p = part.points[0];
    for (part.points[1..part.len]) |q| {
        if (if (top) q.y >= threshold else q.y <= threshold)
            return if (q.y == threshold) q.x else p.x + (threshold - p.y) * (q.x - p.x) / (q.y - p.y);
        p = q;
    }
    return null;
}

test "paired intersections: fat-line and implicit Bernstein retain both quadratic crossings" {
    const t = std.testing;
    // x=3t in both curves, y=6t(1-t) and y=1-6t(1-t).
    // Intersections solve t(1-t)=1/12 and therefore have y=1/2.
    const sources = [_]Source{
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } }, .next = 0, .contour = 0, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1, .y = -1 }, .p2 = .{ .x = 2, .y = -1 }, .p3 = .{ .x = 3, .y = 1 } }, .next = 1, .contour = 1, .operand = 1 },
    };
    for ([_]bool{ false, true }) |implicit| {
        var builder: Builder = .{ .allocator = t.allocator, .scratch = t.allocator, .sources = &sources, .epsilon = 1e-10 };
        defer builder.deinit();
        if (implicit) {
            try t.expect(try implicit_form.addImplicitIntersections(&builder, sources[0].cubic, sources[1].cubic, 0, 1, false, 0, 1, 0, 1));
        } else {
            var calls: usize = 0;
            try addCurveIntersections(&builder, sources[0].cubic, sources[1].cubic, 0, 1, false, 0, &calls, 0, 1, 0, 1);
        }
        try t.expectEqual(@as(usize, 2), builder.events.items.len);
        for (builder.events.items, [_]f64{ (1 - @sqrt(@as(f64, 2.0 / 3.0))) / 2, (1 + @sqrt(@as(f64, 2.0 / 3.0))) / 2 }) |event, expected| {
            try t.expectApproxEqAbs(expected, event.first.location.time, 1e-9);
            try t.expectApproxEqAbs(expected, event.second.location.time, 1e-9);
            try t.expectApproxEqAbs(@as(f64, 0.5), event.point.y, 1e-9);
        }
    }
}
