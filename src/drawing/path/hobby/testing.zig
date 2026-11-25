//! Reference assertions and example knots shared by the Hobby tests.
const std = @import("std");
const geometry = @import("../../geometry.zig");
const Point = geometry.Point;
const hobby = @import("../hobby.zig");

pub fn expectReference(knots: []const hobby.Knot, options: hobby.Options, expected: []const [8]f64) !void {
    try expectReferenceTolerance(knots, options, expected, 1e-8);
}

pub fn expectReferenceTolerance(knots: []const hobby.Knot, options: hobby.Options, expected: []const [8]f64, tolerance: f64) !void {
    const segments = try hobby.interpolate(std.testing.allocator, knots, options);
    defer std.testing.allocator.free(segments);
    try std.testing.expectEqual(expected.len, segments.len);
    for (segments, expected, 0..) |segment, reference, i| {
        const values: [8]f64 = .{ segment.p0.x, segment.p0.y, segment.p1.x, segment.p1.y, segment.p2.x, segment.p2.y, segment.p3.x, segment.p3.y };
        for (values, reference, 0..) |actual, wanted, component| {
            std.testing.expectApproxEqAbs(wanted, actual, tolerance) catch |err| {
                std.debug.print("segment={d} component={d}\n", .{ i, component });
                return err;
            };
        }
    }
}

pub const up: Point = .{ .x = 0, .y = 1 };

pub const right: Point = .{ .x = 1, .y = 0 };

pub const left: Point = .{ .x = -1, .y = 0 };

pub const example_open = [_]hobby.Knot{
    .{ .point = .{ .x = 0, .y = 0 } },    .{ .point = .{ .x = 60, .y = 80 } },
    .{ .point = .{ .x = 130, .y = 20 } }, .{ .point = .{ .x = 210, .y = 90 } },
};

pub const example_closed = [_]hobby.Knot{
    .{ .point = .{ .x = 0, .y = 0 } },     .{ .point = .{ .x = 90, .y = 10 } },
    .{ .point = .{ .x = 110, .y = 100 } }, .{ .point = .{ .x = 10, .y = 80 } },
};
