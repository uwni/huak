//! Compile-time precedence groups and binding of word operators. The VM sees
//! only ordinary calls and existing arithmetic instructions after this pass.
const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const Allocator = std.mem.Allocator;

pub const Id = u32;
pub const max_groups = 512;
const words = max_groups / 64;
const Row = [words]u64;
pub const Error = Allocator.Error || error{ TooManyGroups, InvalidGroup, CyclicPrecedence };
pub const Comparison = enum { higher, lower, same, unrelated };
pub const Group = struct {
    /// Borrowed from persistent module source or a built-in static string.
    name: []const u8,
    module: u32,
    associativity: ast.Associativity,
    span: ast.Span,
};
pub const Builtin = enum {
    logical_or,
    logical_and,
    logical_not,
    equality,
    comparison,
    path,
    addition,
    multiplication,
    unary,
    power,
};

pub fn builtinId(group: Builtin) Id {
    return @backingInt(group);
}
pub fn builtinNamed(name: []const u8) ?Id {
    const group = std.meta.stringToEnum(Builtin, name) orelse return null;
    return builtinId(group);
}

pub const Table = struct {
    allocator: Allocator,
    groups: std.ArrayList(Group) = .empty,
    // Incremental transitive closure: bit B in row A means A binds more tightly
    // than B. Comparisons require no graph walk or allocation while parsing.
    reach: std.ArrayList(Row) = .empty,

    pub fn init(allocator: Allocator) Error!Table {
        var result: Table = .{ .allocator = allocator };
        errdefer result.deinit();
        for (std.enums.values(Builtin)) |group| {
            const association: ast.Associativity = switch (group) {
                .logical_not, .unary, .power => .right,
                else => .left,
            };
            _ = try result.add(@tagName(group), std.math.maxInt(u32), association, .{ .start = 0, .end = 0 });
            const id = builtinId(group);
            if (id != 0) try result.above(id, id - 1);
        }
        return result;
    }
    pub fn deinit(self: *Table) void {
        self.groups.deinit(self.allocator);
        self.reach.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn add(self: *Table, name: []const u8, module: u32, associativity: ast.Associativity, span: ast.Span) Error!Id {
        if (self.groups.items.len == max_groups) return error.TooManyGroups;
        try self.groups.ensureUnusedCapacity(self.allocator, 1);
        try self.reach.ensureUnusedCapacity(self.allocator, 1);
        const id: Id = @intCast(self.groups.items.len);
        self.groups.appendAssumeCapacity(.{ .name = name, .module = module, .associativity = associativity, .span = span });
        self.reach.appendAssumeCapacity(@splat(0));
        return id;
    }
    pub fn above(self: *Table, higher: Id, lower: Id) Error!void {
        try self.check(higher);
        try self.check(lower);
        if (higher == lower or self.reaches(lower, higher)) return error.CyclicPrecedence;
        if (self.reaches(higher, lower)) return;
        var descendants = self.reach.items[lower];
        descendants[lower / 64] |= bit(lower);
        for (self.reach.items, 0..) |*row, id| {
            if (id != higher and !has(row.*, higher)) continue;
            for (row, descendants) |*destination, mask| destination.* |= mask;
        }
    }
    pub fn validate(self: *const Table) Error!void {
        if (self.groups.items.len != self.reach.items.len) return error.InvalidGroup;
        for (self.reach.items, 0..) |row, id| if (has(row, @intCast(id))) return error.CyclicPrecedence;
    }
    pub fn compare(self: *const Table, a: Id, b: Id) Error!Comparison {
        try self.check(a);
        try self.check(b);
        if (a == b) return .same;
        if (self.reaches(a, b)) return .higher;
        if (self.reaches(b, a)) return .lower;
        return .unrelated;
    }
    fn check(self: *const Table, id: Id) Error!void {
        if (id >= self.groups.items.len) return error.InvalidGroup;
    }
    fn reaches(self: *const Table, a: Id, b: Id) bool {
        return has(self.reach.items[a], b);
    }
    fn bit(id: Id) u64 {
        return @as(u64, 1) << @as(u6, @intCast(id % 64));
    }
    fn has(row: Row, id: Id) bool {
        return row[id / 64] & bit(id) != 0;
    }
};

/// Inspect one unparenthesized operator component. An overly deep component
/// goes through resolve too, where it receives the normal depth diagnostic.
pub fn hasCustom(expression: *const ast.Expr) bool {
    return contains(expression, 0);
}
fn contains(expression: *const ast.Expr, depth: usize) bool {
    if (depth > 256) return true;
    return switch (expression.value) {
        .mixfix_call, .path_join => true,
        .binary => |binary| contains(binary.left, depth + 1) or contains(binary.right, depth + 1),
        .unary => |unary| contains(unary.operand, depth + 1),
        else => false,
    };
}

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
fn Binding(comptime Resolver: type) type {
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
        fn flatten(self: *Self, expression: *ast.Expr, depth: usize) anyerror!void {
            if (depth > 256) return self.fail(expression.span, "expression tree exceeds compilation depth 256", .{});
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
        fn bind(self: *Self) !*ast.Expr {
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
    return builtinId(switch (op) {
        .logical_or => .logical_or,
        .logical_and => .logical_and,
        .equal, .not_equal => .equality,
        .less, .less_equal, .greater, .greater_equal => .comparison,
        .add, .subtract => .addition,
        .multiply, .divide, .remainder => .multiplication,
        .power => .power,
    });
}

pub fn resolve(allocator: Allocator, table: *const Table, expression: *ast.Expr, resolver: anytype, diagnostic: *?source.Diagnostic) anyerror!*ast.Expr {
    if (!hasCustom(expression)) return expression;
    var binding: Binding(@TypeOf(resolver)) = .{ .allocator = allocator, .table = table, .resolver = resolver, .diagnostic = diagnostic };
    defer binding.tokens.deinit(allocator);
    defer binding.values.deinit(allocator);
    defer binding.operators.deinit(allocator);
    try binding.flatten(expression, 0);
    return binding.bind();
}

test "groups retain a partial order and reject cycles without changing prior relations" {
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    const a = try table.add("transform", 0, .left, .{ .start = 0, .end = 1 });
    const b = try table.add("other", 1, .right, .{ .start = 2, .end = 3 });
    try table.above(a, builtinId(.path));
    try table.above(builtinId(.addition), a);
    try table.above(b, builtinId(.path));
    try table.above(builtinId(.addition), b);
    try std.testing.expectEqual(Comparison.higher, try table.compare(a, builtinId(.path)));
    try std.testing.expectEqual(Comparison.lower, try table.compare(a, builtinId(.addition)));
    try std.testing.expectEqual(Comparison.higher, try table.compare(builtinId(.power), a));
    try std.testing.expectEqual(Comparison.same, try table.compare(a, a));
    try std.testing.expectEqual(Comparison.unrelated, try table.compare(a, b));
    try std.testing.expectError(error.CyclicPrecedence, table.above(a, builtinId(.addition)));
    try std.testing.expectError(error.CyclicPrecedence, table.above(a, a));
    try std.testing.expectEqual(Comparison.lower, try table.compare(a, builtinId(.addition)));
    try table.validate();
}

fn allocationExercise(allocator: Allocator) !void {
    var table = try Table.init(allocator);
    defer table.deinit();
    for (0..max_groups - std.enums.values(Builtin).len) |index| {
        const id = try table.add("custom", @intCast(index), .left, .{ .start = 0, .end = 0 });
        try table.above(id, builtinId(.path));
    }
    try std.testing.expectError(error.TooManyGroups, table.add("extra", 0, .none, .{ .start = 0, .end = 0 }));
    try table.validate();
}
test "group limits and every allocation failure release table storage" {
    try allocationExercise(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationExercise, .{});
}

const TestResolver = struct {
    id: Id,
    pub fn operatorGroup(self: *TestResolver, _: anytype) !Id {
        return self.id;
    }
};
fn testExpression(allocator: Allocator, text: []const u8) !*ast.Expr {
    var diagnostic: ?source.Diagnostic = null;
    var parser = try @import("Parser.zig").init(allocator, text, .{}, &diagnostic);
    const script = try parser.parse();
    return script.statements[script.statements.len - 1].value.assignment.value;
}

test "native path joins bind through the shared path group and preserve mixed edges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: TestResolver = .{ .id = builtinId(.path) };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "answer:=a+b~~c*d--cycle shade ink");
    const result = try resolve(a, &table, original, &context, &diagnostic);
    const shade = result.value.call;
    try std.testing.expectEqualStrings("shade", shade.name);
    const final = shade.args[0].value.path_literal;
    try std.testing.expectEqual(ast.PathJoin.straight, final.kind);
    try std.testing.expect(final.right.value == .cycle);
    const smooth = final.left.value.path_literal;
    try std.testing.expectEqual(ast.PathJoin.smooth, smooth.kind);
    try std.testing.expectEqual(ast.Binary.add, smooth.left.value.binary.op);
    try std.testing.expectEqual(ast.Binary.multiply, smooth.right.value.binary.op);
    const comparison = try resolve(a, &table, try testExpression(a, "answer:=a~~b<c"), &context, &diagnostic);
    try std.testing.expectEqual(ast.Binary.less, comparison.value.binary.op);
    try std.testing.expect(comparison.value.binary.left.value == .path_literal);
    const grouped = try resolve(a, &table, try testExpression(a, "answer:=(a~~b) shade ink"), &context, &diagnostic);
    try std.testing.expect(grouped.value.call.args[0].value == .grouped);
}

test "drawing prefix operands include native paths and their word styles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: FixityResolver = .{ .prefix = builtinId(.logical_or), .infix = builtinId(.path) };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "mixfix(wrap) wrap _ in logical_or\nanswer:=wrap a~~b shade ink");
    const result = try resolve(a, &table, original, &context, &diagnostic);
    const draw = result.value.call;
    try std.testing.expect(draw.mixed);
    try std.testing.expectEqualStrings("wrap", draw.name);
    const shade = draw.args[0].value.call;
    try std.testing.expectEqualStrings("shade", shade.name);
    try std.testing.expect(shade.args[0].value == .path_literal);
}

test "custom prefixes bind arithmetic with the same unary rules and lower to ordinary calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: TestResolver = .{ .id = builtinId(.unary) };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "mixfix(wrap) wrap _ in unary\nanswer:=wrap -2^3+4");
    try std.testing.expect(hasCustom(original));
    const result = try resolve(a, &table, original, &context, &diagnostic);
    try std.testing.expectEqual(ast.Binary.add, result.value.binary.op);
    const call = result.value.binary.left.value.call;
    try std.testing.expectEqualStrings("wrap", call.name);
    try std.testing.expect(call.mixed);
    try std.testing.expect(!call.dot);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqual(ast.Unary.negate, call.args[0].value.unary.op);
    try std.testing.expectEqual(ast.Binary.power, call.args[0].value.unary.operand.value.binary.op);
    // Normal calls remain barriers regardless of the function's prefix role.
    const normal = try testExpression(a, "mixfix(wrap) wrap _ in unary\nanswer:=wrap(1)+2");
    try std.testing.expect(!hasCustom(normal));
    try std.testing.expect(!normal.value.binary.left.value.call.mixed);
}

