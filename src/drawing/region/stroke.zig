//! Stroke construction for the curve-region backend. Fixed-width curves use
//! the existing MetaPost envelope; varying-width polylines supply positive
//! strips and corner/cap patches. The caller normalizes the returned nonzero
//! tracing once with the region Boolean engine.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const flattening = @import("../path/flatten.zig");
const envelope = @import("../pen/outline.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;

pub const Join = enum { square, bevel, round, miter };
pub const Cap = @import("../pen/stroke.zig").Cap;
pub const Options = struct {
    tolerance: f64 = 1e-3,
    max_segments: usize = 65536,
    max_vertices: usize = 1048576,
    max_depth: usize = 24,
    join: Join = .miter,
    cap: Cap = .butt,
    miter_limit: f64 = 4,
};

fn validate(options: Options) !void {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidMiterLimit;
    if (options.max_segments == 0 or options.max_vertices == 0 or options.max_depth > 64) return error.GeometryWorkLimit;
    if (options.tolerance * 0.125 == 0) return error.PrecisionRange;
}

fn same(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
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
        const two_point = contour.closed and spans.len == 2 and !spans[0].cubic and !spans[1].cubic and same(spans[0].curve.p0, spans[1].curve.p3) and same(spans[0].curve.p3, spans[1].curve.p0);
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

/// Piecewise-linear full width versus normalized contour arc length. Each
/// pen-up restarts the profile. Only this inherently varying-radius offset
/// construction uses the existing bounded centerline subdivision; Boolean
/// operations on ordinary input curves remain independent of subdivision.
pub fn profileTracing(allocator: Allocator, path: Path, positions: []const f64, widths: []const f64, options: Options) !Path {
    const profile: @import("../pen/WidthProfile.zig") = .{ .positions = positions, .widths = widths };
    if (positions.len > options.max_vertices) return error.GeometryWorkLimit;
    try validate(options);
    if (path.segments.items.len > options.max_segments *| 2 +| 1) return error.GeometryWorkLimit;
    const slope = try profile.maxSlope();
    for (path.segments.items) |segment| if (segment == .close and widths[0] != widths[widths.len - 1]) return error.DiscontinuousClosedProfile;
    if (slope == 0) {
        if (path.segments.items.len == 0) return Path.init(allocator);
        return strokeTracing(allocator, path, widths[0], options);
    }
    const base_budget = options.tolerance * 0.125;
    var flat = try flatten(allocator, path, options, base_budget);
    defer flat.deinit();
    const minimum_length = try minimumContourLength(flat);
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
            if (!same(points.items[points.items.len - 1], point)) try points.append(allocator, point);
        },
        .close => {
            const first = start orelse return error.InvalidPath;
            if (!same(points.items[points.items.len - 1], first)) {
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

fn minimumContourLength(path: Path) !f64 {
    var current: ?Point = null;
    var start: Point = .zero;
    var length: f64 = 0;
    var minimum = std.math.inf(f64);
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (length > 0) minimum = @min(minimum, length);
            current = point;
            start = point;
            length = 0;
        },
        .line, .close => {
            const point = if (segment == .line) segment.line else start;
            length += (current orelse return error.InvalidPath).distance(point);
            if (!std.math.isFinite(length)) return error.NonFinite;
            current = point;
            if (segment == .close) {
                if (length > 0) minimum = @min(minimum, length);
                length = 0;
                current = null;
            }
        },
        .cubic => unreachable,
    };
    if (length > 0) minimum = @min(minimum, length);
    return minimum;
}

const Vertex = struct { point: Point, radius: f64 };

fn profiledContour(builder: *Builder, points: []const Point, closed: bool, positions: []const f64, widths: []const f64) !void {
    if (points.len == 0) return error.InvalidPath;
    var length: f64 = 0;
    for (points[1..], points[0 .. points.len - 1]) |point, before| length += before.distance(point);
    if (!std.math.isFinite(length)) return error.NonFinite;
    if (length == 0) {
        if (!closed) try builder.stamp(points[0], widths[0] * 0.5, builder.options.cap);
        return;
    }
    const allocator = builder.result.allocator;
    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(allocator);
    try vertices.append(allocator, .{ .point = points[0], .radius = widths[0] * 0.5 });
    var distance: f64 = 0;
    var knot: usize = 1;
    for (points[1..], points[0 .. points.len - 1]) |point, before| {
        const edge_length = before.distance(point);
        const finish_distance = distance + edge_length;
        if (edge_length > 0 and finish_distance == distance) return error.PrecisionRange;
        while (knot < positions.len - 1 and positions[knot] * length < finish_distance) : (knot += 1) {
            const fraction = (positions[knot] * length - distance) / edge_length;
            if (fraction > 0) {
                if (vertices.items.len >= builder.options.max_vertices) return error.GeometryWorkLimit;
                // Interpolate a displacement, rather than weighted absolute
                // positions, so collinear translated segments stay collinear.
                const interpolated = try builder.point(before, point.sub(before).scale(fraction));
                try vertices.append(allocator, .{ .point = interpolated, .radius = widths[knot] * 0.5 });
            }
        }
        const u = if (finish_distance == length) 1 else finish_distance / length;
        while (knot < positions.len - 1 and positions[knot] < u) knot += 1;
        const index = @min(knot, positions.len - 1);
        const fraction = std.math.clamp((u - positions[index - 1]) / (positions[index] - positions[index - 1]), 0, 1);
        const radius = (widths[index - 1] * (1 - fraction) + widths[index] * fraction) * 0.5;
        if (vertices.items.len >= builder.options.max_vertices) return error.GeometryWorkLimit;
        try vertices.append(allocator, .{ .point = point, .radius = radius });
        distance = finish_distance;
    }
    const count = vertices.items.len - @intFromBool(closed);
    const values = vertices.items[0..count];
    const two_point = closed and count == 2;
    const cycle = closed and !two_point;
    for (0..if (cycle) count else count - 1) |index| {
        const a = values[index];
        const b = values[(index + 1) % count];
        if (same(a.point, b.point)) continue;
        const delta = b.point.sub(a.point);
        const tangent = try delta.normalized();
        const normal: Point = .{ .x = -tangent.y, .y = tangent.x };
        try builder.polygon(a.point, &.{ normal.scale(a.radius), normal.scale(-a.radius), delta.add(normal.scale(-b.radius)), delta.add(normal.scale(b.radius)) });
    }
    if (count == 1) return;
    for ((if (cycle) @as(usize, 0) else 1)..(if (cycle) count else count - 1)) |index| {
        const before = values[(index + count - 1) % count].point;
        const at = values[index];
        const after = values[(index + 1) % count].point;
        if (same(before, at.point) or same(at.point, after)) continue;
        try builder.corner(at.point, try at.point.sub(before).normalized(), try after.sub(at.point).normalized(), at.radius);
    }
    if (!cycle) {
        const cap: Cap = if (two_point) (if (builder.options.join == .round) .round else .square) else builder.options.cap;
        try builder.capPatch(values[0], try values[0].point.sub(values[1].point).normalized(), cap);
        try builder.capPatch(values[count - 1], try values[count - 1].point.sub(values[count - 2].point).normalized(), cap);
    }
}

const Span = struct { curve: g.Cubic, first: Point, last: Point, cubic: bool };
const Contour = struct { start: Point, first: usize, count: usize, closed: bool };
const Contours = struct {
    allocator: Allocator,
    spans: std.ArrayList(Span) = .empty,
    items: std.ArrayList(Contour) = .empty,

    fn init(allocator: Allocator, path: Path, options: Options) !Contours {
        var result: Contours = .{ .allocator = allocator };
        errdefer result.deinit();
        var current: ?Point = null;
        var start: Point = .zero;
        var first: usize = 0;
        var count: usize = 0;
        var vertices: usize = 0;
        for (path.segments.items) |segment| switch (segment) {
            .move => |point| {
                if (!point.isFinite()) return error.NonFinite;
                if (vertices >= options.max_vertices) return error.GeometryWorkLimit;
                vertices += 1;
                if (current != null) try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = false });
                first = result.spans.items.len;
                current = point;
                start = point;
            },
            .line => |point| {
                const previous = current orelse return error.InvalidPath;
                if (!point.isFinite()) return error.NonFinite;
                if (vertices >= options.max_vertices) return error.GeometryWorkLimit;
                vertices += 1;
                count += 1;
                if (count > options.max_segments) return error.GeometryWorkLimit;
                try result.line(previous, point);
                current = point;
            },
            .cubic => |value| {
                const curve: g.Cubic = .{ .p0 = current orelse return error.InvalidPath, .p1 = value.c1, .p2 = value.c2, .p3 = value.end };
                if (!curve.isFinite()) return error.NonFinite;
                if (3 > options.max_vertices - vertices) return error.GeometryWorkLimit;
                vertices += 3;
                count += 1;
                if (count > options.max_segments) return error.GeometryWorkLimit;
                if (try direction(curve, false)) |incoming| try result.spans.append(allocator, .{ .curve = curve, .first = incoming, .last = (try direction(curve, true)).?, .cubic = true });
                current = curve.p3;
            },
            .close => {
                const previous = current orelse return error.InvalidPath;
                if (!same(previous, start)) {
                    count += 1;
                    if (count > options.max_segments) return error.GeometryWorkLimit;
                    try result.line(previous, start);
                }
                try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = true });
                current = null;
            },
        };
        if (current != null) try result.items.append(allocator, .{ .start = start, .first = first, .count = result.spans.items.len - first, .closed = false });
        // A line/cubic span is charged by its input coordinates, and an
        // implicit closing span by its contour's move. Both temporary arrays
        // are therefore bounded while parsing, before any envelope expansion.
        return result;
    }
    fn line(self: *Contours, a: Point, b: Point) !void {
        if (same(a, b)) return;
        const tangent = try b.sub(a).normalized();
        try self.spans.append(self.allocator, .{ .curve = .{ .p0 = a, .p1 = a, .p2 = b, .p3 = b }, .first = tangent, .last = tangent, .cubic = false });
    }
    fn deinit(self: *Contours) void {
        self.spans.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

fn direction(curve: g.Cubic, last: bool) !?Point {
    const points = if (last) [_]Point{ curve.p2, curve.p1, curve.p0 } else [_]Point{ curve.p1, curve.p2, curve.p3 };
    for (points) |point| {
        const delta = if (last) curve.p3.sub(point) else point.sub(curve.p0);
        if (delta.x != 0 or delta.y != 0) return try delta.normalized();
    }
    return null;
}

const Builder = struct {
    result: Path,
    options: Options,
    vertices: usize = 0,

    fn append(self: *Builder, path: Path) !void {
        for (path.segments.items) |segment| try self.budget(if (segment == .cubic) 3 else if (segment == .close) 0 else 1);
        try self.result.append(path);
    }
    fn budget(self: *Builder, count: usize) !void {
        if (count > self.options.max_vertices -| self.vertices) return error.GeometryWorkLimit;
        self.vertices += count;
    }
    fn point(self: *const Builder, origin: Point, displacement: Point) !Point {
        @setFloatMode(.strict);
        var result: Point = undefined;
        inline for (.{ "x", "y" }) |field| {
            const a = @field(origin, field);
            const b = @field(displacement, field);
            const value = a + b;
            const virtual = value - a;
            const residual = (a - (value - virtual)) + (b - virtual);
            if (!std.math.isFinite(value) or !std.math.isFinite(residual)) return error.NonFinite;
            if (@abs(residual) > self.options.tolerance * 0.125) return error.PrecisionRange;
            @field(result, field) = value;
        }
        return result;
    }
    fn polygon(self: *Builder, origin: Point, offsets: []const Point) !void {
        if (offsets.len < 3) return;
        var twice_area: f64 = 0;
        for (offsets, 0..) |p, index| twice_area += p.cross(offsets[(index + 1) % offsets.len]);
        if (!std.math.isFinite(twice_area)) return error.NonFinite;
        if (twice_area == 0) return;
        try self.budget(offsets.len);
        try self.result.moveTo(try self.point(origin, offsets[0]));
        for (1..offsets.len) |index| {
            const i = if (twice_area > 0) index else offsets.len - index;
            try self.result.lineTo(try self.point(origin, offsets[i]));
        }
        try self.result.close();
    }
    fn corner(self: *Builder, at: Point, incoming: Point, outgoing: Point, radius: f64) !void {
        if (radius == 0) return;
        const cross = incoming.cross(outgoing);
        const cosine = std.math.clamp(incoming.dot(outgoing), -1, 1);
        if (cross == 0 and cosine >= 0) return;
        const side: f64 = if (cross >= 0) 1 else -1;
        const n0 = (Point{ .x = incoming.y, .y = -incoming.x }).scale(side);
        const n1 = (Point{ .x = outgoing.y, .y = -outgoing.x }).scale(side);
        const first = n0.scale(radius);
        const last = n1.scale(radius);
        if (self.options.join == .round) return self.arc(at, radius, n0, side * std.math.atan2(@abs(cross), cosine));
        const miter = cosine > 0.999 or (self.options.join == .miter and cosine > 2 / (self.options.miter_limit * self.options.miter_limit) - 1);
        if (miter and cosine > -1) {
            const tip = n0.add(n1).scale(radius / (1 + cosine));
            return self.polygon(at, &.{ .zero, first, tip, last });
        }
        if (self.options.join == .bevel) return self.polygon(at, &.{ .zero, first, last });
        // Intersect both offset edge lines with the perpendicular through a
        // point one radius along the outer angle bisector. This is the square
        // join definition, including the 180-degree reversal.
        const normal = n0.add(n1).normalized() catch incoming;
        const denominator = normal.dot(incoming);
        if (denominator == 0) return error.PrecisionRange;
        const q = normal.scale(radius);
        const a = first.add(incoming.scale((radius - normal.dot(first)) / denominator));
        const b = q.scale(2).sub(a);
        try self.polygon(at, &.{ .zero, first, a, b, last });
    }
    fn arc(self: *Builder, at: Point, radius: f64, from: Point, angle: f64) !void {
        if (radius == 0 or angle == 0) return;
        const ratio = @min(@as(f64, 1), self.options.tolerance * 0.125 / radius);
        // 1-cos(theta) loses tiny angles. The equivalent asin expression
        // keeps the requested bound without a minimum-angle clamp.
        const half_angle = 2 * std.math.asin(@sqrt(ratio * 0.5));
        if (half_angle == 0 or !std.math.isFinite(half_angle)) return error.PrecisionRange;
        const count_float = @max(@as(f64, 1), @ceil(@abs(angle) / (2 * half_angle)));
        if (count_float > @as(f64, @floatFromInt(self.options.max_vertices))) return error.GeometryWorkLimit;
        const count: usize = @intFromFloat(count_float);
        var points: std.ArrayList(Point) = .empty;
        defer points.deinit(self.result.allocator);
        try points.ensureTotalCapacity(self.result.allocator, count + 2);
        points.appendAssumeCapacity(.zero);
        for (0..count + 1) |index| {
            const theta = angle * (@as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count)));
            points.appendAssumeCapacity(.{ .x = radius * (from.x * @cos(theta) - from.y * @sin(theta)), .y = radius * (from.y * @cos(theta) + from.x * @sin(theta)) });
        }
        try self.polygon(at, points.items);
    }
    fn stamp(self: *Builder, at: Point, radius: f64, cap: Cap) !void {
        if (radius == 0 or cap == .butt) return;
        if (cap == .round) return self.arc(at, radius, .{ .x = 1, .y = 0 }, 2 * std.math.pi);
        try self.polygon(at, &.{ .{ .x = -radius, .y = -radius }, .{ .x = radius, .y = -radius }, .{ .x = radius, .y = radius }, .{ .x = -radius, .y = radius } });
    }
    fn capPatch(self: *Builder, at: Vertex, outward: Point, kind: Cap) !void {
        if (at.radius == 0 or kind == .butt) return;
        const normal: Point = .{ .x = outward.y, .y = -outward.x };
        if (kind == .round) return self.arc(at.point, at.radius, normal, std.math.pi);
        const side = normal.scale(at.radius);
        const tip = outward.scale(at.radius);
        try self.polygon(at.point, &.{ side, side.add(tip), tip.sub(side), side.scale(-1) });
    }
};

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

