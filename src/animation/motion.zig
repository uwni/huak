//! Arc-length positioning for the static fallback of native motion animation.
//! Geometry only: no renderer, Typst types, or serialized graphics are involved.
const std = @import("std");
const g = @import("../drawing/geometry.zig");
const Path = @import("../drawing/path/Path.zig");

pub const Pose = struct { position: g.Point, angle: f64 };
pub const Error = std.mem.Allocator.Error || error{
    InvalidFraction,
    InvalidPath,
    NonFinite,
    LengthWorkLimit,
};

/// Control-polygon/chord bounds are adaptively narrowed until the total gap
/// across the path is <= 1e-6 + 1e-7 * total control-polygon length, in path
/// units. Their midpoint estimates arc length; inversion uses tighter bounds.
/// At most 262144 refinement visits, 65536 leaves, and depth 24 are allowed;
/// difficult inputs return LengthWorkLimit instead of silently losing accuracy.
pub const absolute_length_tolerance: f64 = 1e-6;
pub const relative_length_tolerance: f64 = 1e-7;
const max_visits: usize = 262144;
const max_leaves: usize = 65536;
const max_depth: usize = 24;

const Piece = struct { curve: g.Cubic, length: f64 };
const Work = struct {
    visits: usize = 0,
    fn visit(self: *Work) Error!void {
        self.visits += 1;
        if (self.visits > max_visits) return error.LengthWorkLimit;
    }
};

fn finite(value: f64) Error!f64 {
    if (!std.math.isFinite(value)) return error.NonFinite;
    return value;
}
fn estimates(curve: g.Cubic) Error!struct { lower: f64, upper: f64 } {
    const lower = try finite(curve.p0.distance(curve.p3));
    const upper = try finite(curve.p0.distance(curve.p1) + curve.p1.distance(curve.p2) + curve.p2.distance(curve.p3));
    return .{ .lower = lower, .upper = @max(lower, upper) };
}
fn refine(
    allocator: std.mem.Allocator,
    pieces: ?*std.ArrayList(Piece),
    curve: g.Cubic,
    absolute_budget: f64,
    relative_budget: f64,
    depth: usize,
    work: *Work,
) Error!f64 {
    try work.visit();
    if (!curve.isFinite()) return error.NonFinite;
    const bounds = try estimates(curve);
    if (bounds.upper - bounds.lower <= absolute_budget + relative_budget * bounds.upper) {
        const length = bounds.lower + (bounds.upper - bounds.lower) * 0.5;
        if (pieces) |leaves| {
            if (length > 0) {
                if (leaves.items.len >= max_leaves) return error.LengthWorkLimit;
                try leaves.append(allocator, .{ .curve = curve, .length = length });
            }
        }
        return length;
    }
    if (depth >= max_depth) return error.LengthWorkLimit;
    const halves = curve.split(0.5);
    const left = try refine(allocator, pieces, halves.left, absolute_budget * 0.5, relative_budget, depth + 1, work);
    const right = try refine(allocator, pieces, halves.right, absolute_budget * 0.5, relative_budget, depth + 1, work);
    return finite(left + right);
}

fn validate(segments: []const Path.Segment) Error!usize {
    if (segments.len == 0 or segments[0] != .move) return error.InvalidPath;
    var active = false;
    var count: usize = 0;
    for (segments) |segment| switch (segment) {
        .move => |point| {
            if (!point.isFinite()) return error.NonFinite;
            active = true;
        },
        .line => |point| {
            if (!active) return error.InvalidPath;
            if (!point.isFinite()) return error.NonFinite;
            count += 1;
        },
        .cubic => |curve| {
            if (!active) return error.InvalidPath;
            if (!curve.c1.isFinite() or !curve.c2.isFinite() or !curve.end.isFinite()) return error.NonFinite;
            count += 1;
        },
        .close => {
            if (!active) return error.InvalidPath;
            active = false;
            count += 1;
        },
    };
    return count;
}

