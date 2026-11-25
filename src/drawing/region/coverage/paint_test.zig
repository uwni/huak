//! Tests of painted coverage: fills and fill rules, filldraw, stroke expansion before transforms, nested curved clips, miter and bevel strokes.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const DisplayList = @import("../../DisplayList.zig");
const testing = @import("testing.zig");
const rectangle = testing.rectangle;
const extractFixture = testing.extractFixture;
const area = testing.area;
const contains = testing.contains;

test "raw filled regions close implicitly and preserve explicit fill rules and holes" {
    const t = std.testing;
    var outer = try rectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    var inner = try rectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    try outer.append(inner);
    var nonzero = try extractFixture(t.allocator, .{ .path = outer }, .{ .fill_rule = .evenodd }, null);
    defer nonzero.deinit();
    try t.expectEqual(@as(usize, 1), nonzero.paths.len);
    try t.expectApproxEqAbs(@as(f64, 100), area(nonzero.paths[0]), 1e-8);
    var evenodd = try extractFixture(t.allocator, .{ .styled = .{ .path = outer, .style = .{ .fill = .black, .fill_rule = .evenodd }, .transform = g.Transform.scaling(-1, 1) } }, .{}, null);
    defer evenodd.deinit();
    try t.expectApproxEqAbs(@as(f64, 64), area(evenodd.paths[0]), 1e-8);
    try t.expect(contains(evenodd.paths[0], .{ .x = -1, .y = 1 }));
    try t.expect(!contains(evenodd.paths[0], .{ .x = -5, .y = 5 }));
    var triangle = Path.init(t.allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 0, .y = 10 });
    var implicit = try extractFixture(t.allocator, .{ .path = triangle }, .{}, null);
    defer implicit.deinit();
    try t.expectApproxEqAbs(@as(f64, 50), area(implicit.paths[0]), 1e-8);
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var zero_area = try extractFixture(t.allocator, .{ .path = line }, .{}, null);
    defer zero_area.deinit();
    try t.expectEqual(@as(usize, 0), zero_area.paths.len);
    var empty = try extractFixture(t.allocator, .{ .path = Path.init(t.allocator) }, .{}, null);
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.paths.len);
}

test "painted paths union filldraw internally and preserve order across reflected primitives" {
    const t = std.testing;
    var square = try rectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.fill(square, .{ .color = .{ .a = 0 } }, .{});
    try pic.filldraw(square, .{ .color = .{ .a = 0.2 } }, .{ .width = 2 }, .{});
    try pic.fill(square, .black, g.Transform.scaling(-1, 1).then(g.Transform.translation(10, 0)));
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{}, null);
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 144), area(result.paths[0]), 1e-8);
    try t.expectApproxEqAbs(@as(f64, 100), area(result.paths[1]), 1e-8);
    try t.expectEqual(@as(f64, -1), result.paths[0].bounds().?.min.x);
    try t.expectEqual(@as(f64, 0), result.paths[1].bounds().?.min.x);
    var singular = try extractFixture(t.allocator, .{ .styled = .{ .path = square, .style = .{ .fill = .black }, .transform = g.Transform.scaling(0, 1) } }, .{}, null);
    defer singular.deinit();
    try t.expectEqual(@as(usize, 0), singular.paths.len);
}

test "stroke expansion precedes affine transforms and supports ellipse offsets and dash dots" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var scaled = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 2 } }, .transform = g.Transform.scaling(2, 3) } }, .{}, null);
    defer scaled.deinit();
    try t.expectApproxEqAbs(@as(f64, 120), area(scaled.paths[0]), 1e-8);
    try t.expectApproxEqAbs(@as(f64, 6), scaled.paths[0].bounds().?.height(), 1e-8);
    var ellipse = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 0, .cap = .round, .nib = .{ .ellipse = .{ .a = 8, .d = 2, .e = 3, .f = 4 } } } } } }, .{}, null);
    defer ellipse.deinit();
    const box = ellipse.paths[0].bounds().?;
    try t.expectApproxEqAbs(@as(f64, -1), box.min.x, 0.002);
    try t.expectApproxEqAbs(@as(f64, 17), box.max.x, 0.002);
    try t.expectApproxEqAbs(@as(f64, 3), box.min.y, 0.002);
    try t.expectApproxEqAbs(@as(f64, 5), box.max.y, 0.002);
    var dots = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 2, .cap = .round, .dash = &.{ 0, 5 } } } } }, .{}, null);
    defer dots.deinit();
    try t.expectEqual(@as(usize, 1), dots.paths.len);
    try t.expect(contains(dots.paths[0], .{ .x = 0, .y = 0 }));
    try t.expect(contains(dots.paths[0], .{ .x = 5, .y = 0 }));
    try t.expect(!contains(dots.paths[0], .{ .x = 2.5, .y = 0 }));
    var hairline = try extractFixture(t.allocator, .{ .styled = .{ .path = line, .style = .{ .pen = .{ .width = 0 } } } }, .{}, null);
    defer hairline.deinit();
    try t.expectEqual(@as(usize, 0), hairline.paths.len);
}

