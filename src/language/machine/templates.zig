//! Turning read-only program constants and host results into execution-owned graphs that keep their aliases and cycles.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const I = bytecode.Instruction;
const Machine = @import("../Machine.zig");
const validation = @import("validation.zig");
const lists = @import("lists.zig");
const aggregates = @import("aggregates.zig");
const testing = @import("testing.zig");
const Error = Machine.Error;
const ins = testing.ins;
const testProgram = testing.testProgram;

/// A native sequence or constant template never becomes mutable Program
/// storage. Native graphs retain sharing within one returned value.
pub fn materialize(self: *Machine, value: Value) Error!Value {
    if (!isTemplate(value)) return value;
    // Source descriptors remain external/immutable. Validate their entire
    // graph before any clone receives the execution's trusted owner.
    try validation.checkFiniteExternal(self, value);
    if (value == .list) {
        const items = value.list.items();
        var nested = false;
        for (items) |item| if (isTemplate(item)) {
            nested = true;
            break;
        };
        if (!nested) return lists.makeList(self, items);
    }
    var seen: std.AutoHashMapUnmanaged(SequenceKey, Value) = .empty;
    defer seen.deinit(self.gpa);
    const result = try materializeGraph(self, value, &seen, 0);
    finishGraph(self, &seen);
    return result;
}

pub fn finishGraph(self: *Machine, seen: *std.AutoHashMapUnmanaged(SequenceKey, Value)) void {
    var values = seen.valueIterator();
    while (values.next()) |value| switch (value.*) {
        .list => |list| list.owned.owner = self.identity,
        .dict => |dict| dict.owner = self.identity,
        .record => |record_value| record_value.owner = self.identity,
        .function => |function| function.bound.owner = self.identity,
        else => unreachable,
    };
}

pub const SequenceKey = struct { address: usize, length: usize = 0, kind: enum { list, dict, record, function } = .list };

fn isTemplate(value: Value) bool {
    return switch (value) {
        .list => |list| list == .view,
        .dict => |dict| dict.owner == null,
        .record => |record_value| record_value.owner == null,
        .function => |function| function == .bound and function.bound.owner == null,
        else => false,
    };
}

pub fn materializeGraph(self: *Machine, value: Value, seen: *std.AutoHashMapUnmanaged(SequenceKey, Value), depth: usize) Error!Value {
    if (!isTemplate(value)) return value;
    const key: SequenceKey = switch (value) {
        .list => |list| .{ .address = @intFromPtr(list.items().ptr), .length = list.items().len },
        .dict => |dict| .{ .address = @intFromPtr(dict), .kind = .dict },
        .record => |record_value| .{ .address = @intFromPtr(record_value), .kind = .record },
        .function => |function| .{ .address = @intFromPtr(function.bound), .kind = .function },
        else => unreachable,
    };
    if (seen.get(key)) |previous| return previous;
    if (depth > 256) return self.fail("native collection nesting exceeds 256", .{});
    switch (value) {
        .list => |list| {
            const result = try lists.allocateList(self, list.items());
            if (list.items().len != 0) try seen.put(self.gpa, key, result) else result.list.owned.owner = self.identity;
            for (result.list.owned.values.items) |*item| item.* = try materializeGraph(self, item.*, seen, depth + 1);
            return result;
        },
        .dict => |dict| {
            const result = try self.arena.allocator().create(types.Dict);
            result.* = .{};
            const output: Value = .{ .dict = result };
            try seen.put(self.gpa, key, output);
            for (dict.entries.keys(), dict.entries.values()) |name, item| {
                try result.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, name), try materializeGraph(self, item, seen, depth + 1));
            }
            return output;
        },
        .record => |record_value| {
            _ = try aggregates.recordDescriptor(self, record_value);
            const result = try self.arena.allocator().create(types.Record);
            result.* = .{ .kind = record_value.kind, .fields = try self.arena.allocator().alloc(Value, record_value.fields.len) };
            const output: Value = .{ .record = result };
            try seen.put(self.gpa, key, output);
            for (result.fields, record_value.fields) |*target, item| target.* = try materializeGraph(self, item, seen, depth + 1);
            return output;
        },
        .function => |function| {
            const bound = function.bound;
            const result = try self.arena.allocator().create(types.Function.Bound);
            result.* = .{ .target = bound.target, .arguments = try self.arena.allocator().alloc(Value, bound.arguments.len), .names = try self.arena.allocator().dupe(?[]const u8, bound.names) };
            for (@constCast(result.names)) |*name| if (name.*) |label| {
                name.* = try self.arena.allocator().dupe(u8, label);
            };
            const output: Value = .{ .function = .{ .bound = result } };
            try seen.put(self.gpa, key, output);
            for (result.arguments, bound.arguments) |*destination, item| destination.* = try materializeGraph(self, item, seen, depth + 1);
            return output;
        },
        else => unreachable,
    }
}

