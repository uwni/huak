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

pub fn resolve(allocator: std.mem.Allocator, segments: []const Path.Segment, pen: *const DisplayList.Pen, options: pens.StrokeOptions) !?Stroke {
    var center = Path.init(allocator);
    center.segments.items = @constCast(segments);
    center.segments.capacity = segments.len;
    if (pen.profile != null) {
        var outline = try pens.profiledOutline(allocator, center, pen, options);
        if (outline.segments.items.len != 0) return .{ .path = outline, .style = .{ .fill = pen.color } };
        outline.deinit();
        return null;
    }
    var dashed: ?Path = null;
    defer if (dashed) |*value| value.deinit();
    if (pen.dash.len != 0) {
        dashed = try pens.dashed(allocator, center, pen.dash, pen.dash_phase, options);
        center = dashed.?;
    }
    const nib = pen.nib.?;
    const normalized = nib.normalizePath(allocator, center) catch |err| switch (err) {
        error.NonFinite => null,
        else => return err,
    };
    if (normalized) |path| {
        var native_pen = pen.*;
        native_pen.nib = null;
        native_pen.width = 1;
        native_pen.dash = &.{};
        native_pen.dash_phase = 0;
        return .{ .path = path, .style = .{ .pen = native_pen }, .transform = nib.ellipse };
    }
    var geometry = options;
    geometry.cap = pen.cap;
    geometry.join = pen.join;
    geometry.miter_limit = pen.miter_limit;
    var outline = try pens.strokeOutline(allocator, nib, center, geometry);
    if (outline.segments.items.len == 0) {
        outline.deinit();
        return null;
    }
    return .{ .path = outline, .style = .{ .fill = pen.color } };
}

test "ellipse normalization preserves centerline and physical nib offset" {
    const original = [_]Path.Segment{ .{ .move = .{ .x = 16, .y = 20 } }, .{ .line = .{ .x = 80, .y = 20 } } };
    const pen: DisplayList.Pen = .{ .nib = .{ .ellipse = .{ .a = 8, .d = 2, .e = 3, .f = 4 } }, .cap = .round, .join = .round };
    var stroke = (try resolve(std.testing.allocator, &original, &pen, .{})).?;
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
        var stroke = (try resolve(std.testing.allocator, &segments, &pen, .{})).?;
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
            var first = (try resolve(allocator, &source, &pen, .{})).?;
            defer first.deinit();
            var second = (try resolve(allocator, &source, &pen, .{})).?;
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
