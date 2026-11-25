// Copyright 2012 Google Inc.; BSD-style license: ../LICENSE.
// Native Zig binary64 port of SkPathOpsLine/Quad/Cubic and SkDCurve::nearPoint.
//! Tests of curve evaluation, restriction, bounds and line proximity.
const std = @import("std");
const Point = @import("../point.zig").Point;
const Bounds = @import("../point.zig").Bounds;
const curves = @import("../curve.zig");
const axis_roots = @import("axis_roots.zig");
const Quad = @import("Quad.zig");

test "cubic evaluation and coefficients preserve retained C++ fused rounding" {
    const rotated: curves.Cubic = .{ .points = .{
        .{ .x = 0.42473070360522436, .y = -0.9910383084121902 },
        .{ .x = 0.15106303148814484, .y = -0.9910383084121902 },
        .{ .x = -0.07078845060087073, .y = -0.7691868263231746 },
        .{ .x = -0.07078845060087073, .y = -0.4955191542060951 },
    } };
    const source: curves.Cubic = .{ .points = .{
        .{ .x = 0.3125, .y = 0 },
        .{ .x = 0.3125, .y = 0.3020307225637151 },
        .{ .x = 0.0676557225637151, .y = 0.546875 },
        .{ .x = -0.234375, .y = 0.546875 },
    } };
    // Original SkDCubic::ptAtT outputs at fixed parameters, independent of
    // the root solver and platform transcendental functions.
    try std.testing.expectEqual(@as(u64, 0x3cab2be3383cc703), @as(u64, @bitCast(rotated.ptAtT(@bitCast(@as(u64, 0x3fe513a3078db6f2))).x)));
    try std.testing.expectEqual(@as(u64, 0x3fd2f1f6a305c8f7), @as(u64, @bitCast(source.ptAtT(@bitCast(@as(u64, 0x3fd71d0ef0b3479a))).y)));
    const c: curves.Cubic = .{ .points = .{
        .{ .x = 0.07078845060087073, .y = 0 },
        .{ .x = 0.07078845060087073, .y = 0 },
        .{ .x = -0.15106303148814484, .y = 0 },
        .{ .x = -0.42473070360522436, .y = 0 },
    } };
    const expected = [_]u64{ 0x3fc5c3b76948a6f8, 0xbfe54c38d68d9451, 0xbc70000000000000, 0x3fb21f312043e783 };
    for (axis_roots.coefficients(c, .x), expected) |actual, bits| try std.testing.expectEqual(bits, @as(u64, @bitCast(actual)));
}

test "Bezier restriction preserves source endpoints and curved controls" {
    const c: curves.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } };
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
    for ([_]curves.Axis{ .x, .y }) |axis| {
        const count = curve.findExtrema(axis, &ts);
        for (ts[0..count]) |t| result.include(curve.ptAtT(t));
    }
    return result;
}

test "endpoint control hull bounds retain monotone and interior extrema at extreme scales" {
    const cubics = [_]curves.Cubic{
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
    try std.testing.expect(tiny.bounds().min.y < 0);
    try std.testing.expect(tiny.bounds().max.y > 0);
}

test "axis line proximity uses its constant-coordinate ULP budget" {
    const line: curves.Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1e5, .y = 0 } } };
    try std.testing.expectEqual(@as(f64, -1), line.nearPoint(.{ .x = 5e4, .y = 1e-12 }, null));
    var unequal = true;
    try std.testing.expectEqual(@as(f64, 0.5), line.nearPoint(.{ .x = 5e4, .y = 0 }, &unequal));
    try std.testing.expect(!unequal);
    try std.testing.expectEqual(@as(f64, 0), line.exactPoint(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(f64, 1), line.exactPoint(.{ .x = 1e5, .y = 0 }));
}

test "line evaluation matches reference rounding before coincidence classification" {
    // Captured from the existing 65-knot continuous taper. These lines have
    // distinct coverage; an extra intermediate rounding made D16 accept the
    // last pair and later produced an inconsistent coincident parameter run.
    const a: curves.Line = .{ .points = .{
        .{ .x = 0.45588299192121773, .y = -0.42502936011202347 },
        .{ .x = 0.48970774818035510, .y = -0.45885411637116086 },
    } };
    const b: curves.Line = .{ .points = .{
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
    }
}
