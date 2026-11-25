//! Tests of precedence groups, word operator chains and mixfix forms.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");

test "precedence declarations use contextual attributes and qualified names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\precedence transform
        \\ above path
        \\ below arithmetic.addition
        \\ associativity left
        \\end
        \\mixfix(scaled) _ scaled _ in transform
        \\mixfix(shifted) _ shifted _ in common.transform
        \\left:=1;right:=2;none:=3;above:=4;below:=5;associativity:=6
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 9), script.statements.len);
    const group = script.statements[0].value.precedence_group;
    try std.testing.expectEqualStrings("transform", group.name);
    try std.testing.expectEqual(ast.Associativity.left, group.associativity);
    try std.testing.expectEqual(@as(usize, 2), group.relations.len);
    try std.testing.expectEqual(.above, group.relations[0].direction);
    try std.testing.expect(group.relations[0].target.namespace == null);
    try std.testing.expectEqualStrings("path", group.relations[0].target.name);
    try std.testing.expectEqualStrings("above path", parser.lexer.source[group.relations[0].span.start..group.relations[0].span.end]);
    try std.testing.expectEqual(.below, group.relations[1].direction);
    try std.testing.expectEqualStrings("arithmetic", group.relations[1].target.namespace.?);
    try std.testing.expectEqualStrings("addition", group.relations[1].target.name);
    try std.testing.expectEqualStrings("scaled", script.statements[1].value.mixfix_binding.target.name);
    try std.testing.expectEqualStrings("common", script.statements[2].value.mixfix_binding.form.group.namespace.?);
    const contextual = [_][]const u8{ "left", "right", "none", "above", "below", "associativity" };
    for (contextual, script.statements[3..]) |name, stmt| try std.testing.expectEqualStrings(name, stmt.value.assignment.name);
}

test "precedence groups support none by default and explicit right association" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\precedence a;end
        \\precedence b;associativity right;end
        \\precedence c;associativity none;end
    , .{}, &diagnostic);
    const script = try parser.parse();
    for ([_]ast.Associativity{ .none, .right, .none }, script.statements) |expected, stmt|
        try std.testing.expectEqual(expected, stmt.value.precedence_group.associativity);
}

test "precedence syntax rejects malformed duplicated and unknown attributes" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "precedence g\nassociativity left\nassociativity right\nend", .message = "duplicate associativity" },
        .{ .code = "precedence g\nabove common.g\nabove common.g\nend", .message = "duplicate 'above' relation" },
        .{ .code = "precedence g\nassociativity middle\nend", .message = "left, right, or none" },
        .{ .code = "precedence g\nunknown x\nend", .message = "unknown precedence attribute" },
        .{ .code = "precedence g\nabove x below y\nend", .message = "between precedence attributes" },
        .{ .code = "precedence g\nabove x\n", .message = "unterminated precedence group" },
        .{ .code = "mixfix(f) _ f _", .message = "expected a mixfix word" },
        .{ .code = "mixfix(f) _ f _ in", .message = "operator or precedence group name" },
        .{ .code = "mixfix(f) _ f _ in x.", .message = "name after namespace" },
        .{ .code = "mixfix(f) _ ns.f _ in x", .message = "expected a mixfix word" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "word operator chains remain unresolved while grouping stays explicit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=1+2 scaled 3*4 shifted (5+6)
        \\y:=(a shifted b) tools.scaled -c^2
        \\ordinary:=scaled(1,2)
        \\method:=shapes.item.norm()
    , .{}, &diagnostic);
    const script = try parser.parse();
    const outer = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("shifted", outer.operator.name);
    try std.testing.expectEqual(ast.Binary.add, outer.args[1].value.grouped.value.binary.op);
    const inner = outer.args[0].value.mixfix_call;
    try std.testing.expectEqualStrings("scaled", inner.operator.name);
    try std.testing.expectEqual(ast.Binary.add, inner.args[0].value.binary.op);
    try std.testing.expectEqual(ast.Binary.multiply, inner.args[1].value.binary.op);
    const qualified = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("tools", qualified.operator.namespace.?);
    try std.testing.expectEqualStrings("scaled", qualified.operator.name);
    try std.testing.expectEqualStrings("shifted", qualified.args[0].value.grouped.value.mixfix_call.operator.name);
    try std.testing.expectEqual(ast.Unary.negate, qualified.args[1].value.unary.op);
    try std.testing.expectEqual(ast.Binary.power, qualified.args[1].value.unary.operand.value.binary.op);
    const ordinary = script.statements[2].value.assignment.value.value.call;
    try std.testing.expect(!ordinary.dot);
    try std.testing.expectEqual(@as(usize, 2), ordinary.args.len);
    const method = script.statements[3].value.assignment.value.value.call;
    try std.testing.expect(method.dot);
    try std.testing.expectEqualStrings("item", method.args[0].value.member.name);
}

