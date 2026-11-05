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

pub const Options = struct {
    /// Geometric tolerance for explicit ellipse nib approximation and dashes.
    /// Polygon envelopes retain the original centerline curves.
    tolerance: f64 = 1e-3,
    max_segments: usize = 65536,
    max_vertices: usize = 1048576,
    max_depth: usize = 24,
    cap: styles.Cap = .round,
    join: styles.Join = .round,
    miter_limit: f64 = 4,
};
pub const Error = Allocator.Error || nibs.Error || prep.Error || error{
    InvalidTolerance,
    StrokeWorkLimit,
    PrecisionRange,
    InvalidStroke,
    EllipticalPen,
};

/// Independently selected real or artificial section caps.
pub const Ends = struct {
    start: styles.Cap,
    end: styles.Cap,
};

/// Shared tracing state for both native paths and prepared source intervals.
/// Prepared pieces retain the original path's finite, connected topology.
pub const Builder = struct {
    result: Path,
    nib: []const Point,
    options: Options,
    vertices: usize = 0,
    segments: usize = 0,
    directed: bool = false,
    ends: ?Ends = null,

    pub fn init(allocator: Allocator, nib: []const Point, options: Options) Error!Builder {
        try validate(nib, options);
        return .{ .result = Path.init(allocator), .nib = nib, .options = options };
    }

    fn check(self: *Builder, point: Point, count: usize) Error!void {
        if (!point.isFinite()) return error.NonFinite;
        if (count > self.options.max_vertices -| self.vertices) return error.StrokeWorkLimit;
        self.vertices += count;
    }
    fn addCoordinate(self: *const Builder, position: f64, displacement: f64) Error!f64 {
        @setFloatMode(.strict);
        const sum = position + displacement;
        if (!std.math.isFinite(sum)) return error.NonFinite;
        // Knuth's TwoSum recovers the actual addition error, rather than
        // rejecting an exactly representable integer offset merely because
        // its absolute origin is large. Keep the existing precision budget.
        const virtual_displacement = sum - position;
        const residual = (position - (sum - virtual_displacement)) + (displacement - virtual_displacement);
        if (!std.math.isFinite(residual) or @abs(residual) > self.options.tolerance * 0.125) return error.PrecisionRange;
        return sum;
    }
    fn offsetPoint(self: *const Builder, point: Point, displacement: Point) Error!Point {
        return .{
            .x = try self.addCoordinate(point.x, displacement.x),
            .y = try self.addCoordinate(point.y, displacement.y),
        };
    }
    fn move(self: *Builder, point: Point) Error!void {
        try self.check(point, 1);
        try self.result.moveTo(point);
    }
    fn line(self: *Builder, point: Point) Error!void {
        if (prep.same(point, self.result.current.?)) return;
        if (self.segments >= self.options.max_segments) return error.StrokeWorkLimit;
        try self.check(point, 1);
        try self.result.lineTo(point);
        self.segments += 1;
    }
    fn curve(self: *Builder, span: prep.Span) Error!void {
        const offset = self.nib[span.offset];
        const cubic = span.curve;
        // The derivative spec can retain an offset change at an interval
        // whose position controls rounded to one point. Keep its pen walk,
        // while removing the dead geometric cubic as offset_prep does.
        if (prep.stationary(cubic)) return;
        if (!span.cubic) return self.line(try self.offsetPoint(cubic.p3, offset));
        try self.cubicTo(try self.offsetPoint(cubic.p1, offset), try self.offsetPoint(cubic.p2, offset), try self.offsetPoint(cubic.p3, offset));
    }
    fn cubicTo(self: *Builder, first: Point, second: Point, last: Point) Error!void {
        if (self.segments >= self.options.max_segments) return error.StrokeWorkLimit;
        try self.check(first, 1);
        try self.check(second, 1);
        try self.check(last, 1);
        try self.result.cubicTo(first, second, last);
        self.segments += 1;
    }
    fn walk(self: *Builder, at: Point, first: usize, last: usize) Error!void {
        var index = first;
        for (0..self.nib.len) |_| {
            if (index == last) return;
            index = (index + 1) % self.nib.len;
            try self.line(try self.offsetPoint(at, self.nib[index]));
        }
        return error.InvalidNib;
    }
    fn transition(self: *Builder, before: prep.Span, after: prep.Span, cap: ?styles.Cap, initial: bool) Error!void {
        if (before.offset == after.offset) return;
        const at = before.curve.p3;
        const from = self.nib[before.offset];
        const to = self.nib[after.offset];
        const incoming = before.end_direction;
        const outgoing = after.start_direction;
        if (cap) |kind| {
            switch (kind) {
                .round => return self.walk(at, before.offset, after.offset),
                .butt => {},
                .square => {
                    const chord = to.sub(from);
                    if (!prep.zero(chord)) {
                        var normal = try (Point{ .x = chord.y, .y = -chord.x }).normalized();
                        if (normal.dot(incoming) < 0) normal = normal.scale(-1);
                        const denominator = normal.dot(incoming);
                        if (denominator > 0) {
                            const tip = self.nib[try prep.support(self.nib, .{ .x = -normal.y, .y = normal.x })];
                            const height = @max(@as(f64, 0), tip.sub(from).dot(normal));
                            const extension = incoming.scale(height / denominator);
                            try self.line(try self.offsetPoint(try self.offsetPoint(at, from), extension));
                            try self.line(try self.offsetPoint(try self.offsetPoint(at, to), extension));
                        }
                    }
                },
            }
            return self.line(try self.offsetPoint(at, to));
        }
        const first = if (after.first) incoming else before.middle;
        const last = if (after.first) outgoing else after.middle;
        var turn = first.cross(last);
        // offset_prep's final correction normalizes the first knot's change
        // into (-n,0], then adds n for a nonnegative incoming/outgoing cross.
        // Equal tangent directions at a clockwise cycle's start can therefore
        // walk the long CCW pen arc, an observable part of directed envelope.
        if (initial and turn >= 0) {
            turn = 1;
        } else if (turn == 0 and first.dot(last) < 0) turn = if (after.first) 1 else @floatFromInt(after.turn);
        // Retrograde pen edges belong to the inside of the convolution. The
        // original algorithm always bevels these, irrespective of join style.
        if (turn > 0) switch (self.options.join) {
            .round => return self.walk(at, before.offset, after.offset),
            .bevel => {},
            .miter => {
                const cosine_squared = @max(@as(f64, 0), (1 + incoming.dot(outgoing)) * 0.5);
                const determinant = incoming.cross(outgoing);
                if (cosine_squared > 0 and self.options.miter_limit >= 1 / @sqrt(cosine_squared) and @abs(determinant) >= 1e-4) {
                    const distance = to.sub(from).cross(outgoing) / determinant;
                    try self.line(try self.offsetPoint(try self.offsetPoint(at, from), incoming.scale(distance)));
                }
            },
        };
        try self.line(try self.offsetPoint(at, to));
    }
    fn side(self: *Builder, spans: []const prep.Span) Error!void {
        for (spans, 0..) |span, i| {
            try self.curve(span);
            if (i + 1 < spans.len) try self.transition(span, spans[i + 1], null, false);
        }
    }
    fn contour(self: *Builder, spans: []const prep.Span, reverse: []const prep.Span, cap: styles.Cap, ends: ?Ends) Error!void {
        if (spans.len == 0) return;
        if (reverse.len == 0) return error.InvalidPath;
        try self.move(try self.offsetPoint(spans[0].curve.p0, self.nib[spans[0].offset]));
        try self.side(spans);
        try self.transition(spans[spans.len - 1], reverse[0], if (ends) |value| value.end else cap, false);
        try self.side(reverse);
        try self.transition(reverse[reverse.len - 1], spans[0], if (ends) |value| value.start else cap, false);
        try self.result.close();
    }
    fn degenerate(self: *Builder, at: Point, stamp: bool) Error!void {
        const first = try self.offsetPoint(at, self.nib[0]);
        try self.move(first);
        if (stamp) {
            for (self.nib[1..]) |vertex| try self.line(try self.offsetPoint(at, vertex));
            try self.line(first);
        }
        // Keep the degenerate path value as MetaPost does. In particular this
        // must not borrow complete-stroke's deliberate zero-length dot rule.
        for (0..if (stamp) @as(usize, 1) else 2) |_| try self.cubicTo(first, first, first);
        try self.result.close();
    }
    fn directedSubpath(self: *Builder, pieces: []const prep.Piece, at: Point, closed: bool) Error!void {
        const limits: prep.Limits = .{ .max_segments = self.options.max_segments, .max_vertices = self.options.max_vertices, .max_depth = self.options.max_depth };
        const forward = try prep.spans(self.result.allocator, self.nib, pieces, false, limits);
        defer self.result.allocator.free(forward);
        if (forward.len == 0) {
            const stamp = if (closed) pieces.len <= 1 and self.options.join == .round else pieces.len == 0 and self.options.cap == .round;
            return self.degenerate(at, stamp);
        }
        if (closed) {
            // make_envelope starts with the incoming offset at the original
            // knot, then traces that knot's join before its outgoing cubic.
            try self.move(try self.offsetPoint(forward[0].curve.p0, self.nib[forward[forward.len - 1].offset]));
            try self.transition(forward[forward.len - 1], forward[0], null, true);
            try self.side(forward);
            return self.result.close();
        }
        const reverse = try prep.spans(self.result.allocator, self.nib, pieces, true, limits);
        defer self.result.allocator.free(reverse);
        try self.contour(forward, reverse, self.options.cap, null);
    }
    pub fn subpath(self: *Builder, pieces: []const prep.Piece, at: Point, closed: bool) Error!void {
        if (self.directed) return self.directedSubpath(pieces, at, closed);
        if (self.nib.len == 1) return;
        if (self.nib.len == 2) {
            const edge = self.nib[1].sub(self.nib[0]);
            if (!edge.isFinite()) return error.NonFinite;
            if (prep.zero(edge)) return;
            const direction = try edge.normalized();
            var area = false;
            for (pieces) |piece| {
                const controls = [_]Point{ piece.curve.p1, piece.curve.p2, piece.curve.p3 };
                for (controls[if (piece.cubic) 0 else 2..]) |point| {
                    const difference = point.sub(piece.curve.p0);
                    if (!difference.isFinite()) return error.NonFinite;
                    if (difference.cross(direction) != 0) area = true;
                }
            }
            if (!area) return;
        }
        var rotated: std.ArrayList(prep.Piece) = .empty;
        defer rotated.deinit(self.result.allocator);
        var input = pieces;
        if (closed) {
            if (try prep.smoothKnot(pieces)) |index| {
                if (index != 0) {
                    try rotated.ensureTotalCapacity(self.result.allocator, pieces.len);
                    rotated.appendSliceAssumeCapacity(pieces[index..]);
                    rotated.appendSliceAssumeCapacity(pieces[0..index]);
                    input = rotated.items;
                }
            } else for (pieces, 0..) |piece, index| {
                if (prep.stationary(piece.curve)) continue;
                if (pieces.len >= self.options.max_segments) return error.StrokeWorkLimit;
                const cut = piece.curve.split(try prep.interiorCut(piece.curve));
                try rotated.ensureTotalCapacity(self.result.allocator, pieces.len + 1);
                rotated.appendAssumeCapacity(.{ .curve = cut.right, .cubic = piece.cubic });
                rotated.appendSliceAssumeCapacity(pieces[index + 1 ..]);
                rotated.appendSliceAssumeCapacity(pieces[0..index]);
                rotated.appendAssumeCapacity(.{ .curve = cut.left, .cubic = piece.cubic });
                input = rotated.items;
                break;
            }
        }
        const limits: prep.Limits = .{ .max_segments = self.options.max_segments, .max_vertices = self.options.max_vertices, .max_depth = self.options.max_depth };
        const forward = try prep.spans(self.result.allocator, self.nib, input, false, limits);
        defer self.result.allocator.free(forward);
        if (forward.len == 0) {
            // Preserve physical zero-length dots (including dashed zero-on
            // intervals). This complete-stroke API intentionally extends the
            // degenerate directional-envelope behavior of MetaPost.
            const stamp = if (self.ends) |ends| ends.start != .butt or ends.end != .butt else self.options.cap != .butt;
            if (stamp and !closed and self.nib.len > 2) {
                try self.move(try self.offsetPoint(at, self.nib[0]));
                for (self.nib[1..]) |vertex| try self.line(try self.offsetPoint(at, vertex));
                try self.result.close();
            }
            return;
        }
        const reverse = try prep.spans(self.result.allocator, self.nib, input, true, limits);
        defer self.result.allocator.free(reverse);
        // MetaPost's closed *stroke* opens the cycle and connects both sides
        // with round pen walks. Two disconnected directed envelopes can
        // cancel a region covered by a pen wider than the entire centerline.
        // These are construction joins, independent of an open path's cap.
        try self.contour(forward, reverse, if (closed) .round else self.options.cap, if (closed) null else self.ends);
    }
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
    if (!prep.same(before.curve.p3, after.curve.p0)) return error.InvalidPath;
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

fn validate(nib: []const Point, options: Options) Error!void {
    try (nibs.Nib{ .polygon = nib }).validate();
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (!std.math.isFinite(options.miter_limit) or options.miter_limit < 1) return error.InvalidStroke;
    if (options.max_segments == 0 or options.max_vertices < 3 or options.max_depth > 64 or nib.len > options.max_vertices) return error.StrokeWorkLimit;
}

fn build(allocator: Allocator, nib: []const Point, path: Path, options: Options, directed: bool) Error!Path {
    var builder = try Builder.init(allocator, nib, options);
    errdefer builder.result.deinit();
    if (directed and (nib.len == 1 or (nib.len == 2 and prep.same(nib[0], nib[1])))) return error.EllipticalPen;
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
            if (!prep.same(previous, begin)) {
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

const test_nib = [_]Point{
    .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 },
    .{ .x = 2, .y = 1 },   .{ .x = -2, .y = 1 },
};

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

fn testCrossing(first: Point, last: Point, point: Point) i32 {
    const cross = last.sub(first).cross(point.sub(first));
    if (first.y <= point.y and last.y > point.y and cross > 0) return 1;
    if (first.y > point.y and last.y <= point.y and cross < 0) return -1;
    return 0;
}

fn testWinding(path: Path, point: Point) i32 {
    var winding: i32 = 0;
    var current: Point = .zero;
    var start: Point = .zero;
    for (path.segments.items) |segment| switch (segment) {
        .move => |position| {
            current = position;
            start = position;
        },
        .line => |position| {
            winding += testCrossing(current, position, point);
            current = position;
        },
        .cubic => |controls| {
            const curve: g.Cubic = .{ .p0 = current, .p1 = controls.c1, .p2 = controls.c2, .p3 = controls.end };
            for (1..257) |index| {
                const next = curve.at(@as(f64, @floatFromInt(index)) / 256);
                winding += testCrossing(current, next, point);
                current = next;
            }
        },
        .close => {
            winding += testCrossing(current, start, point);
            current = start;
        },
    };
    return winding;
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

fn expectTestPoint(expected: Point, actual: Point) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 1e-12);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 1e-12);
}

