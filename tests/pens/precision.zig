//! Precision regressions: smooth knots at origin 1e16, and all-corner cycles reindexed.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const g = core.geometry;
const Path = core.Path;
const pens = core.pen;
const Point = g.Point;
const Cubic = g.Cubic;
const harness = @import("harness.zig");

const PRECISION_QUARTERS = [_]Cubic{
    .{ .p0 = .{ .x = 100, .y = 44 }, .p1 = .{ .x = 100, .y = 54 }, .p2 = .{ .x = 90, .y = 64 }, .p3 = .{ .x = 80, .y = 64 } },
    .{ .p0 = .{ .x = 80, .y = 64 }, .p1 = .{ .x = 70, .y = 64 }, .p2 = .{ .x = 60, .y = 54 }, .p3 = .{ .x = 60, .y = 44 } },
    .{ .p0 = .{ .x = 60, .y = 44 }, .p1 = .{ .x = 60, .y = 34 }, .p2 = .{ .x = 70, .y = 24 }, .p3 = .{ .x = 80, .y = 24 } },
    .{ .p0 = .{ .x = 80, .y = 24 }, .p1 = .{ .x = 90, .y = 24 }, .p2 = .{ .x = 100, .y = 34 }, .p3 = .{ .x = 100, .y = 44 } },
};

fn precisionLoop(origin: Point, start: usize) !Path {
    var path = Path.init(t.allocator);
    errdefer path.deinit();
    try path.moveTo(PRECISION_QUARTERS[start].p0.add(origin));
    for (0..PRECISION_QUARTERS.len) |offset| {
        const curve = PRECISION_QUARTERS[(start + offset) % PRECISION_QUARTERS.len];
        try path.cubicTo(curve.p1.add(origin), curve.p2.add(origin), curve.p3.add(origin));
    }
    try path.close();
    return path;
}

fn normalizePrimitives(path: *Path, origin: Point) void {
    // Normalize the actual representation first. Converting a world-space
    // line into interpolated cubic controls can itself introduce fake error.
    for (path.segments.items) |*segment| switch (segment.*) {
        .move => |point| segment.move = point.sub(origin),
        .line => |point| segment.line = point.sub(origin),
        .cubic => |curve| segment.cubic = .{ .c1 = curve.c1.sub(origin), .c2 = curve.c2.sub(origin), .end = curve.end.sub(origin) },
        .close => {},
    };
    if (path.current) |point| path.current = point.sub(origin);
    if (path.start) |point| path.start = point.sub(origin);
}

test "existing smooth knots retain complete controls and coverage at origin 1e16" {
    const square = [_]Point{ .{ .x = -4, .y = -4 }, .{ .x = 4, .y = -4 }, .{ .x = 4, .y = 4 }, .{ .x = -4, .y = 4 } };
    var source = try precisionLoop(.zero, 0);
    defer source.deinit();
    var baseline = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, source, .{ .tolerance = 1e-3 });
    defer baseline.deinit();
    const baseline_curves = try harness.curves(t.allocator, baseline);
    defer t.allocator.free(baseline_curves);
    const origin: Point = .{ .x = 1e16, .y = 1e16 };
    for (0..PRECISION_QUARTERS.len) |start| {
        var unit_path = try precisionLoop(.zero, start);
        defer unit_path.deinit();
        var unit = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, unit_path, .{ .tolerance = 1e-3 });
        defer unit.deinit();
        var moved_path = try precisionLoop(origin, start);
        defer moved_path.deinit();
        var moved = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, moved_path, .{ .tolerance = 1e-3 });
        defer moved.deinit();
        normalizePrimitives(&moved, origin);
        try t.expectEqualDeep(unit.segments.items, moved.segments.items);
        var cubic_count: usize = 0;
        for (moved.segments.items) |segment| if (segment == .cubic) {
            cubic_count += 1;
        };
        // Four original quarters, once on each side: no new subdivision.
        try t.expectEqual(@as(usize, 8), cubic_count);
        const actual_curves = try harness.curves(t.allocator, moved);
        defer t.allocator.free(actual_curves);
        _ = try harness.compareCurves(baseline_curves, actual_curves, 0);
        try t.expectEqual(@as(usize, 0), try harness.coverageSampleMismatches(baseline_curves, actual_curves));
        try t.expectEqual(@as(i32, 0), try harness.winding(actual_curves, .{ .x = 80.37, .y = 44.29 }));
        try t.expect(try harness.winding(actual_curves, .{ .x = 102.37, .y = 44.29 }) != 0);
    }
}

test "all-corner cycles retain every join when reindexed" {
    const diamond = [_]Point{ .{ .x = 0, .y = -4 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 4 }, .{ .x = -4, .y = 0 } };
    const points = [_]Point{ .{ .x = 45, .y = 45 }, .{ .x = 125, .y = 35 }, .{ .x = 125, .y = 55 } };
    for ([_]struct { join: pens.Join, limit: f64, min_x: f64 }{
        .{ .join = .round, .limit = 12, .min_x = 41 },
        .{ .join = .bevel, .limit = 12, .min_x = 45 },
        .{ .join = .miter, .limit = 12, .min_x = 13 },
        .{ .join = .miter, .limit = 4, .min_x = 45 },
    }) |case| {
        var baseline: ?Path = null;
        defer if (baseline) |*path| path.deinit();
        for (0..points.len) |start| {
            var source = Path.init(t.allocator);
            defer source.deinit();
            try source.moveTo(points[start]);
            for (1..points.len) |offset| try source.lineTo(points[(start + offset) % points.len]);
            try source.close();
            var result = try pens.strokeOutline(t.allocator, .{ .polygon = &diamond }, source, .{ .join = case.join, .miter_limit = case.limit });
            defer result.deinit();
            try t.expectApproxEqAbs(case.min_x, result.bounds().?.min.x, 1e-10);
            if (baseline) |first| {
                const a = try harness.curves(t.allocator, first);
                defer t.allocator.free(a);
                const b = try harness.curves(t.allocator, result);
                defer t.allocator.free(b);
                try t.expect(try harness.visibleSampledDeviation(a, b) < harness.geometry_tolerance);
                try t.expectEqual(@as(usize, 0), try harness.coverageSampleMismatches(a, b));
            } else baseline = try result.clone(t.allocator);
        }
    }
}
