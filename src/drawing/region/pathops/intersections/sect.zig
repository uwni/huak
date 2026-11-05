// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Skia SkTSpan / SkTSect subdivision and coincidence state. Original curved
//! controls are retained in every span; bounds only reject candidate pairs.
const std = @import("std");
const n = @import("../numeric.zig");
const curves = @import("../curve.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const Bounds = curves.Bounds;
const Allocator = std.mem.Allocator;
const Intersections = @import("../Intersections.zig");

pub const Coincident = struct {
    point: Point = .{ .x = std.math.nan(f64), .y = std.math.nan(f64) },
    t: f64 = -1,
    match: bool = false,
    pub fn init(self: *Coincident) void {
        self.* = .{};
    }
    pub fn markCoincident(self: *Coincident) void {
        if (!self.match) self.t = -1;
        self.match = true;
    }
    pub fn setPerp(self: *Coincident, first: Curve, t: f64, point: Point, second: Curve) void {
        const direction = first.dxdyAtT(t);
        // The ray solver checks an absolute projection residual. A short
        // normal scales that residual down; keep its dominant component at
        // least one so the projection cannot disguise a spatial error.
        const scale = @min(1, @max(@abs(direction.x), @abs(direction.y)));
        if (scale == 0) return self.init();
        const normal: Point = .{ .x = direction.y / scale, .y = -direction.x / scale };
        var result: Intersections = .{};
        const used = result.intersectRayFrom(second, point, normal);
        if (used == 0 or used == 3) {
            self.init();
            return;
        }
        self.t = result.parameters[0][0];
        self.point = result.points[0];
        std.debug.assert(used <= 2);
        if (used == 2 and result.points[1].distanceSquared(point) < self.point.distanceSquared(point)) {
            self.t = result.parameters[0][1];
            self.point = result.points[1];
        }
        self.match = point.approximatelyEqual(self.point);
    }
};

pub const Bounded = struct { span: *Span, next: ?*Bounded };
pub const Span = struct {
    part: Curve,
    coin_start: Coincident = .{},
    coin_end: Coincident = .{},
    bounded: ?*Bounded = null,
    prev: ?*Span = null,
    next: ?*Span = null,
    bounds: Bounds,
    start_t: f64 = 0,
    end_t: f64 = 1,
    bounds_max: f64,
    collapsed: bool,
    has_perp: bool = false,
    is_linear: bool = false,
    is_line: bool = false,
    deleted: bool = false,

    /// Defined storage while split/following links are being constructed.
    /// Their existing initBounds step supplies tight bounds before traversal;
    /// a conservative hull here avoids solving unused extrema on allocation.
    fn storage(curve: Curve) Span {
        const bounds = curve.hullBounds();
        return .{ .part = curve, .bounds = bounds, .bounds_max = @max(bounds.width(), bounds.height()), .collapsed = false };
    }
    pub fn init(curve: Curve) Span {
        const bounds = curve.bounds();
        return .{ .part = curve, .bounds = bounds, .bounds_max = @max(bounds.width(), bounds.height()), .collapsed = curve.collapsed() };
    }
    pub fn resetBounds(self: *Span, curve: Curve) bool {
        self.is_linear = false;
        self.is_line = false;
        return self.initBounds(curve);
    }
    pub fn initBounds(self: *Span, curve: Curve) bool {
        if (std.math.isNan(self.start_t) or std.math.isNan(self.end_t)) return false;
        self.part = curve.subDivide(self.start_t, self.end_t);
        self.bounds = self.part.bounds();
        self.coin_start.init();
        self.coin_end.init();
        self.bounds_max = @max(self.bounds.width(), self.bounds.height());
        self.collapsed = self.part.collapsed();
        self.has_perp = false;
        self.deleted = false;
        return self.bounds.min.isFinite() and self.bounds.max.isFinite() and self.bounds.width() >= 0 and self.bounds.height() >= 0;
    }
    pub fn addBounded(self: *Span, other: *Span, allocator: Allocator) !void {
        const bounded = try allocator.create(Bounded);
        bounded.* = .{ .span = other, .next = self.bounded };
        self.bounded = bounded;
    }
    pub fn contains(self: *const Span, t: f64) bool {
        var next: ?*const Span = self;
        while (next) |work| : (next = work.next) if (n.between(work.start_t, t, work.end_t)) return true;
        return false;
    }
    pub fn findOppSpan(self: *const Span, other: *const Span) ?*Span {
        var next = self.bounded;
        while (next) |bounded| : (next = bounded.next) if (bounded.span == other) return bounded.span;
        return null;
    }
    pub fn oppT(self: *const Span, t: f64) ?*Span {
        var next = self.bounded;
        while (next) |bounded| : (next = bounded.next) if (n.between(bounded.span.start_t, t, bounded.span.end_t)) return bounded.span;
        return null;
    }
    pub fn closestBoundedT(self: *const Span, point: Point) f64 {
        var result: f64 = -1;
        var closest = std.math.floatMax(f64);
        var next = self.bounded;
        while (next) |bounded| : (next = bounded.next) {
            const other = bounded.span;
            const start_distance = other.part.first().distanceSquared(point);
            if (closest > start_distance) {
                closest = start_distance;
                result = other.start_t;
            }
            const end_distance = other.part.last().distanceSquared(point);
            if (closest > end_distance) {
                closest = end_distance;
                result = other.end_t;
            }
        }
        std.debug.assert(n.between(0, result, 1));
        return result;
    }
    pub fn hullsIntersect(self: *Span, other: *Span, start: *bool, other_start: *bool) i32 {
        if (!self.bounds.intersects(other.bounds)) return 0;
        const one = self.hullCheck(other, start, other_start);
        if (one >= 0) return one;
        return other.hullCheck(self, other_start, start);
    }
    fn hullCheck(self: *Span, other: *const Span, start: *bool, other_start: *bool) i32 {
        if (self.is_linear) return -1;
        var common: bool = undefined;
        if (self.onlyEndpointsInCommon(other, start, other_start, &common)) return 2;
        var linear: bool = undefined;
        if (self.part.hullIntersects(&other.part, &linear)) {
            if (!linear) return 1;
            self.is_linear = true;
            self.is_line = self.part.controlsInside();
            return if (common) 1 else -1;
        }
        return if (common) 2 else 0;
    }
    pub fn onlyEndpointsInCommon(self: *const Span, other: *const Span, start: *bool, other_start: *bool, common: *bool) bool {
        if (other.part.first().eql(self.part.first())) {
            start.* = true;
            other_start.* = true;
        } else if (other.part.first().eql(self.part.last())) {
            start.* = false;
            other_start.* = true;
        } else if (other.part.last().eql(self.part.first())) {
            start.* = true;
            other_start.* = false;
        } else if (other.part.last().eql(self.part.last())) {
            start.* = false;
            other_start.* = false;
        } else {
            common.* = false;
            return false;
        }
        common.* = true;
        const base_index = if (start.*) 0 else self.part.pointLast();
        const other_index = if (other_start.*) 0 else other.part.pointLast();
        const base = self.part.point(base_index);
        for (0..self.part.pointCount()) |a| {
            if (a == base_index) continue;
            const one = self.part.point(a).sub(base);
            for (0..other.part.pointCount()) |b| {
                if (b == other_index) continue;
                if (other.part.point(b).sub(base).dot(one) >= 0) return false;
            }
        }
        return true;
    }
    pub fn linearsIntersect(self: *const Span, other: *const Span) bool {
        const result = self.linearIntersects(other.part);
        return if (result <= 1) result != 0 else other.linearIntersects(self.part) != 0;
    }
    fn linearIntersects(self: *const Span, other: Curve) i32 {
        var start: usize = 0;
        var end = self.part.pointLast();
        if (!self.part.controlsInside()) {
            var distance: f64 = 0;
            for (0..self.part.pointCount() - 1) |outer| for (outer + 1..self.part.pointCount()) |inner| {
                const candidate = self.part.point(outer).distanceSquared(self.part.point(inner));
                if (distance > candidate) continue;
                distance = candidate;
                start = outer;
                end = inner;
            };
        }
        const origin = self.part.point(start);
        const direction = self.part.point(end).sub(origin);
        const max_part = @max(@abs(direction.x), @abs(direction.y));
        var sign: f64 = 0;
        for (0..other.pointCount()) |index| {
            const relative = other.point(index).sub(origin);
            const scale = @max(max_part, @max(@abs(relative.x), @abs(relative.y)));
            const candidate = relative.y * direction.x - relative.x * direction.y;
            if (n.preciselyZeroWhenComparedTo(candidate, scale)) return 1;
            if (n.approximatelyZeroWhenComparedTo(candidate, scale)) return 3;
            if (index == 0) {
                sign = candidate;
                continue;
            }
            if (candidate * sign < 0) return 1;
        }
        return 0;
    }
    pub fn removeAllBounded(self: *Span) bool {
        var delete_span = false;
        var next = self.bounded;
        while (next) |bounded| : (next = bounded.next) delete_span = bounded.span.removeBounded(self) or delete_span;
        return delete_span;
    }
    pub fn removeBounded(self: *Span, other: *const Span) bool {
        if (self.has_perp) {
            var found_start = false;
            var found_end = false;
            var next = self.bounded;
            while (next) |bounded| : (next = bounded.next) if (bounded.span != other) {
                found_start = found_start or n.between(bounded.span.start_t, self.coin_start.t, bounded.span.end_t);
                found_end = found_end or n.between(bounded.span.start_t, self.coin_end.t, bounded.span.end_t);
            };
            if (!found_start or !found_end) {
                self.has_perp = false;
                self.coin_start.init();
                self.coin_end.init();
            }
        }
        var next = self.bounded;
        var previous: ?*Bounded = null;
        while (next) |bounded| : (next = bounded.next) {
            if (bounded.span == other) {
                if (previous) |prev| {
                    prev.next = bounded.next;
                    return false;
                }
                self.bounded = bounded.next;
                return self.bounded == null;
            }
            previous = bounded;
        }
        std.debug.assert(false);
        return false;
    }
    pub fn splitAt(self: *Span, work: *Span, t: f64, allocator: Allocator) !bool {
        self.start_t = t;
        self.end_t = work.end_t;
        if (self.start_t == self.end_t) {
            self.collapsed = true;
            return false;
        }
        work.end_t = t;
        if (work.start_t == work.end_t) {
            work.collapsed = true;
            return false;
        }
        self.prev = work;
        self.next = work.next;
        self.is_linear = work.is_linear;
        self.is_line = work.is_line;
        work.next = self;
        if (self.next) |next| next.prev = self;
        var next = work.bounded;
        self.bounded = null;
        while (next) |bounded| : (next = bounded.next) try self.addBounded(bounded.span, allocator);
        next = self.bounded;
        while (next) |bounded| : (next = bounded.next) try bounded.span.addBounded(self, allocator);
        return true;
    }
};

test "TSect spans split original curves and retain reciprocal candidate bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 } } } };
    const second: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -2 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 1 } } } };
    var head = Span.init(first);
    var other = Span.init(second);
    var tail = Span.init(first);
    try head.addBounded(&other, allocator);
    try other.addBounded(&head, allocator);
    try std.testing.expect(try tail.splitAt(&head, 0.5, allocator));
    try std.testing.expect(head.initBounds(first));
    try std.testing.expect(tail.initBounds(first));
    try std.testing.expect(head.next == &tail and tail.prev == &head);
    try std.testing.expect(head.part.last().eql(tail.part.first()));
    try std.testing.expect(head.part.first().eql(first.first()));
    try std.testing.expect(tail.part.last().eql(first.last()));
    try std.testing.expect(other.findOppSpan(&head) == &head);
    try std.testing.expect(other.findOppSpan(&tail) == &tail);
    try std.testing.expect(head.contains(0.75));
    try std.testing.expect(other.removeBounded(&head) == false);
    try std.testing.expect(other.findOppSpan(&tail) == &tail);
    try std.testing.expect(other.removeBounded(&tail));
}

