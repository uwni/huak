//! Tests of caps, joins and miter limits on polygon-pen outlines, with MetaPost reference bounds.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const nibs = @import("../nib.zig");
const stroke = @import("../stroke.zig");
const outline = @import("../outline.zig");

test "polygon butt square and round caps retain independent nib dimensions" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var rectangle = try nibs.Nib.square().transformed(std.testing.allocator, g.Transform.scaling(4, 2));
    defer rectangle.deinit();
    var butt = try outline.strokeOutline(std.testing.allocator, rectangle.nib, line, .{ .cap = .butt, .join = .bevel });
    defer butt.deinit();
    var square = try outline.strokeOutline(std.testing.allocator, rectangle.nib, line, .{ .cap = .square, .join = .bevel });
    defer square.deinit();
    var round = try outline.strokeOutline(std.testing.allocator, rectangle.nib, line, .{ .cap = .round, .join = .bevel });
    defer round.deinit();
    // MetaPost 3.00, double arithmetic, verified by tests/fixtures/pens-reference.mp.
    try std.testing.expectApproxEqAbs(@as(f64, -2), butt.bounds().?.min.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -6), square.bounds().?.min.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -2), round.bounds().?.min.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 20), butt.signedArea(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 36), square.signedArea(), 0.001);
}

test "convex nib joins honor bevel miter and miter limit" {
    var corner = Path.init(std.testing.allocator);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 10, .y = 0 });
    try corner.lineTo(.{ .x = 10, .y = 10 });
    const diamond_vertices = [_]g.Point{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = -1, .y = 0 } };
    const diamond: nibs.Nib = .{ .polygon = &diamond_vertices };
    var bevel = try outline.strokeOutline(std.testing.allocator, diamond, corner, .{ .cap = .butt, .join = .bevel });
    defer bevel.deinit();
    var miter = try outline.strokeOutline(std.testing.allocator, diamond, corner, .{ .cap = .butt, .join = .miter, .miter_limit = 4 });
    defer miter.deinit();
    var limited = try outline.strokeOutline(std.testing.allocator, diamond, corner, .{ .cap = .butt, .join = .miter, .miter_limit = 1 });
    defer limited.deinit();
    try std.testing.expect(miter.signedArea() > bevel.signedArea());
    try std.testing.expectApproxEqAbs(bevel.signedArea(), limited.signedArea(), 0.001);
}

test "cubic subdivisions are smooth joins and preserve butt endpoint caps" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 3, .y = 0 }, .{ .x = 7, .y = 2 }, .{ .x = 10, .y = 2 });
    var stroke_path = try outline.strokeOutline(std.testing.allocator, nibs.Nib.circle(), curve, .{ .cap = .butt, .join = .bevel, .tolerance = 0.001 });
    defer stroke_path.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0), stroke_path.bounds().?.min.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), stroke_path.bounds().?.max.x, 0.001);
}

test "zero-length endpoint segments do not discard square caps or corner joins" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    try line.lineTo(.{ .x = 10, .y = 0 });
    var result = try outline.strokeOutline(std.testing.allocator, nibs.Nib.square(), line, .{ .cap = .square, .join = .bevel });
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), result.bounds().?.min.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 11.5), result.bounds().?.max.x, 0.001);
}

