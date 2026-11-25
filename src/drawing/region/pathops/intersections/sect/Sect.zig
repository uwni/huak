// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! A TSect: the linked spans of one curve, their removal and the bookkeeping of coincident runs.
const std = @import("std");
const n = @import("../../numeric.zig");
const curves = @import("../../curve.zig");
const Curve = curves.Curve;
const Allocator = std.mem.Allocator;
const Span = @import("Span.zig");
const Sect = @This();

curve: Curve,
allocator: Allocator,
head: ?*Span = null,
coincident: ?*Span = null,
deleted: ?*Span = null,
active_count: i32 = 0,
removed_start: bool = false,
removed_end: bool = false,
hung: bool = false,

pub fn init(allocator: Allocator, curve: Curve) !Sect {
    var result: Sect = .{ .curve = curve, .allocator = allocator };
    const head = try result.addOne();
    head.* = Span.init(curve);
    result.head = head;
    return result;
}
pub fn addOne(self: *Sect) !*Span {
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
pub fn addSplitAt(self: *Sect, span: *Span, t: f64) !*Span {
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
pub fn boundsMax(self: *Sect) ?*Span {
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
pub fn tail(self: *const Sect) ?*Span {
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
pub fn removedEndCheck(self: *Sect, span: *const Span) void {
    if (span.start_t == 0) self.removed_start = true;
    if (span.end_t == 1) self.removed_end = true;
}
pub fn resetRemovedEnds(self: *Sect) void {
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
pub fn removeSpan(self: *Sect, span: *Span) bool {
    self.removedEndCheck(span);
    if (!self.unlinkSpan(span)) return false;
    return self.markSpanGone(span);
}
pub fn removeSpanRange(self: *Sect, first: *Span, last: *Span) void {
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
pub fn removeAllBut(self: *Sect, keep: *const Span, span: *Span, other: *Sect) void {
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
pub fn removeCoincident(self: *Sect, span: *Span, is_between: bool) bool {
    if (!self.unlinkSpan(span)) return false;
    if (is_between or n.between(0, span.coin_start.t, 1)) {
        self.active_count -= 1;
        span.next = self.coincident;
        self.coincident = span;
    } else _ = self.markSpanGone(span);
    return true;
}
pub fn deleteEmptySpans(self: *Sect) bool {
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
pub fn recoverCollapsed(self: *Sect) void {
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
pub fn collapsedCount(self: *const Sect) usize {
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
pub fn countConsecutiveSpans(first: *Span, last: **Span) usize {
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
pub fn updateBounded(self: *Sect, first: *Span, last: *Span, other_first: *Span) !bool {
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
pub fn computePerpendiculars(self: *Sect, other: *Sect, first: *Span, last: ?*Span) !void {
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
pub fn removeByPerpendicular(self: *Sect, other: *Sect) bool {
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
pub fn mergeCoincidence(self: *Sect, other: *Sect) void {
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
        var coin: Span.Coincident = .{};
        coin.setPerp(self.curve, mid_t, self.curve.ptAtT(mid_t), other.curve);
        if (coin.match) {
            small.end_t = large.end_t;
            small.coin_end = large.coin_end;
            if (larger_prior) |before| before.next = large.next else self.coincident = large.next;
        }
    }
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
