//! The test nib and the crossing, winding and point checks shared by the envelope tests.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const Point = g.Point;

pub const test_nib = [_]Point{
    .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 },
    .{ .x = 2, .y = 1 },   .{ .x = -2, .y = 1 },
};

fn testCrossing(first: Point, last: Point, point: Point) i32 {
    const cross = last.sub(first).cross(point.sub(first));
    if (first.y <= point.y and last.y > point.y and cross > 0) return 1;
    if (first.y > point.y and last.y <= point.y and cross < 0) return -1;
    return 0;
}

pub fn testWinding(path: Path, point: Point) i32 {
    var winding: i32 = 0;
    var current: Point = .zero;
    var start: Point = .zero;
    for (path.segments.items) |segment| switch (segment) {
        .move => |position| {
            current = position;
            start = position;
        },
        .line => |position| {
            winding += testCrossing(current, position, point);
            current = position;
        },
        .cubic => |controls| {
            const curve: g.Cubic = .{ .p0 = current, .p1 = controls.c1, .p2 = controls.c2, .p3 = controls.end };
            for (1..257) |index| {
                const next = curve.at(@as(f64, @floatFromInt(index)) / 256);
                winding += testCrossing(current, next, point);
                current = next;
            }
        },
        .close => {
            winding += testCrossing(current, start, point);
            current = start;
        },
    };
    return winding;
}

pub fn expectTestPoint(expected: Point, actual: Point) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-12);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-12);
}
