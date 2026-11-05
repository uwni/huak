//! Existing profile contract exercised against the curve-region backend.
const std = @import("std");
const core = @import("drawing");
const g = core.geometry;
const Path = core.Path;
const polygon = core.region;
const profileOutline = polygon.profileStroke;

fn testLine(allocator: std.mem.Allocator) !Path {
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 100, .y = 0 });
    return path;
}
fn area(path: Path) f64 {
    return path.signedArea();
}
test "variable circular profiles form the expected trapezoid and preserve width knots" {
    const t = std.testing;
    var line = try testLine(t.allocator);
    defer line.deinit();
    var tapered = try profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer tapered.deinit();
    try t.expectApproxEqAbs(@as(f64, 600), area(tapered), 0.001);
    try t.expectApproxEqAbs(@as(f64, 10), tapered.bounds().?.height(), 0.001);
    var diamond = try profileOutline(t.allocator, line, &.{ 0, 0.5, 1 }, &.{ 0, 10, 0 }, .{});
    defer diamond.deinit();
    try t.expectApproxEqAbs(@as(f64, 500), area(diamond), 0.001);
}

test "constant profiles agree with ordinary circular stroke cap and join semantics" {
    const t = std.testing;
    var line = try testLine(t.allocator);
    defer line.deinit();
    for ([_]polygon.Cap{ .butt, .round, .square }) |cap| {
        for ([_]polygon.Join{ .miter, .round, .square, .bevel }) |join| {
            const options: polygon.Options = .{ .cap = cap, .join = join };
            var ordinary = try polygon.stroke(t.allocator, line, 4, options);
            defer ordinary.deinit();
            var profiled = try profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 4, 4 }, options);
            defer profiled.deinit();
            try t.expectApproxEqAbs(area(ordinary), area(profiled), 0.001);
            try t.expectApproxEqAbs(ordinary.bounds().?.width(), profiled.bounds().?.width(), 0.001);
            try t.expectApproxEqAbs(ordinary.bounds().?.height(), profiled.bounds().?.height(), 0.001);
        }
    }
}

test "constant profiles retain the curved tube region within the geometric error budget" {
    const t = std.testing;
    const construct = core.path_construct;
    const mm = 72.0 / 25.4;
    var curve = try construct.construct(t.allocator, &.{
        .{ .x = 75 * mm, .y = 43 * mm },  .{ .x = 105 * mm, .y = 65 * mm },
        .{ .x = 135 * mm, .y = 45 * mm }, .{ .x = 160 * mm, .y = 60 * mm },
    }, &.{ .smooth, .smooth, .smooth }, .{});
    defer curve.deinit();
    var outline = try profileOutline(t.allocator, curve, &.{ 0, 0.2, 0.7, 1 }, &.{ 13 * mm, 13 * mm, 13 * mm, 13 * mm }, .{ .cap = .round, .join = .round });
    defer outline.deinit();
    // Reference from the original varying-width algorithm, in square points.
    // The common spatial tolerance permits different subdivision vertices.
    try t.expectApproxEqAbs(@as(f64, 12775.544150207), area(outline), 0.02);
    try t.expect(!outline.open);
    try t.expectEqual(@as(usize, 4), curve.segments.items.len);
}

test "constant profiles preserve closed holes pen-up contours and stationary caps" {
    const t = std.testing;
    var path = try Path.circle(t.allocator, .zero, 20);
    defer path.deinit();
    try path.moveTo(.{ .x = 50, .y = 50 });
    try path.lineTo(.{ .x = 150, .y = 50 });
    var outline = try profileOutline(t.allocator, path, &.{ 0, 0.3, 1 }, &.{ 4, 4, 4 }, .{ .cap = .round, .join = .round });
    defer outline.deinit();
    var contours: usize = 0;
    for (outline.segments.items) |segment| if (segment == .close) {
        contours += 1;
    };
    try t.expectEqual(@as(usize, 3), contours);
    try t.expectApproxEqAbs(2 * std.math.pi * 20 * 4 + 100 * 4 + std.math.pi * 4, area(outline), 0.1);
    const box = outline.bounds().?;
    try t.expectApproxEqAbs(@as(f64, -22), box.min.x, 0.001);
    try t.expectApproxEqAbs(@as(f64, -22), box.min.y, 0.001);
    try t.expectApproxEqAbs(@as(f64, 152), box.max.x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 52), box.max.y, 0.001);
    var zero = try profileOutline(t.allocator, path, &.{ 0, 1 }, &.{ 0, 0 }, .{});
    defer zero.deinit();
    try t.expectEqual(@as(usize, 0), zero.segments.items.len);
    var point: Path = .init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    var square = try profileOutline(t.allocator, point, &.{ 0, 1 }, &.{ 4, 4 }, .{ .cap = .square });
    defer square.deinit();
    try t.expectApproxEqAbs(@as(f64, 16), area(square), 0.001);
}