fn expectTranslatedTestPath(expected: Path, actual: Path, origin: Point) !void {
    try std.testing.expectEqual(expected.segments.items.len, actual.segments.items.len);
    for (expected.segments.items, actual.segments.items) |wanted, found| {
        try std.testing.expectEqual(std.meta.activeTag(wanted), std.meta.activeTag(found));
        switch (wanted) {
            .move => |point| try expectTestPoint(point, found.move.sub(origin)),
            .line => |point| try expectTestPoint(point, found.line.sub(origin)),
            .cubic => |curve| {
                try expectTestPoint(curve.c1, found.cubic.c1.sub(origin));
                try expectTestPoint(curve.c2, found.cubic.c2.sub(origin));
                try expectTestPoint(curve.end, found.cubic.end.sub(origin));
            },
            .close => {},
        }
    }
}

test "exact offsets survive large origins while genuinely lost offsets still fail" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 20, .y = 10 }, .{ .x = 30, .y = 35 }, .{ .x = 60, .y = 40 });
    var single = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer single.deinit();
    var complete = try stroke(allocator, &test_nib, source, .{});
    defer complete.deinit();
    for ([_]f64{ 1e12, 1e15 }) |base| {
        const origin: Point = .{ .x = base, .y = -base };
        var translated = try source.transformed(allocator, g.Transform.translation(origin.x, origin.y));
        defer translated.deinit();
        var actual_single = try envelope(allocator, .{ .polygon = &test_nib }, translated, .{});
        defer actual_single.deinit();
        var actual_complete = try stroke(allocator, &test_nib, translated, .{});
        defer actual_complete.deinit();
        try expectTranslatedTestPath(single, actual_single, origin);
        try expectTranslatedTestPath(complete, actual_complete, origin);
    }
    var translated = try source.transformed(allocator, g.Transform.translation(1e15, -1e15));
    defer translated.deinit();
    const fractional = [_]Point{ .{ .x = -2.1, .y = -1 }, .{ .x = 2.1, .y = -1 }, .{ .x = 2.1, .y = 1 }, .{ .x = -2.1, .y = 1 } };
    try std.testing.expectError(error.PrecisionRange, envelope(allocator, .{ .polygon = &fractional }, translated, .{}));
    try std.testing.expectError(error.PrecisionRange, stroke(allocator, &fractional, translated, .{}));
    var point = Path.init(allocator);
    defer point.deinit();
    try point.moveTo(.{ .x = 1e20, .y = 1e20 });
    try std.testing.expectError(error.PrecisionRange, envelope(allocator, nibs.Nib.square(), point, .{}));
    try std.testing.expectError(error.PrecisionRange, stroke(allocator, nibs.Nib.square().polygon, point, .{}));
}

