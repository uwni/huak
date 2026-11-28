//! Tests of embedded Typst: ellipses, source-block providers, typ.show and typ.module.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const Options = Parser.Options;
const scanHeaders = Parser.scanHeaders;
const ScopeId = Parser.ScopeId;
const TestSourceParser = Parser.TestSourceParser;

test "native Typst ellipses remain opaque inside variadic functions" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = "[#f(..args) ... end]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    const input = "export fn label(args...) return typ[#f(..args) ... end] end\nimport paint.*";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    var parser = try Parser.init(arena.allocator(), input, options, &diagnostic);
    const script = try parser.parse();
    const declaration = script.statements[0].value.function;
    try std.testing.expect(declaration.params[0].variadic);
    try std.testing.expectEqualStrings("[#f(..args) ... end]", declaration.body[0].value.return_value.?.value.typst.code);
    try std.testing.expect(script.statements[1].value.imported.form == .all);
    const headers = try scanHeaders(arena.allocator(), input, options, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), headers.imports.len);
    try std.testing.expectEqualStrings("paint", headers.imports[0].statement.value.imported.path);
}

test "embedded source requires a native source-block provider" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "t:=typ[Hello]\n", .{}, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "source-block") != null);
}

test "native Typst blocks preserve their source and resume host expressions" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = if (std.mem.startsWith(u8, input, "[#let")) "[#let x=2]" else "[Hello]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    var parser = try Parser.init(arena.allocator(), "typst:=2\nvalue:=typ[Hello]\n", options, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    try std.testing.expectEqualStrings("typst", script.statements[0].value.assignment.name);
    try std.testing.expectEqualStrings("[Hello]", script.statements[1].value.assignment.value.value.typst.code);
    parser = try Parser.init(arena.allocator(), "theme:=typ.module [#let x=2]; value:=measure(typ [Hello],2)", options, &diagnostic);
    const inline_script = try parser.parse();
    try std.testing.expectEqualStrings("[#let x=2]", inline_script.statements[0].value.assignment.value.value.typst_module.code);
    const call = inline_script.statements[1].value.assignment.value.value.call;
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("[Hello]", call.args[0].value.typst.code);
    parser = try Parser.init(arena.allocator(), "value:=typst\nHello\nend\n", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    for ([_][]const u8{ "value=typ\nHello\nend\n", "value=typ;\nend\n", "value=typ{Hello}" }) |input| {
        diagnostic = null;
        parser = try Parser.init(arena.allocator(), input, options, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "expected '") != null);
    }
}

test "Typst block providers cannot return ranges outside the source" {
    const Blocks = struct {
        fn block(context: *anyopaque, _: []const u8) !usize {
            const length: *usize = @ptrCast(@alignCast(context));
            return length.*;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 0, 1, 3, std.math.maxInt(usize) }) |invalid_length| {
        var length = invalid_length;
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), "value:=typ[Hello]", .{ .source_parser = .{ .ptr = &length, .vtable = &.{ .block = Blocks.block } } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), "invalid range") != null);
    }
}

test "typ.show declarations retain their paths and lexical header scopes" {
    const input = "typ.show theme.style\nfn label(value:int)->void\ntyp.show theme.label.style\nif true then\ntyp.show inside.style\nelse\ntyp.show other.style\nend\nend\n";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 4), headers.typst_declarations.len);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.typst_declarations[0].scope);
    try std.testing.expect(headers.scopes[headers.typst_declarations[1].scope].kind == .function);
    try std.testing.expect(headers.scopes[headers.typst_declarations[2].scope].kind == .branch);
    try std.testing.expect(headers.typst_declarations[2].scope != headers.typst_declarations[3].scope);
    var frontend = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try frontend.parse();
    for ([_][]const []const u8{ &.{ "theme", "style" }, &.{ "theme", "label", "style" } }, [_]*const ast.Stmt{ script.statements[0], script.statements[1].value.function.body[0] }) |expected, declared| {
        const path = declared.value.typst_show;
        try std.testing.expectEqual(expected.len, path.len);
        for (path, expected) |segment, name| {
            try std.testing.expectEqualStrings(name, segment.name);
            try std.testing.expectEqualStrings(name, input[segment.span.start..segment.span.end]);
        }
    }
    for ([_][]const u8{ "typ.show", "typ.show theme", "typ.show theme.", "typ.show 42", "typ.show theme.style=1", "typ.show theme.style, other.style", "x:=typ.show theme.style" }) |invalid| {
        var broken = try Parser.init(arena.allocator(), invalid, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, broken.parse());
    }
}