test "TSect allocated spans reach tight bounds before candidate traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const curve: Curve = .{ .cubic = .{ .points = .{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = -2 }, .{ .x = 4, .y = 0 },
    } } };
    const storage = Span.storage(curve);
    try std.testing.expect(storage.bounds.containsBounds(curve.bounds()));
    try std.testing.expect(storage.bounded == null and storage.prev == null and storage.next == null);
    var sect = try Sect.init(arena.allocator(), curve);
    const head = sect.head.?;
    try std.testing.expectEqualDeep(curve.bounds(), head.bounds);
    const half = try sect.addSplitAt(head, 0.5);
    try std.testing.expectEqualDeep(head.part.bounds(), head.bounds);
    try std.testing.expectEqualDeep(half.part.bounds(), half.bounds);
    try std.testing.expectEqual(@as(f64, 0.5), head.end_t);
    try std.testing.expectEqual(@as(f64, 0.5), half.start_t);

    var gaps = try Sect.init(arena.allocator(), curve);
    const middle = gaps.head.?;
    middle.start_t = 0.25;
    middle.end_t = 0.75;
    try std.testing.expect(middle.resetBounds(curve));
    const first = try gaps.addFollowing(null);
    const last = try gaps.addFollowing(middle);
    try std.testing.expect(first == gaps.head and first.next == middle and middle.next == last);
    try std.testing.expect(first.prev == null and last.next == null);
    try std.testing.expectEqual(@as(f64, 0.25), first.end_t);
    try std.testing.expectEqual(@as(f64, 0.75), last.start_t);
    for ([_]*Span{ first, middle, last }) |span| {
        try std.testing.expectEqualDeep(span.part.bounds(), span.bounds);
        try std.testing.expectEqualDeep(curve.subDivide(span.start_t, span.end_t), span.part);
    }
}

