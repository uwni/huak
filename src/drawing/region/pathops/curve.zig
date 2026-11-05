// Copyright 2012 Google Inc.; BSD-style license: LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
const std = @import("std");
const n = @import("numeric.zig");
const roots = @import("roots.zig");
pub const Point = @import("point.zig").Point;
pub const Bounds = @import("point.zig").Bounds;
pub const Axis = enum { x, y };
fn coordinate(p: Point, axis: Axis) f64 {
    return if (axis == .x) p.x else p.y;
}
fn controlsWithinEndpoints(points: []const Point, axis: Axis) bool {
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
    pub fn chopAt(self: Line, t: f64) [2]Line {
        const p = self.ptAtT(t);
        return .{ .{ .points = .{ self.points[0], p } }, .{ .points = .{ p, self.points[1] } } };
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
    pub fn nearRay(self: Line, p: Point) bool {
        const len = self.points[1].sub(self.points[0]);
        const ab0 = p.sub(self.points[0]);
        const t = (len.x * ab0.x + ab0.y * len.y) / (len.x * len.x + len.y * len.y);
        const dist = self.ptAtT(t).distance(p);
        const b = self.hullBounds();
        const largest = @max(@max(b.max.x, b.max.y), -@min(b.min.x, b.min.y));
        return n.roughlyEqualUlps(largest, largest + dist);
    }
    pub fn exactPointH(p: Point, left: f64, right: f64, y: f64) f64 {
        return if (p.y == y and p.x == left) 0 else if (p.y == y and p.x == right) 1 else -1;
    }
    pub fn exactPointV(p: Point, top: f64, bottom: f64, x: f64) f64 {
        return if (p.x == x and p.y == top) 0 else if (p.x == x and p.y == bottom) 1 else -1;
    }
    pub fn nearPointH(p: Point, left: f64, right: f64, y: f64) f64 {
        if (!n.almostBequalUlps(p.y, y) or !n.almostBetweenUlps(left, p.x, right)) return -1;
        const t = n.pinT((p.x - left) / (right - left));
        const real_x = (1 - t) * left + t * right;
        const dx = p.y - y;
        const dy = p.x - real_x;
        const dist = @sqrt(dx * dx + dy * dy);
        const largest = interpolatedLargest(.{ .x = left, .y = y }, .{ .x = right, .y = y }, t);
        return if (n.almostEqualUlpsPin(largest, largest + dist)) t else -1;
    }
    pub fn nearPointV(p: Point, top: f64, bottom: f64, x: f64) f64 {
        if (!n.almostBequalUlps(p.x, x) or !n.almostBetweenUlps(top, p.y, bottom)) return -1;
        const t = n.pinT((p.y - top) / (bottom - top));
        const real_y = (1 - t) * top + t * bottom;
        const dx = p.x - x;
        const dy = p.y - real_y;
        const dist = @sqrt(dx * dx + dy * dy);
        const largest = interpolatedLargest(.{ .x = x, .y = top }, .{ .x = x, .y = bottom }, t);
        return if (n.almostEqualUlpsPin(largest, largest + dist)) t else -1;
    }
    pub fn horizontalIntersect(self: Line, y: f64, out: *[1]f64) usize {
        if (self.points[0].y == self.points[1].y) return 0;
        out[0] = n.pinT((y - self.points[0].y) / (self.points[1].y - self.points[0].y));
        return @intFromBool(n.between(0, out[0], 1));
    }
    pub fn verticalIntersect(self: Line, x: f64, out: *[1]f64) usize {
        if (self.points[0].x == self.points[1].x) return 0;
        out[0] = n.pinT((x - self.points[0].x) / (self.points[1].x - self.points[0].x));
        return @intFromBool(n.between(0, out[0], 1));
    }
};

pub const Quad = struct {
    points: [3]Point,
    pub fn ptAtT(self: Quad, t: f64) Point {
        if (t == 0) return self.points[0];
        if (t == 1) return self.points[2];
        const s = 1 - t;
        const a = s * s;
        const b = 2 * s * t;
        const c = t * t;
        return .{ .x = a * self.points[0].x + b * self.points[1].x + c * self.points[2].x, .y = a * self.points[0].y + b * self.points[1].y + c * self.points[2].y };
    }
    pub fn dxdyAtT(self: Quad, t: f64) Point {
        const a = t - 1;
        const b = 1 - 2 * t;
        const c = t;
        var result: Point = .{ .x = a * self.points[0].x + b * self.points[1].x + c * self.points[2].x, .y = a * self.points[0].y + b * self.points[1].y + c * self.points[2].y };
        if (result.x == 0 and result.y == 0 and n.zeroOrOne(t)) result = self.points[2].sub(self.points[0]);
        return result;
    }
    pub fn chopAt(self: Quad, t: f64) [2]Quad {
        const ab = self.points[0].interp(self.points[1], t);
        const bc = self.points[1].interp(self.points[2], t);
        const abc = ab.interp(bc, t);
        return .{ .{ .points = .{ self.points[0], ab, abc } }, .{ .points = .{ abc, bc, self.points[2] } } };
    }
    fn interpPoint(self: Quad, t: f64) Point {
        if (t == 0) return self.points[0];
        if (t == 1) return self.points[2];
        return self.points[0].interp(self.points[1], t).interp(self.points[1].interp(self.points[2], t), t);
    }
    pub fn subDivide(self: Quad, t1: f64, t2: f64) Quad {
        if (t1 == 0 and t2 == 1) return self;
        const a = self.interpPoint(t1);
        const d = self.interpPoint((t1 + t2) / 2);
        const c = self.interpPoint(t2);
        return .{ .points = .{ a, .{ .x = 2 * d.x - (a.x + c.x) / 2, .y = 2 * d.y - (a.y + c.y) / 2 }, c } };
    }
    pub fn hullBounds(self: Quad) Bounds {
        return Bounds.fromPoints(&self.points);
    }
    pub fn bounds(self: Quad) Bounds {
        var result = Bounds.fromPoints(&.{ self.points[0], self.points[2] });
        var ts: [1]f64 = undefined;
        for ([_]Axis{ .x, .y }) |axis| {
            if (controlsWithinEndpoints(&self.points, axis)) continue;
            const count = self.findExtrema(axis, &ts);
            for (ts[0..count]) |t| result.include(self.ptAtT(t));
        }
        return result;
    }
    pub fn reverse(self: Quad) Quad {
        return .{ .points = .{ self.points[2], self.points[1], self.points[0] } };
    }
    pub fn monotonicInX(self: Quad) bool {
        return n.between(self.points[0].x, self.points[1].x, self.points[2].x);
    }
    pub fn monotonicInY(self: Quad) bool {
        return n.between(self.points[0].y, self.points[1].y, self.points[2].y);
    }
    pub fn findExtrema(self: Quad, axis: Axis, out: *[1]f64) usize {
        const a = coordinate(self.points[0], axis);
        const b = coordinate(self.points[1], axis);
        const c = coordinate(self.points[2], axis);
        var numer = a - b;
        var denom = a - b - b + c;
        if (numer < 0) {
            numer = -numer;
            denom = -denom;
        }
        if (denom == 0 or numer == 0 or numer >= denom) return 0;
        const ratio = numer / denom;
        if (ratio == 0) return 0;
        out[0] = ratio;
        return 1;
    }
    pub fn axisIntersect(self: Quad, axis: Axis, intercept: f64, out: *[2]f64) usize {
        var d = coordinate(self.points[2], axis);
        var e = coordinate(self.points[1], axis);
        var f = coordinate(self.points[0], axis);
        d += f - 2 * e;
        e -= f;
        f -= intercept;
        return roots.quadraticValidT(d, 2 * e, f, out);
    }
    pub fn horizontalIntersect(self: Quad, y: f64, out: *[2]f64) usize {
        return self.axisIntersect(.y, y, out);
    }
    pub fn verticalIntersect(self: Quad, x: f64, out: *[2]f64) usize {
        return self.axisIntersect(.x, x, out);
    }
    pub fn nearPoint(self: Quad, p: Point, opposite: Point) f64 {
        return curveNearPoint(self, p, opposite);
    }
    pub fn collapsed(self: Quad) bool {
        return self.points[0].approximatelyEqual(self.points[1]) and self.points[0].approximatelyEqual(self.points[2]);
    }
    pub fn controlsInside(self: Quad) bool {
        const v01 = self.points[0].sub(self.points[1]);
        const v02 = self.points[0].sub(self.points[2]);
        const v12 = self.points[1].sub(self.points[2]);
        return v02.dot(v01) > 0 and v02.dot(v12) > 0;
    }
    pub fn isLinear(self: Quad, start: usize, end: usize) bool {
        return linearControlPoints(&self.points, start, end, &.{1});
    }
    pub fn hullIntersects(self: *const Quad, other: anytype, is_linear: *bool) bool {
        if (@TypeOf(other) == Cubic or @TypeOf(other) == *const Cubic) return other.hullIntersects(self, is_linear);
        return self.hullIntersectsPoints(&other.points, is_linear);
    }
    pub inline fn hullIntersectsPoints(self: *const Quad, points: []const Point, is_linear: *bool) bool {
        var linear = true;
        for (0..3) |odd_man| {
            const first: usize = if (odd_man == 0) 1 else 0;
            const second: usize = if (odd_man == 2) 1 else 2;
            const origin = self.points[first];
            const adj = self.points[second].x - origin.x;
            const opp = self.points[second].y - origin.y;
            const sign_value = (self.points[odd_man].y - origin.y) * adj - (self.points[odd_man].x - origin.x) * opp;
            if (n.approximatelyZero(sign_value)) continue;
            linear = false;
            var found_outlier = false;
            for (points) |p| {
                const value = (p.y - origin.y) * adj - (p.x - origin.x) * opp;
                if (value * sign_value > 0 and !n.preciselyZero(value)) {
                    found_outlier = true;
                    break;
                }
            }
            if (!found_outlier) return false;
        }
        if (linear and !self.points[0].eql(points[0]) and !self.points[2].eql(points[0]) and
            !self.points[0].eql(points[points.len - 1]) and !self.points[2].eql(points[points.len - 1]))
        {
            if (pointInTriangle(self.points, points[0]) or pointInTriangle(self.points, points[points.len - 1])) linear = false;
        }
        is_linear.* = linear;
        return true;
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
    fn interpPoint(self: Cubic, t: f64) Point {
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
    /// SkDCubic::subDivide(a,d,t1,t2): merged intersection endpoints also
    /// translate their adjacent controls; source-axis alignment and the
    /// original two-ULP snaps are applied after that correction.
    pub fn subDivideWithEnds(self: Cubic, a: Point, d: Point, t1: f64, t2: f64) Cubic {
        std.debug.assert(t1 != t2);
        const sub = self.subDivide(t1, t2);
        var controls = [2]Point{ sub.points[1].add(a.sub(sub.points[0])), sub.points[2].add(d.sub(sub.points[3])) };
        if (t1 == 0 or t2 == 0) self.alignControl(0, 1, &controls[if (t1 == 0) 0 else 1]);
        if (t1 == 1 or t2 == 1) self.alignControl(3, 2, &controls[if (t1 == 1) 0 else 1]);
        if (n.almostBequalUlps(controls[0].x, a.x)) controls[0].x = a.x;
        if (n.almostBequalUlps(controls[0].y, a.y)) controls[0].y = a.y;
        if (n.almostBequalUlps(controls[1].x, d.x)) controls[1].x = d.x;
        if (n.almostBequalUlps(controls[1].y, d.y)) controls[1].y = d.y;
        return .{ .points = .{ a, controls[0], controls[1], d } };
    }
    fn alignControl(self: Cubic, end: usize, control: usize, point: *Point) void {
        if (self.points[end].x == self.points[control].x) point.x = self.points[end].x;
        if (self.points[end].y == self.points[control].y) point.y = self.points[end].y;
    }
    pub fn hullBounds(self: Cubic) Bounds {
        return Bounds.fromPoints(&self.points);
    }
    pub fn bounds(self: Cubic) Bounds {
        var result = Bounds.fromPoints(&.{ self.points[0], self.points[3] });
        var ts: [2]f64 = undefined;
        for ([_]Axis{ .x, .y }) |axis| {
            // The control hull proves that this axis already fits between
            // the endpoints. Use exact ordering rather than monotonicInX/Y's
            // absolute epsilon, which can hide extrema of very small curves.
            if (controlsWithinEndpoints(&self.points, axis)) continue;
            const count = self.findExtrema(axis, &ts);
            for (ts[0..count]) |t| result.include(self.ptAtT(t));
        }
        return result;
    }
    pub fn reverse(self: Cubic) Cubic {
        return .{ .points = .{ self.points[3], self.points[2], self.points[1], self.points[0] } };
    }
    pub fn coefficients(self: Cubic, axis: Axis) [4]f64 {
        var a = coordinate(self.points[3], axis);
        var b = coordinate(self.points[2], axis) * 3;
        var c = coordinate(self.points[1], axis) * 3;
        const d = coordinate(self.points[0], axis);
        a -= d - c + b;
        b += @mulAdd(f64, d, 3, -2 * c);
        c = @mulAdd(f64, d, -3, c);
        return .{ a, b, c, d };
    }
    pub fn findExtrema(self: Cubic, axis: Axis, out: *[2]f64) usize {
        const a = coordinate(self.points[0], axis);
        const b = coordinate(self.points[1], axis);
        const c = coordinate(self.points[2], axis);
        const d = coordinate(self.points[3], axis);
        return roots.quadraticValidT(@mulAdd(f64, b - c, 3, d - a), 2 * (a - b - b + c), b - a, out);
    }
    pub fn findInflections(self: Cubic, out: *[2]f64) usize {
        const p = self.points;
        const ax = p[1].x - p[0].x;
        const ay = p[1].y - p[0].y;
        const bx = @mulAdd(f64, p[1].x, -2, p[2].x) + p[0].x;
        const by = @mulAdd(f64, p[1].y, -2, p[2].y) + p[0].y;
        const cx = @mulAdd(f64, p[1].x - p[2].x, 3, p[3].x) - p[0].x;
        const cy = @mulAdd(f64, p[1].y - p[2].y, 3, p[3].y) - p[0].y;
        return roots.quadraticValidT(@mulAdd(f64, bx, cy, -(by * cx)), @mulAdd(f64, ax, cy, -(ay * cx)), @mulAdd(f64, ax, by, -(ay * bx)), out);
    }
    fn atIntercept(self: Cubic, value: f64, t: f64, axis: Axis, intercept: f64) bool {
        const s = 1 - t;
        const weighted = s * s * s * @abs(coordinate(self.points[0], axis)) + 3 * s * s * t * @abs(coordinate(self.points[1], axis)) + 3 * s * t * t * @abs(coordinate(self.points[2], axis)) + t * t * t * @abs(coordinate(self.points[3], axis));
        const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
        return value == intercept or @abs(value - intercept) <= gamma * (weighted + @abs(intercept));
    }
    fn interceptUpperBound(self: Cubic, axis: Axis, intercept: f64) f64 {
        // For t,s in [0,1], the original nonnegative product chains are
        // bounded by |p0|, 3|p1|, 3|p2|, |p3|. Preserve their summation order:
        // rounded multiplication/addition is monotone on nonnegative values.
        // Infinity disables the filter for overflow or nonfinite input.
        const weighted = @abs(coordinate(self.points[0], axis)) + 3 * @abs(coordinate(self.points[1], axis)) + 3 * @abs(coordinate(self.points[2], axis)) + @abs(coordinate(self.points[3], axis));
        const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
        const bound = gamma * (weighted + @abs(intercept));
        return if (std.math.isFinite(bound)) bound else std.math.inf(f64);
    }
    inline fn atInterceptWithinBound(self: Cubic, value: f64, t: f64, axis: Axis, intercept: f64, upper_bound: f64) bool {
        if (t >= 0 and t <= 1 and @abs(value - intercept) > upper_bound) return false;
        return self.atIntercept(value, t, axis, intercept);
    }
    pub fn binarySearch(self: Cubic, min: f64, max: f64, intercept: f64, axis: Axis) f64 {
        var t = (min + max) / 2;
        var step = (t - min) / 2;
        var at = self.ptAtT(t);
        var position = coordinate(at, axis);
        var distance = position - intercept;
        const min_position = coordinate(self.ptAtT(min), axis);
        const max_position = coordinate(self.ptAtT(max), axis);
        const bracketed = (min_position <= intercept and intercept <= max_position) or (max_position <= intercept and intercept <= min_position);
        const upper_bound = self.interceptUpperBound(axis, intercept);
        if (self.atInterceptWithinBound(position, t, axis, intercept, upper_bound)) return t;
        while (true) {
            const prior_t = @max(min, t - step);
            const less = self.ptAtT(prior_t);
            if (prior_t == t or less.eql(at)) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
            const less_distance = coordinate(less, axis) - intercept;
            const last_step = step;
            step /= 2;
            if (if (distance > 0) distance > less_distance else distance < less_distance) {
                t = prior_t;
                at = less;
            } else {
                const next_t = t + last_step;
                if (next_t > max) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
                const more = self.ptAtT(next_t);
                if (next_t == t or more.eql(at)) return nearestRoot(t, distance, min, max, min_position, max_position, intercept, bracketed);
                const more_distance = coordinate(more, axis) - intercept;
                if (if (distance > 0) distance <= more_distance else distance >= more_distance) continue;
                t = next_t;
                at = more;
            }
            position = coordinate(at, axis);
            distance = position - intercept;
            if (self.atInterceptWithinBound(position, t, axis, intercept, upper_bound)) return t;
        }
    }
    pub fn searchRoots(self: Cubic, extremes: []const f64, intercept: f64, axis: Axis, out: *[3]f64) usize {
        var ts: [6]f64 = undefined;
        @memcpy(ts[0..extremes.len], extremes);
        var inflections: [2]f64 = undefined;
        const inflection_count = self.findInflections(&inflections);
        @memcpy(ts[extremes.len..][0..inflection_count], inflections[0..inflection_count]);
        const count = extremes.len + inflection_count + 2;
        ts[count - 2] = 0;
        ts[count - 1] = 1;
        std.mem.sort(f64, ts[0..count], {}, std.sort.asc(f64));
        var valid: usize = 0;
        for (0..count - 1) |i| {
            if (ts[i] == ts[i + 1]) continue;
            const t = self.binarySearch(ts[i], ts[i + 1], intercept, axis);
            if (t >= 0) {
                if (valid >= 3) return 0;
                out[valid] = t;
                valid += 1;
            }
        }
        return valid;
    }
    pub fn axisIntersect(self: Cubic, axis: Axis, intercept: f64, out: *[3]f64) usize {
        var c = self.coefficients(axis);
        c[3] -= intercept;
        const count = roots.cubicValidT(c[0], c[1], c[2], c[3], out);
        for (out[0..count]) |t| if (!n.approximatelyEqual(coordinate(self.ptAtT(t), axis), intercept)) {
            var extremes: [2]f64 = undefined;
            const extreme_count = self.findExtrema(axis, &extremes);
            return self.searchRoots(extremes[0..extreme_count], intercept, axis, out);
        };
        return count;
    }
    pub fn horizontalIntersect(self: Cubic, y: f64, out: *[3]f64) usize {
        return self.axisIntersect(.y, y, out);
    }
    pub fn verticalIntersect(self: Cubic, x: f64, out: *[3]f64) usize {
        return self.axisIntersect(.x, x, out);
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
    pub fn monotonicInX(self: Cubic) bool {
        return n.preciselyBetween(self.points[0].x, self.points[1].x, self.points[3].x) and n.preciselyBetween(self.points[0].x, self.points[2].x, self.points[3].x);
    }
    pub fn monotonicInY(self: Cubic) bool {
        return n.preciselyBetween(self.points[0].y, self.points[1].y, self.points[3].y) and n.preciselyBetween(self.points[0].y, self.points[2].y, self.points[3].y);
    }
    pub fn isLinear(self: Cubic, start: usize, end: usize) bool {
        if (self.points[0].approximatelyDEqual(self.points[3])) return (Quad{ .points = self.points[0..3].* }).isLinear(0, 2);
        return linearControlPoints(&self.points, start, end, &.{ 1, 2 });
    }
    pub fn calcPrecision(self: Cubic) f64 {
        return (self.points[1].sub(self.points[0]).length() + self.points[2].sub(self.points[1]).length() + self.points[3].sub(self.points[2]).length()) / 256;
    }
    pub fn findMaxCurvature(self: Cubic, out: *[3]f64) usize {
        var coefficients_sum: [4]f64 = @splat(0);
        for ([_]Axis{ .x, .y }) |axis| {
            const a = coordinate(self.points[1], axis) - coordinate(self.points[0], axis);
            const b = coordinate(self.points[2], axis) - 2 * coordinate(self.points[1], axis) + coordinate(self.points[0], axis);
            const c = coordinate(self.points[3], axis) + 3 * (coordinate(self.points[1], axis) - coordinate(self.points[2], axis)) - coordinate(self.points[0], axis);
            const values = [4]f64{ c * c, 3 * b * c, 2 * b * b + c * a, a * b };
            for (&coefficients_sum, values) |*sum, value| sum.* += value;
        }
        return roots.cubicValidT(coefficients_sum[0], coefficients_sum[1], coefficients_sum[2], coefficients_sum[3], out);
    }
    pub fn convexHull(self: *const Cubic, order: *[4]usize) usize {
        var y_min: usize = 0;
        for (1..4) |i| if (self.points[y_min].y > self.points[i].y or
            (self.points[y_min].y == self.points[i].y and self.points[y_min].x > self.points[i].x))
        {
            y_min = i;
        };
        order[0] = y_min;
        var mid_x: ?usize = null;
        var backup_y_min: ?usize = null;
        for (0..2) |_| {
            for (0..4) |index| {
                if (index == y_min) continue;
                const mask = otherTwo(y_min, index);
                const side1 = y_min ^ mask;
                const side2 = index ^ mask;
                var rotated_y: [4]f64 = undefined;
                if (!self.rotateHullY(y_min, index, &rotated_y)) {
                    order[1] = side1;
                    order[2] = side2;
                    return 3;
                }
                const sides = n.side(rotated_y[side1] - rotated_y[y_min]) ^ n.side(rotated_y[side2] - rotated_y[y_min]);
                if (sides == 2) {
                    if (mid_x != null) {
                        order[0] = 0;
                        order[1] = 3;
                        if (self.points[1].eql(self.points[0]) or self.points[1].eql(self.points[3])) {
                            order[2] = 2;
                            return 3;
                        }
                        if (self.points[2].eql(self.points[0]) or self.points[2].eql(self.points[3])) {
                            order[2] = 1;
                            return 3;
                        }
                        const smallest1 = @min(self.points[1].distanceSquared(self.points[0]), self.points[1].distanceSquared(self.points[3]));
                        const smallest2 = @min(self.points[2].distanceSquared(self.points[0]), self.points[2].distanceSquared(self.points[3]));
                        if (n.approximatelyZero(@min(smallest1, smallest2))) {
                            order[2] = if (smallest1 < smallest2) 2 else 1;
                            return 3;
                        }
                    }
                    mid_x = index;
                } else if (sides == 0) backup_y_min = index;
            }
            if (mid_x != null or backup_y_min == null) break;
            y_min = backup_y_min.?;
            backup_y_min = null;
        }
        const mid = mid_x orelse (y_min ^ 3);
        const mask = otherTwo(y_min, mid);
        const least = y_min ^ mask;
        const most = mid ^ mask;
        order[0] = y_min;
        order[1] = least;
        var rotated_y: [4]f64 = undefined;
        if (!self.rotateHullY(least, most, &rotated_y)) {
            order[2] = mid;
            return 3;
        }
        const sides = n.side(rotated_y[y_min] - rotated_y[least]) ^ n.side(rotated_y[mid] - rotated_y[least]);
        if (sides != 2) {
            order[2] = most;
            return 3;
        }
        order[2] = mid;
        order[3] = most;
        return 4;
    }
    // Convex-hull classification reads only rotated Y. Keep the source
    // arithmetic/snaps while avoiding unused X rotations and a Cubic return.
    fn rotateHullY(self: *const Cubic, zero: usize, index: usize, result: *[4]f64) bool {
        const dy = self.points[index].y - self.points[zero].y;
        const dx = self.points[index].x - self.points[zero].x;
        if (n.approximatelyZero(dy)) {
            if (n.approximatelyZero(dx)) return false;
            for (self.points, result) |point, *out| out.* = point.y;
            if (dy != 0) {
                result[index] = self.points[zero].y;
                const mask = otherTwo(index, zero);
                const side1 = index ^ mask;
                const side2 = zero ^ mask;
                if (n.approximatelyEqual(self.points[side1].y, self.points[zero].y)) result[side1] = self.points[zero].y;
                if (n.approximatelyEqual(self.points[side2].y, self.points[zero].y)) result[side2] = self.points[zero].y;
            }
            return true;
        }
        for (self.points, result) |point, *out| out.* = point.y * dx - point.x * dy;
        return true;
    }
    pub fn hullIntersects(self: *const Cubic, other: anytype, is_linear: *bool) bool {
        return self.hullIntersectsPoints(&other.points, is_linear);
    }
    pub inline fn hullIntersectsPoints(self: *const Cubic, points: []const Point, is_linear: *bool) bool {
        var linear = true;
        var order: [4]usize = undefined;
        const count = self.convexHull(&order);
        var end1 = order[0];
        var hull_index: usize = 0;
        var first = self.points[end1];
        while (true) {
            hull_index = (hull_index + 1) % count;
            const end2 = order[hull_index];
            const second = self.points[end2];
            const adj = second.x - first.x;
            const opp = second.y - first.y;
            const mask = otherTwo(end1, end2);
            const odd = self.points[end1 ^ mask];
            const odd2 = self.points[end2 ^ mask];
            var sign_value = (odd.y - first.y) * adj - (odd.x - first.x) * opp;
            const sign2 = (odd2.y - first.y) * adj - (odd2.x - first.x) * opp;
            if (sign_value * sign2 < 0) {
                if (hull_index == 0) break;
                continue;
            }
            if (n.approximatelyZero(sign_value)) {
                sign_value = sign2;
                if (n.approximatelyZero(sign_value)) {
                    if (hull_index == 0) break;
                    continue;
                }
            }
            linear = false;
            var found_outlier = false;
            for (points) |p| {
                const value = (p.y - first.y) * adj - (p.x - first.x) * opp;
                // Preserve the established f64 same-side hull correction.
                if (value * sign_value > 0) {
                    found_outlier = true;
                    break;
                }
            }
            if (!found_outlier) return false;
            first = second;
            end1 = end2;
            if (hull_index == 0) break;
        }
        is_linear.* = linear;
        return true;
    }
};
fn otherTwo(one: usize, two: usize) usize {
    return (@as(usize, 1) >> @as(std.math.Log2Int(usize), @intCast(3 - (one ^ two)))) ^ 3;
}
fn linearControlPoints(points: []const Point, start: usize, end: usize, controls: []const usize) bool {
    var a = points[start].y - points[end].y;
    var b = points[end].x - points[start].x;
    var c = points[start].x * points[end].y - points[end].x * points[start].y;
    const normal = @sqrt(a * a + b * b);
    if (n.approximatelyZero(normal)) {
        a = 0;
        b = 0;
        c = 0;
    } else {
        const reciprocal = 1 / normal;
        a *= reciprocal;
        b *= reciprocal;
        c *= reciprocal;
    }
    const bounds = Bounds.fromPoints(points);
    const largest = @max(@max(bounds.max.x, bounds.max.y), -@min(bounds.min.x, bounds.min.y));
    for (controls) |index| if (!n.approximatelyZeroWhenComparedTo(a * points[index].x + b * points[index].y + c, largest)) return false;
    return true;
}
fn pointInTriangle(points: [3]Point, test_point: Point) bool {
    const v0 = points[2].sub(points[0]);
    const v1 = points[1].sub(points[0]);
    const v2 = test_point.sub(points[0]);
    const dot00 = v0.dot(v0);
    const dot01 = v0.dot(v1);
    const dot02 = v0.dot(v2);
    const dot11 = v1.dot(v1);
    const dot12 = v1.dot(v2);
    const denom = dot00 * dot11 - dot01 * dot01;
    const u = dot11 * dot02 - dot01 * dot12;
    const v = dot00 * dot12 - dot01 * dot02;
    return if (denom >= 0) u >= 0 and v >= 0 and u + v < denom else u <= 0 and v <= 0 and u + v > denom;
}
fn nearestRoot(t: f64, distance: f64, min: f64, max: f64, min_position: f64, max_position: f64, intercept: f64, bracketed: bool) f64 {
    if (!bracketed) return -1;
    var result = t;
    var error_value = @abs(distance);
    if (@abs(min_position - intercept) < error_value) {
        error_value = @abs(min_position - intercept);
        result = min;
    }
    if (@abs(max_position - intercept) < error_value) result = max;
    return result;
}
fn curveNearPoint(self: anytype, p: Point, opposite: Point) f64 {
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

test "original cubic ray contracts retain roots at physical and parameter limits" {
    for ([_]f64{ 6, 10 }) |radius| {
        const k = radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
        const quarter: Cubic = .{ .points = .{ .{ .x = -radius, .y = 0 }, .{ .x = -radius, .y = -k }, .{ .x = -k, .y = -radius }, .{ .x = 0, .y = -radius } } };
        const y = -@sqrt(@as(f64, 2));
        var ts: [3]f64 = undefined;
        const count = quarter.horizontalIntersect(y, &ts);
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(@abs(quarter.ptAtT(ts[0]).y - y) <= 16 * n.EPSILON / (1 - 16 * n.EPSILON) * radius);
    }
    const radius = 0.66113130760175032;
    const cx = -0.18889465931478577;
    const k = radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const quarter: Cubic = .{ .points = .{ .{ .x = cx, .y = -radius }, .{ .x = cx - k, .y = -radius }, .{ .x = cx - radius, .y = -k }, .{ .x = cx - radius, .y = 0 } } };
    var ts: [3]f64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), quarter.horizontalIntersect(-5.5511151231257827e-17, &ts));
    try std.testing.expectEqual(@as(f64, 1), ts[0]);
}

fn checkInterceptBound(curve: Cubic, t: f64, axis: Axis, intercept: f64) !void {
    const s = 1 - t;
    // The original acceptance threshold, including its exact evaluation order.
    const weighted = s * s * s * @abs(coordinate(curve.points[0], axis)) + 3 * s * s * t * @abs(coordinate(curve.points[1], axis)) + 3 * s * t * t * @abs(coordinate(curve.points[2], axis)) + t * t * t * @abs(coordinate(curve.points[3], axis));
    const gamma = 16 * n.EPSILON / (1 - 16 * n.EPSILON);
    const threshold = gamma * (weighted + @abs(intercept));
    const bound = curve.interceptUpperBound(axis, intercept);
    try std.testing.expect(threshold <= bound);
    const inf = std.math.inf(f64);
    for ([_]f64{
        0,
        std.math.nextAfter(f64, threshold, 0),
        threshold,
        std.math.nextAfter(f64, threshold, inf),
        bound,
        std.math.nextAfter(f64, bound, inf),
        bound * 2,
        std.math.floatMax(f64),
        inf,
    }) |offset| for ([_]f64{ -1, 1 }) |sign| {
        const value = intercept + sign * offset;
        try std.testing.expectEqual(curve.atIntercept(value, t, axis, intercept), curve.atInterceptWithinBound(value, t, axis, intercept, bound));
    };
}

test "cubic intercept bound preserves the original predicate at rounded boundaries" {
    const sources = [_]Cubic{
        .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = 8, .y = 9 }, .{ .x = -16, .y = -2 }, .{ .x = 3, .y = 4 } } },
        .{ .points = @splat(.{ .x = 1, .y = -1 }) },
        .{ .points = @splat(Point.zero) },
    };
    for (sources) |source| for ([_]i32{ -1020, -500, -80, 0, 80, 500, 1000 }) |exponent| {
        var curve = source;
        for (&curve.points) |*point| {
            point.x = std.math.ldexp(point.x, exponent);
            point.y = std.math.ldexp(point.y, exponent);
        }
        for ([_]f64{ 0, std.math.nextAfter(f64, 0, 1), 0.125, 0.5, 0.875, std.math.nextAfter(f64, 1, 0), 1 }) |t| {
            for ([_]Axis{ .x, .y }) |axis| {
                try checkInterceptBound(curve, t, axis, 0);
                try checkInterceptBound(curve, t, axis, coordinate(curve.ptAtT(t), axis));
            }
        }
    };
}

