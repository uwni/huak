//! Tests of path joins, units, strings, list slices, dictionaries and aggregate syntax.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const units = @import("../../drawing/units.zig");
const Parser = @import("../Parser.zig");

test "native path joins preserve kinds units cycle and operator-line continuation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\curve:=(15mm,120mm)~~
        \\// The next knot belongs to this path.
        \\(50mm,132mm)--corner~~cycle
        \\size:=(a~~b).bounds()
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    const final = script.statements[0].value.assignment.value.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.smooth, final.kind);
    try std.testing.expect(final.right.value == .cycle);
    const middle = final.left.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.straight, middle.kind);
    try std.testing.expectEqualStrings("corner", middle.right.value.name);
    const first = middle.left.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.smooth, first.kind);
    try std.testing.expectEqual(units.Unit.mm, first.left.value.vector.x.value.quantity.unit);
    const postfix = script.statements[1].value.assignment.value.value.call;
    try std.testing.expect(postfix.dot);
    try std.testing.expectEqualStrings("bounds", postfix.name);
    try std.testing.expect(postfix.args[0].value.grouped.value == .path_join);
}

test "dangling path joins fail at the missing operand" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "p:=a~~", "p:=a--\n", "p:=a~~;", "p:=a~~--b", "p:=~~a", "p:=a..b", "cycle=1" }) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "native unit syntax accepts horizontal spacing and preserves identifier boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\a:=1cm; b:=1 cm
        \\c:=2pi rad; d:=2 pi rad; e:=(2*pi) rad
        \\inch:=1in
        \\separate:=2
        \\cm:=3
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(units.Unit.cm, script.statements[0].value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(units.Unit.cm, script.statements[1].value.assignment.value.value.quantity.unit);
    for (script.statements[2..5]) |stmt| try std.testing.expectEqual(units.Unit.rad, stmt.value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(units.Unit.in, script.statements[5].value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(@as(usize, 8), script.statements.len);
    for ([_][]const u8{ "angle:=2pirad", "length:=2unknown" }) |input| {
        parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "identifiers are not split") != null);
    }
}

test "strings use JSON escapes and preserve unicode" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "a:=\"中文\\n\\u03bb\"\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("中文\nλ", script.statements[0].value.assignment.value.value.string);
    parser = try Parser.init(arena.allocator(), "a:=1\nb:=\"\\q\"", .{}, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    const position = diagnostic.?.position("a:=1\nb:=\"\\q\"");
    try std.testing.expectEqual(@as(usize, 2), position.line);
    try std.testing.expectEqual(@as(usize, 4), position.column);
}

test "list slice forms share the loop range grammar and compose with postfix calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\element:=items[2]
        \\tail:=items[1:]
        \\window:=items[1:3]
        \\stride:=items[5:-2:1]
        \\chained:=make()[first():delta():last()][0].finish()
        \\for i in first():delta():last() do end
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(u64, 2), script.statements[0].value.assignment.value.value.index.index.value.integer);
    const tail = script.statements[1].value.assignment.value.value.slice;
    try std.testing.expectEqualStrings("items", tail.object.value.name);
    try std.testing.expectEqual(@as(u64, 1), tail.range.start.value.integer);
    try std.testing.expect(tail.range.step == null and tail.range.stop == null);
    const window = script.statements[2].value.assignment.value.value.slice.range;
    try std.testing.expect(window.step == null);
    try std.testing.expectEqual(@as(u64, 3), window.stop.?.value.integer);
    const stride = script.statements[3].value.assignment.value.value.slice.range;
    try std.testing.expectEqual(ast.Unary.negate, stride.step.?.value.unary.op);
    try std.testing.expectEqual(@as(u64, 2), stride.step.?.value.unary.operand.value.integer);
    try std.testing.expectEqual(@as(u64, 1), stride.stop.?.value.integer);
    const chained = script.statements[4].value.assignment.value.value.call.args[0].value.index.object.value.slice;
    try std.testing.expectEqualStrings("make", chained.object.value.call.name);
    const loop = script.statements[5].value.for_loop;
    try std.testing.expectEqualStrings(loop.iterable.range.start.value.call.name, chained.range.start.value.call.name);
    try std.testing.expectEqualStrings(loop.iterable.range.step.?.value.call.name, chained.range.step.?.value.call.name);
    try std.testing.expectEqualStrings(loop.iterable.range.stop.?.value.call.name, chained.range.stop.?.value.call.name);
}