fn translatedLineCase(allocator: Allocator, closed: bool) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 20, .y = 0 });
    if (closed) {
        // Only the implicit return is a native line. The explicit cubic's
        // integer controls retain their vertical direction after translation.
        try source.cubicTo(.{ .x = 20, .y = 5 }, .{ .x = 20, .y = 15 }, .{ .x = 20, .y = 20 });
        try source.close();
    } else try source.lineTo(.{ .x = 20, .y = 20 });
    const options: Options = .{ .cap = .square, .join = .miter };
    var single = try envelope(allocator, .{ .polygon = &test_nib }, source, options);
    defer single.deinit();
    var complete = try stroke(allocator, &test_nib, source, options);
    defer complete.deinit();
    const origin: Point = .{ .x = 1e15, .y = -1e15 };
    var translated = try source.transformed(allocator, g.Transform.translation(origin.x, origin.y));
    defer translated.deinit();
    var actual_single = try envelope(allocator, .{ .polygon = &test_nib }, translated, options);
    defer actual_single.deinit();
    var actual_complete = try stroke(allocator, &test_nib, translated, options);
    defer actual_complete.deinit();
    try expectTranslatedTestPath(single, actual_single, origin);
    try expectTranslatedTestPath(complete, actual_complete, origin);
}

test "square caps on native lines retain exact directions at large origins" {
    try translatedLineCase(std.testing.allocator, false);
}

