// Ported from Paper.js v0.16.0 src/util/CollisionDetection.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const Allocator = types.Allocator;
const Bounds = geometry.BBox;

const Boxes = struct {
    first: []const Bounds,
    second: []const Bounds,
    fn at(self: Boxes, index: usize) Bounds {
        return if (index < self.first.len) self.first[index] else self.second[index - self.first.len];
    }
};

// Lower bound is the original binarySearch result plus one.
fn lowerBoundHigh(boxes: Boxes, indices: []const usize, axis: usize, value: f64) usize {
    var low: usize = 0;
    var high = indices.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (boxes.at(indices[middle]).high(axis) < value) low = middle + 1 else high = middle;
    }
    return low;
}

/// Paper.js bounds sweep. Equal input slices enable symmetric self collisions;
/// otherwise each row indexes the second input. Rows are sorted ascending.
/// sweep_vertical switches the primary axis; both axes are always checked.
/// The caller owns the rows and their buffers; release with deinitCandidates.
pub fn boundsCandidates(allocator: Allocator, first: []const Bounds, second: []const Bounds, epsilon: f64, sweep_vertical: bool) ![]std.ArrayList(usize) {
    if (!std.math.isFinite(epsilon) or epsilon < 0) return error.InvalidTolerance;
    const self = first.ptr == second.ptr and first.len == second.len;
    const count = if (self) first.len else std.math.add(usize, first.len, second.len) catch return error.GeometryWorkLimit;
    const boxes: Boxes = .{ .first = first, .second = second };
    const primary: usize = if (sweep_vertical) 1 else 0;
    const secondary: usize = 1 - primary;
    const order = try allocator.alloc(usize, count);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| {
        const box = boxes.at(index);
        if (std.math.isNan(box.min.x) or std.math.isNan(box.min.y) or std.math.isNan(box.max.x) or std.math.isNan(box.max.y)) return error.NonFinite;
        if (box.min.x > box.max.x or box.min.y > box.max.y) return error.InvalidBounds;
        entry.* = index;
    }
    const Sort = struct {
        boxes: Boxes,
        coordinate: usize,
        fn less(context: @This(), a: usize, b: usize) bool {
            const x = context.boxes.at(a).low(context.coordinate);
            const y = context.boxes.at(b).low(context.coordinate);
            return if (x == y) a < b else x < y;
        }
    };
    std.mem.sort(usize, order, Sort{ .boxes = boxes, .coordinate = primary }, Sort.less);
    const rows = try allocator.alloc(std.ArrayList(usize), first.len);
    errdefer allocator.free(rows);
    for (rows) |*row| row.* = .empty;
    errdefer for (rows) |*row| row.deinit(allocator);
    var active: std.ArrayList(usize) = .empty;
    defer active.deinit(allocator);
    for (order) |current| {
        const box = boxes.at(current);
        const current_a = current < first.len;
        const current_b = self or !current_a;
        const prune = lowerBoundHigh(boxes, active.items, primary, box.low(primary) - epsilon);
        @memmove(active.items[0 .. active.items.len - prune], active.items[prune..]);
        active.items.len -= prune;
        for (active.items) |other| {
            const opposite = boxes.at(other);
            const other_a = other < first.len;
            const other_b = self or !other_a;
            if ((current_a and other_b or current_b and other_a) and
                box.high(secondary) >= opposite.low(secondary) - epsilon and
                box.low(secondary) <= opposite.high(secondary) + epsilon)
            {
                if (current_a and other_b) try rows[current].append(allocator, if (self) other else other - first.len);
                if (current_b and other_a) try rows[other].append(allocator, if (self) current else current - first.len);
            }
        }
        if (current_a and self) try rows[current].append(allocator, current);
        const insertion = lowerBoundHigh(boxes, active.items, primary, box.high(primary));
        try active.insert(allocator, insertion, current);
    }
    for (rows) |row| std.mem.sort(usize, row.items, {}, std.sort.asc(usize));
    return rows;
}

/// Self-collision sweep of source control bounds. Source values stay borrowed.
pub fn curveCandidates(allocator: Allocator, sources: []const types.Source, epsilon: f64) ![]std.ArrayList(usize) {
    const boxes = try allocator.alloc(Bounds, sources.len);
    defer allocator.free(boxes);
    for (sources, boxes) |*source, *box| {
        if (!source.cubic.isFinite()) return error.NonFinite;
        box.* = source.cubic.controlBounds();
    }
    return boundsCandidates(allocator, boxes, boxes, epsilon, false);
}

