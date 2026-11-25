//! Tests of the binding pass: path joins, word chains and builtin arithmetic, binding barriers, allocation and long chains.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Allocator = std.mem.Allocator;
const precedence = @import("../precedence.zig");
const testing = @import("testing.zig");
const Table = precedence.Table;
const TestResolver = testing.TestResolver;
const builtinId = precedence.builtinId;
const testExpression = testing.testExpression;
const resolve = precedence.resolve;
const hasCustom = precedence.hasCustom;

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
