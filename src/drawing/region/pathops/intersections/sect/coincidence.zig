// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! Coincident runs: binary search along a run, extraction, and the checks that force or reject coincidence.
const std = @import("std");
const n = @import("../../numeric.zig");
const curves = @import("../../curve.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const Intersections = @import("../../Intersections.zig");
const sect = @import("../sect.zig");
const Sect = @import("Sect.zig");
const Span = @import("Span.zig");

fn binarySearchCoin(self: *Sect, other: *Sect, start_t: f64, initial_step: f64, result_t: *f64, other_t: *f64, other_first: *?*Span) bool {
    var work = Span.storage(self.curve);
    work.start_t = start_t;
    work.end_t = start_t;
    var result = start_t;
    var last = self.curve.ptAtT(start_t);
    var other_point: Point = undefined;
    var flip = false;
    var contained = false;
    var step = initial_step;
    const down = step < 0;
    while (true) {
        step *= 0.5;
        work.start_t += step;
        if (flip) {
            step = -step;
            flip = false;
        }
        _ = work.initBounds(self.curve);
        if (work.collapsed) return false;
        if (last.approximatelyEqual(work.part.first())) break;
        last = work.part.first();
        work.coin_start.setPerp(self.curve, work.start_t, last, other.curve);
        if (work.coin_start.match) {
            const candidate = work.coin_start.t;
            if ((other.head orelse return false).contains(candidate)) {
                other_t.* = candidate;
                other_point = work.coin_start.point;
                contained = true;
                if (if (down) result <= work.start_t else result >= work.start_t) {
                    other_first.* = null;
                    return false;
                }
                result = work.start_t;
                continue;
            }
        }
        step = -step;
        flip = true;
    }
    if (!contained) return false;
    if (last.approximatelyEqual(self.curve.first())) result = 0 else if (last.approximatelyEqual(self.curve.last())) result = 1;
    if (other_point.approximatelyEqual(other.curve.first())) other_t.* = 0 else if (other_point.approximatelyEqual(other.curve.last())) other_t.* = 1;
    result_t.* = result;
    return true;
}

fn findCoincidentRun(initial: *Span, last: **Span) ?*Span {
    var work = initial;
    var first: ?*Span = null;
    var last_candidate: ?*Span = null;
    while (true) {
        if (work.coin_start.match) {
            if (!work.coin_end.match) break;
            last_candidate = work;
            if (first == null) first = work;
        } else if (first != null and work.collapsed) {
            last.* = last_candidate orelse return null;
            return first;
        } else last_candidate = null;
        if (work == last.*) return first;
        work = work.next orelse return null;
    }
    if (last_candidate) |candidate| last.* = candidate;
    return first;
}

fn extractCoincident(self: *Sect, other: *Sect, initial_first: *Span, initial_last: *Span, result: *?*Span) !bool {
    var last = initial_last;
    var first = findCoincidentRun(initial_first, &last) orelse {
        result.* = null;
        return true;
    };
    const start_t = first.start_t;
    var other_start_t: f64 = 0;
    var other_end_t: f64 = 0;
    var other_first = first.oppT(first.coin_start.t);
    const matched = first.coin_start.t < first.coin_end.t;
    var coin_start: f64 = undefined;
    if (first.prev) |previous| {
        if (previous.end_t == start_t and binarySearchCoin(self, other, start_t, previous.start_t - start_t, &coin_start, &other_start_t, &other_first) and previous.start_t < coin_start and coin_start < start_t) {
            if (previous.oppT(other_start_t)) |cut_first| {
                other_first = cut_first;
                first = try self.addSplitAt(previous, coin_start);
                first.coin_start.markCoincident();
                first.coin_end.markCoincident();
                previous.coin_end.markCoincident();
                if (cut_first.start_t < other_start_t and other_start_t < cut_first.end_t) {
                    const half = try other.addSplitAt(cut_first, other_start_t);
                    if (matched) {
                        cut_first.coin_end.markCoincident();
                        half.coin_start.markCoincident();
                        half.coin_end.markCoincident();
                        other_first = half;
                    } else {
                        cut_first.coin_start.markCoincident();
                        cut_first.coin_end.markCoincident();
                        half.coin_start.markCoincident();
                    }
                }
            }
        }
    }
    if (other_first == null) return false;
    var other_last = last.oppT(last.coin_end.t);
    if (!matched) std.mem.swap(?*Span, &other_first, &other_last);
    const opposite_first = other_first orelse {
        result.* = null;
        return true;
    };
    const opposite_last = other_last orelse {
        result.* = null;
        return true;
    };
    var delete_empty = try self.updateBounded(first, last, opposite_first);
    delete_empty = (try other.updateBounded(opposite_first, opposite_last, first)) or delete_empty;
    self.removeSpanRange(first, last);
    other.removeSpanRange(opposite_first, opposite_last);
    first.end_t = last.end_t;
    _ = first.resetBounds(self.curve);
    first.coin_start.setPerp(self.curve, first.start_t, first.part.first(), other.curve);
    first.coin_end.setPerp(self.curve, first.end_t, first.part.last(), other.curve);
    other_start_t = first.coin_start.t;
    other_end_t = first.coin_end.t;
    if (n.between(0, other_start_t, 1) and n.between(0, other_end_t, 1)) {
        if (!matched) std.mem.swap(f64, &other_start_t, &other_end_t);
        opposite_first.start_t = other_start_t;
        opposite_first.end_t = other_end_t;
        _ = opposite_first.resetBounds(other.curve);
    }
    const next = first.next;
    if (!self.removeCoincident(first, false) or !other.removeCoincident(opposite_first, true)) return false;
    if (delete_empty and (!self.deleteEmptySpans() or !other.deleteEmptySpans())) {
        result.* = null;
        return false;
    }
    result.* = if (next != null and !next.?.deleted and self.head != null and other.head != null) next else null;
    return true;
}

pub fn coincidentCheck(self: *Sect, other: *Sect) !bool {
    var first = self.head orelse return false;
    while (true) {
        var last: *Span = undefined;
        const consecutive = Sect.countConsecutiveSpans(first, &last);
        const next = last.next;
        if (consecutive >= 9) {
            try self.computePerpendiculars(other, first, last);
            var coin_start: ?*Span = first;
            while (coin_start) |start| {
                if (!try extractCoincident(self, other, start, last, &coin_start)) return false;
                if (last.deleted) break;
            }
            if (self.head == null or other.head == null) break;
            if (next == null or next.?.deleted) break;
        }
        first = next orelse break;
    }
    return true;
}

pub fn coincidentForce(self: *Sect, other: *Sect, start: f64, end: f64) !void {
    const first = self.head orelse return;
    const last = self.tail() orelse return;
    const other_first = other.head orelse return;
    const other_last = other.tail() orelse return;
    var delete_empty = try self.updateBounded(first, last, other_first);
    delete_empty = (try other.updateBounded(other_first, other_last, first)) or delete_empty;
    self.removeSpanRange(first, last);
    other.removeSpanRange(other_first, other_last);
    first.start_t = start;
    first.end_t = end;
    _ = first.resetBounds(self.curve);
    first.coin_start.setPerp(self.curve, start, self.curve.first(), other.curve);
    first.coin_end.setPerp(self.curve, end, self.curve.last(), other.curve);
    const matched = first.coin_start.t < first.coin_end.t;
    var other_start = if (first.coin_start.t == -1) 0 else @max(0, first.coin_start.t);
    var other_end = if (first.coin_end.t == -1) 1 else @min(1, first.coin_end.t);
    if (!matched) std.mem.swap(f64, &other_start, &other_end);
    other_first.start_t = other_start;
    other_first.end_t = other_end;
    _ = other_first.resetBounds(other.curve);
    _ = self.removeCoincident(first, false);
    _ = other.removeCoincident(other_first, true);
    if (delete_empty) {
        _ = self.deleteEmptySpans();
        _ = other.deleteEmptySpans();
    }
}

test "TSect exact f64 coincidence retains two endpoints after Cardano cancellation" {
    // The first missed perpendicular on Linux was at t=1/4. Exercise TSect
    // directly so the shared-coordinate reduction cannot mask a bad projection.
    const curve: Curve = .{ .cubic = .{ .points = .{
        .{ .x = -0.024495747539559964, .y = 0.39813037455249123 },
        .{ .x = -0.016348717241902566, .y = 0.3996600153767855 },
        .{ .x = -0.008181573494766448, .y = 0.40097353160273985 },
        .{ .x = 0, .y = 0.4020709232303551 },
    } } };
    for ([_]bool{ false, true }) |reversed| {
        const other = if (reversed) curve.reverse() else curve;
        var result: Intersections = .{};
        try std.testing.expectEqual(@as(usize, 2), try sect.intersect(std.testing.allocator, curve, other, &result));
        try std.testing.expectEqualSlices(f64, &.{ 0, 1 }, result.parameters[0][0..result.used]);
        try std.testing.expectEqualSlices(f64, if (reversed) &.{ 1, 0 } else &.{ 0, 1 }, result.parameters[1][0..result.used]);
        try std.testing.expectEqual(@as(u16, 3), result.coincident);
        try std.testing.expect(!result.overflow);
        for (result.points[0..result.used], result.parameters[0][0..result.used]) |point, time| {
            try std.testing.expect(point.eql(curve.ptAtT(time)));
        }
        var normal_hit: Span.Coincident = .{};
        normal_hit.setPerp(curve, 0.25, curve.ptAtT(0.25), other);
        try std.testing.expect(normal_hit.match);
    }
}
