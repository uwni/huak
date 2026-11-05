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
pub fn closestTo(self: *const Intersections, start: f64, end: f64, point: Point, distance: *f64) ?usize {
    distance.* = std.math.floatMax(f64);
    var result: ?usize = null;
    for (self.points[0..self.used], 0..) |hit, index| {
        if (!n.between(start, self.parameters[0][index], end)) continue;
        const candidate = point.sub(hit).lengthSquared();
        if (distance.* > candidate) {
            distance.* = candidate;
            result = index;
        }
    }
    return result;
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

fn bit(index: usize) u16 {
    return @as(u16, 1) << @intCast(index);
}

fn expectCoincidenceIdentity(result: *const Intersections, original_flags: u16) !void {
    for (result.points[0..result.used], 0..) |point, index| {
        const identity: usize = @as(usize, @intFromFloat(point.y)) - 1;
        const expected = original_flags & bit(identity) != 0;
        try std.testing.expectEqual(expected, result.isCoincident(index));
    }
    try std.testing.expect(result.coincident < bit(result.used));
}

test "intersection storage preserves root identity across every endpoint replacement position and label pattern" {
    const t = std.testing;
    for (0..16) |pattern| for (0..4) |replaced| for ([_]bool{ false, true }) |to_one| {
        var result: Intersections = .{ .max = 10 };
        for (0..4) |identity| {
            const offset = @as(f64, @floatFromInt(if (to_one) 4 - identity else identity + 1)) * 1e-14;
            const one = if (to_one) 1 - offset else offset;
            _ = result.insert(one, @as(f64, @floatFromInt(identity + 1)) / 5, .{ .x = one, .y = @floatFromInt(identity + 1) });
        }
        for (0..4) |identity| if (pattern & (@as(usize, 1) << @intCast(identity)) != 0) result.setCoincident(identity);
        const old_two = result.parameters[1][replaced];
        const point: Point = .{ .x = if (to_one) 1 else 0, .y = @floatFromInt(replaced + 1) };
        try t.expectEqual(@as(?usize, if (to_one) 3 else 0), result.insert(point.x, old_two, point));
        try t.expectEqual(@as(usize, 4), result.used);
        try expectCoincidenceIdentity(&result, @intCast(pattern));
        for (1..result.used) |index| try t.expect(result.parameters[0][index - 1] <= result.parameters[0][index]);
    };
}

test "intersection storage replacement carries its label to a new equal-time sorted slot" {
    const t = std.testing;
    const second = [_]f64{ 0.1, 1e-14, 0.5, 0.9 };
    for (0..16) |pattern| {
        var result: Intersections = .{ .max = 10 };
        for (second, 0..) |two, identity| _ = result.insert(0.5, two, .{ .x = 0.5, .y = @floatFromInt(identity + 1) });
        for (0..4) |identity| if (pattern & (@as(usize, 1) << @intCast(identity)) != 0) result.setCoincident(identity);
        const replacement = result.insert(0.5, 0, .{ .x = 0.5, .y = 2 });
        // Preserve the existing guard against adding an interior point to a
        // complete coincident run. All other patterns move identity 2 to 3.
        try t.expectEqual(@as(?usize, if (pattern == 3) null else 3), replacement);
        try expectCoincidenceIdentity(&result, @intCast(pattern));
    }
}

test "intersection storage deletion removes only that root label including final and sole entries" {
    const t = std.testing;
    for (0..16) |pattern| for (0..4) |removed| {
        var result: Intersections = .{ .max = 10 };
        for (0..4) |identity| {
            const time = @as(f64, @floatFromInt(identity + 1)) / 5;
            _ = result.insert(time, time, .{ .x = time, .y = @floatFromInt(identity + 1) });
        }
        for (0..4) |identity| if (pattern & (@as(usize, 1) << @intCast(identity)) != 0) result.setCoincident(identity);
        result.removeOne(removed);
        try t.expectEqual(@as(usize, 3), result.used);
        for (result.points[0..result.used]) |point| try t.expect(point.y != @as(f64, @floatFromInt(removed + 1)));
        try expectCoincidenceIdentity(&result, @intCast(pattern));
        try t.expect(result.insert(1, 1, .{ .x = 1, .y = 5 }) != null);
        try expectCoincidenceIdentity(&result, @intCast(pattern));
        while (result.used != 0) result.removeOne(result.used - 1);
        try t.expectEqual(@as(u16, 0), result.coincident);
        _ = result.insert(0, 0, .{ .x = 0, .y = 5 });
        try expectCoincidenceIdentity(&result, 0);
    };
}

test "intersection storage capacity failure clears root tags and keeps overflow until reset" {
    const t = std.testing;
    var result: Intersections = .{ .max = 2 };
    try t.expect(result.insertCoincident(0.2, 0.2, .{ .x = 0.2, .y = 1 }) != null);
    try t.expect(result.insertCoincident(0.4, 0.4, .{ .x = 0.4, .y = 2 }) != null);
    try t.expectEqual(@as(u16, 3), result.coincident);
    try t.expect(result.insert(0.8, 0.8, .{ .x = 0.8, .y = 3 }) == null);
    try t.expectEqual(@as(usize, 0), result.used);
    try t.expect(result.overflow);
    try t.expectEqual(@as(u16, 0), result.coincident);

    result.reset();
    try t.expect(!result.overflow);
    try t.expectEqual(@as(usize, 2), result.max);
    try t.expectEqual(@as(?usize, 0), result.insert(0.5, 0.5, .{ .x = 0.5, .y = 1 }));
    try t.expectEqual(@as(usize, 1), result.used);
    try t.expectEqual(@as(u16, 0), result.coincident);
}

test "intersection storage preserves ordered pairs endpoint replacement and coincidence bits" {
    const t = std.testing;
    var result: Intersections = .{ .max = 10 };
    _ = result.insert(0.8, 0.2, .{ .x = 8, .y = 2 });
    _ = result.insert(0.2, 0.8, .{ .x = 2, .y = 8 });
    _ = result.insert(0.5, 0.5, .{ .x = 5, .y = 5 });
    try t.expectEqualSlices(f64, &.{ 0.2, 0.5, 0.8 }, result.parameters[0][0..result.used]);
    try t.expect(result.insert(0.5, 0.5, .{ .x = 5, .y = 5 }) == null);
    result.setCoincident(0);
    result.setCoincident(2);
    result.removeOne(1);
    try t.expectEqual(@as(usize, 2), result.used);
    try t.expectEqual(@as(u16, 3), result.coincident);
    result.reset();
    _ = result.insert(1e-14, 1e-14, .{ .x = 1e-14, .y = 1e-14 });
    _ = result.insert(0, 0, .{ .x = 0, .y = 0 });
    try t.expectEqual(@as(usize, 1), result.used);
    try t.expectEqual(@as(f64, 0), result.parameters[0][0]);
    try t.expect(result.points[0].eql(.{ .x = 0, .y = 0 }));
}

test "intersection storage endpoint replacement retains the same root coincidence identity" {
    const t = std.testing;
    var result: Intersections = .{ .max = 10 };
    _ = result.insert(1e-14, 1e-14, .zero);
    _ = result.insert(0.5, 0.5, .{ .x = 5, .y = 5 });
    _ = result.insert(1, 1, .{ .x = 10, .y = 10 });
    result.setCoincident(0);
    result.setCoincident(2);
    try t.expectEqual(@as(usize, 3), result.used);
    try t.expectEqual(@as(u16, 5), result.coincident);

    // The original C++ mask 5 -> 6 changed which root was coincident.
    // Endpoint replacement refines root 0, so roots 0 and 2 retain the tag.
    try t.expectEqual(@as(?usize, 0), result.insert(0, 0, .zero));
    try t.expectEqual(@as(usize, 3), result.used);
    try t.expectEqual(@as(u16, 5), result.coincident);
    try t.expectEqualSlices(f64, &.{ 0, 0.5, 1 }, result.parameters[0][0..result.used]);
    try t.expectEqualSlices(f64, &.{ 0, 0.5, 1 }, result.parameters[1][0..result.used]);
    try t.expect(result.points[0].eql(.zero));
    try t.expect(result.points[1].eql(.{ .x = 5, .y = 5 }));
    try t.expect(result.points[2].eql(.{ .x = 10, .y = 10 }));
}

test "intersection storage replacing the last coincident endpoint does not shift a nonexistent tail" {
    const t = std.testing;
    var result: Intersections = .{ .max = 10 };
    const first = [_]f64{ 0, 0.734375, 0.7500000596338054, 1 };
    const second = [_]f64{ 0, 0.7343750000000164, 0.7500000596337759, 0.9999999999999936 };
    for (first, second) |one, two| _ = result.insert(one, two, .{ .x = one, .y = two });
    for (0..result.used) |index| result.setCoincident(index);
    try t.expectEqual(@as(u16, 15), result.coincident);

    // Captured from section INTERSECT canonical circle coverage. The original
    // C++ erase/reinsert at the final slot leaves both masks equal to 15.
    try t.expectEqual(@as(?usize, 3), result.insert(1, 1, .{ .x = 1, .y = 1 }));
    try t.expectEqual(@as(usize, 4), result.used);
    try t.expectEqual(@as(u16, 15), result.coincident);
    try t.expectEqualSlices(f64, &first, result.parameters[0][0..result.used]);
    try t.expectEqualSlices(f64, &.{ 0, second[1], second[2], 1 }, result.parameters[1][0..result.used]);
}

test "DD line intersection preserves original captured near parallel parameters" {
    const cases = [_][2]Line{
        .{ .{ .points = .{ .{ .x = 0.77988957318917262, .y = -0.28513156665940087 }, .{ .x = 0.74990364813785093, .y = -0.28996213816751437 } } }, .{ .points = .{ .{ .x = 0.7499036481378516, .y = -0.28996213816751831 }, .{ .x = 0.77988957318917196, .y = -0.28513156665939693 } } } },
        .{ .{ .points = .{ .{ .x = 0.7499036481378516, .y = -0.28996213816751831 }, .{ .x = 0.77988957318917196, .y = -0.28513156665939693 } } }, .{ .points = .{ .{ .x = 0.76489661066351178, .y = -0.28754685241345762 }, .{ .x = 0.77988957318917262, .y = -0.28513156665940087 } } } },
        .{ .{ .points = .{ .{ .x = -0.77633758876323178, .y = -0.25158900773400045 }, .{ .x = -0.74198642876148746, .y = -0.25814602339387488 } } }, .{ .points = .{ .{ .x = -0.75916200876235962, .y = -0.25486751556393766 }, .{ .x = -0.77633758876323167, .y = -0.25158900773400045 } } } },
    };
    for (cases, 0..) |source, case_index| {
        var baseline: Intersections = .{ .allow_near = false };
        try std.testing.expectEqual(@as(usize, 1), baseline.lineLine(source[0], source[1]));
        if (case_index == 0) {
            try std.testing.expectEqual(@as(f64, 0.5), baseline.parameters[0][0]);
            try std.testing.expectEqual(@as(f64, 0.5), baseline.parameters[1][0]);
        }
        for ([_]i32{ -80, 0, 80 }) |exponent| for (0..4) |reverse| {
            var lines: [2]Line = undefined;
            var largest: f64 = 0;
            for (&lines, 0..) |*line, which| for (&line.points, 0..) |*point, index| {
                point.* = source[which].points[index ^ ((reverse >> @intCast(which)) & 1)];
                point.x = std.math.ldexp(point.x, exponent);
                point.y = std.math.ldexp(point.y, exponent);
                largest = @max(largest, @max(@abs(point.x), @abs(point.y)));
            };
            var result: Intersections = .{ .allow_near = false };
            try std.testing.expectEqual(@as(usize, 1), result.lineLine(lines[0], lines[1]));
            const first = lines[0].ptAtT(result.parameters[0][0]);
            const second = lines[1].ptAtT(result.parameters[1][0]);
            try std.testing.expect(first.sub(second).length() <= 32 * std.math.floatEps(f64) * largest);
            for (0..2) |which| {
                const expected = if (reverse & (@as(usize, 1) << @intCast(which)) != 0) 1 - baseline.parameters[which][0] else baseline.parameters[which][0];
                try std.testing.expectApproxEqAbs(expected, result.parameters[which][0], 32 * std.math.floatEps(f64));
            }
        };
    }
}

test "axis intersections preserve overlap and reversed second parameters" {
    const diagonal: Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.lineLine(diagonal, .{ .points = .{ .{ .x = 8, .y = 2 }, .{ .x = 0, .y = 2 } } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[0][0]);
    try std.testing.expectEqual(@as(f64, 0.75), result.parameters[1][0]);
    result.reset();
    const collinear: Line = .{ .points = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 2 } } };
    try std.testing.expectEqual(@as(usize, 2), result.lineLine(collinear, .{ .points = .{ .{ .x = 0, .y = 2 }, .{ .x = 4, .y = 2 } } }));
    try std.testing.expectEqual(@as(u16, 3), result.coincident);
}

