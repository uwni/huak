//! Tests that sections partition the original stroke: joins, dash phases, closed seams, circle halves and long boundaries.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const DisplayList = @import("../../DisplayList.zig");
const dash = @import("../dash.zig");
const outline = @import("../outline.zig");
const region = @import("../../region/root.zig");
const Allocator = std.mem.Allocator;
const sections = @import("../sections.zig");

fn checkPartition(allocator: Allocator, source: Path, paint: DisplayList.Pen, ranges: []const sections.Range, whole: sections.Range) !void {
    const options: outline.Options = .{ .tolerance = 1e-4 };
    const pieces = try sections.extract(allocator, source, paint, ranges, options);
    defer {
        for (pieces) |*path| path.deinit();
        allocator.free(pieces);
    }
    const full = try sections.extract(allocator, source, paint, &.{whole}, options);
    defer {
        full[0].deinit();
        allocator.free(full);
    }
    var settings = options;
    settings.cap = paint.cap;
    settings.join = paint.join;
    settings.miter_limit = paint.miter_limit;
    var original_dash = try dash.dashed(allocator, source, paint.dash, paint.dash_phase, settings);
    defer original_dash.deinit();
    const nib = paint.nib orelse @import("../nib.zig").Nib{ .ellipse = g.Transform.scaling(paint.width, paint.width) };
    var native_tracing = try outline.strokeOutline(allocator, nib, original_dash, settings);
    defer native_tracing.deinit();
    var native = try region.combine(allocator, native_tracing, Path.init(allocator), .unite, .{ .tolerance = options.tolerance });
    defer native.deinit();
    var native_difference = try region.combine(allocator, native, full[0], .xor, .{ .tolerance = 1e-6 });
    defer native_difference.deinit();
    try std.testing.expect(@abs(native_difference.signedArea()) < 1e-5);
    var combined = Path.init(allocator);
    defer combined.deinit();
    for (pieces) |path| {
        const united = try region.combine(allocator, combined, path, .unite, .{ .tolerance = 1e-6 });
        combined.deinit();
        combined = united;
    }
    var missing = try region.combine(allocator, full[0], combined, .xor, .{ .tolerance = 1e-6 });
    defer missing.deinit();
    if (@abs(missing.signedArea()) >= 1e-5) {
        std.debug.print("section partition: cap={s}, join={s}, dash={any}, full={d}, combined={d}, xor={d}\n", .{ @tagName(paint.cap), @tagName(paint.join), paint.dash, full[0].signedArea(), combined.signedArea(), missing.signedArea() });
        var left = try region.combine(allocator, full[0], combined, .difference, .{ .tolerance = 1e-6 });
        defer left.deinit();
        var right = try region.combine(allocator, combined, full[0], .difference, .{ .tolerance = 1e-6 });
        defer right.deinit();
        std.debug.print("missing={d} {any}; extra={d} {any}\n", .{ left.signedArea(), left.segments.items, right.signedArea(), right.segments.items });
    }
    try std.testing.expect(@abs(missing.signedArea()) < 1e-5);
}

test "source sections partition original joins dash phases and closed seams" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    const ranges = [_]sections.Range{ .{ .contour = 0, .begin = 0, .end = 1 }, .{ .contour = 0, .begin = 1, .end = 2 } };
    inline for (.{ DisplayList.Join.miter, .round, .bevel }) |join| {
        try checkPartition(t.allocator, source, .{ .width = 2, .cap = .square, .join = join }, &ranges, .{ .contour = 0, .begin = 0, .end = 2 });
        try checkPartition(t.allocator, source, .{ .width = 2, .cap = .round, .join = join, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &ranges, .{ .contour = 0, .begin = 0, .end = 2 });
    }
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();
    const seam = [_]sections.Range{ .{ .contour = 0, .begin = 0, .end = 2 }, .{ .contour = 0, .begin = 2, .end = 4 } };
    try checkPartition(t.allocator, source, .{ .nib = .{ .polygon = &.{ .{ .x = -1, .y = -0.5 }, .{ .x = 1, .y = -0.5 }, .{ .x = 1, .y = 0.5 }, .{ .x = -1, .y = 0.5 } } }, .join = .miter }, &seam, .{ .contour = 0, .begin = 0, .end = 4 });
    try checkPartition(t.allocator, source, .{ .width = 2, .cap = .round, .dash = &.{ 15, 10 } }, &seam, .{ .contour = 0, .begin = 0, .end = 4 });
    var curve = Path.init(t.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 });
    try checkPartition(t.allocator, curve, .{ .nib = @import("../nib.zig").Nib.square(), .cap = .round, .dash = &.{ 3, 2 }, .dash_phase = 0.7 }, &.{ .{ .contour = 0, .begin = 0, .end = 0.37 }, .{ .contour = 0, .begin = 0.37, .end = 1 } }, .{ .contour = 0, .begin = 0, .end = 1 });
}

