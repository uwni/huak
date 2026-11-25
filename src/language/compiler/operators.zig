//! Unary and binary operators, and the dimension and operand-type rules.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Span = source.Span;
const units = @import("../../drawing/units.zig");
const expressions = @import("expressions.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const ungroup = ast.ungroup;

/// Unary and binary operators, `and` and `or` short-circuiting.
pub fn compileOperator(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
    const span = expression_.span;
    switch (expression_.value) {
        .unary => |unary| {
            const literal = ungroup(unary.operand);
            if (unary.op == .negate and literal.value == .integer and literal.value.integer == @as(u64, 1) << 63) {
                try context.constant(.{ .int = std.math.minInt(i64) }, span);
                return .int;
            }
            const kind = try expressions.compileExpression(self, context, unary.operand);
            switch (unary.op) {
                .logical_not => {
                    try self.require(.boolean, kind, span);
                    _ = try context.emit(.logical_not, 0, 0, span);
                    return .boolean;
                },
                .positive, .negate => {
                    if (!kind.isVector() and kind != .variable and kind != .linear) try self.require(.scalar, kind, span);
                    _ = try context.emit(if (unary.op == .negate) .negate else .positive, 0, 0, span);
                    return if (unary.op == .negate and kind == .variable) .linear else kind;
                },
            }
        },
        .binary => |binary_| {
            const left = try expressions.compileExpression(self, context, binary_.left);
            if (binary_.op == .logical_and or binary_.op == .logical_or) {
                try self.require(.boolean, left, binary_.left.span);
                _ = try context.emit(.duplicate, 0, 0, span);
                if (binary_.op == .logical_or) _ = try context.emit(.logical_not, 0, 0, span);
                const skip = try context.emit(.jump_if_false, 0, 0, span);
                _ = try context.emit(.pop, 0, 0, span);
                try self.require(.boolean, try expressions.compileExpression(self, context, binary_.right), binary_.right.span);
                try context.patch(skip, context.code.items.len);
                return .boolean;
            }
            const right = try expressions.compileExpression(self, context, binary_.right);
            const result = try binaryType(self, binary_.op, left, right, span);
            _ = try context.emit(switch (binary_.op) {
                .add => .add,
                .subtract => .subtract,
                .multiply => .multiply,
                .divide => .divide,
                .remainder => .remainder,
                .power => .power,
                .equal => .equal,
                .not_equal => .not_equal,
                .less => .less,
                .less_equal => .less_equal,
                .greater => .greater,
                .greater_equal => .greater_equal,
                .logical_and, .logical_or => unreachable,
            }, 0, 0, span);
            return result;
        },
        else => unreachable,
    }
}

pub fn binaryType(self: *Compiler, operation: ast.Binary, left: Type, right: Type, span: Span) !Type {
    const comparison = switch (operation) {
        .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
        else => false,
    };
    if (left.isScalar() and right.isScalar()) {
        const left_dimension = scalarDimension(left);
        const right_dimension = scalarDimension(right);
        if (left_dimension != null and right_dimension != null) {
            const a = left_dimension.?;
            const b = right_dimension.?;
            if (comparison or operation == .add or operation == .subtract or operation == .remainder) {
                if (!a.eql(b)) return self.fail(span, "incompatible dimensions: {s} and {s}", .{ self.typeName(left), self.typeName(right) });
            }
            if (comparison) return .boolean;
            if (!a.eql(.scalar) or !b.eql(.scalar)) {
                return switch (operation) {
                    .add, .subtract, .remainder => dimensionType(a),
                    .multiply, .divide => dimensionType(try a.combine(b, operation == .divide)),
                    .power => if (b.eql(.scalar)) .scalar else self.fail(span, "an exponent must be dimensionless", .{}),
                    else => unreachable,
                };
            }
        } else return if (comparison) .boolean else .scalar;
    }
    if (operation == .equal or operation == .not_equal) return .boolean;
    if (operation == .less or operation == .less_equal or operation == .greater or operation == .greater_equal) {
        if ((left == .string or left == .any) and (right == .string or right == .any)) return .boolean;
        if ((left == .any and right.isScalar()) or (right == .any and left.isScalar())) return .boolean;
        try self.require(.number, left, span);
        try self.require(.number, right, span);
        return .boolean;
    }
    if (left == .any or right == .any) return .any;
    const left_number = left == .int or left == .number;
    const right_number = right == .int or right == .number;
    if (left_number and right_number) return if (operation == .divide or operation == .power or left == .number or right == .number) .number else .int;
    if (operation == .add and left == .string and right == .string) return .string;
    if ((operation == .add or operation == .subtract) and left.isVector() and left == right) return left;
    if ((operation == .multiply or operation == .divide) and left.isVector() and right.isScalar()) return left;
    if (operation == .multiply and left.isScalar() and right.isVector()) return right;
    const left_linear = left == .variable or left == .linear;
    const right_linear = right == .variable or right == .linear;
    if ((operation == .add or operation == .subtract) and (left_linear or left_number) and (right_linear or right_number)) return .linear;
    if ((operation == .multiply and ((left_linear and right_number) or (left_number and right_linear))) or (operation == .divide and left_linear and right_number)) return .linear;
    return self.fail(span, "operator {s} does not accept {s} and {s}", .{ @tagName(operation), self.typeName(left), self.typeName(right) });
}

pub fn scalarDimension(kind: Type) ?units.Dimension {
    return switch (kind) {
        .int, .number => .scalar,
        .length => .distance,
        .angle => .rotation,
        else => null,
    };
}

fn dimensionType(dimension: units.Dimension) Type {
    if (dimension.eql(.scalar)) return .number;
    if (dimension.eql(.distance)) return .length;
    if (dimension.eql(.rotation)) return .angle;
    return .quantity;
}
