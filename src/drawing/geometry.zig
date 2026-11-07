//! Independent, double precision geometry. Angles are in radians; lengths use
//! the caller's common coordinate unit (the native scene adapter uses points).
const std = @import("std");

pub const Numeric = f64;
pub const Pair = Point;

pub const Tolerance = struct {
    absolute: f64 = 1e-9,
    relative: f64 = 1e-12,

    pub fn threshold(self: Tolerance, a: f64, b: f64) f64 {
        return self.absolute + self.relative * @max(@abs(a), @abs(b));
    }
    pub fn equal(self: Tolerance, a: f64, b: f64) bool {
        return std.math.isFinite(a) and std.math.isFinite(b) and @abs(a - b) <= self.threshold(a, b);
    }
    pub fn points(self: Tolerance, a: Point, b: Point) bool {
        return self.equal(a.x, b.x) and self.equal(a.y, b.y);
    }
};
pub const tolerance: Tolerance = .{};

pub const Point = struct {
    x: f64,
    y: f64,

    pub const zero: Point = .{ .x = 0, .y = 0 };
    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Point, s: f64) Point {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: Point, b: Point) f64 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn cross(a: Point, b: Point) f64 {
        return a.x * b.y - a.y * b.x;
    }
    pub fn norm(a: Point) f64 {
        return std.math.hypot(a.x, a.y);
    }
    pub fn distance(a: Point, b: Point) f64 {
        return a.sub(b).norm();
    }
    pub fn normalized(a: Point) error{ ZeroVector, NonFinite }!Point {
        if (!a.isFinite()) return error.NonFinite;
        const magnitude = @max(@abs(a.x), @abs(a.y));
        if (magnitude == 0) return error.ZeroVector;
        const reduced: Point = .{ .x = a.x / magnitude, .y = a.y / magnitude };
        const length = reduced.norm();
        return .{ .x = reduced.x / length, .y = reduced.y / length };
    }
    pub fn isFinite(a: Point) bool {
        return std.math.isFinite(a.x) and std.math.isFinite(a.y);
    }
    pub inline fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
    pub fn lerp(a: Point, b: Point, t: f64) Point {
        return a.scale(1 - t).add(b.scale(t));
    }
};

/// Column-vector affine transform: x'=a*x+c*y+e, y'=b*x+d*y+f.
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub fn translation(x: f64, y: f64) Transform {
        return .{ .e = x, .f = y };
    }
    pub fn scaling(x: f64, y: f64) Transform {
        return .{ .a = x, .d = y };
    }
    pub fn rotation(angle: f64) Transform {
        if (@abs(angle) == std.math.pi / 2.0) {
            const sign: f64 = if (angle > 0) 1 else -1;
            return .{ .a = 0, .b = sign, .c = -sign, .d = 0 };
        }
        const s = @sin(angle);
        const c = @cos(angle);
        return .{ .a = c, .b = s, .c = -s, .d = c };
    }
    /// Map local +x along the given vector and local +y to its left normal.
    pub fn fromXAxis(direction: Point) !Transform {
        const t = try direction.normalized();
        return .{ .a = t.x, .b = t.y, .c = -t.y, .d = t.x };
    }
    pub fn apply(self: Transform, p: Point) Point {
        return .{ .x = self.a * p.x + self.c * p.y + self.e, .y = self.b * p.x + self.d * p.y + self.f };
    }
    /// Apply self first, then next.
    pub fn then(self: Transform, next: Transform) Transform {
        return .{
            .a = next.a * self.a + next.c * self.b,
            .b = next.b * self.a + next.d * self.b,
            .c = next.a * self.c + next.c * self.d,
            .d = next.b * self.c + next.d * self.d,
            .e = next.a * self.e + next.c * self.f + next.e,
            .f = next.b * self.e + next.d * self.f + next.f,
        };
    }
    pub fn isFinite(self: Transform) bool {
        inline for (.{ "a", "b", "c", "d", "e", "f" }) |name| {
            if (!std.math.isFinite(@field(self, name))) return false;
        }
        return true;
    }
    pub fn inverse(self: Transform) error{ SingularTransform, NonFinite }!Transform {
        if (!self.isFinite()) return error.NonFinite;
        const scale = @max(@max(@abs(self.a), @abs(self.b)), @max(@abs(self.c), @abs(self.d)));
        if (scale == 0) return error.SingularTransform;
        const a = self.a / scale;
        const b = self.b / scale;
        const c = self.c / scale;
        const d = self.d / scale;
        const det = a * d - b * c;
        if (det == 0) return error.SingularTransform;
        var result: Transform = .{ .a = (d / det) / scale, .b = (-b / det) / scale, .c = (-c / det) / scale, .d = (a / det) / scale };
        result.e = -result.a * self.e - result.c * self.f;
        result.f = -result.b * self.e - result.d * self.f;
        if (!result.isFinite()) return error.NonFinite;
        return result;
    }
};

