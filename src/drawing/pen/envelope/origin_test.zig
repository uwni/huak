//! Tests of exact offsets at large origins: lost offsets, square caps on native lines, implicit closing lines.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const nibs = @import("../nib.zig");
const Allocator = std.mem.Allocator;
const Point = g.Point;
const pen_envelope = @import("../envelope.zig");
const testing = @import("testing.zig");
const expectTestPoint = testing.expectTestPoint;
const envelope = pen_envelope.envelope;
const test_nib = testing.test_nib;
const stroke = pen_envelope.stroke;
const Options = pen_envelope.Options;

fn expectTranslatedTestPath(expected: Path, actual: Path, origin: Point) !void {
    try std.testing.expectEqual(expected.segments.items.len, actual.segments.items.len);
    for (expected.segments.items, actual.segments.items) |wanted, found| {
        try std.testing.expectEqual(std.meta.activeTag(wanted), std.meta.activeTag(found));
        switch (wanted) {
            .move => |point| try expectTestPoint(point, found.move.sub(origin)),
            .line => |point| try expectTestPoint(point, found.line.sub(origin)),
            .cubic => |curve| {
                try expectTestPoint(curve.c1, found.cubic.c1.sub(origin));
                try expectTestPoint(curve.c2, found.cubic.c2.sub(origin));
                try expectTestPoint(curve.end, found.cubic.end.sub(origin));
            },
            .close => {},
        }
    }
}

test "exact offsets survive large origins while genuinely lost offsets still fail" {
    const allocator = std.testing.allocator;
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.{ .x = 20, .y = 10 }, .{ .x = 30, .y = 35 }, .{ .x = 60, .y = 40 });
    var single = try envelope(allocator, .{ .polygon = &test_nib }, source, .{});
    defer single.deinit();
    var complete = try stroke(allocator, &test_nib, source, .{});
    defer complete.deinit();
    for ([_]f64{ 1e12, 1e15 }) |base| {
        const origin: Point = .{ .x = base, .y = -base };
        var translated = try source.transformed(allocator, g.Transform.translation(origin.x, origin.y));
        defer translated.deinit();
        var actual_single = try envelope(allocator, .{ .polygon = &test_nib }, translated, .{});
        defer actual_single.deinit();
        var actual_complete = try stroke(allocator, &test_nib, translated, .{});
        defer actual_complete.deinit();
        try expectTranslatedTestPath(single, actual_single, origin);
        try expectTranslatedTestPath(complete, actual_complete, origin);
    }
    var translated = try source.transformed(allocator, g.Transform.translation(1e15, -1e15));
    defer translated.deinit();
    const fractional = [_]Point{ .{ .x = -2.1, .y = -1 }, .{ .x = 2.1, .y = -1 }, .{ .x = 2.1, .y = 1 }, .{ .x = -2.1, .y = 1 } };
    try std.testing.expectError(error.PrecisionRange, envelope(allocator, .{ .polygon = &fractional }, translated, .{}));
    try std.testing.expectError(error.PrecisionRange, stroke(allocator, &fractional, translated, .{}));
    var point = Path.init(allocator);
    defer point.deinit();
    try point.moveTo(.{ .x = 1e20, .y = 1e20 });
    try std.testing.expectError(error.PrecisionRange, envelope(allocator, nibs.Nib.square(), point, .{}));
    try std.testing.expectError(error.PrecisionRange, stroke(allocator, nibs.Nib.square().polygon, point, .{}));
}

fn translatedLineCase(allocator: Allocator, closed: bool) !void {
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 20, .y = 0 });
    if (closed) {
        // Only the implicit return is a native line. The explicit cubic's
        // integer controls retain their vertical direction after translation.
        try source.cubicTo(.{ .x = 20, .y = 5 }, .{ .x = 20, .y = 15 }, .{ .x = 20, .y = 20 });
        try source.close();
    } else try source.lineTo(.{ .x = 20, .y = 20 });
    const options: Options = .{ .cap = .square, .join = .miter };
    var single = try envelope(allocator, .{ .polygon = &test_nib }, source, options);
    defer single.deinit();
    var complete = try stroke(allocator, &test_nib, source, options);
    defer complete.deinit();
    const origin: Point = .{ .x = 1e15, .y = -1e15 };
    var translated = try source.transformed(allocator, g.Transform.translation(origin.x, origin.y));
    defer translated.deinit();
    var actual_single = try envelope(allocator, .{ .polygon = &test_nib }, translated, options);
    defer actual_single.deinit();
    var actual_complete = try stroke(allocator, &test_nib, translated, options);
    defer actual_complete.deinit();
    try expectTranslatedTestPath(single, actual_single, origin);
    try expectTranslatedTestPath(complete, actual_complete, origin);
}

test "square caps on native lines retain exact directions at large origins" {
    try translatedLineCase(std.testing.allocator, false);
}

test "implicit closing lines retain exact directions at large origins" {
    try translatedLineCase(std.testing.allocator, true);
}
