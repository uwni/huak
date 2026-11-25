// Copyright 2012 Google Inc.; BSD-style license: LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
const std = @import("std");
const n = @import("numeric.zig");
const roots = @import("roots.zig");
pub const Point = @import("point.zig").Point;
pub const Bounds = @import("point.zig").Bounds;
pub const Quad = @import("curve/Quad.zig");
const axis_roots = @import("curve/axis_roots.zig");
const hull = @import("curve/hull.zig");
pub const Axis = enum { x, y };
pub fn coordinate(p: Point, axis: Axis) f64 {
    return if (axis == .x) p.x else p.y;
}
pub fn controlsWithinEndpoints(points: []const Point, axis: Axis) bool {
    const start = coordinate(points[0], axis);
    const end = coordinate(points[points.len - 1], axis);
    const low = @min(start, end);
    const high = @max(start, end);
    for (points[1 .. points.len - 1]) |point| {
        const value = coordinate(point, axis);
        if (!(low <= value and value <= high)) return false;
    }
    return true;
}
fn interpolatedLargest(a: Point, b: Point, t: f64) f64 {
    return @max((1 - t) * @max(@abs(a.x), @abs(a.y)) + t * @max(@abs(b.x), @abs(b.y)), @max(@abs(b.x - a.x), @abs(b.y - a.y)) * 0.001);
}

pub const Line = struct {
    points: [2]Point,
    pub fn ptAtT(self: Line, t: f64) Point {
        if (t == 0) return self.points[0];
        if (t == 1) return self.points[1];
        // Preserve the reference scalar expression's fused multiply-add.
        // Separate vector scale/add rounds twice and changes coincidence tests.
        return .{
            .x = @mulAdd(f64, 1 - t, self.points[0].x, t * self.points[1].x),
            .y = @mulAdd(f64, 1 - t, self.points[0].y, t * self.points[1].y),
        };
    }
    pub fn dxdyAtT(self: Line, t: f64) Point {
        _ = t;
        return self.points[1].sub(self.points[0]);
    }
    pub fn subDivide(self: Line, t1: f64, t2: f64) Line {
        return .{ .points = .{ self.ptAtT(t1), self.ptAtT(t2) } };
    }
    pub fn hullBounds(self: Line) Bounds {
        return Bounds.fromPoints(&self.points);
    }
    pub const bounds = hullBounds;
    pub fn reverse(self: Line) Line {
        return .{ .points = .{ self.points[1], self.points[0] } };
    }
    pub fn exactPoint(self: Line, p: Point) f64 {
        return if (p.eql(self.points[0])) 0 else if (p.eql(self.points[1])) 1 else -1;
    }
    pub fn nearPoint(self: Line, p: Point, unequal: ?*bool) f64 {
        const a = self.points[0];
        const b = self.points[1];
        if (a.x == b.x and !n.almostBequalUlps(p.x, a.x)) return -1;
        if (a.y == b.y and !n.almostBequalUlps(p.y, a.y)) return -1;
        const len = b.sub(a);
        const denom = len.x * len.x + len.y * len.y;
        const ab0 = p.sub(a);
        const numer = len.x * ab0.x + ab0.y * len.y;
        if (!n.between(0, numer, denom)) return -1;
        const t = if (denom != 0) numer / denom else 0;
        const dist = self.ptAtT(t).distance(p);
        const largest = interpolatedLargest(a, b, t);
        if (!n.almostEqualUlpsPin(largest, largest + dist)) return -1;
        if (unequal) |u| u.* = largest != largest + dist;
        return n.pinT(t);
    }
    pub fn horizontalIntersect(self: Line, y: f64, out: *[1]f64) usize {
        if (self.points[0].y == self.points[1].y) return 0;
        out[0] = n.pinT((y - self.points[0].y) / (self.points[1].y - self.points[0].y));
        return @intFromBool(n.between(0, out[0], 1));
    }
};

