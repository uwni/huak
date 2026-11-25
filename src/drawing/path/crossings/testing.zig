//! The cubic with a known self-crossing at u=1/4, v=3/4, shared by the crossing tests.
const g = @import("../../geometry.zig");

pub const loop: g.Cubic = .{
    .p0 = .zero,
    .p1 = .{ .x = -13, .y = -16 },
    .p2 = .{ .x = -26, .y = -16 },
    .p3 = .{ .x = 9, .y = 0 },
};