test "constant profiles validate every knot and retain empty-path precision and error precedence" {
    const t = std.testing;
    var empty: Path = .init(t.allocator);
    defer empty.deinit();
    for ([_]f64{ 0, 1e-20, std.math.floatTrueMin(f64) }) |width| {
        var result = try profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ width, width }, .{});
        defer result.deinit();
        try t.expectEqual(@as(usize, 0), result.segments.items.len);
    }
    try t.expectError(error.InvalidProfile, profileOutline(t.allocator, empty, &.{ 0, 0.8 }, &.{ 4, 4 }, .{}));
    try t.expectError(error.InvalidProfile, profileOutline(t.allocator, empty, &.{ 0, 0.4, 0.4, 1 }, &.{ 4, 4, 4, 4 }, .{}));
    try t.expectError(error.InvalidProfile, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ 4, 4, 4 }, .{}));
    try t.expectError(error.InvalidProfile, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ std.math.nan(f64), std.math.nan(f64) }, .{}));
    try t.expectError(error.GeometryWorkLimit, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ 4, 4 }, .{ .max_vertices = 1, .tolerance = 0 }));
    try t.expectError(error.InvalidTolerance, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ -1, -1 }, .{ .tolerance = 0, .miter_limit = 0 }));
    try t.expectError(error.InvalidMiterLimit, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ -1, -1 }, .{ .miter_limit = 0 }));
    try t.expectError(error.PrecisionRange, profileOutline(t.allocator, empty, &.{ 0, 1 }, &.{ 0, 0 }, .{ .tolerance = std.math.floatTrueMin(f64) * 4 }));
    var curve = try Path.circle(t.allocator, .zero, 20);
    defer curve.deinit();
    try t.expectError(error.GeometryWorkLimit, profileOutline(t.allocator, curve, &.{ 0, 1 }, &.{ 4, 4 }, .{ .max_segments = 1 }));
    try t.expectError(error.GeometryWorkLimit, profileOutline(t.allocator, curve, &.{ 0, 1 }, &.{ 4, 4 }, .{ .max_depth = 0 }));
    try t.expectError(error.GeometryWorkLimit, profileOutline(t.allocator, curve, &.{ 0, 0.2, 0.5, 1 }, &.{ 4, 4, 4, 4 }, .{ .max_vertices = 3 }));
}

fn constantAllocationExercise(allocator: std.mem.Allocator) !void {
    var path = try testLine(allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 20 });
    try path.lineTo(.{ .x = 100, .y = 20 });
    var result = try profileOutline(allocator, path, &.{ 0, 0.2, 0.7, 1 }, &.{ 4, 4, 4, 4 }, .{ .cap = .round });
    defer result.deinit();
}

test "constant profile allocation failures release flattening and native result storage" {
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), constantAllocationExercise, .{});
}

test "profiles restart at pen-up moves and closed seams retain holes" {
    const t = std.testing;
    var line = try testLine(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = 0, .y = 20 });
    try line.lineTo(.{ .x = 100, .y = 20 });
    var pair = try profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 2, 10 }, .{});
    defer pair.deinit();
    try t.expectApproxEqAbs(@as(f64, 1200), area(pair), 0.001);
    var square = Path.init(t.allocator);
    defer square.deinit();
    try square.moveTo(.zero);
    try square.lineTo(.{ .x = 10, .y = 0 });
    try square.lineTo(.{ .x = 10, .y = 10 });
    try square.lineTo(.{ .x = 0, .y = 10 });
    try square.close();
    var ring = try profileOutline(t.allocator, square, &.{ 0, 0.5, 1 }, &.{ 2, 4, 2 }, .{});
    defer ring.deinit();
    try t.expect(!ring.open);
    try t.expect(area(ring) > 80);
    var negative: usize = 0;
    for (ring.segments.items) |segment| if (segment == .close) {
        negative += 1;
    };
    try t.expectEqual(@as(usize, 2), negative);
    try t.expectError(error.DiscontinuousClosedProfile, profileOutline(t.allocator, square, &.{ 0, 1 }, &.{ 2, 4 }, .{}));
}