test "nested prefixes associate right and explicit grouping limits their operands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: TestResolver = .{ .id = builtinId(.addition) };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "mixfix(wrap) wrap _ in addition\nanswer:=wrap wrap 1+2");
    const result = try resolve(a, &table, original, &context, &diagnostic);
    try std.testing.expectEqualStrings("wrap", result.value.call.name);
    const inner = result.value.call.args[0];
    try std.testing.expectEqualStrings("wrap", inner.value.call.name);
    try std.testing.expectEqual(ast.Binary.add, inner.value.call.args[0].value.binary.op);
    const grouped = try resolve(a, &table, try testExpression(a, "mixfix(wrap) wrap _ in addition\nanswer:=(wrap 1)+2"), &context, &diagnostic);
    // Grouped components are compiled by the caller in their own binding pass.
    try std.testing.expectEqual(ast.Binary.add, grouped.value.binary.op);
    try std.testing.expect(grouped.value.binary.left.value == .grouped);
    try std.testing.expect(hasCustom(grouped.value.binary.left.value.grouped));
}

const FixityResolver = struct {
    prefix: Id,
    infix: Id,
    pub fn operatorGroup(self: *FixityResolver, mixed: anytype) !Id {
        return if (mixed.leading) self.infix else self.prefix;
    }
};

