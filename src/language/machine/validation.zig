//! Checking values against declared types: finite and ownership validation of graphs, coercion, typed reads and parameter text.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Type = types.Type;
const Machine = @import("../Machine.zig");
const aggregates = @import("aggregates.zig");
const templates = @import("templates.zig");
const Error = Machine.Error;
const SequenceKey = templates.SequenceKey;

pub fn parseParameter(self: *Machine, parameter: bytecode.Parameter, text: []const u8) Error!Value {
    return switch (parameter.kind) {
        .int => .{ .int = std.fmt.parseInt(i64, text, 10) catch return self.fail("parameter '{s}' must be int", .{parameter.name}) },
        .number => blk: {
            const numeric_value = std.fmt.parseFloat(f64, text) catch return self.fail("parameter '{s}' must be float", .{parameter.name});
            if (!std.math.isFinite(numeric_value)) return self.fail("parameter '{s}' must be finite", .{parameter.name});
            break :blk .{ .number = numeric_value };
        },
        .length, .angle, .quantity => blk: {
            const value: Value = .{ .quantity = units.parseLiteral(text) catch return self.fail("parameter '{s}' requires a finite quantity with a unit", .{parameter.name}) };
            break :blk try coerce(self, value, parameter.kind);
        },
        .boolean => if (std.mem.eql(u8, text, "true")) .{ .boolean = true } else if (std.mem.eql(u8, text, "false")) .{ .boolean = false } else return self.fail("parameter '{s}' must be true or false", .{parameter.name}),
        .string => blk: {
            if (!std.unicode.utf8ValidateSlice(text)) return self.fail("parameter '{s}' must be valid UTF-8", .{parameter.name});
            break :blk .{ .string = try self.arena.allocator().dupe(u8, text) };
        },
        else => return self.fail("parameter '{s}' has an unsupported CLI type", .{parameter.name}),
    };
}

pub fn coerce(self: *Machine, value: Value, expected: Type) Error!Value {
    const actual = value.valueType();
    if (!Type.accepts(expected, actual))
        return self.fail("expected {s}, received {s}", .{ typeName(self, expected), typeName(self, actual) });
    try checkFinite(self, value);
    return convertValidated(self, value, expected);
}

/// Coerces a value whose reachable graph has already been validated.
pub fn coerceValidated(self: *Machine, value: Value, expected: Type) Error!Value {
    const actual = value.valueType();
    if (!Type.accepts(expected, actual))
        return self.fail("expected {s}, received {s}", .{ typeName(self, expected), typeName(self, actual) });
    return convertValidated(self, value, expected);
}

fn convertValidated(self: *Machine, value: Value, expected: Type) Error!Value {
    if (expected == .number and value == .int) return .{ .number = @floatFromInt(value.int) };
    if ((expected == .length or expected == .angle) and (value == .int or value == .number)) {
        const magnitude = try number(self, value);
        return .{ .quantity = if (expected == .length) units.fromPoints(magnitude) else .{ .value = magnitude, .dimension = .rotation } };
    }
    return value;
}

pub fn typeName(self: *const Machine, kind: Type) []const u8 {
    if (kind.recordIndex()) |index| if (index < self.program.records.len) return self.program.records[index].name;
    return kind.name();
}

pub fn checkFinite(self: *Machine, value: Value) Error!void {
    return checkFiniteGraph(self, value, false);
}

/// Ownership is a validation invariant, not a shortcut at an FFI boundary.
/// Validate Host results and Program descriptors regardless of their owner.
pub fn checkFiniteExternal(self: *Machine, value: Value) Error!void {
    return checkFiniteGraph(self, value, true);
}

fn ownsValidated(self: *const Machine, value: Value) bool {
    return switch (value) {
        .list => |list| list == .owned and list.owned.owner == self.identity,
        .dict => |dict| dict.owner == self.identity,
        .record => |record_value| record_value.owner == self.identity,
        .function => |function| function == .bound and function.bound.owner == self.identity,
        else => false,
    };
}

fn isContainer(value: Value) bool {
    return switch (value) {
        .list, .dict, .record => true,
        .function => |function| function == .bound,
        else => false,
    };
}

