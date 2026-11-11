//! Round the corners of one closed polygonal contour.
//! The result stays a native line/cubic path: every circular arc is appended
//! by `Path.appendArc`, which splits it at no more than a quarter turn.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");

const Allocator = std.mem.Allocator;
const epsilon = 1e-12;

/// Vertices of one closed line contour, read in place from its MOVE/LINE
/// segments. An explicit final edge back to the start is not another vertex.
const Polygon = struct {
    segments: []const Path.Segment,
    len: usize,

    fn at(self: Polygon, index: usize) g.Point {
        return switch (self.segments[index]) {
            .move, .line => |point| point,
            .cubic, .close => unreachable,
        };
    }
};

/// Tangent points and arc of one corner. A sharp corner keeps both tangent
/// points at its vertex and has no arc.
const Corner = struct {
    p_in: g.Point,
    p_out: g.Point,
    /// Distance from the vertex to either tangent point.
    tangent: f64 = 0,
    center: g.Point = .zero,
    radius: f64 = 0,
    start: f64 = 0,
    sweep: f64 = 0,
    /// Whether a straight part of the outgoing edge remains before the next
    /// corner's tangent point.
    keeps_edge: bool = true,

    fn sharp(vertex: g.Point) Corner {
        return .{ .p_in = vertex, .p_out = vertex };
    }
};

/// Fillet one closed polygon. `radii` is either one value applied to every
/// corner or exactly one value per vertex, in path order. A zero radius leaves
/// that corner sharp. Returns null when every radius is zero, so a caller can
/// keep `source` instead of copying it. The result uses `allocator`; per-corner
/// construction data uses `scratch` and is freed before returning.
pub fn fillet(allocator: Allocator, scratch: Allocator, source: Path, radii: []const f64) !?Path {
    if (radii.len == 0) return error.InvalidRadii;
    for (radii) |radius| {
        if (!std.math.isFinite(radius) or radius < 0) return error.InvalidRadii;
    }
    const vertices = try polygon(source);
    const uniform = radii.len == 1;
    if (!uniform and radii.len != vertices.len) return error.InvalidRadii;
    for (radii) |radius| {
        if (radius != 0) break;
    } else return null;

    const area = source.signedArea();
    if (!std.math.isFinite(area) or @abs(area) <= epsilon) return error.DegeneratePolygon;
    const orientation: f64 = if (area > 0) 1 else -1;

    const corners = try scratch.alloc(Corner, vertices.len);
    defer scratch.free(corners);
    for (corners, 0..) |*corner, index| {
        corner.* = try fitCorner(vertices, index, if (uniform) radii[0] else radii[index], orientation);
    }

    // Adjacent fillets must leave a non-negative straight part between them.
    // The part is measured from edge and tangent lengths rather than from
    // tangent points, so the decision does not depend on how far the polygon
    // lies from the origin. Counting the output lets the result allocate once.
    var segments: usize = 2; // MOVE and CLOSE
    for (corners, 0..) |*corner, index| {
        const next = (index + 1) % corners.len;
        const length = vertices.at(index).distance(vertices.at(next));
        const tolerance = 1e-7 * @max(@as(f64, 1), length);
        const remaining = length - corner.tangent - corners[next].tangent;
        if (remaining < -tolerance) return error.RadiusTooLarge;
        corner.keeps_edge = remaining > tolerance;
        // Without a straight part the next corner starts exactly where this
        // one ends, so no rounding-length edge appears between them, and the
        // path starts where its last corner ends.
        if (!corner.keeps_edge) corners[next].p_in = corner.p_out;
        if (corner.tangent != 0) segments += Path.arcSpans(corner.sweep);
        if (next != 0 and corner.keeps_edge) segments += 1;
    }

    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.segments.ensureTotalCapacityPrecise(allocator, segments);
    try result.moveTo(corners[0].p_in);
    for (corners, 0..) |corner, index| {
        const next = (index + 1) % corners.len;
        if (corner.tangent != 0) {
            try result.appendArc(corner.center, corner.radius, corner.start, corner.sweep);
            // Arcs end exactly on their tangent points; with the shared points
            // above, the last corner returns exactly to the start for CLOSE.
            endArcAt(&result, corner.p_out);
        }
        if (next != 0 and corner.keeps_edge) try result.lineTo(corners[next].p_in);
    }
    try result.close();
    return result;
}