fn direction(curve: g.Cubic, t: f64) g.Point {
    const direct = curve.derivative(t);
    if (direct.isFinite() and (direct.x != 0 or direct.y != 0)) return direct;
    // Repeated endpoint controls have a well-defined one-sided tangent. At an
    // interior stationary point prefer the outgoing direction, then incoming.
    if (t == 0) {
        for ([_]g.Point{ curve.p1, curve.p2, curve.p3 }) |point| {
            const delta = point.sub(curve.p0);
            if (delta.x != 0 or delta.y != 0) return delta;
        }
    } else if (t == 1) {
        for ([_]g.Point{ curve.p2, curve.p1, curve.p0 }) |point| {
            const delta = curve.p3.sub(point);
            if (delta.x != 0 or delta.y != 0) return delta;
        }
    } else {
        const at = curve.at(t);
        const after = curve.at(@min(1.0, t + 1e-6)).sub(at);
        if (after.x != 0 or after.y != 0) return after;
        return at.sub(curve.at(@max(0.0, t - 1e-6)));
    }
    return .zero;
}
fn pose(curve: g.Cubic, t: f64) Error!Pose {
    const position = curve.at(t);
    const tangent = direction(curve, t);
    if (!position.isFinite() or !tangent.isFinite()) return error.NonFinite;
    return .{ .position = position, .angle = if (tangent.x == 0 and tangent.y == 0) 0 else std.math.atan2(tangent.y, tangent.x) };
}
fn invert(allocator: std.mem.Allocator, piece: Piece, distance: f64, work: *Work) Error!Pose {
    if (distance <= 0) return pose(piece.curve, 0);
    if (distance >= piece.length) return pose(piece.curve, 1);
    var low: f64 = 0;
    var high: f64 = 1;
    // Fraction is an arc-length fraction, not Bezier time. Even an exactly
    // straight cubic can have x(t)=t^3, so chord length alone cannot invert t.
    const budget = @max(1e-10, @min(absolute_length_tolerance * 0.01, piece.length * 1e-9));
    for (0..48) |_| {
        const middle = (low + high) * 0.5;
        const prefix = piece.curve.split(middle).left;
        const length = try refine(allocator, null, prefix, budget, 1e-9, 0, work);
        if (length < distance) low = middle else high = middle;
    }
    return pose(piece.curve, (low + high) * 0.5);
}

/// fraction is total drawable arc length in [0,1]. Moveto jumps consume no
/// length; close contributes its line back to that subpath's starting point.
/// At an exact join use the preceding positive-length segment's incoming
/// tangent, including before a moveto, matching SVG animateMotion. At fraction
/// 1 use the final positive-length segment's endpoint. Entirely zero-length
/// paths use the first drawable segment's start, or the last moveto if no
/// drawing command occurs, with angle zero. The pose is independent of the path.
pub fn motionPose(allocator: std.mem.Allocator, segments: []const Path.Segment, fraction: f64) Error!Pose {
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidFraction;
    const draw_count = try validate(segments);
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(allocator);
    var work: Work = .{};
    const budget = absolute_length_tolerance / @as(f64, @floatFromInt(@max(@as(usize, 1), draw_count)));
    var current = segments[0].move;
    var start = current;
    var first_draw_start: ?g.Point = null;
    var total: f64 = 0;
    for (segments) |segment| {
        const curve: g.Cubic = switch (segment) {
            .move => |point| {
                current = point;
                start = point;
                continue;
            },
            .line => |point| blk: {
                const line = g.Cubic.line(current, point);
                current = point;
                break :blk line;
            },
            .cubic => |c| blk: {
                const result: g.Cubic = .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end };
                current = c.end;
                break :blk result;
            },
            .close => blk: {
                const line = g.Cubic.line(current, start);
                current = start;
                break :blk line;
            },
        };
        if (first_draw_start == null) first_draw_start = curve.p0;
        total = try finite(total + try refine(allocator, &pieces, curve, budget, relative_length_tolerance, 0, &work));
    }
    if (total == 0) return .{ .position = first_draw_start orelse current, .angle = 0 };
    if (fraction == 1) return pose(pieces.items[pieces.items.len - 1].curve, 1);
    const target = total * fraction;
    var before: f64 = 0;
    for (pieces.items) |piece| {
        const end = before + piece.length;
        if (target <= end) return invert(allocator, piece, target - before, &work);
        before = end;
    }
    // Floating-point accumulation can round the target to the final boundary.
    return pose(pieces.items[pieces.items.len - 1].curve, 1);
}