test "read-only templates materialize independently before script mutation" {
    const constants = [_]Value{ types.listView(&.{.{ .int = 1 }}), .{ .int = 2 } };
    const code = [_]I{
        ins(.constant, 0),    ins(.store_global, 0), ins(.constant, 0),    ins(.store_global, 1),
        ins(.load_global, 0), ins(.constant, 1),     ins(.list_append, 0), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "first", "second" }, &.{ .list, .list });
    defer program.deinit();
    for (0..2) |_| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 2), types.sequence(machine.getGlobal("first").?).?.len);
        try std.testing.expectEqual(@as(usize, 1), types.sequence(machine.getGlobal("second").?).?.len);
        try std.testing.expect(machine.getGlobal("first").?.list.owned != machine.getGlobal("second").?.list.owned);
        try std.testing.expectEqual(@as(usize, 1), constants[0].list.items().len);
        try std.testing.expectEqual(@as(i64, 1), constants[0].list.items()[0].int);
    }
}

test "duplicating a template preserves one evaluated list identity" {
    const template: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{ types.listView(template), .{ .int = 2 } };
    const code = [_]I{
        ins(.constant, 0),    ins(.duplicate, 0), ins(.store_global, 0), ins(.store_global, 1),
        ins(.load_global, 0), ins(.constant, 1),  ins(.list_append, 0),  ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "first", "second" }, &.{ .list, .list });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const first = machine.getGlobal("first").?.list.owned;
    const second = machine.getGlobal("second").?.list.owned;
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), second.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), template.len);
}

test "appended nested templates retain child aliases within each isolated execution" {
    const child: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{
        types.listView(&.{ types.listView(child), types.listView(child) }),
        .{ .int = 0 },
        .{ .int = 2 },
    };
    const code = [_]I{
        ins(.make_list, 0),    ins(.store_global, 0), ins(.load_global, 0), ins(.constant, 0),
        ins(.list_append, 0),  ins(.load_global, 0),  ins(.constant, 1),    ins(.index, 0),
        ins(.store_global, 1), ins(.load_global, 1),  ins(.constant, 2),    ins(.list_append, 0),
        ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "rows", "row" }, &.{ .list, .list });
    defer program.deinit();
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    for ([_]*Machine{ &first, &second }) |machine| {
        _ = try machine.execute(&.{});
        const rows = machine.getGlobal("rows").?.list.owned.values.items;
        const row = machine.getGlobal("row").?.list.owned;
        try std.testing.expect(rows[0] == .list and rows[1] == .list);
        try std.testing.expectEqual(row, rows[0].list.owned);
        try std.testing.expectEqual(row, rows[1].list.owned);
        try std.testing.expectEqual(@as(usize, 2), row.values.items.len);
        try std.testing.expectEqual(@as(i64, 2), row.values.items[1].int);
    }
    try std.testing.expect(first.getGlobal("row").?.list.owned != second.getGlobal("row").?.list.owned);
    try std.testing.expectEqual(@as(usize, 2), first.getGlobal("row").?.list.owned.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), child.len);
    try std.testing.expectEqual(@as(i64, 1), child[0].int);
}

test "task results materialize templates like the coordinating store" {
    const constants = [_]Value{types.listView(&.{.{ .int = 1 }})};
    const code = [_]I{ ins(.constant, 0), ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"value"}, &.{.list});
    defer program.deinit();
    var worker = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer worker.deinit();
    const result = try worker.executeTask(.{ .function = 0, .start = 0, .end = 1, .global = 0, .reads = &.{} });
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(worker.identity, result.list.owned.owner.?);
    try lists.appendList(&worker, result, .{ .int = 2 });
    var serial = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer serial.deinit();
    _ = try serial.execute(&.{});
    try std.testing.expectEqual(@as(usize, 2), result.list.owned.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), serial.getGlobal("value").?.list.owned.values.items.len);
    try std.testing.expect(result.list.owned != serial.getGlobal("value").?.list.owned);
    try std.testing.expectEqual(@as(usize, 1), constants[0].list.items().len);
}
