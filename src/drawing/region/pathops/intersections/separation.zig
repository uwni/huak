// Copyright 2026 Huak contributors. BSD-style license: ../LICENSE.
//! Conservative separation of cubic curves sharing a monotone coordinate.
const std = @import("std");
const curves = @import("../curve.zig");
const n = @import("../numeric.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const max_coordinate = 0x1p100;

/// A sufficient separation certificate, never a replacement root solver.
/// For cubics sharing a monotone coordinate, equal values on that axis imply
/// equal parameters. Also bound near contacts before skipping compensated work.
pub fn disjoint(a: Curve, b: Curve) bool {
    if (a != .cubic or b != .cubic) return false;
    const first = a.cubic.points;
    const second = b.cubic.points;
    var shared_x = true;
    var shared_y = true;
    for (first, second) |p, q| {
        shared_x = shared_x and p.x == q.x;
        shared_y = shared_y and p.y == q.y;
        if (!shared_x and !shared_y) return false;
    }
    var magnitude: f64 = 1;
    for (first, second) |p, q| {
        if (!p.isFinite() or !q.isFinite()) return false;
        magnitude = @max(magnitude, @max(@max(@abs(p.x), @abs(p.y)), @max(@abs(q.x), @abs(q.y))));
    }
    // Outside this normal working domain leave all decisions to refinement.
    if (magnitude > max_coordinate) return false;
    // A conservative exclusion margin, not a changed acceptance threshold:
    // it covers Point's 256-ULP/denormal prerequisite and forward error in
    // ordinary source/subcurve evaluation as well as DD evaluation.
    const error_bound = 4096 * n.EPSILON * magnitude;
    inline for ([_]curves.Axis{ .x, .y }) |axis| {
        const other_axis: curves.Axis = if (axis == .x) .y else .x;
        if (separatedCoordinate(first, second, axis, other_axis, error_bound)) return true;
    }
    return false;
}

/// A sufficient uniqueness certificate, not a root finder. A common strictly
/// monotone coordinate makes both curves graphs. Their ordinate difference is
/// strictly monotone when every tensor Bernstein coefficient of their Jacobian
/// has one nonzero sign, so their common coordinate interval has at most one root.
pub fn atMostOne(a: Curve, b: Curve) bool {
    if (!bounded(a) or !bounded(b)) return false;
    var first: [3]curves.Bounds = undefined;
    var second: [3]curves.Bounds = undefined;
    const da = first[0..derivativeBounds(a, &first)];
    const db = second[0..derivativeBounds(b, &second)];
    if (!((monotone(da, .x) and monotone(db, .x)) or (monotone(da, .y) and monotone(db, .y)))) return false;
    var positive = true;
    var negative = true;
    for (da) |p| for (db) |q| {
        const xy = productBounds(p.min.x, p.max.x, q.min.y, q.max.y);
        const yx = productBounds(p.min.y, p.max.y, q.min.x, q.max.x);
        positive = positive and down(xy[0] - yx[1]) > 0;
        negative = negative and up(xy[1] - yx[0]) < 0;
        if (!positive and !negative) return false;
    };
    return positive or negative;
}
fn bounded(curve: Curve) bool {
    return switch (curve) {
        inline else => |value| blk: {
            for (value.points) |point| if (!point.isFinite() or @abs(point.x) > max_coordinate or @abs(point.y) > max_coordinate) break :blk false;
            break :blk true;
        },
    };
}
fn derivativeBounds(curve: Curve, result: *[3]curves.Bounds) usize {
    return switch (curve) {
        inline else => |value| blk: {
            const degree = value.points.len - 1;
            for (0..degree) |index| {
                const p = value.points[index];
                const q = value.points[index + 1];
                result[index] = .{
                    .min = .{ .x = down(degree * down(q.x - p.x)), .y = down(degree * down(q.y - p.y)) },
                    .max = .{ .x = up(degree * up(q.x - p.x)), .y = up(degree * up(q.y - p.y)) },
                };
            }
            break :blk degree;
        },
    };
}
fn monotone(values: []const curves.Bounds, comptime axis: curves.Axis) bool {
    var positive = true;
    var negative = true;
    for (values) |value| {
        positive = positive and @field(value.min, @tagName(axis)) > 0;
        negative = negative and @field(value.max, @tagName(axis)) < 0;
    }
    return positive or negative;
}
fn productBounds(a0: f64, a1: f64, b0: f64, b1: f64) [2]f64 {
    const values = [_]f64{ a0 * b0, a0 * b1, a1 * b0, a1 * b1 };
    return .{ down(@reduce(.Min, @as(@Vector(4, f64), values))), up(@reduce(.Max, @as(@Vector(4, f64), values))) };
}

fn down(value: f64) f64 {
    return std.math.nextAfter(f64, value, -std.math.inf(f64));
}
fn up(value: f64) f64 {
    return std.math.nextAfter(f64, value, std.math.inf(f64));
}
fn separatedCoordinate(a: [4]Point, b: [4]Point, comptime shared: curves.Axis, comptime separated: curves.Axis, error_bound: f64) bool {
    const shared_name = @tagName(shared);
    const separated_name = @tagName(separated);
    for (a, b) |p, q| if (@field(p, shared_name) != @field(q, shared_name)) return false;
    const increasing = @field(a[3], shared_name) > @field(a[0], shared_name);
    const direction: f64 = if (increasing) 1 else -1;
    for (0..3) |i| if (direction * @field(a[i + 1], shared_name) < direction * @field(a[i], shared_name)) return false;
    const middle = down(direction * (@field(a[2], shared_name) - @field(a[1], shared_name)));
    if (!(middle > 0)) return false;
    const side: f64 = if (@field(a[0], separated_name) > @field(b[0], separated_name)) 1 else -1;
    var gap = std.math.inf(f64);
    var derivative_bound: f64 = 0;
    for (a, b) |p, q| gap = @min(gap, down(side * (@field(p, separated_name) - @field(q, separated_name))));
    if (!(gap > error_bound)) return false;
    for (0..3) |i| derivative_bound = @max(derivative_bound, up(@abs(@field(b[i + 1], separated_name) - @field(b[i], separated_name))));
    derivative_bound = up(3 * derivative_bound);
    const h = down(down(gap - error_bound) / derivative_bound);
    if (!(h > 0)) return false;
    if (h > 1) return true;
    // The shared derivative contains 6*middle*t*(1-t). Its integral over
    // any interval of length h is >= middle*(3*h*h-2*h*h*h) >= middle*h*h.
    // Thus a near contact on the other axis forces a shared-axis gap too big
    // for the original point predicate. Every computed lower bound rounds out.
    return down(down(middle * h) * h) > error_bound;
}

test "separation captures six unsuccessful near-coincident refinements" {
    const guard = @import("guard.zig");
    const Fixture = struct {
        fn curve(bits: [4][2]u64) Curve {
            var points: [4]Point = undefined;
            for (bits, &points) |coordinates, *point| point.* = .{
                .x = @bitCast(coordinates[0]),
                .y = @bitCast(coordinates[1]),
            };
            return .{ .cubic = .{ .points = points } };
        }
        fn transform(source: Curve, mode: u8) Curve {
            var result = source;
            for (&result.cubic.points) |*point| {
                if (mode & 1 != 0) std.mem.swap(f64, &point.x, &point.y);
                if (mode & 8 != 0) point.x = -point.x;
                if (mode & 16 != 0) point.y = -point.y;
            }
            return if (mode & 4 != 0) result.reverse() else result;
        }
        fn reverseRange(range: guard.Range) guard.Range {
            return .{ .start = 1 - range.end, .end = 1 - range.start };
        }
        fn expectFailure(a: Curve, b: Curve, ar: guard.Range, br: guard.Range) !void {
            var t = (ar.start + ar.end) * 0.5;
            var u = (br.start + br.end) * 0.5;
            const before_t: u64 = @bitCast(t);
            const before_u: u64 = @bitCast(u);
            var point: Point = .{ .x = -12.5, .y = 3.25 };
            try std.testing.expect(!guard.refineWithin(a, b, ar, br, &t, &u, &point));
            try std.testing.expectEqual(before_t, @as(u64, @bitCast(t)));
            try std.testing.expectEqual(before_u, @as(u64, @bitCast(u)));
            try std.testing.expectEqual(@as(f64, -12.5), point.x);
            try std.testing.expectEqual(@as(f64, 3.25), point.y);
        }
    };
    // Exact source controls and six span rectangles from one original
    // near_coincident_1e-4 combine; the unfiltered refiner is the old oracle.
    const pairs = [_][2]Curve{
        .{ Fixture.curve(.{
            .{ 0x3fedfffcb923a29c, 0x0000000000000000 },
            .{ 0x3fedfffcb923a29c, 0x3fe0918c003e1580 },
            .{ 0x3fe09188b961b81c, 0x3fee000000000000 },
            .{ 0xbeba36e2eb200000, 0x3fee000000000000 },
        }), Fixture.curve(.{
            .{ 0x3fee000346dc5d64, 0x0000000000000000 },
            .{ 0x3fee000346dc5d64, 0x3fe0918c003e1580 },
            .{ 0x3fe0918f471a72e4, 0x3fee000000000000 },
            .{ 0x3eba36e2eb200000, 0x3fee000000000000 },
        }) },
        .{ Fixture.curve(.{
            .{ 0xbeba36e2eb200000, 0xbfee000000000000 },
            .{ 0x3fe09188b961b81c, 0xbfee000000000000 },
            .{ 0x3fedfffcb923a29c, 0xbfe0918c003e1580 },
            .{ 0x3fedfffcb923a29c, 0x0000000000000000 },
        }), Fixture.curve(.{
            .{ 0x3eba36e2eb200000, 0xbfee000000000000 },
            .{ 0x3fe0918f471a72e4, 0xbfee000000000000 },
            .{ 0x3fee000346dc5d64, 0xbfe0918c003e1580 },
            .{ 0x3fee000346dc5d64, 0x0000000000000000 },
        }) },
    };
    const h: f64 = 0x1p-18;
    const ranges = [2][3][2]guard.Range{
        .{
            .{ .{ .start = 1 - 2 * h, .end = 1 - h }, .{ .start = 1 - h } },
            .{ .{ .start = 1 - 2 * h, .end = 1 - h }, .{ .start = 1 - 2 * h, .end = 1 - h } },
            .{ .{ .start = 1 - h }, .{ .start = 1 - h } },
        },
        .{
            .{ .{ .end = h }, .{ .end = h } },
            .{ .{ .start = h, .end = 2 * h }, .{ .end = h } },
            .{ .{ .start = 2 * h, .end = 3 * h }, .{ .start = h, .end = 2 * h } },
        },
    };
    for (pairs, ranges) |pair, rectangles| for ([_]u8{ 0, 1, 2, 4, 8, 16 }) |mode| {
        var a = Fixture.transform(pair[0], mode);
        var b = Fixture.transform(pair[1], mode);
        if (mode & 2 != 0) std.mem.swap(Curve, &a, &b);
        try std.testing.expect(disjoint(a, b));
        for (rectangles) |rectangle| {
            var ar = rectangle[0];
            var br = rectangle[1];
            if (mode & 4 != 0) {
                ar = Fixture.reverseRange(ar);
                br = Fixture.reverseRange(br);
            }
            if (mode & 2 != 0) std.mem.swap(guard.Range, &ar, &br);
            try Fixture.expectFailure(a, b, ar, br);
        }
    };
}

test "separation preserves intersections coincidence and near contacts" {
    const a: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 },
    } } };
    const crossing: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 },
    } } };
    try std.testing.expect(!disjoint(a, crossing));
    try std.testing.expect(!disjoint(a, a));
    try std.testing.expect(!disjoint(a, a.reverse()));

    const base: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0.25 }, .{ .x = 2, .y = 0.75 }, .{ .x = 3, .y = 1 },
    } } };
    var near = base;
    for (&near.cubic.points) |*point| point.y += 0x1p-52;
    try std.testing.expect(base.ptAtT(0.5).approximatelyEqual(near.ptAtT(0.5)));
    try std.testing.expect(!disjoint(base, near));
    var endpoint = base;
    for (&endpoint.cubic.points) |*point| point.y += 0.125;
    endpoint.cubic.points[3] = base.cubic.points[3];
    try std.testing.expect(!disjoint(base, endpoint));
    endpoint.cubic.points[3].y = std.math.nextAfter(f64, base.cubic.points[3].y, std.math.inf(f64));
    try std.testing.expect(!disjoint(base, endpoint));
    var nonmonotone = base;
    nonmonotone.cubic.points[1].x = 2;
    nonmonotone.cubic.points[2].x = -1;
    var translated = nonmonotone;
    for (&translated.cubic.points) |*point| point.y += 0.125;
    try std.testing.expect(!disjoint(nonmonotone, translated));
}