pub fn deinitCandidates(allocator: Allocator, candidates: []std.ArrayList(usize)) void {
    for (candidates) |*row| row.deinit(allocator);
    allocator.free(candidates);
}

test "control-bound sweep keeps touching, contained, and separated candidates" {
    const t = std.testing;
    const sources = [_]types.Source{
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 0 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 2, .y = 2 } }, .next = 0, .contour = 0, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = 2, .y = 1 }, .p1 = .{ .x = 2, .y = 1 }, .p2 = .{ .x = 3, .y = 3 }, .p3 = .{ .x = 3, .y = 3 } }, .next = 1, .contour = 1, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = 0.5, .y = 0.5 }, .p1 = .{ .x = 0.5, .y = 0.5 }, .p2 = .{ .x = 1, .y = 1 }, .p3 = .{ .x = 1, .y = 1 } }, .next = 2, .contour = 2, .operand = 1 },
        .{ .cubic = .{ .p0 = .{ .x = 5, .y = 0 }, .p1 = .{ .x = 5, .y = 0 }, .p2 = .{ .x = 6, .y = 1 }, .p3 = .{ .x = 6, .y = 1 } }, .next = 3, .contour = 3, .operand = 1 },
    };
    const actual = try curveCandidates(t.allocator, &sources, 0);
    defer deinitCandidates(t.allocator, actual);
    try t.expectEqualSlices(usize, &.{ 0, 1, 2 }, actual[0].items);
    try t.expectEqualSlices(usize, &.{ 0, 1 }, actual[1].items);
    try t.expectEqualSlices(usize, &.{ 0, 2 }, actual[2].items);
    try t.expectEqualSlices(usize, &.{3}, actual[3].items);
}

test "large separated control bounds retain every self candidate" {
    const t = std.testing;
    const sources = try t.allocator.alloc(types.Source, 4096);
    defer t.allocator.free(sources);
    for (sources, 0..) |*source, index| {
        const x: f64 = @floatFromInt(index * 2);
        source.* = .{ .cubic = .{ .p0 = .{ .x = x, .y = 0 }, .p1 = .{ .x = x, .y = 0 }, .p2 = .{ .x = x + 1, .y = 1 }, .p3 = .{ .x = x + 1, .y = 1 } }, .next = index, .contour = index, .operand = 0 };
    }
    const actual = try curveCandidates(t.allocator, sources, 0);
    defer deinitCandidates(t.allocator, actual);
    for (actual, 0..) |row, index| try t.expectEqualSlices(usize, &.{index}, row.items);
}

test "vertical sweep returns ray to component candidates without matching within operands" {
    const t = std.testing;
    const rays = [_]Bounds{ .{ .min = .{ .x = 1, .y = 2 }, .max = .{ .x = std.math.inf(f64), .y = 2 } }, .{ .min = .{ .x = 8, .y = 8 }, .max = .{ .x = std.math.inf(f64), .y = 8 } }, .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = std.math.inf(f64), .y = 0 } } };
    const regions = [_]Bounds{ .{ .min = .{ .x = 3, .y = 1 }, .max = .{ .x = 6, .y = 3 } }, .{ .min = .{ .x = 2, .y = 7 }, .max = .{ .x = 7, .y = 9 } }, .{ .min = .{ .x = -1, .y = -1 }, .max = .{ .x = 1, .y = 1 } } };
    const actual = try boundsCandidates(t.allocator, &rays, &regions, 0, true);
    defer deinitCandidates(t.allocator, actual);
    try t.expectEqualSlices(usize, &.{0}, actual[0].items);
    try t.expectEqualSlices(usize, &.{}, actual[1].items);
    try t.expectEqualSlices(usize, &.{2}, actual[2].items);
}

test "candidate sweep releases partially transferred rows on allocation failure" {
    const Exercise = struct {
        fn run(allocator: Allocator) !void {
            const boxes = [_]Bounds{ .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 3, .y = 3 } }, .{ .min = .{ .x = 1, .y = 1 }, .max = .{ .x = 4, .y = 4 } }, .{ .min = .{ .x = 2, .y = 2 }, .max = .{ .x = 5, .y = 5 } }, .{ .min = .{ .x = 8, .y = 8 }, .max = .{ .x = 9, .y = 9 } } };
            const result = try boundsCandidates(allocator, &boxes, &boxes, 1e-12, false);
            defer deinitCandidates(allocator, result);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}
