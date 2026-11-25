// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! The event solver for two near-linear spans: ray pairing with re-aimed rays, and its fallback refinement.
const std = @import("std");
const n = @import("../../numeric.zig");
const curves = @import("../../curve.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const Intersections = @import("../../Intersections.zig");
const sect = @import("../sect.zig");
const Sect = @import("Sect.zig");
const Span = @import("Span.zig");

pub fn linesIntersect(self: *Sect, span: *Span, other: *Sect, other_span: *Span, result: *Intersections) usize {
    var this_ray: Intersections = .{};
    var other_ray: Intersections = .{};
    var this_line: curves.Line = .{ .points = .{ span.part.first(), span.part.last() } };
    var other_line: curves.Line = .{ .points = .{ other_span.part.first(), other_span.part.last() } };
    const first_ray_count = this_ray.intersectRay(other.curve, this_line);
    const second_ray_count = other_ray.intersectRay(self.curve, other_line);
    if (first_ray_count == 0 or second_ray_count == 0) return refineSpans(self, span, other, other_span, result);
    if (this_ray.used > 1) {
        var matches: usize = 0;
        for (this_ray.points[0..this_ray.used]) |point| for (this_line.points) |endpoint| {
            matches += @intFromBool(point.approximatelyEqual(endpoint));
        };
        if (matches == 2) return 2;
    }
    if (other_ray.used > 1) {
        var matches: usize = 0;
        for (other_ray.points[0..other_ray.used]) |point| for (other_line.points) |endpoint| {
            matches += @intFromBool(point.approximatelyEqual(endpoint));
        };
        if (matches == 2) return 2;
    }
    // Upstream is_parallel is disabled for every non-conic curve. This port
    // receives lines/quadratics/cubics, so no conic-only branch is active.
    var loop_count: usize = 0;
    var best_distance = std.math.floatMax(f64);
    while (true) {
        var closest = std.math.floatMax(f64);
        var close_index: usize = 0;
        var other_close_index: usize = 0;
        for (0..other_ray.used) |index| {
            if (!n.roughlyBetween(span.start_t, other_ray.parameters[0][index], span.end_t)) continue;
            for (0..this_ray.used) |other_index| {
                if (!n.roughlyBetween(other_span.start_t, this_ray.parameters[0][other_index], other_span.end_t)) continue;
                const distance = this_ray.points[other_index].distanceSquared(other_ray.points[index]);
                if (closest > distance) {
                    closest = distance;
                    close_index = index;
                    other_close_index = other_index;
                }
            }
        }
        if (closest == std.math.floatMax(f64)) break;
        const other_point = this_ray.points[other_close_index];
        const point = other_ray.points[close_index];
        if (n.between(span.start_t, other_ray.parameters[0][close_index], span.end_t) and n.between(other_span.start_t, this_ray.parameters[0][other_close_index], other_span.end_t) and other_point.approximatelyEqual(point)) {
            result.merge(&other_ray, close_index, &this_ray, other_close_index);
            return result.used;
        }
        const distance = other_point.distanceSquared(point);
        loop_count += 1;
        if (best_distance < distance or loop_count > 5) {
            var t = other_ray.parameters[0][close_index];
            var u = this_ray.parameters[0][other_close_index];
            var refined: Point = undefined;
            const refined_ok = @import("../guard.zig").refineWithin(self.curve, other.curve, .{ .start = span.start_t, .end = span.end_t }, .{ .start = other_span.start_t, .end = other_span.end_t }, &t, &u, &refined);
            if (refined_ok) {
                result.max = 1;
                _ = result.insert(t, u, refined);
                return 1;
            }
            return 0;
        }
        best_distance = distance;
        const other_start = other_ray.parameters[0][close_index];
        this_line.points[0] = self.curve.ptAtT(other_start);
        this_line.points[1] = this_line.points[0].add(self.curve.dxdyAtT(other_start));
        if (this_ray.intersectRay(other.curve, this_line) == 0) return refineSpans(self, span, other, other_span, result);
        const start = this_ray.parameters[0][other_close_index];
        other_line.points[0] = other.curve.ptAtT(start);
        other_line.points[1] = other_line.points[0].add(other.curve.dxdyAtT(start));
        if (other_ray.intersectRay(self.curve, other_line) == 0) return refineSpans(self, span, other, other_span, result);
    }
    var other_start: Span.Coincident = .{};
    var other_end: Span.Coincident = .{};
    other_start.setPerp(other.curve, other_span.start_t, other_span.part.first(), self.curve);
    other_end.setPerp(other.curve, other_span.end_t, other_span.part.last(), self.curve);
    var start_t = other_start.t;
    var end_t = other_end.t;
    const swap = start_t > end_t;
    if (swap) std.mem.swap(f64, &start_t, &end_t);
    start_t = @max(start_t, span.start_t);
    end_t = @min(end_t, span.end_t);
    if (start_t > end_t) return 0;
    var perp_start: Point = undefined;
    var perp_end: Point = undefined;
    if (start_t == span.start_t) {
        var coin: Span.Coincident = .{};
        coin.setPerp(self.curve, span.start_t, span.part.first(), other.curve);
        perp_start = span.part.first().sub(coin.point);
    } else if (swap) perp_start = other_end.point.sub(other_span.part.last()) else perp_start = other_start.point.sub(other_span.part.first());
    if (end_t == span.end_t) {
        var coin: Span.Coincident = .{};
        coin.setPerp(self.curve, span.end_t, span.part.last(), other.curve);
        perp_end = span.part.last().sub(coin.point);
    } else if (swap) perp_end = other_start.point.sub(other_span.part.first()) else perp_end = other_end.point.sub(other_span.part.last());
    if (perp_start.dot(perp_end) >= 0) return 0;
    var work: Span.Coincident = .{};
    var work_t = start_t;
    var step = end_t - start_t;
    var point: Point = undefined;
    while (true) {
        step *= 0.5;
        if (n.preciselyZero(step)) return 0;
        work_t += step;
        point = self.curve.ptAtT(work_t);
        work.setPerp(self.curve, work_t, point, other.curve);
        if (if (work.match) !n.between(other_span.start_t, work.t, other_span.end_t) else work.t < 0) continue;
        if ((perp_start.dot(point.sub(work.point)) >= 0) == (step < 0)) step = -step;
        if (point.approximatelyEqual(work.point)) break;
    }
    if (!(other.head orelse return 0).contains(work.t)) return 0;
    result.max = 1;
    _ = result.insert(work_t, work.t, point);
    return 1;
}

fn refineSpans(self: *Sect, span: *Span, other: *Sect, other_span: *Span, result: *Intersections) usize {
    // A nearly quadratic ray polynomial can have a tiny nonzero cubic term;
    // the inherited Cardano solve may lose both finite roots. Reuse the same
    // compensated, damped, span-bounded refinement as failed tangent iteration.
    // A rejected refinement contributes no event and changes no tolerance.
    var t = (span.start_t + span.end_t) / 2;
    var u = (other_span.start_t + other_span.end_t) / 2;
    var point: Point = undefined;
    if (!@import("../guard.zig").refineWithin(self.curve, other.curve, .{ .start = span.start_t, .end = span.end_t }, .{ .start = other_span.start_t, .end = other_span.end_t }, &t, &u, &point)) return 0;
    result.max = 1;
    _ = result.insert(t, u, point);
    return result.used;
}

test "TSect failed ray recovery retains genuine cubic interior events" {
    // The 1e-12 final ordinate makes A a genuine cubic. Its first interior
    // event is lost by the original f64 Cardano ray solve even after B is
    // reduced to a quadratic; source-end recovery must retain the guard.
    for ([_]i32{ -8, 0, 8 }) |exponent| {
        var a: curves.Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 1e-12 } } };
        var b: curves.Cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
        for (&a.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        for (&b.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        // B is the degree elevation of this quadratic, scaled exactly.
        var q: curves.Quad = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1.5, .y = -2 }, .{ .x = 3, .y = 1 } } };
        for (&q.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        const source_a: Curve = .{ .cubic = a };
        const source_b: Curve = .{ .cubic = b };
        const lowered_b: Curve = .{ .quad = q };
        for ([_]Curve{ source_b, lowered_b }) |second| {
            var result: Intersections = .{};
            try std.testing.expectEqual(@as(usize, 2), try sect.intersect(std.testing.allocator, source_a, second, &result));
            try std.testing.expectApproxEqAbs(@as(f64, 0.0917517095361369), result.parameters[0][0], 1e-12);
            try std.testing.expectApproxEqAbs(@as(f64, 0.9082482904639391), result.parameters[0][1], 1e-12);
            for (0..result.used) |index| {
                try std.testing.expectApproxEqAbs(result.parameters[0][index], result.parameters[1][index], 1e-12);
                try std.testing.expect(source_a.ptAtT(result.parameters[0][index]).distance(second.ptAtT(result.parameters[1][index])) < 1e-12);
                try std.testing.expect(!result.isCoincident(index));
            }
        }
    }
}

test "TSect ray pairing selects matching active point indices" {
    // Local pairing contract: A has roots 1/4, 1/2, 3/4 on y=0;
    // B intersects A's endpoint chord only at 1/2. The nearest pair is exact.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 2, .y = -9 },  .{ .x = 3, .y = 13 },
        .{ .x = 4, .y = -13 }, .{ .x = 5, .y = 9 },
    } } };
    const b: Curve = .{ .line = .{ .points = .{ .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 } } } };
    var first = try Sect.init(arena.allocator(), a);
    var second = try Sect.init(arena.allocator(), b);
    var found: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), linesIntersect(&first, first.head.?, &second, second.head.?, &found));
    try std.testing.expectEqual(@as(f64, 0.5), found.parameters[0][0]);
    try std.testing.expectEqual(@as(f64, 0.5), found.parameters[1][0]);
}
