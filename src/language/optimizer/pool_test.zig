//! Tests of the shared constant-pool index and pool compaction.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Value = bc.Value;
const types = @import("../types.zig");
const Instruction = bc.Instruction;
const Allocator = std.mem.Allocator;
const immutable = @import("value.zig");
const keyOf = immutable.keyOf;
const scalarValid = immutable.scalarValid;
const optimizer = @import("../optimizer.zig");

test "constant pool compaction merges exact values and preserves signed zero and identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pool: std.ArrayList(Value) = .empty;
    const template = types.listView(&.{.{ .int = 1 }});
    try pool.appendSlice(a, &.{ .{ .int = 42 }, .{ .int = 42 }, .{ .number = 0 }, .{ .number = -0.0 }, .{ .string = "field" }, .{ .string = "field" }, template, template, .{ .int = 999 } });
    const code = [_]Instruction{
        .{ .op = .constant, .a = 0 }, .{ .op = .constant, .a = 1 }, .{ .op = .constant, .a = 2 }, .{ .op = .constant, .a = 3 },
        .{ .op = .field, .a = 4 },    .{ .op = .typst, .a = 5 },    .{ .op = .constant, .a = 6 }, .{ .op = .constant, .a = 7 },
        .{ .op = .halt },
    };
    var functions = [_]bc.Function{.{ .name = "test", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try optimizer.compactConstants(a, &functions, &pool);
    try std.testing.expectEqual(@as(usize, 6), pool.items.len);
    const rewritten = functions[0].code;
    try std.testing.expectEqual(rewritten[0].a, rewritten[1].a);
    try std.testing.expect(rewritten[2].a != rewritten[3].a);
    try std.testing.expectEqual(rewritten[4].a, rewritten[5].a);
    try std.testing.expect(rewritten[6].a != rewritten[7].a);
}

fn allocationCase(allocator: Allocator) !void {
    var pool: std.ArrayList(Value) = .empty;
    defer pool.deinit(allocator);
    try pool.appendSlice(allocator, &.{ .{ .int = 2 }, .{ .int = 3 }, .{ .boolean = true } });
    const input = [_]Instruction{
        .{ .op = .constant, .a = 2 }, .{ .op = .jump_if_false, .a = 7 },
        .{ .op = .constant },         .{ .op = .constant, .a = 1 },
        .{ .op = .add },              .{ .op = .store_global },
        .{ .op = .jump, .a = 7 },     .{ .op = .halt },
    };
    const output = try optimizer.optimize(allocator, &input, &pool, .{});
    defer allocator.free(output);
    var functions = [_]bc.Function{.{ .name = "test", .code = output, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try optimizer.compactConstants(allocator, &functions, &pool);
    if (functions[0].code.ptr != output.ptr) allocator.free(functions[0].code);
}

test "all optimizer and pool-compaction allocation failures release temporary storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "pool compaction remaps field writes and never interns mutable aggregate or omitted constants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dictionary: types.Dict = .{};
    var fields = [_]Value{.{ .int = 1 }};
    var record: types.Record = .{ .kind = bc.Type.record(0), .fields = &fields };
    var pool: std.ArrayList(Value) = .empty;
    try pool.appendSlice(a, &.{
        .{ .int = 999 },          .{ .string = "count" },   .{ .string = "count" },
        .{ .dict = &dictionary }, .{ .dict = &dictionary }, .{ .record = &record },
        .{ .record = &record },   .omitted,                 .omitted,
    });
    const code = [_]Instruction{
        .{ .op = .field, .a = 1, .b = 1 }, .{ .op = .set_field, .a = 2, .b = 1 },
        .{ .op = .constant, .a = 3 },      .{ .op = .constant, .a = 4 },
        .{ .op = .constant, .a = 5 },      .{ .op = .constant, .a = 6 },
        .{ .op = .constant, .a = 7 },      .{ .op = .constant, .a = 8 },
        .{ .op = .halt },
    };
    var functions = [_]bc.Function{.{ .name = "test", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try optimizer.compactConstants(a, &functions, &pool);
    try std.testing.expectEqual(@as(usize, 7), pool.items.len);
    const rewritten = functions[0].code;
    try std.testing.expectEqual(@as(u32, 0), rewritten[1].a);
    try std.testing.expectEqual(rewritten[0].a, rewritten[1].a);
    try std.testing.expectEqual(@as(u32, 1), rewritten[1].b);
    for ([_]usize{ 2, 4, 6 }) |index| try std.testing.expect(rewritten[index].a != rewritten[index + 1].a);
    try std.testing.expect(keyOf(.{ .dict = &dictionary }) == null);
    try std.testing.expect(keyOf(.{ .record = &record }) == null);
    try std.testing.expect(!scalarValid(.omitted));
}

test "shared pool index preserves standalone folding through append growth and propagation" {
    const t = std.testing;
    var actual: std.ArrayList(Value) = .empty;
    defer actual.deinit(t.allocator);
    var expected: std.ArrayList(Value) = .empty;
    defer expected.deinit(t.allocator);
    const template = types.listView(&.{.{ .int = 7 }});
    const initial = [_]Value{
        .{ .int = 2 },      .{ .int = 3 },      .{ .int = 2 }, .{ .number = 0 }, .{ .number = -0.0 },
        .{ .string = "x" }, .{ .string = "x" }, template,      template,         .omitted,
    };
    try actual.appendSlice(t.allocator, &initial);
    try expected.appendSlice(t.allocator, &initial);
    var index = optimizer.PoolIndex.init(t.allocator);
    defer index.deinit();
    const cases = [_][]const Instruction{
        &.{ .{ .op = .constant, .a = 2 }, .{ .op = .constant, .a = 1 }, .{ .op = .add }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 1 }, .{ .op = .store_global }, .{ .op = .load_global }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 3 }, .{ .op = .constant, .a = 4 }, .{ .op = .subtract }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 6 }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 7 }, .{ .op = .constant, .a = 8 }, .{ .op = .constant, .a = 9 }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 0 }, .{ .op = .constant, .a = 3 }, .{ .op = .divide, .span = .{ .start = 10, .end = 12 } }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 999 }, .{ .op = .halt } },
    };
    for (cases, 0..) |code, round| {
        const standalone = try optimizer.optimize(t.allocator, code, &expected, .{ .global_types = &.{.int} });
        defer t.allocator.free(standalone);
        const shared = try optimizer.optimize(t.allocator, code, &actual, .{ .global_types = &.{.int}, .pool_index = &index });
        defer t.allocator.free(shared);
        try t.expect(optimizer.sameCode(standalone, shared));
        try t.expectEqualDeep(expected.items, actual.items);
        // Force append/reallocation independently of the optimizer. Duplicate
        // values must keep their earliest index across function boundaries.
        const extra: Value = .{ .int = @intCast(round) };
        try actual.appendSlice(t.allocator, &.{ extra, extra });
        try expected.appendSlice(t.allocator, &.{ extra, extra });
    }
    try index.sync(actual.items);
    try t.expectEqual(@as(u32, 0), index.map.get(keyOf(.{ .int = 2 }).?).?);
    try t.expect(index.map.get(keyOf(.{ .number = 0 }).?).? != index.map.get(keyOf(.{ .number = -0.0 }).?).?);
    try t.expectEqual(@as(u32, 5), index.map.get(keyOf(.{ .string = "x" }).?).?);
}