/// Move the end of the arc just appended onto `point`, translating its second
/// control point with it. The arc is already within rounding of `point`.
fn endArcAt(path: *Path, point: g.Point) void {
    const last = &path.segments.items[path.segments.items.len - 1].cubic;
    last.c2 = last.c2.add(point.sub(last.end));
    last.end = point;
    path.current = point;
}

fn fitCorner(vertices: Polygon, index: usize, radius: f64, orientation: f64) !Corner {
    const count = vertices.len;
    const previous = vertices.at((index + count - 1) % count);
    const vertex = vertices.at(index);
    const next = vertices.at((index + 1) % count);
    const incoming = vertex.sub(previous);
    const outgoing = next.sub(vertex);
    const incoming_length = incoming.norm();
    const outgoing_length = outgoing.norm();
    if (!std.math.isFinite(incoming_length) or !std.math.isFinite(outgoing_length) or
        incoming_length <= epsilon or outgoing_length <= epsilon)
        return error.DegeneratePolygon;

    const incoming_direction = try incoming.normalized();
    const outgoing_direction = try outgoing.normalized();
    const turn = std.math.atan2(
        incoming_direction.cross(outgoing_direction),
        incoming_direction.dot(outgoing_direction),
    );
    if (!std.math.isFinite(turn)) return error.DegeneratePolygon;
    // A collinear vertex has no corner to round. A zero radius is a sharp
    // corner even when the vertex is reflex, so callers can round selected
    // corners of a mixed polygon.
    if (@abs(turn) <= epsilon or radius == 0) return .sharp(vertex);
    // An edge that reverses onto its predecessor leaves no corner to fit.
    if (@abs(turn) >= std.math.pi - epsilon) return error.DegenerateCorner;
    const tangent = radius * @tan(@abs(turn) / 2);
    if (!std.math.isFinite(tangent)) return error.RadiusTooLarge;
    if (tangent == 0) return .sharp(vertex);

    // The material lies left of a counterclockwise contour. A convex corner
    // puts the center on the material side; a reflex corner uses the opposite
    // side, which fills the notch and keeps the tangent points on the edges.
    const inward = (g.Point{ .x = -incoming_direction.y, .y = incoming_direction.x }).scale(orientation);
    const side: f64 = if (turn * orientation > 0) 1 else -1;
    // Unit vector from the center to the incoming tangent point. Taking the
    // start angle from it avoids differences of large coordinates.
    const radial = inward.scale(-side);
    const p_in = vertex.sub(incoming_direction.scale(tangent));
    return .{
        .p_in = p_in,
        .p_out = vertex.add(outgoing_direction.scale(tangent)),
        .tangent = tangent,
        .center = p_in.sub(radial.scale(radius)),
        .radius = radius,
        .start = std.math.atan2(radial.y, radial.x),
        .sweep = turn,
    };
}

fn polygon(source: Path) !Polygon {
    const segments = source.segments.items;
    var count: usize = 0;
    var closed = false;
    for (segments) |segment| switch (segment) {
        .move => |point| {
            if (count != 0 or closed) return error.MultipleContours;
            if (!point.isFinite()) return error.NonFinite;
            count += 1;
        },
        .line => |point| {
            if (count == 0) return error.InvalidPath;
            if (closed) return error.MultipleContours;
            if (!point.isFinite()) return error.NonFinite;
            count += 1;
        },
        .cubic => return error.CurvedSegment,
        .close => {
            if (count == 0) return error.InvalidPath;
            if (closed) return error.MultipleContours;
            closed = true;
        },
    };
    if (count == 0) return error.TooFewVertices;
    if (!closed or source.open) return error.OpenPath;
    var result: Polygon = .{ .segments = segments, .len = count };
    // A closed path may spell its final edge explicitly before CLOSE.
    if (result.at(count - 1).eql(result.at(0))) result.len -= 1;
    if (result.len < 3) return error.TooFewVertices;
    return result;
}

const testing = std.testing;

fn polygonPath(points: []const g.Point) !Path {
    var path = Path.init(testing.allocator);
    errdefer path.deinit();
    try path.moveTo(points[0]);
    for (points[1..]) |point| try path.lineTo(point);
    try path.close();
    return path;
}

fn rounded(source: Path, radii: []const f64) !Path {
    return (try fillet(testing.allocator, testing.allocator, source, radii)).?;
}