fn checkChildren(self: *Machine, pending: *std.ArrayList(Value), items: []const Value, external: bool) Error!void {
    for (items) |child| {
        if (isContainer(child)) {
            if (child == .list and child.list.items().len == 0) continue;
            if (external or !ownsValidated(self, child)) try pending.append(self.gpa, child);
        } else try checkFiniteLeaf(self, child);
    }
}

fn checkFiniteGraph(self: *Machine, value: Value, external: bool) Error!void {
    if (!isContainer(value)) return checkFiniteLeaf(self, value);
    if (!external and ownsValidated(self, value)) return;
    if (value == .list and value.list.items().len == 0) return;
    var pending: std.ArrayList(Value) = .empty;
    defer pending.deinit(self.gpa);
    var seen: std.AutoHashMapUnmanaged(SequenceKey, void) = .empty;
    defer seen.deinit(self.gpa);
    try pending.append(self.gpa, value);
    while (pending.pop()) |item| {
        const key: SequenceKey = switch (item) {
            .list => |list| switch (list) {
                .view => |items| .{ .address = @intFromPtr(items.ptr), .length = items.len },
                .owned => |storage| .{ .address = @intFromPtr(storage), .kind = .owned_list },
            },
            .dict => |dict| .{ .address = @intFromPtr(dict), .kind = .dict },
            .record => |record_value| .{ .address = @intFromPtr(record_value), .kind = .record },
            .function => |function| .{ .address = @intFromPtr(function.bound), .kind = .function },
            else => unreachable,
        };
        const visited = try seen.getOrPut(self.gpa, key);
        if (visited.found_existing) continue;
        switch (item) {
            .list => |list| try checkChildren(self, &pending, list.items(), external),
            .dict => |dict| {
                for (dict.entries.keys()) |name| if (!std.unicode.utf8ValidateSlice(name)) return self.fail("dictionary key must be valid UTF-8", .{});
                try checkChildren(self, &pending, dict.entries.values(), external);
            },
            .record => |record_value| {
                const descriptor = try aggregates.recordDescriptor(self, record_value);
                for (descriptor.fields, record_value.fields) |field, field_value| {
                    if (!Type.accepts(field.kind, field_value.valueType())) return self.fail("field '{s}' expects {s}, received {s}", .{ field.name, typeName(self, field.kind), typeName(self, field_value.valueType()) });
                }
                try checkChildren(self, &pending, record_value.fields, external);
            },
            .function => |function| {
                const bound = function.bound;
                if (bound.names.len != bound.arguments.len) return self.fail("invalid bound function argument names", .{});
                try checkChildren(self, &pending, bound.arguments, external);
            },
            else => unreachable,
        }
    }
}

pub fn checkFiniteLeaf(self: *Machine, value: Value) Error!void {
    switch (value) {
        .omitted => return self.fail("omitted argument marker cannot be used as a value", .{}),
        .number => |numeric_value| if (!std.math.isFinite(numeric_value)) {
            return self.fail("arithmetic produced a non-finite value", .{});
        },
        .quantity => |quantity| if (!std.math.isFinite(quantity.value)) {
            return self.fail("arithmetic produced a non-finite quantity", .{});
        },
        inline .vec2, .vec3 => |pair| if (!pair.isFinite()) {
            return self.fail("arithmetic produced a non-finite vector", .{});
        },
        .handle => |handle| switch (handle.kind) {
            .path, .shape, .color, .gradient, .pen, .transform, .solver, .variable, .linear, .solution, .text, .measure, .typst_module, .anchor => {},
            else => return self.fail("host returned an invalid native handle type", .{}),
        },
        else => {},
    }
}

pub fn number(self: *Machine, value: Value) Error!f64 {
    const result = switch (value) {
        .int => |integer| @as(f64, @floatFromInt(integer)),
        .number => |float| float,
        else => return self.fail("expected a number, received {s}", .{typeName(self, value.valueType())}),
    };
    if (!std.math.isFinite(result)) return self.fail("number must be finite", .{});
    return result;
}

pub fn boolean(self: *Machine, value: Value) Error!bool {
    return switch (value) {
        .boolean => |result| result,
        else => self.fail("condition must be bool", .{}),
    };
}
