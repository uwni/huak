//! Tests of shared Hobby knots through edits, transforms, reversal and cuts.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const contours = @import("contours.zig");
const trim = @import("trim.zig");

// These fixtures start with a move and contain only cubics, so drawable
// time i-1/2 identifies the cubic at command i.
fn expectSolved(path: Path, index: usize, start: Point, end: Point) !void {
    const pos = try path.curveAt(@as(f64, @floatFromInt(index)) - 0.5);
    try std.testing.expectEqual([2]Point{ start, end }, path.solvedAt(index, pos.curve));
}

test "shared Hobby knot validates edits on each side before a rounding transform" {
    const a = std.testing.allocator;
    var path = try @import("construct.zig").construct(a, &.{ .zero, .{ .x = 5, .y = 8 }, .{ .x = 11, .y = 0 } }, &.{ .smooth, .smooth }, .{});
    defer path.deinit();
    try std.testing.expectEqual(1, path.knotRecords().len);
    const dir = path.knotRecords()[0].tangent;
    const left = &path.segments.items[1].cubic;
    const right = &path.segments.items[2].cubic;
    left.c1.x += 1;
    right.c2.y += 1;
    try expectSolved(path, 1, .zero, dir);
    try expectSolved(path, 2, dir, .zero);
    const original = left.c2;
    left.c2.y = std.math.nextAfter(f64, original.y, std.math.inf(f64));
    try expectSolved(path, 1, .zero, .zero);
    try expectSolved(path, 2, dir, .zero);
    const shift = g.Transform.translation(0, 0x1p40);
    try std.testing.expectEqual(shift.apply(left.c2), shift.apply(original));
    var placed = try path.transformed(a, shift);
    defer placed.deinit();
    try expectSolved(placed, 1, .zero, .zero);
    try expectSolved(placed, 2, dir, .zero);
    var in_place = try path.clone(a);
    defer in_place.deinit();
    try in_place.transform(shift);
    var appended = Path.init(a);
    defer appended.deinit();
    try contours.appendTransformed(&appended, path, shift);
    for ([_]Path{ in_place, appended }) |p| try std.testing.expectEqualDeep(placed.knotRecords(), p.knotRecords());
    left.c2 = original;
    const departing = right.c1;
    right.c1.x += 1;
    try expectSolved(path, 1, .zero, dir);
    try expectSolved(path, 2, .zero, .zero);
    left.end.x += 1;
    try expectSolved(path, 1, .zero, .zero);
    right.c1 = departing;
    try expectSolved(path, 2, .zero, .zero);
}

test "coincident endpoint controls validate the first noncoincident handle and its order" {
    const a = std.testing.allocator;
    const x: Point = .{ .x = 1, .y = 0 };
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    // The departure uses the chord (order three), the arrival its nearest handle.
    try path.solvedCubicTo(.{ .p0 = .zero, .p1 = .zero, .p2 = .zero, .p3 = x }, x, x);
    try expectSolved(path, 1, x, x);
    const c = &path.segments.items[1].cubic;
    c.end.y = 1;
    try expectSolved(path, 1, .zero, .zero);
    c.end = x;
    c.c2 = x; // Same departure witness point, different derivative order.
    try expectSolved(path, 1, .zero, .zero);

    var second = Path.init(a);
    defer second.deinit();
    try second.moveTo(.zero);
    try second.solvedCubicTo(.{ .p0 = .zero, .p1 = .zero, .p2 = x, .p3 = x.scale(2) }, x, .zero);
    second.segments.items[1].cubic.end.y = 1;
    try expectSolved(second, 1, x, .zero);
    second.segments.items[1].cubic.c2.y = 1;
    try expectSolved(second, 1, .zero, .zero);
}

test "shared Hobby knots survive reversal and cuts only at retained endpoints" {
    const a = std.testing.allocator;
    const points = [_]Point{ .zero, .{ .x = 10, .y = 2 }, .{ .x = 20, .y = 3 }, .{ .x = 30, .y = 1 } };
    var path = try @import("construct.zig").construct(a, &points, &.{ .smooth, .smooth, .smooth }, .{});
    defer path.deinit();
    const left = path.knotRecords()[0].tangent;
    const right = path.knotRecords()[1].tangent;
    try std.testing.expect(!left.eql(right));
    var rev = try path.reverse(a);
    defer rev.deinit();
    var back_cut = try trim.trimmed(path, a, 2.75, 0.25);
    defer back_cut.deinit();
    for ([_]Path{ rev, back_cut }) |p| {
        try std.testing.expectEqual(2, p.knotRecords().len);
        try expectSolved(p, 1, .zero, right.scale(-1));
        try expectSolved(p, 2, right.scale(-1), left.scale(-1));
        try expectSolved(p, 3, left.scale(-1), .zero);
    }
    var cut = try trim.clippedToRect(path, a, .fromPoints(.{ .x = 5, .y = -100 }, .{ .x = 25, .y = 100 }));
    defer cut.deinit();
    try std.testing.expectEqual(2, cut.knotRecords().len);
    try expectSolved(cut, 1, .zero, left);
    try expectSolved(cut, 2, left, right);
    try expectSolved(cut, 3, right, .zero);
    var half = try trim.trimmed(path, a, 1, 1.75);
    defer half.deinit();
    try std.testing.expectEqual(1, half.knotRecords().len);
    try expectSolved(half, 1, left, .zero);
}

test "closed Hobby seam is stored once and independent directions at a corner survive" {
    const a = std.testing.allocator;
    var loop = try @import("construct.zig").construct(a, &.{ .zero, .{ .x = 8, .y = 0 }, .{ .x = 2, .y = 7 } }, &.{ .smooth, .smooth, .smooth }, .{ .closed = true });
    defer loop.deinit();
    const records = loop.knotRecords();
    try std.testing.expectEqual(3, records.len);
    try std.testing.expect(records[0].seam);
    try expectSolved(loop, 1, records[0].tangent, records[1].tangent);
    try expectSolved(loop, 3, records[2].tangent, records[0].tangent);
    loop.segments.items[1].cubic.c1.y += 1;
    try expectSolved(loop, 1, .zero, records[1].tangent);
    try expectSolved(loop, 3, records[2].tangent, records[0].tangent);
    var shifted = try loop.transformed(a, .translation(4, 2));
    defer shifted.deinit();
    try expectSolved(shifted, 1, .zero, records[1].tangent);
    try expectSolved(shifted, 3, records[2].tangent, records[0].tangent);
    var rev = try loop.reverse(a);
    defer rev.deinit();
    try expectSolved(rev, 1, records[0].tangent.scale(-1), records[2].tangent.scale(-1));
    try expectSolved(rev, 3, records[1].tangent.scale(-1), .zero);

    const x: Point = .{ .x = 1, .y = 0 };
    const y: Point = .{ .x = 0, .y = 1 };
    var corner = Path.init(a);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.solvedCubicTo(.line(.zero, x), .zero, x);
    try corner.solvedCubicTo(.line(x, x.add(y)), y, .zero);
    try std.testing.expectEqual(2, corner.knotRecords().len);
    try expectSolved(corner, 1, .zero, x);
    try expectSolved(corner, 2, y, .zero);
}