fn expectPoint(expected: g.Point, actual: g.Point, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
}

test "line arc fractions and close segments have deterministic join tangents" {
    const line = [_]Path.Segment{ .{ .move = .{ .x = 2, .y = 3 } }, .{ .line = .{ .x = 12, .y = 3 } } };
    const halfway = try motionPose(std.testing.allocator, &line, 0.5);
    try expectPoint(.{ .x = 7, .y = 3 }, halfway.position, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), halfway.angle, 1e-9);
    const closed = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } }, .{ .line = .{ .x = 10, .y = 10 } }, .{ .line = .{ .x = 0, .y = 10 } }, .close };
    const corner = try motionPose(std.testing.allocator, &closed, 0.25);
    try expectPoint(.{ .x = 10, .y = 0 }, corner.position, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), corner.angle, 1e-9);
    const end = try motionPose(std.testing.allocator, &closed, 1);
    try expectPoint(.zero, end.position, 1e-9);
    try std.testing.expectApproxEqAbs(-std.math.pi / 2.0, end.angle, 1e-9);
}

test "nonuniform straight cubic inverts length rather than treating fraction as time" {
    const segments = [_]Path.Segment{ .{ .move = .zero }, .{ .cubic = .{ .c1 = .zero, .c2 = .zero, .end = .{ .x = 100, .y = 0 } } } };
    const result = try motionPose(std.testing.allocator, &segments, 0.5);
    try expectPoint(.{ .x = 50, .y = 0 }, result.position, 1e-7);
    const start = try motionPose(std.testing.allocator, &segments, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0), start.angle, 1e-9);
}

test "symmetric curved cubic uses adaptive arc length and true derivative direction" {
    const segments = [_]Path.Segment{ .{ .move = .zero }, .{ .cubic = .{ .c1 = .{ .x = 0, .y = 100 }, .c2 = .{ .x = 100, .y = 100 }, .end = .{ .x = 100, .y = 0 } } } };
    const result = try motionPose(std.testing.allocator, &segments, 0.5);
    try expectPoint(.{ .x = 50, .y = 75 }, result.position, 2e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.angle, 2e-5);
    // This curve has speed 300*(2*t*t-2*t+1), hence exact cumulative
    // length 200*t^3-300*t^2+300*t. Quarter length is not quarter time.
    const quarter = try motionPose(std.testing.allocator, &segments, 0.25);
    try expectPoint(.{ .x = 10.589254302501772, .y = 48.35239517939101 }, quarter.position, 2e-5);
}

test "moveto jumps have no length and exact joins retain the incoming SVG pose" {
    const segments = [_]Path.Segment{
        .{ .move = .zero },                     .{ .line = .{ .x = 10, .y = 0 } },
        .{ .move = .{ .x = 1000, .y = 1000 } }, .{ .line = .{ .x = 1000, .y = 1010 } },
    };
    const join = try motionPose(std.testing.allocator, &segments, 0.5);
    try expectPoint(.{ .x = 10, .y = 0 }, join.position, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 0), join.angle, 1e-8);
    const after = try motionPose(std.testing.allocator, &segments, 0.500001);
    try expectPoint(.{ .x = 1000, .y = 1000.00002 }, after.position, 1e-7);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, after.angle, 1e-8);
    const result = try motionPose(std.testing.allocator, &segments, 0.75);
    try expectPoint(.{ .x = 1000, .y = 1005 }, result.position, 1e-7);
}

