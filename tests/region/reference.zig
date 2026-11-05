//! Geometry contracts migrated from the former native PathOps reference tests.
//! The original inputs and absolute area/probe thresholds are unchanged. All
//! calls use Huak's public owned Path and region API, without a C ABI mirror.
const std = @import("std");
const t = std.testing;
const core = @import("drawing");
const Path = core.Path;
const Point = core.geometry.Point;
const Operation = core.region.Operation;
const FillRule = core.region.FillRule;
const Allocator = std.mem.Allocator;
const operations = [_]Operation{ .unite, .intersect, .difference, .xor };
const rules = [_]FillRule{ .evenodd, .nonzero, .positive, .negative };

fn polygon(allocator: Allocator, points: []const [2]f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    if (points.len == 0) return result;
    try result.moveTo(.{ .x = points[0][0], .y = points[0][1] });
    for (points[1..]) |point| try result.lineTo(.{ .x = point[0], .y = point[1] });
    try result.close();
    return result;
}
fn rect(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    return polygon(allocator, &.{ .{ x, y }, .{ x + width, y }, .{ x + width, y + height }, .{ x, y + height } });
}
fn circle(allocator: Allocator, x: f64, y: f64, radius: f64) !Path {
    // Keep the exact reference's kappa literal rather than recomputing tan.
    const k = radius * 0.5522847498307936;
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x + radius, .y = y });
    try result.cubicTo(.{ .x = x + radius, .y = y + k }, .{ .x = x + k, .y = y + radius }, .{ .x = x, .y = y + radius });
    try result.cubicTo(.{ .x = x - k, .y = y + radius }, .{ .x = x - radius, .y = y + k }, .{ .x = x - radius, .y = y });
    try result.cubicTo(.{ .x = x - radius, .y = y - k }, .{ .x = x - k, .y = y - radius }, .{ .x = x, .y = y - radius });
    try result.cubicTo(.{ .x = x + k, .y = y - radius }, .{ .x = x + radius, .y = y - k }, .{ .x = x + radius, .y = y });
    try result.close();
    return result;
}
fn compound(allocator: Allocator, first: Path, second: Path) !Path {
    var result = try first.clone(allocator);
    errdefer result.deinit();
    try result.append(second);
    return result;
}

// The reference's three-point Gauss integral is exact for the degree-five
// polynomial in real arithmetic and independent of the engine's signedArea.
fn cubicArea(start: Point, curve: core.geometry.Cubic) f64 {
    const root = @sqrt(@as(f64, 3.0 / 5.0));
    const times = [_]f64{ 0.5 * (1 - root), 0.5, 0.5 * (1 + root) };
    const weights = [_]f64{ 5.0 / 18.0, 4.0 / 9.0, 5.0 / 18.0 };
    const px = [_]f64{ start.x, curve.p1.x, curve.p2.x, curve.p3.x };
    const py = [_]f64{ start.y, curve.p1.y, curve.p2.y, curve.p3.y };
    var total: f64 = 0;
    for (times, weights) |parameter, weight| {
        const u = 1 - parameter;
        const x = u * u * u * px[0] + 3 * u * u * parameter * px[1] + 3 * u * parameter * parameter * px[2] + parameter * parameter * parameter * px[3];
        const y = u * u * u * py[0] + 3 * u * u * parameter * py[1] + 3 * u * parameter * parameter * py[2] + parameter * parameter * parameter * py[3];
        const dx = 3 * (u * u * (px[1] - px[0]) + 2 * u * parameter * (px[2] - px[1]) + parameter * parameter * (px[3] - px[2]));
        const dy = 3 * (u * u * (py[1] - py[0]) + 2 * u * parameter * (py[2] - py[1]) + parameter * parameter * (py[3] - py[2]));
        total += weight * (x * dy - y * dx);
    }
    return total;
}
fn segmentArea(segments: []const core.Path.Segment) f64 {
    var current: Point = .zero;
    var start: Point = .zero;
    var total: f64 = 0;
    for (segments) |segment| switch (segment) {
        .move => |point| {
            current = point;
            start = point;
        },
        .line => |point| {
            total += current.cross(point);
            current = point;
        },
        .close => {
            total += current.cross(start);
            current = start;
        },
        .cubic => |curve| {
            total += cubicArea(current, .{ .p0 = current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end });
            current = curve.end;
        },
    };
    return total * 0.5;
}
fn area(path: Path) f64 {
    return segmentArea(path.segments.items);
}
fn expectArea(allocator: Allocator, first: Path, second: Path, operation: Operation, rule: FillRule, expected: f64, tolerance: f64, description: []const u8) !void {
    var result = core.region.combine(allocator, first, second, operation, .{ .fill_rule = rule }) catch |err| {
        std.debug.print("reference {s}, {s}/{s}: {s}\n", .{ description, @tagName(operation), @tagName(rule), @errorName(err) });
        return err;
    };
    defer result.deinit();
    const actual = area(result);
    if (@abs(actual - expected) > tolerance) std.debug.print("reference {s}, {s}/{s}: expected {d}, got {d}\n", .{ description, @tagName(operation), @tagName(rule), expected, actual });
    try t.expectApproxEqAbs(expected, actual, tolerance);
}