test "polygon stroke bounds match MetaPost rotated sheared negative and closed references" {
    const Shape = enum { horizontal, negative, triangle, reflex };
    const Case = struct { transform: g.Transform = .{}, shape: Shape = .horizontal, cap: stroke.Cap = .butt, join: stroke.Join = .bevel, limit: f64 = 4, min: g.Point, max: g.Point, area: ?f64 = null };
    const rotation = g.Transform.rotation(std.math.pi / 6.0);
    const shear: g.Transform = .{ .c = 0.5 };
    const cases = [_]Case{
        .{ .transform = rotation, .min = .{ .x = -1.2320508075688774, .y = -1.8660254037844386 }, .max = .{ .x = 11.232050807568877, .y = 1.8660254037844386 }, .area = 37.320508075688771 },
        .{ .transform = rotation, .cap = .square, .min = .{ .x = -3.3756443470178592, .y = -1.8660254037844386 }, .max = .{ .x = 13.375644347017857, .y = 1.8660254037844386 }, .area = 53.320508075688764 },
        .{ .transform = rotation, .cap = .round, .min = .{ .x = -2.2320508075688772, .y = -1.8660254037844386 }, .max = .{ .x = 12.232050807568877, .y = 1.8660254037844386 }, .area = 45.320508075688771 },
        .{ .transform = shear, .min = .{ .x = -1.5, .y = -1 }, .max = .{ .x = 11.5, .y = 1 }, .area = 20 },
        .{ .transform = shear, .cap = .square, .min = .{ .x = -5.5, .y = -1 }, .max = .{ .x = 15.5, .y = 1 }, .area = 36 },
        .{ .transform = shear, .cap = .round, .min = .{ .x = -2.5, .y = -1 }, .max = .{ .x = 12.5, .y = 1 }, .area = 28 },
        .{ .shape = .negative, .min = .{ .x = -12, .y = -6 }, .max = .{ .x = 2, .y = 1 }, .area = 40 },
        .{ .shape = .negative, .cap = .square, .min = .{ .x = -14, .y = -7 }, .max = .{ .x = 4, .y = 2 }, .area = 56 },
        .{ .shape = .negative, .cap = .round, .min = .{ .x = -12, .y = -6 }, .max = .{ .x = 2, .y = 1 }, .area = 48 },
        .{ .shape = .triangle, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 12, .y = 11 } },
        .{ .shape = .triangle, .join = .miter, .min = .{ .x = -4, .y = -1 }, .max = .{ .x = 12, .y = 15 } },
        .{ .shape = .triangle, .join = .round, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 12, .y = 11 } },
        .{ .shape = .triangle, .join = .miter, .limit = 1, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 12, .y = 11 } },
        .{ .shape = .reflex, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 12, .y = 11 } },
        .{ .shape = .reflex, .join = .miter, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 15.333333333333332, .y = 11 } },
        .{ .shape = .reflex, .join = .round, .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 12, .y = 11 } },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("polygon reference case {d}\n", .{index});
        var center = Path.init(std.testing.allocator);
        defer center.deinit();
        try center.moveTo(.zero);
        switch (case.shape) {
            .horizontal => try center.lineTo(.{ .x = 10, .y = 0 }),
            .negative => try center.lineTo(.{ .x = -10, .y = -5 }),
            .triangle => {
                try center.lineTo(.{ .x = 10, .y = 0 });
                try center.lineTo(.{ .x = 10, .y = 10 });
                try center.close();
            },
            .reflex => {
                for ([_]g.Point{ .{ .x = 10, .y = 0 }, .{ .x = 5, .y = 3 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } }) |point| try center.lineTo(point);
                try center.close();
            },
        }
        var nib = try nibs.Nib.square().transformed(std.testing.allocator, g.Transform.scaling(4, 2).then(case.transform));
        defer nib.deinit();
        var result = try outline.strokeOutline(std.testing.allocator, nib.nib, center, .{ .cap = case.cap, .join = case.join, .miter_limit = case.limit });
        defer result.deinit();
        const box = result.bounds().?;
        try std.testing.expectApproxEqAbs(case.min.x, box.min.x, 0.001);
        try std.testing.expectApproxEqAbs(case.min.y, box.min.y, 0.001);
        try std.testing.expectApproxEqAbs(case.max.x, box.max.x, 0.001);
        try std.testing.expectApproxEqAbs(case.max.y, box.max.y, 0.001);
        if (case.area) |area| try std.testing.expectApproxEqAbs(area, result.signedArea(), 0.005);
    }
}
