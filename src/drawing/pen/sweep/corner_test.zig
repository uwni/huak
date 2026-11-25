//! Tests of frame corners: the rotate and overlap policies, the signed turn, and contour progress across corners.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const Nib = @import("../nib.zig").Nib;
const Motion = @import("../Motion.zig");
const sweep = @import("../sweep.zig");

test "rotate and overlap treat open frame corners and closed seams on the same contour" {
    const a = std.testing.allocator;
    const windingAt = @import("../../region/pathops/winding.zig").windingAt;
    const law: Motion = .{
        .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }},
        .keys = &.{},
    };
    var chisel = try Nib.square().transformed(a, .scaling(0.5, 8));
    defer chisel.deinit();
    var open = Path.init(a);
    defer open.deinit();
    try open.moveTo(.{ .x = -12, .y = 0 });
    try open.lineTo(.zero);
    try open.lineTo(.{ .x = 0, .y = 12 });
    var closed = Path.init(a);
    defer closed.deinit();
    try closed.moveTo(.zero);
    try closed.lineTo(.{ .x = 12, .y = 0 });
    try closed.lineTo(.{ .x = 12, .y = 12 });
    try closed.lineTo(.{ .x = 0, .y = 12 });
    try closed.close();
    for ([_]Motion.Corner{ .rotate, .overlap }) |mode| {
        var motion = law;
        motion.corner = mode;
        var corner = try sweep.expand(a, open, chisel.nib, &motion, .{ .tolerance = 0.02 });
        defer corner.deinit();
        var seam = try sweep.expand(a, closed, chisel.nib, &motion, .{ .tolerance = 0.02 });
        defer seam.deinit();
        try std.testing.expectEqual(mode == .rotate, (try windingAt(corner, .{ .x = 2.6, .y = -2.6 })) != 0);
        try std.testing.expectEqual(mode == .rotate, (try windingAt(seam, .{ .x = -2.6, .y = -2.6 })) != 0);
        try std.testing.expectEqual(@as(i32, 0), try windingAt(corner, .{ .x = 3.1, .y = -3.1 }));
        // The shared coverage is painted once; the source remains one contour.
        try std.testing.expectEqual(@as(u32, 1), @abs(try windingAt(corner, .{ .x = -0.1, .y = 0.1 })));
    }
}

test "frame corner rotation takes the short signed turn and positive half-turn on reversal" {
    const a = std.testing.allocator;
    const windingAt = @import("../../region/pathops/winding.zig").windingAt;
    const turn: Motion = .{ .corner = .rotate, .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var eccentric = try Nib.square().transformed(a, g.Transform.scaling(0.5, 0.5).then(.translation(4, 0)));
    defer eccentric.deinit();
    var track = Path.init(a);
    defer track.deinit();
    try track.moveTo(.{ .x = -8, .y = 0 });
    try track.lineTo(.zero);
    try track.lineTo(.{ .x = 0, .y = -8 });
    var clockwise = try sweep.expand(a, track, eccentric.nib, &turn, .{ .tolerance = 0.02 });
    defer clockwise.deinit();
    try std.testing.expect((try windingAt(clockwise, .{ .x = 2.82, .y = -2.82 })) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(clockwise, .{ .x = 0, .y = 4 }));
    var reversed = Path.init(a);
    defer reversed.deinit();
    try reversed.moveTo(.{ .x = -8, .y = 0 });
    try reversed.lineTo(.zero);
    try reversed.lineTo(.{ .x = -8, .y = 0 });
    var half = try sweep.expand(a, reversed, eccentric.nib, &turn, .{ .tolerance = 0.02 });
    defer half.deinit();
    try std.testing.expect((try windingAt(half, .{ .x = 0, .y = 4 })) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(half, .{ .x = 0, .y = -4 }));
}

test "frame corner transitions preserve contour progress and the closed motion contract" {
    const a = std.testing.allocator;
    const windingAt = @import("../../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.{ .x = -20, .y = 0 });
    try path.lineTo(.zero);
    try path.lineTo(.{ .x = 0, .y = 20 });
    var loop = try path.clone(a);
    defer loop.deinit();
    try loop.close();
    for ([_]Motion.Corner{ .rotate, .overlap }) |mode| {
        var motion: Motion = .{
            .corner = mode,
            .tracks = &.{ .{ .kind = .scale_y, .first = 0, .len = 3 }, .{ .kind = .path_frame, .first = 3, .len = 0 } },
            .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 8 }, .{ .t = 1, .value = 2 } },
        };
        var footprint = try sweep.expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
        defer footprint.deinit();
        try std.testing.expectEqual(@as(i32, 0), try windingAt(footprint, .{ .x = -10, .y = 3 }));
        try std.testing.expect((try windingAt(footprint, .{ .x = 3.5, .y = 1 })) != 0);
        try std.testing.expectEqual(mode == .rotate, (try windingAt(footprint, .{ .x = 2.6, .y = -2.6 })) != 0);
        try std.testing.expectError(error.DiscontinuousClosedMotion, sweep.expand(a, loop, Nib.square(), &motion, .{ .tolerance = 0.05 }));
    }
}