test "cubic intercept bound falls back outside the unit interval and for nonfinite inputs" {
    const curve: Cubic = .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = 8, .y = 9 }, .{ .x = -16, .y = -2 }, .{ .x = 3, .y = 4 } } };
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const bound = curve.interceptUpperBound(.x, 0);
    for ([_]f64{ -1, std.math.nextAfter(f64, 0, -1), std.math.nextAfter(f64, 1, inf), 2, inf, nan }) |t| {
        for ([_]f64{ 0, 1, -1, inf, nan }) |value| {
            try std.testing.expectEqual(curve.atIntercept(value, t, .x, 0), curve.atInterceptWithinBound(value, t, .x, 0, bound));
        }
    }
    for ([_]f64{ inf, nan, std.math.floatMax(f64) }) |nonfinite_bound| {
        var extreme = curve;
        extreme.points[1].x = nonfinite_bound;
        const disabled = extreme.interceptUpperBound(.x, 0);
        try std.testing.expectEqual(inf, disabled);
        for ([_]f64{ 0, 0.5, 1 }) |t| for ([_]f64{ 0, 1, inf, nan }) |value| {
            try std.testing.expectEqual(extreme.atIntercept(value, t, .x, 0), extreme.atInterceptWithinBound(value, t, .x, 0, disabled));
        };
    }
    for ([_]f64{ inf, nan }) |intercept| {
        const disabled = curve.interceptUpperBound(.x, intercept);
        try std.testing.expectEqual(inf, disabled);
        try std.testing.expectEqual(curve.atIntercept(intercept, 0.5, .x, intercept), curve.atInterceptWithinBound(intercept, 0.5, .x, intercept, disabled));
    }
}

