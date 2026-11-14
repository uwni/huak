//! Ordered line/Hobby paths. Straight joins end adjacent smooth spans with
//! default curl, matching MetaPost's `-- = {curl 1}..{curl 1}` definition.
//! Geometry only: callers supply points and join kinds, never source tokens.
const std = @import("std");
const geometry = @import("../geometry.zig");
const Path = @import("Path.zig");
const hobby = @import("hobby.zig");

pub const Join = enum { straight, smooth };
pub const Options = struct {
    closed: bool = false,
    max_segments: usize = 65536,
};
pub const Error = hobby.Error || Path.PathError || error{ InvalidJoinCount, GeometryWorkLimit };

// Reserve in the result allocator once. A null span is a straight edge.
fn knotCapacity(spans: anytype) usize {
    var count: usize = 0;
    var previous_end = geometry.Point.zero;
    for (spans) |entry| {
        const span: ?hobby.Span = entry;
        if (span) |s| {
            if (!s.start.eql(.zero) and !s.start.eql(previous_end)) count += 1;
            if (!s.end.eql(.zero)) count += 1;
            previous_end = s.end;
        } else previous_end = .zero;
    }
    return count;
}

/// The result owns its storage at its exact size; the solver's temporary
/// arrays are released before returning.
pub fn fromKnots(allocator: std.mem.Allocator, knots: []const hobby.Knot, options: hobby.Options) Error!Path {
    const spans = try hobby.interpolateSpans(allocator, knots, options);
    defer allocator.free(spans);
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.segments.ensureTotalCapacityPrecise(allocator, 1 + spans.len + @intFromBool(options.closed));
    try path.reserveKnots(knotCapacity(spans));
    try path.moveTo(spans[0].curve.p0);
    for (spans) |s| try path.solvedCubicTo(s.curve, s.start, s.end);
    if (options.closed) try path.close();
    return path;
}

/// The returned path owns its storage. Open paths need points.len-1 joins;
/// closed paths need points.len joins, including the last-to-first edge.
/// Smooth runs reuse Hobby with its default endpoint curl. A straight join
/// allows a corner rather than constraining an adjacent curve's tangent.
/// Repeated endpoints of smooth edges are rejected by Hobby; zero-length
/// straight edges are retained. At least two finite points are required.
pub fn construct(allocator: std.mem.Allocator, points: []const geometry.Point, joins: []const Join, options: Options) Error!Path {
    if (points.len < 2) return error.TooFewKnots;
    const count = if (options.closed) points.len else points.len - 1;
    if (joins.len != count) return error.InvalidJoinCount;
    if (count > options.max_segments or options.max_segments == 0) return error.GeometryWorkLimit;
    for (points) |point| if (!point.isFinite()) return error.NonFinite;

    var smooth_count: usize = 0;
    for (joins) |join| if (join == .smooth) {
        smooth_count += 1;
    };
    if (smooth_count == count) {
        const knots = try allocator.alloc(hobby.Knot, points.len);
        defer allocator.free(knots);
        for (points, knots) |point, *knot| knot.* = .{ .point = point };
        return fromKnots(allocator, knots, .{ .closed = options.closed });
    }

    const curves = try allocator.alloc(?hobby.Span, if (smooth_count == 0) 0 else count);
    defer allocator.free(curves);
    @memset(curves, null);
    if (smooth_count != 0) {
        for (joins, 0..) |join, first| {
            if (join != .smooth) continue;
            const previous = if (first == 0) count - 1 else first - 1;
            if ((options.closed or first != 0) and joins[previous] == .smooth) continue;
            var length: usize = 1;
            while (first + length < count or options.closed) : (length += 1) {
                if (joins[(first + length) % count] != .smooth) break;
            }
            const knots = try allocator.alloc(hobby.Knot, length + 1);
            defer allocator.free(knots);
            for (knots, 0..) |*knot, offset| knot.* = .{ .point = points[(first + offset) % points.len] };
            const run = try hobby.interpolateSpans(allocator, knots, .{});
            defer allocator.free(run);
            for (run, 0..) |span, offset| {
                curves[(first + offset) % count] = span;
            }
        }
    }

    var result = Path.init(allocator);
    errdefer result.deinit();
    const explicit_close = options.closed and joins[count - 1] == .smooth;
    try result.segments.ensureTotalCapacityPrecise(allocator, 1 + count + @intFromBool(explicit_close));
    try result.reserveKnots(knotCapacity(curves));
    try result.moveTo(points[0]);
    for (joins, 0..) |join, index| switch (join) {
        .straight => {
            // Path.close already represents a final straight closing edge.
            if (!options.closed or index + 1 != count) try result.lineTo(points[(index + 1) % points.len]);
        },
        .smooth => {
            const curve = curves[index].?;
            try result.solvedCubicTo(curve.curve, curve.start, curve.end);
        },
    };
    if (options.closed) try result.close();
    return result;
}

