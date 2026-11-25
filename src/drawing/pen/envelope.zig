//! Polygon-pen convolution tracing, following MetaPost's public-domain
//! offset_prep/make_envelope, mp.w at TeX Live commit
//! abf5274f6f69d0a23fcca267e631363d0a1fbc64 (John Hobby et al.).
//!
//! Exact cubic subsegments are translated by pen vertices. Positive offset
//! changes walk the pen boundary; inside changes connect their endpoints.
//! The returned winding path is an envelope, not a polygon Boolean union.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const nibs = @import("nib.zig");
const styles = @import("stroke.zig");
const prep = @import("envelope/prepare.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
pub const Builder = @import("envelope/Builder.zig");
const testing = @import("envelope/testing.zig");
const test_nib = testing.test_nib;
const testWinding = testing.testWinding;

pub const Options = struct {
    /// Geometric tolerance for explicit ellipse nib approximation and dashes.
    /// Polygon envelopes retain the original centerline curves.
    tolerance: f64 = g.curve_tolerance,
    max_segments: usize = 65536,
    max_vertices: usize = 1048576,
    max_depth: usize = 24,
    cap: styles.Cap = .round,
    join: styles.Join = .round,
    miter_limit: f64 = styles.default_miter_limit,
};
pub const Error = Allocator.Error || nibs.Error || prep.Error || error{
    InvalidTolerance,
    StrokeWorkLimit,
    PrecisionRange,
    InvalidStroke,
    EllipticalPen,
};

/// A complete polygon-pen stroke. Both side tracings form one closed contour
/// per subpath. Closed centerlines use round pen walks at their construction
/// cut, as in MetaPost's stroke export. Self intersections and interior
/// retrograde edges retain their nonzero-winding semantics.
/// Inputs are borrowed; the result and all temporary storage use allocator.
pub fn stroke(allocator: Allocator, nib: []const Point, path: Path, options: Options) Error!Path {
    return build(allocator, nib, path, options, false);
}

/// The native join at one knot, independent of the adjacent body tracings.
/// Its winding can be normalized independently before a set union with bodies.
pub fn joinOutline(allocator: Allocator, nib: []const Point, before: prep.Piece, after: prep.Piece, options: Options) Error!Path {
    var builder = try Builder.init(allocator, nib, options);
    errdefer builder.result.deinit();
    if (!before.curve.p3.eql(after.curve.p0)) return error.InvalidPath;
    const limits: prep.Limits = .{ .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth };
    const incoming = try prep.spans(allocator, nib, &.{before}, false, limits);
    defer allocator.free(incoming);
    const outgoing = try prep.spans(allocator, nib, &.{after}, false, limits);
    defer allocator.free(outgoing);
    const returning = try prep.spans(allocator, nib, &.{after}, true, limits);
    defer allocator.free(returning);
    const reverse = try prep.spans(allocator, nib, &.{before}, true, limits);
    defer allocator.free(reverse);
    if (incoming.len == 0 or outgoing.len == 0 or returning.len == 0 or reverse.len == 0) return builder.result;
    const first = incoming[incoming.len - 1];
    const last = returning[returning.len - 1];
    const at = before.curve.p3;
    const origin = try builder.offsetPoint(at, nib[first.offset]);
    try builder.move(origin);
    try builder.transition(first, outgoing[0], null, false);
    try builder.line(try builder.offsetPoint(at, nib[last.offset]));
    try builder.transition(last, reverse[0], null, false);
    try builder.line(origin);
    try builder.result.close();
    return builder.result;
}

/// MetaPost's directed polygon-pen envelope. A closed input traces only its
/// right-hand side and retains the original start and traversal direction;
/// an open input is doubled and capped by make_envelope's endpoint rules.
/// Ellipse and point pens are explicitly unsupported, as in MetaPost. Empty
/// compound paths stay empty. Each input subpath is processed independently.
pub fn envelope(allocator: Allocator, nib: nibs.Nib, path: Path, options: Options) Error!Path {
    return switch (nib) {
        .ellipse => {
            try nib.validate();
            return error.EllipticalPen;
        },
        .polygon => |vertices| result: {
            if (!std.math.isFinite(options.miter_limit)) return error.InvalidStroke;
            var normalized = options;
            // mp_set_up_envelope accepts finite limits below one, clamping
            // them before make_envelope. Complete strokes keep their own
            // existing strict Options contract.
            normalized.miter_limit = @max(@as(f64, 1), options.miter_limit);
            break :result build(allocator, vertices, path, normalized, true);
        },
    };
}

pub fn validate(nib: []const Point, options: Options) Error!void {
    try (nibs.Nib{ .polygon = nib }).validate();
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidStroke;
    if (options.max_segments == 0 or options.max_vertices < 3 or options.max_depth > 64 or nib.len > options.max_vertices) return error.StrokeWorkLimit;
}

fn build(allocator: Allocator, nib: []const Point, path: Path, options: Options, directed: bool) Error!Path {
    var builder = try Builder.init(allocator, nib, options);
    errdefer builder.result.deinit();
    if (directed and (nib.len == 1 or (nib.len == 2 and nib[0].eql(nib[1])))) return error.EllipticalPen;
    builder.directed = directed;
    var pieces: std.ArrayList(prep.Piece) = .empty;
    defer pieces.deinit(allocator);
    var current: ?Point = null;
    var start: ?Point = null;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (!point.isFinite()) return error.NonFinite;
            if (start) |begin| try builder.subpath(pieces.items, begin, false);
            pieces.clearRetainingCapacity();
            current = point;
            start = point;
        },
        .line => |point| {
            const previous = current orelse return error.InvalidPath;
            if (!point.isFinite()) return error.NonFinite;
            if (pieces.items.len >= options.max_segments) return error.StrokeWorkLimit;
            try pieces.append(allocator, linePiece(previous, point));
            current = point;
        },
        .cubic => |curve| {
            const previous = current orelse return error.InvalidPath;
            const native: g.Cubic = .{ .p0 = previous, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end };
            if (!native.isFinite()) return error.NonFinite;
            if (pieces.items.len >= options.max_segments) return error.StrokeWorkLimit;
            try pieces.append(allocator, .{ .curve = native, .cubic = true });
            current = curve.end;
        },
        .close => {
            const previous = current orelse return error.InvalidPath;
            const begin = start orelse return error.InvalidPath;
            if (!previous.eql(begin)) {
                if (pieces.items.len >= options.max_segments) return error.StrokeWorkLimit;
                try pieces.append(allocator, linePiece(previous, begin));
            }
            try builder.subpath(pieces.items, begin, true);
            pieces.clearRetainingCapacity();
            current = null;
            start = null;
        },
    };
    if (start) |begin| try builder.subpath(pieces.items, begin, false);
    return builder.result;
}