test "profile tracing has exact straight taper and diamond areas" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 100, .y = 0 });
    var taper = try profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer taper.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 600), taper.signedArea(), 1e-10);
    var diamond = try profileTracing(std.testing.allocator, line, &.{ 0, 0.5, 1 }, &.{ 0, 10, 0 }, .{});
    defer diamond.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 500), diamond.signedArea(), 1e-10);
}

test "profile tracing restarts at moves and validates closed seams" {
    var line: Path = .init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 100, .y = 0 });
    try line.moveTo(.{ .x = 0, .y = 20 });
    try line.lineTo(.{ .x = 100, .y = 20 });
    var pair = try profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer pair.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 1200), pair.signedArea(), 1e-9);
    try line.close();
    try std.testing.expectError(error.DiscontinuousClosedProfile, profileTracing(std.testing.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{}));
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

test "square joins and miter-limit fallback retain the square corner" {
    const incoming: Point = .{ .x = 1, .y = 0 };
    const outgoing: Point = .{ .x = 0, .y = 1 };
    var square: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .square } };
    defer square.result.deinit();
    try square.corner(.zero, incoming, outgoing, 2);
    const expected = 4 * (2 * @sqrt(@as(f64, 2)) - 2);
    try std.testing.expectApproxEqAbs(expected, square.result.signedArea(), 1e-12);
    var limited: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .miter, .miter_limit = 1 } };
    defer limited.result.deinit();
    try limited.corner(.zero, incoming, outgoing, 2);
    try std.testing.expectApproxEqAbs(expected, limited.result.signedArea(), 1e-12);
    var miter: Builder = .{ .result = .init(std.testing.allocator), .options = .{ .join = .miter, .miter_limit = 4 } };
    defer miter.result.deinit();
    try miter.corner(.zero, incoming, outgoing, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 4), miter.result.signedArea(), 1e-12);
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
