//! Tests of the style pool: shared values and float bits across allocation failure, patch arrays shared through one store, threads, and unique edits.
const std = @import("std");
const builtin = @import("builtin");
const g = @import("../geometry.zig");
const Motion = @import("../pen/Motion.zig");
const drawing_style = @import("../style.zig");
const Pool = @import("Pool.zig");
const Color = drawing_style.Color;
const Style = drawing_style.Style;
const ValueContext = Pool.ValueContext;
const Gradient = drawing_style.Gradient;

fn poolExercise(allocator: std.mem.Allocator) !void {
    var pool = Pool.init(allocator);
    defer pool.deinit();
    var dash = [_]f64{ 1, 2 };
    var vertices = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    var colors = [_]Color{ .black, .{ .r = 1 } };
    var style: Style = .{ .fill = .{ .gradient = &.{ .radial = .{ .start = .zero, .end = .{ .x = 1, .y = 0 }, .colors = &colors } } }, .pen = .{ .dash = &dash, .nib = .{ .polygon = &vertices } } };
    const saved = try pool.intern(&style);
    try std.testing.expect(saved == try pool.intern(&style));
    var other = Pool.init(allocator);
    defer other.deinit();
    const independent = try other.intern(saved);
    try std.testing.expect(saved != independent);
    try std.testing.expect(ValueContext.eql(.{}, saved, independent));
    try std.testing.expect(saved == try pool.intern(independent));
    dash[0] = 3;
    vertices[0].x = -1;
    colors[0].r = 0.5;
    try std.testing.expectEqual(Color.black, saved.gradientFor(.fill).?.radial.colors[0]);
    try std.testing.expectEqual(@as(f64, 1), saved.pen.?.dash[0]);
    try std.testing.expectEqual(@as(f64, 0), saved.pen.?.nib.?.polygon[0].x);
    try std.testing.expect(saved != try pool.intern(&style));
    var offsets = [_]f64{ 0, 1 };
    const placed: Style = .{ .fill = .{ .gradient = &.{ .linear = .{ .start = .zero, .end = .{ .x = 1, .y = 0 }, .colors = &colors, .offsets = &offsets } } } };
    const stored_placed = try pool.intern(&placed);
    try std.testing.expect(stored_placed == try pool.intern(&placed));
    offsets[1] = 0.5;
    try std.testing.expectEqual(@as(f64, 1), stored_placed.gradientFor(.fill).?.linear.offsets[1]);
    try std.testing.expect(stored_placed != try pool.intern(&placed));
    for (0..20) |index| {
        style.pen.?.width = @floatFromInt(index);
        const stored = try pool.intern(&style);
        try std.testing.expect(ValueContext.eql(.{}, &style, stored));
        try std.testing.expectEqual(ValueContext.hash(.{}, &style), ValueContext.hash(.{}, stored));
    }
    style = saved.*;
    style.pen.?.dash_phase = -0.0;
    try std.testing.expect(saved != try pool.intern(&style));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast((try pool.intern(&style)).pen.?.dash_phase)));

    var keys = [_]Motion.Key{ .{ .t = 0, .value = 2 }, .{ .t = 0.5, .value = 14 }, .{ .t = 1, .value = 2 } };
    const pressure: Style = .{ .pen = .{ .motion = &.{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 3 }}, .keys = &keys } } };
    const first_profile = try pool.intern(&pressure);
    try std.testing.expect(first_profile.pen.?.motion.? != pressure.pen.?.motion.?);
    try std.testing.expect(first_profile == try pool.intern(&pressure));
    keys[1].value = 8;
    try std.testing.expect(first_profile != try pool.intern(&pressure));
    try std.testing.expectEqual(@as(f64, 14), first_profile.pen.?.motion.?.keys[1].value);

    var patch_points = test_patches.points;
    var patch_values = test_patches.values;
    var levels = [_]f64{ 0, 1 };
    const patch_style: Style = .{ .fill = .{ .gradient = &.{ .patches = .{ .points = &patch_points, .values = &patch_values, .stops = .{ .levels = &levels, .colors = &test_patches.colors }, .tolerance = 0.01 } } } };
    const patch = try pool.intern(&patch_style);
    try std.testing.expect(patch == try pool.intern(&patch_style));
    patch_points[0][0].x = -1;
    patch_values[0][15] = 2;
    levels[1] = 3;
    try std.testing.expectEqual(@as(f64, 0), patch.gradientFor(.fill).?.patches.points[0][0].x);
    try std.testing.expectEqual(@as(f64, 1), patch.gradientFor(.fill).?.patches.values[0][15]);
    try std.testing.expectEqual(@as(f64, 1), patch.gradientFor(.fill).?.patches.stops.levels[1]);
    try std.testing.expect(patch != try pool.intern(&patch_style));

    var fan_points = [_]g.Point{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = -1, .y = 0 } };
    var fan_values = [_]f64{ 0, 0.5, 1 };
    const fan_style: Style = .{ .fill = .{ .gradient = &.{ .fan = .{ .center = .zero, .points = &fan_points, .values = &fan_values, .stops = .{ .levels = &.{ 0, 1 }, .colors = &test_patches.colors }, .tolerance = 0.01 } } } };
    const fan = try pool.intern(&fan_style);
    try std.testing.expect(fan == try pool.intern(&fan_style));
    fan_points[0].x = 2;
    fan_values[2] = 3;
    try std.testing.expectEqual(@as(f64, 1), fan.gradientFor(.fill).?.fan.points[0].x);
    try std.testing.expectEqual(@as(f64, 1), fan.gradientFor(.fill).?.fan.values[2]);
    try std.testing.expect(fan != try pool.intern(&fan_style));
}