test "quad and cubic line roots preserve tangent events and axis parameters" {
    const cubic: Cubic = .{ .points = .{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    const quad: Quad = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = 1 } } };
    const line: Line = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.cubicLine(cubic, line));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[1][0], 1e-14);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.cubicLine(cubic, .{ .points = .{ .{ .x = 1.5, .y = -2 }, .{ .x = 1.5, .y = 2 } } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[1][0]);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.quadLine(quad, line));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), result.parameters[1][0], 1e-14);
    result.reset();
    try std.testing.expectEqual(@as(usize, 1), result.quadLine(quad, .{ .points = .{ .{ .x = 2, .y = 0 }, Point.zero } }));
    try std.testing.expectEqual(@as(f64, 0.5), result.parameters[1][0]);
}

test "line curve coincidence keeps clipped interval endpoints" {
    const curve: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } } };
    const line: Line = .{ .points = .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 2), result.cubicLine(curve, line));
    try std.testing.expectEqual(@as(u16, 3), result.coincident);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), result.parameters[0][0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), result.parameters[0][1], 1e-14);
}

test {
    _ = @import("intersections/sect.zig");
    _ = @import("intersections/shared_coordinate.zig");
}

test "ray intersections retain curve roots beyond the finite ray segment" {
    const curve: Cubic = .{ .points = .{ .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    const ray: Line = .{ .points = .{ .{ .x = 8, .y = 0 }, .{ .x = 9, .y = 0 } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 1), result.intersectRay(.{ .cubic = curve }, ray));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.parameters[0][0], 1e-14);
    try std.testing.expectEqual(@as(f64, 1.5), result.points[0].x);
    var distance: f64 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), result.closestTo(0, 1, .{ .x = 0, .y = 0 }, &distance));
}

