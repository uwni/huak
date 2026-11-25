//! Tests of signed area, circle construction and segment-time queries.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Path = @import("Path.zig");
const paintedBounds = Path.paintedBounds;

test "signed area integrates cubic boundaries and implicit closure" {
    const allocator = std.testing.allocator;
    var arch = Path.init(allocator);
    defer arch.deinit();
    try arch.moveTo(.zero);
    try arch.cubicTo(.{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), arch.signedArea(), 1e-14);
    var reversed = try arch.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), reversed.signedArea(), 1e-14);
    try arch.close();
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), arch.signedArea(), 1e-14);
}

test "signed area removes a large contour origin before curve integration" {
    const allocator = std.testing.allocator;
    const origin: Point = .{ .x = 1e16, .y = -1e16 };
    var arch = Path.init(allocator);
    defer arch.deinit();
    try arch.moveTo(origin);
    try arch.cubicTo(origin.add(.{ .x = 0, .y = 16 }), origin.add(.{ .x = 16, .y = 16 }), origin.add(.{ .x = 16, .y = 0 }));
    try std.testing.expectApproxEqAbs(@as(f64, -153.6), arch.signedArea(), 1e-11);
    var reversed = try arch.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 153.6), reversed.signedArea(), 1e-11);
}

test "signed area combines separate contours with hole winding" {
    const allocator = std.testing.allocator;
    var path = Path.init(allocator);
    defer path.deinit();
    try std.testing.expectEqual(@as(f64, 0), path.signedArea());
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 10, .y = 10 });
    try path.lineTo(.{ .x = 0, .y = 10 });
    // The next move implicitly closes the outer contour.
    try path.moveTo(.{ .x = 3, .y = 3 });
    try path.lineTo(.{ .x = 3, .y = 7 });
    try path.lineTo(.{ .x = 7, .y = 7 });
    try path.lineTo(.{ .x = 7, .y = 3 });
    try path.close();
    try path.moveTo(.{ .x = 1e16, .y = 1e16 });
    try std.testing.expectEqual(@as(f64, 84), path.signedArea());
    var reversed = try path.reverse(allocator);
    defer reversed.deinit();
    try std.testing.expectEqual(@as(f64, -84), reversed.signedArea());
}

test "circle construction keeps four cubic quarters and finite exact axis bounds" {
    var p = try Path.circle(std.testing.allocator, .{ .x = 3, .y = 4 }, 2);
    defer p.deinit();
    const box = p.bounds().?;
    try std.testing.expectEqual(@as(usize, 4), p.segmentCount());
    try std.testing.expectEqual(@as(f64, 1), box.min.x);
    try std.testing.expectEqual(@as(f64, 6), box.max.y);
    try std.testing.expect(!p.open);
    try p.moveTo(.{ .x = 50, .y = -20 });
    try std.testing.expectEqual(@as(f64, 50), p.bounds().?.max.x);
    try std.testing.expectEqual(box, (try paintedBounds(p.segments.items, .{})).?);
    try std.testing.expectError(error.InvalidParameter, Path.circle(std.testing.allocator, .zero, 0));
    try std.testing.expectError(error.NonFinite, Path.circle(std.testing.allocator, .zero, std.math.inf(f64)));
    var huge = try Path.circle(std.testing.allocator, .zero, 1.7e308);
    defer huge.deinit();
    const huge_bounds = huge.bounds().?;
    try std.testing.expect(huge_bounds.min.isFinite() and huge_bounds.max.isFinite());
    try std.testing.expectEqual(@as(f64, -1.7e308), huge_bounds.min.x);
    try std.testing.expectEqual(@as(f64, 1.7e308), huge_bounds.max.y);
}

test "path queries preserve exact segment boundaries" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.cubicTo(.{ .x = 10, .y = 5 }, .{ .x = 15, .y = 5 }, .{ .x = 20, .y = 0 });
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 0 }, try path.pointAt(0.5)));
    const boundary = try path.curveAt(1);
    try std.testing.expectEqual(@as(f64, 0), boundary.t);
    try std.testing.expect(g.tolerance.points(.{ .x = 10, .y = 0 }, boundary.curve.p0));
    try std.testing.expect(g.tolerance.points(.{ .x = 13.125, .y = 3.75 }, try path.pointAt(1.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 20, .y = 0 }, try path.pointAt(2)));
    try std.testing.expectEqual(@as(f64, 1), (try path.curveAt(2)).t);
    try std.testing.expectError(error.InvalidParameter, path.pointAt(-1));
    try std.testing.expectError(error.InvalidParameter, path.curveAt(2.1));
    try std.testing.expectError(error.InvalidParameter, path.pointAt(std.math.nan(f64)));
}

test "path query time skips pen up moves and zero closes while retaining implicit close edges" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.zero);
    try path.close(); // Zero-length topology marker, not a third segment.
    try path.moveTo(.{ .x = 100, .y = 100 });
    try path.lineTo(.{ .x = 110, .y = 100 });
    try path.close(); // Nonzero closing line is the fourth drawable segment.
    try path.moveTo(.{ .x = 999, .y = 999 }); // No extra drawable time.
    try std.testing.expectEqual(@as(usize, 4), path.segmentCount());
    try std.testing.expect(g.tolerance.points(.{ .x = 100, .y = 100 }, try path.pointAt(2)));
    try std.testing.expect(g.tolerance.points(.{ .x = 105, .y = 100 }, try path.pointAt(2.5)));
    try std.testing.expect(g.tolerance.points(.{ .x = 110, .y = 100 }, try path.pointAt(3)));
    try std.testing.expect(g.tolerance.points(.{ .x = 100, .y = 100 }, try path.pointAt(4)));
    var empty = Path.init(std.testing.allocator);
    defer empty.deinit();
    try empty.moveTo(.{ .x = 3, .y = 4 });
    try empty.close();
    try std.testing.expectError(error.InvalidParameter, empty.pointAt(0));
    try empty.moveTo(.{ .x = 3, .y = 4 });
    try empty.lineTo(.{ .x = 3, .y = 4 });
    try std.testing.expect(g.tolerance.points(.{ .x = 3, .y = 4 }, try empty.pointAt(0)));
}

test "path queries reject invalid topology without trapping" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = -1e308, .y = 0 });
    try path.lineTo(.{ .x = 1e308, .y = 0 });
    try std.testing.expect((try path.pointAt(0.5)).isFinite());
    try path.close();
    // Deliberately malformed raw input: a drawing command after CLOSE needs a
    // new MOVE. Public constructors prohibit it; the query must still reject.
    try path.segments.append(std.testing.allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, path.curveAt(2.5));
}
