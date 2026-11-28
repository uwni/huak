//! Tests of defaults, argument binding, variadic calls and checked arguments and returns.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Type = types.Type;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const operators = @import("operators.zig");
const aggregates = @import("aggregates.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;

test "aggregate VM default mixed graphs clone cycles and aliases freshly per call" {
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    try dict.entries.put(std.testing.allocator, "self", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "record", .{ .record = &record_value });
    const list_values = [_]Value{ .{ .dict = &dict }, .{ .record = &record_value } };
    try dict.entries.put(std.testing.allocator, "list", types.listView(&list_values));
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ .{ .op = .call, .a = 1 }, ins(.store_global, 0), .{ .op = .call, .a = 1 }, ins(.store_global, 1), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "fresh", .code = &.{ ins(.load_local, 0), ins(.return_value, 0) }, .parameters = &.{.dict}, .defaults = &.{Value{ .dict = &dict }}, .result = .dict, .local_types = &.{.dict} },
    }, &.{}, &.{ "first", "second" }, &.{ .dict, .dict });
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    for ([_]*Machine{ &first, &second }) |machine| {
        _ = try machine.execute(&.{});
        const a = machine.getGlobal("first").?.dict;
        const b = machine.getGlobal("second").?.dict;
        try std.testing.expect(a != b);
        try std.testing.expectEqual(a, a.entries.get("self").?.dict);
        try std.testing.expectEqual(a, a.entries.get("record").?.record.fields[0].dict);
        const list = a.entries.get("list").?.list.items();
        try std.testing.expectEqual(a, list[0].dict);
        try std.testing.expectEqual(a.entries.get("record").?.record, list[1].record);
        try std.testing.expect(try operators.valuesEqual(machine, .{ .dict = a }, .{ .dict = b }));
        try aggregates.setIndex(machine, .{ .dict = a }, .{ .string = "extra" }, .{ .int = 1 });
        try std.testing.expect(!b.entries.contains("extra"));
        try std.testing.expect(!try operators.valuesEqual(machine, .{ .dict = a }, .{ .dict = b }));
    }
    try std.testing.expect(first.getGlobal("first").?.dict != second.getGlobal("first").?.dict);
    try std.testing.expect(!dict.entries.contains("extra"));
    try std.testing.expect(record_value.owner == null);
}

test "aggregate VM argument binding reorders only already evaluated operands" {
    const Log = struct {
        values: [2]i64 = undefined,
        count: usize = 0,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.values[self.count] = args[0].int;
            self.count += 1;
            return .unit;
        }
    };
    const code = [_]I{
        ins(.constant, 0),                          .{ .op = .call, .a = 1, .b = 1 }, ins(.constant, 1),     .{ .op = .call, .a = 1, .b = 1 },
        .{ .op = .bind_arguments, .a = 0, .b = 2 }, ins(.make_list, 2),               ins(.store_global, 0), ins(.halt, 0),
    };
    var program = try testProgram(&.{
        .{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "mark", .code = &.{ ins(.load_local, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.print), .b = 1 }, ins(.pop, 0), ins(.load_local, 0), ins(.return_value, 0) }, .parameters = &.{.int}, .result = .int, .local_types = &.{.int} },
    }, &.{ .{ .int = 11 }, .{ .int = 22 } }, &.{"result"}, &.{.list});
    defer program.deinit();
    program.argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }};
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .callBuiltin = Log.call } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(i64, &.{ 11, 22 }, &log.values);
    const result = machine.getGlobal("result").?.list.items();
    try std.testing.expectEqual(@as(i64, 22), result[0].int);
    try std.testing.expectEqual(@as(i64, 11), result[1].int);
    try std.testing.expectEqual(@as(usize, 2), log.count);
}

