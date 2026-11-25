//! Tests of propagation limits, malformed bytecode and allocation failure.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Allocator = std.mem.Allocator;
const t = std.testing;
const propagation = @import("propagation.zig");
const testing = @import("testing.zig");

test "propagation malformed bytecode and proof limits leave the pool untouched" {
    var constants = try testing.pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    const bad = [_][]const bc.Instruction{
        &.{ testing.ins(.jump, 999), testing.ins(.halt, 0) },
        &.{ testing.ins(.constant, 999), testing.ins(.halt, 0) },
        &.{ testing.ins(.load_global, 999), testing.ins(.halt, 0) },
        &.{ testing.ins(.add, 0), testing.ins(.halt, 0) },
        // Diverging stack depth at a reachable join.
        &.{ testing.ins(.load_global, 0), testing.ins(.jump_if_false, 4), testing.ins(.constant, 0), testing.ins(.jump, 4), testing.ins(.halt, 0) },
    };
    for (bad) |code| try t.expect((try propagation.rewrite(t.allocator, code, &constants, .{ .global_types = &.{.boolean} })) == null);
    const long = try t.allocator.alloc(bc.Instruction, propagation.limits.instructions + 1);
    defer t.allocator.free(long);
    @memset(long, testing.ins(.halt, 0));
    try t.expect((try propagation.rewrite(t.allocator, long, &constants, .{})) == null);
    const many = try t.allocator.alloc(bc.Type, propagation.limits.bindings + 1);
    defer t.allocator.free(many);
    @memset(many, .any);
    try t.expect((try propagation.rewrite(t.allocator, &.{testing.ins(.halt, 0)}, &constants, .{ .global_types = many })) == null);
    try t.expectEqual(@as(usize, 1), constants.items.len);
}

fn allocationExercise(a: Allocator) !void {
    var constants = try testing.pool(a, &.{.{ .int = 7 }});
    defer constants.deinit();
    const code = [_]bc.Instruction{ testing.ins(.constant, 0), testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.store_global, 1), testing.ins(.halt, 0) };
    const result = (try propagation.rewrite(a, &code, &constants, .{ .global_types = &.{ .int, .int } })).?;
    defer a.free(result);
    try testing.expectInt(result, constants.items, 2, 7);
}

test "propagation releases all allocations including partial pool rewrites" {
    try allocationExercise(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

fn argumentAllocationExercise(a: Allocator) !void {
    var constants = try testing.pool(a, &.{ .{ .int = 7 }, .{ .int = 11 } });
    defer constants.deinit();
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0),     testing.ins(.constant, 1),     .{ .op = .bind_arguments, .a = 0, .b = 2 },
        testing.ins(.store_global, 0), testing.ins(.store_global, 1), testing.ins(.load_global, 0),
        testing.ins(.store_global, 2), testing.ins(.load_global, 1),  testing.ins(.store_global, 3),
        testing.ins(.halt, 0),
    };
    const result = (try propagation.rewrite(a, &code, &constants, .{
        .global_types = &.{ .int, .int, .int, .int },
        .argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }},
    })).?;
    defer a.free(result);
    try testing.expectInt(result, constants.items, 5, 7);
    try testing.expectInt(result, constants.items, 7, 11);
    try t.expectEqualDeep(code[2], result[2]);
}

test "argument permutations preserve evaluated facts and release every failed allocation" {
    try argumentAllocationExercise(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, argumentAllocationExercise, .{});
}

test "invalid argument descriptors leave propagation and the constant pool unchanged" {
    var constants = try testing.pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    const code = [_]bc.Instruction{ testing.ins(.constant, 0), testing.ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 2 }, testing.ins(.halt, 0) };
    for ([_]bc.ArgumentBinding{
        .{ .slots = &.{ 0, 0 }, .parameter_count = 2 },
        .{ .slots = &.{ 0, 2 }, .parameter_count = 2 },
        .{ .slots = &.{0}, .parameter_count = 2 },
        .{ .slots = &.{ 0, 1 }, .parameter_count = 3 },
    }) |binding| {
        try t.expect((try propagation.rewrite(t.allocator, &code, &constants, .{ .argument_bindings = &.{binding} })) == null);
        try t.expectEqual(@as(usize, 1), constants.items.len);
    }
    try t.expect((try propagation.rewrite(t.allocator, &code, &constants, .{})) == null);
}
