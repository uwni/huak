//! Exact scalar arithmetic shared by the executor and compile-time optimizer.
const std = @import("std");
const Op = @import("bytecode.zig").Op;
const types = @import("types.zig");
const Value = types.Value;
const units = types.units;

pub const NumericError = error{ Overflow, DivisionByZero, NonFinite };
pub const ValueError = NumericError || units.Error || error{TypeMismatch};

pub fn makeVector(comptime size: usize, coordinates: [size]Value) ValueError!Value {
    var dimension: ?units.Dimension = null;
    var components: [size]f64 = undefined;
    for (coordinates, &components) |value, *component| {
        const q = try (try types.asQuantity(value)).checked();
        component.* = q.value;
        if (q.value == 0 and q.dimension.eql(.scalar)) continue;
        if (dimension) |d| if (!d.eql(q.dimension)) return error.DimensionMismatch;
        dimension = q.dimension;
    }
    const d = dimension orelse units.Dimension.scalar;
    return if (size == 2) .{ .vec2 = .{ .x = components[0], .y = components[1], .dimension = d } } else .{ .vec3 = .{ .x = components[0], .y = components[1], .z = components[2], .dimension = d } };
}

pub fn makeVec2(x: Value, y: Value) ValueError!Value {
    return makeVector(2, .{ x, y });
}

pub fn valueArithmetic(op: Op, left: Value, right: Value) ValueError!Value {
    inline for (.{ "vec2", "vec3" }) |name| {
        const tag = @field(std.meta.Tag(Value), name);
        if (left == tag or right == tag) {
            const both = left == tag and right == tag;
            var result = @field(if (left == tag) left else right, name);
            if (both) {
                if (op != .add and op != .subtract) return error.TypeMismatch;
                const other = @field(right, name);
                if (!result.dimension.eql(other.dimension)) return error.DimensionMismatch;
                inline for (.{ "x", "y", "z" }) |axis| if (@hasField(@TypeOf(result), axis)) {
                    @field(result, axis) = try floatArithmetic(op, @field(result, axis), @field(other, axis));
                };
            } else {
                if (op != .multiply and !(left == tag and op == .divide)) return error.TypeMismatch;
                const scalar = try types.asQuantity(if (left == tag) right else left);
                const dimension = result.dimension;
                inline for (.{ "x", "y", "z" }) |axis| if (@hasField(@TypeOf(result), axis)) {
                    const q = try units.arithmetic(if (op == .divide) .divide else .multiply, .{ .value = @field(result, axis), .dimension = dimension }, scalar);
                    @field(result, axis) = q.value;
                    result.dimension = q.dimension;
                };
            }
            return @unionInit(Value, name, result);
        }
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
    const vector = (try makeVec2(.{ .int = 0 }, centimetre)).vec2;
    try std.testing.expect(vector.dimension.eql(.distance));
    const scaled = (try valueArithmetic(.multiply, .{ .vec2 = vector }, centimetre)).vec2;
    try std.testing.expectEqual(units.Dimension{ .length = 2 }, scaled.dimension);
    try std.testing.expectEqual(@as(f64, 100), scaled.y);
    const normalized = (try valueArithmetic(.divide, .{ .vec2 = vector }, centimetre)).vec2;
    try std.testing.expect(normalized.dimension.eql(.scalar));
    try std.testing.expectEqual(@as(f64, 1), normalized.y);
    try std.testing.expectError(error.DimensionMismatch, makeVec2(.{ .int = 1 }, centimetre));
    try std.testing.expectError(error.DimensionMismatch, valueArithmetic(.add, centimetre, .{ .int = 1 }));
    try std.testing.expectError(error.DivisionByZero, valueArithmetic(.divide, centimetre, .{ .int = 0 }));
}
