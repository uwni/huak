//! Tests of the header pre-pass: block ranges, import forms, lexical scopes, record headers and scope ordering.
const std = @import("std");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const Options = Parser.Options;
const scanHeaders = Parser.scanHeaders;
const ScopeId = Parser.ScopeId;

test "header scans reuse native Typst block ranges and ignore embedded declarations" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = if (std.mem.startsWith(u8, input, "[\nimport")) "[\nimport \"ignored\" as ignored\nmixfix(hidden) hidden _ in addition\n]" else "[\n#let prefix = \"@\"\n]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    const headers = try scanHeaders(arena.allocator(),
        \\mixfix(visible) visible _ in addition
        \\theme:=typ.module[
        \\import "ignored" as ignored
        \\mixfix(hidden) hidden _ in addition
        \\]
        \\text:=typ[
        \\#let prefix = "@"
        \\]
        \\import "actual" as actual
        \\block
        \\    mixfix(nested) nested _ in addition
        \\end
    , options, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), headers.imports.len);
    try std.testing.expectEqualStrings("actual", headers.imports[0].statement.value.imported.path);
    try std.testing.expectEqual(@as(usize, 2), headers.operators.len);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.operators[0].scope);
    try std.testing.expectEqualStrings("visible", headers.operators[0].statement.value.mixfix_binding.target.name);
    try std.testing.expect(headers.operators[1].scope != 0);
}

test "header scans share import forms and keep exported function bodies scoped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(),
        \\import paint.{stroke as line, fill}
        \\export fn render()->int
        \\    import hidden.*
        \\    mixfix(nested) nested _ in addition
        \\    return 1
        \\end
        \\import "helpers.huak".*
        \\mixfix(visible) visible _ in addition
    , .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), headers.imports.len);
    try std.testing.expectEqualStrings("line", headers.imports[0].statement.value.imported.form.selected[0].alias);
    try std.testing.expect(headers.imports[1].statement.value.imported.form == .all);
    try std.testing.expectEqualStrings("hidden", headers.imports[1].statement.value.imported.path);
    try std.testing.expectEqual(@as(ScopeId, 1), headers.imports[1].scope);
    try std.testing.expect(headers.imports[2].statement.value.imported.form == .all);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.imports[2].scope);
    try std.testing.expectEqual(@as(usize, 2), headers.operators.len);
    try std.testing.expectEqual(@as(ScopeId, 1), headers.operators[0].scope);
    try std.testing.expectEqualStrings("nested", headers.operators[0].statement.value.mixfix_binding.target.name);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.operators[1].scope);
    try std.testing.expectEqualStrings("visible", headers.operators[1].statement.value.mixfix_binding.target.name);
}

test "header scopes separate sibling branches and leave control headers in their parent" {
    const input =
        \\import paint
        \\fn render(argument:int,remaining...)
        \\    if condition then
        \\        import first.*
        \\        mixfix(decorate) decorate _ in unary
        \\        branch_value:=1
        \\    elseif alternative then
        \\        import second.*
        \\    else
        \\        import third.*
        \\    end
        \\    for index in lower:upper do
        \\        while ready do
        \\            block
        \\                import nested.*
        \\                mixfix(decorate) _ decorate _ in addition
        \\            end
        \\        end
        \\    end
        \\    later:=2
        \\end
        \\root_value:=3
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 8), headers.scopes.len);
    try std.testing.expectEqual(@as(usize, 5), headers.imports.len);
    const function: ScopeId = 1;
    try std.testing.expect(headers.scopes[function].kind == .function);
    const first = headers.imports[1].scope;
    const second = headers.imports[2].scope;
    const third = headers.imports[3].scope;
    try std.testing.expect(first != second and second != third and first != third);
    for ([_]ScopeId{ first, second, third }) |branch| {
        try std.testing.expect(headers.scopes[branch].kind == .branch);
        try std.testing.expectEqual(function, headers.scopes[branch].parent.?);
    }
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.find(u8, input, "condition").?));
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.find(u8, input, "alternative").?));
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.find(u8, input, "lower").?));
    const loop = headers.scopeAt(std.mem.find(u8, input, "ready").?);
    try std.testing.expect(headers.scopes[loop].kind == .loop);
    try std.testing.expectEqual(function, headers.scopes[loop].parent.?);
    const while_body = headers.scopeAt(std.mem.find(u8, input, "block").?);
    try std.testing.expect(headers.scopes[while_body].kind == .loop);
    try std.testing.expectEqual(loop, headers.scopes[while_body].parent.?);
    const drawing = headers.imports[4].scope;
    try std.testing.expect(headers.scopes[drawing].kind == .block);
    try std.testing.expectEqual(while_body, headers.scopes[drawing].parent.?);
    try std.testing.expectEqual(first, headers.operators[0].scope);
    try std.testing.expectEqual(drawing, headers.operators[1].scope);
    try std.testing.expectEqual(@as(usize, 2), headers.operators.len);
    try std.testing.expectEqualStrings("branch_value", headers.scopes[first].ordinary_names[0].name);
    const names = headers.scopes[function].ordinary_names;
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for (names, [_][]const u8{ "argument", "remaining", "later" }) |name, expected| {
        try std.testing.expectEqualStrings(expected, name.name);
        try std.testing.expectEqualStrings(expected, input[name.span.start..name.span.end]);
    }
    try std.testing.expectEqualStrings("root_value", headers.scopes[0].ordinary_names[0].name);
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    parser.headers = headers;
    const script = try parser.parse();
    const function_statement = script.statements[1];
    try std.testing.expectEqual(function, headers.scopeAt(function_statement.span.end - 1));
    try std.testing.expectEqual(@as(ScopeId, 0), headers.scopeAt(script.statements[2].span.start));
}

