//! The binding pass: flattens an unparenthesized operator chain, reduces it by table comparisons and lowers mixfix forms to calls.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Allocator = std.mem.Allocator;
const precedence = @import("../precedence.zig");
const Id = precedence.Id;
const Table = precedence.Table;
const builtinId = precedence.builtinId;
const binaryBuiltin = precedence.binaryBuiltin;

const Operator = struct {
    group: Id,
    span: ast.Span,
    kind: union(enum) {
        unary: ast.Unary,
        binary: ast.Binary,
        path_join: ast.PathJoin,
        custom_mixfix: @FieldType(@FieldType(ast.Expr, "value"), "mixfix_call"),
    },

    fn isPrefix(self: Operator) bool {
        return self.kind == .unary or (self.kind == .custom_mixfix and !self.kind.custom_mixfix.leading);
    }
};

const Token = union(enum) { operand: *ast.Expr, operator: Operator };

pub fn Binding(comptime Resolver: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        table: *const Table,
        resolver: Resolver,
        diagnostic: *?source.Diagnostic,
        tokens: std.ArrayList(Token) = .empty,
        values: std.ArrayList(*ast.Expr) = .empty,
        operators: std.ArrayList(Operator) = .empty,

        fn fail(self: *Self, span: ast.Span, comptime format: []const u8, args: anytype) error{LanguageError} {
            _ = source.Diagnostic.set(self.diagnostic, span, format, args);
            return error.LanguageError;
        }
        fn append(self: *Self, token: Token) !void {
            if (self.tokens.items.len == 4096) return self.fail(switch (token) {
                .operand => |value| value.span,
                .operator => |operator| operator.span,
            }, "operator expression exceeds compilation work limit", .{});
            try self.tokens.append(self.allocator, token);
        }
        pub fn flatten(self: *Self, expression: *ast.Expr, depth: usize) anyerror!void {
            if (depth > ast.max_depth) return self.fail(expression.span, "expression tree exceeds compilation depth {d}", .{ast.max_depth});
            switch (expression.value) {
                .path_join => |join| {
                    try self.flatten(join.left, depth + 1);
                    try self.append(.{ .operator = .{ .group = builtinId(.path), .span = expression.span, .kind = .{ .path_join = join.kind } } });
                    try self.flatten(join.right, depth + 1);
                },
                .binary => |binary| {
                    try self.flatten(binary.left, depth + 1);
                    try self.append(.{ .operator = .{ .group = binaryGroup(binary.op), .span = expression.span, .kind = .{ .binary = binary.op } } });
                    try self.flatten(binary.right, depth + 1);
                },
                .unary => |unary| {
                    const group = if (unary.op == .logical_not) builtinId(.logical_not) else builtinId(.unary);
                    try self.append(.{ .operator = .{ .group = group, .span = expression.span, .kind = .{ .unary = unary.op } } });
                    try self.flatten(unary.operand, depth + 1);
                },
                .mixfix_call => |mixed| {
                    if (mixed.args.len < 1 + @as(usize, @intFromBool(mixed.leading))) return self.fail(mixed.operator.span, "missing mixfix arguments", .{});
                    if (mixed.leading) try self.flatten(mixed.args[0], depth + 1);
                    const group = try self.resolver.operatorGroup(mixed);
                    if (group >= self.table.groups.items.len) return self.fail(mixed.operator.span, "invalid precedence group", .{});
                    try self.append(.{ .operator = .{ .group = group, .span = mixed.operator.span, .kind = .{ .custom_mixfix = mixed } } });
                    try self.flatten(mixed.args[mixed.args.len - 1], depth + 1);
                },
                // Parentheses and postfix forms are boundaries. Their internal
                // expressions are compiled and rebound independently by the caller.
                else => try self.append(.{ .operand = expression }),
            }
        }
        fn create(self: *Self, span: ast.Span, value: @FieldType(ast.Expr, "value")) !*ast.Expr {
            const result = try self.allocator.create(ast.Expr);
            result.* = .{ .span = span, .value = value };
            return result;
        }
        fn reduce(self: *Self) !void {
            const operator = self.operators.pop() orelse return self.fail(.{ .start = 0, .end = 0 }, "missing operator", .{});
            const right = self.values.pop() orelse return self.fail(operator.span, "missing operator operand", .{});
            const result = switch (operator.kind) {
                .unary => |op| try self.create(.{ .start = operator.span.start, .end = right.span.end }, .{ .unary = .{ .op = op, .operand = right } }),
                .custom_mixfix => |mixed| result: {
                    const offset: usize = @intFromBool(mixed.operator.namespace != null);
                    const arguments = try self.allocator.alloc(*ast.Expr, mixed.args.len + offset);
                    if (mixed.operator.namespace) |namespace| arguments[0] = try self.create(mixed.operator.span, .{ .name = namespace });
                    @memcpy(arguments[offset..], mixed.args);
                    arguments[arguments.len - 1] = right;
                    if (mixed.leading) arguments[offset] = self.values.pop() orelse return self.fail(operator.span, "missing left operator operand", .{});
                    break :result try self.create(.{ .start = if (mixed.leading) arguments[offset].span.start else mixed.operator.span.start, .end = right.span.end }, .{ .call = .{ .name = mixed.operator.name, .args = arguments, .dot = offset != 0, .mixed = true, .qualified = if (mixed.qualified) |binding| &binding.target else null } });
                },
                .binary, .path_join => result: {
                    const left = self.values.pop() orelse return self.fail(operator.span, "missing left operator operand", .{});
                    const span = ast.Span.join(left.span, right.span);
                    break :result switch (operator.kind) {
                        .path_join => |kind| try self.create(span, .{ .path_literal = .{ .left = left, .right = right, .kind = kind } }),
                        .binary => |op| try self.create(span, .{ .binary = .{ .op = op, .left = left, .right = right } }),
                        else => unreachable,
                    };
                },
            };
            try self.values.append(self.allocator, result);
        }
        pub fn bind(self: *Self) !*ast.Expr {
            for (self.tokens.items) |token| switch (token) {
                .operand => |value| try self.values.append(self.allocator, value),
                .operator => |incoming| {
                    if (!incoming.isPrefix()) {
                        while (self.operators.items.len != 0) {
                            const top = self.operators.items[self.operators.items.len - 1];
                            switch (try self.table.compare(top.group, incoming.group)) {
                                .higher => try self.reduce(),
                                .lower => break,
                                .unrelated => return self.fail(incoming.span, "precedence groups '{s}' and '{s}' are unrelated; add parentheses", .{ self.table.groups.items[top.group].name, self.table.groups.items[incoming.group].name }),
                                .same => {
                                    // Prefix operands include operators of equal
                                    // binding strength, matching existing unary rules.
                                    if (top.isPrefix()) break;
                                    switch (self.table.groups.items[top.group].associativity) {
                                        .left => try self.reduce(),
                                        .right => break,
                                        .none => return self.fail(incoming.span, "precedence group '{s}' is nonassociative; add parentheses", .{self.table.groups.items[top.group].name}),
                                    }
                                },
                            }
                        }
                    }
                    try self.operators.append(self.allocator, incoming);
                },
            };
            while (self.operators.items.len != 0) try self.reduce();
            if (self.values.items.len != 1) return self.fail(.{ .start = 0, .end = 0 }, "invalid operator expression", .{});
            return self.values.items[0];
        }
    };
}

fn binaryGroup(op: ast.Binary) Id {
    return builtinId(binaryBuiltin(op));
}
