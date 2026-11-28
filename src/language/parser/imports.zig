//! The import grammar: paths, namespaces, selected bindings and aliases.
const std = @import("std");
const Lexer = @import("../Lexer.zig");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const expressions = @import("expressions.zig");
const ungroup = ast.ungroup;

/// `import` with its path and binding form.
pub fn importStatement(self: *Parser) anyerror!*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    const path_span = self.current.span;
    var bare = false;
    var finish = path_span;
    const path = if (self.current.kind == .identifier) path: {
        bare = true;
        const name = self.current;
        try self.advance();
        break :path self.text(name);
    } else path: {
        const expression_ = try expressions.prefix(self);
        const literal = ungroup(expression_);
        if (literal.value != .string) return self.fail(expression_.span, "import path must be a string literal or module name", .{});
        finish = expression_.span;
        break :path literal.value.string;
    };
    var namespace_path: std.ArrayList([]const u8) = .empty;
    const form: ast.ImportForm = if (try self.accept(.dot)) form: {
        while (true) {
            if (self.current.kind == .star) {
                finish = self.current.span;
                try self.advance();
                break :form .all;
            }
            var bindings: std.ArrayList(ast.ImportBinding) = .empty;
            if (try self.accept(.lbrace)) {
                while (true) {
                    const binding = try importBinding(self);
                    try bindings.append(self.allocator, binding);
                    if (!try self.accept(.comma) or self.current.kind == .rbrace) break;
                }
                finish = (try self.expect(.rbrace, "expected '}' after selected imports")).span;
            } else {
                const name = self.current;
                if (name.kind != .identifier) return self.fail(name.span, "expected an exported member name", .{});
                try self.advance();
                if (try self.accept(.dot)) {
                    try namespace_path.append(self.allocator, self.text(name));
                    continue;
                }
                const binding = try importBindingAfter(self, name);
                try bindings.append(self.allocator, binding);
                finish = binding.span;
            }
            break :form .{ .selected = try bindings.toOwnedSlice(self.allocator) };
        }
    } else if (try importAlias(self)) |alias| form: {
        finish = alias.span;
        break :form .{ .namespace = self.text(alias) };
    } else .{ .namespace = try importNamespace(self, path, path_span) };
    return self.createStmt(.join(start, finish), .{ .imported = .{ .path = path, .bare = bare, .namespace_path = try namespace_path.toOwnedSlice(self.allocator), .form = form } });
}

fn importBinding(self: *Parser) !ast.ImportBinding {
    const name = self.current;
    if (name.kind != .identifier) return self.fail(name.span, "expected an exported member name", .{});
    try self.advance();
    return importBindingAfter(self, name);
}

fn importBindingAfter(self: *Parser, name: Lexer.Token) !ast.ImportBinding {
    const alias = try importAlias(self) orelse name;
    return .{ .name = self.text(name), .alias = self.text(alias), .span = .join(name.span, alias.span) };
}

fn importAlias(self: *Parser) !?Lexer.Token {
    if (self.current.kind != .identifier or !std.mem.eql(u8, self.text(self.current), "as")) return null;
    try self.advance();
    return try self.expect(.identifier, "expected a local name after 'as'");
}

fn importNamespace(self: *Parser, path: []const u8, span: source.Span) ![]const u8 {
    const name = std.Io.Dir.path.stem(path);
    var diagnostic: ?source.Diagnostic = null;
    var lexer: Lexer = .{ .source = name, .diagnostic = &diagnostic };
    const first = lexer.next() catch return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    const last = lexer.next() catch return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    if (first.kind != .identifier or last.kind != .eof or first.span.end != name.len)
        return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    return name;
}