test "header ordinary names belong to their lexical blocks without reading expression ranges" {
    const input =
        \\param size=1
        \\export image :=picture(640, 480)
        \\default image
        \\if flag then assigned:int:=1 end
        \\for index in start:step:stop do
        \\    other:=2
        \\end
        \\fn f(argument:int)
        \\    return argument
        \\    later:=1
        \\end
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
    const names = headers.scopes[0].ordinary_names;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    for (names, [_][]const u8{ "size", "image" }) |name, expected|
        try std.testing.expectEqualStrings(expected, name.name);
    const function = headers.scopeAt(std.mem.find(u8, input, "return argument").?);
    try std.testing.expect(headers.scopes[function].kind == .function);
    try std.testing.expectEqual(@as(usize, 2), headers.scopes[function].ordinary_names.len);
    try std.testing.expectEqualStrings("argument", headers.scopes[function].ordinary_names[0].name);
    try std.testing.expectEqualStrings("later", headers.scopes[function].ordinary_names[1].name);
}

test "record headers ignore fields and opaque Typst while retaining their containing scope" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = "[end struct Bogus import fake typ.show field]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    const input =
        \\export struct Style
        \\    field:int=1
        \\    label:text=typ[end struct Bogus import fake typ.show field]
        \\end
        \\fn f()
        \\    struct Local local:int=2 end
        \\    value:=3
        \\end
        \\after:=4
    ;
    const headers = try scanHeaders(arena.allocator(), input, options, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), headers.records.len);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.records[0].scope);
    try std.testing.expect(headers.records[0].statement.value.structure.exported);
    try std.testing.expect(headers.scopes[headers.records[1].scope].kind == .function);
    try std.testing.expectEqual(@as(usize, 1), headers.scopes[0].ordinary_names.len);
    try std.testing.expectEqualStrings("after", headers.scopes[0].ordinary_names[0].name);
    try std.testing.expectEqual(@as(usize, 1), headers.scopes[headers.records[1].scope].ordinary_names.len);
    try std.testing.expectEqualStrings("value", headers.scopes[headers.records[1].scope].ordinary_names[0].name);
    try std.testing.expectEqual(@as(usize, 0), headers.imports.len);
    try std.testing.expectEqual(@as(usize, 0), headers.typst_declarations.len);
    var frontend = try Parser.init(arena.allocator(), input, options, &diagnostic);
    const script = try frontend.parse();
    try std.testing.expectEqualStrings("[end struct Bogus import fake typ.show field]", script.statements[0].value.structure.fields[1].default.?.value.typst.code);
}

test "scanner scope ordering supports indexed lookup at every source byte" {
    const cases = [_][]const u8{
        "",
        "fn empty() end\nif true then else end\nfor i in 0:1 do end",
        "fn outer(a:int) if a>0 then for i in 0:2 do drawing p do end end elseif a<0 then while false do end else end return a end",
        "if true then if false then else end elseif false then else drawing p do if true then end end end\nfn sibling() return 1 end",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |input| {
        var diagnostic: ?source.Diagnostic = null;
        const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expect(headers.scopes.len != 0);
        try std.testing.expectEqual(@as(?ScopeId, null), headers.scopes[0].parent);
        try std.testing.expect(headers.scopes[0].kind == .module);
        for (headers.scopes, 0..) |scope, id| {
            if (id != 0) try std.testing.expect(scope.parent != null);
            if (id != 0) try std.testing.expect(headers.scopes[id - 1].body.start <= scope.body.start);
            if (scope.parent) |parent| {
                try std.testing.expect(parent < id);
                try std.testing.expect(headers.scopes[parent].body.start <= scope.body.start);
                try std.testing.expect(scope.body.end <= headers.scopes[parent].body.end);
                for (headers.scopes[0..id]) |earlier| if (earlier.parent == scope.parent) {
                    try std.testing.expect(earlier.body.end <= scope.body.start);
                };
            }
        }
        for (0..input.len + 2) |offset| {
            var reference: ScopeId = 0;
            for (headers.scopes, 0..) |scope, id| if (scope.body.start <= offset and offset < scope.body.end) {
                reference = @intCast(id);
            };
            try std.testing.expectEqual(reference, headers.scopeAt(offset));
        }
        try std.testing.expectEqual(@as(ScopeId, 0), headers.scopeAt(std.math.maxInt(usize)));
    }
}