test "separation remains conservative across scales special values and degrees" {
    const base: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0.25 }, .{ .x = 2, .y = 0.75 }, .{ .x = 3, .y = 1 },
    } } };
    var translated = base;
    for (&translated.cubic.points) |*point| point.y += 0.125;
    for ([_]i32{ -80, 0, 8, 80, 101 }) |exponent| {
        var a = base;
        var b = translated;
        for (&a.cubic.points, &b.cubic.points) |*p, *q| {
            p.x = std.math.ldexp(p.x, exponent);
            p.y = std.math.ldexp(p.y, exponent);
            q.x = std.math.ldexp(q.x, exponent);
            q.y = std.math.ldexp(q.y, exponent);
        }
        if (exponent == -80 or exponent == 101) {
            try std.testing.expect(!disjoint(a, b));
        } else {
            try std.testing.expect(disjoint(a, b));
            try std.testing.expect(disjoint(b, a));
            try std.testing.expect(disjoint(a.reverse(), b.reverse()));
        }
    }
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |special| {
        var invalid = base;
        invalid.cubic.points[1].y = special;
        try std.testing.expect(!disjoint(invalid, translated));
        try std.testing.expect(!disjoint(translated, invalid));
    }
    const line: Curve = .{ .line = .{ .points = base.cubic.points[0..2].* } };
    const quad: Curve = .{ .quad = .{ .points = base.cubic.points[0..3].* } };
    try std.testing.expect(!disjoint(base, line));
    try std.testing.expect(!disjoint(quad, translated));
}

