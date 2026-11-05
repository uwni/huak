//! MetaPost is used only to refresh the retained independent CSV oracle.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const g = core.geometry;
const Path = core.Path;
const pens = core.pen;
const Point = g.Point;
const Cubic = g.Cubic;

const reference = @embedFile("../fixtures/envelope-reference.csv");
const control_tolerance = 1e-7;
const geometry_tolerance = 2e-5;

const Shape = enum { monotone, inflection, cusp, near_cusp, semicusp, semicusp_tiny, semicusp_near, corner, acute, reversal, closed_cubic, closed_reflex, zero, singleton };
const Nib = enum { rectangle, sheared, triangle };
const rectangle = [_]Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };
const sheared = [_]Point{ .{ .x = 0.5, .y = -3 }, .{ .x = 4.5, .y = -3 }, .{ .x = 5.5, .y = -1 }, .{ .x = 1.5, .y = -1 } };
const triangle = [_]Point{ .{ .x = -2, .y = -1 }, .{ .x = 3, .y = 0 }, .{ .x = -1, .y = 4 } };
const Case = struct {
    name: []const u8,
    shape: Shape,
    nib: Nib = .rectangle,
    reverse: bool = false,
    cap: pens.Cap = .round,
    join: pens.Join = .round,
    miter_limit: f64 = 4,

    fn vertices(self: Case) []const Point {
        return switch (self.nib) {
            .rectangle => &rectangle,
            .sheared => &sheared,
            .triangle => &triangle,
        };
    }
    fn options(self: Case) pens.StrokeOptions {
        return .{ .tolerance = 1e-4, .cap = self.cap, .join = self.join, .miter_limit = self.miter_limit };
    }
};
const cases = [_]Case{
    .{ .name = "cubic-monotone", .shape = .monotone },
    .{ .name = "cubic-inflection", .shape = .inflection },
    .{ .name = "cubic-inflection-reversed", .shape = .inflection, .reverse = true },
    .{ .name = "cubic-sheared-offset", .shape = .inflection, .nib = .sheared },
    .{ .name = "cubic-triangle", .shape = .inflection, .nib = .triangle },
    .{ .name = "cubic-cusp", .shape = .cusp },
    .{ .name = "cubic-cusp-reversed", .shape = .cusp, .reverse = true },
    .{ .name = "cubic-near-cusp", .shape = .near_cusp },
    .{ .name = "cubic-near-cusp-reversed", .shape = .near_cusp, .reverse = true },
    .{ .name = "semicusp", .shape = .semicusp },
    .{ .name = "semicusp-reversed", .shape = .semicusp, .reverse = true },
    .{ .name = "semicusp-sheared", .shape = .semicusp, .nib = .sheared },
    .{ .name = "semicusp-sheared-reversed", .shape = .semicusp, .nib = .sheared, .reverse = true },
    .{ .name = "semicusp-tiny", .shape = .semicusp_tiny },
    .{ .name = "semicusp-tiny-reversed", .shape = .semicusp_tiny, .reverse = true },
    .{ .name = "semicusp-tiny-sheared", .shape = .semicusp_tiny, .nib = .sheared },
    .{ .name = "semicusp-tiny-sheared-reversed", .shape = .semicusp_tiny, .nib = .sheared, .reverse = true },
    .{ .name = "semicusp-near", .shape = .semicusp_near },
    .{ .name = "semicusp-near-reversed", .shape = .semicusp_near, .reverse = true },
    .{ .name = "semicusp-near-sheared", .shape = .semicusp_near, .nib = .sheared },
    .{ .name = "semicusp-near-sheared-reversed", .shape = .semicusp_near, .nib = .sheared, .reverse = true },
    .{ .name = "corner-butt-bevel", .shape = .corner, .cap = .butt, .join = .bevel },
    .{ .name = "corner-square-bevel", .shape = .corner, .cap = .square, .join = .bevel },
    .{ .name = "corner-round-bevel", .shape = .corner, .join = .bevel },
    .{ .name = "corner-butt-miter", .shape = .corner, .cap = .butt, .join = .miter },
    .{ .name = "corner-square-miter", .shape = .corner, .cap = .square, .join = .miter },
    .{ .name = "corner-round-miter", .shape = .corner, .join = .miter },
    .{ .name = "corner-butt-round", .shape = .corner, .cap = .butt },
    .{ .name = "corner-square-round", .shape = .corner, .cap = .square },
    .{ .name = "corner-round-round", .shape = .corner },
    .{ .name = "acute-miter", .shape = .acute, .cap = .butt, .join = .miter },
    .{ .name = "acute-miter-limited", .shape = .acute, .cap = .butt, .join = .miter, .miter_limit = 1 },
    .{ .name = "reversal-round", .shape = .reversal },
    .{ .name = "closed-cubic", .shape = .closed_cubic, .cap = .butt },
    .{ .name = "closed-cubic-reversed", .shape = .closed_cubic, .reverse = true, .cap = .butt },
    .{ .name = "closed-reflex-bevel", .shape = .closed_reflex, .cap = .butt, .join = .bevel },
    .{ .name = "closed-reflex-miter", .shape = .closed_reflex, .cap = .butt, .join = .miter },
    .{ .name = "closed-reflex-round", .shape = .closed_reflex, .cap = .butt },
    .{ .name = "closed-reflex-limited", .shape = .closed_reflex, .cap = .butt, .join = .miter, .miter_limit = 1 },
    .{ .name = "zero-butt", .shape = .zero, .cap = .butt },
    .{ .name = "zero-square", .shape = .zero, .cap = .square },
    .{ .name = "zero-round", .shape = .zero },
    .{ .name = "singleton-butt", .shape = .singleton, .cap = .butt },
    .{ .name = "singleton-square", .shape = .singleton, .cap = .square },
    .{ .name = "singleton-round", .shape = .singleton },
};

