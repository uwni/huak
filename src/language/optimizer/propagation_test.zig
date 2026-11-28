//! Tests of what constant propagation proves across branches, joins, loops and host barriers.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Allocator = std.mem.Allocator;
const Value = bc.Value;
const t = std.testing;
const propagation = @import("propagation.zig");
const testing = @import("testing.zig");

test "propagation follows known branch edges through arithmetic and local stores" {
    var constants = try testing.pool(t.allocator, &.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 5 } });
    defer constants.deinit(t.allocator);
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0),     testing.ins(.store_global, 0),   testing.ins(.load_global, 0),  testing.ins(.constant, 1),
        testing.ins(.add, 0),          testing.ins(.store_local, 0),    testing.ins(.load_local, 0),   testing.ins(.constant, 2),
        testing.ins(.equal, 0),        testing.ins(.jump_if_false, 13), testing.ins(.constant, 0),     testing.ins(.store_global, 1),
        testing.ins(.jump, 15),        testing.ins(.constant, 1),       testing.ins(.store_global, 1), testing.ins(.load_global, 1),
        testing.ins(.store_global, 2), testing.ins(.halt, 0),
    };
    const result = (try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .int, .int, .int }, .local_types = &.{.int} })).?;
    defer t.allocator.free(result);
    try testing.expectInt(result, constants.items, 2, 2);
    try testing.expectInt(result, constants.items, 6, 5);
    try testing.expectInt(result, constants.items, 15, 2);
    for (code, result) |before, after| if (before.op == .store_global or before.op == .store_local) {
        try t.expectEqualDeep(before, after);
    };
}

test "propagation joins all executable predecessors and preserves signed zero" {
    const code = [_]bc.Instruction{
        testing.ins(.load_global, 0),  testing.ins(.jump_if_false, 5), testing.ins(.constant, 0),     testing.ins(.store_global, 1),
        testing.ins(.jump, 7),         testing.ins(.constant, 1),      testing.ins(.store_global, 1), testing.ins(.load_global, 1),
        testing.ins(.store_global, 2), testing.ins(.halt, 0),
    };
    for ([_]bool{ false, true }) |equal| {
        var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = if (equal) 7 else 8 } });
        defer constants.deinit(t.allocator);
        const result = try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .boolean, .int, .int } });
        defer if (result) |output| t.allocator.free(output);
        if (equal) {
            try testing.expectInt(result.?, constants.items, 7, 7);
        } else try t.expect(result == null);
    }
    var zeros = try testing.pool(t.allocator, &.{ .{ .number = -0.0 }, .{ .number = 0.0 } });
    defer zeros.deinit(t.allocator);
    try t.expect((try propagation.rewrite(t.allocator, &code, t.allocator, &zeros, .{ .global_types = &.{ .boolean, .number, .number } })) == null);

    // One predecessor reaches the read without assigning result at all.
    const uninitialized = [_]bc.Instruction{
        testing.ins(.load_global, 0), testing.ins(.jump_if_false, 4), testing.ins(.constant, 0), testing.ins(.store_global, 1),
        testing.ins(.load_global, 1), testing.ins(.store_global, 2),  testing.ins(.halt, 0),
    };
    var constants = try testing.pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit(t.allocator);
    try t.expect((try propagation.rewrite(t.allocator, &uninitialized, t.allocator, &constants, .{ .global_types = &.{ .boolean, .int, .int } })) == null);
}

test "propagation loop fixed points retain invariants and revoke induction facts" {
    var constants = try testing.pool(t.allocator, &.{ .{ .int = 9 }, .{ .int = 0 }, .{ .int = 3 }, .{ .int = 1 } });
    defer constants.deinit(t.allocator);
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0),    testing.ins(.store_global, 0), testing.ins(.constant, 1),   testing.ins(.store_local, 0),
        testing.ins(.load_local, 0),  testing.ins(.constant, 2),     testing.ins(.less, 0),       testing.ins(.jump_if_false, 15),
        testing.ins(.load_global, 0), testing.ins(.store_global, 1), testing.ins(.load_local, 0), testing.ins(.constant, 3),
        testing.ins(.add, 0),         testing.ins(.store_local, 0),  testing.ins(.jump, 4),       testing.ins(.halt, 0),
    };
    const result = (try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .int, .int }, .local_types = &.{.int} })).?;
    defer t.allocator.free(result);
    try t.expectEqual(bc.Op.load_local, result[4].op);
    try t.expectEqual(bc.Op.load_local, result[10].op);
    try testing.expectInt(result, constants.items, 8, 9);
    try t.expectEqualDeep(code[14], result[14]);
}

