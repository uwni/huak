//! SVG has no mesh shading. A mesh triangle whose three vertex colors lie on
//! one line in RGBA space changes color along a single direction, so one
//! two-stop linear gradient reproduces its Gouraud interpolation exactly.
//! Other triangles have no such gradient and need PDF output.
//!
//! The triangles of a mesh share edges and agree in color along them.
//! Antialiasing each triangle on its own would let the background show
//! through those edges, so the stylesheet draws the triangles of a labeled
//! mesh group without antialiasing; the group's exact clip keeps the outline
//! smooth.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const Color = @import("../../drawing/style.zig").Color;

/// Native scene tag of the group holding one mesh's triangles. Typst writes
/// it as `data-typst-label`.
pub const label = "huak-mesh";
const stylesheet = "<style>[data-typst-label=\"" ++ label ++ "\"] path{shape-rendering:crispEdges}</style>";

/// Vertex colors off a common line by more than this need PDF.
const collinear_tolerance = 1e-9;

pub const Linear = struct { start: g.Point, end: g.Point, colors: [2]Color };
pub const Paint = union(enum) {
    /// The triangle has no area.
    none,
    flat: Color,
    linear: Linear,
};

/// The paint reproducing linear interpolation of `colors` across the
/// triangle, or null when the colors do not lie on one line.
pub fn triangle(points: [3]g.Point, colors: [3]Color) ?Paint {
    const first = points[1].sub(points[0]);
    const second = points[2].sub(points[0]);
    const area = first.x * second.y - first.y * second.x;
    if (area == 0 or !std.math.isFinite(area)) return .none;
    const origin = vector(colors[0]);
    const deltas = [2]@Vector(4, f64){ vector(colors[1]) - origin, vector(colors[2]) - origin };
    const lengths = [2]f64{ @reduce(.Add, deltas[0] * deltas[0]), @reduce(.Add, deltas[1] * deltas[1]) };
    // Color changes by `axis` per unit of the scalar s, which is 0 at the
    // first vertex and affine across the triangle.
    const longer: usize = if (lengths[0] >= lengths[1]) 0 else 1;
    if (lengths[longer] == 0) return .{ .flat = colors[0] };
    const axis = deltas[longer];
    var s: [3]f64 = .{ 0, 0, 0 };
    for (deltas, 1..) |delta, index| {
        s[index] = @reduce(.Add, delta * axis) / lengths[longer];
        const residual = delta - axis * @as(@Vector(4, f64), @splat(s[index]));
        if (@reduce(.Max, @abs(residual)) > collinear_tolerance) return null;
    }
    // Solve [first; second] * gradient = [s1; s2] for the gradient of s.
    const gradient: g.Point = .{
        .x = (s[1] * second.y - s[2] * first.y) / area,
        .y = (s[2] * first.x - s[1] * second.x) / area,
    };
    const squared = gradient.x * gradient.x + gradient.y * gradient.y;
    const low = @min(s[0], s[1], s[2]);
    const high = @max(s[0], s[1], s[2]);
    const start = points[0].add(gradient.scale(low / squared));
    const end = points[0].add(gradient.scale(high / squared));
    // A sliver whose color changes across less than the coordinates resolve
    // shows only its mean color.
    if (!start.isFinite() or !end.isFinite() or start.eql(end)) {
        const third: @Vector(4, f64) = @splat(1.0 / 3.0);
        return .{ .flat = color((vector(colors[0]) + vector(colors[1]) + vector(colors[2])) * third) };
    }
    return .{ .linear = .{
        .start = start,
        .end = end,
        .colors = .{ color(origin + axis * @as(@Vector(4, f64), @splat(low))), color(origin + axis * @as(@Vector(4, f64), @splat(high))) },
    } };
}

/// Without antialiasing, a shared edge still leaves a crack wherever the two
/// triangles' copies round apart in the renderer: Typst writes relative path
/// coordinates under per-path transforms, so the copies are not bit-identical,
/// and Chrome and Firefox round vertices to 1/64 pixel. A pixel center in the
/// crack shows the background. Pushing each edge of an opaque mesh out by
/// this fraction of the page's larger side covered every crack in Chrome and
/// Firefox from 80 to 1440 pixel renderings; neighbours paint the overlap
/// with the same field. A translucent mesh keeps exact edges: painting the
/// overlap twice would show along every edge, while a crack shows at most a
/// rare pixel. Smaller fractions left more cracks, since sub-1/64-pixel
/// offsets round the two copies apart.
pub const overlap = 1.0 / 4096.0;

/// The triangle with every edge pushed out by `distance`. Each corner moves to
/// where its two offset edges meet, limited to four times the distance at
/// very sharp corners.
pub fn expanded(points: [3]g.Point, distance: f64) [3]g.Point {
    const area = (points[1].x - points[0].x) * (points[2].y - points[0].y) - (points[1].y - points[0].y) * (points[2].x - points[0].x);
    const side: f64 = if (area > 0) 1 else -1;
    var normals: [3]g.Point = undefined;
    for (&normals, 0..) |*normal, index| {
        const edge = points[(index + 1) % 3].sub(points[index]);
        const length = edge.norm();
        normal.* = if (length > 0) g.Point{ .x = side * edge.y / length, .y = -side * edge.x / length } else .zero;
    }
    var result: [3]g.Point = undefined;
    for (&result, 0..) |*corner, index| {
        const before = normals[(index + 2) % 3];
        const after = normals[index];
        const join = 1 + before.dot(after);
        const reach = if (join > 0.25) distance / join else 4 * distance;
        corner.* = points[index].add(before.add(after).scale(reach));
    }
    return result;
}

