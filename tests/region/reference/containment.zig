//! Nested holes, concave bounds, shared vertices and curved direction.
const std = @import("std");
const t = std.testing;
const core = @import("drawing");
const Path = core.Path;
const harness = @import("harness.zig");

test "reference: nested holes concave bounds shared vertices and curved direction retain signed area" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const outer = try harness.rect(allocator, 0, 0, 10, 10);
    const middle = try harness.rect(allocator, 2, 2, 6, 6);
    const island = try harness.rect(allocator, 4, 4, 2, 2);
    try harness.expectArea(allocator, try harness.compound(allocator, try harness.compound(allocator, outer, middle), island), empty, .unite, .evenodd, 68, 1e-9, "nested hole and island canonical winding");
    const reverse_outer = try harness.polygon(allocator, &.{ .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 0 } });
    try harness.expectArea(allocator, try harness.compound(allocator, reverse_outer, middle), empty, .unite, .nonzero, 64, 1e-9, "negative outer winding canonical normalization");
    const concave = try harness.polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 2 }, .{ 2, 2 }, .{ 2, 8 }, .{ 10, 8 }, .{ 10, 10 }, .{ 0, 10 } });
    try harness.expectArea(allocator, try harness.compound(allocator, concave, try harness.rect(allocator, 5, 4, 2, 2)), empty, .unite, .evenodd, 56, 1e-9, "bounds containment is not region containment");
    var teardrop = Path.init(allocator);
    try teardrop.moveTo(.zero);
    try teardrop.cubicTo(.{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 }, .zero);
    try teardrop.close();
    const teardrop_area = harness.area(teardrop);
    try t.expect(teardrop_area > 0);
    try harness.expectArea(allocator, teardrop, empty, .unite, .nonzero, teardrop_area, 1e-9, "curved loop direction cannot use endpoint polygon");
    try harness.expectArea(allocator, try teardrop.reverse(allocator), empty, .unite, .nonzero, teardrop_area, 1e-9, "reversed curved loop canonical direction");
    const canvas = try harness.rect(allocator, 0, 0, 100, 100);
    const reverse_rectangle = try harness.polygon(allocator, &.{ .{ 40, 80 }, .{ 90, 80 }, .{ 90, 30 }, .{ 40, 30 } });
    const opposite = try harness.compound(allocator, try harness.rect(allocator, 20, 20, 50, 50), reverse_rectangle);
    for (harness.operations, [_]f64{ 10000, 2600, 7400, 7400 }) |operation, expected| try harness.expectArea(allocator, canvas, opposite, operation, .nonzero, expected, 1e-9, "overlapping opposite raw contours preserve cancellation");
    const crossing = try harness.polygon(allocator, &.{ .{ 10, 10 }, .{ 90, 90 }, .{ 10, 90 }, .{ 90, 10 } });
    try harness.expectArea(allocator, crossing, try harness.rect(allocator, 30, 0, 40, 100), .xor, .nonzero, 2400, 1e-9, "self crossing XOR canonical hole winding");
    const e_shape = try harness.polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 1 }, .{ 1, 1 }, .{ 1, 4.5 }, .{ 6, 4.5 }, .{ 6, 5.5 }, .{ 1, 5.5 }, .{ 1, 9 }, .{ 10, 9 }, .{ 10, 10 }, .{ 0, 10 } });
    const c_shape = try harness.polygon(allocator, &.{ .{ 2, 2 }, .{ 8, 2 }, .{ 8, 8 }, .{ 2, 8 }, .{ 2, 7 }, .{ 7, 7 }, .{ 7, 3 }, .{ 2, 3 } });
    const small_hole = try harness.rect(allocator, 4, 4.8, 1, 0.4);
    try harness.expectArea(allocator, try harness.compound(allocator, try harness.compound(allocator, e_shape, c_shape), small_hole), empty, .unite, .evenodd, harness.area(e_shape) + harness.area(c_shape) - 0.4, 1e-9, "nested bounds with a geometrically unrelated intermediate contour");
    const wide_c = try harness.polygon(allocator, &.{ .{ 2, -2 }, .{ 12, -2 }, .{ 12, 8 }, .{ 2, 8 }, .{ 2, 7 }, .{ 11, 7 }, .{ 11, -1 }, .{ 2, -1 } });
    try harness.expectArea(allocator, try harness.compound(allocator, try harness.compound(allocator, wide_c, e_shape), small_hole), empty, .unite, .evenodd, harness.area(e_shape) + harness.area(wide_c) - 0.4, 1e-9, "overlapping sibling bounds do not choose the wrong hole parent");
    const a = try harness.circle(allocator, 0, 0, 10);
    const b = try harness.circle(allocator, 0, 0, 6);
    const c = try harness.circle(allocator, 0, 0, 2);
    try harness.expectArea(allocator, try harness.compound(allocator, try harness.compound(allocator, a, b), c), empty, .unite, .evenodd, harness.area(a) - harness.area(b) + harness.area(c), 1e-9, "nested curved hole and island canonical winding");
}
