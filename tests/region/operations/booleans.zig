//! Booleans and normalization: overlap area, short-edge merging, holes and components, fill rules, source cubics, near-loop cubics and contained regions.
const std = @import("std");
const core = @import("drawing");
const g = core.geometry;
const Path = core.Path;
const api = core.region;
const Operation = api.Operation;
const FillRule = api.FillRule;
const combine = api.combine;
const offset = api.offset;
const harness = @import("harness.zig");
const testRectangle = harness.testRectangle;
const area = harness.area;
const contourCount = harness.contourCount;

test "region booleans preserve overlap area and immutable inputs" {
    const t = std.testing;
    var a = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer a.deinit();
    var b = try testRectangle(t.allocator, 5, 0, 10, 10);
    defer b.deinit();
    var snapshot = try a.clone(t.allocator);
    defer snapshot.deinit();
    for ([_]Operation{ .unite, .intersect, .difference, .xor }, [_]f64{ 150, 50, 50, 100 }) |operation, expected| {
        var result = try combine(t.allocator, a, b, operation, .{});
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 1e-7);
        try t.expect(!result.open);
    }
    try t.expectEqualDeep(snapshot.segments.items, a.segments.items);
}

test "short-edge merging rebuilds vertex references before tracing" {
    const t = std.testing;
    var bevel = Path.init(t.allocator);
    defer bevel.deinit();
    try bevel.moveTo(.zero);
    for ([_]g.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0.000002, .y = 10 }, .{ .x = 0, .y = 9.999998 } }) |point| try bevel.lineTo(point);
    try bevel.close();
    // The bevel exceeds the vertex clustering radius but is shorter than
    // the edge merging threshold, so references must survive a second merge.
    var result = try combine(t.allocator, bevel, Path.init(t.allocator), .unite, .{ .tolerance = 1e-3 });
    defer result.deinit();
    try t.expectEqual(@as(usize, 4), result.segmentCount());
    try t.expectEqual(@as(usize, 1), contourCount(result));
    try t.expect(!result.open);
    try t.expectApproxEqAbs(@as(f64, 99.99999), area(result), 1e-12);
}

test "difference keeps holes and union keeps separate components" {
    const t = std.testing;
    var outer = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    var inner = try testRectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    var ring = try combine(t.allocator, outer, inner, .difference, .{});
    defer ring.deinit();
    try t.expectApproxEqAbs(@as(f64, 64), area(ring), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(ring));
    var far = try testRectangle(t.allocator, 20, 0, 10, 10);
    defer far.deinit();
    var separate = try combine(t.allocator, outer, far, .unite, .{});
    defer separate.deinit();
    try t.expectApproxEqAbs(@as(f64, 200), area(separate), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(separate));
    var empty = try combine(t.allocator, outer, far, .intersect, .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.segments.items.len);
}

test "fill rules resolve repeated contours orientation and self crossings" {
    const t = std.testing;
    var square = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var repeated = try square.clone(t.allocator);
    defer repeated.deinit();
    try repeated.append(square);
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    for ([_]FillRule{ .nonzero, .evenodd, .positive, .negative }, [_]f64{ 100, 0, 100, 0 }) |fill_rule, expected| {
        var result = try combine(t.allocator, repeated, empty, .unite, .{ .fill_rule = fill_rule });
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 1e-7);
    }
    var reverse = try square.reverse(t.allocator);
    defer reverse.deinit();
    var negative = try combine(t.allocator, reverse, empty, .unite, .{ .fill_rule = .negative });
    defer negative.deinit();
    try t.expectApproxEqAbs(@as(f64, 100), area(negative), 1e-7);
    var crossing = Path.init(t.allocator);
    defer crossing.deinit();
    try crossing.moveTo(.{ .x = 0, .y = 0 });
    try crossing.lineTo(.{ .x = 10, .y = 10 });
    try crossing.lineTo(.{ .x = 0, .y = 10 });
    try crossing.lineTo(.{ .x = 10, .y = 0 });
    try crossing.close();
    var resolved = try combine(t.allocator, crossing, empty, .unite, .{ .fill_rule = .evenodd });
    defer resolved.deinit();
    try t.expectApproxEqAbs(@as(f64, 50), area(resolved), 1e-7);
}

test "region normalization retains source cubics without flattening" {
    const t = std.testing;
    var circle = try Path.circle(t.allocator, .zero, 10);
    defer circle.deinit();
    var normalized = try offset(t.allocator, circle, 0, .{ .tolerance = 0.01 });
    defer normalized.deinit();
    try t.expectApproxEqAbs(100 * std.math.pi, area(normalized), 0.15);
    var retained_cubic = false;
    for (normalized.segments.items) |segment| retained_cubic = retained_cubic or segment == .cubic;
    try t.expect(retained_cubic);
    try t.expect(circle.segments.items[1] == .cubic);
    // A zero subdivision budget does not force untouched Beziers to flatten.
    // Source and output work budgets still apply independently of subdivision.
    var no_subdivision = try offset(t.allocator, circle, 0, .{ .tolerance = 0.01, .max_depth = 0 });
    defer no_subdivision.deinit();
    try t.expectApproxEqAbs(100 * std.math.pi, area(no_subdivision), 0.15);
    retained_cubic = false;
    for (no_subdivision.segments.items) |segment| retained_cubic = retained_cubic or segment == .cubic;
    try t.expect(retained_cubic);
    try t.expectError(error.GeometryWorkLimit, offset(t.allocator, circle, 0, .{ .max_segments = 3 }));
}

