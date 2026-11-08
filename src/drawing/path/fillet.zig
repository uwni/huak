//! Round the interior corners of one closed polygonal contour.
//! The result stays a native line/cubic path; circular arcs are represented by
//! cubic segments split at no more than a quarter turn.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");

const Allocator = std.mem.Allocator;
const epsilon = 1e-12;

const Corner = struct {
    p_in: g.Point,
    p_out: g.Point,
    center: g.Point = .zero,
    radius: f64 = 0,
    start: f64 = 0,
    sweep: f64 = 0,
    t_in: f64 = 0,
    t_out: f64 = 0,
    rounded: bool = false,
};

/// Fillet one closed polygon. `radii` is either one value applied to every
/// corner or exactly one value per vertex, in path order. A zero radius leaves
/// that corner sharp.
pub fn fillet(allocator: Allocator, source: Path, radii: []const f64) !Path {
    if (radii.len == 0) return error.InvalidRadii;
    for (radii) |radius| {
        if (!std.math.isFinite(radius) or radius < 0) return error.InvalidRadii;
    }

    var points: std.ArrayList(g.Point) = .empty;
    defer points.deinit(allocator);
    try collectPolygon(source, allocator, &points);
    const count = points.items.len;
    if (radii.len != 1 and radii.len != count) return error.InvalidRadii;

    const uniform = radii.len == 1;
    var any_fillet = false;
    for (radii) |radius| if (radius != 0) {
        any_fillet = true;
        break;
    };
    if (!any_fillet) return source.clone(allocator);

    const area = source.signedArea();
    if (!std.math.isFinite(area) or @abs(area) <= epsilon) return error.DegeneratePolygon;
    const orientation: f64 = if (area > 0) 1 else -1;

    const corners = try allocator.alloc(Corner, count);
    defer allocator.free(corners);
    for (0..count) |index| {
        const previous = points.items[(index + count - 1) % count];
        const current = points.items[index];
        const next = points.items[(index + 1) % count];
        const incoming = current.sub(previous);
        const outgoing = next.sub(current);
        const incoming_length = incoming.norm();
        const outgoing_length = outgoing.norm();
        if (!std.math.isFinite(incoming_length) or !std.math.isFinite(outgoing_length) or
            incoming_length <= epsilon or outgoing_length <= epsilon)
            return error.DegeneratePolygon;

        const radius = if (uniform) radii[0] else radii[index];
        const incoming_direction = try incoming.normalized();
        const outgoing_direction = try outgoing.normalized();
        const turn = std.math.atan2(
            incoming_direction.cross(outgoing_direction),
            incoming_direction.dot(outgoing_direction),
        );
        if (!std.math.isFinite(turn)) return error.DegeneratePolygon;

        // A collinear vertex has no corner to round. A non-zero radius is
        // ignored instead of making a harmless redundant vertex an error.
        if (@abs(turn) <= epsilon) {
            corners[index] = .{ .p_in = current, .p_out = current };
            continue;
        }
        // A zero radius is a sharp corner even when the vertex is reflex.
        // This lets callers round selected convex corners of a mixed polygon.
        if (radius == 0) {
            corners[index] = .{ .p_in = current, .p_out = current };
            continue;
        }
        if (@abs(turn) >= std.math.pi - epsilon) return error.RadiusTooLarge;

        const tangent_distance = radius * @tan(@abs(turn) / 2);
        if (!std.math.isFinite(tangent_distance)) return error.RadiusTooLarge;
        if (tangent_distance == 0) {
            corners[index] = .{ .p_in = current, .p_out = current };
            continue;
        }

        const inward = if (orientation > 0)
            g.Point{ .x = -incoming_direction.y, .y = incoming_direction.x }
        else
            g.Point{ .x = incoming_direction.y, .y = -incoming_direction.x };
        const p_in = current.sub(incoming_direction.scale(tangent_distance));
        const p_out = current.add(outgoing_direction.scale(tangent_distance));
        // Convex vertices put the center on the material side. A reflex
        // vertex uses the opposite side, which fills the notch and keeps the
        // tangent points on the actual adjacent segments.
        const convex = turn * orientation > 0;
        const center = p_in.add(inward.scale(if (convex) radius else -radius));
        const radial_error = center.distance(p_out) - radius;
        if (!std.math.isFinite(radial_error) or
            @abs(radial_error) > 1e-7 * @max(@as(f64, 1), radius))
            return error.DegenerateCorner;

        const start = std.math.atan2(p_in.y - center.y, p_in.x - center.x);
        const sweep = turn;
        const checked = center.add(.{
            .x = radius * @cos(start + sweep),
            .y = radius * @sin(start + sweep),
        });
        if (checked.distance(p_out) > 1e-7 * @max(@as(f64, 1), radius))
            return error.DegenerateCorner;

        corners[index] = .{
            .p_in = p_in,
            .p_out = p_out,
            .center = center,
            .radius = radius,
            .start = start,
            .sweep = sweep,
            .t_in = tangent_distance,
            .t_out = tangent_distance,
            .rounded = true,
        };
    }

    // Adjacent fillets must leave a non-negative segment between them.
    for (0..count) |index| {
        const next = (index + 1) % count;
        const length = points.items[index].distance(points.items[next]);
        if (corners[index].t_out + corners[next].t_in > length + 1e-7 * @max(@as(f64, 1), length))
            return error.RadiusTooLarge;
    }

    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(corners[0].p_in);
    for (0..count) |index| {
        if (corners[index].rounded) try appendArc(&result, corners[index]);
        if (index + 1 < count) {
            const next = corners[index + 1].p_in;
            if (result.current.?.distance(next) > epsilon) try result.lineTo(next);
        }
    }
    try result.close();
    return result;
}