test "nested clipping uses the actual curved region and preserves empty intersections" {
    const t = std.testing;
    var circle = try Path.circle(t.allocator, .zero, 10);
    defer circle.deinit();
    var half = try rectangle(t.allocator, 0, -20, 20, 40);
    defer half.deinit();
    var large = try rectangle(t.allocator, -20, -20, 40, 40);
    defer large.deinit();
    var pic = DisplayList.init(t.allocator);
    defer pic.deinit();
    try pic.beginScope(g.Transform.translation(100, 50), circle);
    try pic.beginScope(.{}, half);
    try pic.fill(large, .black, .{});
    try pic.endScope();
    try pic.endScope();
    var result = try extractFixture(t.allocator, .{ .picture = &pic }, .{ .tolerance = 0.01 }, null);
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), result.paths.len);
    try t.expectApproxEqAbs(@as(f64, 50 * std.math.pi), area(result.paths[0]), 0.1);
    try t.expect(contains(result.paths[0], .{ .x = 105, .y = 50 }));
    try t.expect(!contains(result.paths[0], .{ .x = 109, .y = 59 }));
    var empty_clip = Path.init(t.allocator);
    defer empty_clip.deinit();
    try empty_clip.moveTo(.zero);
    try empty_clip.lineTo(.{ .x = 1, .y = 0 });
    try empty_clip.close();
    var invisible = DisplayList.init(t.allocator);
    defer invisible.deinit();
    try invisible.beginScope(.{}, empty_clip);
    try invisible.fill(large, .black, .{});
    try invisible.addLabel(99, .{ .width = 10, .height = 10, .baseline = 8 }, .{});
    try invisible.endScope();
    var none = try extractFixture(t.allocator, .{ .picture = &invisible }, .{}, null);
    defer none.deinit();
    try t.expectEqual(@as(usize, 0), none.paths.len);
}

test "ordinary miter strokes bevel at the SVG limit including limit one" {
    const t = std.testing;
    var corner = Path.init(t.allocator);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 10, .y = 0 });
    try corner.lineTo(.{ .x = 10, .y = 10 });
    var one = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 1 } } } }, .{}, null);
    defer one.deinit();
    try t.expect(contains(one.paths[0], .{ .x = 10.1, .y = -0.1 }));
    try t.expect(!contains(one.paths[0], .{ .x = 10.9, .y = -0.9 }));
    var full = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 4 } } } }, .{}, null);
    defer full.deinit();
    try t.expect(contains(full.paths[0], .{ .x = 10.9, .y = -0.9 }));
    corner.deinit();
    corner = Path.init(t.allocator);
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 10, .y = 0 });
    try corner.lineTo(.{ .x = 0, .y = 1 });
    var acute = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 2, .miter_limit = 4 } } } }, .{}, null);
    defer acute.deinit();
    try t.expect(acute.paths[0].bounds().?.max.x < 10.11);
    try t.expect(!contains(acute.paths[0], .{ .x = 10.5, .y = -0.5 }));
}

test "wide almost straight bevel strokes do not grow a miter tip" {
    const t = std.testing;
    var corner = Path.init(t.allocator);
    defer corner.deinit();
    try corner.moveTo(.zero);
    try corner.lineTo(.{ .x = 1000, .y = 0 });
    try corner.lineTo(.{ .x = 2000, .y = 20 });
    var bevel = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 1000, .join = .bevel } } } }, .{}, null);
    defer bevel.deinit();
    var miter = try extractFixture(t.allocator, .{ .styled = .{ .path = corner, .style = .{ .pen = .{ .width = 1000, .join = .miter } } } }, .{}, null);
    defer miter.deinit();
    const between: g.Point = .{ .x = 1005, .y = -499.975 };
    try t.expect(!contains(bevel.paths[0], between));
    try t.expect(contains(miter.paths[0], between));
}
