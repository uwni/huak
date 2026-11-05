//! Polygon-pen offset preparation, derived from MetaPost's public-domain
//! offset_prep/fin_offset_prep in mp.w, TeX Live commit
//! abf5274f6f69d0a23fcca267e631363d0a1fbc64.
//!
//! A polygon vertex remains the offset until the quadratic Bézier derivative
//! crosses a pen-edge direction. Split at those roots and translate the exact
//! cubic pieces, rather than flattening the centerline. The root calculation
//! uses huak's shared f64 polynomial solver instead of MetaPost's arithmetic.
const std = @import("std");
const g = @import("../../geometry.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
pub const Error = Allocator.Error || error{ NonFinite, ZeroVector, StrokeWorkLimit, InvalidNib, InvalidParameter };

pub const Piece = struct { curve: g.Cubic, cubic: bool };
pub const Span = struct {
    curve: g.Cubic,
    cubic: bool,
    offset: usize,
    first: bool,
    middle: Point,
    start_direction: Point,
    end_direction: Point,
    turn: i2,
};
pub const Limits = struct { max_segments: usize, max_vertices: usize, max_depth: usize };

/// mp.w keeps derivative coefficients independently of position subdivision.
/// A narrow interval can have meaningful tangent changes even when subtracting
/// its translated position controls would erase their small differences.
const Derivative = struct {
    controls: [3]Point,

    fn init(curve: g.Cubic) Error!Derivative {
        var controls = [_]Point{ curve.p1.sub(curve.p0), curve.p2.sub(curve.p1), curve.p3.sub(curve.p2) };
        var scale: f64 = 0;
        for (controls) |value| {
            if (!value.isFinite()) return error.NonFinite;
            scale = @max(scale, @max(@abs(value.x), @abs(value.y)));
        }
        if (scale != 0) for (&controls) |*value| {
            value.* = .{ .x = value.x / scale, .y = value.y / scale };
        };
        return .{ .controls = controls };
    }
    fn split(self: Derivative, time: f64) struct { left: Derivative, right: Derivative } {
        const first = self.controls[0].lerp(self.controls[1], time);
        const last = self.controls[1].lerp(self.controls[2], time);
        const at = first.lerp(last, time);
        return .{
            .left = .{ .controls = .{ self.controls[0], first, at } },
            .right = .{ .controls = .{ at, last, self.controls[2] } },
        };
    }
    fn restricted(self: Derivative, begin: f64, stop: f64) Derivative {
        if (begin == 0 and stop == 1) return self;
        if (begin == 0) return self.split(stop).left;
        return self.split(begin).right.split((stop - begin) / (1 - begin)).left;
    }
    fn start(self: Derivative) Error!Point {
        for (self.controls) |value| if (!zero(value)) return value.normalized();
        return error.ZeroVector;
    }
    fn end(self: Derivative) Error!Point {
        for (0..3) |index| {
            const value = self.controls[2 - index];
            if (!zero(value)) return value.normalized();
        }
        return error.ZeroVector;
    }
    fn middle(self: Derivative) Error!Point {
        const value = self.controls[0].lerp(self.controls[1], 0.5).lerp(self.controls[1].lerp(self.controls[2], 0.5), 0.5);
        return if (zero(value)) self.start() else value.normalized();
    }
};

/// Three distinct interior candidates cannot all be zeros of a nonzero
/// quadratic derivative. Keep construction caps away from original corners.
pub fn interiorCut(curve: g.Cubic) Error!f64 {
    const derivative = try Derivative.init(curve);
    for ([_]f64{ 0.5, 0.25, 0.75 }) |time| {
        if (!zero(derivative.split(time).left.controls[2])) return time;
    }
    return error.ZeroVector;
}

fn endpointTangent(piece: Piece, from_start: bool) Error!?Point {
    // A native line has a nonzero chord derivative, irrespective of the
    // endpoint-control representation used for its internal cubic storage.
    const first = if (!piece.cubic or from_start) piece.curve.p0 else piece.curve.p2;
    const last = if (!piece.cubic or !from_start) piece.curve.p3 else piece.curve.p1;
    const tangent = last.sub(first);
    if (!tangent.isFinite()) return error.NonFinite;
    if (zero(tangent)) return null;
    if (!exactDifference(last.x, first.x, tangent.x) or !exactDifference(last.y, first.y, tangent.y)) return null;
    return tangent;
}

fn exactDifference(last: f64, first: f64, difference: f64) bool {
    @setFloatMode(.strict);
    const virtual_first = difference - last;
    const residual = (last - (difference - virtual_first)) + (-first - virtual_first);
    return std.math.isFinite(residual) and residual == 0;
}

fn sameRay(first: Point, last: Point) bool {
    @setFloatMode(.strict);
    if (zero(first) or zero(last)) return false;
    if (first.x == 0 or last.x == 0) return first.x == 0 and last.x == 0 and (first.y > 0) == (last.y > 0);
    if (first.y == 0 or last.y == 0) return first.y == 0 and last.y == 0 and (first.x > 0) == (last.x > 0);
    if ((first.x > 0) != (last.x > 0)) return false;
    const forward = first.x * last.y;
    const backward = first.y * last.x;
    if (std.math.isFinite(forward) and std.math.isFinite(backward) and forward != backward) return false;
    // Each product of two binary64 values has at most 106 significant bits.
    // binary128 holds these products exactly, including the smallest/largest
    // finite binary64 exponents. No tolerance or normalization hides a corner.
    return @as(f128, first.x) * @as(f128, last.y) == @as(f128, first.y) * @as(f128, last.x);
}

/// First original knot with proven nonzero, exactly same-ray tangents.
/// Dead pieces do not introduce a corner. Zero cubic endpoint derivatives
/// remain ineligible even when a higher-order limiting direction exists.
pub fn smoothKnot(pieces: []const Piece) Error!?usize {
    var previous = pieces.len;
    while (previous != 0) {
        previous -= 1;
        if (!stationary(pieces[previous].curve)) break;
    }
    if (pieces.len == 0 or stationary(pieces[previous].curve)) return null;
    for (pieces, 0..) |piece, index| {
        if (stationary(piece.curve)) continue;
        const incoming_piece = pieces[previous];
        if (same(incoming_piece.curve.p3, piece.curve.p0)) {
            const incoming = try endpointTangent(incoming_piece, false);
            const outgoing = try endpointTangent(piece, true);
            if (incoming != null and outgoing != null and sameRay(incoming.?, outgoing.?)) return index;
        }
        previous = index;
    }
    return null;
}

pub fn zero(point: Point) bool {
    return point.x == 0 and point.y == 0;
}

pub fn same(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

pub fn stationary(curve: g.Cubic) bool {
    return same(curve.p0, curve.p1) and same(curve.p0, curve.p2) and same(curve.p0, curve.p3);
}

pub fn startDirection(curve: g.Cubic) Error!Point {
    for ([_]Point{ curve.p1, curve.p2, curve.p3 }) |point| {
        const difference = point.sub(curve.p0);
        if (!difference.isFinite()) return error.NonFinite;
        if (!zero(difference)) return difference.normalized();
    }
    return error.ZeroVector;
}

pub fn endDirection(curve: g.Cubic) Error!Point {
    return (try startDirection(curve.reversed())).scale(-1);
}

/// Half-open support sectors select the CCW end of a flat support face,
/// matching get_turn_amt: d_(k-1) <= direction < d_k.
pub fn support(nib: []const Point, direction: Point) Error!usize {
    return supportNear(nib, direction, 0);
}

fn supportNear(nib: []const Point, direction: Point, initial: usize) Error!usize {
    if (nib.len == 0 or initial >= nib.len) return error.InvalidNib;
    const tangent = try direction.normalized();
    const normal: Point = .{ .x = tangent.y, .y = -tangent.x };
    var best = initial;
    if (!nib[best].isFinite()) return error.NonFinite;
    for (0..nib.len) |_| {
        var next = best;
        for ([_]usize{ (best + 1) % nib.len, (best + nib.len - 1) % nib.len }) |index| {
            if (!nib[index].isFinite()) return error.NonFinite;
            const height = projectionOrder(nib[index], nib[next], normal);
            if (height > 0 or (height == 0 and projectionOrder(nib[index], nib[next], tangent) > 0)) {
                next = index;
            }
        }
        if (next == best) return best;
        best = next;
    }
    return error.InvalidNib;
}

/// Compare two support projections without subtracting a common, distant nib
/// origin first. That subtraction can turn adjacent vertices into an equal
/// pair and stop the convex support walk on a nonmaximal plateau.
fn projectionOrder(a: Point, b: Point, direction: Point) i2 {
    @setFloatMode(.strict);
    const relative = a.sub(b);
    const value = relative.dot(direction);
    const magnitude = (@abs(a.x) + @abs(b.x)) * @abs(direction.x) + (@abs(a.y) + @abs(b.y)) * @abs(direction.y);
    const bound = magnitude * (8 * std.math.floatEps(f64));
    // The filter covers the rounded differences, products and sum. Fall back
    // for overflow, underflow or cancellation; no geometric epsilon decides
    // which vertex wins a support sector.
    if (std.math.isFinite(value) and std.math.isFinite(bound) and bound >= std.math.floatMin(f64) and @abs(value) > bound) return sign(value);

    // Each product of two finite binary64 values is exact in binary128:
    // <=106 significant bits, with exponents [-2148,2048], all in range.
    // A four-term TwoSum expansion preserves cancellation across arbitrary
    // exponent gaps; one binary128 subtraction alone would not suffice.
    const terms = [_]f128{
        @as(f128, a.x) * @as(f128, direction.x),
        @as(f128, a.y) * @as(f128, direction.y),
        -@as(f128, b.x) * @as(f128, direction.x),
        -@as(f128, b.y) * @as(f128, direction.y),
    };
    var expansion: [4]f128 = undefined;
    var length: usize = 0;
    for (terms) |term| {
        var sum = term;
        var next: [4]f128 = undefined;
        var count: usize = 0;
        for (expansion[0..length]) |component| {
            const total = sum + component;
            const virtual = total - sum;
            const residual = (sum - (total - virtual)) + (component - virtual);
            if (residual != 0) {
                next[count] = residual;
                count += 1;
            }
            sum = total;
        }
        if (sum != 0) {
            next[count] = sum;
            count += 1;
        }
        expansion = next;
        length = count;
    }
    if (length == 0) return 0;
    return if (expansion[length - 1] > 0) 1 else -1;
}

test "support walk crosses rounded projection plateaus without losing a pen side" {
    const nib = [_]Point{
        .{ .x = -1, .y = 0 },      .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 },
        .{ .x = 0x1p-54, .y = 1 }, .{ .x = 0, .y = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), try supportNear(&nib, .{ .x = 0, .y = -1 }, 3));
    try std.testing.expectEqual(@as(usize, 4), try supportNear(&nib, .{ .x = -1, .y = 0 }, 3));
    try std.testing.expectEqual(@as(usize, 2), try supportNear(&nib, .{ .x = 0, .y = 1 }, 4));
}

test "support projection sign retains extreme cancellation and subnormal products" {
    const a: Point = .{ .x = 0x1p1000, .y = 2 };
    const b: Point = .{ .x = 1, .y = 0x1p1000 };
    const direction: Point = .{ .x = 1, .y = 1 };
    try std.testing.expectEqual(@as(i2, 1), projectionOrder(a, b, direction));
    try std.testing.expectEqual(@as(i2, -1), projectionOrder(b, a, direction));
    const tiny: Point = .{ .x = std.math.floatTrueMin(f64), .y = 0 };
    try std.testing.expectEqual(@as(i2, 1), projectionOrder(tiny, .zero, tiny));
    try std.testing.expectEqual(@as(i2, 0), projectionOrder(a, a, direction));
}

fn sign(value: f64) i2 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

fn turnDirection(curve: g.Cubic) Error!i2 {
    const first = try startDirection(curve);
    const last = try endDirection(curve);
    var turn = sign(first.cross(last));
    if (turn == 0) {
        const chord = curve.p3.sub(curve.p0);
        if (!chord.isFinite()) return error.NonFinite;
        if (!zero(chord)) {
            const unit = try chord.normalized();
            turn = sign(first.cross(unit) + unit.cross(last));
        }
    }
    // MetaPost's tie for an exactly indeterminate cusp is lexicographic.
    if (turn == 0) turn = if (first.x != 0) sign(first.x) else sign(first.y);
    return turn;
}

fn cutsFor(allocator: Allocator, nib: []const Point, derivative: Derivative, cuts: *std.ArrayList(f64), limits: Limits) Error!void {
    for (nib, 0..) |vertex, index| {
        const edge = nib[(index + 1) % nib.len].sub(vertex);
        if (zero(edge)) continue;
        const unit = try edge.normalized();
        var coefficients: [3]f64 = undefined;
        for (derivative.controls, 0..) |value, i| coefficients[i] = value.cross(unit);
        var roots: [2]f64 = undefined;
        const count = g.quadraticRoots(coefficients[0] - 2 * coefficients[1] + coefficients[2], 2 * (coefficients[1] - coefficients[0]), coefficients[0], &roots);
        for (roots[0..count]) |root| if (root > 0 and root < 1) {
            if (cuts.items.len >= limits.max_vertices) return error.StrokeWorkLimit;
            try cuts.append(allocator, root);
        };
    }
    std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
    var unique: usize = 0;
    for (cuts.items) |cut| if (unique == 0 or cut != cuts.items[unique - 1]) {
        cuts.items[unique] = cut;
        unique += 1;
    };
    cuts.shrinkRetainingCapacity(unique);
}

pub fn spans(allocator: Allocator, nib: []const Point, pieces: []const Piece, reversed: bool, limits: Limits) Error![]Span {
    var result: std.ArrayList(Span) = .empty;
    errdefer result.deinit(allocator);
    var cuts: std.ArrayList(f64) = .empty;
    defer cuts.deinit(allocator);
    for (0..pieces.len) |index| {
        const piece = pieces[if (reversed) pieces.len - 1 - index else index];
        const original = if (reversed) piece.curve.reversed() else piece.curve;
        if (stationary(original)) continue;
        const derivative = try Derivative.init(original);
        cuts.clearRetainingCapacity();
        if (piece.cubic) try cutsFor(allocator, nib, derivative, &cuts, limits);
        try cuts.append(allocator, 1);
        var previous: f64 = 0;
        var group_start: f64 = 0;
        var groups: usize = 0;
        var first = true;
        const turn = try turnDirection(original);
        for (cuts.items) |cut| {
            const begin = previous;
            previous = cut;
            if (cut <= begin) continue;
            const directions = derivative.restricted(begin, cut);
            const middle = try directions.middle();
            const offset = try supportNear(nib, middle, if (result.items.len == 0) 0 else result.items[result.items.len - 1].offset);
            if (!first and result.items[result.items.len - 1].offset == offset) {
                // Parallel *and* antiparallel edge roots are candidates. Only
                // actual support changes belong in the envelope spec. Keep a
                // single canonical restriction of the original cubic when a
                // candidate does not change its offset.
                const previous_span = &result.items[result.items.len - 1];
                const joined = if (group_start == 0 and cut == 1) original else try original.trimmed(group_start, cut);
                const joined_directions = derivative.restricted(group_start, cut);
                previous_span.curve = joined;
                previous_span.middle = try joined_directions.middle();
                previous_span.end_direction = try joined_directions.end();
                continue;
            }
            if (result.items.len >= limits.max_segments) return error.StrokeWorkLimit;
            groups += 1;
            if (limits.max_depth < @bitSizeOf(usize) and groups > (@as(usize, 1) << @intCast(limits.max_depth))) return error.StrokeWorkLimit;
            group_start = begin;
            const canonical = if (begin == 0 and cut == 1) original else try original.trimmed(begin, cut);
            try result.append(allocator, .{
                .curve = canonical,
                .cubic = piece.cubic,
                .offset = offset,
                .first = first,
                .middle = middle,
                .start_direction = try directions.start(),
                .end_direction = try directions.end(),
                .turn = turn,
            });
            first = false;
        }
    }
    return result.toOwnedSlice(allocator);
}

test "scaled derivative subdivision retains directions lost by position subtraction" {
    const curve: g.Cubic = .{
        .p0 = .{ .x = 1e9 + 10, .y = -10 },
        .p1 = .{ .x = 1e9 - 10.0 / 3.0, .y = 10 },
        .p2 = .{ .x = 1e9 - 10.0 / 3.0, .y = -10 },
        .p3 = .{ .x = 1e9 + 10, .y = 10 },
    };
    const derivative = try Derivative.init(curve);
    const narrow = derivative.restricted(0.5, 0.5 + 1e-9);
    try std.testing.expect((try narrow.middle()).x > 0.99);
    const position = try curve.trimmed(0.5, 0.5 + 1e-9);
    try std.testing.expectEqual(@as(f64, 0), position.derivative(0.5).x);
    try std.testing.expectEqual(@as(f64, 0.25), try interiorCut(curve));
}

fn testLine(first: Point, last: Point) Piece {
    return .{ .curve = .{ .p0 = first, .p1 = first, .p2 = last, .p3 = last }, .cubic = false };
}

test "smooth knots skip dead pieces and retain a middle same-ray node" {
    const a: Point = .zero;
    const b: Point = .{ .x = 10, .y = 0 };
    const c: Point = .{ .x = 20, .y = 0 };
    const d: Point = .{ .x = 0, .y = 20 };
    const pieces = [_]Piece{ testLine(a, b), testLine(b, b), testLine(b, c), testLine(c, d), testLine(d, a) };
    try std.testing.expectEqual(@as(?usize, 2), try smoothKnot(&pieces));
    const empty = [_]Piece{testLine(a, a)};
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&empty));
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&.{}));
}