fn sharedAllocationCase(allocator: Allocator) !void {
    var constants: std.ArrayList(Value) = .empty;
    defer constants.deinit(allocator);
    try constants.appendSlice(allocator, &.{ .{ .int = 2 }, .{ .int = 3 } });
    var index = optimizer.PoolIndex.init(allocator);
    defer index.deinit();
    const code = [_]Instruction{
        .{ .op = .constant },     .{ .op = .constant, .a = 1 }, .{ .op = .add },
        .{ .op = .store_global }, .{ .op = .load_global },      .{ .op = .store_global },
        .{ .op = .halt },
    };
    for (0..3) |_| {
        const output = try optimizer.optimize(allocator, &code, &constants, .{ .global_types = &.{.int}, .pool_index = &index });
        defer allocator.free(output);
        try std.testing.expectEqual(@as(i64, 5), constants.items[output[0].a].int);
        try constants.append(allocator, .{ .int = 5 });
    }
}

test "shared pool index releases all partial allocations" {
    try sharedAllocationCase(std.testing.allocator);
    // Force growth to allocate consistently instead of depending on whether
    // the backing allocator can extend a particular block in place.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), sharedAllocationCase, .{});
}

test "pool index can retry after partial synchronization or failed insertion" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var index = optimizer.PoolIndex.init(failing.allocator());
    defer index.deinit();
    var pool: std.ArrayList(Value) = .empty;
    defer pool.deinit(t.allocator);
    for (0..100) |value| try pool.append(t.allocator, .{ .int = @intCast(value) });
    try t.expectError(error.OutOfMemory, index.sync(pool.items));
    try t.expect(index.indexed_count > 0 and index.indexed_count < pool.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try index.sync(pool.items);
    try t.expectEqual(pool.items.len, index.indexed_count);
    for (pool.items, 0..) |value, expected| try t.expectEqual(@as(u32, @intCast(expected)), index.map.get(keyOf(value).?).?);

    var failed_pool: std.ArrayList(Value) = .empty;
    defer failed_pool.deinit(failing.allocator());
    var empty_index = optimizer.PoolIndex.init(t.allocator);
    defer empty_index.deinit();
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, empty_index.intern(failing.allocator(), &failed_pool, .{ .int = 9 }));
    try t.expectEqual(@as(usize, 0), failed_pool.items.len);
    try t.expectEqual(@as(usize, 0), empty_index.indexed_count);
    try t.expectEqual(@as(u32, 0), empty_index.map.count());
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqual(@as(u32, 0), try empty_index.intern(failing.allocator(), &failed_pool, .{ .int = 9 }));
    try t.expectEqual(@as(usize, 1), empty_index.indexed_count);
}