test "cubic binary search reuses sampled points with identical reference root bits" {
    const Reference = struct {
        fn finish(t: f64, distance: f64, min: f64, max: f64, min_position: f64, max_position: f64, intercept: f64, bracketed: bool) f64 {
            if (!bracketed) return -1;
            var result = t;
            var error_value = @abs(distance);
            if (@abs(min_position - intercept) < error_value) {
                error_value = @abs(min_position - intercept);
                result = min;
            }
            if (@abs(max_position - intercept) < error_value) result = max;
            return result;
        }

        // Full pre-cache search, including the original acceptance test and
        // every parameter/point progress check and nearest-root return.
        fn search(curve: Cubic, min: f64, max: f64, intercept: f64, axis: Axis) f64 {
            var t = (min + max) / 2;
            var step = (t - min) / 2;
            var at = curve.ptAtT(t);
            var position = coordinate(at, axis);
            var distance = position - intercept;
            const min_position = coordinate(curve.ptAtT(min), axis);
            const max_position = coordinate(curve.ptAtT(max), axis);
            const bracketed = (min_position <= intercept and intercept <= max_position) or (max_position <= intercept and intercept <= min_position);
            if (curve.atIntercept(position, t, axis, intercept)) return t;
            while (true) {
                const prior_t = @max(min, t - step);
                const less = curve.ptAtT(prior_t);
                if (prior_t == t or less.eql(at)) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                const less_distance = coordinate(less, axis) - intercept;
                const last_step = step;
                step /= 2;
                if (if (distance > 0) distance > less_distance else distance < less_distance) t = prior_t else {
                    const next_t = t + last_step;
                    if (next_t > max) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                    const more = curve.ptAtT(next_t);
                    if (next_t == t or more.eql(at)) return finish(t, distance, min, max, min_position, max_position, intercept, bracketed);
                    const more_distance = coordinate(more, axis) - intercept;
                    if (if (distance > 0) distance <= more_distance else distance >= more_distance) continue;
                    t = next_t;
                }
                at = curve.ptAtT(t);
                position = coordinate(at, axis);
                distance = position - intercept;
                if (curve.atIntercept(position, t, axis, intercept)) return t;
            }
        }
    };
    const k: f64 = 6 * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const tiny_radius: f64 = 0.66113130760175032;
    const tiny_x: f64 = -0.18889465931478577;
    const tiny_k: f64 = tiny_radius * ((4.0 / 3.0) * @tan(std.math.pi / 8.0));
    const sources = [_]Cubic{
        .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } },
        .{ .points = .{ .{ .x = -6, .y = 0 }, .{ .x = -6, .y = -k }, .{ .x = -k, .y = -6 }, .{ .x = 0, .y = -6 } } },
        .{ .points = .{ .{ .x = tiny_x, .y = -tiny_radius }, .{ .x = tiny_x - tiny_k, .y = -tiny_radius }, .{ .x = tiny_x - tiny_radius, .y = -tiny_k }, .{ .x = tiny_x - tiny_radius, .y = 0 } } },
        .{ .points = @splat(.{ .x = 1, .y = -1 }) },
    };
    const intervals = [_][2]f64{
        .{ 0, 1 },
        .{ 0, 0.5 },
        .{ 0.5, 1 },
        .{ 0.125, 0.875 },
        .{ 0.5, 0.5 },
        .{ 0, std.math.nextAfter(f64, 0, 1) },
        .{ std.math.nextAfter(f64, 1, 0), 1 },
    };
    var saw_failure = false;
    var saw_endpoint = false;
    var saw_interior = false;
    for (sources) |source| for ([_]i32{ -500, -80, 0, 80, 500 }) |exponent| {
        var curve = source;
        for (&curve.points) |*point| {
            point.x = std.math.ldexp(point.x, exponent);
            point.y = std.math.ldexp(point.y, exponent);
        }
        const bounds = curve.bounds();
        for ([_]Axis{ .x, .y }) |axis| {
            const first = coordinate(curve.points[0], axis);
            const last = coordinate(curve.points[3], axis);
            const low = coordinate(bounds.min, axis);
            const high = coordinate(bounds.max, axis);
            const intercepts = [_]f64{
                0,
                -0.0,
                first,
                last,
                coordinate(curve.ptAtT(0.375), axis),
                low,
                high,
                std.math.nextAfter(f64, last, std.math.inf(f64)),
                high + @max(1, high - low),
                std.math.ldexp(-@sqrt(@as(f64, 2)), exponent),
            };
            for (intercepts) |intercept| for (intervals) |interval| {
                const expected = Reference.search(curve, interval[0], interval[1], intercept, axis);
                const actual = curve.binarySearch(interval[0], interval[1], intercept, axis);
                try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
                if (expected < 0) saw_failure = true else if (expected == 0 or expected == 1) saw_endpoint = true else saw_interior = true;
            };
        }
    };
    try std.testing.expect(saw_failure and saw_endpoint and saw_interior);
}

