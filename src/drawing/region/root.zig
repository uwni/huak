//! Filled-region operations on original binary64 Bezier curves.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const boolean = @import("boolean.zig");
const strokes = @import("stroke.zig");
const Allocator = std.mem.Allocator;
pub const coverage = @import("coverage.zig");

pub const Operation = enum(u32) { unite, intersect, difference, xor };
pub const FillRule = enum(u32) { evenodd, nonzero, positive, negative };
pub const Join = strokes.Join;
pub const Cap = strokes.Cap;
pub const Options = struct {
    tolerance: f64 = 1e-3,
    max_segments: usize = 65536,
    max_vertices: usize = 1048576,
    max_depth: usize = 24,
    fill_rule: FillRule = .nonzero,
    join: Join = .miter,
    cap: Cap = .butt,
    miter_limit: f64 = 4,
};

pub fn combine(allocator: Allocator, a: Path, b: Path, operation: Operation, options: Options) !Path {
    try validateOptions(options);
    const first = try validatePath(a, true);
    const second = try validatePath(b, true);
    if (first > options.max_segments or second > options.max_segments - first) return error.GeometryWorkLimit;
    return boolean.combine(allocator, a, b, operation, options);
}

pub fn offset(allocator: Allocator, path: Path, distance: f64, options: Options) !Path {
    try validateOptions(options);
    try validateMiter(options);
    if (!std.math.isFinite(distance)) return error.InvalidOffset;
    var empty = Path.init(allocator);
    defer empty.deinit();
    var base = try combine(allocator, path, empty, .unite, options);
    if (distance == 0 or base.segments.items.len == 0) return base;
    defer base.deinit();
    const width = 2 * @abs(distance);
    if (!std.math.isFinite(width)) return error.PrecisionRange;
    var settings = options;
    settings.fill_rule = .nonzero;
    // The caller's source span limit was checked before normalization. The
    // derived boundary band instead uses the bounded internal vertex budget.
    settings.max_segments = options.max_vertices;
    var band = try stroke(allocator, base, width, settings);
    defer band.deinit();
    return combine(allocator, base, band, if (distance > 0) .unite else .difference, settings);
}

pub fn stroke(allocator: Allocator, path: Path, width: f64, options: Options) !Path {
    try validateOptions(options);
    try validateMiter(options);
    var tracing = try strokes.strokeTracing(allocator, path, width, strokeOptions(options));
    defer tracing.deinit();
    return normalizeStroke(allocator, tracing, options);
}

pub fn profileStroke(allocator: Allocator, path: Path, positions: []const f64, widths: []const f64, options: Options) !Path {
    var tracing = try strokes.profileTracing(allocator, path, positions, widths, strokeOptions(options));
    defer tracing.deinit();
    return normalizeStroke(allocator, tracing, options);
}

/// Resolve the nonzero fill of a generated stroke outline into an owned path.
pub fn normalizeStroke(allocator: Allocator, tracing: Path, options: Options) !Path {
    var settings = options;
    settings.fill_rule = .nonzero;
    // Envelope construction already applies its own source/work budget. Its
    // resulting tracing can contain several boundary spans per source span.
    settings.max_segments = options.max_vertices;
    var result = try combine(allocator, tracing, Path.init(allocator), .unite, settings);
    errdefer result.deinit();
    if (tracing.segments.items.len != 0 and result.segments.items.len == 0) return error.PrecisionRange;
    return result;
}

pub fn clipRegion(allocator: Allocator, path: Path, rectangle: g.BBox, options: Options) !Path {
    try validateOptions(options);
    try validateRectangle(rectangle);
    if (try validatePath(path, true) > options.max_segments) return error.GeometryWorkLimit;
    if (try boolean.vertexCount(path) > options.max_vertices) return error.GeometryWorkLimit;
    var clip = Path.init(allocator);
    defer clip.deinit();
    if (rectangle.width() == 0 or rectangle.height() == 0) return Path.init(allocator);
    try clip.moveTo(rectangle.min);
    try clip.lineTo(.{ .x = rectangle.max.x, .y = rectangle.min.y });
    try clip.lineTo(rectangle.max);
    try clip.lineTo(.{ .x = rectangle.min.x, .y = rectangle.max.y });
    try clip.close();
    var settings = options;
    settings.max_segments = options.max_vertices +| 4;
    settings.max_vertices = options.max_vertices +| 4;
    var result: Path = undefined;
    // A signed fill rule applies to the source, not the positive clip box.
    if (options.fill_rule == .positive or options.fill_rule == .negative) {
        var empty = Path.init(allocator);
        defer empty.deinit();
        var normalized = try combine(allocator, path, empty, .unite, options);
        defer normalized.deinit();
        settings.fill_rule = .nonzero;
        result = try combine(allocator, normalized, clip, .intersect, settings);
    } else result = try combine(allocator, path, clip, .intersect, settings);
    errdefer result.deinit();
    if (try boolean.vertexCount(result) > options.max_vertices) return error.GeometryWorkLimit;
    return result;
}