test "module imports distinguish namespaces wildcards and selected local bindings" {
    const input =
        \\import paint
        \\import paint as p
        \\import paint.*
        \\import paint.foo
        \\import paint.foo as local
        \\import paint.{foo as first,
        \\    bar,
        \\}
        \\import "shapes/geometry.huak"
        \\import "shapes/dashed-name.huak" as shapes
        \\import ("geometry.huak").{foo, bar as other}
        \\import "geometry.huak".*
        \\import "geometry.huak".image as image
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 11), script.statements.len);
    const namespace = script.statements[0].value.imported;
    try std.testing.expect(namespace.bare);
    try std.testing.expectEqualStrings("paint", namespace.path);
    try std.testing.expectEqualStrings("paint", namespace.form.namespace);
    try std.testing.expectEqualStrings("p", script.statements[1].value.imported.form.namespace);
    try std.testing.expect(script.statements[2].value.imported.form == .all);
    const selected = script.statements[3].value.imported.form.selected;
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("foo", selected[0].name);
    try std.testing.expectEqualStrings("foo", selected[0].alias);
    try std.testing.expectEqualStrings("local", script.statements[4].value.imported.form.selected[0].alias);
    const multiple = script.statements[5].value.imported.form.selected;
    try std.testing.expectEqual(@as(usize, 2), multiple.len);
    try std.testing.expectEqualStrings("foo", multiple[0].name);
    try std.testing.expectEqualStrings("first", multiple[0].alias);
    try std.testing.expectEqualStrings("foo as first", input[multiple[0].span.start..multiple[0].span.end]);
    try std.testing.expectEqualStrings("bar", multiple[1].alias);
    try std.testing.expectEqualStrings("bar", input[multiple[1].span.start..multiple[1].span.end]);
    const quoted = script.statements[6].value.imported;
    try std.testing.expect(!quoted.bare);
    try std.testing.expectEqualStrings("shapes/geometry.huak", quoted.path);
    try std.testing.expectEqualStrings("geometry", quoted.form.namespace);
    try std.testing.expectEqualStrings("shapes", script.statements[7].value.imported.form.namespace);
    try std.testing.expectEqualStrings("other", script.statements[8].value.imported.form.selected[1].alias);
    try std.testing.expect(script.statements[9].value.imported.form == .all);
    const default = script.statements[10].value.imported.form.selected[0];
    try std.testing.expectEqualStrings("image", default.name);
    try std.testing.expectEqualStrings("image", default.alias);
}

test "module import syntax rejects ambiguous or unusable local names" {
    const invalid = [_][]const u8{
        "import",               "import 123",                  "import \"x.huak\"+\"y.huak\"", "import paint.",
        "import paint.{}",      "import paint.{foo",           "import paint.{,foo}",          "import paint.{foo,,bar}",
        "import paint.foo as",  "import paint.foo as default", "import paint.* as p",          "import paint.{foo} as p",
        "import paint.default", "import paint.foo.",           "import \"dashed-name.huak\"",  "import \"fn.huak\"",
        "import \"a.b.huak\"",  "import \".huak\"",
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

test "nested module imports separate namespace paths from final bindings" {
    const input =
        \\import std.math
        \\import std.math as m
        \\import std.math.sin as sine
        \\import std.math.{sin, PI as pi}
        \\import std.math.*
        \\import ("library.huak").first.second.value
        \\import "library.huak".first.image as result
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 7), script.statements.len);
    const simple = script.statements[0].value.imported;
    try std.testing.expectEqualStrings("std", simple.path);
    try std.testing.expectEqual(@as(usize, 0), simple.namespace_path.len);
    try std.testing.expectEqualStrings("math", simple.form.selected[0].name);
    try std.testing.expectEqualStrings("m", script.statements[1].value.imported.form.selected[0].alias);
    const selected = script.statements[2].value.imported;
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"math"}), selected.namespace_path);
    try std.testing.expectEqualStrings("sin", selected.form.selected[0].name);
    try std.testing.expectEqualStrings("sine", selected.form.selected[0].alias);
    const multiple = script.statements[3].value.imported;
    try std.testing.expectEqualDeep(selected.namespace_path, multiple.namespace_path);
    try std.testing.expectEqualStrings("pi", multiple.form.selected[1].alias);
    const all = script.statements[4].value.imported;
    try std.testing.expectEqualDeep(selected.namespace_path, all.namespace_path);
    try std.testing.expect(all.form == .all);
    const quoted = script.statements[5].value.imported;
    try std.testing.expect(!quoted.bare);
    try std.testing.expectEqualStrings("library.huak", quoted.path);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "first", "second" }), quoted.namespace_path);
    try std.testing.expectEqualStrings("value", quoted.form.selected[0].name);
    const default = script.statements[6].value.imported;
    try std.testing.expectEqualStrings("image", default.form.selected[0].name);
    try std.testing.expectEqualStrings("result", default.form.selected[0].alias);
}