test "prefix and infix roles resolve independently and unrelated groups require parentheses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    const isolated = try table.add("isolated", 0, .none, .{ .start = 0, .end = 0 });
    var context: FixityResolver = .{ .prefix = builtinId(.unary), .infix = builtinId(.addition) };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "mixfix(wrap) wrap _ in unary\nanswer:=wrap 2 blend 3*4");
    const result = try resolve(a, &table, original, &context, &diagnostic);
    try std.testing.expectEqualStrings("blend", result.value.call.name);
    try std.testing.expect(result.value.call.mixed);
    try std.testing.expectEqualStrings("wrap", result.value.call.args[0].value.call.name);
    try std.testing.expectEqual(ast.Binary.multiply, result.value.call.args[1].value.binary.op);
    context.prefix = isolated;
    try std.testing.expectError(error.LanguageError, resolve(a, &table, original, &context, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "unrelated") != null);
    diagnostic = null;
    const safe = try resolve(a, &table, try testExpression(a, "mixfix(wrap) wrap _ in unary\nanswer:=wrap +(2+3)"), &context, &diagnostic);
    try std.testing.expectEqual(ast.Unary.positive, safe.value.call.args[0].value.unary.op);
    try std.testing.expect(safe.value.call.args[0].value.unary.operand.value == .grouped);
}