test "source closed cubic circle halves retain the full round stroke" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    const paint: DisplayList.Pen = .{ .width = 6, .cap = .round, .join = .round };
    const settings: outline.Options = .{ .tolerance = 0.001, .cap = .round, .join = .round };
    var original = try outline.strokeOutline(t.allocator, .{ .ellipse = .scaling(6, 6) }, source, settings);
    defer original.deinit();
    var whole = try region.combine(t.allocator, original, Path.init(t.allocator), .unite, .{ .tolerance = 0.001 });
    defer whole.deinit();
    const winding = @import("../../region/pathops/winding.zig");
    for (0..34) |x| for (0..34) |y| {
        const point: g.Point = .{ .x = 8.37 + 2 * @as(f64, @floatFromInt(x)), .y = 18.59 + 2 * @as(f64, @floatFromInt(y)) };
        try t.expectEqual(try winding.windingAt(original, point) != 0, try winding.windingAt(whole, point) != 0);
    };
    const result = try sections.extract(t.allocator, source, paint, &.{ .{ .contour = 0, .begin = 0, .end = 2 }, .{ .contour = 0, .begin = 2, .end = 4 } }, settings);
    defer {
        for (result) |*path| path.deinit();
        t.allocator.free(result);
    }
    for (0..34) |x| for (0..34) |y| {
        const point: g.Point = .{ .x = 8.37 + 2 * @as(f64, @floatFromInt(x)), .y = 18.59 + 2 * @as(f64, @floatFromInt(y)) };
        const covered = try winding.windingAt(result[0], point) != 0 or try winding.windingAt(result[1], point) != 0;
        try t.expectEqual(try winding.windingAt(original, point) != 0, covered);
    };
    var joined = Path.init(t.allocator);
    defer joined.deinit();
    for (result) |path| {
        const united = try region.combine(t.allocator, joined, path, .unite, .{ .tolerance = 0.001 });
        joined.deinit();
        joined = united;
    }
    var difference = try region.combine(t.allocator, whole, joined, .xor, .{ .tolerance = 0.001 });
    defer difference.deinit();
    if (@abs(difference.signedArea()) >= 1e-5) std.debug.print("circle native={d}, united={d}, xor={d}, bounds={any}\n", .{ whole.signedArea(), joined.signedArea(), difference.signedArea(), difference.bounds() });
    try t.expect(@abs(difference.signedArea()) < 1e-5);
}

test "source circle raw nonzero tracing agrees with its canonical region" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    var original = try outline.strokeOutline(t.allocator, .{ .ellipse = .scaling(6, 6) }, source, .{ .tolerance = 0.001, .cap = .round, .join = .round });
    defer original.deinit();
    var canonical = try region.combine(t.allocator, original, Path.init(t.allocator), .unite, .{ .tolerance = 0.001 });
    defer canonical.deinit();
    var difference = try region.combine(t.allocator, original, canonical, .xor, .{ .tolerance = 0.001 });
    defer difference.deinit();
    try t.expect(@abs(difference.signedArea()) < 1e-5);
}

test "source section offset retains a long inactive boundary" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    const result = try sections.extract(t.allocator, source, .{ .width = 6, .cap = .round, .join = .round }, &.{.{ .contour = 0, .begin = 0, .end = 2 }}, .{ .tolerance = 0.001 });
    defer {
        result[0].deinit();
        t.allocator.free(result);
    }
    // The normalized offset band has more than a thousand consecutive
    // inactive spans. Its union must finish the chase rather than stop at an
    // input-independent traversal limit.
    var expanded = try region.offset(t.allocator, result[0], 2, .{ .tolerance = 0.001, .join = .round });
    defer expanded.deinit();
    try t.expect(!expanded.open);
    const winding = @import("../../region/pathops/winding.zig");
    try t.expect(try winding.windingAt(expanded, .{ .x = 40, .y = 79 }) != 0);
    try t.expectEqual(@as(i32, 0), try winding.windingAt(expanded, .{ .x = 40, .y = 81 }));
    try t.expectEqual(@as(i32, 0), try winding.windingAt(expanded, .{ .x = 40, .y = 50 }));
}
