//! Tests of reserved words, list appends, control flow, block bodies and delimiters.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");

test "default and export are reserved while defer is an ordinary name" {
    const invalid = [_][]const u8{
        "default=1", "fn default();end", "fn f(default:int);end", "param default=1", "export default picture()", "default", "export foo.bar", "export foo(1)", "param missing",
    };
    for (invalid) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "defer:=1\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("defer", script.statements[0].value.assignment.name);
}

test "list append assignment is a statement with an existing named target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "items+=value;items += [1,2]\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    const first = script.statements[0].value.list_append;
    try std.testing.expectEqualStrings("items", first.name);
    try std.testing.expectEqualStrings("value", first.value.value.name);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].span.start);
    try std.testing.expectEqual(@as(usize, 12), script.statements[0].span.end);
    try std.testing.expect(script.statements[1].value.list_append.value.value == .list);
}

test "list append assignment cannot be annotated chained or used as an expression" {
    for ([_][]const u8{
        "(items)+=1",        "items:list+=1",
        "value:=(items+=1)", "items+=other+=1",
        "items+=",           "param items+=1",
        "export items+=1",
    }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "script functions control flow arrays pairs and source positions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "param n: int = 4\nfn foo(x: int) -> int\nif x <= 1 then return 1; else return x * foo(x-1); end\nend\na := [foo(n), (2,\n3)]\nfor i in 1:2:9 do\ncontinue\nend\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), script.statements.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].span.start);
    try std.testing.expectEqualStrings("foo", script.statements[1].value.function.name);
    try std.testing.expect(script.statements[3].value.for_loop.iterable.range.step != null);
}

test "explicit control delimiters support nested bodies on one line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "for i in 1:2:9 do while i<5 do if i==1 then continue elseif i==3 then break else i=i+1 end end end", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), script.statements.len);
    const loop = script.statements[0].value.for_loop;
    try std.testing.expectEqual(@as(u64, 2), loop.iterable.range.step.?.value.integer);
    const nested = loop.body[0].value.while_loop.body[0].value.conditional;
    try std.testing.expectEqual(@as(usize, 2), nested.branches.len);
    try std.testing.expect(nested.branches[0].body[0].value == .continue_loop);
    try std.testing.expect(nested.branches[1].body[0].value == .break_loop);
    try std.testing.expectEqual(@as(usize, 1), nested.otherwise.len);
}

test "all block heads accept inline and multiline bodies without line-boundary rules" {
    const Statement = std.meta.Tag(@FieldType(ast.Stmt, "value"));
    const cases = [_]struct { inline_: []const u8, multiline: []const u8, kind: Statement }{
        .{ .inline_ = "fn f(x:int)->int return x end", .multiline = "fn f(x:int)->int\nreturn x\nend", .kind = .function },
        .{ .inline_ = "fn empty() end", .multiline = "fn empty()\nend", .kind = .function },
        .{ .inline_ = "precedence custom above addition;associativity left end", .multiline = "precedence custom\nabove addition\nassociativity left\nend", .kind = .precedence_group },
        .{ .inline_ = "precedence empty end", .multiline = "precedence empty\nend", .kind = .precedence_group },
        .{ .inline_ = "block mixfix(draw) draw _ in logical_or;draw curve end", .multiline = "block\nmixfix(draw) draw _ in logical_or\ndraw curve\nend", .kind = .expression },
        .{ .inline_ = "if ready then end", .multiline = "if ready\nthen\nend", .kind = .conditional },
        .{ .inline_ = "for i in 1:3 do end", .multiline = "for i in 1:3\ndo\nend", .kind = .for_loop },
        .{ .inline_ = "while ready do end", .multiline = "while ready\ndo\nend", .kind = .while_loop },
    };
    for (cases) |case| for ([_][]const u8{ case.inline_, case.multiline }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        const script = try parser.parse();
        try std.testing.expectEqual(@as(usize, 1), script.statements.len);
        try std.testing.expectEqual(case.kind, std.meta.activeTag(script.statements[0].value));
    };
}

test "control bodies allow empty blocks and optional separators after their delimiters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\if ready then end
        \\if first
        \\then;
        \\elseif second
        \\then
        \\else
        \\end
        \\while ready
        \\do;end
        \\for i in 1:3
        \\do
        \\end
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), script.statements.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].value.conditional.branches[0].body.len);
    try std.testing.expectEqual(@as(usize, 2), script.statements[1].value.conditional.branches.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[1].value.conditional.otherwise.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[2].value.while_loop.body.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[3].value.for_loop.body.len);
}

test "control delimiters are required and do not remove ordinary statement boundaries" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "if true\nend", .message = "expected 'then'" },
        .{ .code = "if true do end", .message = "expected 'then'" },
        .{ .code = "if true then elseif false\nend", .message = "expected 'then'" },
        .{ .code = "if true;then end", .message = "expected 'then'" },
        .{ .code = "while true\nend", .message = "expected 'do'" },
        .{ .code = "while true then end", .message = "expected 'do'" },
        .{ .code = "for i in 1:3\nend", .message = "expected 'do'" },
        .{ .code = "for i in 1:3 then end", .message = "expected 'do'" },
        .{ .code = "for i in 1:3;do end", .message = "expected 'do'" },
        .{ .code = "if true then print(1) if true then end end", .message = "between statements" },
        .{ .code = "fn f() return 1 return 2 end", .message = "between statements" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "then and do cannot be used as declaration names" {
    for ([_][]const u8{ "then=1", "do=1", "param do=1", "fn then();end", "fn f(do:int);end", "import \"other\" as then" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}
