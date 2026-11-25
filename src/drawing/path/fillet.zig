//! Round the corners of one closed polygonal contour.
//! The result stays a native line/cubic path: every circular arc is appended
//! by `Path.arcs.appendArc`, which splits it at no more than a quarter turn.
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
/// keep `source` instead of copying it. The result uses `allocator`, which
/// also holds the per-corner construction data until it returns.
pub fn fillet(allocator: Allocator, source: Path, radii: []const f64) !?Path {
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

    const corners = try allocator.alloc(Corner, vertices.len);
    defer allocator.free(corners);
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
        if (corner.tangent != 0) segments += Path.arcs.arcSpans(corner.sweep);
        if (next != 0 and corner.keeps_edge) segments += 1;
    }

    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.segments.ensureTotalCapacityPrecise(allocator, segments);
    try result.moveTo(corners[0].p_in);
    for (corners, 0..) |corner, index| {
        const next = (index + 1) % corners.len;
        if (corner.tangent != 0) {
            try Path.arcs.appendArc(&result, corner.center, corner.radius, corner.start, corner.sweep);
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

test {
    _ = @import("fillet_test.zig");
}
