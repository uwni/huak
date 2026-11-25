// Copyright 2012 Google Inc.
// Copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Tests of intersection storage: sorted paired parameters, root labels and coincidence bits.
const std = @import("std");
const Point = @import("../point.zig").Point;
const Intersections = @import("../Intersections.zig");

fn expectCoincidenceIdentity(result: *const Intersections, original_flags: u16) !void {
    for (result.points[0..result.used], 0..) |point, index| {
        const identity: usize = @as(usize, @intFromFloat(point.y)) - 1;
        const expected = original_flags & Intersections.bit(identity) != 0;
        try std.testing.expectEqual(expected, result.isCoincident(index));
    }
    try std.testing.expect(result.coincident < Intersections.bit(result.used));
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