const Row = struct { name: []const u8, contour: usize, segment: usize, curve: Cubic };

fn readReference(a: std.mem.Allocator) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(a);
    var lines = std.mem.tokenizeScalar(u8, reference, '\n');
    try t.expectEqualStrings("case,contour,segment,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y", lines.next().?);
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ',');
        const name = fields.next() orelse return error.InvalidFixture;
        const contour = try std.fmt.parseInt(usize, fields.next().?, 10);
        const segment = try std.fmt.parseInt(usize, fields.next().?, 10);
        var coordinates: [8]f64 = undefined;
        for (&coordinates) |*coordinate| coordinate.* = try std.fmt.parseFloat(f64, fields.next() orelse return error.InvalidFixture);
        try t.expect(fields.next() == null);
        try rows.append(a, .{ .name = name, .contour = contour, .segment = segment, .curve = .{
            .p0 = .{ .x = coordinates[0], .y = coordinates[1] },
            .p1 = .{ .x = coordinates[2], .y = coordinates[3] },
            .p2 = .{ .x = coordinates[4], .y = coordinates[5] },
            .p3 = .{ .x = coordinates[6], .y = coordinates[7] },
        } });
    }
    return rows.toOwnedSlice(a);
}

fn centerline(a: std.mem.Allocator, case: Case) !Path {
    var path: Path = .init(a);
    errdefer path.deinit();
    const origin: Point = .zero;
    const zero = case.shape == .zero or case.shape == .singleton;
    const cusp = case.shape == .semicusp or case.shape == .semicusp_tiny or case.shape == .semicusp_near;
    try path.moveTo(if (zero) .{ .x = 5, .y = 7 } else if (cusp) .{ .x = 10, .y = -10 } else if (case.shape == .closed_cubic) .{ .x = 20, .y = 0 } else origin);
    switch (case.shape) {
        .monotone => try path.cubicTo(.{ .x = 20, .y = 10 }, .{ .x = 30, .y = 35 }, .{ .x = 60, .y = 40 }),
        .inflection => try path.cubicTo(.{ .x = 15, .y = 35 }, .{ .x = 45, .y = -35 }, .{ .x = 60, .y = 0 }),
        .cusp, .near_cusp => try path.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = -10, .y = if (case.shape == .near_cusp) 0.0001 else 0 }, origin),
        .semicusp, .semicusp_tiny, .semicusp_near => {
            const perturbation: f64 = if (case.shape == .semicusp_tiny) 1e-12 else if (case.shape == .semicusp_near) 1e-6 else 0;
            try path.cubicTo(.{ .x = -10.0 / 3.0, .y = 10 + perturbation }, .{ .x = -10.0 / 3.0, .y = -10 }, .{ .x = 10, .y = 10 });
        },
        .corner, .acute, .reversal => {
            try path.lineTo(.{ .x = 20, .y = 0 });
            try path.lineTo(switch (case.shape) {
                .corner => .{ .x = 20, .y = 20 },
                .acute => .{ .x = 5, .y = 5 },
                else => origin,
            });
        },
        .closed_cubic => {
            try path.cubicTo(.{ .x = 20, .y = 11 }, .{ .x = 11, .y = 20 }, .{ .x = 0, .y = 20 });
            try path.cubicTo(.{ .x = -11, .y = 20 }, .{ .x = -20, .y = 11 }, .{ .x = -20, .y = 0 });
            try path.cubicTo(.{ .x = -20, .y = -11 }, .{ .x = -11, .y = -20 }, .{ .x = 0, .y = -20 });
            try path.cubicTo(.{ .x = 11, .y = -20 }, .{ .x = 20, .y = -11 }, .{ .x = 20, .y = 0 });
            try path.close();
        },
        .closed_reflex => {
            for ([_]Point{ .{ .x = 30, .y = 0 }, .{ .x = 15, .y = 10 }, .{ .x = 30, .y = 25 }, .{ .x = 0, .y = 25 } }) |point| try path.lineTo(point);
            try path.close();
        },
        .zero => try path.lineTo(.{ .x = 5, .y = 7 }),
        .singleton => {},
    }
    if (!case.reverse) return path;
    const result = try path.reverse(a);
    path.deinit();
    return result;
}

