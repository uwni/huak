//! Same-input numerical boundary comparisons against retained MetaPost double
//! results. Unit-size, untranslated references distinguish shared arithmetic
//! failures from true scale/translation invariance of the geometry.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const reference_tools = @import("envelope.zig");
const Point = core.geometry.Point;
const Cubic = core.geometry.Cubic;
const inputs = @embedFile("../fixtures/envelope-numerics/inputs.json");
const oracle = @embedFile("../fixtures/envelope-numerics/results.json");

const Shape = struct { name: []const u8, closed: bool, curves: []const [8]f64 };
const Case = struct {
    name: []const u8,
    path: []const u8,
    scale: f64,
    origin: [2]f64 = .{ 0, 0 },
    pen_origin: [2]f64 = .{ 0, 0 },
    pen_y: f64 = 1,
    shear: f64 = 0,
    pen: enum { polygon, line, point, ellipse } = .polygon,
    reverse: bool = false,
    native_error: ?[]const u8 = null,

    fn position(self: Case, x: f64, y: f64) Point {
        return .{ .x = x * self.scale + self.origin[0], .y = y * self.scale + self.origin[1] };
    }
    fn normalized(self: Case, point: Point) Point {
        return .{ .x = (point.x - self.origin[0]) / self.scale, .y = (point.y - self.origin[1]) / self.scale };
    }
    fn nib(self: Case, storage: *[4]Point) core.pen.Nib {
        if (self.pen == .ellipse) return core.pen.Nib.circle();
        const rectangle = [_][2]f64{ .{ -2, -1 }, .{ 2, -1 }, .{ 2, 1 }, .{ -2, 1 } };
        const line = [_][2]f64{ .{ -2, 0 }, .{ 2, 0 } };
        const vertices: []const [2]f64 = switch (self.pen) {
            .line => &line,
            .point => &.{.{ 0, 0 }},
            else => &rectangle,
        };
        for (vertices, storage[0..vertices.len]) |point, *output| output.* = .{
            .x = (point[0] + self.shear * point[1] + self.pen_origin[0]) * self.scale,
            .y = (point[1] * self.pen_y + self.pen_origin[1]) * self.scale,
        };
        return .{ .polygon = storage[0..vertices.len] };
    }
};
const Input = struct { paths: []const Shape, cases: []const Case };
const InputCheck = struct { ok: bool, path_coordinates: usize, pen_coordinates: usize, mismatches: usize, max_abs_error: f64, max_ulp_error: []const u8 };
const Result = struct { name: []const u8, ok: bool, diagnostic: []const u8, curves: []const [8]f64, input_check: ?InputCheck, canonical_ok: bool, canonical_curves: []const [8]f64, canonical_input_check: ?InputCheck };
const Reference = struct { version: []const u8, input_sha256: []const u8, number_system: []const u8, normalization: []const u8, results: []const Result };

fn pathFor(case: Case, shape: Shape) !core.Path {
    var path: core.Path = .init(t.allocator);
    errdefer path.deinit();
    const start = shape.curves[0];
    try path.moveTo(case.position(start[0], start[1]));
    for (shape.curves) |curve| try path.cubicTo(case.position(curve[2], curve[3]), case.position(curve[4], curve[5]), case.position(curve[6], curve[7]));
    if (shape.closed) try path.close();
    if (!case.reverse) return path;
    const reversed = try path.reverse(t.allocator);
    path.deinit();
    return reversed;
}
fn curvesFrom(rows: []const [8]f64) ![]Cubic {
    const curves = try t.allocator.alloc(Cubic, rows.len);
    for (rows, curves) |row, *curve| curve.* = .{ .p0 = .{ .x = row[0], .y = row[1] }, .p1 = .{ .x = row[2], .y = row[3] }, .p2 = .{ .x = row[4], .y = row[5] }, .p3 = .{ .x = row[6], .y = row[7] } };
    return curves;
}

fn normalizedPath(case: Case, source: core.Path) !core.Path {
    var result: core.Path = .init(t.allocator);
    errdefer result.deinit();
    // Normalize the actual primitive BEFORE converting lines to cubic
    // parameterizations; interpolation at a huge origin can create spurious
    // bowed controls which were never present in the returned line geometry.
    for (source.segments.items) |segment| switch (segment) {
        .move => |point| try result.moveTo(case.normalized(point)),
        .line => |point| try result.lineTo(case.normalized(point)),
        .cubic => |curve| try result.cubicTo(case.normalized(curve.c1), case.normalized(curve.c2), case.normalized(curve.end)),
        .close => try result.close(),
    };
    return result;
}