test "TSect cubic intersections retain two curved source events" {
    const base_a: Cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } };
    const base_b: Cubic = .{ .points = .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 3, .y = 1 } } };
    // x=3t is injective, so t=u. The independent equation
    // 6t(1-t)=1-6t(1-t) gives these two exact mathematical events.
    const first = (1 - @sqrt(@as(f64, 2.0 / 3.0))) / 2;
    const expected = [_]f64{ first, 1 - first };
    for ([_]i32{ -8, 0, 8 }) |exponent| for (0..4) |reverse| for (0..2) |swapped_inputs| {
        errdefer std.debug.print("two-event fixture: scale=2^{d} reverse={d} swap={d}\n", .{ exponent, reverse, swapped_inputs });
        var a = base_a;
        var b = base_b;
        if (reverse & 1 != 0) std.mem.reverse(Point, &a.points);
        if (reverse & 2 != 0) std.mem.reverse(Point, &b.points);
        for (&a.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        for (&b.points) |*point| point.* = .{ .x = std.math.ldexp(point.x, exponent), .y = std.math.ldexp(point.y, exponent) };
        const source_a: Curve = .{ .cubic = if (swapped_inputs == 0) a else b };
        const source_b: Curve = .{ .cubic = if (swapped_inputs == 0) b else a };
        const reverse_a = reverse & (if (swapped_inputs == 0) @as(usize, 1) else 2) != 0;
        const reverse_b = reverse & (if (swapped_inputs == 0) @as(usize, 2) else 1) != 0;
        var result: Intersections = .{};
        try std.testing.expectEqual(@as(usize, 2), try result.curveCurve(std.testing.allocator, source_a, source_b));
        for (0..expected.len) |index| {
            const parameter = expected[if (reverse_a) expected.len - 1 - index else index];
            try std.testing.expectApproxEqAbs(if (reverse_a) 1 - parameter else parameter, result.parameters[0][index], 1e-12);
            try std.testing.expectApproxEqAbs(if (reverse_b) 1 - parameter else parameter, result.parameters[1][index], 1e-12);
            const pa = source_a.ptAtT(result.parameters[0][index]);
            const pb = source_b.ptAtT(result.parameters[1][index]);
            try std.testing.expect(pa.distance(pb) < 1e-12);
            try std.testing.expect(!result.isCoincident(index));
        }
    };
}