fn expectedPath(a: std.mem.Allocator, rows: []const Row, name: []const u8) !Path {
    var path: Path = .init(a);
    errdefer path.deinit();
    var contour: ?usize = null;
    var segment: usize = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, name)) continue;
        if (contour == null or contour.? != row.contour) {
            if (contour != null) try path.close();
            try t.expectEqual(if (contour) |previous| previous + 1 else 0, row.contour);
            contour = row.contour;
            segment = 0;
            try path.moveTo(row.curve.p0);
        }
        try t.expectEqual(segment, row.segment);
        try t.expect(path.current.?.distance(row.curve.p0) <= control_tolerance);
        try path.cubicTo(row.curve.p1, row.curve.p2, row.curve.p3);
        segment += 1;
    }
    try t.expect(contour != null);
    try path.close();
    return path;
}

pub fn curves(a: std.mem.Allocator, path: Path) ![]Cubic {
    const result = try a.alloc(Cubic, path.segmentCount());
    errdefer a.free(result);
    for (result, 0..) |*curve, index| curve.* = (try path.curveAt(@floatFromInt(index))).curve;
    return result;
}

fn segmentDistance(point: Point, from: Point, to: Point) f64 {
    const delta = to.sub(from);
    const square = delta.dot(delta);
    return if (square == 0) point.distance(from) else point.distance(from.add(delta.scale(std.math.clamp(point.sub(from).dot(delta) / square, 0, 1))));
}
fn straight(curve: Cubic) bool {
    var direction = curve.p3.sub(curve.p0);
    if (direction.norm() <= control_tolerance) direction = curve.p1.sub(curve.p0);
    if (direction.norm() <= control_tolerance) direction = curve.p2.sub(curve.p0);
    if (direction.norm() <= control_tolerance) return true;
    const unit = direction.scale(1 / direction.norm());
    return @max(@abs(curve.p1.sub(curve.p0).cross(unit)), @abs(curve.p2.sub(curve.p0).cross(unit))) <= control_tolerance;
}
fn sameControls(first: Cubic, second: Cubic, tolerance: f64) bool {
    return first.p0.distance(second.p0) <= tolerance and first.p1.distance(second.p1) <= tolerance and
        first.p2.distance(second.p2) <= tolerance and first.p3.distance(second.p3) <= tolerance;
}

