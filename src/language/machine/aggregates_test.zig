//! Tests of dictionaries, shallow copies, records, owner checks and allocation failure in aggregates.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Type = types.Type;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const lists = @import("lists.zig");
const aggregates = @import("aggregates.zig");
const builtin_calls = @import("builtin_calls.zig");
const validation = @import("validation.zig");
const templates = @import("templates.zig");
const operators = @import("operators.zig");
const function_calls = @import("function_calls.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;

test "aggregate VM dictionary aliases insertion order and shallow copy" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child = try lists.makeList(&machine, &.{.{ .int = 1 }});
    const original = try aggregates.makeDict(&machine, &.{ .{ .string = "a" }, child, .{ .string = "b" }, .{ .int = 2 } });
    const alias = original;
    try aggregates.setIndex(&machine, alias, .{ .string = "a" }, child);
    try aggregates.setIndex(&machine, alias, .{ .string = "b" }, .{ .int = 3 });
    const copied = (try builtin_calls.coreBuiltin(&machine, .copy, &.{original})).?;
    try std.testing.expect(original.dict != copied.dict);
    try std.testing.expectEqual(@as(i64, 3), original.dict.entries.get("b").?.int);
    try lists.appendList(&machine, child, .{ .int = 4 });
    try std.testing.expectEqual(@as(usize, 2), copied.dict.entries.get("a").?.list.items().len);
    try aggregates.setIndex(&machine, copied, .{ .string = "c" }, .{ .int = 5 });
    try std.testing.expect(!original.dict.entries.contains("c"));
    try std.testing.expect((try builtin_calls.coreBuiltin(&machine, .dict_remove, &.{ alias, .{ .string = "a" } })).?.boolean);
    try std.testing.expect(!(try builtin_calls.coreBuiltin(&machine, .dict_remove, &.{ alias, .{ .string = "a" } })).?.boolean);
    try aggregates.setIndex(&machine, alias, .{ .string = "a" }, child);
    const keys = (try builtin_calls.coreBuiltin(&machine, .dict_keys, &.{original})).?.list.items();
    try std.testing.expectEqualStrings("b", keys[0].string);
    try std.testing.expectEqualStrings("a", keys[1].string);
    try std.testing.expect((try builtin_calls.coreBuiltin(&machine, .dict_contains, &.{ original, .{ .string = "b" } })).?.boolean);
    try std.testing.expectEqual(@as(i64, 2), (try builtin_calls.coreBuiltin(&machine, .len, &.{original})).?.int);
}

fn copyListExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    const child = try lists.makeList(&machine, &.{.{ .int = 7 }});
    const original = try lists.makeList(&machine, &.{ child, child });
    try lists.appendList(&machine, original, try lists.makeList(&machine, &.{original}));
    // A foreign graph must be checked, while the shallow copy retains its
    // nested identities and receives an independently mutable outer list.
    var foreign: types.Ownership = .{};
    original.list.owned.owner = &foreign;
    const copied = try aggregates.copyValue(&machine, original);
    try std.testing.expect(copied.list.owned != original.list.owned);
    try std.testing.expectEqual(machine.identity, copied.list.owned.owner.?);
    try std.testing.expect(copied.list.items()[0].list.owned == child.list.owned);
    try std.testing.expect(copied.list.items()[0].list.owned == copied.list.items()[1].list.owned);
    try std.testing.expect(copied.list.items()[2].list.owned == original.list.owned);
    try lists.appendList(&machine, copied, .{ .int = 9 });
    try std.testing.expectEqual(@as(usize, 3), original.list.items().len);
}