test "variadic calls pack and coerce every remaining argument into a fresh list" {
    var code: std.ArrayList(I) = .empty;
    defer code.deinit(std.testing.allocator);
    try code.append(std.testing.allocator, ins(.constant, 0));
    for (0..32) |_| try code.append(std.testing.allocator, ins(.constant, 1));
    try code.appendSlice(std.testing.allocator, &.{
        .{ .op = .call, .a = 1, .b = 33 }, ins(.store_global, 0),
        ins(.constant, 0),                 .{ .op = .call, .a = 1, .b = 1 },
        ins(.store_global, 1),             ins(.constant, 0),
        .{ .op = .call, .a = 1, .b = 1 },  ins(.store_global, 2),
        ins(.halt, 0),
    });
    var program = try testProgram(&.{
        .{ .name = "script", .code = code.items, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "tail", .code = &.{ ins(.load_local, 1), ins(.return_value, 0) }, .parameters = &.{ .number, .list }, .variadic = .number, .result = .list, .local_types = &.{ .number, .list } },
    }, &.{ .{ .int = 1 }, .{ .int = 2 } }, &.{ "many", "empty", "another" }, &.{ .list, .list, .list });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const many = machine.getGlobal("many").?.list.owned;
    try std.testing.expectEqual(@as(usize, 32), many.values.items.len);
    for (many.values.items) |item| try std.testing.expectEqualDeep(Value{ .number = 2 }, item);
    const empty = machine.getGlobal("empty").?.list.owned;
    const another = machine.getGlobal("another").?.list.owned;
    try std.testing.expectEqual(@as(usize, 0), empty.values.items.len);
    try std.testing.expect(empty != another);
    try std.testing.expectEqual(@as(i64, 2), program.constants[1].int);
}

test "malformed variadic layouts return diagnostics without crossing local bounds" {
    const caller = [_]I{ .{ .op = .call, .a = 1, .b = 0 }, ins(.halt, 0) };
    for ([_][]const Type{ &.{}, &.{.number} }) |parameters| {
        var program = try testProgram(&.{
            .{ .name = "script", .code = &caller, .parameters = &.{}, .result = .unit, .local_types = &.{} },
            .{ .name = "invalid", .code = &.{ins(.halt, 0)}, .parameters = parameters, .variadic = .number, .result = .unit, .local_types = parameters },
        }, &.{}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(machine.failure != null);
    }
}

const default_lists =
    \\fn collect(head:list=[[]],rest:int...)->list
    \\    nested:=head[0]
    \\    nested+=len(rest)
    \\    return head
    \\end
    \\first:=collect()
    \\second:=collect()
    \\third:=collect([[]],7,8)
    \\child:=first[0]
    \\child+=9
    \\first_length:=len(first[0])
    \\second_length:=len(second[0])
    \\third_value:=third[0][0]
;

fn defaultAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("first_length").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("second_length").?.int);
    try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("third_value").?.int);
}

test "default collections and rest lists are owned independently per call and execution" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try @import("../compiler.zig").compile(std.testing.allocator, default_lists, "default-lists.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| try defaultAllocationExercise(std.testing.allocator, &program);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, defaultAllocationExercise, .{&program});
    }
}

test "default metadata is validated for external bytecode before entering a function" {
    const cases = [_]bytecode.Function{
        .{ .name = "mismatched_defaults", .parameters = &.{.int}, .defaults = &.{}, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_defaults_length", .parameters = &.{.int}, .defaults = &.{ .{ .int = 1 }, .{ .int = 2 } }, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_default_type", .parameters = &.{.int}, .defaults = &.{.{ .boolean = true }}, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_default_order", .parameters = &.{ .int, .int }, .defaults = &.{ .{ .int = 1 }, null }, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{ .int, .int } },
        .{ .name = "rest_default", .parameters = &.{.list}, .defaults = &.{types.listView(&.{})}, .variadic = .int, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.list} },
    };
    for (cases, 0..) |function, index| {
        const code: []const I = if (index == 3)
            &.{ ins(.constant, 0), ins(.constant, 0), .{ .op = .call, .a = 1, .b = 2 }, ins(.halt, 0) }
        else
            &.{ .{ .op = .call, .a = 1 }, ins(.halt, 0) };
        var program = try testProgram(&.{
            .{ .name = "script", .parameters = &.{}, .code = code, .result = .unit, .local_types = &.{} },
            function,
        }, &.{.{ .int = 1 }}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
}

test "runtime checks function arguments and returns even for externally constructed bytecode" {
    const function_code = &.{ ins(.constant, 0), ins(.return_value, 0) };
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ .{ .op = .call, .a = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "bad_result", .code = function_code, .parameters = &.{}, .result = .int, .local_types = &.{} },
    }, &.{.{ .boolean = true }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "expected int") != null);
    program.functions = &.{
        .{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call, .a = 1, .b = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "int_argument", .code = function_code, .parameters = &.{.int}, .result = .boolean, .local_types = &.{.int} },
    };
    var arguments_machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer arguments_machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, arguments_machine.execute(&.{}));
    try std.testing.expect(std.mem.find(u8, arguments_machine.failure.?.text(), "expected int") != null);
}