test "mixfix forms delimit multiple arguments and preserve ordinary calls and labels as names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\first:=construct with center (1,2) radius (3+4)
        \\mixfix(construct) construct with center _ radius _ in unary
        \\ordinary:=construct((1,2),7)
        \\with:=1;center:=2;radius:=3
        \\last:=construct with center center radius radius
        \\member:=library.image
    , .{}, &diagnostic);
    const script = try parser.parse();
    const mixed = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("construct", mixed.operator.name);
    try std.testing.expectEqual(@as(usize, 2), mixed.args.len);
    try std.testing.expect(mixed.args[0].value == .vector);
    try std.testing.expect(mixed.args[1].value == .grouped);
    const form = script.statements[1].value.mixfix_binding.form;
    try std.testing.expectEqual(@as(usize, 2), form.arity());
    try std.testing.expectEqualStrings("with", form.parts[0].?);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .call);
    const variable_args = script.statements[6].value.assignment.value.value.mixfix_call.args;
    try std.testing.expectEqualStrings("center", variable_args[0].value.name);
    try std.testing.expectEqualStrings("radius", variable_args[1].value.name);
    try std.testing.expectEqualStrings("image", script.statements[7].value.assignment.value.value.member.name);
}

test "mixfix labels stop only their current argument and parentheses isolate nested forms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\mixfix(combine) combine from _ onto _ in unary
        \\first:=combine from f(onto)+p.onto onto [1,2][0]
        \\second:=combine from (combine from p onto q) onto q
        \\if true then
        \\    mixfix(combine) combine with left _ right _ in unary
        \\    inside:=combine with left 3 right 4
        \\end
        \\outside:=combine from 5 onto 6
    , .{}, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expect(first.args[0].value == .binary);
    try std.testing.expect(first.args[1].value == .index);
    const second = script.statements[2].value.assignment.value.value.mixfix_call;
    try std.testing.expect(second.args[0].value.grouped.value == .mixfix_call);
    const branch = script.statements[3].value.conditional.branches[0].body;
    try std.testing.expectEqual(@as(u64, 3), branch[1].value.assignment.value.value.mixfix_call.args[0].value.integer);
    try std.testing.expectEqual(@as(u64, 5), script.statements[4].value.assignment.value.value.mixfix_call.args[0].value.integer);
}

test "mixfix incomplete words and arguments continue lines without swallowing complete statements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\mixfix(combine) combine with first _
        \\    second _ in
        \\    unary
        \\result:=combine with
        \\    first
        \\    (1+2)
        \\    second
        \\    4
        \\following:=5
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), script.statements.len);
    const args = script.statements[1].value.assignment.value.value.mixfix_call.args;
    try std.testing.expect(args[0].value == .grouped);
    try std.testing.expectEqual(@as(u64, 4), args[1].value.integer);
    try std.testing.expectEqualStrings("following", script.statements[2].value.assignment.name);
}

test "mixfix declarations reject ambiguous templates and unparenthesized nested forms" {
    const invalid = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "mixfix(f) f with _ _ in unary", .message = "preceded by a word" },
        .{ .input = "mixfix(f) f with _ ending in unary", .message = "must end" },
        .{ .input = "mixfix(f) f with center in unary", .message = "must end" },
        .{ .input = "mixfix(f) f in unary", .message = "must end" },
        .{ .input = "mixfix(f) f cm _ in unary", .message = "unit 'cm'" },
        .{ .input = "mixfix(f) f then _ in unary", .message = "expected a mixfix word" },
        .{ .input = "mixfix(f) f from _ until _ in unary; x:=f from 1 true 2", .message = "expected mixfix word 'until'" },
        .{ .input = "mixfix(f) f from _ until _ in unary; x:=f from f from 1 until 2 until 3", .message = "require parentheses" },
        .{ .input = "mixfix(crop) _ crop from _ to _ in addition; x:=1 crop 2", .message = "expected mixfix word 'from'" },
        .{ .input = "mixfix(crop) _ crop from _ to _ in addition; x:=1 crop(2)", .message = "expected mixfix word 'from'" },
    };
    for (invalid) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}