test "implicit closing lines retain exact directions at large origins" {
    try translatedLineCase(std.testing.allocator, true);
}

test "directed envelope retains the original knot and MetaPost full cubic controls" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .zero);
    try source.close();
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    // MetaPost 3.00 double: envelope (pensquare xscaled 4 yscaled 2)
    // of ((0,0)..controls (10,0) and (10,10)..cycle), rounded join.
    // Every retained knot/control is checked, including the original join.
    const expected = [_]Path.Segment{
        .{ .move = .{ .x = -2, .y = 1 } },
        .{ .line = .{ .x = -2, .y = -1 } },
        .{ .line = .{ .x = 2, .y = -1 } },
        .{ .cubic = .{ .c1 = .{ .x = 7, .y = -1 }, .c2 = .{ .x = 9.5, .y = 1.5 }, .end = .{ .x = 9.5, .y = 2.75 } } },
        .{ .line = .{ .x = 9.5, .y = 4.75 } },
        .{ .cubic = .{ .c1 = .{ .x = 9.5, .y = 31.0 / 6.0 }, .c2 = .{ .x = 83.0 / 9.0, .y = 49.0 / 9.0 }, .end = .{ .x = 26.0 / 3.0, .y = 49.0 / 9.0 } } },
        .{ .line = .{ .x = 14.0 / 3.0, .y = 49.0 / 9.0 } },
        .{ .cubic = .{ .c1 = .{ .x = 32.0 / 9.0, .y = 49.0 / 9.0 }, .c2 = .{ .x = 4.0 / 3.0, .y = 13.0 / 3.0 }, .end = .{ .x = -2, .y = 1 } } },
        .close,
    };
    try std.testing.expectEqual(expected.len, result.segments.items.len);
    for (expected, result.segments.items) |wanted, actual| {
        try std.testing.expectEqual(std.meta.activeTag(wanted), std.meta.activeTag(actual));
        switch (wanted) {
            .move => |point| try expectTestPoint(point, actual.move),
            .line => |point| try expectTestPoint(point, actual.line),
            .cubic => |curve| {
                try expectTestPoint(curve.c1, actual.cubic.c1);
                try expectTestPoint(curve.c2, actual.cubic.c2);
                try expectTestPoint(curve.end, actual.cubic.end);
            },
            .close => {},
        }
    }
    // The other directed side has different translated controls; it is not
    // the complete stroke or a reversal of the already-offset result.
    var reversed = try source.reverse(allocator);
    defer reversed.deinit();
    var other = try envelope(allocator, .{ .polygon = &test_nib }, reversed, .{});
    defer other.deinit();
    const other_cubics = [_]g.Cubic{
        .{ .p0 = .{ .x = 2, .y = -1 }, .p1 = .{ .x = 16.0 / 3.0, .y = 7.0 / 3.0 }, .p2 = .{ .x = 68.0 / 9.0, .y = 31.0 / 9.0 }, .p3 = .{ .x = 26.0 / 3.0, .y = 31.0 / 9.0 } },
        .{ .p0 = .{ .x = 14.0 / 3.0, .y = 31.0 / 9.0 }, .p1 = .{ .x = 47.0 / 9.0, .y = 31.0 / 9.0 }, .p2 = .{ .x = 5.5, .y = 19.0 / 6.0 }, .p3 = .{ .x = 5.5, .y = 2.75 } },
        .{ .p0 = .{ .x = 5.5, .y = 4.75 }, .p1 = .{ .x = 5.5, .y = 3.5 }, .p2 = .{ .x = 3, .y = 1 }, .p3 = .{ .x = -2, .y = 1 } },
    };
    var index: usize = 0;
    var current: Point = .zero;
    for (other.segments.items) |segment| switch (segment) {
        .move, .line => |point| current = point,
        .cubic => |curve| {
            try std.testing.expect(index < other_cubics.len);
            const wanted = other_cubics[index];
            try expectTestPoint(wanted.p0, current);
            try expectTestPoint(wanted.p1, curve.c1);
            try expectTestPoint(wanted.p2, curve.c2);
            try expectTestPoint(wanted.p3, curve.end);
            current = curve.end;
            index += 1;
        },
        .close => {},
    };
    try std.testing.expectEqual(other_cubics.len, index);
}

