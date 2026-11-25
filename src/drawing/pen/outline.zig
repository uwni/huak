//! Convex-nib outline adapter. Polygon envelopes retain original cubic
//! segments; only explicit ellipse outlines approximate the nib perimeter.
//! Native nonsingular ellipse rendering remains a backend stroke operation.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const nibs = @import("nib.zig");
const envelope = @import("envelope.zig");
const Allocator = std.mem.Allocator;

pub const Options = envelope.Options;
pub const Error = envelope.Error || nibs.Error || error{ InvalidTolerance, StrokeWorkLimit, PrecisionRange, InvalidStroke };

fn appendSupports(allocator: Allocator, points: *std.ArrayList(g.Point), nib: nibs.Nib, tangent: g.Point, limit: usize) Error!void {
    if (tangent.x == 0 and tangent.y == 0) return;
    if (points.items.len > limit -| 2) return error.StrokeWorkLimit;
    const normal = g.Point{ .x = -tangent.y, .y = tangent.x };
    try points.append(allocator, try nib.support(normal));
    try points.append(allocator, try nib.support(normal.scale(-1)));
}
fn addExactSupports(allocator: Allocator, points: *std.ArrayList(g.Point), nib: nibs.Nib, path: Path, limit: usize) Error!void {
    var current: ?g.Point = null;
    var start: ?g.Point = null;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            current = point;
            start = point;
        },
        .line => |point| {
            const previous = current orelse return error.InvalidPath;
            try appendSupports(allocator, points, nib, point.sub(previous), limit);
            current = point;
        },
        .cubic => |curve| {
            const previous = current orelse return error.InvalidPath;
            const first = if (curve.c1.x != previous.x or curve.c1.y != previous.y) curve.c1.sub(previous) else if (curve.c2.x != previous.x or curve.c2.y != previous.y) curve.c2.sub(previous) else curve.end.sub(previous);
            const last = if (curve.c2.x != curve.end.x or curve.c2.y != curve.end.y) curve.end.sub(curve.c2) else if (curve.c1.x != curve.end.x or curve.c1.y != curve.end.y) curve.end.sub(curve.c1) else curve.end.sub(previous);
            try appendSupports(allocator, points, nib, first, limit);
            try appendSupports(allocator, points, nib, last, limit);
            current = curve.end;
        },
        .close => {
            const previous = current orelse return error.InvalidPath;
            try appendSupports(allocator, points, nib, start.?.sub(previous), limit);
            current = null;
            start = null;
        },
    };
}
pub fn meshEllipse(allocator: Allocator, transform: g.Transform, path: Path, options: Options) Error![]const g.Point {
    const nib: nibs.Nib = .{ .ellipse = transform };
    try nib.validate();
    // The Frobenius norm bounds the largest singular value of A. The
    // transformed circle's chord error is therefore bounded by this
    // radius times (1-cos(half_step)), including singular ellipses.
    const radius = std.math.hypot(std.math.hypot(transform.a * 0.5, transform.b * 0.5), std.math.hypot(transform.c * 0.5, transform.d * 0.5));
    if (!std.math.isFinite(radius)) return error.NonFinite;
    if (radius == 0) return allocator.dupe(g.Point, &.{.{ .x = transform.e, .y = transform.f }});
    const ratio = options.tolerance * 0.25 / radius;
    const half_step = std.math.acos(1 - @min(@as(f64, 1), ratio));
    if (half_step == 0 or !std.math.isFinite(half_step)) return error.StrokeWorkLimit;
    const count_float = @max(@as(f64, 4), @ceil(std.math.pi / half_step));
    if (count_float > @as(f64, @floatFromInt(options.max_vertices)) or count_float > 65536) return error.StrokeWorkLimit;
    const count: usize = @intFromFloat(count_float);
    var points: std.ArrayList(g.Point) = .empty;
    defer points.deinit(allocator);
    try points.ensureTotalCapacity(allocator, count);
    for (0..count) |index| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count));
        const point = transform.apply(.{ .x = @cos(angle) * 0.5, .y = @sin(angle) * 0.5 });
        if (!point.isFinite()) return error.NonFinite;
        points.appendAssumeCapacity(point);
    }
    if (options.cap != .round or options.join != .round) try addExactSupports(allocator, &points, nib, path, options.max_vertices);
    return nibs.convexHullScratch(allocator, points.items);
}

