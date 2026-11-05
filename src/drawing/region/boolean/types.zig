const std = @import("std");
const geometry = @import("../../geometry.zig");
pub const Point = geometry.Point;

pub const Source = struct {
    cubic: geometry.Cubic,
    next: usize,
    contour: usize,
    operand: u1,
};
pub const Location = struct { curve: usize, time: f64 };
pub const Allocator = std.mem.Allocator;
