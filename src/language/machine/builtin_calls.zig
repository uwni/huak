//! Builtin calls: arity and coercion from the signature, the primitives the VM runs itself, host dispatch and result checks.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const Value = types.Value;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const validation = @import("validation.zig");
const failures = @import("failures.zig");
const templates = @import("templates.zig");
const lists = @import("lists.zig");
const aggregates = @import("aggregates.zig");
const testing = @import("testing.zig");
const Error = Machine.Error;
const ins = testing.ins;
const testProgram = testing.testProgram;

pub fn callBuiltin(self: *Machine, index_: u32, count: usize) Error!void {
    const id = std.enums.fromInt(builtin.Id, index_) orelse return self.fail("invalid bytecode builtin", .{});
    const signature = builtin.signature(id);
    if (!signature.acceptsCount(count)) return self.fail("invalid argument count for '{s}'", .{signature.name});
    const args = try self.arguments(count);
    for (args, 0..) |*arg, index| {
        if (arg.* == .omitted and index >= signature.minimum) continue;
        const expected = if (index < signature.args.len) signature.args[index] else signature.variadic.?;
        arg.* = try validation.coerce(self, arg.*, expected);
    }
    if (try coreBuiltin(self, id, args)) |value| {
        self.stack.items.len -= count;
        try validation.checkFinite(self, value);
        try self.push(try validation.coerceValidated(self, try templates.materializeValidated(self, value), signature.result));
        return;
    }
    if (self.host.vtable.call_builtin == null) return self.fail("builtin '{s}' requires a host", .{signature.name});
    const value = self.host.callBuiltin(self.arena.allocator(), id, args, self) catch |err| return failures.nativeFailure(self, err);
    try validation.checkFiniteExternal(self, value);
    self.stack.items.len -= count;
    const materialized = try templates.materializeValidated(self, value);
    try self.push(try validation.coerceValidated(self, materialized, signature.result));
}

/// Language primitives need no geometry/typesetting host.
pub fn coreBuiltin(self: *Machine, id: builtin.Id, args: []const Value) Error!?Value {
    switch (id) {
        .seed => {
            self.random = .init(@bitCast(builtin.arguments(.seed, args).value.int));
            return .unit;
        },
        .random => return .{ .number = self.random.random().float(f64) },
        .randn => return .{ .number = self.random.random().floatNorm(f64) },
        .randint => {
            const arg = builtin.arguments(.randint, args);
            const min = arg.min.int;
            const max = arg.max.int;
            if (min > max) return self.fail("math.randint requires min <= max", .{});
            return .{ .int = self.random.random().intRangeAtMost(i64, min, max) };
        },
        .panic => {
            const cause = self.fail("panic", .{});
            if (cause == error.OutOfMemory) return error.OutOfMemory;
            self.failure.?.native_message = try self.arena.allocator().dupe(u8, builtin.arguments(.panic, args).message.string);
            return cause;
        },
        .len => switch (builtin.arguments(.len, args).value) {
            .string => |text| return .{ .int = @intCast(std.unicode.utf8CountCodepoints(text) catch return self.fail("len requires valid UTF-8", .{})) },
            .list => |list| return .{ .int = @intCast(list.items().len) },
            .dict => |dict| return .{ .int = @intCast(dict.entries.count()) },
            else => {},
        },
        .dict_contains => {
            const arg = builtin.arguments(.dict_contains, args);
            if (arg.dictionary != .dict or arg.key != .string) return self.fail("dict_contains requires dictionary and string", .{});
            return .{ .boolean = arg.dictionary.dict.entries.contains(arg.key.string) };
        },
        .dict_remove => {
            const arg = builtin.arguments(.dict_remove, args);
            if (arg.dictionary != .dict or arg.key != .string) return self.fail("dict_remove requires dictionary and string", .{});
            const dict = arg.dictionary.dict;
            if (dict.owner != self.identity) return self.fail("cannot modify a borrowed dictionary", .{});
            return .{ .boolean = dict.entries.orderedRemove(arg.key.string) };
        },
        .dict_keys => {
            const dictionary = builtin.arguments(.dict_keys, args).dictionary;
            if (dictionary != .dict) return self.fail("keys requires dictionary", .{});
            const value = try lists.makeList(self, &.{});
            for (dictionary.dict.entries.keys()) |key| try value.list.owned.values.append(self.arena.allocator(), .{ .string = key });
            return value;
        },
        .copy => {
            const original = builtin.arguments(.copy, args).value;
            if (original != .object) return try aggregates.copyValue(self, original);
        },
        else => {},
    }
    return null;
}