const Sect = struct {
    curve: Curve,
    allocator: Allocator,
    head: ?*Span = null,
    coincident: ?*Span = null,
    deleted: ?*Span = null,
    active_count: i32 = 0,
    removed_start: bool = false,
    removed_end: bool = false,
    hung: bool = false,

    fn init(allocator: Allocator, curve: Curve) !Sect {
        var result: Sect = .{ .curve = curve, .allocator = allocator };
        const head = try result.addOne();
        head.* = Span.init(curve);
        result.head = head;
        return result;
    }
    fn addOne(self: *Sect) !*Span {
        const result = if (self.deleted) |deleted| blk: {
            self.deleted = deleted.next;
            break :blk deleted;
        } else blk: {
            const created = try self.allocator.create(Span);
            created.* = Span.storage(self.curve);
            break :blk created;
        };
        result.bounded = null;
        result.has_perp = false;
        result.deleted = false;
        self.active_count += 1;
        return result;
    }
    fn addSplitAt(self: *Sect, span: *Span, t: f64) !*Span {
        const result = try self.addOne();
        _ = try result.splitAt(span, t, self.allocator);
        _ = result.initBounds(self.curve);
        _ = span.initBounds(self.curve);
        return result;
    }
    fn addFollowing(self: *Sect, prior: ?*Span) !*Span {
        const result = try self.addOne();
        result.start_t = if (prior) |p| p.end_t else 0;
        const next = if (prior) |p| p.next else self.head;
        result.end_t = if (next) |p| p.start_t else 1;
        result.prev = prior;
        result.next = next;
        if (prior) |p| p.next = result else self.head = result;
        if (next) |p| p.prev = result;
        _ = result.resetBounds(self.curve);
        return result;
    }
    fn addForPerp(self: *Sect, span: *Span, t: f64) !void {
        if (span.oppT(t) != null) return;
        var prior: ?*Span = null;
        const other = self.spanAtT(t, &prior) orelse try self.addFollowing(prior);
        try other.addBounded(span, self.allocator);
        try span.addBounded(other, self.allocator);
    }
    fn boundsMax(self: *Sect) ?*Span {
        var largest = self.head orelse return null;
        var next = largest.next;
        var safety: usize = 10000;
        while (next) |candidate| : (next = candidate.next) {
            safety -= 1;
            if (safety == 0) {
                self.hung = true;
                return null;
            }
            if ((largest.collapsed and !candidate.collapsed) or (largest.collapsed == candidate.collapsed and largest.bounds_max < candidate.bounds_max)) largest = candidate;
        }
        return largest;
    }
    fn tail(self: *const Sect) ?*Span {
        var result = self.head orelse return null;
        var next = result.next;
        var safety: usize = 100000;
        while (next) |candidate| : (next = candidate.next) {
            safety -= 1;
            if (safety == 0) return null;
            if (candidate.end_t > result.end_t) result = candidate;
        }
        return result;
    }
    fn spanAtT(self: *Sect, t: f64, prior: *?*Span) ?*Span {
        var next = self.head;
        prior.* = null;
        while (next) |candidate| {
            if (candidate.end_t >= t) break;
            prior.* = candidate;
            next = candidate.next;
        }
        if (next) |candidate| if (candidate.start_t <= t) return candidate;
        return null;
    }
    fn hasBounded(self: *const Sect, span: *const Span) bool {
        var next = self.head;
        while (next) |candidate| : (next = candidate.next) if (candidate.findOppSpan(span) != null) return true;
        return false;
    }
    fn removedEndCheck(self: *Sect, span: *const Span) void {
        if (span.start_t == 0) self.removed_start = true;
        if (span.end_t == 1) self.removed_end = true;
    }
    fn resetRemovedEnds(self: *Sect) void {
        self.removed_start = false;
        self.removed_end = false;
    }
    fn unlinkSpan(self: *Sect, span: *Span) bool {
        if (span.prev) |prior| {
            prior.next = span.next;
            if (span.next) |next| {
                next.prev = prior;
                if (next.start_t > next.end_t) return false;
            }
        } else {
            self.head = span.next;
            if (span.next) |next| next.prev = null;
        }
        return true;
    }
    fn markSpanGone(self: *Sect, span: *Span) bool {
        self.active_count -= 1;
        if (self.active_count < 0) return false;
        span.next = self.deleted;
        self.deleted = span;
        std.debug.assert(!span.deleted);
        span.deleted = true;
        return true;
    }
    fn removeSpan(self: *Sect, span: *Span) bool {
        self.removedEndCheck(span);
        if (!self.unlinkSpan(span)) return false;
        return self.markSpanGone(span);
    }
    fn removeSpanRange(self: *Sect, first: *Span, last: *Span) void {
        if (first == last) return;
        const final = last.next;
        var next = first.next;
        while (next) |span| {
            if (span == final) break;
            next = span.next;
            _ = self.markSpanGone(span);
        }
        if (final) |span| span.prev = first;
        first.next = final;
    }
    fn removeSpans(self: *Sect, span: *Span, other: *Sect) bool {
        var next = span.bounded;
        while (next) |bounded| {
            next = bounded.next;
            if (span.removeBounded(bounded.span)) _ = self.removeSpan(span);
            if (bounded.span.removeBounded(span)) _ = other.removeSpan(bounded.span);
            if (span.deleted and other.hasBounded(span)) return false;
        }
        return true;
    }
    fn removeAllBut(self: *Sect, keep: *const Span, span: *Span, other: *Sect) void {
        _ = self;
        var next = span.bounded;
        while (next) |bounded| {
            next = bounded.next;
            if (bounded.span != keep and !bounded.span.deleted) {
                _ = span.removeBounded(bounded.span);
                if (bounded.span.removeBounded(span)) _ = other.removeSpan(bounded.span);
            }
        }
        std.debug.assert(!span.deleted and span.findOppSpan(keep) != null and keep.findOppSpan(span) != null);
    }
    fn removeCoincident(self: *Sect, span: *Span, is_between: bool) bool {
        if (!self.unlinkSpan(span)) return false;
        if (is_between or n.between(0, span.coin_start.t, 1)) {
            self.active_count -= 1;
            span.next = self.coincident;
            self.coincident = span;
        } else _ = self.markSpanGone(span);
        return true;
    }
    fn deleteEmptySpans(self: *Sect) bool {
        var next = self.head;
        var safety: i32 = 1000;
        while (next) |span| {
            next = span.next;
            if (span.bounded == null and !self.removeSpan(span)) return false;
            safety -= 1;
            if (safety < 0) return false;
        }
        return true;
    }
    fn recoverCollapsed(self: *Sect) void {
        var next = self.deleted;
        while (next) |span| {
            next = span.next;
            if (span.collapsed) {
                var pointer = &self.head;
                while (pointer.*) |candidate| {
                    if (candidate.end_t > span.start_t) break;
                    pointer = &candidate.next;
                }
                span.next = pointer.*;
                pointer.* = span;
            }
        }
    }
    fn collapsedCount(self: *const Sect) usize {
        var count: usize = 0;
        var next = self.head;
        while (next) |span| : (next = span.next) count += @intFromBool(span.collapsed);
        return count;
    }
    fn coincidentHasT(self: *const Sect, t: f64) bool {
        var next = self.coincident;
        while (next) |span| : (next = span.next) if (n.between(span.start_t, t, span.end_t)) return true;
        return false;
    }
    fn countConsecutiveSpans(first: *Span, last: **Span) usize {
        var count: usize = 1;
        var span = first;
        while (span.next) |next| {
            if (next.start_t > span.end_t) break;
            count += 1;
            span = next;
        }
        last.* = span;
        return count;
    }
    fn updateBounded(self: *Sect, first: *Span, last: *Span, other_first: *Span) !bool {
        const final = last.next;
        var delete_span = false;
        var next: ?*Span = first;
        while (next) |span| {
            delete_span = span.removeAllBounded() or delete_span;
            next = span.next;
            if (next == final) break;
        }
        first.bounded = null;
        try first.addBounded(other_first, self.allocator);
        return delete_span;
    }
    fn computePerpendiculars(self: *Sect, other: *Sect, first: *Span, last: ?*Span) !void {
        const final = last orelse return;
        var work = first;
        var prior: ?*Span = null;
        while (true) {
            if (!work.has_perp and !work.collapsed) {
                if (prior) |span| work.coin_start = span.coin_end else work.coin_start.setPerp(self.curve, work.start_t, work.part.first(), other.curve);
                if (work.coin_start.match) {
                    if (other.coincidentHasT(work.coin_start.t)) work.coin_start.init() else try other.addForPerp(work, work.coin_start.t);
                }
                work.coin_end.setPerp(self.curve, work.end_t, work.part.last(), other.curve);
                if (work.coin_end.match) {
                    if (other.coincidentHasT(work.coin_end.t)) work.coin_end.init() else try other.addForPerp(work, work.coin_end.t);
                }
                work.has_perp = true;
            }
            if (work == final) break;
            prior = work;
            work = work.next orelse return error.InvalidIntersectionTopology;
        }
    }
    fn removeByPerpendicular(self: *Sect, other: *Sect) bool {
        var next = self.head;
        while (next) |span| {
            next = span.next;
            if (span.coin_start.t < 0 or span.coin_end.t < 0) continue;
            const start = span.coin_start.point.sub(span.part.first());
            const end = span.coin_end.point.sub(span.part.last());
            if (start.dot(end) <= 0) continue;
            if (!self.removeSpans(span, other)) return false;
        }
        return true;
    }
    fn mergeCoincidence(self: *Sect, other: *Sect) void {
        var small_limit: f64 = 0;
        while (true) {
            var smaller: ?*Span = null;
            var next = self.coincident;
            while (next) |span| : (next = span.next) {
                if (span.start_t < small_limit) continue;
                if (smaller) |small| if (small.end_t < span.start_t) continue;
                smaller = span;
            }
            const small = smaller orelse return;
            small_limit = small.end_t;
            var prior: ?*Span = null;
            var larger: ?*Span = null;
            var larger_prior: ?*Span = null;
            next = self.coincident;
            while (next) |span| {
                next = span.next;
                defer prior = span;
                if (span.start_t < small.end_t) continue;
                if (larger) |large| if (large.start_t < span.start_t) continue;
                larger_prior = prior;
                larger = span;
            }
            const large = larger orelse continue;
            const mid_t = (small.end_t + large.start_t) / 2;
            var coin: Coincident = .{};
            coin.setPerp(self.curve, mid_t, self.curve.ptAtT(mid_t), other.curve);
            if (coin.match) {
                small.end_t = large.end_t;
                small.coin_end = large.coin_end;
                if (larger_prior) |before| before.next = large.next else self.coincident = large.next;
            }
        }
    }
};

