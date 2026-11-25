//! Stroke construction for the curve-region backend. Fixed-width curves use
//! the existing MetaPost envelope; varying-width polylines supply positive
//! strips and corner/cap patches. The caller normalizes the returned nonzero
//! tracing once with the region Boolean engine.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const flattening = @import("../path/flatten.zig");
const envelope = @import("../pen/outline.zig");
const pen_stroke = @import("../pen/stroke.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
const Contours = @import("stroke/Contours.zig");
const Builder = @import("stroke/Builder.zig");
const profile = @import("stroke/profile.zig");
const profiledContour = profile.profiledContour;

pub const Join = enum { square, bevel, round, miter };
pub const Cap = pen_stroke.Cap;
pub const Options = struct {
    tolerance: f64 = g.curve_tolerance,
    max_segments: usize = 65536,
    max_vertices: usize = 1048576,
    max_depth: usize = 24,
    /// A pen's default join; region joins add `square` to a pen's.
    join: Join = @field(Join, @tagName(pen_stroke.default_join)),
    cap: Cap = pen_stroke.default_cap,
    miter_limit: f64 = pen_stroke.default_miter_limit,
};

fn validate(options: Options) !void {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidMiterLimit;
    if (options.max_segments == 0 or options.max_vertices == 0 or options.max_depth > 64) return error.GeometryWorkLimit;
    if (options.tolerance * 0.125 == 0) return error.PrecisionRange;
}

/// Exact input curves stay curves. The square/miter patches fill the extra
/// outer corner beyond the bevel envelope; this preserves the existing
/// square fallback when a miter exceeds its limit.
pub fn strokeTracing(allocator: Allocator, path: Path, width: f64, options: Options) !Path {
    try validate(options);
    if (!std.math.isFinite(width) or width < 0) return error.InvalidWidth;
    var contours = try Contours.init(allocator, path, options);
    defer contours.deinit();
    var builder: Builder = .{ .result = .init(allocator), .options = options };
    errdefer builder.result.deinit();
    if (width == 0) return builder.result;
    const radius = width * 0.5;
    if (radius == 0) return error.PrecisionRange;
    for (contours.items.items) |contour| {
        if (contour.count == 0) {
            if (!contour.closed) try builder.stamp(contour.start, radius, options.cap);
            continue;
        }
        const spans = contours.spans.items[contour.first .. contour.first + contour.count];
        var centerline: Path = .init(allocator);
        defer centerline.deinit();
        try centerline.moveTo(contour.start);
        // A two-vertex closed centerline has capped-line semantics in the
        // previous public API, independent of later closed contours.
        const two_point = contour.closed and spans.len == 2 and !spans[0].cubic and !spans[1].cubic and spans[0].curve.p0.eql(spans[1].curve.p3) and spans[0].curve.p3.eql(spans[1].curve.p0);
        for (spans[0..if (two_point) 1 else spans.len]) |span| {
            if (span.cubic) try centerline.cubicTo(span.curve.p1, span.curve.p2, span.curve.p3) else try centerline.lineTo(span.curve.p3);
        }
        if (contour.closed and !two_point) try centerline.close();
        const cap: Cap = if (two_point) (if (options.join == .round) .round else .square) else options.cap;
        var tracing = envelope.strokeOutline(allocator, .{ .ellipse = .scaling(width, width) }, centerline, .{
            // Construction receives a quarter of the caller's spatial
            // budget, leaving room for Boolean restriction and final binary64
            // coordinates. The ellipse mesh reserves a further quarter for
            // its support polygon inside this construction budget.
            .tolerance = options.tolerance * 0.25,
            // Contours has already checked the original source segment
            // budget. Envelope spans, joins and construction caps are
            // derived geometry and share the output-coordinate budget.
            .max_segments = options.max_vertices,
            .max_vertices = options.max_vertices,
            .max_depth = options.max_depth,
            .cap = if (cap == .square) .butt else cap,
            .join = if (options.join == .round) .round else .bevel,
            .miter_limit = options.miter_limit,
        }) catch |err| switch (err) {
            error.StrokeWorkLimit => return error.GeometryWorkLimit,
            else => return err,
        };
        defer tracing.deinit();
        try builder.append(tracing);
        if (cap == .square and (!contour.closed or two_point)) {
            const last = spans[if (two_point) 0 else spans.len - 1];
            try builder.capPatch(.{ .point = contour.start, .radius = radius }, spans[0].first.scale(-1), .square);
            try builder.capPatch(.{ .point = last.curve.p3, .radius = radius }, last.last, .square);
        }
        if (options.join != .round and !two_point) {
            for (spans, 0..) |span, index| {
                if (index == 0 and !contour.closed) continue;
                const before = spans[(index + spans.len - 1) % spans.len];
                try builder.corner(span.curve.p0, before.last, span.first, radius);
            }
        }
    }
    return builder.result;
}

fn maxSlope(positions: []const f64, widths: []const f64) error{InvalidProfile}!f64 {
    if (positions.len < 2 or positions.len != widths.len) return error.InvalidProfile;
    if (positions[0] != 0 or positions[positions.len - 1] != 1) return error.InvalidProfile;
    var slope: f64 = 0;
    for (positions, widths, 0..) |position, width, index| {
        if (!std.math.isFinite(position) or !std.math.isFinite(width) or width < 0) return error.InvalidProfile;
        if (index == 0) continue;
        if (position <= positions[index - 1]) return error.InvalidProfile;
        const change = @abs(width - widths[index - 1]) / (position - positions[index - 1]);
        if (!std.math.isFinite(change)) return error.InvalidProfile;
        slope = @max(slope, change);
    }
    return slope;
}

/// Piecewise-linear full width versus normalized contour arc length. Each
/// pen-up restarts the profile. Only this inherently varying-radius offset
/// construction uses the existing bounded centerline subdivision; Boolean
/// operations on ordinary input curves remain independent of subdivision.
pub fn profileTracing(allocator: Allocator, path: Path, positions: []const f64, widths: []const f64, options: Options) !Path {
    if (positions.len > options.max_vertices) return error.GeometryWorkLimit;
    try validate(options);
    if (path.segments.items.len > options.max_segments *| 2 +| 1) return error.GeometryWorkLimit;
    const slope = try maxSlope(positions, widths);
    for (path.segments.items) |segment| if (segment == .close and widths[0] != widths[widths.len - 1]) return error.DiscontinuousClosedProfile;
    if (slope == 0) {
        if (path.segments.items.len == 0) return Path.init(allocator);
        return strokeTracing(allocator, path, widths[0], options);
    }
    const base_budget = options.tolerance * 0.125;
    var flat = try flatten(allocator, path, options, base_budget);
    defer flat.deinit();
    const minimum_length = try flattening.minimumContourLength(flat);
    if (slope > minimum_length and minimum_length > 0) {
        const budget = base_budget * (minimum_length / slope) * 0.5;
        if (budget == 0 or !std.math.isFinite(budget)) return error.PrecisionRange;
        var refined = try flatten(allocator, path, options, budget);
        flat.deinit();
        flat = refined;
        refined = undefined;
    }
    var builder: Builder = .{ .result = .init(allocator), .options = options };
    errdefer builder.result.deinit();
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(allocator);
    var start: ?Point = null;
    for (flat.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (start != null) try profiledContour(&builder, points.items, false, positions, widths);
            points.clearRetainingCapacity();
            start = point;
            try points.append(allocator, point);
        },
        .line => |point| {
            if (start == null) return error.InvalidPath;
            if (points.items.len >= options.max_vertices) return error.GeometryWorkLimit;
            if (!points.items[points.items.len - 1].eql(point)) try points.append(allocator, point);
        },
        .close => {
            const first = start orelse return error.InvalidPath;
            if (!points.items[points.items.len - 1].eql(first)) {
                if (points.items.len >= options.max_vertices) return error.GeometryWorkLimit;
                try points.append(allocator, first);
            }
            try profiledContour(&builder, points.items, true, positions, widths);
            points.clearRetainingCapacity();
            start = null;
        },
        .cubic => unreachable,
    };
    if (start != null) try profiledContour(&builder, points.items, false, positions, widths);
    return builder.result;
}