test "rectangle fillet keeps its outer bounds and allocates the result once" {
    var source = try polygonPath(&.{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 0, .y = 10 } });
    defer source.deinit();

    var result = try rounded(source, &.{2});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), countCubics(result));
    try testing.expectEqual(@as(usize, 3), countLines(result));
    try testing.expectEqual(result.segments.items.len, result.segments.capacity);
    const bounds = result.bounds().?;
    try testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), bounds.max.y, 1e-9);
}

test "a pill closes exactly so a line through its tangent points meets only them" {
    var source = try polygonPath(&.{ .{ .x = -17, .y = -10.85 }, .{ .x = 17, .y = -10.85 }, .{ .x = 17, .y = 10.85 }, .{ .x = -17, .y = 10.85 } });
    defer source.deinit();

    var pill = try rounded(source, &.{10.85});
    defer pill.deinit();
    // Both short edges vanish: no LINE remains on them and the last arc
    // returns exactly to the start, so CLOSE adds no rounding-length edge.
    try testing.expectEqual(@as(usize, 2), countLines(pill));
    const items = pill.segments.items;
    try testing.expect(items[items.len - 2].cubic.end.eql(items[0].move));
    try testing.expectEqual(items.len, pill.segments.capacity);

    // A rounding-length CLOSE edge on this line used to be reported as a
    // coincident curve. Segment junctions may report a point once per side.
    var line = Path.init(testing.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = -40, .y = 0 });
    try line.lineTo(.{ .x = 40, .y = 0 });
    const hits = try line.intersectionDetails(testing.allocator, pill, 1e-8);
    defer testing.allocator.free(hits);
    var sides = [2]bool{ false, false };
    for (hits) |hit| {
        const side: usize = if (hit.point.x < 0) 0 else 1;
        try testing.expectApproxEqAbs(@as(f64, if (side == 0) -17 else 17), hit.point.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), hit.point.y, 1e-9);
        sides[side] = true;
    }
    try testing.expect(sides[0] and sides[1]);
}

test "a sharp corner and a fully consumed edge share one exact point" {
    // A rotated square whose first corner consumes both adjacent edges. The
    // rounding of tan(45deg) must not leave a separate LINE or CLOSE edge.
    var points: [4]g.Point = undefined;
    for (&points, 0..) |*point, index| {
        const angle = std.math.pi / 6.0 + @as(f64, @floatFromInt(index)) * std.math.pi / 2.0;
        point.* = .{ .x = 10 * @cos(angle), .y = 10 * @sin(angle) };
    }
    var source = try polygonPath(&points);
    defer source.deinit();

    var result = try rounded(source, &.{ points[0].distance(points[1]), 0, 0, 0 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), countCubics(result));
    try testing.expectEqual(@as(usize, 2), countLines(result));
    const items = result.segments.items;
    try testing.expect(items[0].move.eql(points[3]));
    try testing.expect(items[items.len - 2].line.eql(points[3]));
    try testing.expectEqual(items.len, result.segments.capacity);
}

test "triangle accepts one radius per corner and zero leaves a sharp vertex" {
    var source = try polygonPath(&.{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 8, .y = 12 } });
    defer source.deinit();

    var result = try rounded(source, &.{ 1, 0, 2 });
    defer result.deinit();
    // The two rounded triangle corners sweep more than a quarter turn each,
    // so every arc is split into two cubic segments.
    try testing.expectEqual(@as(usize, 4), countCubics(result));
    try testing.expectEqual(@as(usize, 2), countLines(result));
    try testing.expect(hasLineEnd(result, .{ .x = 20, .y = 0 }));
    try testing.expectEqual(result.segments.items.len, result.segments.capacity);
}

test "quarter-circle fillet uses the optimal kappa and stays on the radius" {
    var source = try polygonPath(&.{ .zero, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } });
    defer source.deinit();

    var result = try rounded(source, &.{2});
    defer result.deinit();
    const first = result.segments.items[1];
    try testing.expect(first == .cubic);
    const start = result.segments.items[0].move;
    const center = g.Point{ .x = 2, .y = 2 };
    var maximum_error: f64 = 0;
    for ([_]f64{ 0.1, 0.25, 0.5, 0.75, 0.9 }) |time| {
        const point = cubicPoint(start, first.cubic, time);
        maximum_error = @max(maximum_error, @abs(center.distance(point) - 2));
    }
    // A quarter-circle cubic's standard kappa keeps the radial error below
    // about 2.8e-4 of the radius; this also catches a wrong control point.
    try testing.expect(maximum_error <= 2.8e-4 * 2 + 1e-9);
    try testing.expect(@abs(center.distance(cubicPoint(start, first.cubic, 0.5)) - 2) <= 1e-9);
}

