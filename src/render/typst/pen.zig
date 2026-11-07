//! Physical pens resolved with the existing geometry algorithms. Ordinary
//! strokes already have a native representation and need no intermediate plan.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Path = @import("../../drawing/path/Path.zig");
const pens = @import("../../drawing/pen/root.zig");

pub fn checkOutputPrecision(path: *const Path, tolerance: f64) !void {
    var magnitude: f64 = 0;
    for (path.segments.items) |segment| switch (segment) {
        .move, .line => |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y)),
        .cubic => |c| {
            for ([_]g.Point{ c.c1, c.c2, c.end }) |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y));
        },
        .close => {},
    };
    // The pinned Typst PDF backend stores controls as binary32. Casting and
    // shortest-decimal formatting each consume at most half a binary32 ulp.
    // SVG writes relative coordinates to nine decimal places. Errors of
    // successive endpoints can accumulate. The convex hull property extends
    // the control-point bound to every point of the resulting Bézier curve.
    const count: f64 = @floatFromInt(path.segments.items.len);
    const pdf = 2 * (magnitude * std.math.floatEps(f32) + std.math.floatMin(f32));
    const svg = count * (1e-9 + 8 * std.math.floatEps(f64) * magnitude);
    if (magnitude > std.math.floatMax(f32) or @max(pdf, svg) > tolerance * 0.25) return error.OutputPrecisionRange;
}

// Keep erasure and export on the same geometric tolerance; only encoded
// coordinates have to satisfy the remaining output precision budget.
fn geometryTolerance(tolerance: f64) f64 {
    return tolerance * 0.75;
}

pub fn strokeFootprint(allocator: std.mem.Allocator, scratch: std.mem.Allocator, curve: Path, pen: *const DisplayList.Pen, tolerance: ?f64) !Path {
    const geometric = if (pen.motion) |motion| geometryTolerance(tolerance orelse motion.tolerance) else tolerance;
    return pens.footprint(allocator, scratch, curve, pen, geometric);
}

pub fn motionFootprint(allocator: std.mem.Allocator, center: Path, pen: *const DisplayList.Pen, options: pens.StrokeOptions) !Path {
    var geometry = options;
    geometry.tolerance = geometryTolerance(options.tolerance);
    var path = try pens.motionOutline(allocator, center, pen, geometry);
    errdefer path.deinit();
    try checkOutputPrecision(&path, options.tolerance);
    return path;
}

pub fn resolve(allocator: std.mem.Allocator, segments: []const Path.Segment, style: *const DisplayList.Style, options: pens.StrokeOptions) !pens.Stroke {
    var center = Path.init(allocator);
    center.segments.items = @constCast(segments);
    center.segments.capacity = segments.len;
    return resolvePath(allocator, center, style, options);
}
pub fn resolvePath(allocator: std.mem.Allocator, center: Path, style: *const DisplayList.Style, options: pens.StrokeOptions) !pens.Stroke {
    const pen = &style.pen.?;
    var settings = options;
    if (pen.motion) |motion| settings.tolerance = geometryTolerance(motion.tolerance);
    const representation: pens.Representation = if (style.gradientFor(.stroke) != null) .outline else .normalized_stroke;
    return pens.resolveStroke(allocator, allocator, center, pen, settings, representation);
}

/// Bounds in picture coordinates for the representation used by the renderer.
/// Native ellipse strokes use the ordinary pen bounds. Filled envelopes use
/// their actual transformed Bézier extrema, including any underlying fill.
pub fn inkBounds(stroke: *const pens.Stroke, segments: []const Path.Segment, style: *const DisplayList.Style, transform: g.Transform) !?g.BBox {
    if (stroke.transform != null) return DisplayList.pathBounds(segments, style.pen, transform);
    const ink = try Path.paintedBounds(stroke.path.segments.items, transform);
    if (style.fill != null) if (try Path.paintedBounds(segments, transform)) |fill|
        return if (ink) |edge| fill.unite(edge) else fill;
    return ink;
}

test "ellipse normalization preserves centerline and physical nib offset" {
    const original = [_]Path.Segment{ .{ .move = .{ .x = 16, .y = 20 } }, .{ .line = .{ .x = 80, .y = 20 } } };
    const pen: DisplayList.Pen = .{ .nib = .{ .ellipse = .{ .a = 8, .d = 2, .e = 3, .f = 4 } }, .cap = .round, .join = .round };
    var stroke = try resolve(std.testing.allocator, &original, &.{ .pen = pen }, .{});
    defer stroke.path.deinit();
    const transform = stroke.transform.?.then(g.Transform.translation(10, 30));
    try std.testing.expectEqualDeep(g.Point{ .x = 29, .y = 54 }, transform.apply(stroke.path.segments.items[0].move));
    try std.testing.expectEqualDeep(g.Point{ .x = 93, .y = 54 }, transform.apply(stroke.path.segments.items[1].line));
}

test "polygon nib cap styles reach the computed stroke outline" {
    const segments = [_]Path.Segment{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 10, .y = 0 } } };
    const vertices = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    for ([_]DisplayList.Cap{ .butt, .square }, [_]f64{ -2, -6 }) |cap, expected_min| {
        const pen: DisplayList.Pen = .{ .nib = .{ .polygon = &vertices }, .cap = cap, .join = .bevel };
        var stroke = try resolve(std.testing.allocator, &segments, &.{ .pen = pen }, .{});
        defer stroke.path.deinit();
        try std.testing.expect(stroke.transform == null);
        var minimum: f64 = std.math.inf(f64);
        for (stroke.path.segments.items) |segment| switch (segment) {
            .move, .line => |point| minimum = @min(minimum, point.x),
            else => {},
        };
        try std.testing.expectApproxEqAbs(expected_min, minimum, 0.002);
    }
}