// Reuse the core's de Casteljau split. This test-only distance bound accepts
// arbitrary contour starts and MP's nonuniform parameterization of straight
// connectors; it does not flatten the candidate before checking its controls.
fn nearest(point: Point, curve: Cubic, best: *f64, depth: usize) void {
    const box = curve.controlBounds();
    const closest: Point = .{ .x = std.math.clamp(point.x, box.min.x, box.max.x), .y = std.math.clamp(point.y, box.min.y, box.max.y) };
    if (point.distance(closest) > best.*) return;
    const flatness = @max(segmentDistance(curve.p1, curve.p0, curve.p3), segmentDistance(curve.p2, curve.p0, curve.p3));
    if (flatness <= geometry_tolerance * 0.05 or depth == 24) {
        best.* = @min(best.*, segmentDistance(point, curve.p0, curve.p3));
        return;
    }
    const halves = curve.split(0.5);
    nearest(point, halves.left, best, depth + 1);
    nearest(point, halves.right, best, depth + 1);
}

/// Geometric deviation after excluding ONLY redundant straight retracing
/// whose local nonzero coverage is constant and equal on both results.
pub fn visibleSampledDeviation(first: []const Cubic, second: []const Cubic) !f64 {
    if (first.len == 0 or second.len == 0) return if (first.len == second.len) 0 else std.math.inf(f64);
    var maximum: f64 = 0;
    for ([_]struct { from: []const Cubic, to: []const Cubic }{ .{ .from = first, .to = second }, .{ .from = second, .to = first } }) |direction| {
        for (direction.from) |curve| for (0..17) |index| {
            const point = curve.at(@as(f64, @floatFromInt(index)) / 16);
            var distance = std.math.inf(f64);
            for (direction.to) |candidate| nearest(point, candidate, &distance, 0);
            if (distance > geometry_tolerance and straight(curve) and try redundantTrace(direction.from, direction.to, point)) continue;
            maximum = @max(maximum, distance);
        };
    }
    return maximum;
}

/// Independent paint samples: identical curve sets can still have different
/// nonzero fill when a hole's traversal direction changes.
pub fn coverageSampleMismatches(first: []const Cubic, second: []const Cubic) !usize {
    if (first.len == 0 or second.len == 0) return if (first.len == second.len) 0 else 1;
    var box = first[0].bounds();
    for (first[1..]) |curve| box = box.unite(curve.bounds());
    for (second) |curve| box = box.unite(curve.bounds());
    box = box.expanded(1);
    var mismatches: usize = 0;
    for (0..23) |y| for (0..27) |x| {
        const point: Point = .{
            .x = box.min.x + (box.max.x - box.min.x) * (@as(f64, @floatFromInt(x)) + 0.371) / 27,
            .y = box.min.y + (box.max.y - box.min.y) * (@as(f64, @floatFromInt(y)) + 0.613) / 23,
        };
        if ((try winding(first, point) != 0) != (try winding(second, point) != 0)) mismatches += 1;
    };
    return mismatches;
}

fn compareCurves(expected: []const Cubic, actual: []const Cubic, oracle_tolerance: f64) !usize {
    // Every genuinely curved piece must retain the independent oracle's full
    // controls (up to traversal direction), not merely endpoint/bbox/area.
    const used = try t.allocator.alloc(bool, actual.len);
    defer t.allocator.free(used);
    @memset(used, false);
    var count: usize = 0;
    for (expected) |curve| {
        if (straight(curve)) continue;
        var matched = false;
        for (actual, 0..) |candidate, index| {
            if (used[index] or straight(candidate)) continue;
            if (sameControls(curve, candidate, oracle_tolerance) or sameControls(curve, candidate.reversed(), oracle_tolerance)) {
                used[index] = true;
                matched = true;
                break;
            }
        }
        if (!matched) std.debug.print("missing cubic controls: {any}\nactual: {any}\n", .{ curve, actual });
        try t.expect(matched);
        count += 1;
    }
    var actual_count: usize = 0;
    for (actual) |curve| if (!straight(curve)) {
        actual_count += 1;
    };
    try t.expectEqual(count, actual_count);
    var redundant_samples: usize = 0;
    for ([_]struct { from: []const Cubic, to: []const Cubic }{ .{ .from = expected, .to = actual }, .{ .from = actual, .to = expected } }) |direction| {
        for (direction.from) |curve| for (0..17) |sample| {
            const point = curve.at(@as(f64, @floatFromInt(sample)) / 16);
            var distance = std.math.inf(f64);
            for (direction.to) |candidate| nearest(point, candidate, &distance, 0);
            if (distance > geometry_tolerance) {
                // MP can select either endpoint of a flat support face and
                // retain a different interior retracing. Permit this only for
                // straight pieces whose entire local neighborhood has the
                // SAME constant coverage on BOTH paths. A visible boundary,
                // missing hole or extra filled region cannot use this escape.
                const redundant = straight(curve) and try redundantTrace(direction.from, direction.to, point);
                if (!redundant) std.debug.print("visible boundary sample {any}: distance={d}\n", .{ point, distance });
                try t.expect(redundant);
                redundant_samples += 1;
            }
        };
    }
    return redundant_samples;
}