test "clockwise polygon fillets the same corners from the interior side" {
    var source = try polygonPath(&.{ .zero, .{ .x = 0, .y = 10 }, .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 0 } });
    defer source.deinit();

    var result = try rounded(source, &.{2});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), countCubics(result));
    const bounds = result.bounds().?;
    try testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), bounds.min.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), bounds.max.y, 1e-9);
}

test "explicit closing line is not counted as a duplicate vertex" {
    var source = try polygonPath(&.{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 10, .y = 10 }, .zero });
    defer source.deinit();

    var result = try rounded(source, &.{1});
    defer result.deinit();
    // Two 135-degree corners take two spans each and the 90-degree apex one.
    try testing.expectEqual(@as(usize, 5), countCubics(result));
    try testing.expectEqual(@as(usize, 2), countLines(result));
}

// Counterclockwise pentagon whose vertex (10,4) is reflex.
const notch = [_]g.Point{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 10, .y = 4 }, .{ .x = 0, .y = 10 } };
// A unit circle tangent to both notch edges is centered on the vertical
// bisector, r / sin(half notch angle) = sqrt(136) / 10 above the vertex.
const notch_center = g.Point{ .x = 10, .y = 4 + @sqrt(136.0) / 10.0 };

test "zero radius keeps a reflex vertex sharp while convex corners round" {
    var source = try polygonPath(&notch);
    defer source.deinit();

    var result = try rounded(source, &.{ 1, 1, 1, 0, 1 });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 6), countCubics(result));
    try testing.expect(hasLineEnd(result, notch[3]));
    // Rounding only convex corners removes material.
    try testing.expect(result.signedArea() < source.signedArea());
}

test "reflex corner with a radius fills the notch" {
    var source = try polygonPath(&notch);
    defer source.deinit();

    var selected = try rounded(source, &.{ 0, 0, 0, 1, 0 });
    defer selected.deinit();
    try testing.expectEqual(@as(usize, 1), countCubics(selected));
    try testing.expect(selected.signedArea() > source.signedArea());
    try expectArcsOnCircle(selected, notch_center, 1);

    var uniform = try rounded(source, &.{1});
    defer uniform.deinit();
    const bounds = uniform.bounds().?;
    try testing.expectApproxEqAbs(@as(f64, 0), bounds.min.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), bounds.max.x, 1e-9);
}

test "clockwise reflex polygon uses the same notch-side construction" {
    var source = try polygonPath(&.{ .{ .x = 0, .y = 10 }, .{ .x = 10, .y = 4 }, .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 0 }, .zero });
    defer source.deinit();
    try testing.expect(source.signedArea() < 0);

    var result = try rounded(source, &.{ 0, 1, 0, 0, 0 });
    defer result.deinit();
    // Filling the notch enlarges a clockwise area, making it more negative.
    try testing.expect(result.signedArea() < source.signedArea());
    try expectArcsOnCircle(result, notch_center, 1);
}

test "zero radii report an unchanged polygon without building a copy" {
    var source = try polygonPath(&.{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 8, .y = 12 } });
    defer source.deinit();
    try testing.expect(try fillet(testing.allocator, testing.allocator, source, &.{0}) == null);
    try testing.expect(try fillet(testing.allocator, testing.allocator, source, &.{ 0, 0, 0 }) == null);

    var open = Path.init(testing.allocator);
    defer open.deinit();
    try open.moveTo(.zero);
    try open.lineTo(.{ .x = 10, .y = 0 });
    try open.lineTo(.{ .x = 0, .y = 10 });
    try testing.expectError(error.OpenPath, fillet(testing.allocator, testing.allocator, open, &.{0}));
}

