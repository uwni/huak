// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Skia SkTSpan / SkTSect subdivision and coincidence state. Original curved
//! controls are retained in every span; bounds only reject candidate pairs.
const std = @import("std");
const n = @import("../numeric.zig");
const curves = @import("../curve.zig");
const Curve = curves.Curve;
const Allocator = std.mem.Allocator;
const Intersections = @import("../Intersections.zig");
pub const Span = @import("sect/Span.zig");
const Sect = @import("sect/Sect.zig");
const candidates = @import("sect/candidates.zig");
const ends = @import("sect/ends.zig");
const coincidence = @import("sect/coincidence.zig");

fn binarySearch(first: *Sect, second: *Sect, result: *Intersections) !void {
    result.reset();
    const max_intersections: usize = if (first.curve == .cubic) 9 else 4;
    result.setMax(max_intersections + 4);
    if (@import("separation.zig").disjoint(first.curve, second.curve)) return;
    const one = first.head.?;
    const two = second.head.?;
    var other_count: i32 = undefined;
    var event: Intersections = undefined;
    const count = candidates.intersects(first, one, second, two, &other_count, &event);
    if (count == 0) return;
    if (count == 2 and other_count == 2) {
        if (event.used == 1) _ = result.insert(event.parameters[0][0], event.parameters[1][0], event.points[0]);
        _ = ends.endsEqual(first, second, result);
        return;
    }
    try one.addBounded(two, first.allocator);
    try two.addBounded(one, second.allocator);
    var coin_loops: i32 = 8;
    var start: f64 = 0;
    var end: f64 = 1;
    while (true) {
        const largest_a = first.boundsMax() orelse {
            if (first.hung) return error.IntersectionWorkLimit;
            break;
        };
        const largest_b = second.boundsMax();
        if (largest_b == null or largest_a.bounds_max > largest_b.?.bounds_max or (!largest_a.collapsed and largest_b.?.collapsed)) {
            if (second.hung) return error.IntersectionWorkLimit;
            if (largest_a.collapsed) break;
            first.resetRemovedEnds();
            second.resetRemovedEnds();
            const half = try first.addOne();
            if (!try half.splitAt(largest_a, (largest_a.start_t + largest_a.end_t) / 2, first.allocator)) break;
            if (!candidates.trim(first, largest_a, second, result, false) or !candidates.trim(first, half, second, result, false)) return error.InvalidIntersectionTopology;
        } else {
            const largest = largest_b.?;
            if (largest.collapsed) break;
            first.resetRemovedEnds();
            second.resetRemovedEnds();
            const half = try second.addOne();
            if (!try half.splitAt(largest, (largest.start_t + largest.end_t) / 2, second.allocator)) break;
            if (!candidates.trim(second, largest, first, result, true) or !candidates.trim(second, half, first, result, true)) return error.InvalidIntersectionTopology;
        }
        if (first.active_count >= 9 and second.active_count >= 9) {
            if (coin_loops == 8) {
                start = (first.head orelse return).start_t;
                end = (first.tail() orelse return error.InvalidIntersectionTopology).end_t;
            }
            if (!try coincidence.coincidentCheck(first, second)) return error.InvalidIntersectionTopology;
            coin_loops -= 1;
            if (coin_loops == 0 and first.head != null and second.head != null) try coincidence.coincidentForce(first, second, start, end);
        }
        if (first.active_count >= 9 and second.active_count >= 9) {
            try first.computePerpendiculars(second, first.head orelse return, first.tail());
            try second.computePerpendiculars(first, second.head orelse return, second.tail());
            if (!first.removeByPerpendicular(second)) return error.InvalidIntersectionTopology;
            if (first.collapsedCount() > max_intersections) break;
        }
        if (first.head == null or second.head == null) break;
    }
    if (first.coincident) |coin| {
        if (coin.next != null) first.mergeCoincidence(second);
        var next = first.coincident;
        while (next) |span| : (next = span.next) {
            if (!span.coin_start.match or !span.coin_end.match) continue;
            if (span.coin_start.t < 0) return error.InvalidIntersectionTopology;
            const index = result.insertCoincident(span.start_t, span.coin_start.t, span.part.first());
            if (result.insertCoincident(span.end_t, span.coin_end.t, span.part.last()) == null) if (index) |at| result.clearCoincidence(at);
        }
    }
    const flags = ends.endsEqual(first, second, result);
    ends.addRemovedEnds(first, second, flags, result);
    if (first.head == null or second.head == null) return;
    first.recoverCollapsed();
    second.recoverCollapsed();
    const head_a = first.head.?;
    const head_b = second.head.?;
    if (flags & 1 == 0 and n.approximatelyLessThanZero(head_a.start_t) and head_a.bounded != null) {
        const t = head_a.closestBoundedT(first.curve.first());
        if (second.curve.ptAtT(t).approximatelyEqual(first.curve.first())) _ = result.insert(0, t, first.curve.first());
    }
    if (flags & 4 == 0 and n.approximatelyLessThanZero(head_b.start_t) and head_b.bounded != null) {
        const t = head_b.closestBoundedT(second.curve.first());
        if (first.curve.ptAtT(t).approximatelyEqual(second.curve.first())) _ = result.insert(t, 0, second.curve.first());
    }
    if (flags & 2 == 0) {
        const tail = first.tail() orelse return error.InvalidIntersectionTopology;
        if (n.approximatelyGreaterThanOne(tail.end_t) and tail.bounded != null) {
            const t = tail.closestBoundedT(first.curve.last());
            if (second.curve.ptAtT(t).approximatelyEqual(first.curve.last())) _ = result.insert(1, t, first.curve.last());
        }
    }
    if (flags & 8 == 0) {
        const tail = second.tail() orelse return error.InvalidIntersectionTopology;
        if (n.approximatelyGreaterThanOne(tail.end_t) and tail.bounded != null) {
            const t = tail.closestBoundedT(second.curve.last());
            if (first.curve.ptAtT(t).approximatelyEqual(second.curve.last())) _ = result.insert(t, 1, second.curve.last());
        }
    }
    try ends.addClosest(first, second, result);
    // A fixed nonzero Jacobian rules out a shared interval. Keep all finite-
    // precision observations and the original endpoint priority; proximity
    // between them cannot establish continuous coincidence.
    if (result.used > 1 and result.coincident == 0 and @import("separation.zig").atMostOne(first.curve, second.curve)) return;
    var index: usize = 0;
    while (index + 1 < result.used) {
        if (result.isCoincident(index) and result.isCoincident(index + 1)) {
            index += 1;
            continue;
        }
        const t = (result.parameters[0][index] + result.parameters[0][index + 1]) / 2;
        var perpendicular: Span.Coincident = .{};
        perpendicular.setPerp(first.curve, t, first.curve.ptAtT(t), second.curve);
        if (!perpendicular.match) {
            index += 1;
            continue;
        }
        if (result.isCoincident(index)) result.removeOne(index) else if (result.isCoincident(index + 1)) result.removeOne(index + 1) else {
            result.setCoincident(index);
            index += 1;
        }
        result.setCoincident(index);
    }
}

pub fn intersect(allocator: Allocator, a: Curve, b: Curve, result: *Intersections) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Ordinary curve pairs need only a few spans. Keep this scratch local,
    // with the same unbounded-by-buffer-size arena fallback for harder pairs.
    var span_storage: [4096]u8 = undefined;
    var scratch: std.heap.BufferFirstAllocator = .init(&span_storage, arena.allocator());
    var first = try Sect.init(scratch.allocator(), a);
    var second = try Sect.init(scratch.allocator(), b);
    try binarySearch(&first, &second, result);
    if (result.overflow) return error.IntersectionWorkLimit;
    return result.used;
}

test {
    _ = @import("sect/Span.zig");
    _ = @import("sect/Sect.zig");
    _ = @import("sect/candidates.zig");
    _ = @import("sect/lines.zig");
    _ = @import("sect/coincidence.zig");
    _ = @import("sect/ends.zig");
}
