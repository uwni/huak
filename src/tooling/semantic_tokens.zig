//! Semantic overlays for call templates; parsing and import resolution remain
//! in the ordinary frontend. TextMate supplies the remaining lexical colors.
const std = @import("std");
const ast = @import("../language/ast.zig");
const Lexer = @import("../language/Lexer.zig");
const ModuleGraph = @import("../language/ModuleGraph.zig");
const builtin = @import("../language/builtin.zig");
const Frontend = @import("Frontend.zig");
const position = @import("position.zig");

pub const Kind = enum { function, keyword, variable, namespace, operator };
pub const legend = .{ .tokenTypes = std.meta.fieldNames(Kind), .tokenModifiers = [_][]const u8{} };
const Token = struct { span: ast.Span, kind: Kind };

/// The encoded result and syntax snapshot belong to the request arena.
/// Incomplete syntax falls back to lexical highlighting; OOM is propagated.
pub fn collect(frontend: *Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8) ![]const u32 {
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    const graph = frontend.graph(arena, text, path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        return &.{};
    };
    var collector: Collector = .{ .allocator = arena, .unit = graph.units.items[0] };
    try ast.walkStatements(&collector, collector.unit.script.statements);
    std.mem.sort(Token, collector.tokens.items, {}, struct {
        fn before(_: void, a: Token, b: Token) bool {
            return a.span.start < b.span.start;
        }
    }.before);
    var data: std.ArrayList(u32) = .empty;
    var cursor: usize = 0;
    for (collector.tokens.items) |token| {
        // Scan successive gaps once, including UTF-16 characters in comments
        // and Typst, rather than rescanning the document for every position.
        const delta = position.at(text[cursor..], token.span.start - cursor);
        try data.appendSlice(arena, &.{ @intCast(delta.line), @intCast(delta.character), @intCast(token.span.end - token.span.start), @backingInt(token.kind), 0 });
        cursor = token.span.start;
    }
    return data.items;
}

const Collector = struct {
    allocator: std.mem.Allocator,
    unit: *const ModuleGraph.Unit,
    tokens: std.ArrayList(Token) = .empty,

    pub fn enter(self: *Collector, node: ast.Node) !bool {
        switch (node) {
            .expression => |expr| switch (expr.value) {
                .expansion => |call| try self.words(call.name.span, call.name.span),
                .mixfix_call => |call| {
                    var cursor = expr.span.start;
                    for (call.args) |argument| {
                        try self.words(.{ .start = cursor, .end = argument.span.start }, call.operator.span);
                        cursor = argument.span.end;
                    }
                    try self.words(.{ .start = cursor, .end = expr.span.end }, call.operator.span);
                },
                .name => |name| {
                    const resolver = self.unit.resolverAt(expr.span.start);
                    const scope = self.unit.scopeAt(expr.span.start);
                    const namespace = resolver.namespace(scope, name) != null or
                        (resolver.readable(scope, name) == null and builtin.Namespace.parse(name) != null);
                    try self.tokens.append(self.allocator, .{ .span = expr.span, .kind = if (namespace) .namespace else .variable });
                },
                else => {},
            },
            .statement => |stmt| switch (stmt.value) {
                .mixfix_binding => |binding| try self.words(.{ .start = stmt.span.start, .end = binding.form.group.span.start }, binding.target.span),
                else => {},
            },
        }
        return true;
    }

    /// Arguments are visited as AST children. Only the intervening template
    /// words are lexed here, so strings/comments/Typst cannot become labels.
    fn words(self: *Collector, span: ast.Span, head: ast.Span) !void {
        var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
        var lexer: Lexer = .{ .source = self.unit.source_text[span.start..span.end], .diagnostic = &diagnostic };
        while (true) {
            const token = try lexer.next();
            if (token.kind == .eof) break;
            if (Lexer.isOperator(token.kind)) {
                try self.tokens.append(self.allocator, .{ .span = .{ .start = span.start + token.span.start, .end = span.start + token.span.end }, .kind = .operator });
                continue;
            }
            if (token.kind != .identifier) continue;
            const word = lexer.source[token.span.start..token.span.end];
            const absolute: ast.Span = .{ .start = span.start + token.span.start, .end = span.start + token.span.end };
            const kind: Kind = if (std.mem.eql(u8, word, "_")) .operator else if (absolute.start >= head.start and absolute.end <= head.end)
                (if (absolute.end == head.end) Kind.function else Kind.namespace)
            else
                .keyword;
            try self.tokens.append(self.allocator, .{ .span = absolute, .kind = kind });
        }
    }
};
