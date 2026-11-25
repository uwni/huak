//! Tests of whole-path intersections and their details.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");
const intersect = @import("intersect.zig");
const cubic_intersect = @import("cubic_intersect.zig");
const Intersection = cubic_intersect.Intersection;

test "whole path intersections deduplicate shared vertices and respect caller tolerance" {
    var first = Path.init(std.testing.allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.zero);
    try first.lineTo(.{ .x = 10, .y = 0 });
    var other = Path.init(std.testing.allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 0, .y = -10 });
    try other.lineTo(.{ .x = 0, .y = 10 });
    const shared = try intersect.intersections(first, std.testing.allocator, other, 1e-9);
    defer std.testing.allocator.free(shared);
    try std.testing.expectEqual(@as(usize, 1), shared.len);
    try std.testing.expect(g.tolerance.points(.zero, shared[0]));
    var nearby = Path.init(std.testing.allocator);
    defer nearby.deinit();
    try nearby.moveTo(.{ .x = -1, .y = 0 });
    try nearby.lineTo(.{ .x = 1, .y = 0 });
    try nearby.moveTo(.{ .x = -1, .y = 5e-8 });
    try nearby.lineTo(.{ .x = 1, .y = 5e-8 });
    const separate = try intersect.intersections(nearby, std.testing.allocator, other, 1e-9);
    defer std.testing.allocator.free(separate);
    try std.testing.expectEqual(@as(usize, 2), separate.len);
    try std.testing.expectApproxEqAbs(@as(f64, 5e-8), separate[1].y, 1e-12);
    const merged = try intersect.intersections(nearby, std.testing.allocator, other, 1e-6);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectError(error.NonFinite, intersect.intersections(first, std.testing.allocator, other, 0));
    try std.testing.expectError(error.CoincidentCurves, intersect.intersections(first, std.testing.allocator, first, 1e-9));
    var partly_coincident = Path.init(std.testing.allocator);
    defer partly_coincident.deinit();
    try partly_coincident.moveTo(.{ .x = -1, .y = 0 });
    try partly_coincident.lineTo(.{ .x = 1, .y = 0 });
    try partly_coincident.moveTo(.{ .x = 0, .y = -10 });
    try partly_coincident.lineTo(.{ .x = 0, .y = 10 });
    // The first pair already produced an owned hit before a later pair reports
    // coincidence. The partially accumulated output must also be released.
    try std.testing.expectError(error.CoincidentCurves, intersect.intersections(partly_coincident, std.testing.allocator, other, 1e-9));
}

test "whole path intersections include cubic roots and nonzero closing segments" {
    var triangle = Path.init(std.testing.allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 10, .y = 10 });
    try triangle.close();
    var vertical = Path.init(std.testing.allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 5, .y = -1 });
    try vertical.lineTo(.{ .x = 5, .y = 11 });
    const closed_hits = try intersect.intersections(triangle, std.testing.allocator, vertical, 1e-9);
    defer std.testing.allocator.free(closed_hits);
    try std.testing.expectEqual(@as(usize, 2), closed_hits.len);
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 0 }, closed_hits[0]));
    try std.testing.expect(g.tolerance.points(.{ .x = 5, .y = 5 }, closed_hits[1]));
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = 2, .y = -3 }, .{ .x = 3, .y = 0 });
    var horizontal = Path.init(std.testing.allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -1, .y = 0 });
    try horizontal.lineTo(.{ .x = 4, .y = 0 });
    const roots = try intersect.intersections(curve, std.testing.allocator, horizontal, 1e-9);
    defer std.testing.allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len);
}