fn operationArea(operation: Operation, a: f64, b: f64) f64 {
    return switch (operation) {
        .unite => @max(a, b),
        .intersect => @min(a, b),
        .difference => if (b == 0) a else 0,
        .xor => @abs(a - b),
    };
}

test "reference: rectangles curved lens coincidence and fine holes retain native thresholds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const a = try rect(allocator, 0, 0, 10, 10);
    const b = try rect(allocator, 5, 0, 10, 10);
    for (operations, [_]f64{ 150, 50, 50, 100 }) |operation, expected| try expectArea(allocator, a, b, operation, .nonzero, expected, 1e-10, "rectangle operation area");
    const c = try circle(allocator, 45, 50, 35);
    const d = try circle(allocator, 75, 50, 35);
    var lens = try core.region.combine(allocator, c, d, .intersect, .{});
    defer lens.deinit();
    var has_cubic = false;
    for (lens.segments.items) |segment| if (segment == .cubic) {
        has_cubic = true;
    };
    try t.expect(has_cubic);
    var difference = try core.region.combine(allocator, c, c, .difference, .{});
    defer difference.deinit();
    try t.expectEqual(@as(usize, 0), difference.segments.items.len);
    for ([_]f64{ 1e5, 1e6, 1e8 }) |span| {
        var result = try core.region.combine(allocator, try rect(allocator, 0, 0, span, 100), try rect(allocator, span * 0.75, 20, 0.001, 20), .difference, .{});
        defer result.deinit();
        var count: usize = 0;
        for (result.segments.items) |segment| if (segment == .move) {
            count += 1;
        };
        try t.expectEqual(@as(usize, 2), count);
    }
}

test "reference: four fill rules preserve repeated reverse and self crossing rectangle matrices" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const ccw = try rect(allocator, 0, 0, 10, 10);
    // Keep the reference reverse's original final-vertex start position.
    const cw = try polygon(allocator, &.{ .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 0 } });
    const twice = try compound(allocator, ccw, ccw);
    const cancelled = try compound(allocator, ccw, cw);
    const crossing = try polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 10, 0 } });
    const upper = try rect(allocator, -1, 5, 12, 6);
    const lower = try rect(allocator, -1, -1, 12, 6);
    const ccw_expected = [_]f64{ 100, 100, 100, 0 };
    const cw_expected = [_]f64{ 100, 100, 0, 100 };
    const twice_expected = [_]f64{ 0, 100, 100, 0 };
    const crossing_expected = [_]f64{ 50, 50, 25, 25 };
    const upper_expected = [_]f64{ 25, 25, 25, 0 };
    const lower_expected = [_]f64{ 25, 25, 0, 25 };
    for (rules, 0..) |rule, index| {
        try expectArea(allocator, ccw, empty, .unite, rule, ccw_expected[index], 1e-9, "CCW fill rule");
        try expectArea(allocator, cw, empty, .unite, rule, cw_expected[index], 1e-9, "CW fill rule");
        try expectArea(allocator, twice, empty, .unite, rule, twice_expected[index], 1e-9, "same direction double winding");
        try expectArea(allocator, cancelled, empty, .unite, rule, 0, 1e-9, "opposite winding cancellation");
        try expectArea(allocator, crossing, empty, .unite, rule, crossing_expected[index], 1e-9, "self crossing fill rule");
        var resolved = try core.region.combine(allocator, crossing, empty, .unite, .{ .fill_rule = rule });
        defer resolved.deinit();
        try expectArea(allocator, resolved, upper, .intersect, .nonzero, upper_expected[index], 1e-9, "self crossing upper lobe");
        try expectArea(allocator, resolved, lower, .intersect, .nonzero, lower_expected[index], 1e-9, "self crossing lower lobe");
        for ([_]bool{ false, true }) |reverse| for (operations) |operation| {
            const other = if (reverse) cw else ccw;
            const other_area = if (reverse) cw_expected[index] else ccw_expected[index];
            try expectArea(allocator, ccw, other, operation, rule, operationArea(operation, ccw_expected[index], other_area), 1e-9, "coincident rectangles each operand fill");
        };
    }
}