test "clockwise directed cycles preserve MetaPost first offset correction" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 20, .y = 0 });
    try source.cubicTo(.{ .x = 20, .y = -11 }, .{ .x = 11, .y = -20 }, .{ .x = 0, .y = -20 });
    try source.cubicTo(.{ .x = -11, .y = -20 }, .{ .x = -20, .y = -11 }, .{ .x = -20, .y = 0 });
    try source.cubicTo(.{ .x = -20, .y = 11 }, .{ .x = -11, .y = 20 }, .{ .x = 0, .y = 20 });
    try source.cubicTo(.{ .x = 11, .y = 20 }, .{ .x = 20, .y = 11 }, .{ .x = 20, .y = 0 });
    try source.close();
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    // Independent mp_offset_prep behavior: the seam's change is +3, not -1.
    // These three pen edges form a visible stub, not an ignorable retracing.
    const start = [_]Point{ .{ .x = 18, .y = -1 }, .{ .x = 22, .y = -1 }, .{ .x = 22, .y = 1 }, .{ .x = 18, .y = 1 } };
    try expectTestPoint(start[0], result.segments.items[0].move);
    for (start[1..], result.segments.items[1..4]) |wanted, actual| try expectTestPoint(wanted, actual.line);
    const expected = [_]g.Cubic{
        .{ .p0 = .{ .x = 18, .y = 1 }, .p1 = .{ .x = 18, .y = -10 }, .p2 = .{ .x = 9, .y = -19 }, .p3 = .{ .x = -2, .y = -19 } },
        .{ .p0 = .{ .x = 2, .y = -19 }, .p1 = .{ .x = -9, .y = -19 }, .p2 = .{ .x = -18, .y = -10 }, .p3 = .{ .x = -18, .y = 1 } },
        .{ .p0 = .{ .x = -18, .y = -1 }, .p1 = .{ .x = -18, .y = 10 }, .p2 = .{ .x = -9, .y = 19 }, .p3 = .{ .x = 2, .y = 19 } },
        .{ .p0 = .{ .x = -2, .y = 19 }, .p1 = .{ .x = 9, .y = 19 }, .p2 = .{ .x = 18, .y = 10 }, .p3 = .{ .x = 18, .y = -1 } },
    };
    var current: Point = .zero;
    var index: usize = 0;
    for (result.segments.items) |segment| switch (segment) {
        .move, .line => |point| current = point,
        .cubic => |curve| {
            try std.testing.expect(index < expected.len);
            try expectTestPoint(expected[index].p0, current);
            try expectTestPoint(expected[index].p1, curve.c1);
            try expectTestPoint(expected[index].p2, curve.c2);
            try expectTestPoint(expected[index].p3, curve.end);
            current = curve.end;
            index += 1;
        },
        .close => {},
    };
    try std.testing.expectEqual(expected.len, index);
    try std.testing.expect(testWinding(result, .{ .x = 21, .y = 0 }) != 0);
    var bevel = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .bevel });
    defer bevel.deinit();
    try std.testing.expectEqual(@as(i32, 0), testWinding(bevel, .{ .x = 21, .y = 0 }));
}

