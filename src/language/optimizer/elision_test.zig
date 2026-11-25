//! Tests of literal-append elision.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Value = bc.Value;
const Instruction = bc.Instruction;
const optimizer = @import("../optimizer.zig");

test "literal append elision combines one operation with both spans and nested construction" {
    for ([_]u32{ 0, 1, 3 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var pool = std.array_list.Managed(Value).init(arena.allocator());
        try pool.append(.{ .int = 7 });
        var code = std.array_list.Managed(Instruction).init(arena.allocator());
        try code.append(.{ .op = .load_global });
        for (0..count) |_| try code.append(.{ .op = .constant });
        const prepare_span: bc.Span = .{ .start = 5, .end = 10 };
        const append_span: bc.Span = .{ .start = 1, .end = 10 };
        try code.appendSlice(&.{ .{ .op = .make_list, .a = count, .span = prepare_span }, .{ .op = .list_append, .span = append_span }, .{ .op = .halt } });
        const result = try optimizer.optimize(arena.allocator(), code.items, &pool, .{ .global_types = &.{.list} });
        try std.testing.expectEqual(code.items.len - 1, result.len);
        const append = result[result.len - 2];
        try std.testing.expectEqual(bc.Op.list_append_items, append.op);
        try std.testing.expectEqual(count, append.a);
        try std.testing.expectEqual(prepare_span.start, append.b);
        try std.testing.expectEqualDeep(append_span, append.span);
        try std.testing.expectEqualDeep(Instruction.StackEffect{ .consumed = @as(usize, count) + 1, .produced = 0 }, append.stackEffect());
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    try pool.append(.{ .int = 7 });
    const nested = [_]Instruction{ .{ .op = .load_global }, .{ .op = .constant }, .{ .op = .make_list, .a = 1 }, .{ .op = .make_list, .a = 1 }, .{ .op = .list_append }, .{ .op = .halt } };
    const result = try optimizer.optimize(arena.allocator(), &nested, &pool, .{ .global_types = &.{.list} });
    try std.testing.expectEqual(bc.Op.make_list, result[2].op);
    try std.testing.expectEqual(bc.Op.list_append_items, result[3].op);
}

test "literal append elision retains original code when both spans cannot be represented" {
    const wide = std.math.add(usize, std.math.maxInt(u32), 1) catch return;
    for ([_]bc.Span{ .{ .start = 5, .end = 9 }, .{ .start = wide, .end = wide + 5 } }) |rhs| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var pool = std.array_list.Managed(Value).init(arena.allocator());
        const code = [_]Instruction{
            .{ .op = .load_global },                                                                         .{ .op = .make_list, .span = rhs },
            .{ .op = .list_append, .span = .{ .start = 1, .end = if (rhs.start == wide) rhs.end else 10 } }, .{ .op = .halt },
        };
        try std.testing.expectEqualDeep(&code, try optimizer.optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{.list} }));
    }
}

test "literal append elision remaps forward branches and loop back edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    const code = [_]Instruction{
        .{ .op = .load_global, .a = 1 }, .{ .op = .jump_if_false, .a = 6 },
        .{ .op = .load_global },         .{ .op = .make_list },
        .{ .op = .list_append },         .{ .op = .jump, .a = 0 },
        .{ .op = .halt },
    };
    const result = try optimizer.optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{ .list, .boolean } });
    try std.testing.expectEqual(@as(usize, code.len - 1), result.len);
    try std.testing.expectEqual(@as(u32, 5), result[1].a);
    try std.testing.expectEqual(bc.Op.list_append_items, result[3].op);
    try std.testing.expectEqual(bc.Op.jump, result[4].op);
    try std.testing.expectEqual(@as(u32, 0), result[4].a);
}

test "literal append elision does not cross an incoming branch to append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    const code = [_]Instruction{
        .{ .op = .load_global, .a = 0 },   .{ .op = .load_global, .a = 1 }, .{ .op = .load_global, .a = 2 },
        .{ .op = .jump_if_false, .a = 5 }, .{ .op = .make_list, .a = 1 },   .{ .op = .list_append },
        .{ .op = .halt },
    };
    const result = try optimizer.optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{ .list, .any, .boolean } });
    try std.testing.expectEqual(bc.Op.make_list, result[4].op);
    try std.testing.expectEqual(bc.Op.list_append, result[5].op);
}