test "aggregate VM optional builtin omissions remain distinct from explicit unit" {
    const Probe = struct {
        seen: bool = false,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(builtin.Id.rgb, id);
            try std.testing.expectEqual(@as(usize, 4), args.len);
            try std.testing.expect(args[3] == .omitted);
            self.seen = true;
            return .{ .handle = .{ .kind = .color, .index = 0 } };
        }
    };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 0), ins(.constant, 0), ins(.constant, 1), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.rgb), .b = 4 }, ins(.pop, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .number = 0 }, .omitted }, &.{}, &.{});
    defer program.deinit();
    var probe: Probe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .call_builtin = Probe.call } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expect(probe.seen);
    program.constants = &.{ .{ .number = 0 }, .unit };
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "expected number") != null);
}

test "host builtin claims fresh ownerless lists in place and checks leaves inline once" {
    const Probe = struct {
        poison: bool = false,
        inner: ?*types.List.Owned = null,
        items_ptr: ?[*]Value = null,
        fn call(context: ?*anyopaque, allocator: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const items = try allocator.alloc(Value, 256);
            for (items, 0..) |*slot, i| slot.* = .{ .number = @floatFromInt(i) };
            if (self.poison) items[200] = .{ .number = std.math.nan(f64) };
            const inner = try allocator.create(types.List.Owned);
            inner.* = .{ .values = .fromOwnedSlice(items) };
            self.inner = inner;
            self.items_ptr = items.ptr;
            return types.listView(try allocator.dupe(Value, &.{.{ .list = .{ .owned = inner } }}));
        }
    };
    const code = [_]I{
        ins(.constant, 0),
        .{ .op = .call_builtin, .a = @backingInt(builtin.Id.bounds), .b = 1 },
        ins(.store_global, 0),
        ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .int = 0 }}, &.{"result"}, &.{.list});
    defer program.deinit();
    var probe: Probe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .call_builtin = Probe.call } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const result = machine.getGlobal("result").?;
    try std.testing.expectEqual(machine.identity, result.list.owned.owner.?);
    const child = result.list.items()[0];
    try std.testing.expectEqual(probe.inner.?, child.list.owned);
    try std.testing.expectEqual(probe.items_ptr.?, child.list.owned.values.items.ptr);
    try std.testing.expectEqual(machine.identity, child.list.owned.owner.?);

    var bad_probe: Probe = .{ .poison = true };
    var invalid = try Machine.init(std.testing.allocator, &program, .{ .ptr = &bad_probe, .vtable = &.{ .call_builtin = Probe.call } }, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "non-finite") != null);

    const small_buf = [_]Value{ .{ .number = 1 }, .{ .number = 2 } };
    var large_buf: [512]Value = undefined;
    for (&large_buf, 0..) |*slot, i| slot.* = .{ .number = @floatFromInt(i) };
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const prev_gpa = machine.gpa;
    machine.gpa = counter.allocator();
    defer machine.gpa = prev_gpa;
    try validation.checkFiniteExternal(&machine, types.listView(&small_buf));
    const small_allocs = counter.allocations;
    try std.testing.expect(small_allocs > 0);
    try validation.checkFiniteExternal(&machine, types.listView(&large_buf));
    try std.testing.expectEqual(small_allocs * 2, counter.allocations);
}