test "single envelopes compare scales translations aspect ratios and cusps with MetaPost double" {
    const source = try std.json.parseFromSlice(Input, t.allocator, inputs, .{ .allocate = .alloc_always });
    defer source.deinit();
    const saved = try std.json.parseFromSlice(Reference, t.allocator, oracle, .{ .allocate = .alloc_always });
    defer saved.deinit();
    try t.expectEqualStrings("double", saved.value.number_system);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(inputs, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try t.expectEqualStrings(&digest_hex, saved.value.input_sha256);
    try t.expectEqual(source.value.cases.len, saved.value.results.len);
    var failures: usize = 0;
    var verified: usize = 0;
    for (source.value.cases, saved.value.results) |case, expected| {
        try t.expectEqualStrings(case.name, expected.name);
        const canonical_input = expected.canonical_input_check orelse return error.InvalidFixtureInput;
        try t.expect(canonical_input.ok);
        try t.expectEqual(@as(usize, 0), canonical_input.mismatches);
        if (expected.input_check) |input_check| {
            try t.expect(input_check.ok);
            try t.expectEqual(@as(usize, 0), input_check.mismatches);
        } else {
            try t.expect(!expected.ok);
            try t.expect(std.mem.indexOf(u8, expected.diagnostic, "Enormous number") != null);
        }
        var shape: ?Shape = null;
        for (source.value.paths) |candidate| if (std.mem.eql(u8, candidate.name, case.path)) {
            shape = candidate;
            break;
        };
        var path = try pathFor(case, shape orelse return error.InvalidFixture);
        defer path.deinit();
        var vertices: [4]Point = undefined;
        var output = core.pen.envelope(t.allocator, case.nib(&vertices), path, .{ .tolerance = @abs(case.scale) * 1e-3 }) catch |err| {
            std.debug.print("numeric {s}: huak={s} mp={s}\n", .{ case.name, @errorName(err), if (expected.ok) "ok" else "error" });
            if (case.native_error) |name| {
                try t.expectEqualStrings(name, @errorName(err));
                try t.expect(!expected.ok);
                verified += 1;
            } else failures += 1;
            continue;
        };
        defer output.deinit();
        try t.expect(case.native_error == null and expected.canonical_ok);
        var normalized = try normalizedPath(case, output);
        defer normalized.deinit();
        const actual = try reference_tools.curves(t.allocator, normalized);
        defer t.allocator.free(actual);
        for (actual) |curve| try t.expect(curve.isFinite());
        const canonical = try curvesFrom(expected.canonical_curves);
        defer t.allocator.free(canonical);
        const mp = try curvesFrom(expected.curves);
        defer t.allocator.free(mp);
        const native_deviation = try reference_tools.visibleSampledDeviation(canonical, actual);
        const coverage_mismatches = try reference_tools.coverageSampleMismatches(canonical, actual);
        if (expected.ok) {
            const mp_deviation = try reference_tools.visibleSampledDeviation(canonical, mp);
            const same_input_deviation = try reference_tools.visibleSampledDeviation(mp, actual);
            std.debug.print("numeric {s}: huak_unit={d:.9} mp_unit={d:.9} same_input={d:.9} coverage_mismatches={d}/621\n", .{ case.name, native_deviation, mp_deviation, same_input_deviation, coverage_mismatches });
        } else {
            std.debug.print("numeric {s}: huak_unit={d:.9} mp=input_scanner_error coverage_mismatches={d}/621\n", .{ case.name, native_deviation, coverage_mismatches });
        }
        // The requested absolute tolerance scales with the source geometry.
        // A noisy upstream result is measured, never copied as a golden error.
        if (native_deviation > 1e-3 or coverage_mismatches != 0) failures += 1 else verified += 1;
    }
    std.debug.print("numeric verified={d}/{d} failures={d}\n", .{ verified, source.value.cases.len, failures });
    try t.expectEqual(@as(usize, 0), failures);
}
