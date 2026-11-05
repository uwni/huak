//! Three rows of an affine matrix, with translation in the last column.
const std = @import("std");
const geometry = @import("../geometry.zig");
const Affine3 = @This();

rows: [3][4]f64 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } },

pub fn fromPlane(t: geometry.Transform) Affine3 {
    return .{ .rows = .{ .{ t.a, t.c, 0, t.e }, .{ t.b, t.d, 0, t.f }, .{ 0, 0, 1, 0 } } };
}

pub fn rotation(angle: f64, axis: [3]f64) !Affine3 {
    const length = std.math.hypot(std.math.hypot(axis[0], axis[1]), axis[2]);
    if (length == 0 or !std.math.isFinite(length)) return error.InvalidAxis;
    const x, const y, const z = @as(@Vector(3, f64), axis) / @as(@Vector(3, f64), @splat(length));
    const c = @cos(angle);
    const s = @sin(angle);
    const k = 1 - c;
    return .{ .rows = .{
        .{ c + x * x * k, x * y * k - z * s, x * z * k + y * s, 0 },
        .{ y * x * k + z * s, c + y * y * k, y * z * k - x * s, 0 },
        .{ z * x * k - y * s, z * y * k + x * s, c + z * z * k, 0 },
    } };
}

pub fn apply(self: Affine3, p: [3]f64) [3]f64 {
    var result: [3]f64 = undefined;
    for (&result, self.rows) |*v, row| v.* = row[0] * p[0] + row[1] * p[1] + row[2] * p[2] + row[3];
    return result;
}

pub fn then(self: Affine3, next: Affine3) Affine3 {
    var result: Affine3 = undefined;
    for (&result.rows, next.rows) |*out, row| {
        for (0..4) |j| out[j] = row[0] * self.rows[0][j] + row[1] * self.rows[1][j] + row[2] * self.rows[2][j];
        out[3] += row[3];
    }
    return result;
}