fn redundantTrace(first: []const Cubic, second: []const Cubic, point: Point) !bool {
    var occupied: ?bool = null;
    // Every offset is shorter than the rejected distance and non-axis-aligned.
    // Requiring constant occupancy also rejects nearby shifted boundaries.
    const epsilon = geometry_tolerance * 0.25;
    for (0..8) |index| {
        const angle = (@as(f64, @floatFromInt(index)) + 0.173) * std.math.pi / 4;
        const sample = point.add(.{ .x = epsilon * @cos(angle), .y = epsilon * @sin(angle) });
        const a = try winding(first, sample) != 0;
        const b = try winding(second, sample) != 0;
        if (a != b or (occupied != null and occupied.? != a)) return false;
        occupied = a;
    }
    return true;
}

pub fn winding(curves_: []const Cubic, point: Point) !i32 {
    var result: i32 = 0;
    for (curves_) |curve| {
        if (straight(curve)) {
            const first = curve.p0;
            const last = curve.p3;
            if ((first.y <= point.y and last.y > point.y) or (last.y <= point.y and first.y > point.y)) {
                const x = first.x + (point.y - first.y) * (last.x - first.x) / (last.y - first.y);
                if (x > point.x) result += if (last.y > first.y) @as(i32, 1) else -1;
            }
            continue;
        }
        const hits = try Path.intersectLineCubic(t.allocator, point, .{ .x = 1000, .y = point.y }, curve);
        defer t.allocator.free(hits);
        for (hits) |hit| {
            if (hit.b >= 1 or hit.a <= 0) continue;
            const derivative = curve.derivative(hit.b).y;
            if (@abs(derivative) > 1e-8) result += if (derivative > 0) @as(i32, 1) else -1;
        }
    }
    return result;
}

fn compareCase(rows: []const Row, case: Case) !void {
    errdefer std.debug.print("MetaPost envelope case: {s}\n", .{case.name});
    var center = try centerline(t.allocator, case);
    defer center.deinit();
    var expected = try expectedPath(t.allocator, rows, case.name);
    defer expected.deinit();
    var actual = try pens.strokeOutline(t.allocator, .{ .polygon = case.vertices() }, center, case.options());
    defer actual.deinit();
    const first = try curves(t.allocator, expected);
    defer t.allocator.free(first);
    const second = try curves(t.allocator, actual);
    defer t.allocator.free(second);
    if (case.shape == .zero or case.shape == .singleton) {
        // Retain the oracle's directional-envelope quirks, but deliberately
        // preserve the complete-stroke API's round/square zero-length dots.
        if (case.shape == .singleton and case.cap == .round) {
            _ = try compareCurves(first, second, control_tolerance);
            return;
        }
        for (first) |curve| try t.expect(curve.p0.distance(curve.p1) == 0 and curve.p0.distance(curve.p2) == 0 and curve.p0.distance(curve.p3) == 0);
        if (case.cap == .butt) return t.expectEqual(@as(usize, 0), second.len);
        const box = actual.bounds().?;
        try t.expectApproxEqAbs(@as(f64, 3), box.min.x, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 6), box.min.y, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 7), box.max.x, 1e-12);
        try t.expectApproxEqAbs(@as(f64, 8), box.max.y, 1e-12);
        try t.expect(try winding(second, .{ .x = 5.1, .y = 7.2 }) != 0);
        try t.expectEqual(@as(i32, 0), try winding(second, .{ .x = 8.1, .y = 7.2 }));
        return;
    }
    // At an EXACT semicubical cusp MP's double root path emits controls about
    // 2.45e-7 away from the analytic t=1/2 split. Only this ill-conditioned
    // oracle receives a separate 1e-6 bound; the analytic test below requires
    // the actual implementation to retain the exact controls within 1e-12.
    const oracle_tolerance: f64 = if (case.shape == .semicusp) 1e-6 else control_tolerance;
    const redundant = try compareCurves(first, second, oracle_tolerance);
    if (redundant != 0) std.debug.print("MetaPost {s}: {d} internal retracing samples differ; native controls and local nonzero coverage agree\n", .{ case.name, redundant });
    // Compare actual nonzero fill, including inner/outer closed boundaries.
    // Noninteger offsets avoid shared polygon corners and horizontal edges.
    for (0..7) |y| for (0..10) |x| {
        const point: Point = .{ .x = -24.37 + @as(f64, @floatFromInt(x)) * 10.13, .y = -24.29 + @as(f64, @floatFromInt(y)) * 10.17 };
        try t.expectEqual(try winding(first, point) != 0, try winding(second, point) != 0);
    };
    if (case.shape == .closed_cubic) {
        try t.expectEqual(@as(i32, 0), try winding(second, .{ .x = 0.37, .y = 0.29 }));
        try t.expect(try winding(second, .{ .x = 20.37, .y = 0.29 }) != 0);
    }
}