test "captured Cardano candidates pass the original cubic back substitution" {
    const queries = [_]struct { curve: Cubic, axis: Axis, intercept: f64 }{
        .{ .curve = .{ .points = .{
            .{ .x = 0.42473070360522436, .y = -0.9910383084121902 },
            .{ .x = 0.15106303148814484, .y = -0.9910383084121902 },
            .{ .x = -0.07078845060087073, .y = -0.7691868263231746 },
            .{ .x = -0.07078845060087073, .y = -0.4955191542060951 },
        } }, .axis = .x, .intercept = 0 },
        .{ .curve = .{ .points = .{
            .{ .x = 0.3125, .y = 0 },
            .{ .x = 0.3125, .y = 0.3020307225637151 },
            .{ .x = 0.0676557225637151, .y = 0.546875 },
            .{ .x = -0.234375, .y = 0.546875 },
        } }, .axis = .y, .intercept = 0.29601827545333426 },
    };
    for (queries) |query| {
        var coefficients = query.curve.coefficients(query.axis);
        coefficients[3] -= query.intercept;
        var base_roots: [3]f64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), roots.cubicValidT(coefficients[0], coefficients[1], coefficients[2], coefficients[3], &base_roots));
        const t = base_roots[0];
        try std.testing.expect(t > 0 and t < 1);
        const value = coordinate(query.curve.ptAtT(t), query.axis);
        try std.testing.expect(n.approximatelyEqual(value, query.intercept));
        var recovered: [3]f64 = undefined;
        try std.testing.expectEqual(@as(usize, 1), query.curve.axisIntersect(query.axis, query.intercept, &recovered));
        try std.testing.expectEqual(@as(u64, @bitCast(t)), @as(u64, @bitCast(recovered[0])));
        for ([_]i32{ -800, -80, 80, 800 }) |exponent| {
            var scaled: [4]f64 = undefined;
            for (&scaled, coefficients) |*scaled_value, coefficient| scaled_value.* = std.math.ldexp(coefficient, exponent);
            var values: [3]f64 = undefined;
            try std.testing.expectEqual(@as(usize, 1), roots.cubicValidT(scaled[0], scaled[1], scaled[2], scaled[3], &values));
            try std.testing.expectEqual(@as(u64, @bitCast(t)), @as(u64, @bitCast(values[0])));
        }
    }
}

