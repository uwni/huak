//! Compile-time evaluation of constant defaults, and which function defaults need a default function.
const std = @import("std");
const ast = @import("../ast.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Value = bc.Value;
const units = @import("../../drawing/units.zig");
const numeric = @import("../numeric.zig");
const modules = @import("modules.zig");
const Compiler = @import("Compiler.zig");
const expressions = @import("expressions.zig");
const namedConstant = expressions.namedConstant;
const ungroup = ast.ungroup;

pub fn constantValue(self: *Compiler, expression_: *ast.Expr, function_parameters: ?[]const ast.Parameter) anyerror!Value {
    return switch (expression_.value) {
        .grouped => |inner| constantValue(self, inner, function_parameters),
        .integer => |value| if (value <= std.math.maxInt(i64)) .{ .int = @intCast(value) } else self.fail(expression_.span, "integer literal is outside int range", .{}),
        .float => |value| .{ .number = value },
        .quantity => |quantity| numeric.valueArithmetic(.multiply, try constantValue(self, quantity.operand, function_parameters), .{ .quantity = try units.applyUnit(1, quantity.unit) }) catch |err| self.fail(expression_.span, "invalid constant quantity: {s}", .{@errorName(err)}),
        .binary => |binary| blk: {
            const op: bc.Op = switch (binary.op) {
                .add => .add,
                .subtract => .subtract,
                .multiply => .multiply,
                .divide => .divide,
                .remainder => .remainder,
                .power => .power,
                else => return self.fail(expression_.span, "parameter default must be a constant literal", .{}),
            };
            break :blk numeric.valueArithmetic(op, try constantValue(self, binary.left, function_parameters), try constantValue(self, binary.right, function_parameters)) catch |err| return self.fail(expression_.span, "invalid constant parameter default: {s}", .{@errorName(err)});
        },
        .boolean => |value| .{ .boolean = value },
        .list => |items| blk: {
            const values = try self.allocator.alloc(Value, items.len);
            for (items, values) |item, *value| value.* = try constantValue(self, item, function_parameters);
            break :blk @import("../types.zig").listView(values);
        },
        .dict => |entries| blk: {
            const dictionary = try self.allocator.create(bc.types.Dict);
            dictionary.* = .{};
            for (entries) |entry| {
                const key = try self.allocator.dupe(u8, entry.key);
                const value = try constantValue(self, entry.value, function_parameters);
                const stored = try dictionary.entries.getOrPut(self.allocator, key);
                if (stored.found_existing) return self.fail(entry.span, "duplicate dictionary key '{s}'", .{key});
                stored.value_ptr.* = value;
            }
            break :blk .{ .dict = dictionary };
        },
        .vector => |v| blk: {
            const x = try constantValue(self, v.x, function_parameters);
            const y = try constantValue(self, v.y, function_parameters);
            break :blk (if (v.z) |z| numeric.makeVector(3, .{ x, y, try constantValue(self, z, function_parameters) }) else numeric.makeVec2(x, y)) catch |err| self.fail(expression_.span, "invalid constant vector: {s}", .{@errorName(err)});
        },
        .string => |value| .{ .string = try self.allocator.dupe(u8, value) },
        .name => |name| blk: {
            if (function_parameters) |parameters| {
                for (parameters) |parameter| if (std.mem.eql(u8, parameter.name, name))
                    return self.fail(expression_.span, "function default cannot reference parameter '{s}'", .{name});
            }
            if (self.environment.unit.resolverAt(expression_.span.start).readable(0, name)) |readable| {
                if (readable == .imported and readable.imported == .member) {
                    const member = readable.imported.member;
                    if (self.build.graph.units.items[member.module].native_namespace) |native| if (builtin.namespaceConstant(native, member.name)) |value| break :blk value;
                }
                if (function_parameters != null) return self.fail(expression_.span, "function default cannot reference nonconstant binding '{s}'", .{name});
            }
            break :blk namedConstant(name) orelse return self.fail(expression_.span, "parameter default must be a constant literal", .{});
        },
        .member => |member| blk: {
            const object = ungroup(member.object);
            var root = object;
            while (root.value == .member) root = ungroup(root.value.member.object);
            if (root.value == .name) if (function_parameters) |parameters| for (parameters) |parameter| if (std.mem.eql(u8, parameter.name, root.value.name))
                return self.fail(expression_.span, "function default cannot reference parameter '{s}'", .{root.value.name});
            if (modules.moduleExpression(self, object)) |index| if (self.build.graph.units.items[index].native_namespace) |native| {
                if (builtin.namespaceConstant(native, member.name)) |value| break :blk value;
            };
            if (object.value == .name) {
                const name = object.value.name;
                const native = if (modules.imported(self, name, expression_.span)) |index|
                    self.build.graph.units.items[index].native_namespace
                else if (self.environment.unit.resolverAt(expression_.span.start).readable(0, name) == null) builtin.Namespace.parse(name) else null;
                if (native) |domain| if (builtin.namespaceConstant(domain, member.name)) |value| break :blk value;
            }
            return self.fail(expression_.span, "parameter default must be a constant literal", .{});
        },
        .unary => |unary| blk: {
            const literal = ungroup(unary.operand);
            if (unary.op == .negate and literal.value == .integer and literal.value.integer == @as(u64, 1) << 63) break :blk .{ .int = std.math.minInt(i64) };
            const operand = try constantValue(self, unary.operand, function_parameters);
            switch (unary.op) {
                .positive => if (operand.valueType().isScalar()) break :blk operand,
                .negate => switch (operand) {
                    .int => |value| {
                        const result = @subWithOverflow(@as(i64, 0), value);
                        if (result[1] == 0) break :blk .{ .int = result[0] };
                    },
                    .number => |value| break :blk .{ .number = -value },
                    .quantity => |value| break :blk .{ .quantity = value.negate() },
                    else => {},
                },
                .logical_not => if (operand == .boolean) break :blk .{ .boolean = !operand.boolean },
            }
            return self.fail(expression_.span, "invalid constant parameter default", .{});
        },
        else => return self.fail(expression_.span, "parameter default must be a constant literal", .{}),
    };
}

pub const DefaultReferences = struct {
    compiler: *Compiler,
    parameters: []const ast.Parameter,
    dynamic: bool = false,
    pub fn enter(self: *DefaultReferences, node: ast.Node) !bool {
        if (node != .expression) return true;
        const expression = node.expression;
        switch (expression.value) {
            .name => |name| {
                for (self.parameters) |param| if (std.mem.eql(u8, param.name, name))
                    return self.compiler.fail(expression.span, "function default cannot reference parameter '{s}'", .{name});
                if (namedConstant(name) == null or self.compiler.environment.unit.resolverAt(expression.span.start).readable(0, name) != null) self.dynamic = true;
            },
            .call, .mixfix_call, .block, .expansion, .typst, .index, .slice => self.dynamic = true,
            else => {},
        }
        return true;
    }
};