fn collectPolygon(source: Path, allocator: Allocator, points: *std.ArrayList(g.Point)) !void {
    var moved = false;
    var closed = false;
    for (source.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (moved or closed) return error.MultipleContours;
            if (!point.isFinite()) return error.NonFinite;
            moved = true;
            try points.append(allocator, point);
        },
        .line => |point| {
            if (!moved) return error.InvalidPath;
            if (closed) return error.MultipleContours;
            if (!point.isFinite()) return error.NonFinite;
            try points.append(allocator, point);
        },
        .cubic => return error.CurvedSegment,
        .close => {
            if (!moved) return error.InvalidPath;
            if (closed) return error.MultipleContours;
            closed = true;
        },
    };
    if (!moved) return error.TooFewVertices;
    if (!closed or source.open) return error.OpenPath;
    if (points.items.len < 3) return error.TooFewVertices;
    // A closed path may spell its final edge explicitly before CLOSE.
    if (points.items[points.items.len - 1].eql(points.items[0])) points.items.len -= 1;
    if (points.items.len < 3) return error.TooFewVertices;
}

fn appendArc(result: *Path, corner: Corner) !void {
    const sweep = @abs(corner.sweep);
    if (sweep <= epsilon) return;
    const quarter_turn: f64 = @as(f64, std.math.pi) / 2.0;
    const segments = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(sweep / quarter_turn))));
    const step = corner.sweep / @as(f64, @floatFromInt(segments));
    var angle = corner.start;
    for (0..segments) |index| {
        const next_angle = angle + step;
        const p0 = circlePoint(corner, angle);
        const p3 = if (index + 1 == segments)
            corner.p_out
        else
            circlePoint(corner, next_angle);
        // Standard optimal kappa for an endpoint/midpoint-exact cubic arc.
        // Each segment is at most a quarter turn, so the radial error stays
        // bounded without flattening the circle into line segments.
        const kappa = (4.0 / 3.0) * @tan(@abs(step) / 4.0) * corner.radius;
        const direction: f64 = if (step > 0) 1 else -1;
        const tangent_start = g.Point{
            .x = -@sin(angle) * direction,
            .y = @cos(angle) * direction,
        };
        const tangent_end = g.Point{
            .x = -@sin(next_angle) * direction,
            .y = @cos(next_angle) * direction,
        };
        try result.cubicTo(
            p0.add(tangent_start.scale(kappa)),
            p3.sub(tangent_end.scale(kappa)),
            p3,
        );
        angle = next_angle;
    }
}

fn circlePoint(corner: Corner, angle: f64) g.Point {
    return corner.center.add(.{
        .x = corner.radius * @cos(angle),
        .y = corner.radius * @sin(angle),
    });
}

test "rectangle fillet keeps its outer bounds and replaces corners with cubics" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{2});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), countCubics(result));
    try std.testing.expectEqual(@as(usize, 3), countLines(result));
    const bounds = result.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), bounds.max.y, 1e-9);
}

test "triangle accepts one radius per corner and zero leaves a sharp vertex" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 8, .y = 12 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{ 1, 0, 2 });
    defer result.deinit();
    // The two rounded triangle corners sweep more than a quarter turn each,
    // so every arc is split into two cubic segments.
    try std.testing.expectEqual(@as(usize, 4), countCubics(result));
    try std.testing.expectEqual(@as(usize, 2), countLines(result));
}

