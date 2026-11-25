// Copyright 2012 Google Inc.
// Copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Tests of line and ray intersections.
const std = @import("std");
const Point = @import("../point.zig").Point;
const Line = @import("../curve.zig").Line;
const Quad = @import("../curve.zig").Quad;
const Cubic = @import("../curve.zig").Cubic;
const Intersections = @import("../Intersections.zig");

test "DD line intersection preserves original captured near parallel parameters" {
    const cases = [_][2]Line{
        .{ .{ .points = .{ .{ .x = 0.77988957318917262, .y = -0.28513156665940087 }, .{ .x = 0.74990364813785093, .y = -0.28996213816751437 } } }, .{ .points = .{ .{ .x = 0.7499036481378516, .y = -0.28996213816751831 }, .{ .x = 0.77988957318917196, .y = -0.28513156665939693 } } } },
        .{ .{ .points = .{ .{ .x = 0.7499036481378516, .y = -0.28996213816751831 }, .{ .x = 0.77988957318917196, .y = -0.28513156665939693 } } }, .{ .points = .{ .{ .x = 0.76489661066351178, .y = -0.28754685241345762 }, .{ .x = 0.77988957318917262, .y = -0.28513156665940087 } } } },
        .{ .{ .points = .{ .{ .x = -0.77633758876323178, .y = -0.25158900773400045 }, .{ .x = -0.74198642876148746, .y = -0.25814602339387488 } } }, .{ .points = .{ .{ .x = -0.75916200876235962, .y = -0.25486751556393766 }, .{ .x = -0.77633758876323167, .y = -0.25158900773400045 } } } },
    };
    for (cases, 0..) |source, case_index| {
        var baseline: Intersections = .{ .allow_near = false };
        try std.testing.expectEqual(@as(usize, 1), baseline.lineLine(source[0], source[1]));
        if (case_index == 0) {
            try std.testing.expectEqual(@as(f64, 0.5), baseline.parameters[0][0]);
            try std.testing.expectEqual(@as(f64, 0.5), baseline.parameters[1][0]);
        }
        for ([_]i32{ -80, 0, 80 }) |exponent| for (0..4) |reverse| {
            var lines: [2]Line = undefined;
            var largest: f64 = 0;
            for (&lines, 0..) |*line, which| for (&line.points, 0..) |*point, index| {
                point.* = source[which].points[index ^ ((reverse >> @intCast(which)) & 1)];
                point.x = std.math.ldexp(point.x, exponent);
                point.y = std.math.ldexp(point.y, exponent);
                largest = @max(largest, @max(@abs(point.x), @abs(point.y)));
            };
            var result: Intersections = .{ .allow_near = false };
            try std.testing.expectEqual(@as(usize, 1), result.lineLine(lines[0], lines[1]));
            const first = lines[0].ptAtT(result.parameters[0][0]);
            const second = lines[1].ptAtT(result.parameters[1][0]);
            try std.testing.expect(first.sub(second).length() <= 32 * std.math.floatEps(f64) * largest);
            for (0..2) |which| {
                const expected = if (reverse & (@as(usize, 1) << @intCast(which)) != 0) 1 - baseline.parameters[which][0] else baseline.parameters[which][0];
                try std.testing.expectApproxEqAbs(expected, result.parameters[which][0], 32 * std.math.floatEps(f64));
            }
        };
    }
}

test "axis intersections preserve overlap and reversed second parameters" {
    const diagonal: Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.lineLine(diagonal, .{ .points = .{ .{ .x = 8, .y = 2 }, .{ .x = 0, .y = 2 } } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[0][0]);
    try std.testing.expectEqual(@as(f64, 0.75), result.parameters[1][0]);
    result.reset();
    const collinear: Line = .{ .points = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 2 } } };
    try std.testing.expectEqual(@as(usize, 2), result.lineLine(collinear, .{ .points = .{ .{ .x = 0, .y = 2 }, .{ .x = 4, .y = 2 } } }));
    try std.testing.expectEqual(@as(u16, 3), result.coincident);
}

test "quad and cubic line roots preserve tangent events and axis parameters" {
    const cubic: Cubic = .{ .points = .{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    const quad: Quad = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = 1 } } };
    const line: Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.cubicLine(cubic, line));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[1][0], 1e-14);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.cubicLine(cubic, .{ .points = .{ .{ .x = 1.5, .y = -2 }, .{ .x = 1.5, .y = 2 } } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[1][0]);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.quadLine(quad, line));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), result.parameters[1][0], 1e-14);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.quadLine(quad, .{ .points = .{ .{ .x = 2, .y = 0 }, Point.zero } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[1][0]);
}

test "line curve coincidence keeps clipped interval endpoints" {
    const curve: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } } };
    const line: Line = .{ .points = .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 2), result.cubicLine(curve, line));
    try std.testing.expectEqual(@as(u16, 3), result.coincident);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), result.parameters[0][1], 1e-14);
}

test "ray intersections retain curve roots beyond the finite ray segment" {
    const curve: Cubic = .{ .points = .{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    const ray: Line = .{ .points = .{ .{ .x = 8, .y = 0 }, .{ .x = 9, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.intersectRay(.{ .cubic = curve }, ray));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectEqual(@as(f64, 1.5), result.points[0].x);
}
