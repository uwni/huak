//! Tests of finite and ownership validation.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Type = types.Type;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const validation = @import("validation.zig");
const lists = @import("lists.zig");
const aggregates = @import("aggregates.zig");
const templates = @import("templates.zig");
const testing = @import("testing.zig");
const testProgram = testing.testProgram;
const ins = testing.ins;
const TypstRequest = Machine.TypstRequest;
const TypstBatchDiagnostic = Machine.TypstBatchDiagnostic;

test "aggregate VM finite validation walks cyclic nested containers" {
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    const list_values = [_]Value{ .{ .record = &record_value }, .{ .number = std.math.nan(f64) } };
    try dict.entries.put(std.testing.allocator, "cycle", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "list", types.listView(&list_values));
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, validation.checkFinite(&machine, .{ .dict = &dict }));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
}

test "aggregate VM internal coercion reuses validated execution ownership without allocations" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const list = try lists.makeList(&machine, &.{.{ .int = 1 }});
    const dict = try aggregates.makeDict(&machine, &.{ .{ .string = "items" }, list });
    const record_value = try aggregates.makeRecord(&machine, 0, &.{dict});
    try aggregates.setIndex(&machine, dict, .{ .string = "node" }, record_value);
    try lists.appendList(&machine, list, record_value);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original = machine.gpa;
    machine.gpa = failing.allocator();
    defer machine.gpa = original;
    for (0..64) |_| {
        _ = try validation.coerce(&machine, record_value, Type.record(0));
        _ = try validation.coerce(&machine, list, .list);
        _ = try validation.coerce(&machine, dict, .dict);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "aggregate VM external validation ignores forged owners and template clones validate owned children" {
    const Invalid = enum { nonfinite, field_type, dictionary_key, native_handle };
    for ([_]Invalid{ .nonfinite, .field_type, .dictionary_key, .native_handle }) |invalid| for ([_]bool{ false, true }) |template| {
        var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
        defer program.deinit();
        program.records = &.{.{ .name = "Count", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        var forged: types.List.Owned = .{ .owner = machine.identity };
        defer forged.values.deinit(std.testing.allocator);
        var fields = [_]Value{.{ .string = "wrong" }};
        var record_value: types.Record = .{ .owner = machine.identity, .kind = Type.record(0), .fields = &fields };
        var dict: types.Dict = .{ .owner = machine.identity };
        defer dict.entries.deinit(std.testing.allocator);
        try dict.entries.put(std.testing.allocator, "\xff", .unit);
        const bad: Value = switch (invalid) {
            .nonfinite => .{ .number = std.math.nan(f64) },
            .field_type => .{ .record = &record_value },
            .dictionary_key => .{ .dict = &dict },
            .native_handle => .{ .handle = .{ .kind = .dict, .index = 0 } },
        };
        try forged.values.appendSlice(std.testing.allocator, &.{ bad, .{ .list = .{ .owned = &forged } } });
        const value: Value = .{ .list = .{ .owned = &forged } };
        if (template) {
            try std.testing.expectError(error.RuntimeFailed, templates.materialize(&machine, types.listView(&.{value})));
        } else try std.testing.expectError(error.RuntimeFailed, validation.checkFiniteExternal(&machine, value));
        const expected = switch (invalid) {
            .nonfinite => "non-finite",
            .field_type => "expects int",
            .dictionary_key => "valid UTF-8",
            .native_handle => "invalid native handle",
        };
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), expected) != null);
    };
}

test "aggregate VM borrowed nodes retain complete finite and nominal field validation" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Count", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
    for ([_]bool{ false, true }) |record_case| {
        var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer owner.deinit();
        var borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer borrower.deinit();
        const value = if (record_case) try aggregates.makeRecord(&owner, 0, &.{.{ .int = 1 }}) else try lists.makeList(&owner, &.{.{ .int = 1 }});
        try validation.checkFinite(&borrower, value);
        // Simulate changed foreign storage to prove that a borrowed owner is
        // never cached. Production task parents stay frozen until join.
        if (record_case) value.record.fields[0] = .{ .string = "wrong" } else value.list.owned.values.items[0] = .{ .number = std.math.nan(f64) };
        try std.testing.expectError(error.RuntimeFailed, validation.checkFinite(&borrower, value));
        try std.testing.expect(std.mem.indexOf(u8, borrower.failure.?.text(), if (record_case) "expects int" else "non-finite") != null);
    }
}

test "aggregate VM every host return path fully checks nested values despite a matching owner" {
    const Probe = struct {
        owner: *const types.Ownership,
        calls: usize = 0,
        fn bad(self: *@This(), allocator: std.mem.Allocator) !Value {
            self.calls += 1;
            const list = try allocator.create(types.List.Owned);
            list.* = .{ .owner = self.owner };
            try list.values.append(allocator, .{ .number = std.math.nan(f64) });
            return .{ .list = .{ .owned = list } };
        }
        fn from(context: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(context.?));
        }
        fn call(context: ?*anyopaque, allocator: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            return from(context).bad(allocator);
        }
        fn field(context: ?*anyopaque, allocator: std.mem.Allocator, _: Value, _: []const u8) !Value {
            return from(context).bad(allocator);
        }
        fn binary(context: ?*anyopaque, allocator: std.mem.Allocator, _: bytecode.Op, _: Value, _: Value) !Value {
            return from(context).bad(allocator);
        }
        fn typst(context: ?*anyopaque, allocator: std.mem.Allocator, _: TypstRequest) !Value {
            return from(context).bad(allocator);
        }
        fn batch(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const TypstRequest, values: []Value, _: *TypstBatchDiagnostic) !void {
            for (values) |*value| value.* = try from(context).bad(allocator);
        }
    };
    const cases = [_]struct { code: []const I, batch: bool = false }{
        .{ .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.bounds), .b = 1 }, ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.constant, 0), ins(.field, 1), ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.constant, 0), ins(.constant, 0), ins(.add, 0), ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.typst, 1), ins(.store_global, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.typst, 1), ins(.store_global, 0), ins(.halt, 0) }, .batch = true },
    };
    for (cases) |case| {
        var program = try testProgram(&.{.{ .name = "script", .code = case.code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .handle = .{ .kind = .variable, .index = 0 } }, .{ .string = "sample" } }, &.{"text"}, &.{.text});
        defer program.deinit();
        var probe: Probe = .{ .owner = undefined };
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .callBuiltin = Probe.call, .field = Probe.field, .binary = Probe.binary, .typst = Probe.typst, .typstBatch = if (case.batch) Probe.batch else null } }, .{});
        defer machine.deinit();
        probe.owner = machine.identity;
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
    }
}