test "immutable styles share equal values own slices and preserve float bits across OOM" {
    try poolExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, poolExercise, .{});
}

/// One flat patch over the unit square whose field rises along u.
const test_patches = struct {
    pub const points: [1][16]g.Point = grid: {
        var result: [1][16]g.Point = undefined;
        for (0..4) |i| for (0..4) |j| {
            result[0][i * 4 + j] = .{ .x = @as(f64, @floatFromInt(i)) / 3, .y = @as(f64, @floatFromInt(j)) / 3 };
        };
        break :grid result;
    };
    pub const values: [1][16]f64 = field: {
        var result: [1][16]f64 = undefined;
        for (0..4) |i| for (0..4) |j| {
            result[0][i * 4 + j] = @as(f64, @floatFromInt(i)) / 3;
        };
        break :field result;
    };
    pub const colors = [_]Color{ .{ .r = 1 }, .{ .b = 1, .a = 0.5 } };
    const style: Style = .{ .fill = .{ .gradient = &.{ .patches = .{ .points = &points, .values = &values, .stops = .{ .levels = &.{ 0, 1 }, .colors = &colors }, .tolerance = 0.01 } } } };
};

test "pools attached to one store share patch arrays and other pools copy them" {
    const t = std.testing;
    var store = Gradient.Store.init(t.allocator);
    defer store.deinit();
    var second = Pool.initWithMeshes(t.allocator, &store);
    defer second.deinit();
    var first = Pool.initWithMeshes(t.allocator, &store);
    var first_alive = true;
    defer if (first_alive) first.deinit();
    const original = try first.intern(&test_patches.style);
    const patches = original.gradientFor(.fill).?.patches;
    try t.expect(patches.points.ptr != &test_patches.points);
    try t.expectEqual(@as(usize, 1), store.count());
    try t.expectEqual(ValueContext.hash(.{}, &test_patches.style), ValueContext.hash(.{}, original));

    const copied = try second.intern(original);
    const shared = copied.gradientFor(.fill).?.patches;
    try t.expect(shared.shared.? == patches.shared.?);
    try t.expectEqual(patches.points.ptr, shared.points.ptr);
    try t.expectEqual(@as(usize, 2), shared.shared.?.referenceCount());
    try t.expectEqual(@as(usize, 1), store.count());
    first.deinit();
    first_alive = false;
    try t.expectEqual(@as(usize, 1), shared.shared.?.referenceCount());
    try t.expectEqual(@as(f64, 0.5), shared.stops.colors[1].a);

    // A pool without the store, or attached to another one, copies.
    var local = Pool.init(t.allocator);
    defer local.deinit();
    const independent = try local.intern(copied);
    try t.expect(independent.gradientFor(.fill).?.patches.shared.? != shared.shared.?);
    try t.expect(independent.gradientFor(.fill).?.patches.points.ptr != shared.points.ptr);
    try t.expect(ValueContext.eql(.{}, independent, copied));
    var other_store = Gradient.Store.init(t.allocator);
    defer other_store.deinit();
    var other = Pool.initWithMeshes(t.allocator, &other_store);
    defer other.deinit();
    const foreign = try other.intern(copied);
    try t.expect(foreign.gradientFor(.fill).?.patches.shared.? != shared.shared.?);
    try t.expectEqual(@as(usize, 1), other_store.count());
    try t.expectEqual(@as(usize, 1), shared.shared.?.referenceCount());
}