test "a straight cubic far from the origin is not taken for a loop" {
    // Face regions of a lit vase projection, reduced: a sliver of the neck
    // and the top, which begins with a straight piece of the rim written as
    // a cubic. Two squares fix the bounds, which place the kernel's origin
    // and so how far from it the straight cubic lies. There the cubic
    // classification read a loop whose two points lie 0.01pt apart; uniting
    // them folded the rim back over itself and lost the top.
    const t = std.testing;
    var faces = Path.init(t.allocator);
    defer faces.deinit();
    for ([_]g.Point{ .{ .x = 146.35658863592505, .y = -29.96577341979041 }, .{ .x = 209.8317160883295, .y = -29.96577341979041 } }) |corner| {
        var square = try testRectangle(t.allocator, corner.x, corner.y, 1, 1);
        defer square.deinit();
        try faces.append(square);
    }
    try faces.moveTo(.{ .x = 190.7715905462222, .y = -1.3800944344451596 });
    try faces.lineTo(.{ .x = 189.00977452877933, .y = 5.492615341328995 });
    try faces.lineTo(.{ .x = 188.99690147873653, .y = 5.500756874785078 });
    try faces.cubicTo(.{ .x = 189.03314290137462, .y = 5.486679385942028 }, .{ .x = 189.16198098053778, .y = 5.367301094536265 }, .{ .x = 189.38341571622598, .y = 5.142622000567798 });
    try faces.close();
    try faces.moveTo(.{ .x = 188.99690147873656, .y = 5.50075687478508 });
    try faces.cubicTo(.{ .x = 189.00119249541748, .y = 5.498043030299718 }, .{ .x = 189.0054835120984, .y = 5.495329185814357 }, .{ .x = 189.00977452877933, .y = 5.492615341328995 });
    try faces.lineTo(.{ .x = 198.9805497838637, .y = 12.038173865196336 });
    try faces.cubicTo(.{ .x = 197.45308952378588, .y = 12.26895034551507 }, .{ .x = 195.94122539361584, .y = 12.282881886789639 }, .{ .x = 194.6670907137477, .y = 12.176152621946335 });
    try faces.lineTo(.{ .x = 187.34122286517922, .y = 7.352664223992482 });
    try faces.cubicTo(.{ .x = 187.586193436829, .y = 6.623412831268673 }, .{ .x = 188.225066184585, .y = 5.98790559137918 }, .{ .x = 188.99690147873656, .y = 5.50075687478508 });
    try faces.close();
    var united = try combine(t.allocator, faces, Path.init(t.allocator), .unite, .{});
    defer united.deinit();
    try t.expect(try api.windingAt(united, .{ .x = 193.5, .y = 10 }) != 0);
    try t.expectApproxEqAbs(@as(f64, 29.3302), area(united), 1e-4);
}

test "a region inside another stays when its corner lies on the chord of the other's arc" {
    // A piece from overlapping eight circles: a curved triangle inside a
    // circle, one corner exactly on the chord of the circle's upper-left arc.
    // Clipping shrank the triangle's side to that corner and narrowed the arc
    // to where it crosses the corner's x, pairing two points 12pt apart as
    // one intersection; the union and the intersection came out empty.
    const t = std.testing;
    var triangle = Path.init(t.allocator);
    defer triangle.deinit();
    try triangle.moveTo(.{ .x = 1.943334382303874e-12, .y = 10.100293401361455 });
    try triangle.cubicTo(.{ .x = -1.1309568507194627, .y = 9.413091785313565 }, .{ .x = -2.212872553126151, .y = 8.653217790598447 }, .{ .x = -3.239265515186327, .y = 7.827153009247898 });
    try triangle.cubicTo(.{ .x = -2.175176174582095, .y = 7.941395346028589 }, .{ .x = -1.0944320124659423, .y = 8.000000000000004 }, .{ .x = -4.440892098500626e-15, .y = 8 });
    try triangle.cubicTo(.{ .x = 1.0944320124659386, .y = 8 }, .{ .x = 2.175176174582099, .y = 7.941395346028582 }, .{ .x = 3.2392655151863354, .y = 7.8271530092478905 });
    try triangle.cubicTo(.{ .x = 2.2128725531267364, .y = 8.653217790597978 }, .{ .x = 1.130956850722658, .y = 9.41309178531387 }, .{ .x = 1.943334382303874e-12, .y = 10.100293401361455 });
    try triangle.close();
    var circle = try Path.circle(t.allocator, .{ .x = 22, .y = 0 }, 30);
    defer circle.deinit();
    for ([2][2]Path{ .{ triangle, circle }, .{ circle, triangle } }) |operands| {
        var both = try combine(t.allocator, operands[0], operands[1], .intersect, .{});
        defer both.deinit();
        try t.expectApproxEqAbs(area(triangle), area(both), 1e-9);
        var either = try combine(t.allocator, operands[0], operands[1], .unite, .{});
        defer either.deinit();
        try t.expectApproxEqAbs(area(circle), area(either), 1e-9);
    }
    var outside = try combine(t.allocator, triangle, circle, .difference, .{});
    defer outside.deinit();
    try t.expectEqual(@as(usize, 0), outside.segments.items.len);
}
