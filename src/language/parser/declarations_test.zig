//! Tests of exports, rest parameters, default outputs and record declarations.
const std = @import("std");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");

test "export forms and inferred parameters remain syntax-only statements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\param path="."
        \\export later
        \\export named:=picture(20,30)
        \\default named
        \\later:=named
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 5), script.statements.len);
    try std.testing.expect(script.statements[0].value.parameter.annotation == null);
    try std.testing.expectEqualStrings("path", script.statements[0].value.parameter.name);
    try std.testing.expectEqualStrings("later", script.statements[1].value.exported.names[0].name);
    try std.testing.expect(script.statements[1].value.exported.value == null);
    try std.testing.expectEqualStrings("named", script.statements[2].value.exported.names[0].name);
    try std.testing.expectEqualStrings("picture", script.statements[2].value.exported.value.?.value.call.name);
    try std.testing.expectEqualStrings("named", script.statements[3].value.default_output.value.name);
}

test "export function modifiers and name lists preserve existing declaration shapes" {
    const input =
        \\export fn doubled(x:int)->int return 2*x end
        \\fn private(x:int)->int return x end
        \\export doubled,
        \\    private, colors
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), script.statements.len);
    const declaration = script.statements[0];
    try std.testing.expect(declaration.value.function.exported);
    try std.testing.expectEqual(@as(usize, 0), declaration.span.start);
    try std.testing.expectEqualStrings("doubled", declaration.value.function.name);
    try std.testing.expectEqualStrings("x", declaration.value.function.params[0].name);
    try std.testing.expectEqualStrings("int", declaration.value.function.result.?.name);
    try std.testing.expect(!script.statements[1].value.function.exported);
    const names = script.statements[2].value.exported.names;
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for (names, [_][]const u8{ "doubled", "private", "colors" }) |name, expected| {
        try std.testing.expectEqualStrings(expected, name.name);
        try std.testing.expectEqualStrings(expected, input[name.span.start..name.span.end]);
    }
    try std.testing.expect(script.statements[2].value.exported.value == null);
}

test "function rest parameters preserve element annotations and complete source spans" {
    const input =
        \\fn collect(args...) return args end
        \\export fn points(label:string, points:vec2...)->list return points end
        \\fn ordinary(value:int)->int return value end
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    const inferred = script.statements[0].value.function.params;
    try std.testing.expectEqual(@as(usize, 1), inferred.len);
    try std.testing.expect(inferred[0].variadic);
    try std.testing.expectEqualStrings("args", inferred[0].name);
    try std.testing.expectEqualStrings("any", inferred[0].annotation.name);
    try std.testing.expectEqualStrings("args", input[inferred[0].annotation.span.start..inferred[0].annotation.span.end]);
    try std.testing.expectEqualStrings("args...", input[inferred[0].span.start..inferred[0].span.end]);
    const typed = script.statements[1].value.function;
    try std.testing.expect(typed.exported);
    try std.testing.expectEqual(@as(usize, 2), typed.params.len);
    try std.testing.expect(!typed.params[0].variadic);
    try std.testing.expectEqualStrings("string", typed.params[0].annotation.name);
    try std.testing.expect(typed.params[1].variadic);
    try std.testing.expectEqualStrings("vec2", typed.params[1].annotation.name);
    try std.testing.expectEqualStrings("points:vec2...", input[typed.params[1].span.start..typed.params[1].span.end]);
    try std.testing.expectEqualStrings("list", typed.result.?.name);
    try std.testing.expect(!script.statements[2].value.function.params[0].variadic);
}

test "rest parameters allow no fixed prefix and multiline typed declarations" {
    for ([_][]const u8{
        "fn empty(args...) end",
        "fn typed(args:any...) end",
        "fn multiline(\nfirst:int,\nrest:\nfloat...\n)\nend",
    }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        const script = try parser.parse();
        const params = script.statements[0].value.function.params;
        try std.testing.expect(params.len > 0);
        try std.testing.expect(params[params.len - 1].variadic);
    }
}

test "rest parameter declarations reject missing names types and following parameters" {
    const cases = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "fn missing(...) end", .message = "expected parameter name" },
        .{ .input = "fn untyped(value) end", .message = "fixed function parameters need a type annotation" },
        .{ .input = "fn missing_type(value:...) end", .message = "expected a type name" },
        .{ .input = "fn following(rest..., value:int) end", .message = "must be the last" },
        .{ .input = "fn multiple(first..., second...) end", .message = "must be the last" },
        .{ .input = "fn trailing(rest...,) end", .message = "must be the last" },
        .{ .input = "fn repeated(rest......) end", .message = "must be the last" },
        .{ .input = "fn fixed(value,rest...) end", .message = "fixed function parameters need a type annotation" },
        .{ .input = "fn old_dots(rest..) end", .message = "fixed function parameters need a type annotation" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.find(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "export name lists reject missing names and mixed initializers" {
    const invalid = [_][]const u8{
        "export",                                 "export ,foo",                  "export foo,",       "export foo,\n",      "export foo,;bar:=1",
        "export foo,default",                     "export foo,bar=1",             "export foo:=1,bar", "export fn foo( end", "default first,second=1",
        "export first:=1,second=2;default first", "export first:=;default first",
    };
    for (invalid) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "module exports and default output expressions are distinct" {
    const input = "export plate:=picture(180mm,180mm);default plate\ndefault other\n";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    const combined = script.statements[0].value.exported;
    try std.testing.expect(combined.value != null);
    try std.testing.expectEqual(@as(usize, 1), combined.names.len);
    try std.testing.expectEqualStrings("plate", combined.names[0].name);
    try std.testing.expectEqualStrings("plate", input[combined.names[0].span.start..combined.names[0].span.end]);
    try std.testing.expectEqualStrings("picture", combined.value.?.value.call.name);
    const plain = script.statements[2].value.default_output;
    try std.testing.expectEqualStrings("other", plain.value.name);
}

test "struct declarations retain typed fields defaults qualified types and export spans" {
    const input =
        \\export struct Style
        \\    color: color
        \\    width: length = 2mm;
        \\    base: palette . Base = palette.Base(weight: 3)
        \\end
        \\struct Empty end
        \\param initial: palette.Style
        \\fn apply(style: palette.Style)->palette . Style return style end
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var frontend = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try frontend.parse();
    const statement_ = script.statements[0];
    const structure_ = statement_.value.structure;
    try std.testing.expect(structure_.exported);
    try std.testing.expectEqualStrings("Style", structure_.name);
    try std.testing.expectEqual(@as(usize, 0), statement_.span.start);
    try std.testing.expectEqual(@as(usize, 3), structure_.fields.len);
    try std.testing.expect(structure_.fields[0].default == null);
    try std.testing.expectEqualStrings("color: color", input[structure_.fields[0].span.start..structure_.fields[0].span.end]);
    try std.testing.expect(structure_.fields[1].default.?.value == .quantity);
    try std.testing.expectEqualStrings("palette.Base", structure_.fields[2].annotation.name);
    try std.testing.expectEqualStrings("weight", structure_.fields[2].default.?.value.call.argument_names[1].?);
    try std.testing.expectEqual(@as(usize, 0), script.statements[1].value.structure.fields.len);
    try std.testing.expectEqualStrings("palette.Style", script.statements[2].value.parameter.annotation.?.name);
    try std.testing.expectEqualStrings("palette.Style", script.statements[3].value.function.params[0].annotation.name);
    try std.testing.expectEqualStrings("palette.Style", script.statements[3].value.function.result.?.name);
}
