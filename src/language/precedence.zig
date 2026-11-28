//! Compile-time precedence groups and binding of word operators. The VM sees
//! only ordinary calls and existing arithmetic instructions after this pass.
const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const Allocator = std.mem.Allocator;
const binder = @import("precedence/binding.zig");
const Binding = binder.Binding;

pub const Id = u32;
pub const max_groups = 512;
const Row = std.bit_set.Static(max_groups);
pub const Error = Allocator.Error || error{ TooManyGroups, InvalidGroup, CyclicPrecedence };
pub const Comparison = enum { higher, lower, same, unrelated };
pub const Group = struct {
    /// Borrowed from persistent module source or a built-in static string.
    name: []const u8,
    module: u32,
    associativity: ast.Associativity,
    span: ast.Span,
};
/// The built-in groups, each binding more tightly than the one before it.
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
/// How a built-in group associates: `not`, signs and powers from the right.
pub fn builtinAssociativity(group: Builtin) ast.Associativity {
    return switch (group) {
        .logical_not, .unary, .power => .right,
        else => .left,
    };
}
/// The level at which the parser binds a built-in group: one above the
/// group before it, above level 0, which takes every operator.
pub fn builtinLevel(group: Builtin) u8 {
    return @intCast(builtinId(group) + 1);
}
/// The built-in group of a binary operator.
pub fn binaryBuiltin(op: ast.Binary) Builtin {
    return switch (op) {
        .logical_or => .logical_or,
        .logical_and => .logical_and,
        .equal, .not_equal => .equality,
        .less, .less_equal, .greater, .greater_equal => .comparison,
        .add, .subtract => .addition,
        .multiply, .divide, .remainder => .multiplication,
        .power => .power,
    };
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
            _ = try result.add(@tagName(group), std.math.maxInt(u32), builtinAssociativity(group), .{ .start = 0, .end = 0 });
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
        self.reach.appendAssumeCapacity(.empty);
        return id;
    }
    pub fn above(self: *Table, higher: Id, lower: Id) Error!void {
        try self.check(higher);
        try self.check(lower);
        if (higher == lower or self.reaches(lower, higher)) return error.CyclicPrecedence;
        if (self.reaches(higher, lower)) return;
        var descendants = self.reach.items[lower];
        descendants.set(lower);
        for (self.reach.items, 0..) |*row, id| {
            if (id != higher and !row.isSet(higher)) continue;
            row.setUnion(descendants);
        }
    }
    pub fn validate(self: *const Table) Error!void {
        if (self.groups.items.len != self.reach.items.len) return error.InvalidGroup;
        for (self.reach.items, 0..) |row, id| if (row.isSet(id)) return error.CyclicPrecedence;
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
        return self.reach.items[a].isSet(b);
    }
};

/// Inspect one unparenthesized operator component. An overly deep component
/// goes through resolve too, where it receives the normal depth diagnostic.
pub fn hasCustom(expression: *const ast.Expr) bool {
    return contains(expression, 0);
}
fn contains(expression: *const ast.Expr, depth: usize) bool {
    if (depth > ast.max_depth) return true;
    return switch (expression.value) {
        .mixfix_call, .path_join => true,
        .binary => |binary| contains(binary.left, depth + 1) or contains(binary.right, depth + 1),
        .unary => |unary| contains(unary.operand, depth + 1),
        else => false,
    };
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

test {
    _ = @import("precedence/binding_test.zig");
    _ = @import("precedence/mixfix_test.zig");
}