pub const Cubic = struct {
    points: [4]Point,
    pub fn ptAtT(self: Cubic, t: f64) Point {
        if (t == 0) return self.points[0];
        if (t == 1) return self.points[3];
        const s = 1 - t;
        const s2 = s * s;
        const a = s2 * s;
        const b = 3 * s2 * t;
        const t2 = t * t;
        const c = 3 * s * t2;
        const d = t2 * t;
        // Keep the reference's two-lane FMA chain after search-loop inlining.
        const V = @Vector(2, f64);
        const p0: V = .{ self.points[0].x, self.points[0].y };
        const p1: V = .{ self.points[1].x, self.points[1].y };
        const p2: V = .{ self.points[2].x, self.points[2].y };
        const p3: V = .{ self.points[3].x, self.points[3].y };
        const initial = @as(V, @splat(b)) * p1;
        const first = @mulAdd(V, @splat(a), p0, initial);
        const second = @mulAdd(V, @splat(c), p2, first);
        const result = @mulAdd(V, @splat(d), p3, second);
        return .{ .x = result[0], .y = result[1] };
    }
    fn derivative(self: Cubic, axis: Axis, t: f64) f64 {
        const s = 1 - t;
        const a = coordinate(self.points[0], axis);
        const b = coordinate(self.points[1], axis);
        const c = coordinate(self.points[2], axis);
        const d = coordinate(self.points[3], axis);
        return 3 * @mulAdd(f64, (d - c) * t, t, @mulAdd(f64, (b - a) * s, s, 2 * (c - b) * t * s));
    }
    pub fn dxdyAtT(self: Cubic, t: f64) Point {
        var result: Point = .{ .x = self.derivative(.x, t), .y = self.derivative(.y, t) };
        if (result.x == 0 and result.y == 0) {
            if (t == 0) result = self.points[2].sub(self.points[0]) else if (t == 1) result = self.points[3].sub(self.points[1]);
            if (result.x == 0 and result.y == 0 and n.zeroOrOne(t)) result = self.points[3].sub(self.points[0]);
        }
        return result;
    }
    pub fn chopAt(self: Cubic, t: f64) [2]Cubic {
        if (t == 0.5) {
            const p = self.points;
            const a = p[0].mid(p[1]);
            const b: Point = .{ .x = (@mulAdd(f64, 2, p[1].x, p[0].x) + p[2].x) / 4, .y = (@mulAdd(f64, 2, p[1].y, p[0].y) + p[2].y) / 4 };
            const c: Point = .{ .x = (@mulAdd(f64, 3, p[1].x + p[2].x, p[0].x) + p[3].x) / 8, .y = (@mulAdd(f64, 3, p[1].y + p[2].y, p[0].y) + p[3].y) / 8 };
            const d: Point = .{ .x = (@mulAdd(f64, 2, p[2].x, p[1].x) + p[3].x) / 4, .y = (@mulAdd(f64, 2, p[2].y, p[1].y) + p[3].y) / 4 };
            const e = p[2].mid(p[3]);
            return .{ .{ .points = .{ p[0], a, b, c } }, .{ .points = .{ c, d, e, p[3] } } };
        }
        const ab = self.points[0].interp(self.points[1], t);
        const bc = self.points[1].interp(self.points[2], t);
        const cd = self.points[2].interp(self.points[3], t);
        const abc = ab.interp(bc, t);
        const bcd = bc.interp(cd, t);
        const abcd = abc.interp(bcd, t);
        return .{ .{ .points = .{ self.points[0], ab, abc, abcd } }, .{ .points = .{ abcd, bcd, cd, self.points[3] } } };
    }
    pub fn interpPoint(self: Cubic, t: f64) Point {
        const ab = self.points[0].interp(self.points[1], t);
        const bc = self.points[1].interp(self.points[2], t);
        const cd = self.points[2].interp(self.points[3], t);
        return ab.interp(bc, t).interp(bc.interp(cd, t), t);
    }
    pub fn subDivide(self: Cubic, t1: f64, t2: f64) Cubic {
        if (t1 == 0 or t2 == 1) {
            if (t1 == 0 and t2 == 1) return self;
            const pair = self.chopAt(if (t1 == 0) t2 else t1);
            return pair[if (t1 == 0) 0 else 1];
        }
        const a = self.interpPoint(t1);
        const e = self.interpPoint(@mulAdd(f64, t1, 2, t2) / 3);
        const f = self.interpPoint(@mulAdd(f64, t2, 2, t1) / 3);
        const d = self.interpPoint(t2);
        const mx = @mulAdd(f64, 27, e.x, -8 * a.x) - d.x;
        const my = @mulAdd(f64, 27, e.y, -8 * a.y) - d.y;
        const nx = @mulAdd(f64, -8, d.x, @mulAdd(f64, 27, f.x, -a.x));
        const ny = @mulAdd(f64, -8, d.y, @mulAdd(f64, 27, f.y, -a.y));
        return .{ .points = .{ a, .{ .x = @mulAdd(f64, 2, mx, -nx) / 18, .y = @mulAdd(f64, 2, my, -ny) / 18 }, .{ .x = @mulAdd(f64, 2, nx, -mx) / 18, .y = @mulAdd(f64, 2, ny, -my) / 18 }, d } };
    }
    pub fn hullBounds(self: Cubic) Bounds {
        return Bounds.fromPoints(&self.points);
    }
    pub fn bounds(self: Cubic) Bounds {
        var result = Bounds.fromPoints(&.{ self.points[0], self.points[3] });
        var ts: [2]f64 = undefined;
        for ([_]Axis{ .x, .y }) |axis| {
            // The control hull proves that this axis already fits between
            // the endpoints. Exact ordering, not an absolute epsilon, which
            // could hide extrema of very small curves.
            if (controlsWithinEndpoints(&self.points, axis)) continue;
            const count = self.findExtrema(axis, &ts);
            for (ts[0..count]) |t| result.include(self.ptAtT(t));
        }
        return result;
    }
    pub fn reverse(self: Cubic) Cubic {
        return .{ .points = .{ self.points[3], self.points[2], self.points[1], self.points[0] } };
    }
    pub fn findExtrema(self: Cubic, axis: Axis, out: *[2]f64) usize {
        const a = coordinate(self.points[0], axis);
        const b = coordinate(self.points[1], axis);
        const c = coordinate(self.points[2], axis);
        const d = coordinate(self.points[3], axis);
        return roots.quadraticValidT(@mulAdd(f64, b - c, 3, d - a), 2 * (a - b - b + c), b - a, out);
    }
    pub fn horizontalIntersect(self: Cubic, y: f64, out: *[3]f64) usize {
        return axis_roots.axisIntersect(self, .y, y, out);
    }
    pub fn verticalIntersect(self: Cubic, x: f64, out: *[3]f64) usize {
        return axis_roots.axisIntersect(self, .x, x, out);
    }
    pub fn nearPoint(self: Cubic, p: Point, opposite: Point) f64 {
        return curveNearPoint(self, p, opposite);
    }
    pub fn collapsed(self: Cubic) bool {
        return self.points[0].approximatelyEqual(self.points[1]) and self.points[0].approximatelyEqual(self.points[2]) and self.points[0].approximatelyEqual(self.points[3]);
    }
    pub fn controlsInside(self: Cubic) bool {
        const v01 = self.points[0].sub(self.points[1]);
        const v02 = self.points[0].sub(self.points[2]);
        const v03 = self.points[0].sub(self.points[3]);
        const v13 = self.points[1].sub(self.points[3]);
        const v23 = self.points[2].sub(self.points[3]);
        return v03.dot(v01) > 0 and v03.dot(v02) > 0 and v03.dot(v13) > 0 and v03.dot(v23) > 0;
    }
    pub fn hullIntersects(self: *const Cubic, other: anytype, is_linear: *bool) bool {
        return hull.hullIntersectsPoints(self, &other.points, is_linear);
    }
};
pub fn curveNearPoint(self: anytype, p: Point, opposite: Point) f64 {
    const bounds = self.hullBounds();
    if (!n.almostBetweenUlps(bounds.min.x, p.x, bounds.max.x) or !n.almostBetweenUlps(bounds.min.y, p.y, bounds.max.y)) return -1;
    const perp = Point{ .x = p.x + opposite.y - p.y, .y = p.y + p.x - opposite.x };
    const direction = perp.sub(p);
    var rotated = self;
    for (&rotated.points) |*point| point.* = .{ .x = (point.y - p.y) * direction.x - (point.x - p.x) * direction.y, .y = point.y };
    var ts: [if (@TypeOf(self) == Cubic) 3 else 2]f64 = undefined;
    const count = rotated.verticalIntersect(0, &ts);
    var best_t: f64 = -1;
    var best_distance = std.math.floatMax(f64);
    for (ts[0..count]) |t| {
        const distance = self.ptAtT(t).distance(p);
        if (distance < best_distance) {
            best_distance = distance;
            best_t = t;
        }
    }
    if (best_t < 0) return -1;
    const largest = @max(@max(bounds.max.x, bounds.max.y), -@min(bounds.min.x, bounds.min.y));
    return if (n.almostEqualUlpsPin(largest, largest + best_distance)) n.pinT(best_t) else -1;
}

