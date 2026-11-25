// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! Candidate span pairs: the hull test, the line shortcut, and trimming every bounded partner after a split.
const std = @import("std");
const curves = @import("../../curve.zig");
const Allocator = std.mem.Allocator;
const Intersections = @import("../../Intersections.zig");
const sect = @import("../sect.zig");
const Sect = @import("Sect.zig");
const Span = @import("Span.zig");
const lines = @import("lines.zig");

pub fn intersects(self: *Sect, span: *Span, other: *Sect, other_span: *Span, other_result: *i32, event: *Intersections) i32 {
    event.used = 0;
    var span_start: bool = undefined;
    var other_start: bool = undefined;
    var hull_result = span.hullsIntersect(other_span, &span_start, &other_start);
    if (hull_result >= 0) {
        if (hull_result == 2) {
            if (span.bounded == null or span.bounded.?.next == null) {
                if (span_start) span.end_t = span.start_t else span.start_t = span.end_t;
            } else hull_result = 1;
            if (other_span.bounded == null or other_span.bounded.?.next == null) {
                if (other_span.bounded != null and other_span.bounded.?.span != span) return 0;
                if (other_start) other_span.end_t = other_span.start_t else other_span.start_t = other_span.end_t;
                other_result.* = 2;
            } else other_result.* = 1;
        } else other_result.* = 1;
        return hull_result;
    }
    if (span.is_line and other_span.is_line) {
        event.* = .{};
        const count = lines.linesIntersect(self, span, other, other_span, event);
        if (count == 2) {
            other_result.* = 1;
            return 1;
        }
        if (count == 0) return -1;
        self.removedEndCheck(span);
        span.start_t = event.parameters[0][0];
        span.end_t = span.start_t;
        other.removedEndCheck(other_span);
        other_span.start_t = event.parameters[1][0];
        other_span.end_t = other_span.start_t;
        other_result.* = 2;
        return 2;
    }
    other_result.* = if (span.is_linear or other_span.is_linear) @intFromBool(span.linearsIntersect(other_span)) else 1;
    return other_result.*;
}

pub fn trim(self: *Sect, span: *Span, other: *Sect, found: *Intersections, swapped: bool) bool {
    if (!span.initBounds(self.curve)) return false;
    var next = span.bounded;
    while (next) |bounded| {
        next = bounded.next;
        const candidate = bounded.span;
        var other_count: i32 = undefined;
        var event: Intersections = undefined;
        const count = intersects(self, span, other, candidate, &other_count, &event);
        if (count >= 1) {
            if (other_count == 2) {
                _ = candidate.initBounds(other.curve);
                other.removeAllBut(span, candidate, self);
            }
            if (count == 2) {
                _ = span.initBounds(self.curve);
                // Collapse re-evaluates each curve independently. Preserve the
                // accepted event only when that round trip would make the
                // existing closest-endpoint comparison discard it.
                if (event.used == 1 and !span.part.first().approximatelyEqual(candidate.part.first())) {
                    if (swapped) _ = found.insert(event.parameters[1][0], event.parameters[0][0], event.points[0]) else _ = found.insert(event.parameters[0][0], event.parameters[1][0], event.points[0]);
                }
                self.removeAllBut(candidate, span, other);
                return true;
            }
        } else {
            if (span.removeBounded(candidate)) _ = self.removeSpan(span);
            if (candidate.removeBounded(span)) _ = other.removeSpan(candidate);
        }
    }
    return true;
}

test "TSect preserves accepted transverse events across collapsed point rounding" {
    // Exact raw991/raw1898 from the trefoil stroke. Both x coordinates are
    // strictly decreasing, while the y derivatives have opposite signs.
    // A lies below B at one common-x endpoint and above at the other, hence
    // exactly one transverse event exists. Independent collapse evaluation
    // formerly rejected the event already accepted by linesIntersect.
    const Case = struct {
        const a: curves.Cubic = .{ .points = .{
            .{ .x = -0.17739075509017366, .y = 0.13204678764587374 },
            .{ .x = -0.17968456857226545, .y = 0.13966414220964718 },
            .{ .x = -0.18188397852326088, .y = 0.14726121393331248 },
            .{ .x = -0.183986439488385, .y = 0.15483359395987173 },
        } };
        const b: curves.Cubic = .{ .points = .{
            .{ .x = -0.17305072698961, .y = 0.14019438271454066 },
            .{ .x = -0.1831299080407467, .y = 0.13909820571624443 },
            .{ .x = -0.1931621280667819, .y = 0.13789799245920364 },
            .{ .x = -0.20313847308874045, .y = 0.13659374294341853 },
        } };
        fn check(allocator: Allocator) !void {
            for ([_]i32{ -20, 0, 20 }) |exponent| for (0..4) |reversed| for (0..2) |swapped| {
                var first = a;
                var second = b;
                for (&first.points) |*p| p.* = .{ .x = std.math.ldexp(p.x, exponent), .y = std.math.ldexp(p.y, exponent) };
                for (&second.points) |*p| p.* = .{ .x = std.math.ldexp(p.x, exponent), .y = std.math.ldexp(p.y, exponent) };
                if (reversed & 1 != 0) first = first.reverse();
                if (reversed & 2 != 0) second = second.reverse();
                if (swapped != 0) std.mem.swap(curves.Cubic, &first, &second);
                var result: Intersections = .{};
                try std.testing.expectEqual(@as(usize, 1), try sect.intersect(allocator, .{ .cubic = first }, .{ .cubic = second }, &result));
                const times = [2]f64{
                    if (reversed & 1 == 0) 0.32499531489600025 else 1 - 0.32499531489600025,
                    if (reversed & 2 == 0) 0.21672300536388972 else 1 - 0.21672300536388972,
                };
                try std.testing.expectApproxEqAbs(times[swapped], result.parameters[0][0], 1e-12);
                try std.testing.expectApproxEqAbs(times[1 - swapped], result.parameters[1][0], 1e-12);
                try std.testing.expect(!result.isCoincident(0));
                try std.testing.expect(first.ptAtT(result.parameters[0][0]).distance(second.ptAtT(result.parameters[1][0])) < std.math.ldexp(@as(f64, 1e-12), exponent));
            };
        }
    };
    try Case.check(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.check, .{});
}