test "qualified prefix lowering retains its exported namespace and a single operand" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: TestResolver = .{ .id = builtinId(.unary) };
    var diagnostic: ?source.Diagnostic = null;
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?@import("Parser.zig").MixfixLookup.Binding {
            const matches = !leading and name.namespace != null and std.mem.eql(u8, name.namespace.?, "ops") and std.mem.eql(u8, name.name, "wrap");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var parser = try @import("Parser.zig").init(a, "answer:=ops.wrap values[0]+2", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const result = try resolve(a, &table, script.statements[0].value.assignment.value, &context, &diagnostic);
    try std.testing.expectEqual(ast.Binary.add, result.value.binary.op);
    const call = result.value.binary.left.value.call;
    try std.testing.expect(call.mixed);
    try std.testing.expect(call.dot);
    try std.testing.expectEqualStrings("wrap", call.name);
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("ops", call.args[0].value.name);
    try std.testing.expect(call.args[1].value == .index);
}

test "word chains obey left right and none associations" {
    for ([_]ast.Associativity{ .left, .right, .none }) |association| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var table = try Table.init(std.testing.allocator);
        defer table.deinit();
        const id = try table.add("mix", 0, association, .{ .start = 0, .end = 0 });
        var context: TestResolver = .{ .id = id };
        var diagnostic: ?source.Diagnostic = null;
        const original = try testExpression(arena.allocator(), "answer:=10 blend 3 blend 1");
        if (association == .none) {
            try std.testing.expectError(error.LanguageError, resolve(arena.allocator(), &table, original, &context, &diagnostic));
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "nonassociative") != null);
            continue;
        }
        const result = try resolve(arena.allocator(), &table, original, &context, &diagnostic);
        try std.testing.expectEqualStrings("blend", result.value.call.name);
        const nested = if (association == .left) result.value.call.args[0] else result.value.call.args[1];
        try std.testing.expectEqualStrings("blend", nested.value.call.name);
        try std.testing.expectEqual(@as(u64, if (association == .left) 1 else 10), (if (association == .left) result.value.call.args[1] else result.value.call.args[0]).value.integer);
    }
}