test "open directed envelopes reuse every cap and join of complete strokes" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 20 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| for ([_]styles.Join{ .miter, .round, .bevel }) |join| {
        const options: Options = .{ .cap = cap, .join = join };
        var directed = try envelope(allocator, .{ .polygon = &test_nib }, source, options);
        defer directed.deinit();
        var complete = try stroke(allocator, &test_nib, source, options);
        defer complete.deinit();
        try std.testing.expectEqualDeep(complete.segments.items, directed.segments.items);
    };
}

test "directed envelope follows MetaPost singleton and zero segment rules" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 5, .y = 7 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| {
        var point = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .cap = cap });
        defer point.deinit();
        try std.testing.expectEqual(@as(usize, if (cap == .round) 5 else 2), point.segmentCount());
        try expectTestPoint(.{ .x = 3, .y = 6 }, point.segments.items[0].move);
    }
    try source.lineTo(.{ .x = 5, .y = 7 });
    for ([_]styles.Cap{ .butt, .round, .square }) |cap| {
        var zero = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .cap = cap });
        defer zero.deinit();
        try std.testing.expectEqual(@as(usize, 2), zero.segmentCount());
        try std.testing.expectEqual(Point{ .x = 3, .y = 6 }, zero.bounds().?.min);
        try std.testing.expectEqual(zero.bounds().?.min, zero.bounds().?.max);
    }
    try source.close();
    for ([_]styles.Join{ .miter, .round, .bevel }) |join| {
        var closed = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = join });
        defer closed.deinit();
        try std.testing.expectEqual(@as(usize, if (join == .round) 5 else 2), closed.segmentCount());
    }
}

