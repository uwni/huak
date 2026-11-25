// Copyright 2012 Google Inc.
// Copyright 2026 Huak contributors.
// BSD-style license: LICENSE.
//! Binary64 Zig port of SkIntersections and SkDLineIntersection at Skia
//! 1c2b83b5af8f53181742af1505edd18c2418c777, including the existing DD solve.
const std = @import("std");
const n = @import("numeric.zig");
const Point = @import("point.zig").Point;
const Line = @import("curve.zig").Line;
const Quad = @import("curve.zig").Quad;
const Cubic = @import("curve.zig").Cubic;
const Curve = @import("curve.zig").Curve;
const line_curve = @import("intersections/line_curve.zig");

/// Sorted intersections and their paired parameters. Coincidence and near-end
/// metadata retain upstream meanings; each paired event has one coincidence bit.
const Intersections = @This();

points: [13]Point = @splat(.{ .x = 0, .y = 0 }),
parameters: [2][13]f64 = @splat(@splat(0)),
coincident: u16 = 0,
nearly_same: [2]bool = @splat(false),
used: usize = 0,
max: usize = 0,
allow_near: bool = true,
/// The upstream release implementation clears results on capacity failure.
/// Keep that state but expose it so the caller can propagate the failure.
overflow: bool = false,

pub fn reset(self: *Intersections) void {
    self.nearly_same = @splat(false);
    self.used = 0;
    self.coincident = 0;
    self.overflow = false;
}
pub fn setMax(self: *Intersections, count: usize) void {
    std.debug.assert(count <= self.points.len);
    self.max = count;
}
pub fn hasT(self: *const Intersections, t: f64) bool {
    std.debug.assert(t == 0 or t == 1);
    return self.used > 0 and (if (t == 0) self.parameters[0][0] == 0 else self.parameters[0][self.used - 1] == 1);
}
pub fn hasOppT(self: *const Intersections, t: f64) bool {
    return self.used > 0 and (self.parameters[1][0] == t or self.parameters[1][self.used - 1] == t);
}
pub fn isCoincident(self: *const Intersections, index: usize) bool {
    return self.coincident & bit(index) != 0;
}
pub fn setCoincident(self: *Intersections, index: usize) void {
    self.coincident |= bit(index);
}
pub fn clearCoincidence(self: *Intersections, index: usize) void {
    self.coincident &= ~bit(index);
}
pub fn insert(self: *Intersections, one: f64, two: f64, point: Point) ?usize {
    var was_coincident = false;
    if (self.coincident == 3 and n.between(self.parameters[0][0], one, self.parameters[0][1])) return null;
    for (0..self.used) |index| {
        const old_one = self.parameters[0][index];
        const old_two = self.parameters[1][index];
        if (one == old_one and two == old_two) return null;
        if (n.moreRoughlyEqual(old_one, one) and n.moreRoughlyEqual(old_two, two)) {
            if ((!n.preciselyZero(one) or n.preciselyZero(old_one)) and
                (!n.preciselyEqual(one, 1) or n.preciselyEqual(old_one, 1)) and
                (!n.preciselyZero(two) or n.preciselyZero(old_two)) and
                (!n.preciselyEqual(two, 1) or n.preciselyEqual(old_two, 1))) return null;
            was_coincident = self.isCoincident(index);
            self.removeOne(index);
            break;
        }
    }
    var index: usize = 0;
    while (index < self.used and self.parameters[0][index] <= one) : (index += 1) {}
    if (self.used >= self.max) {
        self.used = 0;
        self.coincident = 0;
        self.overflow = true;
        return null;
    }
    // Upstream only inserts valid closed-segment parameters.
    if (one < 0 or one > 1 or two < 0 or two > 1) return null;
    var at = self.used;
    while (at > index) : (at -= 1) {
        self.points[at] = self.points[at - 1];
        self.parameters[0][at] = self.parameters[0][at - 1];
        self.parameters[1][at] = self.parameters[1][at - 1];
    }
    if (index < self.used) {
        const clear_mask = ~((bit(index)) - 1);
        self.coincident += self.coincident & clear_mask;
    }
    self.points[index] = point;
    self.parameters[0][index] = one;
    self.parameters[1][index] = two;
    self.used += 1;
    if (was_coincident) self.setCoincident(index);
    return index;
}
pub fn insertNear(self: *Intersections, one: f64, two: f64, first: Point, second: Point) void {
    std.debug.assert(n.zeroOrOne(one) and n.zeroOrOne(two) and !first.eql(second));
    const index: usize = if (one != 0) 1 else 0;
    self.nearly_same[index] = true;
    _ = self.insert(one, two, first);
}
pub fn insertCoincident(self: *Intersections, one: f64, two: f64, point: Point) ?usize {
    const index = self.insert(one, two, point) orelse return null;
    self.setCoincident(index);
    return index;
}
pub fn removeOne(self: *Intersections, index: usize) void {
    std.debug.assert(index < self.used);
    self.used -= 1;
    const remaining = self.used - index;
    @memmove(self.points[index..][0..remaining], self.points[index + 1 ..][0..remaining]);
    for (&self.parameters) |*column| @memmove(column[index..][0..remaining], column[index + 1 ..][0..remaining]);
    const lower_mask = bit(index) - 1;
    self.coincident = (self.coincident & lower_mask) | ((self.coincident >> 1) & ~lower_mask);
}
pub fn merge(self: *Intersections, first: *const Intersections, first_index: usize, second: *const Intersections, second_index: usize) void {
    self.reset();
    self.parameters[0][0] = first.parameters[0][first_index];
    self.parameters[1][0] = second.parameters[0][second_index];
    self.points[0] = first.points[first_index];
    self.used = 1;
}
pub fn intersectRay(self: *Intersections, curve: Curve, line: Line) usize {
    return self.intersectRayFrom(curve, line.points[0], line.points[1].sub(line.points[0]));
}
pub fn intersectRayFrom(self: *Intersections, curve: Curve, origin: Point, direction: Point) usize {
    return switch (curve) {
        .line => |value| self.lineRayFrom(value, origin, direction),
        inline .quad, .cubic => |value| line_curve.ray(self, value, origin, direction),
    };
}
fn lineRayFrom(self: *Intersections, a: Line, origin: Point, b_length: Point) usize {
    self.max = 2;
    const a_length = a.points[1].sub(a.points[0]);
    const denominator = b_length.y * a_length.x - a_length.y * b_length.x;
    if (!n.approximatelyZero(denominator)) {
        const ab = a.points[0].sub(origin);
        self.parameters[0][0] = (ab.y * b_length.x - b_length.y * ab.x) / denominator;
        self.parameters[1][0] = (ab.y * a_length.x - a_length.y * ab.x) / denominator;
        self.computePoints(a, 1);
    } else {
        if (!n.almostEqualUlps(a_length.x * a.points[0].y - a_length.y * a.points[0].x, a_length.x * origin.y - a_length.y * origin.x)) {
            self.used = 0;
            return 0;
        }
        // Match the original ray convention: coincident unbounded rays
        // have no distinguished intersection parameter pair.
        self.parameters[0][0] = 0;
        self.parameters[1][0] = 1;
        self.parameters[1][1] = 1;
        self.computePoints(a, 2);
    }
    return self.used;
}

