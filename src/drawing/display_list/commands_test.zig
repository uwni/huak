//! Tests of recording and bounds: transformed cubic extrema, nib snapshots, nested transforms and clips, label placement and bounds, invalid input, allocation failure and borrowed styles.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Storage = @import("../Storage.zig");
const Pen = Storage.Pen;
const Style = Storage.Style;
const Metrics = Storage.Metrics;
const DisplayList = @import("../DisplayList.zig");

fn rectangle(allocator: std.mem.Allocator, min: g.Point, max: g.Point) !Path {
    return Path.rectangle(allocator, min, max.x - min.x, max.y - min.y);
}

test "fill bounds use transformed cubic extrema, owned segments and command order" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.fill(path, .{ .color = .{ .r = 1, .a = 0.5 } }, g.Transform.scaling(2, 3));
    try path.transform(g.Transform.translation(1000, 0));
    const box = (try picture.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 200), box.max.x, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 225), box.max.y, 1e-12);
    try std.testing.expectEqual(@as(f64, 0.5), picture.commands.items[0].path.style.fill.?.color.a);
}

test "stroke patterns reject invalid lengths and miter limits" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 20, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    for ([_]Pen{
        .{ .dash = &.{ 0, 0 } },            .{ .dash = &.{ -1, 2 } },
        .{ .dash = &.{std.math.inf(f64)} }, .{ .dash_phase = std.math.nan(f64) },
        .{ .miter_limit = 0.5 },            .{ .miter_limit = std.math.inf(f64) },
    }) |pen| try std.testing.expectError(error.InvalidPen, picture.draw(path, pen, .{}));
    try std.testing.expectEqual(@as(usize, 0), picture.commands.items.len);
}

test "physical nib snapshots own polygon vertices and bounds follow nib transforms" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 20, .y = 0 });
    var vertices = [_]g.Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.draw(path, .{ .nib = .{ .polygon = &vertices }, .cap = .round, .join = .round }, .{});
    vertices[0].x = -100;
    const nib = picture.commands.items[0].path.style.pen.?.nib.?;
    try std.testing.expectEqual(@as(f64, -2), nib.polygon[0].x);
    const box = (try picture.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = -2, .y = -1 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 22, .y = 1 }, box.max);
}

test "nested transforms clipping and composition preserve draw order" {
    var shape = try rectangle(std.testing.allocator, .zero, .{ .x = 100, .y = 100 });
    defer shape.deinit();
    var clip = try rectangle(std.testing.allocator, .{ .x = 10, .y = 20 }, .{ .x = 40, .y = 50 });
    defer clip.deinit();
    var child = DisplayList.init(std.testing.allocator);
    defer child.deinit();
    try child.beginScope(g.Transform.translation(5, 7), clip);
    try child.fill(shape, .{ .color = .{ .g = 1 } }, .{});
    try child.endScope();
    var parent = DisplayList.init(std.testing.allocator);
    defer parent.deinit();
    try parent.append(&child, g.Transform.scaling(2, 3));
    const box = (try parent.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 81 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 90, .y = 171 }, box.max);
    try std.testing.expect(parent.commands.items[0] == .push);
    try std.testing.expect(parent.commands.items[2] == .path);
    try std.testing.expect(parent.commands.items[4] == .pop);
}

test "disjoint clips stay empty and stroke bounds cover transformed square caps" {
    var shape = try rectangle(std.testing.allocator, .zero, .{ .x = 1, .y = 1 });
    defer shape.deinit();
    var a = try rectangle(std.testing.allocator, .zero, .{ .x = 5, .y = 5 });
    defer a.deinit();
    var b = try rectangle(std.testing.allocator, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer b.deinit();
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.beginScope(.{}, a);
    try picture.beginScope(.{}, b);
    try picture.fill(shape, .black, .{});
    try picture.endScope();
    try picture.endScope();
    try std.testing.expect((try picture.bounds()) == null);
    try picture.draw(shape, .{ .width = 2, .cap = .square, .join = .bevel }, g.Transform.scaling(2, 3));
    const box = (try picture.bounds()).?;
    try std.testing.expect(box.contains(.{ .x = -3, .y = -4 }));
    try std.testing.expect(box.contains(.{ .x = 5, .y = 7 }));
}

test "baseline and tangent label placement convert y-down frames to y-up" {
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    const metrics = Metrics{ .width = 20, .height = 10, .baseline = 7 };
    try picture.labelAtBaseline(0, metrics, .{ .x = 10, .y = 30 }, .{});
    const first = picture.commands.items[0].label;
    try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 }, first.transform.apply(.{ .x = 0, .y = 7 }));
    const box = (try picture.bounds()).?;
    try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 27 }, box.min);
    try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 37 }, box.max);
    try picture.labelAlong(1, metrics, .{ .x = 50, .y = 60 }, .{ .x = 0, .y = 2 }, 3);
    const second = picture.commands.items[1].label;
    try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 60 }, second.transform.apply(.{ .x = 0, .y = 7 }));
    try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 80 }, second.transform.apply(.{ .x = 20, .y = 7 }));
}