test "directed envelope rejects ellipse and point pens but accepts line pens" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    var empty = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.segments.items.len);
    try std.testing.expectError(error.EllipticalPen, envelope(allocator, nibs.Nib.circle(), source, .{}));
    try std.testing.expectError(error.EllipticalPen, envelope(allocator, .{ .polygon = &.{.zero} }, source, .{}));
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 0, .y = 10 });
    var line = try envelope(allocator, .{ .polygon = &.{ .zero, .{ .x = 2, .y = 0 } } }, source, .{});
    defer line.deinit();
    try std.testing.expect(testWinding(line, .{ .x = 1, .y = 5 }) != 0);
    try source.segments.append(allocator, .{ .cubic = .{ .c1 = .zero, .c2 = .zero, .end = .{ .x = std.math.inf(f64), .y = 0 } } });
    try std.testing.expectError(error.NonFinite, envelope(allocator, .{ .polygon = &test_nib }, source, .{}));
}

test "only directed envelope clamps finite miter limits as MetaPost does" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 5, .y = 5 });
    var baseline = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .miter, .miter_limit = 1 });
    defer baseline.deinit();
    for ([_]f64{ -3, 0, 0.5 }) |limit| {
        var clamped = try envelope(allocator, .{ .polygon = &test_nib }, source, .{ .join = .miter, .miter_limit = limit });
        defer clamped.deinit();
        try std.testing.expectEqualDeep(baseline.segments.items, clamped.segments.items);
        try std.testing.expectError(error.InvalidStroke, stroke(allocator, &test_nib, source, .{ .miter_limit = limit }));
    }
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |limit| {
        try std.testing.expectError(error.InvalidStroke, envelope(allocator, .{ .polygon = &test_nib }, source, .{ .miter_limit = limit }));
    }
}

fn allocationCaseDirected(allocator: Allocator) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .zero);
    try source.close();
    try source.moveTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 30, .y = 0 });
    try source.moveTo(.{ .x = 40, .y = 0 });
    var result = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer result.deinit();
    source.segments.clearRetainingCapacity();
    try std.testing.expect(result.segments.items.len != 0);
}

test "directed envelope snapshots and temporary storage survive all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCaseDirected, .{});
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