fn cleanUpParallelLines(self: *Intersections, parallel: bool) void {
    while (self.used > 2) self.removeOne(1);
    if (self.used == 2 and !parallel) {
        const start_match = self.parameters[0][0] == 0 or n.zeroOrOne(self.parameters[1][0]);
        const end_match = self.parameters[0][1] == 1 or n.zeroOrOne(self.parameters[1][1]);
        if ((!start_match and !end_match) or n.approximatelyEqual(self.parameters[0][0], self.parameters[0][1])) {
            if (start_match and end_match and (self.parameters[0][0] != 0 or !n.zeroOrOne(self.parameters[1][0])) and self.parameters[0][1] == 1 and n.zeroOrOne(self.parameters[1][1])) self.removeOne(0) else self.removeOne(@intFromBool(end_match));
        }
    }
    if (self.used == 2) self.coincident = 3;
}
fn computePoints(self: *Intersections, line: Line, count: usize) void {
    self.points[0] = line.ptAtT(self.parameters[0][0]);
    self.used = count;
    if (count == 2) self.points[1] = line.ptAtT(self.parameters[0][1]);
}

/// SkDLineIntersection.cpp::intersect. Endpoint and near/coincidence flow
/// is unchanged; determinant arithmetic retains the accepted DD port.
pub fn lineLine(self: *Intersections, a: Line, b: Line) usize {
    self.max = 3;
    for (a.points, 0..) |point, index| {
        const t = b.exactPoint(point);
        if (t >= 0) _ = self.insert(@floatFromInt(index), t, point);
    }
    for (b.points, 0..) |point, index| {
        const t = a.exactPoint(point);
        if (t >= 0) _ = self.insert(t, @floatFromInt(index), point);
    }
    const av = a.points[1].sub(a.points[0]);
    const bv = b.points[1].sub(b.points[0]);
    const unparallel = if (self.allow_near) n.notAlmostEqualUlpsPin(av.x * bv.y, av.y * bv.x) else n.notAlmostDequalUlps(av.x * bv.y, av.y * bv.x);
    if (unparallel and self.used == 0) {
        const ax = n.DD.difference(a.points[1].x, a.points[0].x);
        const ay = n.DD.difference(a.points[1].y, a.points[0].y);
        const bx = n.DD.difference(b.points[1].x, b.points[0].x);
        const by = n.DD.difference(b.points[1].y, b.points[0].y);
        const abx = n.DD.difference(a.points[0].x, b.points[0].x);
        const aby = n.DD.difference(a.points[0].y, b.points[0].y);
        const denominator = n.ddCross(ax, ay, bx, by);
        const ta = n.ddCross(bx, by, abx, aby).dividedBy(denominator);
        const tb = n.ddCross(ax, ay, abx, aby).dividedBy(denominator);
        if (n.between(0, ta, 1) and n.between(0, tb, 1)) {
            self.parameters[0][0] = ta;
            self.parameters[1][0] = tb;
            self.computePoints(a, 1);
        }
    }
    if (self.allow_near or !unparallel) {
        var a_near_b: [2]f64 = undefined;
        var b_near_a: [2]f64 = undefined;
        var a_not_b = [_]bool{ false, false };
        var b_not_a = [_]bool{ false, false };
        var near_count: usize = 0;
        for (0..2) |index| {
            a_near_b[index] = b.nearPoint(a.points[index], &a_not_b[index]);
            near_count += @intFromBool(a_near_b[index] >= 0);
            b_near_a[index] = a.nearPoint(b.points[index], &b_not_a[index]);
            near_count += @intFromBool(b_near_a[index] >= 0);
        }
        if (near_count > 0) {
            if (near_count != 2 or a_not_b[0] == a_not_b[1]) {
                for (0..2) |index| {
                    if (!a_not_b[index]) continue;
                    const nearer: usize = @intFromBool(a_near_b[index] > 0.5);
                    if (!b_not_a[nearer]) continue;
                    self.insertNear(@floatFromInt(index), @floatFromInt(nearer), a.points[index], b.points[nearer]);
                    a_near_b[index] = -1;
                    b_near_a[nearer] = -1;
                    near_count -= 2;
                }
            }
            if (near_count > 0) {
                for (0..2) |index| {
                    if (a_near_b[index] >= 0) _ = self.insert(@floatFromInt(index), a_near_b[index], a.points[index]);
                }
                for (0..2) |index| {
                    if (b_near_a[index] >= 0) _ = self.insert(b_near_a[index], @floatFromInt(index), b.points[index]);
                }
            }
        }
    }
    self.cleanUpParallelLines(!unparallel);
    return self.used;
}

