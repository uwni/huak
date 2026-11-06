//! Physical pens resolved with the existing geometry algorithms. Ordinary
//! strokes already have a native representation and need no intermediate plan.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Path = @import("../../drawing/path/Path.zig");
const pens = @import("../../drawing/pen/root.zig");

pub const Stroke = struct {
    path: Path,
    style: DisplayList.Style,
    /// Elliptical normalization changes coordinates; an envelope already uses
    /// the source coordinates and needs no additional matrix composition.
    transform: ?g.Transform = null,

    pub fn deinit(self: *Stroke) void {
        self.path.deinit();
    }
};

/// Draw and erase share one stored footprint, including a precision budget
/// for either native export format. Keep encoding constraints out of the
/// standalone geometry kernel. Units are physical points in the path frame.
pub fn motionFootprint(allocator: std.mem.Allocator, center: Path, pen: *const DisplayList.Pen, options: pens.StrokeOptions) !Path {
    var geometry = options;
    geometry.tolerance *= 0.75;
    var path = try pens.motionOutline(allocator, center, pen, geometry);
    errdefer path.deinit();
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
    if (magnitude > std.math.floatMax(f32) or @max(pdf, svg) > options.tolerance * 0.25) return error.OutputPrecisionRange;
    return path;
}

pub fn resolve(allocator: std.mem.Allocator, segments: []const Path.Segment, style: *const DisplayList.Style, options: pens.StrokeOptions) !?Stroke {
    var center = Path.init(allocator);
    center.segments.items = @constCast(segments);
    center.segments.capacity = segments.len;
    const pen = &style.pen.?;
    var settings = options;
    if (pen.motion) |motion| settings.tolerance = motion.tolerance;
    var stroke = try buildStroke(allocator, allocator, center, pen, settings, if (style.gradientFor(.stroke) != null) .outline else .native);
    if (stroke.path.segments.items.len != 0 or stroke.style.pen != null) return stroke;
    stroke.deinit();
    return null;
}

pub fn strokeFootprint(allocator: std.mem.Allocator, scratch: std.mem.Allocator, curve: Path, pen: *const DisplayList.Pen, tolerance: ?f64) !Path {
    var settings: pens.StrokeOptions = .{};
    if (pen.motion) |motion| settings.tolerance = motion.tolerance;
    if (tolerance) |value| settings.tolerance = value;
    return (try buildStroke(allocator, scratch, curve, pen, settings, .outline)).path;
}

fn buildStroke(allocator: std.mem.Allocator, scratch: std.mem.Allocator, source: Path, pen: *const DisplayList.Pen, options: pens.StrokeOptions, representation: enum { native, outline }) !Stroke {
    if (pen.motion != null) return .{ .path = try motionFootprint(allocator, source, pen, options), .style = .{ .fill = pen.color } };
    var geometry = options;
    geometry.cap = pen.cap;
    geometry.join = pen.join;
    geometry.miter_limit = pen.miter_limit;
    var dashed: ?Path = null;
    defer if (dashed) |*value| value.deinit();
    if (pen.dash.len != 0) dashed = try pens.dashed(scratch, source, pen.dash, pen.dash_phase, geometry);
    const center = dashed orelse source;
    const nib = try pen.fixedNib();
    const normalized = if (representation == .native) nib.normalizePath(allocator, center) catch |err| switch (err) {
        error.NonFinite => null,
        else => return err,
    } else null;
    if (normalized) |path| {
        var native_pen = pen.*;
        native_pen.nib = null;
        native_pen.width = 1;
        native_pen.dash = &.{};
        native_pen.dash_phase = 0;
        return .{ .path = path, .style = .{ .pen = native_pen }, .transform = nib.ellipse };
    }
    return .{ .path = try pens.strokeOutline(allocator, nib, center, geometry), .style = .{ .fill = pen.color } };
}

