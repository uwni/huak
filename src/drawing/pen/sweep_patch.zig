//! The determinant of a bilinear edge patch is affine on the parameter
//! square. The advancing sheet has negative determinant for a CCW nib.
//! Only its fold and the uncancelled sides contribute to the swept boundary.
//! F(u,t)=a+u(b-a)+t(c-a)+ut(d-b-c+a). On the line det(Fu,Ft)=0,
//! F is quadratic. Its endpoints and quadratic coefficient determine both
//! cubic controls by exact degree elevation, before floating-point rounding.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Boundary = @import("SweepBoundary.zig");
const square = [4]Point{ .zero, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } };

pub const Side = struct {
    a: f64,
    b: f64,
    pub const all: Side = .{ .a = -1, .b = -1 };
    pub const none: Side = .{ .a = 1, .b = 1 };
    fn changes(self: Side) bool {
        return self.a < 0 and self.b > 0 or self.a > 0 and self.b < 0;
    }
    fn root(self: Side) f64 {
        const n = @max(@abs(self.a), @abs(self.b));
        return (self.a / n) / (self.a / n - self.b / n);
    }
    fn inside(self: Side, u: f64) bool {
        return (1 - u) * self.a + u * self.b < 0;
    }
};

// Emit the oriented difference of two sheet restrictions on the same edge.
// Interior mesh edges are cancelled here, before allocating any geometry.
pub fn difference(out: *Boundary, a: Point, b: Point, positive: Side, negative: Side) !void {
    if (!positive.changes() and !negative.changes()) {
        const p = positive.a < 0 or positive.b < 0;
        const n = negative.a < 0 or negative.b < 0;
        if (p != n) try out.line(if (p) a else b, if (p) b else a);
        return;
    }
    var cuts = [4]f64{ 0, 1, 1, 1 };
    if (positive.changes()) cuts[1] = positive.root();
    if (negative.changes()) cuts[2] = negative.root();
    if (cuts[2] < cuts[1]) std.mem.swap(f64, &cuts[1], &cuts[2]);
    for (cuts[0..3], cuts[1..]) |lo, hi| {
        if (hi <= lo) continue;
        const mid = (lo + hi) / 2;
        const p = positive.inside(mid);
        if (p == negative.inside(mid)) continue;
        const from = a.lerp(b, lo);
        const to = a.lerp(b, hi);
        try out.line(if (p) from else to, if (p) to else from);
    }
}

pub const Patch = struct {
    a: Point,
    b: Point,
    c: Point,
    d: Point,
    pub fn map(self: Patch, p: Point) Point {
        return self.a.lerp(self.b, p.x).lerp(self.c.lerp(self.d, p.x), p.y);
    }
    pub fn sides(self: Patch) !Sides {
        const e0 = self.b.sub(self.a);
        const e1 = self.d.sub(self.c);
        const va = self.c.sub(self.a);
        const vb = self.d.sub(self.b);
        const j = [4]f64{ cross(e0, va), cross(e0, vb), cross(e1, vb), cross(e1, va) };
        for (j) |v| if (!std.math.isFinite(v)) return error.PrecisionRange;
        return .{ .bottom = .{ .a = j[0], .b = j[1] }, .right = .{ .a = j[1], .b = j[2] }, .top = .{ .a = j[3], .b = j[2] }, .left = .{ .a = j[0], .b = j[3] } };
    }

    pub fn fold(self: Patch, s: Sides, out: *Boundary) !void {
        const j = [4]f64{ s.bottom.a, s.bottom.b, s.top.b, s.top.a };
        if (@reduce(.Min, @as(@Vector(4, f64), j)) >= 0 or @reduce(.Max, @as(@Vector(4, f64), j)) <= 0) return;
        const edges = [4]Side{ s.bottom, s.right, s.top, s.left };
        var enter: ?Point = null;
        var leave: ?Point = null;
        for (edges, 0..) |edge, i| {
            const k = (i + 1) % 4;
            if ((j[i] < 0) == (j[k] < 0)) continue;
            const p = if (j[i] == 0) square[i] else if (j[k] == 0) square[k] else switch (i) {
                0 => Point{ .x = edge.root(), .y = 0 },
                1 => Point{ .x = 1, .y = edge.root() },
                2 => Point{ .x = edge.root(), .y = 1 },
                3 => Point{ .x = 0, .y = edge.root() },
                else => unreachable,
            };
            if (j[k] < 0) enter = p else leave = p;
        }
        const p = enter orelse return error.PrecisionRange;
        const q = leave orelse return error.PrecisionRange;
        const start = self.map(p);
        const end = self.map(q);
        const quadratic = self.d.sub(self.b).sub(self.c.sub(self.a)).scale((q.x - p.x) * (q.y - p.y));
        if (quadratic.eql(.zero)) return out.line(start, end);
        const delta = end.sub(start);
        if (out.curves.items.len + out.lines.count() >= out.limit) return error.GeometryWorkLimit;
        try out.curves.append(out.allocator, .{ .p0 = start, .p1 = start.add(delta.sub(quadratic).scale(1.0 / 3.0)), .p2 = end.sub(delta.add(quadratic).scale(1.0 / 3.0)), .p3 = end });
    }
};

pub const Sides = struct {
    bottom: Side,
    right: Side,
    top: Side,
    left: Side,
    // On an identically stationary side use the one-sided interior sign.
    pub fn interior(a: Side, opposite: Side) Side {
        return if (a.a == 0 and a.b == 0) opposite else a;
    }
};

fn cross(a: Point, b: Point) f64 {
    const product = a.y * b.x;
    return @mulAdd(f64, a.x, b.y, -product) - @mulAdd(f64, a.y, b.x, -product);
}

test "fold of (u+t,ut) is exactly the parabola (2t,t squared)" {
    const p: Patch = .{ .a = .zero, .b = .{ .x = 1, .y = 0 }, .c = .{ .x = 1, .y = 0 }, .d = .{ .x = 2, .y = 1 } };
    var out: Boundary = .{ .allocator = std.testing.allocator, .limit = 12 };
    defer out.deinit();
    try p.fold(try p.sides(), &out);
    try std.testing.expectEqual(@as(usize, 1), out.curves.items.len);
    const mid = out.curves.items[0].at(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1), mid.x, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), mid.y, 1e-14);
}