fn vector(value: Color) @Vector(4, f64) {
    return .{ value.r, value.g, value.b, value.a };
}

/// Extreme stops lie on the vertex color line; rounding may leave them a few
/// ulps outside the channel range.
fn color(value: @Vector(4, f64)) Color {
    const clamped = @min(@max(value, @as(@Vector(4, f64), @splat(0))), @as(@Vector(4, f64), @splat(1)));
    return .{ .r = clamped[0], .g = clamped[1], .b = clamped[2], .a = clamped[3] };
}

/// Appends the mesh stylesheet to a document with mesh groups, before the
/// root element's closing tag. The caller owns the result.
pub fn addStylesheet(allocator: std.mem.Allocator, svg: []const u8) ![]u8 {
    const close = std.mem.lastIndexOf(u8, svg, "</svg>") orelse return error.UnsupportedSvg;
    return std.mem.concat(allocator, u8, &.{ svg[0..close], stylesheet, svg[close..] });
}

const t = std.testing;

fn interpolate(colors: [3]Color, weights: [3]f64) @Vector(4, f64) {
    var sum: @Vector(4, f64) = @splat(0);
    for (colors, weights) |value, weight| sum += vector(value) * @as(@Vector(4, f64), @splat(weight));
    return sum;
}

fn sample(paint: Linear, point: g.Point) @Vector(4, f64) {
    const axis = paint.end.sub(paint.start);
    const along = point.sub(paint.start);
    const fraction = std.math.clamp((along.x * axis.x + along.y * axis.y) / (axis.x * axis.x + axis.y * axis.y), 0, 1);
    return vector(paint.colors[0]) + (vector(paint.colors[1]) - vector(paint.colors[0])) * @as(@Vector(4, f64), @splat(fraction));
}

test "a gradient along the color line reproduces Gouraud interpolation" {
    const points = [3]g.Point{ .{ .x = 3, .y = -2 }, .{ .x = 41, .y = 7 }, .{ .x = 12, .y = 33 } };
    // Colors on the line low + s * (high - low), including alpha.
    const low = Color{ .r = 0.2, .g = 0.1, .b = 0.6, .a = 0.9 };
    const high = Color{ .r = 0.9, .g = 0.8, .b = 0.3, .a = 0.5 };
    var colors: [3]Color = undefined;
    for (&colors, [3]f64{ 0.7, 0.1, 0.45 }) |*value, s| value.* = color(vector(low) + (vector(high) - vector(low)) * @as(@Vector(4, f64), @splat(s)));
    const paint = triangle(points, colors).?.linear;
    var weights: [3]f64 = undefined;
    for (0..11) |i| for (0..11 - i) |j| {
        weights = .{ @as(f64, @floatFromInt(i)) / 10, @as(f64, @floatFromInt(j)) / 10, @as(f64, @floatFromInt(10 - i - j)) / 10 };
        var point = g.Point.zero;
        for (points, weights) |p, w| point = point.add(p.scale(w));
        const difference = sample(paint, point) - interpolate(colors, weights);
        try t.expect(@reduce(.Max, @abs(difference)) < 1e-12);
    };
}

test "triangles off the color line need PDF and degenerate ones paint nothing" {
    const points = [3]g.Point{ .zero, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    try t.expectEqual(@as(?Paint, null), triangle(points, .{ .{ .r = 1 }, .{ .g = 1 }, .{ .b = 1 } }));
    const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    try t.expectEqual(Paint{ .flat = gray }, triangle(points, .{ gray, gray, gray }).?);
    try t.expectEqual(Paint.none, triangle(.{ .zero, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 } }, .{ .{ .r = 1 }, .{ .g = 1 }, .{ .b = 1 } }).?);
    // A sliver one unit in the last place wide at one end: its color changes
    // across less than its coordinates resolve, so it takes the mean color.
    const thin = std.math.nextAfter(f64, 30, 31);
    const sliver = triangle(.{ .{ .x = 30, .y = 40 }, .{ .x = thin, .y = 41 }, .{ .x = 30, .y = 40.001 } }, .{ .{ .r = 0.5 }, .{ .r = 0.5 }, .{ .r = 0.8 } }).?;
    try t.expectApproxEqAbs(@as(f64, 0.6), sliver.flat.r, 1e-12);
}

test "expansion moves every edge out by the distance in either orientation" {
    const triangles = [_][3]g.Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 1, .y = 3 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 4, .y = 0 } },
    };
    for (triangles) |points| {
        const result = expanded(points, 0.01);
        for (0..3) |index| {
            const start = points[index];
            const edge = points[(index + 1) % 3].sub(start);
            const opposite = points[(index + 2) % 3].sub(start);
            // Signed distance away from the opposite corner, for both new ends.
            for ([_]g.Point{ result[index], result[(index + 1) % 3] }) |corner| {
                const away = -std.math.sign(edge.cross(opposite)) * edge.cross(corner.sub(start)) / edge.norm();
                try t.expectApproxEqAbs(@as(f64, 0.01), away, 1e-12);
            }
        }
    }
}

test "the stylesheet ends the root element" {
    const result = try addStylesheet(t.allocator, "<svg><g/></svg>\n");
    defer t.allocator.free(result);
    try t.expectEqualStrings("<svg><g/>" ++ stylesheet ++ "</svg>\n", result);
    try t.expectError(error.UnsupportedSvg, addStylesheet(t.allocator, "<g/>"));
}
