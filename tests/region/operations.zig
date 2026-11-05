//! Migrated region contracts. Numeric/error/allocation expectations are kept
//! from the former polygon adapter; only flattening-specific assertions change.
const std = @import("std");
const core = @import("drawing");
const g = core.geometry;
const Path = core.Path;
const api = core.region;
const Allocator = std.mem.Allocator;
const Operation = api.Operation;
const FillRule = api.FillRule;
const Join = api.Join;
const Cap = api.Cap;
const combine = api.combine;
const offset = api.offset;
const stroke = api.stroke;
const clipRegion = api.clipRegion;
const clipLines = api.clipLines;

fn testRectangle(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y + height });
    try result.lineTo(.{ .x = x, .y = y + height });
    try result.close();
    return result;
}

fn area(path: Path) f64 {
    return path.signedArea();
}

fn contourCount(path: Path) usize {
    var count: usize = 0;
    for (path.segments.items) |segment| if (segment == .move) {
        count += 1;
    };
    return count;
}

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

test "offset expands contracts and removes regions with their holes" {
    const t = std.testing;
    var outer = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    for ([_]f64{ 2, -2, -6 }, [_]f64{ 196, 36, 0 }) |distance, expected| {
        var result = try offset(t.allocator, outer, distance, .{ .join = .miter });
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 1e-7);
    }
    var inner = try testRectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    var ring = try combine(t.allocator, outer, inner, .difference, .{});
    defer ring.deinit();
    var expanded = try offset(t.allocator, ring, 1, .{ .join = .miter });
    defer expanded.deinit();
    try t.expectApproxEqAbs(@as(f64, 128), area(expanded), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(expanded));
    var vanished = try offset(t.allocator, ring, -1, .{ .join = .miter });
    defer vanished.deinit();
    try t.expectEqual(@as(usize, 0), vanished.segments.items.len);
    var duplicate = try ring.clone(t.allocator);
    defer duplicate.deinit();
    try ring.append(duplicate);
    var normalized = try offset(t.allocator, ring, 0, .{ .fill_rule = .evenodd });
    defer normalized.deinit();
    try t.expectEqual(@as(usize, 0), normalized.segments.items.len);
}

test "ordinary stroke outlines honor caps and closed seams in mixed input" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    for ([_]Cap{ .butt, .square, .round }, [_]f64{ 40, 56, 40 + 4 * std.math.pi }) |cap, expected| {
        var result = try stroke(t.allocator, line, 4, .{ .cap = cap });
        defer result.deinit();
        try t.expectApproxEqAbs(expected, area(result), 0.01);
    }
    var closed = try testRectangle(t.allocator, 30, 0, 10, 10);
    defer closed.deinit();
    var outline = try stroke(t.allocator, closed, 2, .{ .join = .miter });
    defer outline.deinit();
    try t.expectApproxEqAbs(@as(f64, 80), area(outline), 1e-7);
    try t.expectEqual(@as(usize, 2), contourCount(outline));
    try line.append(closed);
    var mixed = try stroke(t.allocator, line, 2, .{ .cap = .square, .join = .miter });
    defer mixed.deinit();
    try t.expectApproxEqAbs(@as(f64, 104), area(mixed), 1e-7);
    var zero = try stroke(t.allocator, line, 0, .{});
    defer zero.deinit();
    try t.expectEqual(@as(usize, 0), zero.segments.items.len);
}

test "a two-point closed path does not change the seam of later closed paths" {
    const t = std.testing;
    var pair = Path.init(t.allocator);
    defer pair.deinit();
    try pair.moveTo(.zero);
    try pair.lineTo(.{ .x = 10, .y = 0 });
    try pair.close();
    var square = try testRectangle(t.allocator, 30, 0, 10, 10);
    defer square.deinit();
    var both = try pair.clone(t.allocator);
    defer both.deinit();
    try both.append(square);
    for ([_]Join{ .miter, .round, .bevel, .square }) |join| {
        var first = try stroke(t.allocator, pair, 2, .{ .join = join });
        defer first.deinit();
        var second = try stroke(t.allocator, square, 2, .{ .join = join });
        defer second.deinit();
        var result = try stroke(t.allocator, both, 2, .{ .join = join });
        defer result.deinit();
        try t.expectApproxEqAbs(area(first) + area(second), area(result), 0.01);
        try t.expectEqual(contourCount(first) + contourCount(second), contourCount(result));
    }
}

test "point strokes use the cap rather than unrelated join choices" {
    const t = std.testing;
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try point.lineTo(.zero);
    for ([_]Join{ .miter, .round }) |join| {
        for ([_]Cap{ .butt, .round, .square }, [_]f64{ 0, 4 * std.math.pi, 16 }) |cap, expected| {
            var result = try stroke(t.allocator, point, 4, .{ .cap = cap, .join = join });
            defer result.deinit();
            try t.expectApproxEqAbs(expected, area(result), 0.01);
        }
    }
    try point.close();
    var closed = try stroke(t.allocator, point, 4, .{ .cap = .round, .join = .round });
    defer closed.deinit();
    try t.expectEqual(@as(usize, 0), closed.segments.items.len);
}