test "cubic evaluation and coefficients preserve retained C++ fused rounding" {
    const rotated: Cubic = .{ .points = .{
        .{ .x = 0.42473070360522436, .y = -0.9910383084121902 },
        .{ .x = 0.15106303148814484, .y = -0.9910383084121902 },
        .{ .x = -0.07078845060087073, .y = -0.7691868263231746 },
        .{ .x = -0.07078845060087073, .y = -0.4955191542060951 },
    } };
    const source: Cubic = .{ .points = .{
        .{ .x = 0.3125, .y = 0 },
        .{ .x = 0.3125, .y = 0.3020307225637151 },
        .{ .x = 0.0676557225637151, .y = 0.546875 },
        .{ .x = -0.234375, .y = 0.546875 },
    } };
    // Original SkDCubic::ptAtT outputs at fixed parameters, independent of
    // the root solver and platform transcendental functions.
    try std.testing.expectEqual(@as(u64, 0x3cab2be3383cc703), @as(u64, @bitCast(rotated.ptAtT(@bitCast(@as(u64, 0x3fe513a3078db6f2))).x)));
    try std.testing.expectEqual(@as(u64, 0x3fd2f1f6a305c8f7), @as(u64, @bitCast(source.ptAtT(@bitCast(@as(u64, 0x3fd71d0ef0b3479a))).y)));
    const c: Cubic = .{ .points = .{
        .{ .x = 0.07078845060087073, .y = 0 },
        .{ .x = 0.07078845060087073, .y = 0 },
        .{ .x = -0.15106303148814484, .y = 0 },
        .{ .x = -0.42473070360522436, .y = 0 },
    } };
    const expected = [_]u64{ 0x3fc5c3b76948a6f8, 0xbfe54c38d68d9451, 0xbc70000000000000, 0x3fb21f312043e783 };
    for (c.coefficients(.x), expected) |actual, bits| try std.testing.expectEqual(bits, @as(u64, @bitCast(actual)));
}