fn expectCurve(expected: geometry.Cubic, segment: Path.Segment) !void {
    try std.testing.expect(segment == .cubic);
    inline for (.{ .{ expected.p1, segment.cubic.c1 }, .{ expected.p2, segment.cubic.c2 }, .{ expected.p3, segment.cubic.end } }) |pair| {
        try std.testing.expectApproxEqAbs(pair[0].x, pair[1].x, 1e-9);
        try std.testing.expectApproxEqAbs(pair[0].y, pair[1].y, 1e-9);
    }
}

test "uniform joins preserve Hobby controls and native line topology" {
    const points = [_]geometry.Point{ .{ .x = 0, .y = 0 }, .{ .x = 60, .y = 80 }, .{ .x = 130, .y = 20 }, .{ .x = 210, .y = 90 } };
    for ([_]bool{ false, true }) |closed| {
        const joins = [_]Join{ .smooth, .smooth, .smooth, .smooth };
        var result = try construct(std.testing.allocator, &points, joins[0..if (closed) 4 else 3], .{ .closed = closed });
        defer result.deinit();
        const knots = [_]hobby.Knot{ .{ .point = points[0] }, .{ .point = points[1] }, .{ .point = points[2] }, .{ .point = points[3] } };
        const expected = try hobby.interpolate(std.testing.allocator, &knots, .{ .closed = closed });
        defer std.testing.allocator.free(expected);
        for (expected, 1..) |curve, index| try std.testing.expectEqualDeep(curve, geometry.Cubic{
            .p0 = points[index - 1],
            .p1 = result.segments.items[index].cubic.c1,
            .p2 = result.segments.items[index].cubic.c2,
            .p3 = result.segments.items[index].cubic.end,
        });
    }
    var lines = try construct(std.testing.allocator, points[0..3], &.{ .straight, .straight, .straight }, .{ .closed = true });
    defer lines.deinit();
    try std.testing.expectEqual(null, lines.knots);
    try std.testing.expectEqual(@as(usize, 4), lines.segments.items.len);
    try std.testing.expect(lines.segments.items[1] == .line and lines.segments.items[2] == .line and lines.segments.items[3] == .close);
    try std.testing.expectEqual(@as(usize, 3), lines.segmentCount());
}

// MetaPost 3.00, numbersystem=double, independently emitted on 2026-10-25.
// Source and the full numeric reference live in tests/fixtures/path-reference.mp.
test "mixed open paths agree with MetaPost curl breaks rather than line tangents" {
    const points = [_]geometry.Point{ .{ .x = 0, .y = 0 }, .{ .x = 60, .y = 80 }, .{ .x = 130, .y = 20 }, .{ .x = 210, .y = 90 } };
    var start_line = try construct(std.testing.allocator, &points, &.{ .straight, .smooth, .smooth }, .{});
    defer start_line.deinit();
    try std.testing.expect(start_line.segments.items[1] == .line);
    try expectCurve(.{ .p0 = points[1], .p1 = .{ .x = 66.800612298190742, .y = 46.306608903444761 }, .p2 = .{ .x = 95.66290809426917, .y = 21.567498221091814 }, .p3 = points[2] }, start_line.segments.items[2]);
    try expectCurve(.{ .p0 = points[2], .p1 = .{ .x = 171.11707968869445, .y = 18.122993366897148 }, .p2 = .{ .x = 206.40237652723098, .y = 48.997628100616616 }, .p3 = points[3] }, start_line.segments.items[3]);
    var end_line = try construct(std.testing.allocator, &points, &.{ .smooth, .smooth, .straight }, .{});
    defer end_line.deinit();
    try expectCurve(.{ .p0 = points[0], .p1 = .{ .x = -8.2850303397314207, .y = 39.319046187913557 }, .p2 = .{ .x = 19.933907164478192, .y = 76.94429619352637 }, .p3 = points[1] }, end_line.segments.items[1]);
    try expectCurve(.{ .p0 = points[1], .p1 = .{ .x = 95.890603727125296, .y = 82.737253539441241 }, .p2 = .{ .x = 127.21589939835806, .y = 55.887000106956002 }, .p3 = points[2] }, end_line.segments.items[2]);
    try std.testing.expect(end_line.segments.items[3] == .line);
}