test "aggregate VM shallow list copy validates once and preserves cycles through allocation failures" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    try copyListExercise(std.testing.allocator, &program);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyListExercise, .{&program});
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child = try lists.makeList(&machine, &.{.{ .int = 7 }});
    var foreign: types.Ownership = .{};
    child.list.owned.owner = &foreign;
    const original = try lists.makeList(&machine, &.{child});
    original.list.owned.owner = &foreign;
    // Graph traversal uses gpa, while the new container uses the existing
    // arena. Count traversal allocations independently of container growth.
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const previous = machine.gpa;
    machine.gpa = counter.allocator();
    defer machine.gpa = previous;
    try validation.checkFinite(&machine, original);
    const one_validation = counter.allocations;
    try std.testing.expect(one_validation > 0);
    _ = try aggregates.copyValue(&machine, original);
    try std.testing.expectEqual(one_validation * 2, counter.allocations);
    child.list.owned.values.items[0] = .{ .number = std.math.nan(f64) };
    try std.testing.expectError(error.RuntimeFailed, aggregates.copyValue(&machine, original));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
}

test "aggregate VM dictionary opcodes validate duplicate and missing keys" {
    const code = [_]I{
        ins(.constant, 0), ins(.constant, 1),     ins(.make_dict, 1), ins(.duplicate, 0),   ins(.store_global, 0),
        ins(.constant, 0), ins(.constant, 2),     ins(.set_index, 0), ins(.load_global, 0), ins(.constant, 0),
        ins(.index, 0),    ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "Ω" }, .{ .int = 1 }, .{ .int = 7 } }, &.{ "dict", "result" }, &.{ .dict, .int });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("result").?.int);
    try std.testing.expectError(error.RuntimeFailed, aggregates.readIndex(&machine, machine.getGlobal("dict").?, .{ .string = "absent" }));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "has no key 'absent'") != null);
    var duplicate = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer duplicate.deinit();
    try std.testing.expectError(error.RuntimeFailed, aggregates.makeDict(&duplicate, &.{ .{ .string = "same" }, .unit, .{ .string = "same" }, .unit }));
    try std.testing.expect(std.mem.indexOf(u8, duplicate.failure.?.text(), "duplicate dictionary key") != null);
}

test "aggregate VM nominal struct field typing and static slots" {
    const code = [_]I{
        ins(.constant, 0),     .{ .op = .make_record, .a = 0, .b = 1 }, ins(.duplicate, 0),   ins(.store_global, 0),
        ins(.constant, 1),     .{ .op = .set_field, .a = 2, .b = 1 },   ins(.load_global, 0), .{ .op = .field, .a = 2, .b = 1 },
        ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .int = 9 }, .{ .string = "count" } }, &.{ "state", "result" }, &.{ Type.record(0), .int });
    defer program.deinit();
    program.records = &.{
        .{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} },
        .{ .name = "Other", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} },
    };
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("result").?.int);
    const state = machine.getGlobal("state").?;
    const alias = state;
    alias.record.fields[0] = .{ .int = 12 };
    try std.testing.expectEqual(@as(i64, 12), state.record.fields[0].int);
    const copy = try aggregates.copyValue(&machine, state);
    copy.record.fields[0] = .{ .int = 13 };
    try std.testing.expectEqual(@as(i64, 12), state.record.fields[0].int);
    try std.testing.expectError(error.RuntimeFailed, validation.coerce(&machine, state, Type.record(1)));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "expected Other, received State") != null);
    var wrong = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.RuntimeFailed, aggregates.makeRecord(&wrong, 0, &.{.{ .string = "wrong" }}));
}