fn flatten(allocator: Allocator, path: Path, options: Options, length_budget: f64) !Path {
    return flattening.flatten(allocator, path, .{
        .tolerance = options.tolerance * 0.25,
        .length_tolerance = length_budget,
        .max_segments = options.max_segments,
        .max_depth = options.max_depth,
    }) catch |err| switch (err) {
        error.StrokeWorkLimit => error.GeometryWorkLimit,
        else => err,
    };
}

test "fixed stroke tracing preserves cubics and exact square caps" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var result = try strokeTracing(std.testing.allocator, line, 4, .{ .cap = .square });
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 56), result.signedArea(), 1e-9);
    var curve: Path = .init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 2, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 10, .y = 0 });
    var curved = try strokeTracing(std.testing.allocator, curve, 2, .{});
    defer curved.deinit();
    var cubics: usize = 0;
    for (curved.segments.items) |segment| if (segment == .cubic) {
        cubics += 1;
    };
    try std.testing.expect(cubics > 0);
}

fn allocationExercise(allocator: Allocator) !void {
    var line: Path = .init(allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 100, .y = 0 });
    try line.lineTo(.{ .x = 100, .y = 100 });
    var fixed = try strokeTracing(allocator, line, 4, .{ .cap = .square, .join = .square });
    defer fixed.deinit();
    var varying = try profileTracing(allocator, line, &.{ 0, 0.3, 1 }, &.{ 0, 4, 2 }, .{ .cap = .round, .join = .round });
    defer varying.deinit();
}

test "stroke construction cleans all intermediate allocations on failure" {
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}

test "all constant cap and join combinations retain straight stroke coverage" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    for ([_]Cap{ .butt, .round, .square }) |cap| {
        const expected: f64 = switch (cap) {
            .butt => 40,
            .round => 40 + 4 * std.math.pi,
            .square => 56,
        };
        for ([_]Join{ .square, .bevel, .round, .miter }) |join| {
            var fixed = try strokeTracing(std.testing.allocator, line, 4, .{ .cap = cap, .join = join });
            defer fixed.deinit();
            try std.testing.expectApproxEqAbs(expected, fixed.signedArea(), 0.01);
            var profiled = try profileTracing(std.testing.allocator, line, &.{ 0, 0.3, 1 }, &.{ 4, 4, 4 }, .{ .cap = cap, .join = join });
            defer profiled.deinit();
            try std.testing.expectApproxEqAbs(fixed.signedArea(), profiled.signedArea(), 1e-12);
        }
    }
}

test "stationary open caps and closed points remain distinct" {
    var point: Path = .init(std.testing.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    for ([_]Cap{ .butt, .round, .square }, [_]f64{ 0, 4 * std.math.pi, 16 }) |cap, expected| {
        var dot = try strokeTracing(std.testing.allocator, point, 4, .{ .cap = cap });
        defer dot.deinit();
        try std.testing.expectApproxEqAbs(expected, dot.signedArea(), 0.01);
    }
    try point.close();
    var closed = try strokeTracing(std.testing.allocator, point, 4, .{ .cap = .round });
    defer closed.deinit();
    try std.testing.expectEqual(@as(usize, 0), closed.segments.items.len);
}

test {
    _ = @import("stroke/Builder.zig");
    _ = @import("stroke/profile.zig");
}
