//! Expressions: the dispatcher, literals, names, member, index and slice access, and path literals.
const std = @import("std");
const ast = @import("../ast.zig");
const ungroup = ast.ungroup;
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const precedence = @import("../precedence.zig");
const units = @import("../../drawing/units.zig");
const operators = @import("operators.zig");
const calls = @import("calls.zig");
const blocks = @import("blocks.zig");
const typst = @import("typst.zig");
const modules = @import("modules.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const scalarDimension = operators.scalarDimension;

pub fn compileExpression(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
    self.expression_depth += 1;
    defer self.expression_depth -= 1;
    if (self.expression_depth > ast.max_depth) return self.fail(expression_.span, "expression tree exceeds compilation depth {d}", .{ast.max_depth});
    if (precedence.hasCustom(expression_)) {
        const resolved = precedence.resolve(self.build.syntax_allocator, &self.build.precedence, expression_, self, self.diagnostic) catch |err| {
            if (self.diagnostic.*) |*detail| if (detail.fileName() == null) detail.setSource(self.environment.unit.name, self.environment.unit.source_text);
            return err;
        };
        return compileExpression(self, context, resolved);
    }
    const span = expression_.span;
    switch (expression_.value) {
        .grouped => |inner| return compileExpression(self, context, inner),
        .mixfix_call, .path_join => unreachable,
        .path_literal => return compilePathLiteral(self, context, expression_),
        .cycle => return self.fail(span, "cycle is only valid at the end of a path literal", .{}),
        .integer, .float, .quantity, .boolean, .string, .list, .dict, .vector => return compileLiteral(self, context, expression_),
        .name => |name| return compileName(self, context, name, span),
        .unary, .binary => return operators.compileOperator(self, context, expression_),
        .call => |call| return calls.compileCallExpression(self, context, call, span),
        .index, .slice, .member => return compileAccess(self, context, expression_),
        .expansion => |invocation| return blocks.compileExpansion(self, context, invocation, span),
        .block => |body| return blocks.compileBlock(self, context, body, span),
        .typst => |block| return typst.compileTypstBlock(self, context, block, span),
        .typst_module => |block| return typst.compileTypstModule(self, context, block, span, null),
    }
}

/// Literals: numbers, quantities, booleans, strings, lists, dictionaries and vectors.
pub fn compileLiteral(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
    const span = expression_.span;
    switch (expression_.value) {
        .integer => |value| {
            if (value > std.math.maxInt(i64)) return self.fail(span, "integer literal is outside int range", .{});
            try context.constant(.{ .int = @intCast(value) }, span);
            return .int;
        },
        .float => |value| {
            try context.constant(.{ .number = value }, span);
            return .number;
        },
        .quantity => |quantity| {
            const operand = try compileExpression(self, context, quantity.operand);
            try self.require(.scalar, operand, quantity.operand.span);
            const unit = Value{ .quantity = try units.applyUnit(1, quantity.unit) };
            try context.constant(unit, span);
            const result = try operators.binaryType(self, .multiply, operand, unit.valueType(), span);
            _ = try context.emit(.multiply, 0, 0, span);
            return result;
        },
        .boolean => |value| {
            try context.constant(.{ .boolean = value }, span);
            return .boolean;
        },
        .string => |value| {
            try context.constant(.{ .string = try self.allocator.dupe(u8, value) }, span);
            return .string;
        },
        .list => |values| {
            for (values) |value| _ = try compileExpression(self, context, value);
            _ = try context.emit(.make_list, try self.narrow(values.len, span), 0, span);
            return .list;
        },
        .dict => |entries| {
            for (entries) |entry| {
                try context.constant(.{ .string = try self.allocator.dupe(u8, entry.key) }, entry.span);
                _ = try compileExpression(self, context, entry.value);
            }
            _ = try context.emit(.make_dict, try self.narrow(entries.len, span), 0, span);
            return .dict;
        },
        .vector => |v| {
            var dimension: ?units.Dimension = null;
            for ([_]?*ast.Expr{ v.x, v.y, v.z }) |coordinate| if (coordinate) |expr| {
                const kind = try compileExpression(self, context, expr);
                try self.require(.scalar, kind, expr.span);
                if (scalarDimension(kind)) |d| {
                    if (d.eql(.scalar) and zeroLiteral(expr)) continue;
                    if (dimension) |prior| if (!prior.eql(d))
                        return self.fail(span, "vector coordinates have incompatible dimensions", .{});
                    dimension = d;
                }
            };
            _ = try context.emit(if (v.z == null) .make_vec2 else .make_vec3, 0, 0, span);
            return if (v.z == null) .vec2 else .vec3;
        },
        else => unreachable,
    }
}

/// A name: a binding, a named constant, or a callable target as a function value.
pub fn compileName(self: *Compiler, context: *Context, name: []const u8, span: Span) anyerror!Type {
    if (context.resolve(name, span)) |binding| {
        try context.load(binding, span);
        return binding.symbol.kind;
    }
    if (modules.imported(self, name, span) != null) return self.fail(span, "module namespace '{s}' is not a readable value", .{name});
    if (namedConstant(name)) |value| {
        try context.constant(value, span);
        return value.valueType();
    }
    const resolved = self.environment.unit.resolverAt(span.start).callable(self.environment.unit.scopeAt(span.start), name);
    if (!resolved.shadowed) if (modules.callTarget(self, name, resolved.member)) |target| {
        if (resolved.member) |member| if (member.module != self.environment.module_index) try context.checkImport(member.module, member.initializer, span);
        return calls.functionValue(self, context, target, span);
    };
    return self.fail(span, "unknown name '{s}'", .{name});
}

/// Index, slice and member access.
pub fn compileAccess(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
    const span = expression_.span;
    switch (expression_.value) {
        .index => |index| {
            const object = try compileExpression(self, context, index.object);
            if (object != .list and object != .dict and object != .any) return self.fail(index.object.span, "indexing requires a list or dictionary", .{});
            const key = try compileExpression(self, context, index.index);
            if (object == .dict) try self.require(.string, key, index.index.span) else if (object == .list) try self.require(.int, key, index.index.span);
            _ = try context.emit(.index, 0, 0, span);
            return .any;
        },
        .slice => |slice| {
            const object = try compileExpression(self, context, slice.object);
            if (object != .list and object != .any) return self.fail(slice.object.span, "slicing requires a list", .{});
            try self.require(.int, try compileExpression(self, context, slice.range.start), slice.range.start.span);
            // Keep the established for-range operand order.
            if (slice.range.stop) |stop| {
                try self.require(.int, try compileExpression(self, context, stop), stop.span);
            } else try context.constant(.unit, span);
            if (slice.range.step) |step| {
                try self.require(.int, try compileExpression(self, context, step), step.span);
            } else try context.constant(.{ .int = 1 }, span);
            _ = try context.emit(.slice, @intFromBool(slice.range.stop == null), 0, span);
            return .list;
        },
        .member => |member| {
            if (ungroup(member.object).value == .name) {
                if (modules.defaultNamespace(self, context, ungroup(member.object).value.name, span)) |native| {
                    if (builtin.namespaceConstant(native, member.name)) |value| {
                        try context.constant(value, span);
                        return value.valueType();
                    }
                    if (builtin.namespaceLookup(native, member.name)) |signature| return calls.functionValue(self, context, .{ .builtin = signature.id }, span);
                    return self.fail(span, "{s} has no readable member '{s}'", .{ native.name(), member.name });
                }
            }
            if (modules.moduleExpression(self, member.object)) |module_index| {
                const exposed = try modules.importedExport(self, module_index, member.name, span);
                try context.checkImport(module_index, modules.moduleInitializer(self, member.object), span);
                if (exposed.target != .global) return calls.functionValue(self, context, exposed.target, span);
                _ = try context.emit(.load_global, exposed.target.global, 0, span);
                return self.build.types.items[exposed.target.global];
            }
            const object = try compileExpression(self, context, member.object);
            if (try self.recordField(object, member.name, span)) |index| {
                _ = try context.emit(.field, try self.addConstant(.{ .string = member.name }, span), try self.narrow(index + 1, span), span);
                return self.build.records.items[object.recordIndex().?].fields[index].kind;
            }
            const result: Type = if (object == .any) .any else object.fieldType(member.name) orelse
                return self.fail(span, "{s} has no member '{s}'", .{ self.typeName(object), member.name });
            _ = try context.emit(.field, try self.addConstant(.{ .string = member.name }, span), 0, span);
            return result;
        },
        else => unreachable,
    }
}

pub fn compilePathLiteral(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
    var points: std.ArrayList(*ast.Expr) = .empty;
    defer points.deinit(self.build.syntax_allocator);
    var joins: std.ArrayList(ast.PathJoin) = .empty;
    defer joins.deinit(self.build.syntax_allocator);
    var closed = false;
    try collectPathLiteral(self, expression_, &points, &joins, &closed, 0);
    if (points.items.len < 2) return self.fail(expression_.span, "a path literal needs at least two points", .{});
    var dimension: Type = .any;
    for (points.items) |point_| {
        const actual = try compileExpression(self, context, point_);
        try self.require(if (dimension == .any) .vector else dimension, actual, point_.span);
        if (actual.isVector()) dimension = actual;
    }
    _ = try context.emit(.make_list, try self.narrow(points.items.len, expression_.span), 0, expression_.span);
    try context.constant(.{ .boolean = closed }, expression_.span);
    const values = try self.allocator.alloc(Value, joins.items.len);
    for (values, joins.items) |*value, join| value.* = .{ .string = @tagName(join) };
    try context.constant(bc.types.listView(values), expression_.span);
    _ = try context.emit(.call_builtin, @backingInt(builtin.Id.path), 3, expression_.span);
    return switch (dimension) {
        .vec2 => .path,
        .vec3 => .shape,
        else => .any,
    };
}

pub fn collectPathLiteral(self: *Compiler, expression_: *ast.Expr, points: *std.ArrayList(*ast.Expr), joins: *std.ArrayList(ast.PathJoin), closed: *bool, depth: usize) anyerror!void {
    if (depth > ast.max_depth) return self.fail(expression_.span, "path literal exceeds compilation depth {d}", .{ast.max_depth});
    switch (expression_.value) {
        .path_literal => |join| {
            try collectPathLiteral(self, join.left, points, joins, closed, depth + 1);
            if (closed.*) return self.fail(join.left.span, "cycle must be the final endpoint of a path literal", .{});
            try joins.append(self.build.syntax_allocator, join.kind);
            try collectPathLiteral(self, join.right, points, joins, closed, depth + 1);
        },
        .cycle => {
            if (closed.* or points.items.len == 0 or joins.items.len != points.items.len)
                return self.fail(expression_.span, "cycle is only valid as the closing endpoint of a path literal", .{});
            closed.* = true;
        },
        else => try points.append(self.build.syntax_allocator, expression_),
    }
}

pub fn namedConstant(name: []const u8) ?Value {
    if (units.unitNamed(name)) |unit| return .{ .quantity = units.applyUnit(1, unit) catch unreachable };
    return null;
}

fn zeroLiteral(expression: *ast.Expr) bool {
    return switch (expression.value) {
        .grouped => |inner| zeroLiteral(inner),
        .integer => |value| value == 0,
        .float => |value| value == 0,
        .unary => |unary| unary.op != .logical_not and zeroLiteral(unary.operand),
        else => false,
    };
}