pub const BBox = struct {
    min: Point,
    max: Point,

    pub fn fromPoint(p: Point) BBox {
        return .{ .min = p, .max = p };
    }
    pub fn fromPoints(a: Point, b: Point) BBox {
        return .{ .min = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) }, .max = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) } };
    }
    pub inline fn low(self: BBox, axis: usize) f64 {
        return if (axis == 0) self.min.x else self.min.y;
    }
    pub inline fn high(self: BBox, axis: usize) f64 {
        return if (axis == 0) self.max.x else self.max.y;
    }
    pub fn width(self: BBox) f64 {
        return self.max.x - self.min.x;
    }
    pub fn height(self: BBox) f64 {
        return self.max.y - self.min.y;
    }
    pub fn include(self: BBox, p: Point) BBox {
        return self.unite(fromPoint(p));
    }
    pub fn unite(self: BBox, other: BBox) BBox {
        return .{ .min = .{ .x = @min(self.min.x, other.min.x), .y = @min(self.min.y, other.min.y) }, .max = .{ .x = @max(self.max.x, other.max.x), .y = @max(self.max.y, other.max.y) } };
    }
    pub inline fn contains(self: BBox, p: Point) bool {
        return p.x >= self.min.x and p.x <= self.max.x and p.y >= self.min.y and p.y <= self.max.y;
    }
    pub fn overlaps(self: BBox, other: BBox, margin: f64) bool {
        return self.min.x <= other.max.x + margin and self.max.x + margin >= other.min.x and
            self.min.y <= other.max.y + margin and self.max.y + margin >= other.min.y;
    }
    pub fn expanded(self: BBox, amount: f64) BBox {
        return .{ .min = self.min.sub(.{ .x = amount, .y = amount }), .max = self.max.add(.{ .x = amount, .y = amount }) };
    }
    /// A transformed rectangle's bounds. For a transformed cubic use
    /// Cubic.transformed(...).bounds() to retain tight extrema.
    pub fn transformed(self: BBox, transform: Transform) BBox {
        return fromPoint(transform.apply(self.min)).include(transform.apply(self.max))
            .include(transform.apply(.{ .x = self.min.x, .y = self.max.y }))
            .include(transform.apply(.{ .x = self.max.x, .y = self.min.y }));
    }
};