test "empty and zero-area regions remain empty and every contour must close" {
    const t = std.testing;
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    for ([_]Operation{ .unite, .intersect, .difference, .xor }) |operation| {
        var result = try combine(t.allocator, empty, empty, operation, .{});
        defer result.deinit();
        try t.expectEqual(@as(usize, 0), result.segments.items.len);
    }
    var collinear = Path.init(t.allocator);
    defer collinear.deinit();
    try collinear.moveTo(.zero);
    try collinear.lineTo(.{ .x = 10, .y = 0 });
    try collinear.lineTo(.{ .x = 20, .y = 0 });
    try collinear.close();
    var collapsed = try combine(t.allocator, collinear, empty, .unite, .{});
    defer collapsed.deinit();
    try t.expectEqual(@as(usize, 0), collapsed.segments.items.len);
    try collinear.moveTo(.zero);
    try collinear.moveTo(.{ .x = 5, .y = 5 });
    try collinear.close();
    try t.expectError(error.OpenPath, offset(t.allocator, collinear, 1, .{}));
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try t.expectError(error.OpenPath, combine(t.allocator, point, empty, .unite, .{}));
    try point.close();
    var closed_point = try offset(t.allocator, point, 1, .{});
    defer closed_point.deinit();
    try t.expectEqual(@as(usize, 0), closed_point.segments.items.len);
}

test "rectangle region clipping resolves a hole opening onto its boundary" {
    const t = std.testing;
    var outer = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer outer.deinit();
    var inner = try testRectangle(t.allocator, 2, 2, 6, 6);
    defer inner.deinit();
    var ring = try combine(t.allocator, outer, inner, .difference, .{});
    defer ring.deinit();
    var clipped = try clipRegion(t.allocator, ring, .{ .min = .{ .x = 5, .y = -1 }, .max = .{ .x = 12, .y = 11 } }, .{});
    defer clipped.deinit();
    try t.expectApproxEqAbs(@as(f64, 32), area(clipped), 1e-7);
    try t.expectEqual(@as(usize, 1), contourCount(clipped));
}

test "line rectangle clipping keeps open fragments and implicit closing edges" {
    const t = std.testing;
    var closed = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer closed.deinit();
    var left = try clipLines(t.allocator, closed, .{ .min = .{ .x = -1, .y = 2 }, .max = .{ .x = 1, .y = 8 } }, .{});
    defer left.deinit();
    try t.expectEqual(@as(usize, 1), contourCount(left));
    try t.expectEqual(@as(usize, 1), left.segmentCount());
    try t.expect(left.open);
    const box = left.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 0), box.min.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 0), box.max.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 2), box.min.y, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 8), box.max.y, 1e-7);
}

test "line rectangle clipping retains boundary segments and drops point-only contacts" {
    const t = std.testing;
    const box = g.BBox.fromPoints(.zero, .{ .x = 1, .y = 1 });
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = -1, .y = 0 });
    try line.lineTo(.{ .x = 2, .y = 0 });
    var boundary = try clipLines(t.allocator, line, box, .{});
    defer boundary.deinit();
    try t.expectEqual(@as(usize, 1), boundary.segmentCount());
    try t.expectApproxEqAbs(@as(f64, 0), boundary.bounds().?.min.x, 1e-7);
    try t.expectApproxEqAbs(@as(f64, 1), boundary.bounds().?.max.x, 1e-7);
    var touching = Path.init(t.allocator);
    defer touching.deinit();
    try touching.moveTo(.{ .x = -1, .y = 1 });
    try touching.lineTo(.{ .x = 1, .y = -1 });
    var contact = try clipLines(t.allocator, touching, box, .{});
    defer contact.deinit();
    try t.expectEqual(@as(usize, 0), contact.segmentCount());
}

test "line clipping retains physically nonempty short parameter intervals" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = -1e12, .y = 0 });
    try line.lineTo(.{ .x = 1e12, .y = 0 });
    const rectangle = g.BBox.fromPoints(.{ .x = 1, .y = -1 }, .{ .x = 1.01, .y = 1 });
    var clipped = try clipLines(t.allocator, line, rectangle, .{ .tolerance = 0.001 });
    defer clipped.deinit();
    try t.expectEqual(@as(usize, 1), clipped.segmentCount());
    try t.expectApproxEqAbs(@as(f64, 1), clipped.bounds().?.min.x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 1.01), clipped.bounds().?.max.x, 0.001);
}