test "word operators bind against builtin arithmetic and prefix groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    const id = try table.add("mix", 0, .left, .{ .start = 0, .end = 0 });
    try table.above(id, builtinId(.addition));
    try table.above(builtinId(.multiplication), id);
    var context: TestResolver = .{ .id = id };
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a, "answer:=1+2 blend 3*4");
    const result = try resolve(a, &table, original, &context, &diagnostic);
    try std.testing.expectEqual(ast.Binary.add, result.value.binary.op);
    try std.testing.expectEqualStrings("blend", result.value.binary.right.value.call.name);
    try std.testing.expectEqual(ast.Binary.multiply, result.value.binary.right.value.call.args[1].value.binary.op);
    const high = try table.add("high", 0, .left, .{ .start = 0, .end = 0 });
    try table.above(high, builtinId(.power));
    context.id = high;
    const prefixed = try resolve(a, &table, try testExpression(a, "answer:=-2 blend 3"), &context, &diagnostic);
    try std.testing.expectEqual(ast.Unary.negate, prefixed.value.unary.op);
    try std.testing.expectEqualStrings("blend", prefixed.value.unary.operand.value.call.name);
    context.id = id;
    const logical = try resolve(a, &table, try testExpression(a, "answer:=not 1 blend 2 == 3"), &context, &diagnostic);
    try std.testing.expectEqual(ast.Unary.logical_not, logical.value.unary.op);
    try std.testing.expectEqual(ast.Binary.equal, logical.value.unary.operand.value.binary.op);
}

test "parentheses and postfix operands are binding barriers and qualified calls retain namespaces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    const id = try table.add("isolated", 0, .none, .{ .start = 0, .end = 0 });
    var context: TestResolver = .{ .id = id };
    var diagnostic: ?source.Diagnostic = null;
    const result = try resolve(a, &table, try testExpression(a, "answer:=(1+2) ops.blend values[0]"), &context, &diagnostic);
    try std.testing.expect(result.value.call.dot);
    try std.testing.expectEqualStrings("ops", result.value.call.args[0].value.name);
    try std.testing.expect(result.value.call.args[1].value == .grouped);
    try std.testing.expect(result.value.call.args[2].value == .index);
    const outer = try testExpression(a, "answer:=fn_call(1 blend 2)+3");
    try std.testing.expect(!hasCustom(outer));
    try std.testing.expect(hasCustom(outer.value.binary.left.value.call.args[0]));
    const ungrouped = try testExpression(a, "answer:=1+2 blend 3");
    try std.testing.expectError(error.LanguageError, resolve(a, &table, ungrouped, &context, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "unrelated") != null);
}

fn bindingAllocationExercise(allocator: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var table = try Table.init(allocator);
    defer table.deinit();
    const id = try table.add("mix", 0, .left, .{ .start = 0, .end = 0 });
    try table.above(builtinId(.addition), id);
    try table.above(id, builtinId(.path));
    var context: TestResolver = .{ .id = id };
    var diagnostic: ?source.Diagnostic = null;
    const result = try resolve(arena.allocator(), &table, try testExpression(arena.allocator(), "mixfix(wrap) wrap _ in path\nanswer:=not wrap -1+2 ops.blend 3^4 == 9"), &context, &diagnostic);
    try std.testing.expectEqual(ast.Unary.logical_not, result.value.unary.op);
}

test "binding allocates only compile-time AST and releases all failure paths" {
    try bindingAllocationExercise(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), bindingAllocationExercise, .{});
}

test "long unresolved operator chains fail before overflowing the compiler stack" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(std.testing.allocator);
    defer table.deinit();
    var context: TestResolver = .{ .id = builtinId(.addition) };
    const one = try a.create(ast.Expr);
    one.* = .{ .span = .{ .start = 0, .end = 1 }, .value = .{ .integer = 1 } };
    var expression = one;
    for (0..1000) |_| {
        const next = try a.create(ast.Expr);
        next.* = .{ .span = .{ .start = 0, .end = 1 }, .value = .{ .mixfix_call = .{ .operator = .{ .name = "blend", .span = .{ .start = 0, .end = 1 } }, .args = try a.dupe(*ast.Expr, &.{ expression, one }), .leading = true } } };
        expression = next;
    }
    var diagnostic: ?source.Diagnostic = null;
    try std.testing.expect(hasCustom(expression));
    try std.testing.expectError(error.LanguageError, resolve(a, &table, expression, &context, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "depth") != null);
}