fn linePiece(first: Point, last: Point) prep.Piece {
    // Endpoint controls represent the exact same straight segment without
    // forming 1/3 absolute coordinates. That interpolation could manufacture
    // a false tangent at large origins; direction comes from the chord.
    return .{ .curve = .{ .p0 = first, .p1 = first, .p2 = last, .p3 = last }, .cubic = false };
}

test "polygon envelopes translate original cubic controls without flattening" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 3, .y = 1 }, .{ .x = 7, .y = 2 }, .{ .x = 10, .y = 4 });
    var result = try stroke(allocator, &test_nib, source, .{ .cap = .butt });
    defer result.deinit();
    const first = result.segments.items[1].cubic;
    try std.testing.expectEqual(Point{ .x = 5, .y = 0 }, first.c1);
    try std.testing.expectEqual(Point{ .x = 9, .y = 1 }, first.c2);
    try std.testing.expectEqual(Point{ .x = 12, .y = 3 }, first.end);
    var cubics: usize = 0;
    for (result.segments.items) |segment| if (segment == .cubic) {
        cubics += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), cubics);
}

test "envelope support chooses the outgoing end of a flat pen face" {
    try std.testing.expectEqual(@as(usize, 1), try prep.support(&test_nib, .{ .x = 1, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 3), try prep.support(&test_nib, .{ .x = -1, .y = 0 }));
}

test "complete strokes retain round zero length dots and connected closed sides" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.zero);
    var dot = try stroke(allocator, &test_nib, source, .{});
    defer dot.deinit();
    try std.testing.expectEqual(@as(usize, 5), dot.segments.items.len);
    var butt = try stroke(allocator, &test_nib, source, .{ .cap = .butt });
    defer butt.deinit();
    try std.testing.expectEqual(@as(usize, 0), butt.segments.items.len);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 5, .y = 10 });
    try source.close();
    var cycle = try stroke(allocator, &test_nib, source, .{});
    defer cycle.deinit();
    var contours: usize = 0;
    for (cycle.segments.items) |segment| if (segment == .close) {
        contours += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), contours);
}