test "fully retained closed linework still returns open fragments" {
    const t = std.testing;
    var square = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var result = try clipLines(t.allocator, square, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 11, .y = 11 }), .{});
    defer result.deinit();
    try t.expect(result.open);
    try t.expectEqual(@as(usize, 4), result.segmentCount());
    for (result.segments.items) |segment| try t.expect(segment != .close);
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    try point.lineTo(.zero);
    var empty = try clipLines(t.allocator, point, .fromPoints(.{ .x = -1, .y = -1 }, .{ .x = 1, .y = 1 }), .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.segments.items.len);
}

test "region vertex budgets count coordinates independently of close markers" {
    const t = std.testing;
    var square = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer square.deinit();
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    var result = try combine(t.allocator, square, empty, .unite, .{ .max_vertices = 4 });
    defer result.deinit();
    try t.expectApproxEqAbs(@as(f64, 100), area(result), 1e-7);
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, square, empty, .unite, .{ .max_vertices = 3 }));
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

test "region validation precision and aggregate work limits are explicit" {
    const t = std.testing;
    var a = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer a.deinit();
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    var open = Path.init(t.allocator);
    defer open.deinit();
    try open.moveTo(.zero);
    try open.lineTo(.{ .x = 10, .y = 0 });
    try t.expectError(error.OpenPath, combine(t.allocator, open, a, .unite, .{}));
    try t.expectError(error.OpenPath, offset(t.allocator, open, 1, .{}));
    try t.expectError(error.OpenPath, clipRegion(t.allocator, open, .fromPoints(.zero, .{ .x = 10, .y = 10 }), .{}));
    try t.expectError(error.InvalidTolerance, combine(t.allocator, a, empty, .unite, .{ .tolerance = 0 }));
    try t.expectError(error.InvalidWidth, stroke(t.allocator, open, -1, .{}));
    try t.expectError(error.PrecisionRange, stroke(t.allocator, open, @bitCast(@as(u64, 1)), .{}));
    try t.expectError(error.InvalidOffset, offset(t.allocator, a, std.math.inf(f64), .{}));
    try t.expectError(error.InvalidMiterLimit, offset(t.allocator, a, 1, .{ .miter_limit = 0 }));
    try t.expectError(error.InvalidRectangle, clipRegion(t.allocator, a, .{ .min = .{ .x = 2, .y = 0 }, .max = .{ .x = 1, .y = 1 } }, .{}));
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, a, a, .unite, .{ .max_segments = 6 }));
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, a, a, .unite, .{ .max_vertices = 6 }));
    var huge = try testRectangle(t.allocator, 1e16, 0, 100, 100);
    defer huge.deinit();
    try t.expectError(error.PrecisionRange, offset(t.allocator, huge, 0, .{}));
    var horizontal = try testRectangle(t.allocator, 0, 4, 10, 2);
    defer horizontal.deinit();
    var vertical = try testRectangle(t.allocator, 4, 0, 2, 10);
    defer vertical.deinit();
    try t.expectError(error.GeometryWorkLimit, combine(t.allocator, horizontal, vertical, .unite, .{ .max_vertices = 8 }));
}

fn allocationExercise(allocator: Allocator) !void {
    var a = try testRectangle(allocator, 0, 0, 10, 10);
    defer a.deinit();
    var b = try testRectangle(allocator, 3, 3, 10, 10);
    defer b.deinit();
    var united = try combine(allocator, a, b, .unite, .{});
    defer united.deinit();
    var expanded = try offset(allocator, united, 1, .{});
    defer expanded.deinit();
    var outline = try stroke(allocator, a, 2, .{});
    defer outline.deinit();
    var clipped = try clipRegion(allocator, expanded, .fromPoints(.zero, .{ .x = 10, .y = 10 }), .{});
    defer clipped.deinit();
    var lines = try clipLines(allocator, a, .fromPoints(.zero, .{ .x = 5, .y = 5 }), .{});
    defer lines.deinit();
}

test "allocation failures release prepared paths native results and copied contours" {
    // In-place arena/list growth can change the allocation count with the
    // backing allocator's address layout. Force growth to allocate and copy,
    // so every allocation is a deterministic failure-injection point.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}

test "source segment limits do not count derived stroke and offset boundaries again" {
    const t = std.testing;
    var rectangle = try testRectangle(t.allocator, 0, 0, 10, 10);
    defer rectangle.deinit();
    const options: api.Options = .{ .max_segments = 4, .join = .miter };
    var outline = try stroke(t.allocator, rectangle, 2, options);
    defer outline.deinit();
    try t.expectApproxEqAbs(@as(f64, 80), area(outline), 1e-7);
    var expanded = try offset(t.allocator, rectangle, 2, options);
    defer expanded.deinit();
    try t.expectApproxEqAbs(@as(f64, 196), area(expanded), 1e-7);
    try t.expectError(error.GeometryWorkLimit, stroke(t.allocator, rectangle, 2, .{ .max_segments = 3 }));
    try t.expectError(error.GeometryWorkLimit, stroke(t.allocator, rectangle, 0, .{ .max_vertices = 3 }));
}