const MixfixTestResolver = struct {
    pub fn operatorGroup(_: @This(), mixed: anytype) !Id {
        return builtinId(if (mixed.leading) .path else if (std.mem.eql(u8, mixed.operator.name, "append")) .logical_or else .unary);
    }
};

fn mixfixBindingExercise(allocator: Allocator) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(a);
    defer table.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const original = try testExpression(a,
        \\mixfix(append) append _ in logical_or
        \\mixfix(combine) combine with left _ right _ in unary
        \\answer:=append combine with left (1+2) right 3+4 filled ink
    );
    const result = try resolve(a, &table, original, MixfixTestResolver{}, &diagnostic);
    const appended = result.value.call;
    try std.testing.expectEqualStrings("append", appended.name);
    try std.testing.expect(appended.mixed);
    const filled = appended.args[0].value.call;
    try std.testing.expectEqualStrings("filled", filled.name);
    const added = filled.args[0].value.binary;
    try std.testing.expectEqual(ast.Binary.add, added.op);
    const combined = added.left.value.call;
    try std.testing.expectEqualStrings("combine", combined.name);
    try std.testing.expect(combined.mixed and !combined.dot);
    try std.testing.expect(combined.args[0].value == .grouped);
    try std.testing.expectEqual(@as(u64, 3), combined.args[1].value.integer);
    try std.testing.expectEqual(@as(u64, 4), added.right.value.integer);

    const leading = try testExpression(a, "mixfix(crop) _ crop from _ to _ in addition;answer:=1+2 crop from (3*4) to 5*6+7");
    var addition: TestResolver = .{ .id = builtinId(.addition) };
    const bounded = try resolve(a, &table, leading, &addition, &diagnostic);
    try std.testing.expectEqual(ast.Binary.add, bounded.value.binary.op);
    const crop = bounded.value.binary.left.value.call;
    try std.testing.expectEqualStrings("crop", crop.name);
    try std.testing.expectEqual(@as(usize, 3), crop.args.len);
    try std.testing.expectEqual(ast.Binary.add, crop.args[0].value.binary.op);
    try std.testing.expect(crop.args[1].value == .grouped);
    try std.testing.expectEqual(ast.Binary.multiply, crop.args[2].value.binary.op);
    try std.testing.expectEqual(@as(u64, 7), bounded.value.binary.right.value.integer);
}

test "mixfix binding preserves earlier arguments and shares prefix infix precedence and allocation cleanup" {
    try mixfixBindingExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, mixfixBindingExercise, .{});
}

test "mixfix binding retains namespace calls and reports unrelated outer groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = try Table.init(a);
    defer table.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?@import("Parser.zig").MixfixLookup.Binding {
            if (leading) return null;
            if (name.namespace == null or !std.mem.eql(u8, name.namespace.?, "ops") or !std.mem.eql(u8, name.name, "combine")) return null;
            return .{ .form = .{ .head = name.name, .parts = &.{ "with", "left", null, "right", null }, .group = .{ .name = "unary", .span = name.span } } };
        }
    };
    var parser = try @import("Parser.zig").init(a, "answer:=ops.combine with left 1 right (2+3)", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const bound = try resolve(a, &table, script.statements[0].value.assignment.value, MixfixTestResolver{}, &diagnostic);
    const call = bound.value.call;
    try std.testing.expect(call.dot and call.mixed);
    try std.testing.expectEqualStrings("ops", call.args[0].value.name);
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expect(call.args[2].value == .grouped);

    const isolated = try table.add("isolated", 0, .none, .{ .start = 0, .end = 0 });
    var unrelated: TestResolver = .{ .id = isolated };
    const expression = try testExpression(a, "mixfix(f) f from _ to _ in isolated;answer:=f from 1 to 2+3");
    try std.testing.expectError(error.LanguageError, resolve(a, &table, expression, &unrelated, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "unrelated") != null);
}