pub fn validateOptions(options: Options) Error!void {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.max_segments == 0 or options.max_vertices < 3 or options.max_depth > 64) return error.StrokeWorkLimit;
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidStroke;
}

/// Polygon vertices stay borrowed. Ellipse vertices belong to allocator and
/// must be freed after the tracing; one mesh can serve every source interval.
pub fn nibVertices(allocator: Allocator, nib: nibs.Nib, path: Path, options: Options) Error![]const g.Point {
    return switch (nib) {
        .polygon => |vertices| vertices,
        .ellipse => |transform| meshEllipse(allocator, transform, path, options),
    };
}

/// Returns a closed compound path for one nonzero-rule fill. Closed
/// centerlines connect both directed sides at an internal construction cut,
/// including the interior boundary and the cut's pen sweep.
/// Like MetaPost's envelope this is a curve tracing, not a Boolean-normalized
/// polygon: self intersections and retraced internal edges can remain.
/// The result owns its storage; the centerline and nib remain borrowed.
pub fn strokeOutline(allocator: Allocator, nib: nibs.Nib, path: Path, options: Options) Error!Path {
    try validateOptions(options);
    const vertices = try nibVertices(allocator, nib, path, options);
    defer if (nib == .ellipse) allocator.free(vertices);
    return envelope.stroke(allocator, vertices, path, options);
}

test "square nib envelope retains straight stroke area and one open contour" {
    var centerline = Path.init(std.testing.allocator);
    defer centerline.deinit();
    try centerline.moveTo(.zero);
    try centerline.lineTo(.{ .x = 10, .y = 0 });
    try centerline.lineTo(.{ .x = 10, .y = 10 });
    var result = try strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{});
    defer result.deinit();
    const box = result.bounds().?;
    try std.testing.expectEqual(@as(f64, -0.5), box.min.x);
    try std.testing.expectEqual(@as(f64, 10.5), box.max.y);
    try std.testing.expectApproxEqAbs(@as(f64, 21), result.signedArea(), 1e-9);
    var moves: usize = 0;
    for (result.segments.items) |segment| if (segment == .move) {
        moves += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), moves);
}

test "closed swept path retains a clockwise hole with no filled interior" {
    var centerline = Path.init(std.testing.allocator);
    defer centerline.deinit();
    try centerline.moveTo(.zero);
    try centerline.lineTo(.{ .x = 10, .y = 0 });
    try centerline.lineTo(.{ .x = 10, .y = 10 });
    try centerline.lineTo(.{ .x = 0, .y = 10 });
    try centerline.close();
    var result = try strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{});
    defer result.deinit();
    // The construction cut joins both directed sides. Integrate the tracing
    // with nonzero winding, not by counting overlapping signed areas twice.
    var empty = Path.init(std.testing.allocator);
    defer empty.deinit();
    var region = try @import("../region/root.zig").combine(std.testing.allocator, result, empty, .unite, .{ .tolerance = 1e-8 });
    defer region.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 40), region.signedArea(), 1e-9);
    var contours: usize = 0;
    for (result.segments.items) |segment| if (segment == .move) {
        contours += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), contours);
    // A line through the hole intersects exactly four true boundary edges.
    var across = try rectangleTestLine(std.testing.allocator);
    defer across.deinit();
    const intersections = try Path.intersect.intersections(result, std.testing.allocator, across, 1e-8);
    defer std.testing.allocator.free(intersections);
    try std.testing.expectEqual(@as(usize, 4), intersections.len);
}

fn rectangleTestLine(allocator: Allocator) !Path {
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.moveTo(.{ .x = -2, .y = 5 });
    try path.lineTo(.{ .x = 12, .y = 5 });
    return path;
}