test "propagation call barriers forget bindings but retain evaluated operand values" {
    var constants = try testing.pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit(t.allocator);
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0),    testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.call, 0),
        testing.ins(.pop, 0),         testing.ins(.store_global, 1), testing.ins(.load_global, 0), testing.ins(.pop, 0),
        testing.ins(.load_global, 1), testing.ins(.store_global, 2), testing.ins(.halt, 0),
    };
    const result = (try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .int, .int, .int } })).?;
    defer t.allocator.free(result);
    try testing.expectInt(result, constants.items, 2, 7);
    try t.expectEqual(bc.Op.load_global, result[6].op);
    try testing.expectInt(result, constants.items, 8, 7);
    try t.expectEqualDeep(code[3], result[3]);
}

test "propagation unknown handle arithmetic is a host barrier but numeric arithmetic is not" {
    for ([_]bc.Op{ .add, .negate }) |operation| {
        for ([_]bc.Type{ .any, .variable, .int }) |kind| {
            var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = 1 } });
            defer constants.deinit(t.allocator);
            var code: std.ArrayList(bc.Instruction) = .empty;
            defer code.deinit(t.allocator);
            try code.appendSlice(t.allocator, &.{ testing.ins(.constant, 0), testing.ins(.store_global, 0), testing.ins(.load_global, 1) });
            if (operation == .add) try code.append(t.allocator, testing.ins(.constant, 1));
            try code.appendSlice(t.allocator, &.{ testing.ins(operation, 0), testing.ins(.pop, 0), testing.ins(.load_global, 0), testing.ins(.store_global, 2), testing.ins(.halt, 0) });
            const result = try propagation.rewrite(t.allocator, code.items, t.allocator, &constants, .{ .global_types = &.{ .int, kind, .int } });
            defer if (result) |output| t.allocator.free(output);
            if (kind == .int) {
                try testing.expectInt(result.?, constants.items, code.items.len - 3, 7);
            } else try t.expect(result == null);
        }
    }
}

test "propagation preserves a custom native arithmetic mutation after an earlier propagated load" {
    const Machine = @import("../Machine.zig");
    const Host = struct {
        machine: *Machine = undefined,
        calls: usize = 0,
        fn binary(context: ?*anyopaque, _: Allocator, _: bc.Op, _: Value, _: Value) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.machine.globals[0] = .{ .int = 11 };
            return .{ .int = 1 };
        }
    };
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0),    testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.pop, 0),
        testing.ins(.load_global, 1), testing.ins(.constant, 1),     testing.ins(.add, 0),         testing.ins(.pop, 0),
        testing.ins(.load_global, 0), testing.ins(.store_global, 2), testing.ins(.halt, 0),
    };
    var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = 1 } });
    defer constants.deinit(t.allocator);
    const result = (try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .int, .any, .int } })).?;
    defer t.allocator.free(result);
    try testing.expectInt(result, constants.items, 2, 7);
    try t.expectEqual(bc.Op.load_global, result[8].op);
    for ([_][]const bc.Instruction{ &code, result }) |instructions| {
        var program: bc.Program = .{
            .arena = .init(t.allocator),
            .source_text = "",
            .name = "native-propagation.huak",
            .functions = &.{.{ .name = "script", .code = instructions, .parameters = &.{}, .result = .unit, .local_types = &.{} }},
            .constants = constants.items,
            .parameters = &.{},
            .global_names = &.{ "initial", "dynamic", "result" },
            .global_types = &.{ .int, .any, .int },
            .readonly_globals = &.{ false, false, false },
        };
        defer program.deinit();
        var host: Host = .{};
        var machine = try Machine.init(t.allocator, &program, .{ .ptr = &host, .vtable = &.{ .binary = Host.binary } }, .{});
        defer machine.deinit();
        host.machine = &machine;
        machine.globals[1] = .{ .handle = .{ .kind = .variable, .index = 0 } };
        machine.initialized[1] = true;
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 1), host.calls);
        try t.expectEqual(@as(i64, 11), machine.getGlobal("result").?.int);
    }
}