test "closed mixed paths solve smooth spans across the array seam" {
    const points = [_]geometry.Point{ .{ .x = 0, .y = 0 }, .{ .x = 90, .y = 10 }, .{ .x = 110, .y = 100 }, .{ .x = 10, .y = 80 } };
    var result = try construct(std.testing.allocator, &points, &.{ .smooth, .straight, .smooth, .smooth }, .{ .closed = true });
    defer result.deinit();
    try expectCurve(.{ .p0 = points[0], .p1 = .{ .x = 24.144917291122429, .y = -31.735933708170002 }, .p2 = .{ .x = 73.410407603137386, .y = -26.261990340168346 }, .p3 = points[1] }, result.segments.items[1]);
    try std.testing.expect(result.segments.items[2] == .line);
    try expectCurve(.{ .p0 = points[2], .p1 = .{ .x = 75.805247468019587, .y = 115.2773410250883 }, .p2 = .{ .x = 35.688486558332578, .y = 107.25398884315092 }, .p3 = points[3] }, result.segments.items[3]);
    try expectCurve(.{ .p0 = points[3], .p1 = .{ .x = -11.300195637025297, .y = 57.401732370250613 }, .p2 = .{ .x = -18.156297687362574, .y = 23.8645282087505 }, .p3 = points[0] }, result.segments.items[4]);
    try std.testing.expect(result.segments.items[5] == .close);
    var split = try construct(std.testing.allocator, &points, &.{ .smooth, .straight, .smooth, .straight }, .{ .closed = true });
    defer split.deinit();
    try std.testing.expectEqual(@as(usize, 4), split.segmentCount());
    try std.testing.expect(split.segments.items[4] == .close);
}

test "path construction validates finite values join counts degeneracy and work budgets" {
    const points = [_]geometry.Point{ .zero, .{ .x = 10, .y = 0 } };
    try std.testing.expectError(error.TooFewKnots, construct(std.testing.allocator, points[0..1], &.{}, .{}));
    try std.testing.expectError(error.InvalidJoinCount, construct(std.testing.allocator, &points, &.{}, .{}));
    try std.testing.expectError(error.GeometryWorkLimit, construct(std.testing.allocator, &points, &.{.straight}, .{ .max_segments = 0 }));
    try std.testing.expectError(error.NonFinite, construct(std.testing.allocator, &.{ .zero, .{ .x = std.math.inf(f64), .y = 1 } }, &.{.straight}, .{}));
    try std.testing.expectError(error.CoincidentKnots, construct(std.testing.allocator, &.{ .zero, .zero }, &.{.smooth}, .{}));
    var zero = try construct(std.testing.allocator, &.{ .zero, .zero }, &.{.straight}, .{});
    defer zero.deinit();
    try std.testing.expectEqual(@as(usize, 2), zero.segments.items.len);
    var closed = try construct(std.testing.allocator, &points, &.{ .straight, .straight }, .{ .closed = true });
    defer closed.deinit();
    try std.testing.expectEqual(@as(usize, 2), closed.segmentCount());
    var smooth = try construct(std.testing.allocator, &points, &.{ .smooth, .smooth }, .{ .closed = true });
    defer smooth.deinit();
    try std.testing.expectEqual(@as(usize, 2), smooth.segmentCount());
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const points = [_]geometry.Point{ .{ .x = 0, .y = 0 }, .{ .x = 90, .y = 10 }, .{ .x = 110, .y = 100 }, .{ .x = 10, .y = 80 } };
    for ([_]struct { joins: [4]Join, closed: bool }{
        .{ .joins = .{ .smooth, .smooth, .smooth, .smooth }, .closed = true },
        .{ .joins = .{ .smooth, .straight, .smooth, .smooth }, .closed = true },
        .{ .joins = .{ .straight, .smooth, .smooth, .straight }, .closed = false },
        .{ .joins = .{ .straight, .straight, .straight, .straight }, .closed = false },
    }) |case| {
        var path = try construct(allocator, &points, case.joins[0..if (case.closed) 4 else 3], .{ .closed = case.closed });
        path.deinit();
    }
}

test "path construction releases every partial allocation" {
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}

test "Hobby construction and cloning fit the exact result budget" {
    const t = std.testing;
    const n = 256;
    var points: [n + 1]geometry.Point = undefined;
    for (&points, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = @floatFromInt(i % 7) };
    const joins: [n]Join = @splat(.smooth);
    const bytes = @sizeOf(Path.Segment) * (n + 1) + @sizeOf(Path.KnotTable) + @sizeOf(Path.KnotTable.Knot) * (n - 1);
    // The working arrays share the allocator and are released before the
    // path returns, which then holds exactly its own storage.
    var counting: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer t.expect(counting.deinit() == .ok) catch @panic("leak");
    var path = try construct(counting.allocator(), &points, &joins, .{});
    defer path.deinit();
    try t.expectEqual(bytes, counting.total_requested_bytes);
    try t.expectEqual(n - 1, path.knotRecords().len);
    var clone_buffer: [bytes]u8 align(@alignOf(Path.KnotTable)) = undefined;
    var clone_storage = std.heap.FixedBufferAllocator.init(&clone_buffer);
    var clone = try path.clone(clone_storage.allocator());
    defer clone.deinit();
    try t.expectEqualDeep(path.knotRecords(), clone.knotRecords());
    try t.expect(path.knotRecords().ptr != clone.knotRecords().ptr);
}