test "polygon pen envelopes preserve MetaPost cubic controls boundaries and nonzero coverage" {
    const rows = try readReference(t.allocator);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 735), rows.len);
    var failures: usize = 0;
    for (cases) |case| compareCase(rows, case) catch |err| {
        if (err == error.OutOfMemory) return err;
        std.debug.print("envelope case {s} failed: {s}\n", .{ case.name, @errorName(err) });
        failures += 1;
    };
    try t.expectEqual(@as(usize, 0), failures);
    for (rows) |row| {
        var known = false;
        for (cases) |case| known = known or std.mem.eql(u8, row.name, case.name);
        try t.expect(known);
    }
}

test "multi-subpath polygon envelopes equal independently stroked subpaths after input release" {
    const case: Case = .{ .name = "combined", .shape = .inflection, .nib = .sheared };
    var first = try centerline(t.allocator, case);
    defer first.deinit();
    var second = try centerline(t.allocator, .{ .name = "loop", .shape = .closed_cubic });
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
    const a = try curves(t.allocator, expected);
    defer t.allocator.free(a);
    const b = try curves(t.allocator, actual);
    defer t.allocator.free(b);
    _ = try compareCurves(a, b, control_tolerance);
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
    var center = try centerline(t.allocator, .{ .name = "analytic-cusp", .shape = .semicusp });
    defer center.deinit();
    var actual = try pens.strokeOutline(t.allocator, .{ .polygon = &rectangle }, center, .{});
    defer actual.deinit();
    const actual_curves = try curves(t.allocator, actual);
    defer t.allocator.free(actual_curves);
    var matched: [analytic.len]bool = @splat(false);
    var count: usize = 0;
    for (actual_curves) |candidate| {
        if (straight(candidate)) continue;
        var found = false;
        for (analytic, 0..) |expected, index| if (!matched[index] and sameControls(candidate, expected, 1e-12)) {
            matched[index] = true;
            found = true;
            break;
        };
        try t.expect(found);
        count += 1;
    }
    try t.expectEqual(analytic.len, count);
}

