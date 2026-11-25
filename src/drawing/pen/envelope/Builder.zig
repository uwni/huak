//! The tracing state of a polygon-pen envelope and its per-subpath tracing for complete strokes and directed envelopes: offsets, pen walks, caps and joins.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const styles = @import("../stroke.zig");
const prep = @import("prepare.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
const pen_envelope = @import("../envelope.zig");
const Builder = @This();
const Options = pen_envelope.Options;
const Error = pen_envelope.Error;
const validate = pen_envelope.validate;

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
pub fn offsetPoint(self: *const Builder, point: Point, displacement: Point) Error!Point {
    return .{
        .x = try self.addCoordinate(point.x, displacement.x),
        .y = try self.addCoordinate(point.y, displacement.y),
    };
}
pub fn move(self: *Builder, point: Point) Error!void {
    try self.check(point, 1);
    try self.result.moveTo(point);
}
pub fn line(self: *Builder, point: Point) Error!void {
    if (point.eql(self.result.current.?)) return;
    if (self.segments >= self.options.max_segments) return error.StrokeWorkLimit;
    try self.check(point, 1);
    try self.result.lineTo(point);
    self.segments += 1;
}
pub fn curve(self: *Builder, span: prep.Span) Error!void {
    const offset = self.nib[span.offset];
    const cubic = span.curve;
    // The derivative spec can retain an offset change at an interval
    // whose position controls rounded to one point. Keep its pen walk,
    // while removing the dead geometric cubic as offset_prep does.
    if (prep.stationary(cubic)) return;
    if (!span.cubic) return self.line(try self.offsetPoint(cubic.p3, offset));
    try self.cubicTo(try self.offsetPoint(cubic.p1, offset), try self.offsetPoint(cubic.p2, offset), try self.offsetPoint(cubic.p3, offset));
}
pub fn cubicTo(self: *Builder, first: Point, second: Point, last: Point) Error!void {
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
pub fn transition(self: *Builder, before: prep.Span, after: prep.Span, cap: ?styles.Cap, initial: bool) Error!void {
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

/// Independently selected real or artificial section caps.
pub const Ends = struct {
    start: styles.Cap,
    end: styles.Cap,
};
