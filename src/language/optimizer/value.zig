//! Exact immutable values shared by folding and data-flow propagation.
const std = @import("std");
const bc = @import("../bytecode.zig");
const numeric = @import("../numeric.zig");
const types = @import("../types.zig");
const units = types.units;
const Value = bc.Value;

pub const Key = struct {
    tag: enum { unit, int, number, quantity, boolean, string, pair },
    a: u64 = 0,
    b: u64 = 0,
    dimension: units.Dimension = .scalar,
    bytes: []const u8 = &.{},
};
pub const KeyContext = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        var result = std.hash.Wyhash.init(@backingInt(key.tag));
        result.update(std.mem.asBytes(&key.a));
        result.update(std.mem.asBytes(&key.b));
        result.update(std.mem.asBytes(&key.dimension));
        result.update(key.bytes);
        return result.final();
    }
    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.tag == b.tag and a.a == b.a and a.b == b.b and a.dimension.eql(b.dimension) and std.mem.eql(u8, a.bytes, b.bytes);
    }
};
pub fn keyOf(value: Value) ?Key {
    return switch (value) {
        .unit => .{ .tag = .unit },
        .int => |v| .{ .tag = .int, .a = @bitCast(v) },
        .number => |v| .{ .tag = .number, .a = @bitCast(v) },
        .quantity => |v| .{ .tag = .quantity, .a = @bitCast(v.value), .dimension = v.dimension },
        .boolean => |v| .{ .tag = .boolean, .a = @intFromBool(v) },
        .string => |v| .{ .tag = .string, .bytes = v },
        .pair => |v| .{ .tag = .pair, .a = @bitCast(v.x), .b = @bitCast(v.y), .dimension = v.dimension },
        .omitted, .list, .dict, .record, .handle, .function, .object => null,
    };
}

pub fn scalarValid(value: Value) bool {
    return switch (value) {
        .unit, .int, .boolean, .string => true,
        .number => |v| std.math.isFinite(v),
        .quantity => |v| std.math.isFinite(v.value),
        .pair => |v| v.isFinite(),
        .omitted, .list, .dict, .record, .handle, .function, .object => false,
    };
}

pub fn unary(op: bc.Op, operand: Value) ?Value {
    if (!scalarValid(operand)) return null;
    return switch (op) {
        .logical_not => if (operand == .boolean) .{ .boolean = !operand.boolean } else null,
        .positive => switch (operand) {
            .int, .number, .quantity, .pair => operand,
            else => null,
        },
        .negate => switch (operand) {
            .int => |v| .{ .int = numeric.integerNegate(v) catch return null },
            .number => |v| .{ .number = -v },
            .quantity => |v| .{ .quantity = v.negate() },
            .pair => |v| .{ .pair = v.scale(-1) },
            else => null,
        },
        else => null,
    };
}

fn ordering(left: Value, right: Value) ?std.math.Order {
    if (!scalarValid(left) or !scalarValid(right)) return null;
    if (left == .quantity or right == .quantity) return units.compare(types.asQuantity(left) catch return null, types.asQuantity(right) catch return null) catch return null;
    return switch (left) {
        .int => |a| switch (right) {
            .int => |b| std.math.order(a, b),
            .number => |b| numeric.compareIntegerFloat(a, b),
            else => null,
        },
        .number => |a| switch (right) {
            .int => |b| numeric.reverseOrder(numeric.compareIntegerFloat(b, a)),
            .number => |b| std.math.order(a, b),
            else => null,
        },
        .string => |a| if (right == .string) std.mem.order(u8, a, right.string) else null,
        else => null,
    };
}

pub fn binary(op: bc.Op, left: Value, right: Value) ?Value {
    if (!scalarValid(left) or !scalarValid(right)) return null;
    switch (op) {
        .equal, .not_equal => {
            const equal = if (left.valueType().isScalar() and right.valueType().isScalar())
                (ordering(left, right) orelse return null) == .eq
            else if (std.meta.activeTag(left) != std.meta.activeTag(right))
                false
            else switch (left) {
                .unit => true,
                .boolean => |a| a == right.boolean,
                .string => |a| std.mem.eql(u8, a, right.string),
                .pair => |a| a.dimension.eql(right.pair.dimension) and a.x == right.pair.x and a.y == right.pair.y,
                else => return null,
            };
            return .{ .boolean = if (op == .equal) equal else !equal };
        },
        .less, .less_equal, .greater, .greater_equal => {
            const order = ordering(left, right) orelse return null;
            return .{ .boolean = switch (op) {
                .less => order == .lt,
                .less_equal => order != .gt,
                .greater => order == .gt,
                .greater_equal => order != .lt,
                else => unreachable,
            } };
        },
        .make_pair => return numeric.makePair(left, right) catch return null,
        .add, .subtract, .multiply, .divide, .remainder, .power => {
            return numeric.valueArithmetic(op, left, right) catch return null;
        },
        else => return null,
    }
}

/// Representation equality keeps signed zero and quantity dimensions distinct.
pub fn exactSame(left: Value, right: Value) bool {
    const a = keyOf(left) orelse return false;
    const b = keyOf(right) orelse return false;
    return (KeyContext{}).eql(a, b);
}
