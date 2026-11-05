//! Physical quantities independent of the language, renderer and native ABI.
//! Length magnitudes are millimetres; angular magnitudes are radians.
const std = @import("std");

pub const Error = error{ DimensionMismatch, DimensionOverflow, DivisionByZero, NonFinite, InvalidPower, InvalidQuantity };
pub const Dimension = struct {
    length: i8 = 0,
    angle: i8 = 0,
    pub const scalar: Dimension = .{};
    pub const distance: Dimension = .{ .length = 1 };
    pub const rotation: Dimension = .{ .angle = 1 };
    pub fn eql(a: Dimension, b: Dimension) bool {
        return a.length == b.length and a.angle == b.angle;
    }
    pub fn combine(a: Dimension, b: Dimension, subtract: bool) Error!Dimension {
        const sign: i16 = if (subtract) -1 else 1;
        return .{
            .length = std.math.cast(i8, @as(i16, a.length) + sign * @as(i16, b.length)) orelse return error.DimensionOverflow,
            .angle = std.math.cast(i8, @as(i16, a.angle) + sign * @as(i16, b.angle)) orelse return error.DimensionOverflow,
        };
    }
    pub fn powered(self: Dimension, exponent: i64) Error!Dimension {
        const length = @mulWithOverflow(@as(i64, self.length), exponent);
        const angle = @mulWithOverflow(@as(i64, self.angle), exponent);
        if (length[1] != 0 or angle[1] != 0) return error.DimensionOverflow;
        return .{
            .length = std.math.cast(i8, length[0]) orelse return error.DimensionOverflow,
            .angle = std.math.cast(i8, angle[0]) orelse return error.DimensionOverflow,
        };
    }
};
pub const Quantity = struct {
    value: f64,
    dimension: Dimension = .scalar,
    pub fn checked(self: Quantity) Error!Quantity {
        if (!std.math.isFinite(self.value)) return error.NonFinite;
        return self;
    }
    pub fn negate(self: Quantity) Quantity {
        return .{ .value = -self.value, .dimension = self.dimension };
    }
};
pub const Unit = enum { mm, cm, m, in, pt, bp, texpt, rad, deg, turn };
pub fn unitNamed(name: []const u8) ?Unit {
    return std.meta.stringToEnum(Unit, name);
}
pub fn unitDimension(unit: Unit) Dimension {
    return switch (unit) {
        .rad, .deg, .turn => .rotation,
        else => .distance,
    };
}
pub fn unitScale(unit: Unit) f64 {
    return switch (unit) {
        .mm => 1,
        .cm => 10,
        .m => 1000,
        .in => 25.4,
        .pt, .bp => 25.4 / 72.0,
        .texpt => 25.4 / 72.27,
        .rad => 1,
        .deg => std.math.pi / 180.0,
        .turn => std.math.tau,
    };
}
pub fn applyUnit(value: f64, unit: Unit) Error!Quantity {
    return (Quantity{ .value = value * unitScale(unit), .dimension = unitDimension(unit) }).checked();
}
pub fn fromPoints(points: f64) Quantity {
    return .{ .value = points * (25.4 / 72.0), .dimension = .distance };
}
pub fn toPoints(value: Quantity) Error!f64 {
    if (!value.dimension.eql(.distance)) return error.DimensionMismatch;
    return finite(value.value * (72.0 / 25.4));
}
pub const Arithmetic = enum { add, subtract, multiply, divide, remainder, power };
pub fn arithmetic(op: Arithmetic, a: Quantity, b: Quantity) Error!Quantity {
    _ = try a.checked();
    _ = try b.checked();
    var dimension = a.dimension;
    const value = switch (op) {
        .add, .subtract, .remainder => blk: {
            if (!a.dimension.eql(b.dimension)) return error.DimensionMismatch;
            if (op == .remainder and b.value == 0) return error.DivisionByZero;
            break :blk switch (op) {
                .add => a.value + b.value,
                .subtract => a.value - b.value,
                .remainder => @rem(a.value, b.value),
                else => unreachable,
            };
        },
        .multiply => blk: {
            dimension = try a.dimension.combine(b.dimension, false);
            break :blk a.value * b.value;
        },
        .divide => blk: {
            if (b.value == 0) return error.DivisionByZero;
            dimension = try a.dimension.combine(b.dimension, true);
            break :blk a.value / b.value;
        },
        .power => blk: {
            if (!b.dimension.eql(.scalar)) return error.DimensionMismatch;
            if (!a.dimension.eql(.scalar)) {
                if (b.value != @trunc(b.value) or b.value < -9223372036854775808.0 or b.value >= 9223372036854775808.0) return error.InvalidPower;
                dimension = try a.dimension.powered(@intFromFloat(b.value));
            }
            if (a.value == 0 and b.value < 0) return error.DivisionByZero;
            break :blk std.math.pow(f64, a.value, b.value);
        },
    };
    return (Quantity{ .value = value, .dimension = dimension }).checked();
}
pub fn squareRoot(value: Quantity) Error!Quantity {
    if (@rem(value.dimension.length, 2) != 0 or @rem(value.dimension.angle, 2) != 0) return error.InvalidPower;
    return (Quantity{ .value = @sqrt(value.value), .dimension = .{ .length = @divExact(value.dimension.length, 2), .angle = @divExact(value.dimension.angle, 2) } }).checked();
}
pub fn compare(a: Quantity, b: Quantity) Error!std.math.Order {
    _ = try a.checked();
    _ = try b.checked();
    if (!a.dimension.eql(b.dimension)) return error.DimensionMismatch;
    return std.math.order(a.value, b.value);
}
fn finite(value: f64) Error!f64 {
    if (!std.math.isFinite(value)) return error.NonFinite;
    return value;
}

