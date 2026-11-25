//! Polygon-pen envelopes compared with the retained MetaPost oracle in reference.zig, and their ownership on allocation failure.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const g = core.geometry;
const pens = core.pen;
const Point = g.Point;
const Cubic = g.Cubic;
const reference = @import("reference.zig");
const harness = @import("harness.zig");

fn compareCase(rows: []const reference.Row, case: reference.Case) !void {
    errdefer std.debug.print("MetaPost envelope case: {s}\n", .{case.name});
    var center = try reference.centerline(t.allocator, case);
    defer center.deinit();
    var expected = try reference.expectedPath(t.allocator, rows, case.name);
    defer expected.deinit();
    var actual = try pens.strokeOutline(t.allocator, .{ .polygon = case.vertices() }, center, case.options());
    defer actual.deinit();
    const first = try harness.curves(t.allocator, expected);
    defer t.allocator.free(first);
    const second = try harness.curves(t.allocator, actual);
    defer t.allocator.free(second);
    if (case.shape == .zero or case.shape == .singleton) {
        // Retain the oracle's directional-envelope quirks, but deliberately
        // preserve the complete-stroke API's round/square zero-length dots.
        if (case.shape == .singleton and case.cap == .round) {
            _ = try harness.compareCurves(first, second, harness.control_tolerance);
            return;
        }
        for (first) |curve| try t.expect(curve.p0.distance(curve.p1) == 0 and curve.p0.distance(curve.p2) == 0 and curve.p0.distance(curve.p3) == 0);
        if (case.cap == .butt) return t.expectEqual(@as(usize, 0), second.len);
        const box = actual.bounds().?;
        try t.expectApproxEqAbs(@as(f64, 3), box.min.x, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 6), box.min.y, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 7), box.max.x, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 8), box.max.y, 1e-12);
        try t.expect(try harness.winding(second, .{ .x = 5.1, .y = 7.2 }) != 0);
        try t.expectEqual(@as(i32, 0), try harness.winding(second, .{ .x = 8.1, .y = 7.2 }));
        return;
    }
    // At an EXACT semicubical cusp MP's double root path emits controls about
    // 2.45e-7 away from the analytic t=1/2 split. Only this ill-conditioned
    // oracle receives a separate 1e-6 bound; the analytic test below requires
    // the actual implementation to retain the exact controls within 1e-12.
    const oracle_tolerance: f64 = if (case.shape == .semicusp) 1e-6 else harness.control_tolerance;
    const redundant = try harness.compareCurves(first, second, oracle_tolerance);
    if (redundant != 0) std.debug.print("MetaPost {s}: {d} internal retracing samples differ; native controls and local nonzero coverage agree\n", .{ case.name, redundant });
    // Compare actual nonzero fill, including inner/outer closed boundaries.
    // Noninteger offsets avoid shared polygon corners and horizontal edges.
    for (0..7) |y| for (0..10) |x| {
        const point: Point = .{ .x = -24.37 + @as(f64, @floatFromInt(x)) * 10.13, .y = -24.29 + @as(f64, @floatFromInt(y)) * 10.17 };
        try t.expectEqual(try harness.winding(first, point) != 0, try harness.winding(second, point) != 0);
    };
    if (case.shape == .closed_cubic) {
        try t.expectEqual(@as(i32, 0), try harness.winding(second, .{ .x = 0.37, .y = 0.29 }));
        try t.expect(try harness.winding(second, .{ .x = 20.37, .y = 0.29 }) != 0);
    }
}

test "polygon pen envelopes preserve MetaPost cubic controls boundaries and nonzero coverage" {
    const rows = try reference.readReference(t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 735), rows.len);
    var failures: usize = 0;
    for (reference.cases) |case| compareCase(rows, case) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.debug.print("envelope case {s} failed: {s}\n", .{ case.name, @errorName(err) });
        failures += 1;
    };
    try t.expectEqual(@as(usize, 0), failures);
    for (rows) |row| {
        var known = false;
        for (reference.cases) |case| known = known or std.mem.eql(u8, row.name, case.name);
        try t.expect(known);
    }
}

test "multi-subpath polygon envelopes equal independently stroked subpaths after input release" {
    const case: reference.Case = .{ .name = "combined", .shape = .inflection, .nib = .sheared };
    var first = try reference.centerline(t.allocator, case);
    defer first.deinit();
    var second = try reference.centerline(t.allocator, .{ .name = "loop", .shape = .closed_cubic });
    defer second.deinit();
    try second.transform(.translation(100, 60));
    var combined = try first.clone(t.allocator);
    defer combined.deinit();
    try combined.append(second);
    var expected = try pens.strokeOutline(t.allocator, .{ .polygon = case.vertices() }, first, case.options());
    defer expected.deinit();
    var other = try pens.strokeOutline(t.allocator, .{ .polygon = case.vertices() }, second, case.options());
    defer other.deinit();
    try expected.append(other);
    var actual = try pens.strokeOutline(t.allocator, .{ .polygon = case.vertices() }, combined, case.options());
    defer actual.deinit();
    combined.deinit();
    combined = .init(t.allocator);
    const a = try harness.curves(t.allocator, expected);
    defer t.allocator.free(a);
    const b = try harness.curves(t.allocator, actual);
    defer t.allocator.free(b);
    _ = try harness.compareCurves(a, b, harness.control_tolerance);
}

test "exact semicubical cusp retains analytic half-cubic controls independently of MP root noise" {
    const original: Cubic = .{ .p0 = .{ .x = 10, .y = -10 }, .p1 = .{ .x = -10.0 / 3.0, .y = 10 }, .p2 = .{ .x = -10.0 / 3.0, .y = -10 }, .p3 = .{ .x = 10, .y = 10 } };
    try t.expect(original.at(0.5).norm() < 1e-12);
    try t.expect(original.derivative(0.5).norm() < 1e-12);
    const halves = original.split(0.5);
    const analytic = [_]Cubic{
        halves.left.transformed(.translation(2, 1)),
        halves.right.transformed(.translation(2, -1)),
        halves.right.reversed().transformed(.translation(-2, 1)),
        halves.left.reversed().transformed(.translation(-2, -1)),
    };
    var center = try reference.centerline(t.allocator, .{ .name = "analytic-cusp", .shape = .semicusp });
    defer center.deinit();
    var actual = try pens.strokeOutline(t.allocator, .{ .polygon = &reference.rectangle }, center, .{});
    defer actual.deinit();
    const actual_curves = try harness.curves(t.allocator, actual);
    defer t.allocator.free(actual_curves);
    var matched: [analytic.len]bool = @splat(false);
    var count: usize = 0;
    for (actual_curves) |candidate| {
        if (harness.straight(candidate)) continue;
        var found = false;
        for (analytic, 0..) |expected, index| if (!matched[index] and harness.sameControls(candidate, expected, 1e-12)) {
            matched[index] = true;
            found = true;
            break;
        };
        try t.expect(found);
        count += 1;
    }
    try t.expectEqual(analytic.len, count);
}

fn allocationExercise(a: std.mem.Allocator) !void {
    const case: reference.Case = .{ .name = "allocation", .shape = .inflection, .nib = .triangle };
    var center = try reference.centerline(a, case);
    defer center.deinit();
    var result = try pens.strokeOutline(a, .{ .polygon = case.vertices() }, center, case.options());
    defer result.deinit();
    try t.expect(result.segmentCount() > 0);
}

test "polygon envelope ownership is released at every failed allocation" {
    var allocator = std.testing.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(allocator.allocator(), allocationExercise, .{});
}

test {
    _ = @import("harness.zig");
    _ = @import("precision.zig");
}
