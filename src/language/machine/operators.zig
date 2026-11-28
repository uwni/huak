//! Arithmetic, unary operators, ordering and structural equality.
const std = @import("std");
const numeric = @import("../numeric.zig");
const units = @import("../../drawing/units.zig");
const integerNegate = numeric.integerNegate;
const compareIntegerFloat = numeric.compareIntegerFloat;
const reverseOrder = numeric.reverseOrder;
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const validation = @import("validation.zig");
const failures = @import("failures.zig");
const templates = @import("templates.zig");
const testing = @import("testing.zig");
const Error = Machine.Error;
const testProgram = testing.testProgram;
const ins = testing.ins;

/// Unary `+`: checks that the operand is a number, vector or linear value.
pub fn positive(self: *Machine) Error!void {
    const value = try self.pop();
    switch (value) {
        .int, .number, .quantity, .vec2, .vec3 => {},
        .handle => |handle| if (handle.kind != .variable and handle.kind != .linear) {
            return self.fail("cannot apply unary + to {s}", .{validation.typeName(self, handle.kind)});
        },
        else => return self.fail("cannot apply unary + to {s}", .{validation.typeName(self, value.valueType())}),
    }
    try validation.checkFinite(self, value);
    try self.push(value);
}

/// Unary `-`.
pub fn negate(self: *Machine) Error!void {
    const value = try self.pop();
    const result: Value = switch (value) {
        .int => |integer| .{ .int = integerNegate(integer) catch return self.fail("integer overflow", .{}) },
        .number => |numeric_value| .{ .number = -numeric_value },
        .quantity => |quantity| .{ .quantity = quantity.negate() },
        .vec2 => |pair| .{ .vec2 = pair.scale(-1) },
        .vec3 => |pair| .{ .vec3 = pair.scale(-1) },
        .handle => try nativeBinary(self, .subtract, .{ .int = 0 }, value),
        else => return self.fail("cannot negate {s}", .{validation.typeName(self, value.valueType())}),
    };
    try validation.checkFinite(self, result);
    try self.push(result);
}

pub fn arithmetic(self: *Machine, op: bytecode.Op, left: Value, right: Value) Error!Value {
    if (left == .handle or right == .handle) return nativeBinary(self, op, left, right);
    if (op == .add and left == .string and right == .string) {
        const len = std.math.add(usize, left.string.len, right.string.len) catch return error.OutOfMemory;
        const result = try self.arena.allocator().alloc(u8, len);
        @memcpy(result[0..left.string.len], left.string);
        @memcpy(result[left.string.len..], right.string);
        return .{ .string = result };
    }
    return numeric.valueArithmetic(op, left, right) catch |err| return failures.numericFailure(self, err);
}

fn nativeBinary(self: *Machine, op: bytecode.Op, left: Value, right: Value) Error!Value {
    if (self.host.vtable.binary == null) return self.fail("operator {s} requires a host for these operands", .{@tagName(op)});
    const result = self.host.binary(self.arena.allocator(), op, left, right) catch |err| return failures.nativeFailure(self, err);
    try validation.checkFiniteExternal(self, result);
    return templates.materialize(self, result);
}

pub fn compare(self: *Machine, left: Value, right: Value) Error!std.math.Order {
    try validation.checkFinite(self, left);
    try validation.checkFinite(self, right);
    if (left == .quantity or right == .quantity) return units.compare(types.asQuantity(left) catch return self.fail("comparison requires compatible values", .{}), types.asQuantity(right) catch return self.fail("comparison requires compatible values", .{})) catch |err| return failures.numericFailure(self, err);
    return switch (left) {
        .int => |integer| switch (right) {
            .int => |other| std.math.order(integer, other),
            .number => |float| compareIntegerFloat(integer, float),
            else => self.fail("comparison requires compatible values", .{}),
        },
        .number => |float| switch (right) {
            .int => |integer| reverseOrder(compareIntegerFloat(integer, float)),
            .number => |other| std.math.order(float, other),
            else => self.fail("comparison requires compatible values", .{}),
        },
        .string => |string| if (right == .string) std.mem.order(u8, string, right.string) else self.fail("comparison requires compatible values", .{}),
        else => self.fail("ordering requires numbers or strings", .{}),
    };
}