/// Parse parameter data only: one numeric coefficient, optional pi, and a unit.
/// This deliberately does not evaluate expressions or split an identifier.
pub fn parseLiteral(input: []const u8) Error!Quantity {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) return error.InvalidQuantity;
    var end: usize = 0;
    if (text[end] == '+' or text[end] == '-') end += 1;
    var has_digit = false;
    while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '.')) : (end += 1) has_digit = has_digit or std.ascii.isDigit(text[end]);
    if (has_digit and end < text.len and (text[end] == 'e' or text[end] == 'E')) {
        end += 1;
        if (end < text.len and (text[end] == '+' or text[end] == '-')) end += 1;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    }
    var coefficient: f64 = if (has_digit) std.fmt.parseFloat(f64, text[0..end]) catch return error.InvalidQuantity else if (end == 1 and text[0] == '-') -1 else 1;
    var remaining = std.mem.trim(u8, text[end..], " \t");
    if (std.mem.startsWith(u8, remaining, "pi") and remaining.len > 2 and (remaining[2] == ' ' or remaining[2] == '\t')) {
        coefficient *= std.math.pi;
        remaining = std.mem.trim(u8, remaining[2..], " \t");
    } else if (!has_digit) return error.InvalidQuantity;
    const unit = unitNamed(remaining) orelse return error.InvalidQuantity;
    return applyUnit(coefficient, unit);
}

test "native length and angle conversions preserve dimensions" {
    try std.testing.expectEqual(try applyUnit(1, .cm), try applyUnit(10, .mm));
    try std.testing.expectEqual(try applyUnit(std.math.tau, .rad), try applyUnit(360, .deg));
    try std.testing.expectApproxEqAbs(@as(f64, 72), try toPoints(try applyUnit(1, .in)), 1e-12);
    try std.testing.expectError(error.DimensionMismatch, arithmetic(.add, try applyUnit(1, .cm), try applyUnit(1, .deg)));
    const area = try arithmetic(.multiply, try applyUnit(2, .cm), try applyUnit(3, .mm));
    try std.testing.expectEqual(Dimension{ .length = 2 }, area.dimension);
    try std.testing.expectEqual(@as(f64, 60), area.value);
    try std.testing.expectEqual(@as(f64, 10), (try arithmetic(.divide, try applyUnit(1, .cm), try applyUnit(1, .mm))).value);
    try std.testing.expectError(error.InvalidPower, squareRoot(try applyUnit(1, .mm)));
}
test "quantity parameters are data with intact identifier boundaries" {
    try std.testing.expectEqual(try applyUnit(1, .cm), try parseLiteral("1 cm"));
    try std.testing.expectEqual(try applyUnit(std.math.tau, .rad), try parseLiteral("2pi rad"));
    try std.testing.expectEqual(try applyUnit(std.math.tau, .rad), try parseLiteral("2 pi rad"));
    try std.testing.expectError(error.InvalidQuantity, parseLiteral("2pirad"));
    try std.testing.expectError(error.InvalidQuantity, parseLiteral("1cm+2mm"));
    try std.testing.expectError(error.NonFinite, parseLiteral("1e308m"));
}