fn storeExercise(allocator: std.mem.Allocator) !void {
    var store = Gradient.Store.init(allocator);
    defer store.deinit();
    var first = Pool.initWithMeshes(allocator, &store);
    defer first.deinit();
    var second = Pool.initWithMeshes(allocator, &store);
    defer second.deinit();
    const original = try first.intern(&test_patches.style);
    _ = try second.intern(original);
}

test "store-attached pools release every partial patch copy on allocation failure" {
    try storeExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, storeExercise, .{});
}

test "pools on several threads share and create patch arrays through one store" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var store = Gradient.Store.init(std.testing.allocator);
    defer store.deinit();
    var owner = Pool.initWithMeshes(std.testing.allocator, &store);
    defer owner.deinit();
    const original = try owner.intern(&test_patches.style);
    const worker = struct {
        fn run(meshes: *Gradient.Store, source: *const Style) !void {
            var own = test_patches.values;
            own[0][0] = 0.25;
            for (0..200) |_| {
                var pool = Pool.initWithMeshes(std.testing.allocator, meshes);
                defer pool.deinit();
                const copy = try pool.intern(source);
                if (copy.gradientFor(.fill).?.patches.points.ptr != source.gradientFor(.fill).?.patches.points.ptr) return error.NotShared;
                // New arrays are created and released through the store too.
                _ = try pool.intern(&.{ .fill = .{ .gradient = &.{ .patches = .{ .points = &test_patches.points, .values = &own, .stops = .{ .levels = &.{ 0, 1 }, .colors = &test_patches.colors }, .tolerance = 0.01 } } } });
            }
        }
        fn spawn(meshes: *Gradient.Store, source: *const Style, failed: *std.atomic.Value(bool)) void {
            run(meshes, source) catch failed.store(true, .release);
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    {
        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |thread| thread.join();
        while (spawned < threads.len) : (spawned += 1) threads[spawned] = try std.Thread.spawn(.{}, worker.spawn, .{ &store, original, &failed });
    }
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), original.gradientFor(.fill).?.patches.shared.?.referenceCount());
    try std.testing.expectEqual(@as(usize, 1), store.count());
}

test "unique style edits do not retain history or allocate new entries" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var pool = Pool.init(failing.allocator());
    defer pool.deinit();
    var value = try pool.intern(&.{ .fill = .black });
    failing.fail_index = failing.alloc_index;
    const bytes = pool.allocatedBytes();
    for (1..10001) |i| {
        value = try pool.replace(value, &.{ .fill = .{ .color = .{ .r = @as(f64, @floatFromInt(i)) / 10001 } } });
        try t.expectEqual(@as(u32, 1), pool.entries.count());
        try t.expectEqual(bytes, pool.allocatedBytes());
    }
    pool.release(value);
}