test "ellipse normalization preserves centerline and physical nib offset" {
    const original = [_]Path.Segment{ .{ .move = .{ .x = 16, .y = 20 } }, .{ .line = .{ .x = 80, .y = 20 } } };
    const pen: DisplayList.Pen = .{ .nib = .{ .ellipse = .{ .a = 8, .d = 2, .e = 3, .f = 4 } }, .cap = .round, .join = .round };
    var stroke = (try resolve(std.testing.allocator, &original, &.{ .pen = pen }, .{})).?;
    defer stroke.deinit();
    try std.testing.expectEqual(@as(f64, 1), stroke.style.pen.?.width);
    const transform = stroke.transform.?.then(g.Transform.translation(10, 30));
    try std.testing.expectEqualDeep(g.Point{ .x = 29, .y = 54 }, transform.apply(stroke.path.segments.items[0].move));
    try std.testing.expectEqualDeep(g.Point{ .x = 93, .y = 54 }, transform.apply(stroke.path.segments.items[1].line));
}

test "polygon nib cap styles reach the computed stroke outline" {
    const segments = [_]Path.Segment{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 10, .y = 0 } } };
    const vertices = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    for ([_]DisplayList.Cap{ .butt, .square }, [_]f64{ -2, -6 }) |cap, expected_min| {
        const pen: DisplayList.Pen = .{ .nib = .{ .polygon = &vertices }, .cap = cap, .join = .bevel };
        var stroke = (try resolve(std.testing.allocator, &segments, &.{ .pen = pen }, .{})).?;
        defer stroke.deinit();
        try std.testing.expect(stroke.style.fill != null);
        var minimum: f64 = std.math.inf(f64);
        for (stroke.path.segments.items) |segment| switch (segment) {
            .move, .line => |point| minimum = @min(minimum, point.x),
            else => {},
        };
        try std.testing.expectApproxEqAbs(expected_min, minimum, 0.002);
    }
}

fn exerciseNibGeometry(allocator: std.mem.Allocator) !void {
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 40, .y = 20 } },
        .{ .line = .{ .x = 40, .y = 40 } }, .close,
    };
    for ([_]pens.Nib{ pens.Nib.square(), .{ .ellipse = .{ .a = 4, .d = 2 } } }) |nib| {
        for ([_][]const f64{ &.{}, &.{ 4, 2 } }) |dash| {
            const pen: DisplayList.Pen = .{ .nib = nib, .cap = .round, .join = .round, .dash = dash, .dash_phase = 1 };
            var first = (try resolve(allocator, &source, &.{ .pen = pen }, .{})).?;
            defer first.deinit();
            var second = (try resolve(allocator, &source, &.{ .pen = pen }, .{})).?;
            defer second.deinit();
            try std.testing.expect(first.path.segments.items.len != 0);
            try std.testing.expect(first.path.segments.items.ptr != second.path.segments.items.ptr);
            try std.testing.expectEqualDeep(first.path.segments.items, second.path.segments.items);
            if (first.style.pen) |native| {
                try std.testing.expect(native.nib == null);
                try std.testing.expectEqual(@as(usize, 0), native.dash.len);
                try std.testing.expectEqual(@as(f64, 0), native.dash_phase);
            }
        }
    }
}

test "resolved strokes own their geometry and clean up every failed allocation" {
    try exerciseNibGeometry(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), exerciseNibGeometry, .{});
}

test "export rejects a moving outline below the physical coordinate precision budget" {
    const a = std.testing.allocator;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.{ .x = 100, .y = 0 });
    try path.lineTo(.{ .x = 110, .y = 0 });
    const motion: pens.Motion = .{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 2 }}, .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 1, .value = 2 } } };
    const paint: DisplayList.Pen = .{ .nib = pens.Nib.square(), .motion = &motion };
    try std.testing.expectError(error.OutputPrecisionRange, motionFootprint(a, path, &paint, .{ .tolerance = 1e-7 }));
    var output = try motionFootprint(a, path, &paint, .{ .tolerance = 0.001 });
    defer output.deinit();
    try std.testing.expect(output.segments.items.len > 0);
}