fn intersects(self: *Sect, span: *Span, other: *Sect, other_span: *Span, other_result: *i32, event: *Intersections) i32 {
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
        const count = linesIntersect(self, span, other, other_span, event);
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

fn linesIntersect(self: *Sect, span: *Span, other: *Sect, other_span: *Span, result: *Intersections) usize {
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
            const refined_ok = @import("guard.zig").refineWithin(self.curve, other.curve, .{ .start = span.start_t, .end = span.end_t }, .{ .start = other_span.start_t, .end = other_span.end_t }, &t, &u, &refined);
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
    var other_start: Coincident = .{};
    var other_end: Coincident = .{};
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
        var coin: Coincident = .{};
        coin.setPerp(self.curve, span.start_t, span.part.first(), other.curve);
        perp_start = span.part.first().sub(coin.point);
    } else if (swap) perp_start = other_end.point.sub(other_span.part.last()) else perp_start = other_start.point.sub(other_span.part.first());
    if (end_t == span.end_t) {
        var coin: Coincident = .{};
        coin.setPerp(self.curve, span.end_t, span.part.last(), other.curve);
        perp_end = span.part.last().sub(coin.point);
    } else if (swap) perp_end = other_start.point.sub(other_span.part.first()) else perp_end = other_end.point.sub(other_span.part.last());
    if (perp_start.dot(perp_end) >= 0) return 0;
    var work: Coincident = .{};
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
    if (!@import("guard.zig").refineWithin(self.curve, other.curve, .{ .start = span.start_t, .end = span.end_t }, .{ .start = other_span.start_t, .end = other_span.end_t }, &t, &u, &point)) return 0;
    result.max = 1;
    _ = result.insert(t, u, point);
    return result.used;
}