pub fn clipLines(allocator: Allocator, path: Path, rectangle: g.BBox, options: Options) !Path {
    try validateOptions(options);
    try validateRectangle(rectangle);
    if (try validatePath(path, false) > options.max_segments) return error.GeometryWorkLimit;
    if (try boolean.vertexCount(path) > options.max_vertices) return error.GeometryWorkLimit;
    if (rectangle.width() == 0 or rectangle.height() == 0) return Path.init(allocator);
    var result = try path.clippedToRect(allocator, rectangle);
    errdefer result.deinit();
    // clipLines treats closing edges as ordinary drawn edges. Path's general
    // clipping method preserves a wholly retained closed stroke instead.
    openFragments(&result);
    if (try boolean.vertexCount(result) > options.max_vertices) return error.GeometryWorkLimit;
    return result;
}

fn openFragments(path: *Path) void {
    var start: g.Point = .zero;
    var current: g.Point = .zero;
    var pending_move: ?g.Point = null;
    var last_start: ?g.Point = null;
    var last_point: ?g.Point = null;
    var written: usize = 0;
    for (path.segments.items) |segment| {
        var value = segment;
        var end: g.Point = undefined;
        switch (segment) {
            .move => |point| {
                start = point;
                current = point;
                pending_move = point;
                continue;
            },
            .line => |point| end = point,
            .cubic => |curve| {
                if (samePoint(current, curve.c1) and samePoint(current, curve.c2) and samePoint(current, curve.end)) continue;
                end = curve.end;
            },
            .close => {
                end = start;
                value = .{ .line = start };
            },
        }
        if (value == .line and samePoint(current, end)) continue;
        if (pending_move) |point| {
            path.segments.items[written] = .{ .move = point };
            written += 1;
            last_start = point;
            pending_move = null;
        }
        path.segments.items[written] = value;
        written += 1;
        current = end;
        last_point = end;
    }
    path.segments.items.len = written;
    path.start = last_start;
    path.current = last_point;
    path.open = last_point != null;
}

fn samePoint(a: g.Point, b: g.Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn strokeOptions(options: Options) strokes.Options {
    return .{ .tolerance = options.tolerance, .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth, .join = options.join, .cap = options.cap, .miter_limit = options.miter_limit };
}
fn validateOptions(options: Options) !void {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.tolerance * 0.25 == 0) return error.PrecisionRange;
    if (options.max_segments == 0 or options.max_vertices == 0 or options.max_depth > 64) return error.GeometryWorkLimit;
}
fn validateMiter(options: Options) !void {
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidMiterLimit;
}
fn validateRectangle(rectangle: g.BBox) !void {
    if (!rectangle.min.isFinite() or !rectangle.max.isFinite() or rectangle.min.x > rectangle.max.x or rectangle.min.y > rectangle.max.y) return error.InvalidRectangle;
    if (!std.math.isFinite(rectangle.width()) or !std.math.isFinite(rectangle.height())) return error.PrecisionRange;
}
fn validatePath(path: Path, closed: bool) !usize {
    var active = false;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (active and closed) return error.OpenPath;
            if (!point.isFinite()) return error.NonFinite;
            active = true;
        },
        .line => |point| {
            if (!active) return error.InvalidPath;
            if (!point.isFinite()) return error.NonFinite;
        },
        .cubic => |curve| {
            if (!active) return error.InvalidPath;
            if (!curve.c1.isFinite() or !curve.c2.isFinite() or !curve.end.isFinite()) return error.NonFinite;
        },
        .close => {
            if (!active) return error.InvalidPath;
            active = false;
        },
    };
    if (closed and active) return error.OpenPath;
    return path.segmentCount();
}

test {
    _ = strokes;
    _ = coverage;
    _ = @import("pathops/root.zig");
}

