//! Tests of appending literal items: one instruction, validation, jumps and task boundaries.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const lists = @import("lists.zig");
const function_calls = @import("function_calls.zig");
const testing = @import("testing.zig");
const Error = Machine.Error;
const ins = testing.ins;
const testProgram = testing.testProgram;

test "literal append uses one instruction with identical scheduled and serial budget prefixes" {
    const Scheduler = struct {
        fn unchanged(_: ?*anyopaque, _: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            return false;
        }
    };
    const code = [_]I{
        ins(.make_list, 0),                                                                 ins(.store_global, 0), ins(.load_global, 0), ins(.constant, 0), ins(.constant, 1),
        .{ .op = .list_append_items, .a = 2, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .int = 2 } }, &.{"items"}, &.{.list});
    defer program.deinit();
    program.task_regions = &.{.{ .function = 0, .start = 5, .end = 6, .tasks = &.{} }};
    for (0..code.len + 1) |limit| {
        var serial = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = limit });
        defer serial.deinit();
        var scheduled = try Machine.init(std.testing.allocator, &program, .{ .tasks = .{ .vtable = &.{ .dispatch = Scheduler.unchanged } } }, .{ .instructions = limit });
        defer scheduled.deinit();
        if (serial.execute(&.{})) |_| {
            _ = try scheduled.execute(&.{});
        } else |err| try std.testing.expectError(err, scheduled.execute(&.{}));
        try std.testing.expectEqual(serial.steps, scheduled.steps);
        try std.testing.expectEqualDeep(serial.initialized, scheduled.initialized);
        if (serial.getGlobal("items")) |value| try std.testing.expectEqualDeep(value.list.items(), scheduled.getGlobal("items").?.list.items());
        if (serial.failure) |failure| {
            try std.testing.expectEqualDeep(failure.diagnostic.span, scheduled.failure.?.diagnostic.span);
            try std.testing.expectEqualStrings(failure.text(), scheduled.failure.?.text());
            try std.testing.expectEqual(serial.frames.items[0].ip, scheduled.frames.items[0].ip);
        }
    }
}

