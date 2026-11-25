// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! One span of a TSect: a sub-curve with its retained controls, bounds and the spans of the other curve it may still meet.
const std = @import("std");
const n = @import("../../numeric.zig");
const curves = @import("../../curve.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const Bounds = curves.Bounds;
const Allocator = std.mem.Allocator;
const Intersections = @import("../../Intersections.zig");
const Span = @This();

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
pub fn storage(curve: Curve) Span {
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