test "zero length SVG paths use the first drawing start or the final moveto" {
    const segments = [_]Path.Segment{
        .{ .move = .{ .x = 7, .y = 9 } },   .{ .line = .{ .x = 7, .y = 9 } }, .close,
        .{ .move = .{ .x = 20, .y = 30 } },
    };
    for ([_]f64{ 0, 0.3, 1 }) |fraction| {
        const result = try motionPose(std.testing.allocator, &segments, fraction);
        try expectPoint(.{ .x = 7, .y = 9 }, result.position, 0);
        try std.testing.expectEqual(@as(f64, 0), result.angle);
    }
    const single = [_]Path.Segment{.{ .move = .{ .x = 5, .y = 6 } }};
    try expectPoint(.{ .x = 5, .y = 6 }, (try motionPose(std.testing.allocator, &single, 0.7)).position, 0);
    const moves = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .move = .{ .x = 50, .y = 60 } } };
    const leading_moves = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .move = .{ .x = 50, .y = 60 } }, .{ .line = .{ .x = 50, .y = 60 } } };
    for ([_]f64{ 0, 0.5, 1 }) |fraction| {
        try expectPoint(.{ .x = 50, .y = 60 }, (try motionPose(std.testing.allocator, &moves, fraction)).position, 0);
        try expectPoint(.{ .x = 50, .y = 60 }, (try motionPose(std.testing.allocator, &leading_moves, fraction)).position, 0);
    }
}

test "invalid paths fractions and overflowing geometry fail explicitly" {
    const line = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    for ([_]f64{ -1, 1.1, std.math.inf(f64), std.math.nan(f64) }) |fraction|
        try std.testing.expectError(error.InvalidFraction, motionPose(std.testing.allocator, &line, fraction));
    try std.testing.expectError(error.InvalidPath, motionPose(std.testing.allocator, &.{}, 0));
    try std.testing.expectError(error.InvalidPath, motionPose(std.testing.allocator, &.{.{ .line = .zero }}, 0));
    try std.testing.expectError(error.InvalidPath, motionPose(std.testing.allocator, &.{ .{ .move = .zero }, .close, .close }, 0));
    try std.testing.expectError(error.NonFinite, motionPose(std.testing.allocator, &.{.{ .move = .{ .x = std.math.nan(f64), .y = 0 } }}, 0));
    const overflow = [_]Path.Segment{ .{ .move = .{ .x = -1e308, .y = 0 } }, .{ .line = .{ .x = 1e308, .y = 0 } } };
    try std.testing.expectError(error.NonFinite, motionPose(std.testing.allocator, &overflow, 0.5));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const segments = [_]Path.Segment{ .{ .move = .zero }, .{ .cubic = .{ .c1 = .{ .x = 0, .y = 100 }, .c2 = .{ .x = 100, .y = 100 }, .end = .{ .x = 100, .y = 0 } } } };
    const result = try motionPose(allocator, &segments, 0.3);
    try std.testing.expect(result.position.isFinite());
}
test "arc length refinement releases allocations on every allocator failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "paths exceeding the documented refinement storage limit fail and release scratch storage" {
    var segments: std.ArrayList(Path.Segment) = .empty;
    defer segments.deinit(std.testing.allocator);
    try segments.append(std.testing.allocator, .{ .move = .zero });
    for (0..max_leaves + 1) |index| {
        try segments.append(std.testing.allocator, .{ .line = .{ .x = @floatFromInt(index + 1), .y = 0 } });
    }
    try std.testing.expectError(error.LengthWorkLimit, motionPose(std.testing.allocator, segments.items, 0.5));
}