test "TSect rejects curved hull overlaps without a true event" {
    const a: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } } };
    const b: Curve = .{ .cubic = .{ .points = .{ .{ .x = 0, .y = 0.1 }, .{ .x = 1, .y = 2.1 }, .{ .x = 2, .y = 2.1 }, .{ .x = 3, .y = 0.1 } } } };
    var result: Intersections = .{};
    try std.testing.expectEqual(@as(usize, 0), try result.curveCurve(std.testing.allocator, a, b));
}

test "curve dispatch returns exact coincident cubic endpoints under either near policy" {
    const curves = [_]Curve{
        .{ .cubic = .{ .points = .{ Point.zero, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 0 } } } },
        // TSect alone can return both endpoints without marking this overlap.
        .{ .cubic = .{ .points = .{ Point.zero, .{ .x = 0.0625, .y = -0.75 }, .{ .x = 0.1875, .y = 0.25 }, .{ .x = 0.5, .y = 0 } } } },
    };
    for (curves) |a| for ([_]bool{ false, true }) |allow_near| for ([_]bool{ false, true }) |reversed| {
        var result: Intersections = .{ .allow_near = allow_near };
        const b = if (reversed) a.reverse() else a;
        try std.testing.expectEqual(@as(usize, 2), try result.curveCurve(std.testing.allocator, a, b));
        try std.testing.expectEqualSlices(f64, &.{ 0, 1 }, result.parameters[0][0..result.used]);
        try std.testing.expectEqualSlices(f64, if (reversed) &.{ 1, 0 } else &.{ 0, 1 }, result.parameters[1][0..result.used]);
        try std.testing.expectEqual(@as(u16, 3), result.coincident);
    };
}