test "quarter-circle fillet uses the optimal kappa and stays on the radius" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{2});
    defer result.deinit();
    const first = result.segments.items[1];
    try std.testing.expect(first == .cubic);
    const start = result.segments.items[0].move;
    const center = g.Point{ .x = 2, .y = 2 };
    var maximum_error: f64 = 0;
    for ([_]f64{ 0.1, 0.25, 0.5, 0.75, 0.9 }) |time| {
        const point = cubicPoint(start, first.cubic, time);
        maximum_error = @max(maximum_error, @abs(center.distance(point) - 2));
    }
    // A quarter-circle cubic's standard kappa keeps the radial error below
    // about 2.8e-4 of the radius; this also catches a wrong control point.
    try std.testing.expect(maximum_error <= 2.8e-4 * 2 + 1e-9);
    try std.testing.expect(@abs(center.distance(cubicPoint(start, first.cubic, 0.5)) - 2) <= 1e-9);
}

test "clockwise polygon fillets the same corners from the interior side" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{2});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), countCubics(result));
    const bounds = result.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), bounds.max.y, 1e-9);
}

test "explicit closing line is not counted as a duplicate vertex" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    try source.lineTo(.zero);
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{1});
    defer result.deinit();
    // The explicit closing line is normalized away; the three corners still
    // produce arcs (some split into two cubic segments).
    try std.testing.expect(countCubics(result) >= 3);
}

test "zero radius keeps a reflex vertex sharp while convex corners round" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 10, .y = 4 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{ 1, 1, 1, 0, 1 });
    defer result.deinit();
    try std.testing.expect(countCubics(result) > 0);
}

test "reflex corner with a radius fills the notch" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 10, .y = 4 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{1});
    defer result.deinit();
    try std.testing.expect(countCubics(result) > 0);
    const bounds = result.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
}

test "clockwise reflex polygon uses the same notch-side construction" {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 0, .y = 10 });
    try source.lineTo(.{ .x = 10, .y = 4 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 0, .y = 0 });
    try source.close();

    var result = try fillet(std.testing.allocator, source, &.{1});
    defer result.deinit();
    try std.testing.expect(countCubics(result) > 0);
    const bounds = result.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-9);
    try std.testing.expect(bounds.max.y <= 10 + 1e-9);
}

test "fillet rejects open, curved, multi-contour, oversized, and mismatched inputs" {
    var empty = Path.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectError(error.TooFewVertices, fillet(std.testing.allocator, empty, &.{1}));

    var open = Path.init(std.testing.allocator);
    defer open.deinit();
    try open.moveTo(.zero);
    try open.lineTo(.{ .x = 10, .y = 0 });
    try open.lineTo(.{ .x = 0, .y = 10 });
    try std.testing.expectError(error.OpenPath, fillet(std.testing.allocator, open, &.{1}));

    var curved = try Path.circle(std.testing.allocator, .zero, 5);
    defer curved.deinit();
    try std.testing.expectError(error.CurvedSegment, fillet(std.testing.allocator, curved, &.{1}));

    var multiple = Path.init(std.testing.allocator);
    defer multiple.deinit();
    try multiple.moveTo(.zero);
    try multiple.lineTo(.{ .x = 10, .y = 0 });
    try multiple.lineTo(.{ .x = 0, .y = 10 });
    try multiple.close();
    try multiple.moveTo(.{ .x = 20, .y = 0 });
    try multiple.lineTo(.{ .x = 30, .y = 0 });
    try multiple.lineTo(.{ .x = 20, .y = 10 });
    try multiple.close();
    try std.testing.expectError(error.MultipleContours, fillet(std.testing.allocator, multiple, &.{1}));

    var square = Path.init(std.testing.allocator);
    defer square.deinit();
    try square.moveTo(.zero);
    try square.lineTo(.{ .x = 10, .y = 0 });
    try square.lineTo(.{ .x = 10, .y = 10 });
    try square.lineTo(.{ .x = 0, .y = 10 });
    try square.close();
    try std.testing.expectError(error.RadiusTooLarge, fillet(std.testing.allocator, square, &.{8}));
    try std.testing.expectError(error.InvalidRadii, fillet(std.testing.allocator, square, &.{ 1, 2 }));
}

fn cubicPoint(start: g.Point, curve: anytype, time: f64) g.Point {
    const one = 1 - time;
    return start.scale(one * one * one)
        .add(curve.c1.scale(3 * one * one * time))
        .add(curve.c2.scale(3 * one * time * time))
        .add(curve.end.scale(time * time * time));
}

fn countCubics(path: Path) usize {
    var result: usize = 0;
    for (path.segments.items) |segment| if (segment == .cubic) {
        result += 1;
    };
    return result;
}

fn countLines(path: Path) usize {
    var result: usize = 0;
    for (path.segments.items) |segment| if (segment == .line) {
        result += 1;
    };
    return result;
}