pub const Cubic = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    pub fn line(start: Point, end: Point) Cubic {
        return .{ .p0 = start, .p1 = start.lerp(end, 1.0 / 3.0), .p2 = start.lerp(end, 2.0 / 3.0), .p3 = end };
    }
    pub fn isFinite(self: Cubic) bool {
        inline for (@typeInfo(Cubic).@"struct".field_names) |name| {
            if (!@field(self, name).isFinite()) return false;
        }
        return true;
    }
    pub fn at(self: Cubic, t: f64) Point {
        const ab = self.p0.lerp(self.p1, t);
        const bc = self.p1.lerp(self.p2, t);
        const cd = self.p2.lerp(self.p3, t);
        return ab.lerp(bc, t).lerp(bc.lerp(cd, t), t);
    }
    pub fn derivative(self: Cubic, t: f64) Point {
        const u = 1 - t;
        return self.p1.sub(self.p0).scale(3 * u * u).add(self.p2.sub(self.p1).scale(6 * u * t)).add(self.p3.sub(self.p2).scale(3 * t * t));
    }
    pub fn split(self: Cubic, t: f64) struct { left: Cubic, right: Cubic } {
        const a = self.p0.lerp(self.p1, t);
        const b = self.p1.lerp(self.p2, t);
        const c = self.p2.lerp(self.p3, t);
        const d = a.lerp(b, t);
        const e = b.lerp(c, t);
        const p = d.lerp(e, t);
        return .{ .left = .{ .p0 = self.p0, .p1 = a, .p2 = d, .p3 = p }, .right = .{ .p0 = p, .p1 = e, .p2 = c, .p3 = self.p3 } };
    }
    /// Exact de Casteljau restriction; t0/t1 must satisfy 0<=t0<=t1<=1.
    pub fn trimmed(self: Cubic, t0: f64, t1: f64) error{InvalidParameter}!Cubic {
        if (!std.math.isFinite(t0) or !std.math.isFinite(t1) or t0 < 0 or t1 > 1 or t0 > t1) return error.InvalidParameter;
        if (t0 == t1) {
            const p = self.at(t0);
            return .{ .p0 = p, .p1 = p, .p2 = p, .p3 = p };
        }
        if (t0 == 0) return self.split(t1).left;
        return self.split(t0).right.split((t1 - t0) / (1 - t0)).left;
    }
    pub fn reversed(self: Cubic) Cubic {
        return .{ .p0 = self.p3, .p1 = self.p2, .p2 = self.p1, .p3 = self.p0 };
    }
    pub fn transformed(self: Cubic, t: Transform) Cubic {
        return .{ .p0 = t.apply(self.p0), .p1 = t.apply(self.p1), .p2 = t.apply(self.p2), .p3 = t.apply(self.p3) };
    }
    pub fn controlBounds(self: Cubic) BBox {
        return BBox.fromPoints(self.p0, self.p3).include(self.p1).include(self.p2);
    }
    pub fn bounds(self: Cubic) BBox {
        var result = BBox.fromPoints(self.p0, self.p3);
        inline for (.{ "x", "y" }) |field| {
            const a = @field(self.p0, field);
            const b = @field(self.p1, field);
            const c = @field(self.p2, field);
            const d = @field(self.p3, field);
            // Scale before forming differences: finite controls near the f64
            // limit must not overflow in 3*b or in a subtraction of opposites.
            // Differences also avoid multiplying a large common translation.
            const magnitude = @max(@max(@abs(a), @abs(b)), @max(@abs(c), @abs(d)));
            const scale = if (magnitude == 0) 1 else magnitude;
            const ab = b / scale - a / scale;
            const bc = c / scale - b / scale;
            const cd = d / scale - c / scale;
            // derivative/3 = A*t^2+B*t+C, solved without cancellation.
            var roots: [2]f64 = undefined;
            const count = quadraticRoots(ab - 2 * bc + cd, 2 * (bc - ab), ab, &roots);
            for (roots[0..count]) |t| if (t > 0 and t < 1) {
                result = result.include(self.at(t));
            };
        }
        return result;
    }
};

/// Numerically stable real roots, including linear and repeated-root cases.
pub fn quadraticRoots(a: f64, b: f64, c: f64, roots: *[2]f64) usize {
    const scale = @max(@abs(a), @max(@abs(b), @abs(c)));
    if (scale == 0) return 0;
    const aa = a / scale;
    const bb = b / scale;
    const cc = c / scale;
    if (@abs(aa) <= 4 * std.math.floatEps(f64) * @abs(bb)) {
        if (bb == 0) return 0;
        roots[0] = -cc / bb;
        return 1;
    }
    const discriminant = bb * bb - 4 * aa * cc;
    if (discriminant < 0) return 0;
    if (discriminant == 0) {
        roots[0] = -bb / (2 * aa);
        return 1;
    }
    const q = -0.5 * (bb + std.math.copysign(@sqrt(discriminant), bb));
    roots[0] = q / aa;
    roots[1] = cc / q;
    if (roots[1] < roots[0]) std.mem.swap(f64, &roots[0], &roots[1]);
    return 2;
}