test "literal append validates its items once with or without a scheduler" {
    const Scheduler = struct {
        fn unexpected(_: ?*anyopaque, _: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            return error.RuntimeFailed;
        }
    };
    const code = [_]I{ ins(.list_append_items, 1), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer owner.deinit();
    const borrowed = try lists.makeList(&owner, &.{.{ .int = 7 }});
    for ([_]bool{ false, true }) |with_scheduler| {
        var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var machine = try Machine.init(counter.allocator(), &program, .{ .tasks = if (with_scheduler) .{ .vtable = &.{ .dispatch = Scheduler.unexpected } } else null }, .{});
        defer machine.deinit();
        const target = try lists.makeList(&machine, &.{});
        try target.list.owned.values.ensureUnusedCapacity(machine.arena.allocator(), 1);
        try function_calls.enter(&machine, 0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, &.{ target, borrowed });
        var one = [_]Value{borrowed};
        const before_reference = counter.allocations;
        try lists.prepareListItems(&machine, &one);
        const one_preparation = counter.allocations - before_reference;
        try std.testing.expect(one_preparation > 0);
        const before_execution = counter.allocations;
        _ = try machine.run(null);
        try std.testing.expectEqual(one_preparation, counter.allocations - before_execution);
        try std.testing.expect(target.list.items()[0].list.owned == borrowed.list.owned);
        try std.testing.expectEqual(@as(u64, code.len), machine.steps);
    }
}

test "literal append validates jump entries and respects task suspension and scheduler boundaries" {
    const code = [_]I{
        ins(.jump, 1), .{ .op = .list_append_items, .a = 1, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var suspended = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer suspended.deinit();
    const untouched = try lists.makeList(&suspended, &.{});
    try function_calls.enter(&suspended, 0, 0, .{ .start = 0, .end = 0 });
    try suspended.stack.appendSlice(suspended.gpa, &.{ untouched, .{ .int = 7 } });
    const result = try suspended.run(1);
    try std.testing.expectEqual(@as(i64, 7), result.int);
    try std.testing.expectEqual(@as(usize, 0), untouched.list.items().len);
    try std.testing.expectEqual(@as(usize, 1), suspended.frames.items[0].ip);
    try std.testing.expectEqual(@as(u64, 1), suspended.steps);

    const Scheduler = struct {
        calls: usize = 0,
        fn mutate(context: ?*anyopaque, machine: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            machine.stack.items[machine.stack.items.len - 1] = .{ .number = std.math.nan(f64) };
            return false;
        }
    };
    for ([_]bool{ false, true }) |with_scheduler| {
        var scheduler: Scheduler = .{};
        program.task_regions = &.{.{ .function = 0, .start = 1, .end = 2, .tasks = &.{} }};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .tasks = if (with_scheduler) .{ .ptr = &scheduler, .vtable = &.{ .dispatch = Scheduler.mutate } } else null }, .{});
        defer machine.deinit();
        const target = try lists.makeList(&machine, &.{});
        try function_calls.enter(&machine, 0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, &.{ target, if (with_scheduler) Value{ .int = 7 } else Value{ .number = std.math.nan(f64) } });
        try std.testing.expectError(error.RuntimeFailed, machine.run(null));
        try std.testing.expectEqual(@as(usize, if (with_scheduler) 1 else 0), scheduler.calls);
        try std.testing.expectEqual(@as(usize, 0), target.list.items().len);
        try std.testing.expectEqual(@as(usize, 10), machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(u64, 2), machine.steps);
    }
}

test "list item opcodes validate standalone inputs and retain construction before target errors" {
    for ([_]bool{ false, true }) |optimized| for ([_]bool{ false, true }) |bad_input| {
        const original = [_]I{ ins(.load_global, 0), ins(.load_global, 1), .{ .op = .make_list, .a = 1, .span = .{ .start = 10, .end = 20 } }, .{ .op = .list_append, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        const combined = [_]I{ ins(.load_global, 0), ins(.load_global, 1), .{ .op = .list_append_items, .a = 1, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = if (optimized) &combined else &original, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "input" }, &.{ .any, .any });
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = .{ .int = 42 };
        machine.globals[1] = if (bad_input) .{ .number = std.math.nan(f64) } else .{ .int = 7 };
        @memset(machine.initialized, true);
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, if (bad_input) 10 else 5), machine.failure.?.diagnostic.span.start);
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), if (bad_input) "non-finite" else "expected a list") != null);
        try std.testing.expectEqual(@as(i64, 42), machine.globals[0].int);
    };
    const code = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.list_append_items, 1), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "input" }, &.{ .any, .any });
    defer program.deinit();
    for ([_]bool{ false, true }) |bad_input| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = try lists.makeList(&machine, &.{});
        machine.globals[1] = types.listView(if (bad_input) &.{.{ .number = std.math.nan(f64) }} else &.{.{ .int = 7 }});
        @memset(machine.initialized, true);
        if (bad_input) {
            try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try std.testing.expectEqual(@as(usize, 0), machine.globals[0].list.items().len);
        } else {
            _ = try machine.execute(&.{});
            const nested = machine.globals[0].list.items()[0].list.owned;
            try std.testing.expectEqual(machine.identity, nested.owner);
            try std.testing.expectEqual(@as(i64, 7), nested.values.items[0].int);
            try std.testing.expect(machine.globals[1].list == .view);
        }
    }
}

test "literal append reports item underflow and validation before missing target" {
    const cases = [_]struct { count: u32, values: []const Value, start: usize }{
        .{ .count = 0, .values = &.{}, .start = 5 },
        .{ .count = 1, .values = &.{.{ .int = 7 }}, .start = 5 },
        .{ .count = 1, .values = &.{.{ .number = std.math.nan(f64) }}, .start = 10 },
        .{ .count = 2, .values = &.{.{ .int = 7 }}, .start = 10 },
    };
    for (cases) |case| {
        const code = [_]I{ .{ .op = .list_append_items, .a = case.count, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try function_calls.enter(&machine, 0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, case.values);
        try std.testing.expectError(error.RuntimeFailed, machine.run(null));
        try std.testing.expectEqual(case.start, machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(usize, 20), machine.failure.?.diagnostic.span.end);
        try std.testing.expectEqual(@as(u64, 1), machine.steps);
    }
}

test "list item preparation materializes every item before validating an earlier scalar" {
    for ([_]bool{ false, true }) |optimized| {
        const original = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.load_global, 2), .{ .op = .make_list, .a = 2, .span = .{ .start = 10, .end = 20 } }, .{ .op = .list_append, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        const combined = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.load_global, 2), .{ .op = .list_append_items, .a = 2, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = if (optimized) &combined else &original, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "first", "second" }, &.{ .any, .any, .any });
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = try lists.makeList(&machine, &.{});
        machine.globals[1] = .{ .number = std.math.nan(f64) };
        machine.globals[2] = types.listView(&.{.omitted});
        @memset(machine.initialized, true);
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "omitted argument marker") != null);
        try std.testing.expectEqual(@as(usize, 10), machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(usize, 0), machine.globals[0].list.items().len);
    }
}