test "unite preserves the counter between two overlapping diagonal strokes" {
    const point = struct {
        fn at(x: f64, y: f64) g.Point {
            return .{ .x = x, .y = y };
        }
    }.at;
    const a = std.testing.allocator;
    var guide = Path.init(a);
    defer guide.deinit();
    // Two open strokes from the top of 隹. Their outlines enclose a diamond.
    try guide.moveTo(point(71.15, 38.58));
    try guide.cubicTo(point(73.82, 41.26), point(78.29, 43.9), point(81.09, 45.02));
    try guide.cubicTo(point(83.22, 44.54), point(89.09, 40.94), point(91.26, 39.02));
    try guide.moveTo(point(75.26, 41.58));
    try guide.lineTo(point(80.19718786250743, 36.42969611465051));
    try guide.cubicTo(point(80.61239595416914, 35.99656537155017), point(81.0607303763256, 35.95902202633791), point(81.5421911289768, 36.31706607901375));
    try guide.lineTo(point(87.92, 41.06));

    const windingAt = @import("pathops/winding.zig").windingAt;
    // Separate strokes change the arrangement bounds and snap resolution.
    // The distant case also produces adjacent representable cut parameters.
    for ([_]?[2]g.Point{ null, .{ point(54.8, 46.9), point(54.8, 7.74) }, .{ point(500, 0), point(500, 40) } }) |neighbor| {
        var drawing = try guide.clone(a);
        defer drawing.deinit();
        if (neighbor) |line| {
            try drawing.moveTo(line[0]);
            try drawing.lineTo(line[1]);
        }
        var raw = try strokes.strokeTracing(a, drawing, 3.4, .{ .cap = .butt, .join = .round });
        defer raw.deinit();
        var united = try combine(a, raw, Path.init(a), .unite, .{});
        defer united.deinit();
        for ([_]Path{ raw, united }) |path| {
            try std.testing.expectEqual(@as(i32, 0), try windingAt(path, point(81, 41.25)));
            try std.testing.expect(try windingAt(path, point(81, 44.5)) != 0);
            try std.testing.expect(try windingAt(path, point(81, 36.5)) != 0);
        }
    }
}

test "intersection preserves the four junctions where a narrow strip crosses a rectangle" {
    const a = std.testing.allocator;
    const boxes = [_]g.BBox{
        .{ .min = .{ .x = -1000, .y = -1 }, .max = .{ .x = 1000, .y = 1 } },
        .{ .min = .{ .x = -0.0001875, .y = -3 }, .max = .{ .x = 0.0001875, .y = 3 } },
    };
    var paths = [2]Path{ Path.init(a), Path.init(a) };
    defer for (&paths) |*path| path.deinit();
    for (&paths, boxes) |*path, box| {
        try path.moveTo(box.min);
        try path.lineTo(.{ .x = box.max.x, .y = box.min.y });
        try path.lineTo(box.max);
        try path.lineTo(.{ .x = box.min.x, .y = box.max.y });
        try path.close();
    }
    // The strip is three snap radii wide, inside the short-span threshold.
    // Crossing the other rectangle creates two distinct junctions per side.
    for ([_]bool{ false, true }) |swap| {
        const i: usize = @intFromBool(swap);
        var clipped = try combine(a, paths[i], paths[1 - i], .intersect, .{});
        defer clipped.deinit();
        try std.testing.expectApproxEqAbs(boxes[0].height() * boxes[1].width(), clipped.signedArea(), 1e-12);
    }
}

test "tight cubic stroke has no pinhole at close inner-edge crossings" {
    const a = std.testing.allocator;
    var guide = try Path.circle(a, .zero, 7);
    defer guide.deinit();
    try guide.moveTo(.{ .x = 20, .y = 5 });
    try guide.cubicTo(.{ .x = 24, .y = -20 }, .{ .x = 32, .y = 35 }, .{ .x = 48, .y = 4 });
    try guide.moveTo(.{ .x = 60, .y = 1 });
    try guide.lineTo(.{ .x = 60, .y = 1 });
    var ink = try stroke(a, guide, 4, .{ .cap = .round, .join = .round });
    defer ink.deinit();
    const windingAt = @import("pathops/winding.zig").windingAt;
    try std.testing.expect(try windingAt(ink, .{ .x = 22.556458, .y = 0.218695 }) != 0);
    var contours: usize = 0;
    for (ink.segments.items) |segment| contours += @intFromBool(segment == .close);
    try std.testing.expectEqual(@as(usize, 4), contours);
}

test "a chain of individually short edges preserves a resolved disk" {
    const a = std.testing.allocator;
    var outline = Path.init(a);
    defer outline.deinit();
    for (0..64) |i| {
        const angle = std.math.tau * @as(f64, @floatFromInt(i)) / 64;
        const point: g.Point = .{ .x = 0.004 * @cos(angle), .y = 0.004 * @sin(angle) };
        if (i == 0) try outline.moveTo(point) else try outline.lineTo(point);
    }
    try outline.close();
    // Set the scene scale with a separate triangle. Each edge of the disk
    // is shorter than the merge threshold, but its diameter spans 8 tolerances.
    try outline.moveTo(.{ .x = 2000, .y = 0 });
    try outline.lineTo(.{ .x = 2001, .y = 0 });
    try outline.lineTo(.{ .x = 2000, .y = 1 });
    try outline.close();
    var ink = try combine(a, outline, Path.init(a), .unite, .{ .tolerance = 0.001 });
    defer ink.deinit();
    const windingAt = @import("pathops/winding.zig").windingAt;
    try std.testing.expectEqual(@as(i32, 1), try windingAt(ink, .zero));
    try std.testing.expectEqual(@as(i32, 0), try windingAt(ink, .{ .x = 0.006, .y = 0 }));
}