test "uniqueness certificate supports independent directions scales and mixed degrees" {
    const first: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1.5 }, .{ .x = 3, .y = 3 } } } };
    const second: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 3 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 1.5 }, .{ .x = 3, .y = 0 } } } };
    for ([_]i32{ -400, -8, 0, 8, 80 }) |exponent| for (0..4) |directions| for (0..2) |swapped| for (0..2) |axes| {
        var a = first;
        var b = second;
        if (directions & 1 != 0) a = a.reverse();
        if (directions & 2 != 0) b = b.reverse();
        for (&a.cubic.points, &b.cubic.points) |*p, *q| {
            p.* = .{ .x = std.math.ldexp(p.x, exponent), .y = std.math.ldexp(p.y, exponent) };
            q.* = .{ .x = std.math.ldexp(q.x, exponent), .y = std.math.ldexp(q.y, exponent) };
            if (axes != 0) {
                std.mem.swap(f64, &p.x, &p.y);
                std.mem.swap(f64, &q.x, &q.y);
            }
        }
        try std.testing.expect(if (swapped == 0) atMostOne(a, b) else atMostOne(b, a));
    };
    const line: Curve = .{ .line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 3 } } } };
    const quad: Curve = .{ .quad = .{ .points = .{ .{ .x = 0, .y = 3 }, .{ .x = 1.5, .y = 2 }, .{ .x = 3, .y = 0 } } } };
    try std.testing.expect(atMostOne(line, quad));
    try std.testing.expect(atMostOne(quad.reverse(), line));
    try std.testing.expect(atMostOne(first, quad));
}

test "uniqueness certificate rejects double intersections tangencies and unresolved bounds" {
    const a: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } } };
    const b: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } } };
    try std.testing.expect(!atMostOne(a, b));
    try std.testing.expect(!atMostOne(a.reverse(), b));
    try std.testing.expect(!atMostOne(a, b.reverse()));
    try std.testing.expect(!atMostOne(a, a));
    const line: Curve = .{ .line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } } } };
    var near_parallel = line;
    near_parallel.line.points[1].y = std.math.nextAfter(f64, 1, 2);
    try std.testing.expect(!atMostOne(line, near_parallel));
    var invalid = line;
    invalid.line.points[0].x = std.math.nan(f64);
    try std.testing.expect(!atMostOne(line, invalid));
    invalid.line.points[0].x = 0x1p101;
    try std.testing.expect(!atMostOne(line, invalid));
    invalid = line;
    invalid.line.points[1] = invalid.line.points[0];
    try std.testing.expect(!atMostOne(line, invalid));
    invalid = line;
    invalid.line.points[1] = .{ .x = @bitCast(@as(u64, 1)), .y = @bitCast(@as(u64, 2)) };
    try std.testing.expect(!atMostOne(line, invalid));
}
