// Copyright 2014 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../../LICENSE.
//! End events: equal ends, the closest records, and recovering removed ends.
const std = @import("std");
const curves = @import("../../curve.zig");
const Curve = curves.Curve;
const Point = curves.Point;
const Intersections = @import("../../Intersections.zig");
const sect = @import("../sect.zig");
const Sect = @import("Sect.zig");
const Span = @import("Span.zig");

pub fn endsEqual(first: *const Sect, second: *const Sect, result: *Intersections) u4 {
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

pub fn addClosest(first: *Sect, second: *Sect, result: *Intersections) !void {
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

pub fn addRemovedEnds(first: *Sect, second: *Sect, flags: u4, result: *Intersections) void {
    if (first.removed_start and flags & 1 == 0) addRemovedEnd(first, second, 0, false, result);
    if (first.removed_end and flags & 2 == 0) addRemovedEnd(first, second, 1, false, result);
    if (second.removed_start and flags & 4 == 0) addRemovedEnd(second, first, 0, true, result);
    if (second.removed_end and flags & 8 == 0) addRemovedEnd(second, first, 1, true, result);
}

fn addRemovedEnd(first: *Sect, second: *Sect, t: f64, swapped: bool, result: *Intersections) void {
    const point = first.curve.ptAtT(t);
    var perpendicular: Span.Coincident = .{};
    perpendicular.setPerp(first.curve, t, point, second.curve);
    if (!perpendicular.match) return;
    if (swapped) _ = result.insert(perpendicular.t, t, perpendicular.point) else _ = result.insert(t, perpendicular.t, perpendicular.point);
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
        const count = try sect.intersect(std.testing.allocator, source_a, source_b, &result);
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
        try std.testing.expect(@import("../separation.zig").atMostOne(a, b));
        var result: Intersections = .{};
        try std.testing.expectEqual(@as(usize, 1), try sect.intersect(std.testing.allocator, a, b, &result));
        const root = (@sqrt(@as(f64, 3)) - 1) / 2;
        const source_time = if (reversed & 1 == 0) root else 1 - root;
        const endpoint: f64 = if (reversed & 2 == 0) 1 else 0;
        try std.testing.expectApproxEqAbs(source_time, result.parameters[swapped][0], 1e-14);
        try std.testing.expectEqual(endpoint, result.parameters[1 - swapped][0]);
        try std.testing.expect(!result.isCoincident(0));
    };
}