test "label ink bounds share transforms clipping and diagnostic order with logical bounds" {
    const t = std.testing;
    const Resolver = struct {
        calls: usize = 0,
        fail: bool = false,
        pub fn resolveBounds(self: *@This(), reference: u32) anyerror!g.BBox {
            self.calls += 1;
            try t.expectEqual(@as(u32, 7), reference);
            if (self.fail) return error.MissingTestFrame;
            return .{ .min = .{ .x = -2, .y = -1 }, .max = .{ .x = 4, .y = 8 } };
        }
    };
    var resolver: Resolver = .{};
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var clip = try rectangle(t.allocator, .zero, .{ .x = 10, .y = 10 });
    defer clip.deinit();
    try picture.beginScope(.translation(10, 20), clip);
    try picture.addLabel(7, .{ .width = 2, .height = 3, .baseline = 2 }, .translation(1, 1));
    try picture.endScope();
    try t.expectEqualDeep(g.BBox{ .min = .{ .x = 11, .y = 21 }, .max = .{ .x = 13, .y = 24 } }, (try picture.bounds()).?);
    try t.expectEqualDeep(g.BBox{ .min = .{ .x = 10, .y = 20 }, .max = .{ .x = 15, .y = 29 } }, (try picture.boundsWith(&resolver)).?);
    resolver.fail = true;
    try t.expectError(error.MissingTestFrame, picture.boundsWith(&resolver));
    picture.commands.items[0].push.transform.a = std.math.inf(f64);
    try t.expectError(error.NonFinite, picture.boundsWith(&resolver));
    try t.expectError(error.NonFinite, picture.bounds());
    try t.expectEqual(@as(usize, 2), resolver.calls);
}

test "baselines outside the frame preserve baseline and tangent label placement" {
    for ([_]f64{ -3, 12 }) |baseline| {
        var picture = DisplayList.init(std.testing.allocator);
        defer picture.deinit();
        const metrics = Metrics{ .width = 20, .height = 10, .baseline = baseline };
        try picture.labelAtBaseline(0, metrics, .{ .x = 10, .y = 30 }, .{});
        const first = picture.commands.items[0].label;
        try std.testing.expectEqual(baseline, first.metrics.baseline);
        try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 }, first.transform.apply(.{ .x = 0, .y = baseline }));
        const box = (try picture.bounds()).?;
        try std.testing.expectEqualDeep(g.Point{ .x = 10, .y = 30 + baseline - 10 }, box.min);
        try std.testing.expectEqualDeep(g.Point{ .x = 30, .y = 30 + baseline }, box.max);
        try picture.labelAlong(1, metrics, .{ .x = 50, .y = 60 }, .{ .x = 0, .y = 2 }, 3);
        const second = picture.commands.items[1].label;
        try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 60 }, second.transform.apply(.{ .x = 0, .y = baseline }));
        try std.testing.expectEqualDeep(g.Point{ .x = 47, .y = 80 }, second.transform.apply(.{ .x = 20, .y = baseline }));
    }
}

test "invalid styles metrics open clips and groups are rejected" {
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try std.testing.expectError(error.InvalidStyle, picture.addPath(path, .{}, .{}));
    try std.testing.expectError(error.InvalidColor, picture.fill(path, .{ .color = .{ .a = 2 } }, .{}));
    try std.testing.expectError(error.InvalidPen, picture.draw(path, .{ .width = -1 }, .{}));
    try std.testing.expectError(error.InvalidPath, picture.beginScope(.{}, path));
    try std.testing.expectError(error.NonFinite, picture.fill(path, .black, .{ .a = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidMetrics, picture.addLabel(0, .{ .width = -1, .height = 1, .baseline = 2 }, .{}));
    try std.testing.expectError(error.InvalidMetrics, picture.addLabel(0, .{ .width = 1, .height = -1, .baseline = 0 }, .{}));
    inline for (.{ "width", "height", "baseline" }) |field| {
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
            var invalid = Metrics{ .width = 1, .height = 1, .baseline = 0 };
            @field(invalid, field) = value;
            try std.testing.expectError(error.NonFinite, picture.addLabel(0, invalid, .{}));
        }
    }
    try std.testing.expectError(error.UnbalancedGroups, picture.endScope());
    try std.testing.expectError(error.SelfAppend, picture.append(&picture, .{}));
    try picture.beginScope(.{}, null);
    try std.testing.expectError(error.UnbalancedGroups, picture.bounds());
    try picture.endScope();
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var path = try rectangle(allocator, .zero, .{ .x = 10, .y = 10 });
    defer path.deinit();
    var child = DisplayList.init(allocator);
    defer child.deinit();
    try child.beginScope(.{}, path);
    try child.filldraw(path, .{ .color = .{ .b = 1 } }, .{}, .{});
    try child.labelAtBaseline(0, .{ .width = 2, .height = 3, .baseline = 2 }, .{ .x = 5, .y = 5 }, .{});
    try child.endScope();
    var parent = DisplayList.init(allocator);
    defer parent.deinit();
    try parent.append(&child, .{});
    _ = try parent.bounds();
}

test "all picture allocation failures release owned arrays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "borrowed style survives command array growth" {
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    var path = Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 30, .y = 40 });
    const dashes = [_]f64{ 1, 2 };
    const style: Style = .{ .fill = .{ .color = .{ .r = 0.25, .g = 0.5, .b = 0.75 } }, .pen = .{ .width = 3, .dash = &dashes } };
    try picture.addPath(path, style, .{});
    while (picture.commands.items.len < picture.commands.capacity) try picture.addPath(path, style, .{});
    const borrowed = picture.commands.items[0].path.style;
    try picture.addPathView(&path, borrowed, .{});
    const stored = picture.commands.items[picture.commands.items.len - 1].path.style;
    try std.testing.expectEqualDeep(style, stored.*);
    try std.testing.expectEqualSlices(f64, &dashes, stored.pen.?.dash);
}
