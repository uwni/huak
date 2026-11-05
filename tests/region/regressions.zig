//! Production f64 region regressions using the original comparison corpus.
//! This test root links only the production region implementation. No research
//! backend, coordinate downcast or replacement fixture participates.
const std = @import("std");
const shared = @import("region_fixtures");
const core = shared.drawing;
const fixtures = shared.source;
const validation = shared.validation;

fn check(comptime name: []const u8) !void {
    const case = comptime blk: {
        for (fixtures.cases) |value| {
            if (std.mem.eql(u8, value.name, name)) break :blk value;
        }
        @compileError("unknown path regression fixture: " ++ name);
    };
    const allocator = std.testing.allocator;
    var data = try fixtures.input(allocator, case);
    defer data.deinit(allocator);
    const operations = [_]fixtures.Operation{ .difference, .intersection, .unite, .xor };
    for (operations) |operation| {
        var actual = core.region.combine(allocator, data.a, data.b, switch (operation) {
            .difference => .difference,
            .intersection => .intersect,
            .unite => .unite,
            .xor => .xor,
        }, .{
            .tolerance = case.tolerance,
            .fill_rule = if (case.fill == 1) .evenodd else .nonzero,
            .max_segments = if (case.expanded_budget) 1048576 else 65536,
            .max_vertices = if (case.expanded_budget) 4194304 else 1048576,
        }) catch |err| {
            std.debug.print("\nf64 region failed: {s} {s}, tolerance={e}: {s}\n", .{ case.name, @tagName(operation), case.tolerance, @errorName(err) });
            return err;
        };
        defer actual.deinit();
        const elements = try fixtures.elements(allocator, actual);
        defer allocator.free(elements);
        // Region Path has the production canonical nonzero filling contract.
        const report = try validation.verifyOperation(allocator, data, case, elements, 0, operation);
        if (report.grid_mismatch != 0 or report.special_mismatch != 0) {
            std.debug.print("\nf64 region coverage: {s} {s}, tolerance={e}: grid={d}/{d}, probes={d}/{d}\n", .{ case.name, @tagName(operation), case.tolerance, report.grid_mismatch, report.grid_checked, report.special_mismatch, report.special_checked });
            const alternate = try validation.verifyOperation(allocator, data, case, elements, 1, operation);
            const shape = validation.counts(elements);
            std.debug.print("same boundary evenodd: grid={d}/{d}, probes={d}/{d}; moves={d}, cubics={d}, lines={d}, closes={d}\n", .{ alternate.grid_mismatch, alternate.grid_checked, alternate.special_mismatch, alternate.special_checked, shape.moves, shape.cubics, shape.lines, shape.closes });
            for (elements[0..@min(elements.len, 20)], 0..) |element, index| {
                std.debug.print("element[{d}] verb={d} data={any}\n", .{ index, element.verb, element.data });
            }
        }
        try std.testing.expect(report.grid_checked != 0);
        try std.testing.expectEqual(@as(usize, 0), report.grid_mismatch);
        try std.testing.expectEqual(@as(usize, 0), report.special_mismatch);
        try std.testing.expectEqual(data.probes.len, report.special_checked);
        if (case.shape == .unchanged and operation == case.operation) {
            try std.testing.expect(validation.counts(elements).cubics >= 4);
            try std.testing.expect(try validation.preservation(allocator, data.ae, elements) <= case.tolerance * 0.25);
        }
        if ((case.shape == .coincident or case.shape == .coincident_reversed) and
            (operation == .difference or operation == .xor))
        {
            try std.testing.expectEqual(@as(usize, 0), elements.len);
        }
    }
}

test "Skia f64: unchanged cubic remains cubic" {
    try check("cubic_unchanged");
}
test "Skia f64: intersecting cubic lens" {
    try check("cubic_lens");
}
test "Skia f64: cubic and straight boundary" {
    try check("cubic_half");
}
test "Skia f64: 256 curved holes at default budget" {
    try check("256_curved_holes");
}
test "Skia f64: 256 curved holes at expanded budget" {
    try check("256_holes_expanded_budget");
}
test "Skia f64: opposite raw winding" {
    try check("opposite_raw_nonzero");
}
test "Skia f64: independent canonical winding" {
    try check("independent_canonical");
}
test "Skia f64: evenodd ring" {
    try check("evenodd_ring");
}
test "Skia f64: self intersection" {
    try check("self_intersection_clip");
}
test "Skia f64: translated origin 1e12" {
    try check("large_origin_1e12");
}
test "Skia f64: translated origin 1e16" {
    try check("huge_origin_1e16");
}
test "Skia f64: span 1e8 retains 1e-3 hole" {
    try check("span_1e8_hole_1e-3");
}
test "Skia f64: span 1e6 retains 1e-3 hole" {
    try check("span_1e6_hole_1e-3");
}
test "Skia f64: span 1e5 retains 1e-3 hole" {
    try check("span_1e5_hole_1e-3");
}
test "Skia f64: tiny 1e-24 coordinates" {
    try check("tiny_coordinates_1e-24");
}
test "Skia f64: near coincident curves" {
    try check("near_coincident_1e-4");
}
test "Skia f64: tangent circles" {
    try check("tangent_circles");
}
test "Skia f64: shared rectangle edge" {
    try check("shared_edge_rectangles");
}
test "Skia f64: collinear and repeated vertices" {
    try check("collinear_zero_repeated");
}
test "Skia f64: coincident curves" {
    try check("coincident_same_difference");
}
test "Skia f64: reversed coincident curves" {
    try check("coincident_reversed_difference");
}