test "list slices require a start and do not add multi-index or extra open forms" {
    for ([_][]const u8{ "items[:]", "items[:3]", "items[1,2]", "items[1::3]", "items[1:2:]", "items[1:2:3:4]", "for i in 1: do end" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "dictionaries and named calls preserve order decoded keys and nested assignment targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var frontend = try Parser.init(arena.allocator(),
        \\options:={"line-width": 2mm, "nested": {"value": [1,2]},}
        \\empty:={}
        \\style:=Style(1, width: 2mm, options: options)
        \\other:=palette.Style(width: 3mm,)
        \\plain:=f(1,2)
        \\data[0].items["key"].width=4mm
        \\data[lookup("key")]=style
        \\name:=2
        \\values += [3]
    , .{}, &diagnostic);
    const script = try frontend.parse();
    const dict = script.statements[0].value.assignment.value.value.dict;
    try std.testing.expectEqual(@as(usize, 2), dict.len);
    try std.testing.expectEqualStrings("line-width", dict[0].key);
    try std.testing.expect(dict[0].value.value == .quantity);
    try std.testing.expect(dict[1].value.value.dict[0].value.value == .list);
    try std.testing.expectEqual(@as(usize, 0), script.statements[1].value.assignment.value.value.dict.len);
    const call = script.statements[2].value.assignment.value.value.call;
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expect(call.argument_names[0] == null);
    try std.testing.expectEqualStrings("width", call.argument_names[1].?);
    try std.testing.expectEqualStrings("options", call.argument_names[2].?);
    const qualified = script.statements[3].value.assignment.value.value.call;
    try std.testing.expect(qualified.dot);
    try std.testing.expect(qualified.argument_names[0] == null);
    try std.testing.expectEqualStrings("width", qualified.argument_names[1].?);
    try std.testing.expectEqual(@as(usize, 0), script.statements[4].value.assignment.value.value.call.argument_names.len);
    const target = script.statements[5].value.set.target.value.member;
    try std.testing.expectEqualStrings("width", target.name);
    try std.testing.expect(target.object.value.index.object.value == .member);
    try std.testing.expect(script.statements[6].value.set.target.value.index.index.value == .call);
    try std.testing.expect(script.statements[7].value == .assignment);
    try std.testing.expect(script.statements[8].value == .list_append);
}

test "aggregate syntax rejects malformed fields dictionaries calls and lvalues" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "struct end", .message = "expected struct name" },
        .{ .code = "struct A x:int", .message = "expected 'end'" },
        .{ .code = "struct A x:=1 end", .message = "explicit type annotation" },
        .{ .code = "struct A x: end", .message = "expected a type name" },
        .{ .code = "struct A x:int; x:int end", .message = "duplicate struct field" },
        .{ .code = "struct A x:int y:int end", .message = "between struct fields" },
        .{ .code = "struct A fn method() end end", .message = "typed struct field" },
        .{ .code = "x: lib. = 1", .message = "type name after '.'" },
        .{ .code = "x:={key:1}", .message = "keys must be string literals" },
        .{ .code = "x:={1:2}", .message = "keys must be string literals" },
        .{ .code = "x:={\"a\":1,\"\\u0061\":2}", .message = "duplicate dictionary key" },
        .{ .code = "x:={\"a\" 1}", .message = "':' after dictionary key" },
        .{ .code = "x:={\"a\":}", .message = "expected an expression" },
        .{ .code = "x:=f(a:1,2)", .message = "positional arguments cannot follow" },
        .{ .code = "x:=f(a:1,a:2)", .message = "duplicate named argument" },
        .{ .code = "x:=f(a:)", .message = "expected an expression" },
        .{ .code = "x:=f(\"a\":1)", .message = "')' after arguments" },
        .{ .code = "a+b=2", .message = "assignment target" },
        .{ .code = "data.x:int=2", .message = "assignment target" },
        .{ .code = "data[0:2]=[]", .message = "assignment target" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var frontend = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, frontend.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), case.message) != null);
    }
}