test "Bezier restriction preserves source endpoints and curved controls" {
    const c: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } };
    const pieces = c.chopAt(0.5);
    try std.testing.expect(pieces[0].points[0].eql(c.points[0]));
    try std.testing.expect(pieces[1].points[3].eql(c.points[3]));
    try std.testing.expect(pieces[0].points[3].eql(pieces[1].points[0]));
    const sub = c.subDivide(0.2, 0.8);
    try std.testing.expectApproxEqAbs(c.ptAtT(0.2).x, sub.points[0].x, 1e-15);
    try std.testing.expectApproxEqAbs(c.ptAtT(0.8).y, sub.points[3].y, 1e-15);
}

// The previous bounds path always solved both axes. Keep that reference to
// check that skipping an endpoint-contained control hull changes no bounds.
fn unconditionalExtremaBounds(curve: anytype) Bounds {
    var result = Bounds.fromPoints(&.{ curve.points[0], curve.points[curve.points.len - 1] });
    var ts: [curve.points.len - 2]f64 = undefined;
    for ([_]Axis{ .x, .y }) |axis| {
        const count = curve.findExtrema(axis, &ts);
        for (ts[0..count]) |t| result.include(curve.ptAtT(t));
    }
    return result;
}

test "endpoint control hull bounds retain monotone and interior extrema at extreme scales" {
    const cubics = [_]Cubic{
        .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = -3, .y = -2 }, .{ .x = 2, .y = 5 }, .{ .x = 8, .y = 9 } } },
        .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 3, .y = 0 } } },
        .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 5 }, .{ .x = -3, .y = 5 }, .{ .x = 0, .y = 0 } } },
    };
    const quads = [_]Quad{
        .{ .points = .{ .{ .x = -4, .y = -3 }, .{ .x = 2, .y = 5 }, .{ .x = 8, .y = 9 } } },
        .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 0 } } },
    };
    for ([_]i32{ -500, -80, 0, 80, 500 }) |exponent| {
        for (cubics) |source| {
            var curve = source;
            for (&curve.points) |*point| {
                point.x = std.math.ldexp(point.x, exponent);
                point.y = std.math.ldexp(point.y, exponent);
            }
            try std.testing.expectEqualDeep(unconditionalExtremaBounds(curve), curve.bounds());
            const reversed = curve.reverse();
            try std.testing.expectEqualDeep(unconditionalExtremaBounds(reversed), reversed.bounds());
        }
        for (quads) |source| {
            var curve = source;
            for (&curve.points) |*point| {
                point.x = std.math.ldexp(point.x, exponent);
                point.y = std.math.ldexp(point.y, exponent);
            }
            try std.testing.expectEqualDeep(unconditionalExtremaBounds(curve), curve.bounds());
            const reversed = curve.reverse();
            try std.testing.expectEqualDeep(unconditionalExtremaBounds(reversed), reversed.bounds());
        }
    }
    var tiny = cubics[1];
    for (&tiny.points) |*point| {
        point.x = std.math.ldexp(point.x, -80);
        point.y = std.math.ldexp(point.y, -80);
    }
    // Existing tolerant monotonicity is intentionally unchanged. It is not
    // sufficient to discard this curve's nonzero interior extrema.
    try std.testing.expect(tiny.monotonicInY());
    try std.testing.expect(tiny.bounds().min.y < 0);
    try std.testing.expect(tiny.bounds().max.y > 0);
}