fn exerciseWholeIntersections(allocator: std.mem.Allocator) !void {
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    try first.moveTo(.{ .x = -1, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var other = Path.init(allocator);
    defer other.deinit();
    try other.moveTo(.{ .x = 0, .y = -1 });
    try other.lineTo(.{ .x = 0, .y = 3 });
    const hits = try intersect.intersections(first, allocator, other, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "whole path intersection allocation failures release temporary hits and output points" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseWholeIntersections, .{});
}

test "whole path intersection details retain cubic root parameters and shared endpoint identity" {
    const allocator = std.testing.allocator;
    var curve = Path.init(allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 3 }, .{ .x = 2, .y = -3 }, .{ .x = 3, .y = 0 });
    var horizontal = Path.init(allocator);
    defer horizontal.deinit();
    try horizontal.moveTo(.{ .x = -1, .y = 0 });
    try horizontal.lineTo(.{ .x = 4, .y = 0 });
    const roots = try intersect.intersectionDetails(curve, allocator, horizontal, 1e-9);
    defer allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len);
    for (roots, [_]f64{ 0, 0.5, 1 }, [_]f64{ 0.2, 0.5, 0.8 }) |hit, a, b| {
        try std.testing.expectApproxEqAbs(a, hit.a, 1e-12);
        try std.testing.expectApproxEqAbs(b, hit.b, 1e-12);
        try std.testing.expect((try curve.pointAt(hit.a)).distance(hit.point) <= 1e-9);
        try std.testing.expect((try horizontal.pointAt(hit.b)).distance(hit.point) <= 1e-9);
    }
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.zero);
    try first.lineTo(.{ .x = 10, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -10 });
    try second.lineTo(.zero);
    try second.lineTo(.{ .x = 0, .y = 10 });
    const shared = try intersect.intersectionDetails(first, allocator, second, 1e-9);
    defer allocator.free(shared);
    try std.testing.expectEqual(@as(usize, 1), shared.len);
    try std.testing.expectEqualDeep(Intersection{ .point = .zero, .a = 1, .b = 1 }, shared[0]);
}

test "whole path intersection details preserve branches at one spatial coordinate" {
    const allocator = std.testing.allocator;
    var crossed = Path.init(allocator);
    defer crossed.deinit();
    try crossed.moveTo(.{ .x = 50, .y = 50 }); // Empty contour consumes no time.
    try crossed.moveTo(.{ .x = -2, .y = -2 });
    try crossed.lineTo(.{ .x = 2, .y = 2 });
    try crossed.moveTo(.{ .x = -2, .y = 2 });
    try crossed.lineTo(.{ .x = 2, .y = -2 });
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 0, .y = -3 });
    try vertical.lineTo(.{ .x = 0, .y = 3 });
    const hits = try intersect.intersectionDetails(crossed, allocator, vertical, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    for (hits, [_]f64{ 0.5, 1.5 }) |hit, time| {
        try std.testing.expectApproxEqAbs(time, hit.a, 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), hit.b, 1e-12);
        try std.testing.expect(hit.point.distance(.zero) <= 1e-9);
    }
    const reversed = try intersect.intersectionDetails(vertical, allocator, crossed, 1e-9);
    defer allocator.free(reversed);
    try std.testing.expectEqual(@as(usize, 2), reversed.len);
    try std.testing.expect(reversed[0].b < reversed[1].b);
    const points = try intersect.intersections(crossed, allocator, vertical, 1e-9);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
}