test "cubic centerlines use explicit tolerance and preserve curved bounds" {
    var centerline = Path.init(std.testing.allocator);
    defer centerline.deinit();
    try centerline.moveTo(.zero);
    try centerline.cubicTo(.{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 });
    var result = try strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{ .tolerance = 0.001 });
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 8), result.bounds().?.max.y, 0.001);
    try std.testing.expectError(error.StrokeWorkLimit, strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{ .max_depth = 0 }));
}

test "singular line nibs sweep nonzero area without matrix inversion" {
    const nib: nibs.Nib = .{ .ellipse = g.Transform.scaling(4, 0) };
    var centerline = Path.init(std.testing.allocator);
    defer centerline.deinit();
    try centerline.moveTo(.zero);
    try centerline.lineTo(.{ .x = 0, .y = 8 });
    var result = try strokeOutline(std.testing.allocator, nib, centerline, .{});
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 32), result.signedArea(), 0.004);
    var empty = try strokeOutline(std.testing.allocator, .{ .ellipse = g.Transform.scaling(0, 0) }, centerline, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.segments.items.len);
}

test "invalid tolerance and unrepresentable offsets fail while thin outlines retain precision" {
    var centerline = Path.init(std.testing.allocator);
    defer centerline.deinit();
    try centerline.moveTo(.{ .x = 1e20, .y = 1e20 });
    try std.testing.expectError(error.PrecisionRange, strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{}));
    try std.testing.expectError(error.InvalidTolerance, strokeOutline(std.testing.allocator, nibs.Nib.square(), centerline, .{ .tolerance = 0 }));
    var thin = try nibs.Nib.square().transformed(std.testing.allocator, g.Transform.scaling(1, 1e-8));
    defer thin.deinit();
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var narrow = try strokeOutline(std.testing.allocator, thin.nib, line, .{});
    defer narrow.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1e-8), narrow.bounds().?.height(), 1e-20);
    try std.testing.expectApproxEqAbs(@as(f64, 11e-8), narrow.signedArea(), 1e-19);
}

fn allocationExercise(allocator: Allocator) !void {
    var centerline = Path.init(allocator);
    defer centerline.deinit();
    try centerline.moveTo(.zero);
    try centerline.lineTo(.{ .x = 2, .y = 0 });
    try centerline.lineTo(.{ .x = 2, .y = 2 });
    var result = try strokeOutline(allocator, nibs.Nib.square(), centerline, .{});
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 5), result.signedArea(), 1e-9);
}

fn styledAllocationExercise(allocator: Allocator) !void {
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 2, .y = 0 });
    try path.lineTo(.{ .x = 2, .y = 2 });
    var result = try strokeOutline(allocator, nibs.Nib.square(), path, .{ .cap = .square, .join = .miter });
    defer result.deinit();
    try std.testing.expect(result.segments.items.len != 0);
}
test "styled envelope allocation failures release all geometry" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), styledAllocationExercise, .{});
}

test "all failed stroke outline allocations release temporary and result geometry" {
    try allocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}

test "polygon outlines borrow nib vertices and retain validation order" {
    var vertices = [_]g.Point{ .{ .x = -1, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = -1, .y = 1 } };
    const snapshot = vertices;
    var empty = Path.init(std.testing.allocator);
    defer empty.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var outline = try strokeOutline(failing.allocator(), .{ .polygon = &vertices }, empty, .{});
    defer outline.deinit();
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), outline.segments.items.len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&snapshot), std.mem.asBytes(&vertices));
    try std.testing.expectError(error.StrokeWorkLimit, strokeOutline(std.testing.allocator, .{ .polygon = &vertices }, empty, .{ .max_vertices = 3 }));
    vertices[0].x = std.math.nan(f64);
    try std.testing.expectError(error.NonFinite, strokeOutline(std.testing.allocator, .{ .polygon = &vertices }, empty, .{ .max_vertices = 3 }));
    try std.testing.expectError(error.InvalidTolerance, strokeOutline(std.testing.allocator, .{ .polygon = &vertices }, empty, .{ .tolerance = 0 }));
}

test {
    _ = @import("outline/styles_test.zig");
}
