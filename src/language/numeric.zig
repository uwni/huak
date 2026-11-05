//! Exact scalar arithmetic shared by the executor and compile-time optimizer.
const std = @import("std");
const Op = @import("bytecode.zig").Op;
const types = @import("types.zig");
const Value = types.Value;
const units = types.units;

pub const NumericError = error{ Overflow, DivisionByZero, NonFinite };
pub const ValueError = NumericError || units.Error || error{TypeMismatch};

pub fn makePair(x: Value, y: Value) ValueError!Value {
    var a = try types.asQuantity(x);
    var b = try types.asQuantity(y);
    _ = try a.checked();
    _ = try b.checked();
    // An unqualified zero can be an axis origin in any dimensional vector.
    if (!a.dimension.eql(b.dimension)) {
        if (a.dimension.eql(.scalar) and a.value == 0) a.dimension = b.dimension else if (b.dimension.eql(.scalar) and b.value == 0) b.dimension = a.dimension else return error.DimensionMismatch;
    }
    return .{ .pair = .{ .x = a.value, .y = b.value, .dimension = a.dimension } };
}

pub fn valueArithmetic(op: Op, left: Value, right: Value) ValueError!Value {
    if (left == .pair or right == .pair) {
        if (left == .pair and right == .pair) {
            if (op != .add and op != .subtract) return error.TypeMismatch;
            const a = left.pair;
            const b = right.pair;
            if (!a.dimension.eql(b.dimension)) return error.DimensionMismatch;
            const result: types.Pair = .{
                .x = try floatArithmetic(op, a.x, b.x),
                .y = try floatArithmetic(op, a.y, b.y),
                .dimension = a.dimension,
            };
            return .{ .pair = result };
        }
        if (op != .multiply and !(left == .pair and op == .divide)) return error.TypeMismatch;
        const p = if (left == .pair) left.pair else right.pair;
        const scalar = try types.asQuantity(if (left == .pair) right else left);
        const operation: units.Arithmetic = if (op == .divide) .divide else .multiply;
        const x = try units.arithmetic(operation, .{ .value = p.x, .dimension = p.dimension }, scalar);
        const y = try units.arithmetic(operation, .{ .value = p.y, .dimension = p.dimension }, scalar);
        return .{ .pair = .{ .x = x.value, .y = y.value, .dimension = x.dimension } };
    }
    if (left == .int and right == .int and op != .divide and op != .power) {
        return .{ .int = try switch (op) {
            .add => integerAdd(left.int, right.int),
            .subtract => integerSubtract(left.int, right.int),
            .multiply => integerMultiply(left.int, right.int),
            .remainder => integerRemainder(left.int, right.int),
            else => return error.TypeMismatch,
        } };
    }
    if (left == .quantity or right == .quantity) {
        const operation: units.Arithmetic = switch (op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .remainder => .remainder,
            .power => .power,
            else => return error.TypeMismatch,
        };
        return types.fromQuantity(try units.arithmetic(operation, try types.asQuantity(left), try types.asQuantity(right)));
    }
    const a = try types.asQuantity(left);
    const b = try types.asQuantity(right);
    return .{ .number = try floatArithmetic(op, a.value, b.value) };
}

pub fn integerAdd(a: i64, b: i64) NumericError!i64 {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

pub fn integerSubtract(a: i64, b: i64) NumericError!i64 {
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

pub fn integerMultiply(a: i64, b: i64) NumericError!i64 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

pub fn integerNegate(value: i64) NumericError!i64 {
    return integerSubtract(0, value);
}

pub fn integerRemainder(a: i64, b: i64) NumericError!i64 {
    if (b == 0) return error.DivisionByZero;
    if (b == -1) return 0;
    return @rem(a, b);
}

pub fn floatArithmetic(op: Op, a: f64, b: f64) NumericError!f64 {
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return error.NonFinite;
    if ((op == .divide or op == .remainder) and b == 0) return error.DivisionByZero;
    const result = switch (op) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => a / b,
        .remainder => @rem(a, b),
        .power => std.math.pow(f64, a, b),
        else => unreachable,
    };
    if (!std.math.isFinite(result)) return error.NonFinite;
    return result;
}

/// Compare mathematical values without rounding an integer to f64 first.
pub fn compareIntegerFloat(integer: i64, float: f64) std.math.Order {
    std.debug.assert(std.math.isFinite(float));
    if (float >= 9223372036854775808.0) return .lt;
    if (float < -9223372036854775808.0) return .gt;
    const truncated: i64 = @intFromFloat(float);
    const order = std.math.order(integer, truncated);
    if (order != .eq) return order;
    if (float > @trunc(float)) return .lt;
    if (float < @trunc(float)) return .gt;
    return .eq;
}

pub fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

test "shared floating arithmetic preserves finite results and runtime errors" {
    try std.testing.expectEqual(@as(f64, 0.25), try floatArithmetic(.divide, 1, 4));
    try std.testing.expectError(error.DivisionByZero, floatArithmetic(.divide, 1, -0.0));
    try std.testing.expectError(error.DivisionByZero, floatArithmetic(.remainder, 1, 0));
    try std.testing.expectError(error.NonFinite, floatArithmetic(.multiply, 1e308, 2));
    try std.testing.expectError(error.NonFinite, floatArithmetic(.power, -1, 0.5));
}

test "shared dimensional arithmetic retains vectors quantities and unit ratios" {
    const centimetre: Value = .{ .quantity = try units.applyUnit(1, .cm) };
    const millimetre: Value = .{ .quantity = try units.applyUnit(1, .mm) };
    try std.testing.expectEqual(@as(f64, 10), (try valueArithmetic(.divide, centimetre, millimetre)).number);
    const vector = (try makePair(.{ .int = 0 }, centimetre)).pair;
    try std.testing.expect(vector.dimension.eql(.distance));
    const scaled = (try valueArithmetic(.multiply, .{ .pair = vector }, centimetre)).pair;
    try std.testing.expectEqual(units.Dimension{ .length = 2 }, scaled.dimension);
    try std.testing.expectEqual(@as(f64, 100), scaled.y);
    const normalized = (try valueArithmetic(.divide, .{ .pair = vector }, centimetre)).pair;
    try std.testing.expect(normalized.dimension.eql(.scalar));
    try std.testing.expectEqual(@as(f64, 1), normalized.y);
    try std.testing.expectError(error.DimensionMismatch, makePair(.{ .int = 1 }, centimetre));
    try std.testing.expectError(error.DimensionMismatch, valueArithmetic(.add, centimetre, .{ .int = 1 }));
    try std.testing.expectError(error.DivisionByZero, valueArithmetic(.divide, centimetre, .{ .int = 0 }));
}