pub fn valuesEqual(self: *Machine, left: Value, right: Value) Error!bool {
    const Comparison = struct { left: Value, right: Value };
    const SequencePair = struct { left: usize, right: usize, length: usize, kind: enum { list, dict, record } = .list };
    var pending: std.ArrayList(Comparison) = .empty;
    defer pending.deinit(self.gpa);
    var seen: std.AutoHashMapUnmanaged(SequencePair, void) = .empty;
    defer seen.deinit(self.gpa);
    try validation.checkFinite(self, left);
    try validation.checkFinite(self, right);
    try pending.append(self.gpa, .{ .left = left, .right = right });
    while (pending.pop()) |comparison| {
        try self.tick();
        const a = comparison.left;
        const b = comparison.right;
        try validation.checkFiniteLeaf(self, a);
        try validation.checkFiniteLeaf(self, b);
        if (a.valueType().isScalar() and b.valueType().isScalar()) {
            if (try compare(self, a, b) != .eq) return false;
            continue;
        }
        if (a == .dict) {
            if (b != .dict or a.dict.entries.count() != b.dict.entries.count()) return false;
            const pair: SequencePair = .{ .left = @intFromPtr(a.dict), .right = @intFromPtr(b.dict), .length = a.dict.entries.count(), .kind = .dict };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (a.dict.entries.keys(), a.dict.entries.values()) |key, value| {
                const other = b.dict.entries.get(key) orelse return false;
                try pending.append(self.gpa, .{ .left = value, .right = other });
            }
            continue;
        }
        if (a == .record) {
            if (b != .record or a.record.kind != b.record.kind) return false;
            const pair: SequencePair = .{ .left = @intFromPtr(a.record), .right = @intFromPtr(b.record), .length = a.record.fields.len, .kind = .record };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (a.record.fields, b.record.fields) |value, other| try pending.append(self.gpa, .{ .left = value, .right = other });
            continue;
        }
        if (types.sequence(a)) |items| {
            const other = types.sequence(b) orelse return false;
            if (items.len != other.len) return false;
            if (items.len == 0) continue;
            const pair: SequencePair = .{ .left = @intFromPtr(items.ptr), .right = @intFromPtr(other.ptr), .length = items.len };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (items, other) |a_value, b_value| try pending.append(self.gpa, .{ .left = a_value, .right = b_value });
            continue;
        }
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .unit => {},
            .omitted => unreachable,
            .int, .number, .quantity => unreachable,
            .boolean => |boolean_value| if (boolean_value != b.boolean) {
                return false;
            },
            .string => |string| if (!std.mem.eql(u8, string, b.string)) {
                return false;
            },
            inline .vec2, .vec3 => |v, tag| if (!std.meta.eql(v, @field(b, @tagName(tag)))) return false,
            .handle => |handle| if (handle.kind != b.handle.kind or handle.index != b.handle.index) {
                return false;
            },
            .function => |fun| if (!std.meta.eql(fun, b.function)) return false,
            .object => |object| if (!std.meta.eql(object, b.object)) return false,
            .list, .dict, .record => unreachable,
        }
    }
    return true;
}

test "arithmetic lists pairs and finite errors execute without a native library" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{
        ins(.constant, 0), ins(.constant, 1), ins(.make_vec2, 0), ins(.constant, 1), ins(.multiply, 0), ins(.store_global, 0),
        ins(.constant, 2), ins(.constant, 1), ins(.make_list, 2), ins(.constant, 3), ins(.index, 0),    ins(.store_global, 1),
        ins(.halt, 0),
    }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 3 }, .{ .int = 2 }, .{ .string = "first" }, .{ .int = 0 } }, &.{ "point", "first" }, &.{ .vec2, .string });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const point = machine.getGlobal("point").?.vec2;
    try std.testing.expectEqual(@as(f64, 6), point.x);
    try std.testing.expectEqual(@as(f64, 4), point.y);
    try std.testing.expectEqualStrings("first", machine.getGlobal("first").?.string);
    try std.testing.expectError(error.RuntimeFailed, arithmetic(&machine, .multiply, .{ .number = 1e308 }, .{ .number = 1e308 }));
}

test "list equality terminates on cycles and native sequences become owned lists" {
    const compiler = @import("../compiler.zig");
    const Native = struct {
        fn call(_: ?*anyopaque, allocator: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            if (id != .bounds) return error.UnexpectedBuiltin;
            const shared = try allocator.dupe(Value, &.{.{ .int = 1 }});
            const rows = try allocator.dupe(Value, &.{ types.listView(shared), types.listView(shared) });
            return types.listView(rows);
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\import object.bounds
            \\a:=[];a+=[a]
            \\b:=[];b+=[b]
            \\same:=a==b
            \\different:=a==[[]]
            \\rows:=bounds(0)
            \\row:=rows[0]
            \\row+=2
            \\shared:=len(rows[1])
            \\contents:=rows==[[1,2],[1,2]]
        , "list-graphs.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try Machine.init(std.testing.allocator, &program, .{ .vtable = &.{ .callBuiltin = Native.call } }, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            try std.testing.expect(machine.getGlobal("same").?.boolean);
            try std.testing.expect(!machine.getGlobal("different").?.boolean);
            try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("shared").?.int);
            try std.testing.expect(machine.getGlobal("contents").?.boolean);
            try std.testing.expectEqual(machine.identity, machine.getGlobal("rows").?.list.owned.owner);
        }
    }
}

test "unary positive preserves numbers pairs and linear handles but checks dynamic types" {
    const accepted = [_]Value{
        .{ .int = 7 },                                     .{ .number = 2.5 },                              .{ .vec2 = .{ .x = 1, .y = 2 } },
        .{ .handle = .{ .kind = .variable, .index = 0 } }, .{ .handle = .{ .kind = .linear, .index = 1 } },
    };
    for (accepted) |value| {
        var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.constant, 0), ins(.positive, 0), ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{value}, &.{"result"}, &.{value.valueType()});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expect(try valuesEqual(&machine, value, machine.getGlobal("result").?));
    }
    const compiler = @import("../compiler.zig");
    const rejected = [_][]const u8{ "v:=[true][0];result:=+v", "v:=[\"text\"][0];result:=+v", "v:=[[1]][0];result:=+v" };
    for (rejected) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "positive.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.find(u8, machine.failure.?.text(), "unary +") != null);
    }
}