test "whole path intersection details count closing edges and preserve closed seam times" {
    const allocator = std.testing.allocator;
    var triangle = Path.init(allocator);
    defer triangle.deinit();
    try triangle.moveTo(.zero);
    try triangle.lineTo(.{ .x = 10, .y = 0 });
    try triangle.lineTo(.{ .x = 10, .y = 10 });
    try triangle.close();
    var vertical = Path.init(allocator);
    defer vertical.deinit();
    try vertical.moveTo(.{ .x = 5, .y = -1 });
    try vertical.lineTo(.{ .x = 5, .y = 11 });
    const hits = try intersect.intersectionDetails(triangle, allocator, vertical, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), hits[0].a, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), hits[1].a, 1e-12);
    var seam = Path.init(allocator);
    defer seam.deinit();
    try seam.moveTo(.{ .x = -1, .y = 1 });
    try seam.lineTo(.{ .x = 1, .y = -1 });
    const endpoints = try intersect.intersectionDetails(triangle, allocator, seam, 1e-9);
    defer allocator.free(endpoints);
    try std.testing.expectEqual(@as(usize, 2), endpoints.len);
    try std.testing.expectEqual(@as(f64, 0), endpoints[0].a);
    try std.testing.expectEqual(@as(f64, 3), endpoints[1].a);
    // Explicitly returning to the start makes CLOSE a zero-time marker.
    var returned = Path.init(allocator);
    defer returned.deinit();
    try returned.moveTo(.zero);
    try returned.lineTo(.{ .x = 10, .y = 0 });
    try returned.lineTo(.zero);
    try returned.close();
    const zero_close = try intersect.intersectionDetails(returned, allocator, seam, 1e-9);
    defer allocator.free(zero_close);
    try std.testing.expectEqual(@as(usize, 2), zero_close.len);
    try std.testing.expectEqual(@as(f64, 0), zero_close[0].a);
    try std.testing.expectEqual(@as(f64, 2), zero_close[1].a);
}

test "whole path intersection details do not merge parameters by spatial tolerance" {
    const allocator = std.testing.allocator;
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -10, .y = 0 });
    try first.lineTo(.{ .x = 10, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = -10, .y = -3 });
    try second.cubicTo(.{ .x = -10, .y = 3 }, .{ .x = 10, .y = 3 }, .{ .x = 10, .y = -3 });
    const hits = try intersect.intersectionDetails(first, allocator, second, 2);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(hits[0].a < hits[1].a and hits[0].b < hits[1].b);
    try std.testing.expect(hits[1].a - hits[0].a < 2 and hits[1].b - hits[0].b < 2);
    try std.testing.expect(hits[0].point.distance(hits[1].point) > 2);
}

test "whole path intersection details retain disconnected endpoints at identical times" {
    const allocator = std.testing.allocator;
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.zero);
    try first.moveTo(.{ .x = 0, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.zero);
    try second.moveTo(.{ .x = 0, .y = 2 });
    try second.lineTo(.{ .x = 0, .y = 3 });
    const hits = try intersect.intersectionDetails(first, allocator, second, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    for (hits) |hit| {
        try std.testing.expectEqual(@as(f64, 1), hit.a);
        try std.testing.expectEqual(@as(f64, 1), hit.b);
    }
    try std.testing.expectEqual(@as(f64, 0), hits[0].point.y);
    try std.testing.expectEqual(@as(f64, 2), hits[1].point.y);
}

fn exerciseWholeIntersectionDetails(allocator: std.mem.Allocator) !void {
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    try first.moveTo(.{ .x = -1, .y = 2 });
    try first.lineTo(.{ .x = 1, .y = 2 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.{ .x = 0, .y = 3 });
    const hits = try intersect.intersectionDetails(first, allocator, second, 1e-9);
    defer allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "whole path intersection details preserve diagnostics and release every failed allocation" {
    const allocator = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(allocator, exerciseWholeIntersectionDetails, .{});
    var first = Path.init(allocator);
    defer first.deinit();
    try first.moveTo(.{ .x = -1, .y = 0 });
    try first.lineTo(.{ .x = 1, .y = 0 });
    var second = Path.init(allocator);
    defer second.deinit();
    try second.moveTo(.{ .x = 0, .y = -1 });
    try second.lineTo(.{ .x = 0, .y = 1 });
    try first.moveTo(.{ .x = 0, .y = -1 });
    try first.lineTo(.{ .x = 0, .y = 1 });
    try std.testing.expectError(error.CoincidentCurves, intersect.intersectionDetails(first, allocator, second, 1e-9));
    try std.testing.expectError(error.NonFinite, intersect.intersectionDetails(first, allocator, second, 0));
    try std.testing.expectError(error.NonFinite, intersect.intersectionDetails(first, allocator, second, std.math.nan(f64)));
    var invalid = Path.init(allocator);
    defer invalid.deinit();
    try invalid.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, intersect.intersectionDetails(invalid, allocator, second, 1e-9));
}
