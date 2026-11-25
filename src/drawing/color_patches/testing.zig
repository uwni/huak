//! Fixtures shared by the color patch tests.
const g = @import("../geometry.zig");

pub fn plane(width: f64, height: f64) [16]g.Point {
    var net: [16]g.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        net[i * 4 + j] = .{ .x = width * @as(f64, @floatFromInt(i)) / 3, .y = height * @as(f64, @floatFromInt(j)) / 3 };
    };
    return net;
}