fn trim(self: *Sect, span: *Span, other: *Sect, found: *Intersections, swapped: bool) bool {
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

fn coincidentCheck(self: *Sect, other: *Sect) !bool {
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

fn coincidentForce(self: *Sect, other: *Sect, start: f64, end: f64) !void {
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

fn endsEqual(first: *const Sect, second: *const Sect, result: *Intersections) u4 {
    var flags: u4 = 0;
    for (0..2) |one| for (0..2) |two| {
        const a = if (one == 0) first.curve.first() else first.curve.last();
        const b = if (two == 0) second.curve.first() else second.curve.last();
        if (a.eql(b)) {
            flags |= (@as(u4, 1) << @intCast(one)) | (@as(u4, 4) << @intCast(two));
            _ = result.insert(@floatFromInt(one), @floatFromInt(two), a);
        }
    };
    for (0..2) |one| for (0..2) |two| {
        const mask = (@as(u4, 1) << @intCast(one)) | (@as(u4, 4) << @intCast(two));
        if (flags & mask != 0) continue;
        const a = if (one == 0) first.curve.first() else first.curve.last();
        const b = if (two == 0) second.curve.first() else second.curve.last();
        if (a.approximatelyEqual(b)) {
            flags |= mask;
            result.insertNear(@floatFromInt(one), @floatFromInt(two), a, b);
        }
    };
    return flags;
}

const ClosestRecord = struct {
    first: ?*Span = null,
    second: ?*Span = null,
    closest: f64 = std.math.floatMax(f64),
    first_index: usize = 0,
    second_index: usize = 0,

    fn findEnd(self: *ClosestRecord, first: *Span, second: *Span, a: usize, b: usize) void {
        const point = first.part.point(a);
        const other = second.part.point(b);
        if (!point.approximatelyEqual(other)) return;
        const distance = point.distanceSquared(other);
        if (self.closest < distance) return;
        self.* = .{ .first = first, .second = second, .first_index = a, .second_index = b, .closest = distance };
    }
    fn matesWith(self: ClosestRecord, other: ClosestRecord) bool {
        const a = self.first.?;
        const b = self.second.?;
        const oa = other.first.?;
        const ob = other.second.?;
        return a == oa or a.end_t == oa.start_t or a.start_t == oa.end_t or b == ob or b.end_t == ob.start_t or b.start_t == ob.end_t;
    }
    fn merge(self: *ClosestRecord, other: ClosestRecord) void {
        if (self.closest > other.closest) self.* = other;
    }
    fn add(self: ClosestRecord, result: *Intersections) void {
        const a = self.first.?;
        const b = self.second.?;
        _ = result.insert(if (self.first_index != 0) a.end_t else a.start_t, if (self.second_index != 0) b.end_t else b.start_t, a.part.point(self.first_index));
    }
    fn lessThan(_: void, a: ClosestRecord, b: ClosestRecord) bool {
        return a.closest < b.closest;
    }
};

fn addClosest(first: *Sect, second: *Sect, result: *Intersections) !void {
    var records: std.ArrayList(ClosestRecord) = .empty;
    defer records.deinit(first.allocator);
    var next_a = first.head;
    while (next_a) |a| : (next_a = a.next) {
        if (a.coin_start.match and a.coin_end.match) continue;
        var next_b = second.head;
        while (next_b) |b| : (next_b = b.next) {
            var record: ClosestRecord = .{};
            record.findEnd(a, b, 0, 0);
            record.findEnd(a, b, 0, b.part.pointLast());
            record.findEnd(a, b, a.part.pointLast(), 0);
            record.findEnd(a, b, a.part.pointLast(), b.part.pointLast());
            if (record.closest == std.math.floatMax(f64)) continue;
            var merged = false;
            for (records.items) |*candidate| {
                if (candidate.matesWith(record)) {
                    candidate.merge(record);
                    merged = true;
                    break;
                }
            }
            if (!merged) try records.append(first.allocator, record);
        }
    }
    std.sort.pdq(ClosestRecord, records.items, {}, ClosestRecord.lessThan);
    for (records.items) |record| record.add(result);
}

fn binarySearch(first: *Sect, second: *Sect, result: *Intersections) !void {
    result.reset();
    const max_intersections: usize = if (first.curve == .cubic) 9 else 4;
    result.setMax(max_intersections + 4);
    if (@import("separation.zig").disjoint(first.curve, second.curve)) return;
    const one = first.head.?;
    const two = second.head.?;
    var other_count: i32 = undefined;
    var event: Intersections = undefined;
    const count = intersects(first, one, second, two, &other_count, &event);
    if (count == 0) return;
    if (count == 2 and other_count == 2) {
        if (event.used == 1) _ = result.insert(event.parameters[0][0], event.parameters[1][0], event.points[0]);
        _ = endsEqual(first, second, result);
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
            if (!trim(first, largest_a, second, result, false) or !trim(first, half, second, result, false)) return error.InvalidIntersectionTopology;
        } else {
            const largest = largest_b.?;
            if (largest.collapsed) break;
            first.resetRemovedEnds();
            second.resetRemovedEnds();
            const half = try second.addOne();
            if (!try half.splitAt(largest, (largest.start_t + largest.end_t) / 2, second.allocator)) break;
            if (!trim(second, largest, first, result, true) or !trim(second, half, first, result, true)) return error.InvalidIntersectionTopology;
        }
        if (first.active_count >= 9 and second.active_count >= 9) {
            if (coin_loops == 8) {
                start = (first.head orelse return).start_t;
                end = (first.tail() orelse return error.InvalidIntersectionTopology).end_t;
            }
            if (!try coincidentCheck(first, second)) return error.InvalidIntersectionTopology;
            coin_loops -= 1;
            if (coin_loops == 0 and first.head != null and second.head != null) try coincidentForce(first, second, start, end);
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
    const flags = endsEqual(first, second, result);
    addRemovedEnds(first, second, flags, result);
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
    try addClosest(first, second, result);
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
        var perpendicular: Coincident = .{};
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

fn addRemovedEnds(first: *Sect, second: *Sect, flags: u4, result: *Intersections) void {
    if (first.removed_start and flags & 1 == 0) addRemovedEnd(first, second, 0, false, result);
    if (first.removed_end and flags & 2 == 0) addRemovedEnd(first, second, 1, false, result);
    if (second.removed_start and flags & 4 == 0) addRemovedEnd(second, first, 0, true, result);
    if (second.removed_end and flags & 8 == 0) addRemovedEnd(second, first, 1, true, result);
}

fn addRemovedEnd(first: *Sect, second: *Sect, t: f64, swapped: bool, result: *Intersections) void {
    const point = first.curve.ptAtT(t);
    var perpendicular: Coincident = .{};
    perpendicular.setPerp(first.curve, t, point, second.curve);
    if (!perpendicular.match) return;
    if (swapped) _ = result.insert(perpendicular.t, t, perpendicular.point) else _ = result.insert(t, perpendicular.t, perpendicular.point);
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
        try std.testing.expectEqual(@as(usize, 2), try intersect(std.testing.allocator, curve, other, &result));
        try std.testing.expectEqualSlices(f64, &.{ 0, 1 }, result.parameters[0][0..result.used]);
        try std.testing.expectEqualSlices(f64, if (reversed) &.{ 1, 0 } else &.{ 0, 1 }, result.parameters[1][0..result.used]);
        try std.testing.expectEqual(@as(u16, 3), result.coincident);
        try std.testing.expect(!result.overflow);
        for (result.points[0..result.used], result.parameters[0][0..result.used]) |point, time| {
            try std.testing.expect(point.eql(curve.ptAtT(time)));
        }
        var normal_hit: Coincident = .{};
        normal_hit.setPerp(curve, 0.25, curve.ptAtT(0.25), other);
        try std.testing.expect(normal_hit.match);
    }
}

test "TSect approximate end recovery retains isolated candidate bits" {
    // Exact dyadic derivative controls certify at most one transverse event.
    // Preserve the accepted interior candidate bits and all approximate source
    // ends in their original priority. These observations must not be treated
    // as a continuous overlapping interval or asserted to be distinct roots.
    const expected = [_][4]u64{
        .{ 0x3fae9305b0787884, 0x3feffffffff9fa75, 0x3f65e50265afd88a, 0xbf315f0cc11692f4 },
        .{ 0x3feffffffff9fa75, 0x3fae9305b0787884, 0x3f65e50265afd879, 0xbf315f0cc116937c },
        .{ 0x3fee16cfa4f87878, 0x3feffffffff9fa75, 0x3f65e50265afd88a, 0xbf315f0cc11692f4 },
        .{ 0x3feffffffff9fa75, 0x3fee16cfa4f87878, 0x3f65e50265afd879, 0xbf315f0cc116937c },
        .{ 0x3fae9305b0787884, 0x3dc8162cd7200000, 0x3f65e50265afd88a, 0xbf315f0cc11692f4 },
        .{ 0x3dc8162cd7200000, 0x3fae9305b0787884, 0x3f65e50265afd879, 0xbf315f0cc116937c },
        .{ 0x3fee16cfa4f87878, 0x3dc8162cd7800000, 0x3f65e50265afd88a, 0xbf315f0cc11692f4 },
        .{ 0x3dc8162cd7800000, 0x3fee16cfa4f87878, 0x3f65e50265afd879, 0xbf315f0cc116937c },
        .{ 0x3fae9305b0ccfe66, 0x3feffffffffff63f, 0x3fe5e50265afd645, 0xbfb15f0cc1174a06 },
        .{ 0x3feffffffffff63f, 0x3fae9305b0ccfe66, 0x3fe5e50265afd645, 0xbfb15f0cc1174a07 },
        .{ 0x3fee16cfa4f33019, 0x3feffffffffff640, 0x3fe5e50265afd645, 0xbfb15f0cc1174a06 },
        .{ 0x3feffffffffff640, 0x3fee16cfa4f33019, 0x3fe5e50265afd645, 0xbfb15f0cc1174a07 },
        .{ 0x3fae9305b0ccfe66, 0x3d5382a9fb400000, 0x3fe5e50265afd645, 0xbfb15f0cc1174a06 },
        .{ 0x3d5382a9fb400000, 0x3fae9305b0ccfe66, 0x3fe5e50265afd645, 0xbfb15f0cc1174a07 },
        .{ 0x3fee16cfa4f33019, 0x3d538073649246c8, 0x3fe5e50265afd645, 0xbfb15f0cc1174a06 },
        .{ 0x3d538073649246c8, 0x3fee16cfa4f33019, 0x3fe5e50265afd645, 0xbfb15f0cc1174a07 },
        .{ 0x3fae9305b0ccfe76, 0x3feffffffffff640, 0x4065e50265afd645, 0xc0315f0cc1174a07 },
        .{ 0x3feffffffffff640, 0x3fae9305b0ccfe76, 0x4065e50265afd645, 0xc0315f0cc1174a07 },
        .{ 0x3fee16cfa4f338d8, 0x3fefffffffffea84, 0x4065e50265afd64a, 0xc0315f0cc11748d8 },
        .{ 0x3fefffffffffea84, 0x3fee16cfa4f338d8, 0x4065e50265afd64b, 0xc0315f0cc11748a2 },
        .{ 0x3fae9305b0ccfe76, 0x3d538073648eea16, 0x4065e50265afd645, 0xc0315f0cc1174a07 },
        .{ 0x3d538073648eea16, 0x3fae9305b0ccfe76, 0x4065e50265afd645, 0xc0315f0cc1174a07 },
        .{ 0x3fee16cfa4f33019, 0x3d53807364b48a00, 0x4065e50265afd645, 0xc0315f0cc1174a06 },
        .{ 0x3d53807364b48a00, 0x3fee16cfa4f33019, 0x4065e50265afd645, 0xc0315f0cc1174a07 },
    };
    const first: curves.Cubic = .{ .points = .{
        .{ .x = 0.68430475604368124, .y = -0.066845930293522704 },
        .{ .x = 0.68375286442238825, .y = -0.072488543101240532 },
        .{ .x = 0.68314094325928587, .y = -0.078113553109506295 },
        .{ .x = 0.68246963955255446, .y = -0.083720313320140294 },
    } };
    const second: curves.Cubic = .{ .points = .{
        .{ .x = 0.6855028164095287, .y = -0.052920675614067214 },
        .{ .x = 0.68511706257494875, .y = -0.057912611829187721 },
        .{ .x = 0.68468439187328545, .y = -0.062891398462162851 },
        .{ .x = 0.68420524464335863, .y = -0.067856595174174528 },
    } };
    for ([_]i32{ -8, 0, 8 }, 0..) |exponent, scale_index| for (0..4) |reversed| for (0..2) |swapped| {
        errdefer std.debug.print("isolated near-end fixture: scale=2^{d} reverse={d} swap={d}\n", .{ exponent, reversed, swapped });
        var a = first;
        var b = second;
        if (reversed & 1 != 0) std.mem.reverse(Point, &a.points);
        if (reversed & 2 != 0) std.mem.reverse(Point, &b.points);
        for (&a.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        for (&b.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        const source_a: Curve = .{ .cubic = if (swapped == 0) a else b };
        const source_b: Curve = .{ .cubic = if (swapped == 0) b else a };
        var result: Intersections = .{};
        const count = try intersect(std.testing.allocator, source_a, source_b, &result);
        var interior: ?usize = null;
        for (0..count) |index| {
            if (!(result.parameters[0][index] > 0 and result.parameters[0][index] < 1 and result.parameters[1][index] > 0 and result.parameters[1][index] < 1)) continue;
            try std.testing.expect(interior == null);
            interior = index;
        }
        const index = interior orelse return error.TestExpectedInteriorEvent;
        const actual = [_]u64{ @bitCast(result.parameters[0][index]), @bitCast(result.parameters[1][index]), @bitCast(result.points[index].x), @bitCast(result.points[index].y) };
        try std.testing.expectEqualSlices(u64, &expected[scale_index * 8 + reversed * 2 + swapped], &actual);
        for (0..count) |event_index| try std.testing.expect(!result.isCoincident(event_index));
        try std.testing.expect(source_a.ptAtT(result.parameters[0][index]).approximatelyEqual(source_b.ptAtT(result.parameters[1][index])));
    };
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
        const source_a: Curve = .{ .cubic = a };
        const source_b: Curve = .{ .cubic = b };
        const lowered_b = @import("../reduce.zig").cubic(b).?;
        try std.testing.expect(lowered_b == .quad);
        for ([_]Curve{ source_b, lowered_b }) |second| {
            var result: Intersections = .{};
            try std.testing.expectEqual(@as(usize, 2), try intersect(std.testing.allocator, source_a, second, &result));
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

test "TSect source endpoint identity survives scale reversal and operand order" {
    // A(t) = (3t + 3t*t, 1/4 - 3t/2 + 3t*t + 3t*t*t).
    // At t=(sqrt(3)-1)/2 it equals B's exact endpoint (3/2,1/4).
    // A numerical interior approximation must not suppress that true endpoint,
    // even when evaluating the irrational root rounds to a different Point.
    const first: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0.25 }, .{ .x = 1, .y = -0.25 }, .{ .x = 3, .y = 0.25 }, .{ .x = 6, .y = 4.75 } } } };
    const second: Curve = .{ .cubic = .{ .points = .{ .{ .x = 1, .y = 0.75 }, .{ .x = 1.125, .y = 0.625 }, .{ .x = 1.25, .y = 0.5 }, .{ .x = 1.5, .y = 0.25 } } } };
    for ([_]i32{ -20, -8, 0, 20 }) |exponent| for (0..4) |reversed| for (0..2) |swapped| {
        var a = first;
        var b = second;
        for (&a.cubic.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        for (&b.cubic.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        if (reversed & 1 != 0) a = a.reverse();
        if (reversed & 2 != 0) b = b.reverse();
        if (swapped != 0) std.mem.swap(Curve, &a, &b);
        try std.testing.expect(@import("separation.zig").atMostOne(a, b));
        var result: Intersections = .{};
        try std.testing.expectEqual(@as(usize, 1), try intersect(std.testing.allocator, a, b, &result));
        const root = (@sqrt(@as(f64, 3)) - 1) / 2;
        const source_time = if (reversed & 1 == 0) root else 1 - root;
        const endpoint: f64 = if (reversed & 2 == 0) 1 else 0;
        try std.testing.expectApproxEqAbs(source_time, result.parameters[swapped][0], 1e-14);
        try std.testing.expectEqual(endpoint, result.parameters[1 - swapped][0]);
        try std.testing.expect(!result.isCoincident(0));
    };
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
                try std.testing.expectEqual(@as(usize, 1), try intersect(allocator, .{ .cubic = first }, .{ .cubic = second }, &result));
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
