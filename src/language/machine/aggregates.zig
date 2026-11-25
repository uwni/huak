//! Dictionaries, records, shallow copies, and index and field access.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Type = types.Type;
const Machine = @import("../Machine.zig");
const interpreter = @import("interpreter.zig");
const templates = @import("templates.zig");
const validation = @import("validation.zig");
const failures = @import("failures.zig");
const lists = @import("lists.zig");
const Error = Machine.Error;

/// Reads a vector component, a record field or a native field.
pub fn readField(self: *Machine, instruction: bytecode.Instruction) Error!void {
    const name = try interpreter.stringConstant(self, instruction.a);
    const object = try self.pop();
    if (object.vectorField(name)) |component| {
        try self.push(component);
    } else if (object == .record) {
        const index = try recordField(self, object.record, name, instruction.b);
        try self.push(try templates.materialize(self, object.record.fields[index]));
    } else {
        if (self.host.vtable.field == null) return self.fail("unknown field '{s}' of {s}", .{ name, validation.typeName(self, object.valueType()) });
        const result = self.host.field(self.arena.allocator(), object, name) catch |err| return failures.nativeFailure(self, err);
        try validation.checkFiniteExternal(self, result);
        try self.push(try templates.materialize(self, result));
    }
}

/// Writes a field of a record this execution owns.
pub fn writeField(self: *Machine, instruction: bytecode.Instruction) Error!void {
    const name = try interpreter.stringConstant(self, instruction.a);
    const value = try self.pop();
    const object = try self.pop();
    if (object == .record) {
        const index = try recordField(self, object.record, name, instruction.b);
        if (object.record.owner != self.identity) return self.fail("cannot modify a borrowed struct", .{});
        const descriptor = self.program.records[object.record.kind.recordIndex().?];
        object.record.fields[index] = try validation.coerce(self, try templates.materialize(self, value), descriptor.fields[index].kind);
    } else return self.fail("cannot assign field '{s}' of {s}", .{ name, object.valueType().name() });
}

/// A new outer container retains its children's runtime identities.
pub fn copyValue(self: *Machine, input: Value) Error!Value {
    const value = try templates.materialize(self, input);
    try validation.checkFinite(self, value);
    switch (value) {
        .list => |list| {
            const result = try lists.allocateList(self, list.items());
            result.list.owned.owner = self.identity;
            return result;
        },
        .dict => |dict| {
            const result = try self.arena.allocator().create(types.Dict);
            result.* = .{};
            for (dict.entries.keys(), dict.entries.values()) |key, item| try result.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, key), item);
            result.owner = self.identity;
            return .{ .dict = result };
        },
        .record => |record_value| {
            const result = try self.arena.allocator().create(types.Record);
            result.* = .{ .owner = self.identity, .kind = record_value.kind, .fields = try self.arena.allocator().dupe(Value, record_value.fields) };
            return .{ .record = result };
        },
        else => return self.fail("copy requires a list, dictionary or struct", .{}),
    }
}

pub fn makeDict(self: *Machine, entries: []const Value) Error!Value {
    if (entries.len % 2 != 0) return self.fail("invalid bytecode dictionary entries", .{});
    const dict = try self.arena.allocator().create(types.Dict);
    dict.* = .{};
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const key = entries[i];
        if (key != .string) return self.fail("dictionary key must be string", .{});
        if (!std.unicode.utf8ValidateSlice(key.string)) return self.fail("dictionary key must be valid UTF-8", .{});
        if (dict.entries.contains(key.string)) return self.fail("duplicate dictionary key '{s}'", .{key.string});
        const value = try templates.materialize(self, entries[i + 1]);
        try validation.checkFinite(self, value);
        try dict.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, key.string), value);
    }
    dict.owner = self.identity;
    return .{ .dict = dict };
}

pub fn makeRecord(self: *Machine, index: u32, values: []const Value) Error!Value {
    if (index >= self.program.records.len) return self.fail("invalid bytecode struct index", .{});
    const descriptor = self.program.records[index];
    if (values.len != descriptor.fields.len) return self.fail("invalid field count for struct '{s}'", .{descriptor.name});
    const record_value = try self.arena.allocator().create(types.Record);
    record_value.* = .{ .kind = Type.record(index), .fields = try self.arena.allocator().alloc(Value, values.len) };
    for (record_value.fields, values, descriptor.fields) |*target, value, field| target.* = try validation.coerce(self, try templates.materialize(self, value), field.kind);
    record_value.owner = self.identity;
    return .{ .record = record_value };
}

pub fn recordDescriptor(self: *Machine, record_value: *const types.Record) Error!*const bytecode.Record {
    const index = record_value.kind.recordIndex() orelse return self.fail("invalid struct type", .{});
    if (index >= self.program.records.len) return self.fail("invalid struct type index", .{});
    const descriptor = &self.program.records[index];
    if (record_value.fields.len != descriptor.fields.len) return self.fail("invalid field count for struct '{s}'", .{descriptor.name});
    return descriptor;
}

fn recordField(self: *Machine, record_value: *const types.Record, name: []const u8, slot: u32) Error!usize {
    const descriptor = try recordDescriptor(self, record_value);
    if (slot != 0) {
        const index = slot - 1;
        if (index >= descriptor.fields.len or !std.mem.eql(u8, descriptor.fields[index].name, name)) return self.fail("invalid bytecode struct field slot", .{});
        return index;
    }
    for (descriptor.fields, 0..) |field, index| if (std.mem.eql(u8, field.name, name)) return index;
    return self.fail("unknown field '{s}' of struct '{s}'", .{ name, descriptor.name });
}

pub fn readIndex(self: *Machine, object: Value, key: Value) Error!Value {
    if (object == .dict) {
        if (key != .string) return self.fail("dictionary key must be string", .{});
        const value = object.dict.entries.get(key.string) orelse return self.fail("dictionary has no key '{s}'", .{key.string});
        return templates.materialize(self, value);
    }
    const items = types.sequence(object) orelse return self.fail("indexing requires a list or dictionary", .{});
    if (key != .int) return self.fail("list index must be int", .{});
    return templates.materialize(self, items[try lists.listIndex(self, key.int, items.len)]);
}

pub fn setIndex(self: *Machine, object: Value, key: Value, input: Value) Error!void {
    if (object == .dict) {
        if (object.dict.owner != self.identity) return self.fail("cannot modify a borrowed dictionary", .{});
        if (key != .string) return self.fail("dictionary key must be string", .{});
        if (!std.unicode.utf8ValidateSlice(key.string)) return self.fail("dictionary key must be valid UTF-8", .{});
        const value = try templates.materialize(self, input);
        try validation.checkFinite(self, value);
        const owned_key = if (object.dict.entries.contains(key.string)) key.string else try self.arena.allocator().dupe(u8, key.string);
        const entry = try object.dict.entries.getOrPut(self.arena.allocator(), owned_key);
        entry.value_ptr.* = value;
        return;
    }
    const list = try lists.mutableList(self, object);
    if (key != .int) return self.fail("list index must be int", .{});
    const index = try lists.listIndex(self, key.int, list.items.len);
    const value = try templates.materialize(self, input);
    try validation.checkFinite(self, value);
    list.items[index] = value;
}