test "upstream curve hull and linearity methods compile and retain strict separation" {
    const cubic: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } };
    const quad: Quad = .{ .points = .{ .{ .x = 0, .y = 2 }, .{ .x = 2, .y = -1 }, .{ .x = 4, .y = 2 } } };
    const far: Quad = .{ .points = .{ .{ .x = 10, .y = 2 }, .{ .x = 12, .y = -1 }, .{ .x = 14, .y = 2 } } };
    var linear = false;
    try std.testing.expect(!(Curve{ .cubic = cubic }).hullIntersects(&.{ .quad = far }, &linear));
    try std.testing.expect(!(Curve{ .quad = far }).hullIntersects(&.{ .cubic = cubic }, &linear));
    try std.testing.expect((Curve{ .quad = quad }).hullIntersects(&.{ .cubic = cubic }, &linear));
    try std.testing.expect(quad.hullIntersects(quad, &linear));
    try std.testing.expect(cubic.hullIntersects(cubic, &linear));
    try std.testing.expect(!cubic.isLinear(0, 3));
    try std.testing.expect(!quad.isLinear(0, 2));
    try std.testing.expect(cubic.bounds().valid());
    try std.testing.expect(!(Curve{ .cubic = cubic }).collapsed());
    try std.testing.expectEqual(@as(usize, 4), (Curve{ .cubic = cubic }).pointCount());
    try std.testing.expect((Curve{ .cubic = cubic }).point(3).eql(cubic.points[3]));
    _ = cubic.controlsInside();
    _ = quad.controlsInside();
}