test "typ.module keeps opaque Typst code and Typst blocks record the huak members they read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const options: Options = .{ .source_parser = TestSourceParser.parser };
    const input =
        \\fn style(size:length)->typ.module
        \\    return typ.module[#let style(body) = text(huak.size, body) end struct Bogus import fake typ.show field]
        \\end
        \\marked:=typ.module[#let style(it) = [*#it* end]]
        \\typ.show marked.style
        \\if true then
        \\    typ.show inside.style
        \\end
        \\caption:=typ[#huak.size $huak.mark(1)$ #huak.size]
    ;
    const headers = try scanHeaders(arena.allocator(), input, options, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), headers.records.len);
    try std.testing.expectEqual(@as(usize, 0), headers.imports.len);
    try std.testing.expectEqual(@as(usize, 2), headers.typst_declarations.len);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.typst_declarations[0].scope);
    try std.testing.expect(headers.scopes[headers.typst_declarations[1].scope].kind == .branch);
    var frontend = try Parser.init(arena.allocator(), input, options, &diagnostic);
    const script = try frontend.parse();
    const function = script.statements[0].value.function;
    try std.testing.expectEqualStrings("typ.module", function.result.?.name);
    const module = function.body[0].value.return_value.?.value.typst_module;
    try std.testing.expectEqualStrings("[#let style(body) = text(huak.size, body) end struct Bogus import fake typ.show field]", module.code);
    try std.testing.expectEqual(@as(usize, 1), module.uses.len);
    try std.testing.expectEqualStrings("size", module.uses[0].name);
    try std.testing.expectEqualStrings("size", input[module.uses[0].span.start..module.uses[0].span.end]);
    const marked = script.statements[1].value.assignment.value.value.typst_module;
    try std.testing.expectEqualStrings("[#let style(it) = [*#it* end]]", marked.code);
    try std.testing.expectEqual(@as(usize, 0), marked.uses.len);
    const caption = script.statements[4].value.assignment.value.value.typst;
    try std.testing.expectEqual(@as(usize, 3), caption.uses.len);
    try std.testing.expect(!caption.rebound);
    for (caption.uses, [_][]const u8{ "size", "mark", "size" }) |use, name| {
        try std.testing.expectEqualStrings(name, use.name);
        try std.testing.expectEqualStrings(name, input[use.span.start..use.span.end]);
    }
    for ([_][]const u8{ "r:=typ.module", "r:=typ.module{body}", "r:=typ.modules[x]", "r:=typ.show theme.style", "r:=typ.module[x" }) |invalid| {
        var broken = try Parser.init(arena.allocator(), invalid, options, &diagnostic);
        try std.testing.expectError(error.LanguageError, broken.parse());
    }
}

test "typ.module names the type in declaration and field annotations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const input =
        \\typed: typ.module := given
        \\struct Styled
        \\    style: typ.module
        \\end
        \\block
        \\    local: typ.module := typed
        \\end
    ;
    const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), headers.records.len);
    try std.testing.expectEqual(@as(usize, 0), headers.source_blocks.len);
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("typ.module", script.statements[0].value.assignment.annotation.?.name);
    try std.testing.expectEqualStrings("typ.module", script.statements[1].value.structure.fields[0].annotation.name);
    for ([_][]const u8{ "x: typ := y", "x: typ.show := y", "x: typ.module.style := y" }) |invalid| {
        var broken = try Parser.init(arena.allocator(), invalid, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, broken.parse());
    }
}