test "reference: four fill rules preserve all identical and reversed cubic operations" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const curve = try circle(allocator, 12, 15, 10);
    const back = try curve.reverse(allocator);
    const curve_area = area(curve);
    for (rules) |rule| for ([_]bool{ false, true }) |reverse| for (operations) |operation| {
        const a = if (rule == .negative) 0 else curve_area;
        const b = if (reverse) (if (rule == .positive) 0 else curve_area) else a;
        try expectArea(allocator, curve, if (reverse) back else curve, operation, rule, operationArea(operation, a, b), 1e-9, "coincident cubics each operand fill");
    };
}

test "reference: nested holes concave bounds shared vertices and curved direction retain signed area" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const outer = try rect(allocator, 0, 0, 10, 10);
    const middle = try rect(allocator, 2, 2, 6, 6);
    const island = try rect(allocator, 4, 4, 2, 2);
    try expectArea(allocator, try compound(allocator, try compound(allocator, outer, middle), island), empty, .unite, .evenodd, 68, 1e-9, "nested hole and island canonical winding");
    const reverse_outer = try polygon(allocator, &.{ .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 0 } });
    try expectArea(allocator, try compound(allocator, reverse_outer, middle), empty, .unite, .nonzero, 64, 1e-9, "negative outer winding canonical normalization");
    const concave = try polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 2 }, .{ 2, 2 }, .{ 2, 8 }, .{ 10, 8 }, .{ 10, 10 }, .{ 0, 10 } });
    try expectArea(allocator, try compound(allocator, concave, try rect(allocator, 5, 4, 2, 2)), empty, .unite, .evenodd, 56, 1e-9, "bounds containment is not region containment");
    var teardrop = Path.init(allocator);
    try teardrop.moveTo(.zero);
    try teardrop.cubicTo(.{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 }, .zero);
    try teardrop.close();
    const teardrop_area = area(teardrop);
    try t.expect(teardrop_area > 0);
    try expectArea(allocator, teardrop, empty, .unite, .nonzero, teardrop_area, 1e-9, "curved loop direction cannot use endpoint polygon");
    try expectArea(allocator, try teardrop.reverse(allocator), empty, .unite, .nonzero, teardrop_area, 1e-9, "reversed curved loop canonical direction");
    const canvas = try rect(allocator, 0, 0, 100, 100);
    const reverse_rectangle = try polygon(allocator, &.{ .{ 40, 80 }, .{ 90, 80 }, .{ 90, 30 }, .{ 40, 30 } });
    const opposite = try compound(allocator, try rect(allocator, 20, 20, 50, 50), reverse_rectangle);
    for (operations, [_]f64{ 10000, 2600, 7400, 7400 }) |operation, expected| try expectArea(allocator, canvas, opposite, operation, .nonzero, expected, 1e-9, "overlapping opposite raw contours preserve cancellation");
    const crossing = try polygon(allocator, &.{ .{ 10, 10 }, .{ 90, 90 }, .{ 10, 90 }, .{ 90, 10 } });
    try expectArea(allocator, crossing, try rect(allocator, 30, 0, 40, 100), .xor, .nonzero, 2400, 1e-9, "self crossing XOR canonical hole winding");
    const e_shape = try polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 1 }, .{ 1, 1 }, .{ 1, 4.5 }, .{ 6, 4.5 }, .{ 6, 5.5 }, .{ 1, 5.5 }, .{ 1, 9 }, .{ 10, 9 }, .{ 10, 10 }, .{ 0, 10 } });
    const c_shape = try polygon(allocator, &.{ .{ 2, 2 }, .{ 8, 2 }, .{ 8, 8 }, .{ 2, 8 }, .{ 2, 7 }, .{ 7, 7 }, .{ 7, 3 }, .{ 2, 3 } });
    const small_hole = try rect(allocator, 4, 4.8, 1, 0.4);
    try expectArea(allocator, try compound(allocator, try compound(allocator, e_shape, c_shape), small_hole), empty, .unite, .evenodd, area(e_shape) + area(c_shape) - 0.4, 1e-9, "nested bounds with a geometrically unrelated intermediate contour");
    const wide_c = try polygon(allocator, &.{ .{ 2, -2 }, .{ 12, -2 }, .{ 12, 8 }, .{ 2, 8 }, .{ 2, 7 }, .{ 11, 7 }, .{ 11, -1 }, .{ 2, -1 } });
    try expectArea(allocator, try compound(allocator, try compound(allocator, wide_c, e_shape), small_hole), empty, .unite, .evenodd, area(e_shape) + area(wide_c) - 0.4, 1e-9, "overlapping sibling bounds do not choose the wrong hole parent");
    const a = try circle(allocator, 0, 0, 10);
    const b = try circle(allocator, 0, 0, 6);
    const c = try circle(allocator, 0, 0, 2);
    try expectArea(allocator, try compound(allocator, try compound(allocator, a, b), c), empty, .unite, .evenodd, area(a) - area(b) + area(c), 1e-9, "nested curved hole and island canonical winding");
}