test "hull Y projection preserves original rotation bits and degeneracy" {
    const Reference = struct {
        // The original full rotation is retained only as the test oracle.
        fn rotate(curve: Cubic, zero: usize, index: usize) ?Cubic {
            const dy = curve.points[index].y - curve.points[zero].y;
            const dx = curve.points[index].x - curve.points[zero].x;
            var result = curve;
            if (n.approximatelyZero(dy)) {
                if (n.approximatelyZero(dx)) return null;
                if (dy != 0) {
                    result.points[index].y = curve.points[zero].y;
                    const mask = otherTwo(index, zero);
                    const side1 = index ^ mask;
                    const side2 = zero ^ mask;
                    if (n.approximatelyEqual(curve.points[side1].y, curve.points[zero].y)) result.points[side1].y = curve.points[zero].y;
                    if (n.approximatelyEqual(curve.points[side2].y, curve.points[zero].y)) result.points[side2].y = curve.points[zero].y;
                }
                return result;
            }
            for (curve.points, &result.points) |point, *out| out.* = .{ .x = point.x * dx + point.y * dy, .y = point.y * dx - point.x * dy };
            return result;
        }

        fn check(points: [4]Point) !void {
            const curve: Cubic = .{ .points = points };
            for (0..4) |zero| for (0..4) |index| {
                const marker: f64 = @bitCast(@as(u64, 0x7ff8000000000055));
                var actual: [4]f64 = @splat(marker);
                const expected = rotate(curve, zero, index);
                try std.testing.expectEqual(expected != null, curve.rotateHullY(zero, index, &actual));
                if (expected) |want| {
                    for (want.points, actual) |point, value| try std.testing.expectEqual(@as(u64, @bitCast(point.y)), @as(u64, @bitCast(value)));
                } else {
                    for (actual) |value| try std.testing.expectEqual(@as(u64, @bitCast(marker)), @as(u64, @bitCast(value)));
                }
            };
        }

        fn scales(points: [4]Point) !void {
            for ([_]i32{ -900, -500, -80, 0, 80, 500, 900 }) |exponent| {
                var scaled: [4]Point = undefined;
                for (points, &scaled) |point, *out| out.* = .{
                    .x = std.math.ldexp(point.x, exponent),
                    .y = std.math.ldexp(point.y, exponent),
                };
                try check(scaled);
                try check(.{ scaled[3], scaled[2], scaled[1], scaled[0] });
            }
        }
    };
    const fixtures = [_][4]Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 3 } },
        .{ .{ .x = -0.0, .y = 0 }, .{ .x = 0, .y = -0.0 }, .{ .x = -0.0, .y = -0.0 }, .{ .x = 0, .y = 0 } },
        .{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = n.EPSILON / 2 }, .{ .x = 2, .y = -n.EPSILON / 2 }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = n.EPSILON }, .{ .x = 2, .y = -n.EPSILON }, .{ .x = 3, .y = 0 } },
        .{ .{ .x = -1, .y = -1 }, .{ .x = 0.5, .y = 1 }, .{ .x = -0.5, .y = 1 }, .{ .x = 1, .y = -1 } },
    };
    for (fixtures) |points| try Reference.scales(points);
    var prng: std.Random.DefaultPrng = .init(0x6ad2a8e4172c3f5b);
    const random = prng.random();
    for (0..64) |_| {
        var points: [4]Point = undefined;
        for (&points) |*point| point.* = .{ .x = (random.float(f64) - 0.5) * 8, .y = (random.float(f64) - 0.5) * 8 };
        try Reference.scales(points);
    }
}

test "merged cubic endpoints shift adjacent controls while retaining source alignment" {
    const c: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 4, .y = 2 } } };
    const sub = c.subDivide(0, 0.5);
    const delta: Point = .{ .x = 0.001, .y = -0.002 };
    const endpoint = sub.points[3].add(delta);
    const adjusted = c.subDivideWithEnds(c.points[0], endpoint, 0, 0.5);
    try std.testing.expect(adjusted.points[0].eql(c.points[0]));
    try std.testing.expect(adjusted.points[3].eql(endpoint));
    try std.testing.expectEqual(@as(f64, 0), adjusted.points[1].y);
    try std.testing.expect(adjusted.points[2].eql(sub.points[2].add(endpoint.sub(sub.points[3]))));
    const reversed = c.subDivideWithEnds(endpoint, c.points[0], 0.5, 0);
    try std.testing.expectEqual(@as(f64, 0), reversed.points[2].y);
    try std.testing.expect(reversed.points[3].eql(c.points[0]));
}

test "axis line proximity uses its constant-coordinate ULP budget" {
    const line: Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1e5, .y = 0 } } };
    try std.testing.expectEqual(@as(f64, -1), line.nearPoint(.{ .x = 5e4, .y = 1e-12 }, null));
    try std.testing.expectEqual(@as(f64, -1), Line.nearPointH(.{ .x = 5e4, .y = 1e-12 }, 0, 1e5, 0));
    var unequal = true;
    try std.testing.expectEqual(@as(f64, 0.5), line.nearPoint(.{ .x = 5e4, .y = 0 }, &unequal));
    try std.testing.expect(!unequal);
    try std.testing.expectEqual(@as(f64, 0), line.exactPoint(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(f64, 1), line.exactPoint(.{ .x = 1e5, .y = 0 }));
    try std.testing.expect(line.nearRay(.{ .x = 2e5, .y = 0 }));
}

test "line evaluation matches reference rounding before coincidence classification" {
    // Captured from the existing 65-knot continuous taper. These lines have
    // distinct coverage; an extra intermediate rounding made D16 accept the
    // last pair and later produced an inconsistent coincident parameter run.
    const a: Line = .{ .points = .{
        .{ .x = 0.45588299192121773, .y = -0.42502936011202347 },
        .{ .x = 0.48970774818035510, .y = -0.45885411637116086 },
    } };
    const b: Line = .{ .points = .{
        .{ .x = 0.48970774818035570, .y = -0.45885411637116020 },
        .{ .x = 0.45588299192121840, .y = -0.42502936011202290 },
    } };
    // Verified against the retained C++ SkDLine::ptAtT, not another Zig path.
    const expected = [3][2][2]u64{
        .{ .{ 0x3fde424783045fc6, 0xbfdc48c6001f0abf }, .{ 0x3fde424783045fd1, 0xbfdc48c6001f0ab4 } },
        .{ .{ 0x3fde42478304261b, 0xbfdc48c6001ed114 }, .{ 0x3fde424783042626, 0xbfdc48c6001ed109 } },
        .{ .{ 0x3fde424783049971, 0xbfdc48c6001f446a }, .{ 0x3fde42478304997c, 0xbfdc48c6001f445f } },
    };
    for ([_]f64{ 0.5, 0.49999999997577140, 0.50000000002422860 }, expected) |t, bits| {
        const pa = a.ptAtT(t);
        const pb = b.ptAtT(1 - t);
        for ([_]Point{ pa, pb }, bits) |point, coordinates| {
            try std.testing.expectEqual(coordinates[0], @as(u64, @bitCast(point.x)));
            try std.testing.expectEqual(coordinates[1], @as(u64, @bitCast(point.y)));
        }
        try std.testing.expect(!pa.approximatelyDEqual(pb));
    }
}
