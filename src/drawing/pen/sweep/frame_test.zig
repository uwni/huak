//! Tests of path-framed motion: original derivatives, seams and lifts, arc-length keys, monotone cubics and Hobby knots.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const outline = @import("../outline.zig");
const Nib = @import("../nib.zig").Nib;
const Motion = @import("../Motion.zig");
const Point = g.Point;
const Direction = @import("../../path/Direction.zig");
const sweep = @import("../sweep.zig");

test "local frame uses the original derivative and honors noncommuting motion order" {
    const curve: g.Cubic = .{ .p0 = .zero, .p1 = .{ .x = 3, .y = 4 }, .p2 = .{ .x = 8, .y = -2 }, .p3 = .{ .x = 9, .y = 2 } };
    const field = try Direction.init(curve, true);
    const motion: Motion = .{
        .tracks = &.{ .{ .kind = .scale_x, .first = 0, .len = 2 }, .{ .kind = .rotate, .first = 2, .len = 2 }, .{ .kind = .path_frame, .first = 4, .len = 0 } },
        .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 1, .value = 3 }, .{ .t = 0, .value = std.math.pi / 2.0 }, .{ .t = 1, .value = std.math.pi / 2.0 } },
    };
    try motion.validate();
    try std.testing.expectError(error.UndefinedPathFrame, motion.atContext(.{ .progress = 0.25 }));
    for ([_]f64{ 0, 0.013, 0.3729, 0.7, 1 }) |u| {
        const m = try motion.atContext(.{ .progress = 0.25, .tangent = try field.at(u) });
        const axis = m.apply(.{ .x = 1, .y = 0 });
        const tangent = try curve.derivative(u).normalized();
        try std.testing.expectApproxEqAbs(@as(f64, 0), axis.dot(tangent), 1e-14);
        try std.testing.expectApproxEqAbs(@as(f64, 1.5), tangent.cross(axis), 1e-14);
    }
}

test "tiny curved centerline sweeps large rotating nib between endpoint directions" {
    // Spatial and arc deficit fit the initial flattening budget. The frame
    // still rotates by 90 degrees, so accepting a single linear slab fails.
    const a = std.testing.allocator;
    const windingAt = @import("../../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0.0001, .y = 0 }, .{ .x = 0.0002, .y = 0.0001 }, .{ .x = 0.0002, .y = 0.0002 });
    const motion: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var chisel = try Nib.square().transformed(a, .scaling(8, 0.4));
    defer chisel.deinit();
    var out = try sweep.expand(a, path, chisel.nib, &motion, .{ .tolerance = 0.02 });
    defer out.deinit();
    try std.testing.expect(try windingAt(out, .{ .x = 2.7, .y = 2.7 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 3, .y = 3 }));
    try std.testing.expectError(error.GeometryWorkLimit, sweep.expand(a, path, chisel.nib, &motion, .{ .tolerance = 0.02, .max_depth = 1 }));
}

test "path frames respect seams, lifts, stationary limits and undefined directions" {
    const a = std.testing.allocator;
    const motion: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var path = try Path.circle(a, .zero, 5);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 12, .y = 0 }, .{ .x = 13, .y = 0 });
    // The derivative of this next segment vanishes at 1/2 with the same
    // positive horizontal limiting tangent on each side.
    try path.cubicTo(.{ .x = 14, .y = 0 }, .{ .x = 13, .y = 0 }, .{ .x = 14, .y = 0 });
    var out = try sweep.expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
    defer out.deinit();
    try path.lineTo(.{ .x = 14, .y = 5 });
    try std.testing.expectError(error.UndefinedPathFrame, sweep.expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 }));

    var stop = Path.init(a);
    defer stop.deinit();
    try stop.moveTo(.zero);
    try stop.lineTo(.zero);
    try std.testing.expectError(error.UndefinedPathFrame, sweep.expand(a, stop, Nib.square(), &motion, .{}));
    try stop.cubicTo(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 }, .zero);
    try std.testing.expectError(error.UndefinedPathFrame, sweep.expand(a, stop, Nib.square(), &motion, .{}));
}

