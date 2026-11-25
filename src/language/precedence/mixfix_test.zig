//! Tests of prefix and mixfix binding: drawing prefixes, custom prefixes, nesting, prefix and infix roles, qualified prefixes and mixfix arguments.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Allocator = std.mem.Allocator;
const precedence = @import("../precedence.zig");
const testing = @import("testing.zig");
const Table = precedence.Table;
const builtinId = precedence.builtinId;
const testExpression = testing.testExpression;
const resolve = precedence.resolve;
const TestResolver = testing.TestResolver;
const hasCustom = precedence.hasCustom;
const Id = precedence.Id;

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
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?@import("../Parser.zig").MixfixLookup.Binding {
            const matches = !leading and name.namespace != null and std.mem.eql(u8, name.namespace.?, "ops") and std.mem.eql(u8, name.name, "wrap");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var parser = try @import("../Parser.zig").init(a, "answer:=ops.wrap values[0]+2", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
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
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?@import("../Parser.zig").MixfixLookup.Binding {
            if (leading) return null;
            if (name.namespace == null or !std.mem.eql(u8, name.namespace.?, "ops") or !std.mem.eql(u8, name.name, "combine")) return null;
            return .{ .form = .{ .head = name.name, .parts = &.{ "with", "left", null, "right", null }, .group = .{ .name = "unary", .span = name.span } } };
        }
    };
    var parser = try @import("../Parser.zig").init(a, "answer:=ops.combine with left 1 right (2+3)", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
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