test "interior trace allowance rejects shifted boundaries missing holes and added ink" {
    const Fixture = struct {
        fn box(min: Point, max: Point) !Path {
            var path: Path = .init(t.allocator);
            errdefer path.deinit();
            try path.moveTo(min);
            try path.lineTo(.{ .x = max.x, .y = min.y });
            try path.lineTo(max);
            try path.lineTo(.{ .x = min.x, .y = max.y });
            try path.close();
            return path;
        }
    };
    var solid = try Fixture.box(.zero, .{ .x = 10, .y = 10 });
    defer solid.deinit();
    const original = try curves(t.allocator, solid);
    defer t.allocator.free(original);
    try t.expect(try redundantTrace(original, original, .{ .x = 5, .y = 5 }));
    var shifted = try solid.transformed(t.allocator, .translation(1, 0));
    defer shifted.deinit();
    const moved = try curves(t.allocator, shifted);
    defer t.allocator.free(moved);
    try t.expect(!try redundantTrace(original, moved, .{ .x = 0, .y = 5 }));
    var inner = try Fixture.box(.{ .x = 3, .y = 3 }, .{ .x = 7, .y = 7 });
    defer inner.deinit();
    var reverse = try inner.reverse(t.allocator);
    defer reverse.deinit();
    var ring = try solid.clone(t.allocator);
    defer ring.deinit();
    try ring.append(reverse);
    const hole = try curves(t.allocator, ring);
    defer t.allocator.free(hole);
    try t.expectEqual(@as(i32, 0), try winding(hole, .{ .x = 5, .y = 5 }));
    try t.expect(!try redundantTrace(hole, original, .{ .x = 5, .y = 5 }));
    try t.expect(!try redundantTrace(hole, original, .{ .x = 3, .y = 5 }));
    var covered = try solid.clone(t.allocator);
    defer covered.deinit();
    try covered.append(inner);
    const no_hole = try curves(t.allocator, covered);
    defer t.allocator.free(no_hole);
    // The geometric curve sets agree exactly even though the hole is filled.
    try t.expect(try visibleSampledDeviation(hole, no_hole) < geometry_tolerance);
    try t.expect(try coverageSampleMismatches(hole, no_hole) > 0);
    try t.expectEqual(@as(usize, 0), try coverageSampleMismatches(hole, hole));
    var island = try Fixture.box(.{ .x = 12, .y = 0 }, .{ .x = 14, .y = 2 });
    defer island.deinit();
    var extra = try solid.clone(t.allocator);
    defer extra.deinit();
    try extra.append(island);
    const added = try curves(t.allocator, extra);
    defer t.allocator.free(added);
    try t.expect(!try redundantTrace(original, added, .{ .x = 13, .y = 1 }));
}

fn allocationExercise(a: std.mem.Allocator) !void {
    const case: Case = .{ .name = "allocation", .shape = .inflection, .nib = .triangle };
    var center = try centerline(a, case);
    defer center.deinit();
    var result = try pens.strokeOutline(a, .{ .polygon = case.vertices() }, center, case.options());
    defer result.deinit();
    try t.expect(result.segmentCount() > 0);
}

test "polygon envelope ownership is released at every failed allocation" {
    var allocator = std.testing.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(allocator.allocator(), allocationExercise, .{});
}

const PRECISION_QUARTERS = [_]Cubic{
    .{ .p0 = .{ .x = 100, .y = 44 }, .p1 = .{ .x = 100, .y = 54 }, .p2 = .{ .x = 90, .y = 64 }, .p3 = .{ .x = 80, .y = 64 } },
    .{ .p0 = .{ .x = 80, .y = 64 }, .p1 = .{ .x = 70, .y = 64 }, .p2 = .{ .x = 60, .y = 54 }, .p3 = .{ .x = 60, .y = 44 } },
    .{ .p0 = .{ .x = 60, .y = 44 }, .p1 = .{ .x = 60, .y = 34 }, .p2 = .{ .x = 70, .y = 24 }, .p3 = .{ .x = 80, .y = 24 } },
    .{ .p0 = .{ .x = 80, .y = 24 }, .p1 = .{ .x = 90, .y = 24 }, .p2 = .{ .x = 100, .y = 34 }, .p3 = .{ .x = 100, .y = 44 } },
};

fn precisionLoop(origin: Point, start: usize) !Path {
    var path = Path.init(t.allocator);
    errdefer path.deinit();
    try path.moveTo(PRECISION_QUARTERS[start].p0.add(origin));
    for (0..PRECISION_QUARTERS.len) |offset| {
        const curve = PRECISION_QUARTERS[(start + offset) % PRECISION_QUARTERS.len];
        try path.cubicTo(curve.p1.add(origin), curve.p2.add(origin), curve.p3.add(origin));
    }
    try path.close();
    return path;
}