test "successive curve queries preserve the near policy and clear prior endpoint observations" {
    const a: Curve = .{ .quad = .{ .points = .{ Point.zero, .{ .x = 1, .y = 0.5 }, .{ .x = 2, .y = 1 } } } };
    var b = a;
    b.quad.points[2].y = std.math.nextAfter(f64, 1, 2);
    var exact: Intersections = .{ .allow_near = false };
    try std.testing.expectEqual(@as(usize, 1), try exact.curveCurve(std.testing.allocator, a, b));
    try std.testing.expectEqual(@as(f64, 0), exact.parameters[0][0]);
    try std.testing.expectEqual(@as(f64, 0), exact.parameters[1][0]);
    try std.testing.expectEqual(Point.zero, exact.points[0]);
    try std.testing.expectEqual(@as(usize, 1), try exact.curveCurve(std.testing.allocator, a, b));

    // The endpoint at t=1 is only present under the near policy.
    var near: Intersections = .{};
    _ = try near.curveCurve(std.testing.allocator, a, b);
    try std.testing.expect(near.nearly_same[1]);
    try std.testing.expect(near.hasT(1));
    _ = try near.curveCurve(std.testing.allocator, a, a);
    try std.testing.expectEqual([2]bool{ false, false }, near.nearly_same);
}