pub fn cubicLine(self: *Intersections, cubic: Cubic, line: Line) usize {
    return line_curve.intersect(Cubic, self, cubic, line);
}
pub fn quadLine(self: *Intersections, quad: Quad, line: Line) usize {
    return line_curve.intersect(Quad, self, quad, line);
}
pub fn curveCurve(self: *Intersections, allocator: std.mem.Allocator, first: Curve, second: Curve) !usize {
    if (second == .line) return switch (first) {
        .line => |a| self.lineLine(a, second.line),
        .quad => |a| self.quadLine(a, second.line),
        .cubic => |a| self.cubicLine(a, second.line),
    };
    if (first == .line) {
        const count = switch (second) {
            .line => unreachable,
            .quad => |b| self.quadLine(b, first.line),
            .cubic => |b| self.cubicLine(b, first.line),
        };
        std.mem.swap([13]f64, &self.parameters[0], &self.parameters[1]);
        return count;
    }
    if (@import("intersections/shared_coordinate.zig").intersect(first, second, self)) return self.used;
    // Match SkIntersections' cubic/quad overload: the higher degree
    // curve owns TSect's capacity and the stored parameters are restored
    // to the caller's operand order after subdivision.
    if (first == .quad and second == .cubic) {
        const count = try @import("intersections/sect.zig").intersect(allocator, second, first, self);
        std.mem.swap([13]f64, &self.parameters[0], &self.parameters[1]);
        return count;
    }
    return @import("intersections/sect.zig").intersect(allocator, first, second, self);
}

pub fn bit(index: usize) u16 {
    return @as(u16, 1) << @intCast(index);
}

test {
    _ = @import("intersections/sect.zig");
    _ = @import("intersections/shared_coordinate.zig");
    _ = @import("intersections/storage_test.zig");
    _ = @import("intersections/lines_test.zig");
    _ = @import("intersections/curves_test.zig");
}