test "aggregate VM owner checks reject foreign dictionaries lists and structs" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.load_global, 0), ins(.constant, 0), .{ .op = .set_field, .a = 1, .b = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .string = "count" } }, &.{"state"}, &.{Type.record(0)});
    defer program.deinit();
    program.records = &.{.{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
    var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer owner.deinit();
    const dict = try aggregates.makeDict(&owner, &.{});
    var borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer borrower.deinit();
    try std.testing.expectError(error.RuntimeFailed, aggregates.setIndex(&borrower, dict, .{ .string = "x" }, .unit));
    try std.testing.expectEqual(@as(usize, 0), dict.dict.entries.count());
    const list = try lists.makeList(&owner, &.{.unit});
    var list_borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer list_borrower.deinit();
    try std.testing.expectError(error.RuntimeFailed, aggregates.setIndex(&list_borrower, list, .{ .int = 0 }, .{ .int = 1 }));
    try std.testing.expectEqual(Value.unit, list.list.items()[0]);
    const copied = try aggregates.copyValue(&owner, dict);
    try std.testing.expectEqual(owner.identity, copied.dict.owner.?);
    const record_value = try aggregates.makeRecord(&owner, 0, &.{.{ .int = 0 }});
    var record_borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer record_borrower.deinit();
    record_borrower.globals[0] = record_value;
    record_borrower.initialized[0] = true;
    try std.testing.expectError(error.RuntimeFailed, record_borrower.execute(&.{}));
    try std.testing.expectEqual(@as(i64, 0), record_value.record.fields[0].int);
    try std.testing.expect(std.mem.indexOf(u8, record_borrower.failure.?.text(), "cannot modify a borrowed struct") != null);
}

test "aggregate VM malformed struct fields and bindings fail with diagnostics" {
    const cases = [_]struct { code: []const I, message: []const u8 }{
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, ins(.constant, 2), .{ .op = .set_field, .a = 1, .b = 1 } }, .message = "expected int" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, .{ .op = .field, .a = 1, .b = 2 } }, .message = "invalid bytecode struct field slot" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, .{ .op = .field, .a = 2 } }, .message = "unknown field 'wrong'" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 1, .b = 1 } }, .message = "invalid bytecode struct index" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 1 } }, .message = "argument binding count" },
        .{ .code = &.{ ins(.constant, 0), ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 2 } }, .message = "argument binding slot" },
    };
    for (cases) |case| {
        var program = try testProgram(&.{.{ .name = "script", .code = case.code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .string = "count" }, .{ .string = "wrong" } }, &.{}, &.{});
        defer program.deinit();
        program.records = &.{.{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
        program.argument_bindings = &.{.{ .slots = &.{ 0, 0 }, .parameter_count = 2 }};
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
    }
}

fn aggregateAllocationProbe(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    const graph = try templates.materialize(&machine, program.constants[0]);
    const dict = try aggregates.makeDict(&machine, &.{ .{ .string = "graph" }, graph });
    try aggregates.setIndex(&machine, dict, .{ .string = "self" }, dict);
    const record_value = try aggregates.makeRecord(&machine, 0, &.{dict});
    try aggregates.setIndex(&machine, dict, .{ .string = "record" }, record_value);
    const copied = try aggregates.copyValue(&machine, dict);
    try std.testing.expect(try operators.valuesEqual(&machine, dict, copied));
    _ = try builtin_calls.coreBuiltin(&machine, .dict_keys, &.{dict});
    _ = try builtin_calls.coreBuiltin(&machine, .dict_contains, &.{ dict, .{ .string = "graph" } });
    _ = try builtin_calls.coreBuiltin(&machine, .dict_remove, &.{ copied, .{ .string = "record" } });
    try machine.push(dict);
    try machine.push(record_value);
    try function_calls.bindArguments(&machine, 0, 2);
    try std.testing.expect(machine.stack.items[0] == .record);
    try std.testing.expect(machine.stack.items[1] == .dict);
}

test "aggregate VM every allocation failure releases mixed graphs and argument buffers" {
    var template_dict: types.Dict = .{};
    defer template_dict.entries.deinit(std.testing.allocator);
    try template_dict.entries.put(std.testing.allocator, "self", .{ .dict = &template_dict });
    const template_list = [_]Value{ .{ .dict = &template_dict }, .{ .dict = &template_dict } };
    try template_dict.entries.put(std.testing.allocator, "list", types.listView(&template_list));
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .dict = &template_dict }}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    program.argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aggregateAllocationProbe, .{&program});
}