test "propagation does not bypass store conversions or mutable identities" {
    var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .number = 7 }, bc.types.listView(&.{.{ .int = 1 }}), .{ .handle = .{ .kind = .picture, .index = 0 } } });
    defer constants.deinit(t.allocator);
    const code = [_]bc.Instruction{
        testing.ins(.constant, 0), testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.pop, 0),
        testing.ins(.constant, 1), testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.pop, 0),
        testing.ins(.constant, 0), testing.ins(.store_global, 1), testing.ins(.load_global, 1), testing.ins(.pop, 0),
        testing.ins(.constant, 2), testing.ins(.store_global, 2), testing.ins(.load_global, 2), testing.ins(.pop, 0),
        testing.ins(.constant, 3), testing.ins(.store_global, 3), testing.ins(.load_global, 3), testing.ins(.pop, 0),
        testing.ins(.halt, 0),
    };
    const result = (try propagation.rewrite(t.allocator, &code, t.allocator, &constants, .{ .global_types = &.{ .number, .length, .list, .picture } })).?;
    defer t.allocator.free(result);
    try t.expectEqual(bc.Op.load_global, result[2].op);
    try t.expectEqual(bc.Op.constant, result[6].op);
    try t.expectEqual(@as(f64, 7), constants.items[result[6].a].number);
    for ([_]usize{ 10, 14, 18 }) |index| try t.expectEqual(bc.Op.load_global, result[index].op);
}

test "propagation unknown fields imports and typography remain host barriers" {
    const barriers = [_]bc.Instruction{ testing.ins(.import_module, 0), testing.ins(.typst_module, 1), testing.ins(.typst, 1), testing.ins(.field, 1) };
    for (barriers) |barrier| {
        var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .string = "x" } });
        defer constants.deinit(t.allocator);
        var code: std.ArrayList(bc.Instruction) = .empty;
        defer code.deinit(t.allocator);
        try code.appendSlice(t.allocator, &.{ testing.ins(.constant, 0), testing.ins(.store_global, 0) });
        if (barrier.op == .field) try code.append(t.allocator, testing.ins(.constant, 0));
        try code.append(t.allocator, barrier);
        if (barrier.stackEffect().produced != 0) try code.append(t.allocator, testing.ins(.pop, 0));
        try code.appendSlice(t.allocator, &.{ testing.ins(.load_global, 0), testing.ins(.pop, 0), testing.ins(.halt, 0) });
        try t.expect((try propagation.rewrite(t.allocator, code.items, t.allocator, &constants, .{ .global_types = &.{.int} })) == null);
    }
}

test "aggregate writes stop binding propagation without replacing aggregate identities" {
    for ([_]bc.Op{ .set_index, .set_field }) |operation| {
        var constants = try testing.pool(t.allocator, &.{ .{ .int = 7 }, .{ .string = "field" } });
        defer constants.deinit(t.allocator);
        var code: std.ArrayList(bc.Instruction) = .empty;
        defer code.deinit(t.allocator);
        try code.appendSlice(t.allocator, &.{ testing.ins(.constant, 0), testing.ins(.store_global, 0), testing.ins(.load_global, 0), testing.ins(.pop, 0), testing.ins(.load_global, 1) });
        if (operation == .set_index) try code.append(t.allocator, testing.ins(.constant, 0));
        try code.appendSlice(t.allocator, &.{ testing.ins(.constant, 0), testing.ins(operation, 1), testing.ins(.load_global, 0), testing.ins(.pop, 0), testing.ins(.halt, 0) });
        const result = (try propagation.rewrite(t.allocator, code.items, t.allocator, &constants, .{ .global_types = &.{ .int, if (operation == .set_index) .dict else bc.Type.record(0) } })).?;
        defer t.allocator.free(result);
        try testing.expectInt(result, constants.items, 2, 7);
        try t.expectEqual(bc.Op.load_global, result[result.len - 3].op);
        try t.expectEqual(bc.Op.load_global, result[4].op);
    }
}