fn normalizePrimitives(path: *Path, origin: Point) void {
    // Normalize the actual representation first. Converting a world-space
    // line into interpolated cubic controls can itself introduce fake error.
    for (path.segments.items) |*segment| switch (segment.*) {
        .move => |point| segment.move = point.sub(origin),
        .line => |point| segment.line = point.sub(origin),
        .cubic => |curve| segment.cubic = .{ .c1 = curve.c1.sub(origin), .c2 = curve.c2.sub(origin), .end = curve.end.sub(origin) },
        .close => {},
    };
    if (path.current) |point| path.current = point.sub(origin);
    if (path.start) |point| path.start = point.sub(origin);
}

test "existing smooth knots retain complete controls and coverage at origin 1e16" {
    const square = [_]Point{ .{ .x = -4, .y = -4 }, .{ .x = 4, .y = -4 }, .{ .x = 4, .y = 4 }, .{ .x = -4, .y = 4 } };
    var source = try precisionLoop(.zero, 0);
    defer source.deinit();
    var baseline = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, source, .{ .tolerance = 1e-3 });
    defer baseline.deinit();
    const baseline_curves = try curves(t.allocator, baseline);
    defer t.allocator.free(baseline_curves);
    const origin: Point = .{ .x = 1e16, .y = 1e16 };
    for (0..PRECISION_QUARTERS.len) |start| {
        var unit_path = try precisionLoop(.zero, start);
        defer unit_path.deinit();
        var unit = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, unit_path, .{ .tolerance = 1e-3 });
        defer unit.deinit();
        var moved_path = try precisionLoop(origin, start);
        defer moved_path.deinit();
        var moved = try pens.strokeOutline(t.allocator, .{ .polygon = &square }, moved_path, .{ .tolerance = 1e-3 });
        defer moved.deinit();
        normalizePrimitives(&moved, origin);
        try t.expectEqualDeep(unit.segments.items, moved.segments.items);
        var cubic_count: usize = 0;
        for (moved.segments.items) |segment| if (segment == .cubic) {
            cubic_count += 1;
        };
        // Four original quarters, once on each side: no new subdivision.
        try t.expectEqual(@as(usize, 8), cubic_count);
        const actual_curves = try curves(t.allocator, moved);
        defer t.allocator.free(actual_curves);
        _ = try compareCurves(baseline_curves, actual_curves, 0);
        try t.expectEqual(@as(usize, 0), try coverageSampleMismatches(baseline_curves, actual_curves));
        try t.expectEqual(@as(i32, 0), try winding(actual_curves, .{ .x = 80.37, .y = 44.29 }));
        try t.expect(try winding(actual_curves, .{ .x = 102.37, .y = 44.29 }) != 0);
    }
}

test "all-corner cycles retain every join when reindexed" {
    const diamond = [_]Point{ .{ .x = 0, .y = -4 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 4 }, .{ .x = -4, .y = 0 } };
    const points = [_]Point{ .{ .x = 45, .y = 45 }, .{ .x = 125, .y = 35 }, .{ .x = 125, .y = 55 } };
    for ([_]struct { join: pens.Join, limit: f64, min_x: f64 }{
        .{ .join = .round, .limit = 12, .min_x = 41 },
        .{ .join = .bevel, .limit = 12, .min_x = 45 },
        .{ .join = .miter, .limit = 12, .min_x = 13 },
        .{ .join = .miter, .limit = 4, .min_x = 45 },
    }) |case| {
        var baseline: ?Path = null;
        defer if (baseline) |*path| path.deinit();
        for (0..points.len) |start| {
            var source = Path.init(t.allocator);
            defer source.deinit();
            try source.moveTo(points[start]);
            for (1..points.len) |offset| try source.lineTo(points[(start + offset) % points.len]);
            try source.close();
            var result = try pens.strokeOutline(t.allocator, .{ .polygon = &diamond }, source, .{ .join = case.join, .miter_limit = case.limit });
            defer result.deinit();
            try t.expectApproxEqAbs(case.min_x, result.bounds().?.min.x, 1e-10);
            if (baseline) |first| {
                const a = try curves(t.allocator, first);
                defer t.allocator.free(a);
                const b = try curves(t.allocator, result);
                defer t.allocator.free(b);
                try t.expect(try visibleSampledDeviation(a, b) < geometry_tolerance);
                try t.expectEqual(@as(usize, 0), try coverageSampleMismatches(a, b));
            } else baseline = try result.clone(t.allocator);
        }
    }
}
