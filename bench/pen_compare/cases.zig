//! Single source of numeric inputs for the native and MetaPost processes.
const std = @import("std");
pub const core = @import("drawing");
pub const Point = core.geometry.Point;
pub const Cubic = core.geometry.Cubic;
pub const Mode = enum { envelope, stroke };
const Shape = enum { wave, loop, reflex };
const Nib = enum { rectangle, polygon16, sheared };
pub const Case = struct { name: []const u8, mode: Mode, shape: Shape, nib: Nib };
pub const cases = [_]Case{
    .{ .name = "closed_cubic", .mode = .envelope, .shape = .loop, .nib = .rectangle },
    .{ .name = "closed_reflex_shear", .mode = .envelope, .shape = .reflex, .nib = .sheared },
    .{ .name = "open_cubic_rectangle", .mode = .stroke, .shape = .wave, .nib = .rectangle },
    .{ .name = "open_cubic_polygon16", .mode = .stroke, .shape = .wave, .nib = .polygon16 },
    .{ .name = "closed_cubic", .mode = .stroke, .shape = .loop, .nib = .rectangle },
    .{ .name = "closed_reflex_shear", .mode = .stroke, .shape = .reflex, .nib = .sheared },
};

pub fn closed(case: Case) bool {
    return case.shape != .wave;
}

pub fn path(allocator: std.mem.Allocator, case: Case) !core.Path {
    var result = core.Path.init(allocator);
    errdefer result.deinit();
    switch (case.shape) {
        .wave => {
            try result.moveTo(.zero);
            try result.cubicTo(.{ .x = 10, .y = 55 }, .{ .x = 70, .y = -30 }, .{ .x = 100, .y = 10 });
            try result.cubicTo(.{ .x = 125, .y = 65 }, .{ .x = 155, .y = -40 }, .{ .x = 200, .y = 0 });
        },
        .loop => {
            try result.moveTo(.{ .x = 40, .y = 0 });
            try result.cubicTo(.{ .x = 40, .y = 22 }, .{ .x = 22, .y = 40 }, .{ .x = 0, .y = 40 });
            try result.cubicTo(.{ .x = -22, .y = 40 }, .{ .x = -40, .y = 22 }, .{ .x = -40, .y = 0 });
            try result.cubicTo(.{ .x = -40, .y = -22 }, .{ .x = -22, .y = -40 }, .{ .x = 0, .y = -40 });
            try result.cubicTo(.{ .x = 22, .y = -40 }, .{ .x = 40, .y = -22 }, .{ .x = 40, .y = 0 });
        },
        .reflex => {
            try result.moveTo(.zero);
            for ([_]Point{ .{ .x = 60, .y = 0 }, .{ .x = 30, .y = 20 }, .{ .x = 60, .y = 50 }, .{ .x = 0, .y = 50 } }) |point| try result.lineTo(point);
        },
    }
    if (closed(case)) try result.close();
    return result;
}

pub fn vertices(case: Case, buffer: *[16]Point) []const Point {
    switch (case.nib) {
        .rectangle => {
            const transform = core.geometry.Transform.scaling(8, 3).then(core.geometry.Transform.rotation(0.4));
            const square = [_]Point{ .{ .x = -0.5, .y = -0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 } };
            for (square, buffer[0..4]) |point, *output| output.* = transform.apply(point);
            return buffer[0..4];
        },
        .sheared => {
            @memcpy(buffer[0..4], &[_]Point{ .{ .x = -5, .y = -2 }, .{ .x = 3, .y = -2 }, .{ .x = 5, .y = 2 }, .{ .x = -3, .y = 2 } });
            return buffer[0..4];
        },
        .polygon16 => {
            for (buffer, 0..) |*point, index| {
                const angle = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / buffer.len;
                point.* = .{ .x = 4 * @cos(angle), .y = 2 * @sin(angle) };
            }
            return buffer;
        },
    }
}