test "zero area pens still validate source topology and finite controls" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.segments.append(allocator, .{ .line = .zero });
    try std.testing.expectError(error.InvalidPath, stroke(allocator, &.{.zero}, source, .{}));
    source.segments.clearRetainingCapacity();
    try source.moveTo(.zero);
    try source.segments.append(allocator, .{ .cubic = .{ .c1 = .zero, .c2 = .zero, .end = .{ .x = std.math.inf(f64), .y = 0 } } });
    try std.testing.expectError(error.NonFinite, stroke(allocator, &.{.zero}, source, .{}));
}

fn allocationCase(allocator: Allocator) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 12, .y = 24 }, .{ .x = -4, .y = 24 }, .{ .x = 10, .y = 0 });
    try source.moveTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 30, .y = 0 });
    try source.lineTo(.{ .x = 25, .y = 10 });
    try source.close();
    var result = try stroke(allocator, &test_nib, source, .{ .join = .miter, .cap = .square });
    defer result.deinit();
}

test "envelope work limits and allocation failures release both tracings" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try std.testing.expectError(error.StrokeWorkLimit, stroke(allocator, &test_nib, source, .{ .max_segments = 1 }));
    try std.testing.expectError(error.StrokeWorkLimit, stroke(allocator, &test_nib, source, .{ .max_vertices = 3 }));
    try std.testing.expectError(error.InvalidTolerance, stroke(allocator, &test_nib, source, .{ .tolerance = 0 }));
    try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{});
}

test "a pen wider than a closed centerline fills its center" {
    const allocator = std.testing.allocator;
    var source = try Path.circle(allocator, .zero, 1);
    defer source.deinit();
    const square = [_]Point{ .{ .x = -2, .y = -2 }, .{ .x = 2, .y = -2 }, .{ .x = 2, .y = 2 }, .{ .x = -2, .y = 2 } };
    var result = try stroke(allocator, &square, source, .{});
    defer result.deinit();
    try std.testing.expect(testWinding(result, .zero) != 0);
}

fn allocationCaseSmoothKnot(allocator: Allocator) !void {
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 20, .y = 0 });
    try path.lineTo(.{ .x = 0, .y = 20 });
    try path.close();
    var result = try stroke(allocator, &test_nib, path, .{ .join = .miter });
    defer result.deinit();
    try std.testing.expectEqual(Point{ .x = 12, .y = -1 }, result.segments.items[0].move);
}

test "full strokes reuse a middle smooth knot and release rotation storage on every OOM" {
    try allocationCaseSmoothKnot(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCaseSmoothKnot, .{});
}

test {
    _ = @import("envelope/origin_test.zig");
    _ = @import("envelope/directed_test.zig");
}
