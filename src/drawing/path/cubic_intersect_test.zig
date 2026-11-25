//! Tests of line/cubic and cubic/cubic intersection: tangency, endpoint contacts, near-tangent crossings and coincidence.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const cubic_intersect = @import("cubic_intersect.zig");
const intersectLineCubic = cubic_intersect.intersectLineCubic;
const intersectCubics = cubic_intersect.intersectCubics;

test "line-cubic intersections include tangency and endpoints once" {
    const allocator = std.testing.allocator;
    const c: Cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 2.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } };
    const hits = try intersectLineCubic(allocator, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, c);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].b, 1e-10);
    const endpoints = try intersectLineCubic(allocator, .{ .x = -1, .y = 1 }, .{ .x = 2, .y = 1 }, c);
    defer allocator.free(endpoints);
    try std.testing.expectEqual(@as(usize, 2), endpoints.len);
    try std.testing.expectError(error.DegenerateLine, intersectLineCubic(allocator, .zero, .zero, c));
    try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.zero, .{ .x = 1, .y = 0 })));
    const isolated = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 0.5, .y = 0 }, .{ .x = 0.5, .y = 0 }));
    defer allocator.free(isolated);
    try std.testing.expectEqual(@as(usize, 1), isolated.len);
    const disjoint = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, Cubic.line(.{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }));
    defer allocator.free(disjoint);
    try std.testing.expectEqual(@as(usize, 0), disjoint.len);
}

test "collinear endpoint contacts are finite and overlap still diagnoses coincidence" {
    const allocator = std.testing.allocator;
    const adjoining = Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 });
    const hits = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, adjoining);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(f64, 1), hits[0].a);
    try std.testing.expectEqual(@as(f64, 0), hits[0].b);
    const backwards = try intersectLineCubic(allocator, .{ .x = 1, .y = 0 }, .zero, adjoining);
    defer allocator.free(backwards);
    try std.testing.expectEqual(@as(usize, 1), backwards.len);
    try std.testing.expectEqual(@as(f64, 0), backwards[0].a);
    const touch: Cubic = .{ .p0 = .{ .x = 2, .y = 0 }, .p1 = .{ .x = 2.0 / 3.0, .y = 0 }, .p2 = .{ .x = 2.0 / 3.0, .y = 0 }, .p3 = .{ .x = 2, .y = 0 } };
    const interior = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, touch);
    defer allocator.free(interior);
    try std.testing.expectEqual(@as(usize, 1), interior.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), interior[0].b, 1e-12);
    try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, .zero, .{ .x = 1.5, .y = 0 }, adjoining));
    const point = Cubic.line(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 });
    const points = try intersectCubics(allocator, point, point, 1e-12);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    for ([_]Point{ .{ .x = 3, .y = 4 }, .{ .x = 4, .y = 3 }, .{ .x = -3, .y = 4 }, .{ .x = 3, .y = -4 } }) |direction| {
        const start: Point = .{ .x = 7, .y = -11 };
        const end = start.add(direction);
        try std.testing.expectError(error.CoincidentCurves, intersectLineCubic(allocator, start, end, Cubic.line(start, end)));
        const contact = try intersectLineCubic(allocator, start, end, Cubic.line(end, end.add(direction)));
        defer allocator.free(contact);
        try std.testing.expectEqual(@as(usize, 1), contact.len);
        try std.testing.expectEqual(@as(f64, 1), contact[0].a);
        try std.testing.expectEqual(@as(f64, 0), contact[0].b);
    }
}

test "near tangent crossings are distinct and linear shortcuts enforce spatial residuals" {
    const allocator = std.testing.allocator;
    const line = Cubic.line(.zero, .{ .x = 1, .y = 0 });
    for ([_]f64{ 1, 1e6 }) |scale| {
        const e = 1e-15 * scale;
        const curve: Cubic = .{
            .p0 = .{ .x = 0, .y = 0.25 * scale - e },
            .p1 = .{ .x = 1.0 / 3.0, .y = -scale / 12 - e },
            .p2 = .{ .x = 2.0 / 3.0, .y = -scale / 12 - e },
            .p3 = .{ .x = 1, .y = 0.25 * scale - e },
        };
        const raw = try intersectLineCubic(allocator, .zero, .{ .x = 1, .y = 0 }, curve);
        defer allocator.free(raw);
        try std.testing.expectEqual(@as(usize, 2), raw.len);
        try std.testing.expect(raw[0].b < 0.5 and raw[1].b > 0.5);
        const limit = 1e-12;
        const hits = try intersectCubics(allocator, line, curve, limit);
        defer allocator.free(hits);
        const swapped = try intersectCubics(allocator, curve, line, limit);
        defer allocator.free(swapped);
        try std.testing.expectEqual(@as(usize, 2), hits.len);
        try std.testing.expectEqual(hits.len, swapped.len);
        for (hits, swapped) |hit, other| {
            try std.testing.expect(line.at(hit.a).distance(curve.at(hit.b)) <= limit);
            try std.testing.expect(curve.at(other.a).distance(line.at(other.b)) <= limit);
        }
    }
    // A tiny but nonzero line is not a point; do not square its length into 0.
    const tiny = try intersectLineCubic(allocator, .zero, .{ .x = 1e-250, .y = 0 }, Cubic.line(.{ .x = 1e-250, .y = 0 }, .{ .x = 2e-250, .y = 0 }));
    defer allocator.free(tiny);
    try std.testing.expectEqual(@as(usize, 1), tiny.len);
}

test "bounded cubic intersection refinement and coincident diagnostics" {
    const allocator = std.testing.allocator;
    const a = Cubic.line(.{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 });
    const b: Cubic = .{ .p0 = .{ .x = 0, .y = 10 }, .p1 = .{ .x = 4, .y = 10 }, .p2 = .{ .x = 6, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    const hits = try intersectCubics(allocator, a, b, 1e-8);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].a, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].b, 1e-8);
    try std.testing.expectError(error.CoincidentCurves, intersectCubics(allocator, b, b.reversed(), 1e-8));
    const tangent: Cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1.0 / 3.0, .y = -1.0 / 3.0 }, .p2 = .{ .x = 2.0 / 3.0, .y = -1.0 / 3.0 }, .p3 = .{ .x = 1, .y = 1 } };
    const touching = try intersectCubics(allocator, tangent, Cubic.line(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }), 1e-8);
    defer allocator.free(touching);
    try std.testing.expectEqual(@as(usize, 1), touching.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), touching[0].a, 2e-5);
    const lower = tangent.transformed(g.Transform.scaling(1, -1));
    const curved_touch = try intersectCubics(allocator, tangent, lower, 1e-8);
    defer allocator.free(curved_touch);
    try std.testing.expectEqual(@as(usize, 1), curved_touch.len);
}
