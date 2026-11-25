//! Tests of compound and subpaths across allocation failure.
const std = @import("std");
const typst = @import("libtypst");
const types = @import("../types.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const builtin_calls = @import("builtin_calls.zig");
const conversions = @import("conversions.zig");
const sequence = conversions.sequence;

fn compoundAllocationExercise(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const start: Value = .{ .vec2 = .{ .x = -5, .y = 2 } };
    const end: Value = .{ .vec2 = .{ .x = 5, .y = 7 } };
    const open = try builtin_calls.invoke(&runtime, a, .path, &.{ start, end });
    const closed = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ start, .{ .number = 5 }, .{ .number = 8 } });
    const combined = try builtin_calls.invoke(&runtime, a, .compound, &.{types.listView(&.{ open, closed, open })});
    const segments = (try runtime.path(combined)).segments.items;
    const open_segments = (try runtime.path(open)).segments.items;
    const closed_segments = (try runtime.path(closed)).segments.items;
    try std.testing.expectEqualDeep(open_segments, segments[0..open_segments.len]);
    try std.testing.expectEqualDeep(closed_segments, segments[open_segments.len .. open_segments.len + closed_segments.len]);
    try std.testing.expectEqualDeep(open_segments, segments[open_segments.len + closed_segments.len ..]);
    const empty = try builtin_calls.invoke(&runtime, a, .compound, &.{types.listView(&.{})});
    try std.testing.expectEqual(@as(usize, 0), (try runtime.path(empty)).segments.items.len);
    const invalid = builtin_calls.invoke(&runtime, a, .compound, &.{types.listView(&.{ open, .{ .int = 1 } })}) catch |err|
        if (err == error.OutOfMemory) return err else err;
    try std.testing.expectError(error.TypeMismatch, invalid);
    try std.testing.expectEqualStrings("compound requires path elements", runtime.native_message);
}

fn subpathsAllocationExercise(a: std.mem.Allocator) !void {
    var outputs: std.heap.ArenaAllocator = .init(a);
    defer outputs.deinit();
    const out = outputs.allocator();
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const open = try builtin_calls.invoke(&runtime, out, .bezier, &.{
        .{ .vec2 = .zero },
        .{ .vec2 = .{ .x = 0, .y = 2 } },
        .{ .vec2 = .{ .x = 2, .y = 2 } },
        .{ .vec2 = .{ .x = 2, .y = 0 } },
    });
    const closed = try builtin_calls.invoke(&runtime, out, .rectangle, &.{ .{ .vec2 = .zero }, .{ .number = 5 }, .{ .number = 8 } });
    const combined = try builtin_calls.invoke(&runtime, out, .compound, &.{types.listView(&.{ open, closed, open })});
    const parts = try sequence(try builtin_calls.invoke(&runtime, out, .subpaths, &.{combined}));
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    for (parts, [_]Value{ open, closed, open }) |part, source| {
        const actual = try runtime.path(part);
        const expected = try runtime.path(source);
        try std.testing.expectEqualDeep(expected.segments.items, actual.segments.items);
        try std.testing.expectEqual(expected.open, actual.open);
        try std.testing.expect(actual.segments.items.ptr != expected.segments.items.ptr);
    }
    try std.testing.expect((try runtime.path(parts[0])).segments.items.ptr != (try runtime.path(parts[2])).segments.items.ptr);
    const joined = try builtin_calls.invoke(&runtime, out, .compound, &.{types.listView(parts)});
    try std.testing.expectEqualDeep((try runtime.path(combined)).segments.items, (try runtime.path(joined)).segments.items);
    const empty = try builtin_calls.invoke(&runtime, out, .compound, &.{types.listView(&.{})});
    try std.testing.expectEqual(@as(usize, 0), (try sequence(try builtin_calls.invoke(&runtime, out, .subpaths, &.{empty}))).len);
    try std.testing.expectError(error.TypeMismatch, builtin_calls.invoke(&runtime, out, .subpaths, &.{.{ .int = 1 }}));
    try std.testing.expect(runtime.engine == null);
}

test "compound preserves ordered subpaths and cleans up each allocation failure" {
    try compoundAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), compoundAllocationExercise, .{});
}

test "subpaths transfers independent paths and caller lists safely across allocation failures" {
    try subpathsAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), subpathsAllocationExercise, .{});
}