pub const Curve = union(enum) {
    line: Line,
    quad: Quad,
    cubic: Cubic,
    pub fn ptAtT(self: Curve, t: f64) Point {
        return switch (self) {
            inline else => |curve| curve.ptAtT(t),
        };
    }
    pub fn dxdyAtT(self: Curve, t: f64) Point {
        return switch (self) {
            inline else => |curve| curve.dxdyAtT(t),
        };
    }
    pub fn subDivide(self: Curve, t1: f64, t2: f64) Curve {
        return switch (self) {
            .line => |c| .{ .line = c.subDivide(t1, t2) },
            .quad => |c| .{ .quad = c.subDivide(t1, t2) },
            .cubic => |c| .{ .cubic = c.subDivide(t1, t2) },
        };
    }
    pub fn reverse(self: Curve) Curve {
        return switch (self) {
            .line => |c| .{ .line = c.reverse() },
            .quad => |c| .{ .quad = c.reverse() },
            .cubic => |c| .{ .cubic = c.reverse() },
        };
    }
    pub fn hullBounds(self: Curve) Bounds {
        return switch (self) {
            inline else => |c| c.hullBounds(),
        };
    }
    pub fn bounds(self: Curve) Bounds {
        return switch (self) {
            inline else => |c| c.bounds(),
        };
    }
    pub fn first(self: *const Curve) Point {
        return switch (self.*) {
            inline else => |*c| c.points[0],
        };
    }
    pub fn last(self: *const Curve) Point {
        return switch (self.*) {
            .line => |*c| c.points[1],
            .quad => |*c| c.points[2],
            .cubic => |*c| c.points[3],
        };
    }
    pub fn degree(self: *const Curve) usize {
        return switch (self.*) {
            .line => 1,
            .quad => 2,
            .cubic => 3,
        };
    }
    pub fn pointCount(self: *const Curve) usize {
        return self.degree() + 1;
    }
    pub fn pointLast(self: *const Curve) usize {
        return self.degree();
    }
    pub fn point(self: *const Curve, index: usize) Point {
        return switch (self.*) {
            inline else => |*c| c.points[index],
        };
    }
    pub fn collapsed(self: Curve) bool {
        return switch (self) {
            .line => |c| c.points[0].approximatelyEqual(c.points[1]),
            .quad => |c| c.collapsed(),
            .cubic => |c| c.collapsed(),
        };
    }
    pub fn controlsInside(self: Curve) bool {
        return switch (self) {
            .line => true,
            .quad => |c| c.controlsInside(),
            .cubic => |c| c.controlsInside(),
        };
    }
    /// SkTCurve's hull predicate applies to quadratic/cubic curve pairs.
    /// Lines use their direct intersection routines instead of TSect.
    pub fn hullIntersects(self: *const Curve, other: *const Curve, is_linear: *bool) bool {
        return switch (self.*) {
            .line => unreachable,
            .quad => |*c| switch (other.*) {
                .line => unreachable,
                .quad => |*q| c.hullIntersects(q, is_linear),
                .cubic => |*q| c.hullIntersects(q, is_linear),
            },
            .cubic => |*c| switch (other.*) {
                .line => unreachable,
                .quad => |*q| c.hullIntersects(q, is_linear),
                .cubic => |*q| c.hullIntersects(q, is_linear),
            },
        };
    }
};

test {
    _ = @import("curve/axis_roots.zig");
    _ = @import("curve/hull.zig");
    _ = @import("curve/intercept_test.zig");
    _ = @import("curve/evaluation_test.zig");
}