test "point arithmetic, finite values and mixed tolerance" {
    const a: Point = .{ .x = 3, .y = 4 };
    try std.testing.expectEqual(@as(f64, 5), a.norm());
    try std.testing.expectEqual(@as(f64, 25), a.dot(a));
    try std.testing.expectApproxEqAbs(@as(f64, 1), (try a.normalized()).norm(), 1e-14);
    for ([_]f64{ 1e-320, 1e308 }) |magnitude| {
        const unit = try (Point{ .x = magnitude, .y = magnitude }).normalized();
        try std.testing.expect(unit.isFinite());
        try std.testing.expectApproxEqAbs(@as(f64, 1), unit.norm(), 1e-14);
    }
    try std.testing.expectError(error.ZeroVector, Point.zero.normalized());
    try std.testing.expect(!tolerance.equal(std.math.inf(f64), std.math.inf(f64)));
    try std.testing.expect(tolerance.equal(1e8, 1e8 + 0.00001));
}

test "affine composition inversion and singular diagnostics" {
    const p: Point = .{ .x = 3, .y = -2 };
    const t = Transform.scaling(2, 3).then(Transform.rotation(std.math.pi / 2.0)).then(Transform.translation(5, 8));
    try std.testing.expect(tolerance.points(t.apply(p), .{ .x = 11, .y = 14 }));
    try std.testing.expect(tolerance.points((try t.inverse()).apply(t.apply(p)), p));
    try std.testing.expectError(error.SingularTransform, Transform.scaling(0, 1).inverse());
    try std.testing.expect(tolerance.points((try Transform.scaling(1e-10, 1e-10).inverse()).apply(.{ .x = 1e-10, .y = 1e-10 }), .{ .x = 1, .y = 1 }));
}

test "Bezier extrema, splitting and transformed tight bounds" {
    const curve: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 4 }, .p2 = .{ .x = 4, .y = 4 }, .p3 = .{ .x = 4, .y = 0 } };
    const b = curve.bounds();
    try std.testing.expectApproxEqAbs(@as(f64, 3), b.max.y, 1e-13);
    const halves = curve.split(0.4);
    try std.testing.expect(tolerance.points(curve.at(0.2), halves.left.at(0.5)));
    try std.testing.expect(tolerance.points(curve.at(0.7), halves.right.at(0.5)));
    const cut = try curve.trimmed(0.2, 0.8);
    try std.testing.expect(tolerance.points(cut.at(0.37), curve.at(0.2 + 0.6 * 0.37)));
    const rotated = curve.transformed(Transform.rotation(std.math.pi / 4.0));
    const tight = rotated.bounds();
    try std.testing.expect(tight.width() < b.transformed(Transform.rotation(std.math.pi / 4.0)).width());
    var i: usize = 0;
    while (i <= 1000) : (i += 1) try std.testing.expect(tight.expanded(1e-12).contains(rotated.at(@as(f64, @floatFromInt(i)) / 1000)));
}

test "near linear derivative and degenerate cubic bounds" {
    const line = Cubic.line(.{ .x = -4, .y = 6 }, .{ .x = 8, .y = 6 });
    try std.testing.expectEqual(@as(f64, 0), line.bounds().height());
    const point = Cubic.line(Point.zero, Point.zero);
    try std.testing.expectEqual(@as(f64, 0), point.bounds().width());
    try std.testing.expectError(error.InvalidParameter, line.trimmed(0.7, 0.3));
}

test "finite extreme-scale Bezier bounds contain their actual extrema" {
    for ([_]f64{ 1e-308, 1, 1e308 }) |scale| {
        const curve: Cubic = .{ .p0 = .zero, .p1 = .{ .x = 0, .y = scale }, .p2 = .{ .x = scale, .y = scale }, .p3 = .{ .x = scale, .y = 0 } };
        const box = curve.bounds();
        try std.testing.expect(box.min.isFinite() and box.max.isFinite());
        try std.testing.expect(box.contains(curve.at(0.5)));
        try std.testing.expectApproxEqRel(@as(f64, 0.75), box.max.y / scale, 1e-14);
        for (0..101) |i| try std.testing.expect(box.contains(curve.at(@as(f64, @floatFromInt(i)) / 100)));
    }
}