fn cubic(path: *Path, points: [3][2]f64) !void {
    try path.cubicTo(.{ .x = points[0][0], .y = points[0][1] }, .{ .x = points[1][0], .y = points[1][1] }, .{ .x = points[2][0], .y = points[2][1] });
}

test "reference: normalization preserves repeated traversal and overlapping contour winding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const empty = Path.init(allocator);
    const overlapping = try compound(allocator, try rect(allocator, 0, 0, 10, 10), try rect(allocator, 5, 0, 10, 10));
    // One contour visits the same boundary twice; its winding is two, not zero.
    const twice = try polygon(allocator, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } });
    for (rules, [_]f64{ 100, 150, 150, 0 }, [_]f64{ 0, 100, 100, 0 }) |rule, overlap_area, twice_area| {
        try expectArea(allocator, overlapping, empty, .unite, rule, overlap_area, 1e-9, "same-direction overlapping contours");
        try expectArea(allocator, twice, empty, .unite, rule, twice_area, 1e-9, "twice-traversed contour");
    }
}

test "reference: exact glyph O boundary cut retains its counter without installed fonts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const domain = try polygon(allocator, &.{
        .{ -0.78132812500000004, -0.54656249999999995 },
        .{ 0.78132812499999993, -0.54656249999999995 },
        .{ 0.78132812499999993, 0.54734375000000002 },
        .{ -0.78132812500000004, 0.54734375000000002 },
    });
    var glyph = Path.init(allocator);
    try glyph.moveTo(.{ .x = -0.75168749999999995, .y = -0.48993749999999991 });
    try cubic(&glyph, .{ .{ -0.76835937499999996, -0.48993749999999991 }, .{ -0.77807031250000003, -0.50317187499999994 }, .{ -0.77807031250000003, -0.51984374999999994 } });
    try cubic(&glyph, .{ .{ -0.77807031250000003, -0.53677343749999995 }, .{ -0.76578124999999997, -0.54734374999999991 }, .{ -0.75117187500000004, -0.54734374999999991 } });
    try cubic(&glyph, .{ .{ -0.74163281250000002, -0.54734374999999991 }, .{ -0.73407031249999999, -0.54321874999999986 }, .{ -0.72934374999999996, -0.53651562499999994 } });
    try cubic(&glyph, .{ .{ -0.72590624999999998, -0.53161718749999987 }, .{ -0.72401562500000005, -0.52542968749999996 }, .{ -0.72401562500000005, -0.51821093749999991 } });
    try cubic(&glyph, .{ .{ -0.72401562500000005, -0.5004218749999999 }, .{ -0.7363046875, -0.48993749999999991 }, .{ -0.75168749999999995, -0.48993749999999991 } });
    try glyph.close();
    try glyph.moveTo(.{ .x = -0.73226562500000003, .y = -0.51984374999999994 });
    try cubic(&glyph, .{ .{ -0.73226562500000003, -0.53522656249999989 }, .{ -0.73965625000000002, -0.5442499999999999 }, .{ -0.74945312500000005, -0.5442499999999999 } });
    try cubic(&glyph, .{ .{ -0.75993750000000004, -0.5442499999999999 }, .{ -0.76982031250000005, -0.53488281249999992 }, .{ -0.76982031250000005, -0.51838281249999996 } });
    try cubic(&glyph, .{ .{ -0.76982031250000005, -0.50033593749999994 }, .{ -0.76131249999999995, -0.49303124999999992 }, .{ -0.75280468749999996, -0.49303124999999992 } });
    try cubic(&glyph, .{ .{ -0.74146093749999997, -0.49303124999999992 }, .{ -0.73226562500000003, -0.50248437499999987 }, .{ -0.73226562500000003, -0.51984374999999994 } });
    try glyph.close();
    var result = try core.region.combine(allocator, domain, glyph, .difference, .{});
    defer result.deinit();
    var components: usize = 0;
    var cubics: usize = 0;
    var start: usize = 0;
    for (result.segments.items, 0..) |segment, index| switch (segment) {
        .move => start = index,
        .cubic => cubics += 1,
        .close => {
            try t.expect(segmentArea(result.segments.items[start .. index + 1]) > 0);
            components += 1;
        },
        .line => {},
    };
    try t.expectEqual(@as(usize, 2), components);
    try t.expect(cubics >= 9);
    const probes = [_]struct { x: f64, y: f64, expected: f64, name: []const u8 }{
        .{ .x = -0.70, .y = -0.52, .expected = 4e-8, .name = "glyph cut keeps surrounding canvas" },
        .{ .x = -0.751, .y = -0.519, .expected = 4e-8, .name = "glyph cut keeps the counter island" },
        .{ .x = -0.775, .y = -0.52, .expected = 0, .name = "glyph cut removes the left stroke" },
        .{ .x = -0.750, .y = -0.545, .expected = 0, .name = "glyph cut removes the bottom stroke" },
        .{ .x = -0.79, .y = -0.50, .expected = 0, .name = "glyph cut preserves the domain boundary" },
    };
    for (probes) |probe| try expectArea(allocator, result, try rect(allocator, probe.x, probe.y, 0.0002, 0.0002), .intersect, .nonzero, probe.expected, 1e-9, probe.name);
}

test "reference: owned Path retains binary64 controls reversal and explicit close semantics" {
    // This carries the C++ container test's geometric intent. The removed
    // legacy iterator's synthetic line records are not a public Path API.
    const base = 1e12;
    const detail = 0.001;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = base, .y = base });
    try source.lineTo(.{ .x = base + detail, .y = base });
    try source.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    try t.expectEqual(@as(f64, base + detail), source.segments.items[1].line.x);
    try t.expectEqual(Point{ .x = 1, .y = 2 }, source.segments.items[2].cubic.c1);
    try t.expectEqual(Point{ .x = 3, .y = 4 }, source.segments.items[2].cubic.c2);
    try t.expectEqual(Point{ .x = 5, .y = 6 }, source.segments.items[2].cubic.end);
    var reversed = try source.reverse(t.allocator);
    defer reversed.deinit();
    var restored = try reversed.reverse(t.allocator);
    defer restored.deinit();
    try t.expectEqualDeep(source.segments.items, restored.segments.items);
    try source.close();
    try t.expect(!source.open);
    try t.expect(source.segments.items[source.segments.items.len - 1] == .close);
    try t.expectEqual(@as(usize, 3), source.segmentCount());
}