test "large coordinates round as they do near the origin" {
    const offset = g.Point{ .x = 1e9, .y = 1e9 };
    const shape = [_]g.Point{ .zero, .{ .x = 100, .y = 0 }, .{ .x = 31, .y = 47 } };
    var far_points: [shape.len]g.Point = undefined;
    for (shape, &far_points) |point, *far| far.* = point.add(offset);

    var near = try polygonPath(&shape);
    defer near.deinit();
    var far = try polygonPath(&far_points);
    defer far.deinit();
    var near_result = try rounded(near, &.{1});
    defer near_result.deinit();
    var far_result = try rounded(far, &.{1});
    defer far_result.deinit();
    try testing.expectEqual(countCubics(near_result), countCubics(far_result));
    try testing.expectEqual(countLines(near_result), countLines(far_result));

    // Fully consumed edges stay consumed far from the origin: tangent points
    // that differ only by rounding of the coordinates add no extra LINE.
    const box = [_]g.Point{ .{ .x = -17, .y = -10.85 }, .{ .x = 17, .y = -10.85 }, .{ .x = 17, .y = 10.85 }, .{ .x = -17, .y = 10.85 } };
    var far_box: [box.len]g.Point = undefined;
    for (box, &far_box) |point, *far_point| far_point.* = point.add(offset);
    var far_source = try polygonPath(&far_box);
    defer far_source.deinit();
    var far_pill = try rounded(far_source, &.{10.85});
    defer far_pill.deinit();
    try testing.expectEqual(@as(usize, 2), countLines(far_pill));
    const items = far_pill.segments.items;
    try testing.expect(items[items.len - 2].cubic.end.eql(items[0].move));
}

test "fillet rejects open, curved, multi-contour, oversized, spiked, and mismatched inputs" {
    const a = testing.allocator;
    var empty = Path.init(a);
    defer empty.deinit();
    try testing.expectError(error.TooFewVertices, fillet(a, a, empty, &.{1}));

    var open = Path.init(a);
    defer open.deinit();
    try open.moveTo(.zero);
    try open.lineTo(.{ .x = 10, .y = 0 });
    try open.lineTo(.{ .x = 0, .y = 10 });
    try testing.expectError(error.OpenPath, fillet(a, a, open, &.{1}));

    var curved = try Path.circle(a, .zero, 5);
    defer curved.deinit();
    try testing.expectError(error.CurvedSegment, fillet(a, a, curved, &.{1}));

    var multiple = try polygonPath(&.{ .zero, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 10 } });
    defer multiple.deinit();
    try multiple.moveTo(.{ .x = 20, .y = 0 });
    try multiple.lineTo(.{ .x = 30, .y = 0 });
    try multiple.lineTo(.{ .x = 20, .y = 10 });
    try multiple.close();
    try testing.expectError(error.MultipleContours, fillet(a, a, multiple, &.{1}));

    var square = try polygonPath(&.{ .zero, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } });
    defer square.deinit();
    try testing.expectError(error.RadiusTooLarge, fillet(a, a, square, &.{8}));
    try testing.expectError(error.InvalidRadii, fillet(a, a, square, &.{ 1, 2 }));
    try testing.expectError(error.InvalidRadii, fillet(a, a, square, &.{-1}));

    // The edge at (20,0) reverses onto its predecessor: no radius fits it.
    var spike = try polygonPath(&.{ .zero, .{ .x = 20, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } });
    defer spike.deinit();
    try testing.expectError(error.DegenerateCorner, fillet(a, a, spike, &.{0.001}));
}

fn filletUnderFailure(allocator: Allocator) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.lineTo(.{ .x = 20, .y = 10 });
    try source.lineTo(.{ .x = 10, .y = 4 });
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();
    var result = (try fillet(allocator, allocator, source, &.{1})).?;
    result.deinit();
}

test "fillet releases scratch and partial results on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, filletUnderFailure, .{});
}

fn cubicPoint(start: g.Point, curve: anytype, time: f64) g.Point {
    const one = 1 - time;
    return start.scale(one * one * one)
        .add(curve.c1.scale(3 * one * one * time))
        .add(curve.c2.scale(3 * one * time * time))
        .add(curve.end.scale(time * time * time));
}

/// Every cubic's endpoints and its midpoint, which the standard kappa places
/// exactly, lie on the given circle.
fn expectArcsOnCircle(path: Path, center: g.Point, radius: f64) !void {
    var current: g.Point = .zero;
    var arcs: usize = 0;
    for (path.segments.items) |segment| switch (segment) {
        .move, .line => |point| current = point,
        .cubic => |curve| {
            for ([_]g.Point{ current, cubicPoint(current, curve, 0.5), curve.end }) |point| {
                try testing.expectApproxEqAbs(radius, center.distance(point), 1e-9);
            }
            current = curve.end;
            arcs += 1;
        },
        .close => {},
    };
    try testing.expect(arcs > 0);
}

fn hasLineEnd(path: Path, point: g.Point) bool {
    for (path.segments.items) |segment| {
        if (segment == .line and segment.line.eql(point)) return true;
    }
    return false;
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