test "framed motion key still addresses physical arc length on a nonuniform cubic" {
    const a = std.testing.allocator;
    const windingAt = @import("../../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.zero, .zero, .{ .x = 16, .y = 0 });
    const motion: Motion = .{
        .tracks = &.{ .{ .kind = .path_frame, .first = 0, .len = 0 }, .{ .kind = .scale_y, .first = 0, .len = 3 } },
        .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 8 }, .{ .t = 1, .value = 1 } },
    };
    var out = try sweep.expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
    defer out.deinit();
    // x = 16u^3, so u=1/2 is at x=2, but the middle key belongs at x=8.
    try std.testing.expect(try windingAt(out, .{ .x = 8, .y = 3.9 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 2, .y = 3 }));
}

test "a constant framed nib sweeps a monotone straight cubic under the line budget" {
    const a = std.testing.allocator;
    const law: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var line = Path.init(a);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 16, .y = 0 });
    var curve = Path.init(a);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.zero, .zero, .{ .x = 16, .y = 0 });
    const opts: outline.Options = .{ .tolerance = 0.001, .max_segments = 64 };
    var reference = try sweep.expand(a, line, Nib.square(), &law, opts);
    defer reference.deinit();
    var actual = try sweep.expand(a, curve, Nib.square(), &law, opts);
    defer actual.deinit();
    try std.testing.expectEqualDeep(reference.segments.items, actual.segments.items);
    // A nonzero transverse component must never earn the chord certificate.
    try std.testing.expect(!Direction.monotoneLine(.{ .p0 = .zero, .p1 = .zero, .p2 = .{ .x = 0, .y = 1e-100 }, .p3 = .{ .x = 16, .y = 0 } }));
    try std.testing.expect(!Direction.monotoneLine(.{ .p0 = .zero, .p1 = .{ .x = 3, .y = 0 }, .p2 = .{ .x = -3, .y = 0 }, .p3 = .{ .x = 1, .y = 0 } }));
}

test "strict frame honors solved Hobby knots and still rejects a hand-made or edited corner" {
    const a = std.testing.allocator;
    const construct = @import("../../path/construct.zig");
    const points = [_]Point{ .zero, .{ .x = 60, .y = 80 }, .{ .x = 130, .y = 20 }, .{ .x = 210, .y = 90 } };
    const strict: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    for ([_]bool{ false, true }) |closed| {
        const joins = [_]construct.Join{ .smooth, .smooth, .smooth, .smooth };
        var path = try construct.construct(a, &points, joins[0..if (closed) @as(usize, 4) else 3], .{ .closed = closed });
        defer path.deinit();
        var ink = try sweep.expand(a, path, Nib.square(), &strict, .{ .tolerance = 0.02 });
        defer ink.deinit();
        try std.testing.expect(ink.segments.items.len > 0);
        var reverse = try path.reverse(a);
        defer reverse.deinit();
        try reverse.transform(g.Transform.rotation(0.31).then(.translation(12, 7)));
        var cut = try Path.trim.trimmed(reverse, a, 0.25, 2.5);
        defer cut.deinit();
        var cut_ink = try sweep.expand(a, cut, Nib.square(), &strict, .{ .tolerance = 0.02 });
        defer cut_ink.deinit();
        path.segments.items[2].cubic.c1.y += 0.1;
        try std.testing.expectError(error.UndefinedPathFrame, sweep.expand(a, path, Nib.square(), &strict, .{ .tolerance = 0.02 }));
    }
    var hand = Path.init(a);
    defer hand.deinit();
    try hand.moveTo(.zero);
    try hand.cubicTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 });
    try hand.cubicTo(.{ .x = 4, .y = 1e-16 }, .{ .x = 5, .y = 0 }, .{ .x = 6, .y = 0 });
    try std.testing.expectError(error.UndefinedPathFrame, sweep.expand(a, hand, Nib.square(), &strict, .{ .tolerance = 0.02 }));
}