test "smooth knots reject reversal rays zero derivatives and tiny true corners" {
    const a: Point = .zero;
    const b: Point = .{ .x = 10, .y = 0 };
    const c: Point = .{ .x = 20, .y = 0 };
    const d: Point = .{ .x = 0, .y = 20 };
    const reversal = [_]Piece{ testLine(a, b), testLine(b, a) };
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&reversal));
    const stationary_derivative = [_]Piece{
        .{ .curve = .{ .p0 = a, .p1 = .{ .x = 5, .y = 0 }, .p2 = b, .p3 = b }, .cubic = true },
        testLine(b, c),
        testLine(c, d),
        testLine(d, a),
    };
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&stationary_derivative));
    const epsilon = std.math.floatEps(f64);
    const first: Point = .{ .x = 1, .y = 1 - epsilon };
    const last: Point = .{ .x = 1 + epsilon, .y = 1 };
    try std.testing.expectEqual(first.x * last.y, first.y * last.x);
    try std.testing.expect(!sameRay(first, last));
    const almost = [_]Piece{ testLine(first.scale(-1), a), testLine(a, last), testLine(last, first.scale(-1)) };
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&almost));
    const inexact_corner = [_]Piece{
        testLine(.{ .x = -1, .y = 0 }, .{ .x = 1e16, .y = 1e16 }),
        testLine(.{ .x = 1e16, .y = 1e16 }, .{ .x = 2e16, .y = 2e16 }),
        testLine(.{ .x = 2e16, .y = 2e16 }, .{ .x = -1, .y = 0 }),
    };
    // Rounded tangent subtraction would hide this actual corner before even
    // the wide product comparison; it must remain conservatively ineligible.
    try std.testing.expectEqual(@as(?usize, null), try smoothKnot(&inexact_corner));
    try std.testing.expect(!sameRay(.{ .x = 1e-300, .y = 1e-300 }, .{ .x = 1e-300, .y = 2e-300 }));
    try std.testing.expect(sameRay(.{ .x = 1e300, .y = 1e300 }, .{ .x = 2e300, .y = 2e300 }));
}