test "profiles handle stationary caps zero widths invalid data and work budgets" {
    const t = std.testing;
    var point = Path.init(t.allocator);
    defer point.deinit();
    try point.moveTo(.zero);
    var disk = try profileOutline(t.allocator, point, &.{ 0, 1 }, &.{ 4, 4 }, .{ .cap = .round });
    defer disk.deinit();
    try t.expectApproxEqAbs(@as(f64, 4 * std.math.pi), area(disk), 0.01);
    var line = try testLine(t.allocator);
    defer line.deinit();
    var zero = try profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 0, 0 }, .{});
    defer zero.deinit();
    try t.expectEqual(@as(usize, 0), zero.segments.items.len);
    for ([_][]const f64{ &.{ 1, 0 }, &.{ 0, 0 }, &.{ 0.1, 1 }, &.{ 0, std.math.nan(f64) } }) |positions| {
        try t.expectError(error.InvalidProfile, profileOutline(t.allocator, line, positions, &.{ 1, 1 }, .{}));
    }
    try t.expectError(error.InvalidProfile, profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ -1, 1 }, .{}));
    try t.expectError(error.GeometryWorkLimit, profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 4, 4 }, .{ .max_vertices = 3 }));
    try t.expectError(error.PrecisionRange, profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ 1e-20, 1e-20 }, .{}));
    try t.expectError(error.PrecisionRange, profileOutline(t.allocator, line, &.{ 0, 1 }, &.{ std.math.floatTrueMin(f64), std.math.floatTrueMin(f64) }, .{}));
}

test "profile centerlines retain collinearity under translated floating interpolation" {
    const t = std.testing;
    var line = Path.init(t.allocator);
    defer line.deinit();
    const mm = 72.0 / 25.4;
    try line.moveTo(.{ .x = 10 * mm, .y = 70 * mm });
    try line.lineTo(.{ .x = 65 * mm, .y = 70 * mm });
    var positions: [17]f64 = undefined;
    var widths: [17]f64 = undefined;
    for (&positions, &widths, 0..) |*position, *width, index| {
        const u = @as(f64, @floatFromInt(index)) / 16;
        position.* = u;
        width.* = 2 * mm * (0.7 + 0.2 * @cos(4 * std.math.pi * u));
    }
    var outline = try profileOutline(t.allocator, line, &positions, &widths, .{ .cap = .round, .join = .round });
    defer outline.deinit();
    try t.expect(area(outline) > 100);
}

test "continuous tapers retain zero ends and closed curve seams at native precision" {
    const t = std.testing;
    var curve = Path.init(t.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 80 }, .{ .x = 100, .y = 80 }, .{ .x = 100, .y = 0 });
    var circle = try Path.circle(t.allocator, .zero, 40);
    defer circle.deinit();
    var positions: [65]f64 = undefined;
    var widths: [65]f64 = undefined;
    for (&positions, &widths, 0..) |*position, *width, index| {
        const u = @as(f64, @floatFromInt(index)) / 64;
        position.* = u;
        width.* = if (index == 0 or index == 64) 0 else 8 * @sin(std.math.pi * u);
    }
    for ([_]Path{ curve, circle }) |path| {
        var outline = try profileOutline(t.allocator, path, &positions, &widths, .{ .cap = .round, .join = .round });
        defer outline.deinit();
        try t.expect(outline.segments.items.len > 10);
        try t.expect(area(outline) > 100);
    }
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var path = try testLine(allocator);
    defer path.deinit();
    var outline = try profileOutline(allocator, path, &.{ 0, 0.3, 1 }, &.{ 0, 4, 1 }, .{});
    defer outline.deinit();
}
test "profile allocation failures release every intermediate and native result" {
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}
