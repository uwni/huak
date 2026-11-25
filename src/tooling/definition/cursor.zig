//! What the cursor is on: the token, a huak member read inside Typst code, and the innermost syntax node.
const std = @import("std");
const ast = @import("../../language/ast.zig");
const ungroup = ast.ungroup;
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Lexer = @import("../../language/Lexer.zig");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const definition = @import("../definition.zig");
const find = definition.find;

/// An incomplete document may still provide builtin hover before its error.
pub fn tokenAt(frontend: *const Frontend, input: []const u8, byte_offset: usize, source_blocks: ?[]const ast.Span) !?Lexer.Token {
    var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = input, .diagnostic = &diagnostic };
    var trailing: ?Lexer.Token = null;
    var blocks = source_blocks;
    while (true) {
        const token = scanner.next() catch return null;
        if (token.kind == .eof or token.span.start > byte_offset) return trailing;
        if (token.span.start <= byte_offset and byte_offset < token.span.end) {
            if (token.kind != .identifier and !Lexer.isOperator(token.kind) and trailing != null) return trailing;
            return token;
        }
        if (token.span.end == byte_offset and token.kind == .identifier) trailing = token;
        // Typst blocks name nothing in Huak; their `huak.name` reads are
        // found from the parsed uses. `typ.show` and a `typ.module`
        // annotation have no block.
        if (token.kind == .kw_typ and typstBlockFollows(&scanner)) {
            if (blocks) |ranges| {
                if (ranges.len == 0) return null;
                scanner.pos = ranges[0].end;
                blocks = ranges[1..];
            } else {
                var start = scanner.pos;
                while (start < input.len and (input[start] == ' ' or input[start] == '\t' or input[start] == '\r')) start += 1;
                const length = frontend.sourceBlock(input[start..]) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return null;
                };
                scanner.pos = start + length;
            }
            if (byte_offset < scanner.pos) return null;
        }
    }
}

/// Whether a Typst block follows `typ`, directly or after `.module`; the
/// scanner is left just before the block.
fn typstBlockFollows(scanner: *Lexer) bool {
    if (scanner.startsBlock('[')) return true;
    if (!scanner.startsMember("module")) return false;
    var ahead = scanner.*;
    _ = ahead.next() catch return false;
    _ = ahead.next() catch return false;
    if (!ahead.startsBlock('[')) return false;
    scanner.* = ahead;
    return true;
}

/// The `huak.name` read in Typst code at the offset, if any.
pub fn typstUseAt(unit: *const ModuleGraph.Unit, byte_offset: usize) ?ast.TypstUse {
    const node = SyntaxAt.find(unit.script.statements, .{ .start = byte_offset, .end = byte_offset }).node orelse return null;
    if (node != .expression) return null;
    const code = switch (node.expression.value) {
        .typst, .typst_module => |code| code,
        else => return null,
    };
    for (code.uses) |use| if (use.span.start <= byte_offset and byte_offset <= use.span.end) return use;
    return null;
}

/// Locate the innermost node and its owning statement in source order. A
/// cursor between arguments belongs to the call, including at an argument's
/// right edge. Inside the argument, its own syntax determines completions.
pub const SyntaxAt = struct {
    node: ?ast.Node = null,
    statement: ?*const ast.Stmt = null,
    completion: ?*const ast.Expr = null,

    pub fn find(body: []const *ast.Stmt, span: ast.Span) SyntaxAt {
        var child: Child = .{ .span = span };
        ast.walkStatements(&child, body) catch |err| std.debug.assert(err == error.Found);
        var found: SyntaxAt = .{};
        while (child.match) |node| {
            found.node = node;
            child.match = null;
            switch (node) {
                .statement => |stmt| found.statement = stmt,
                .expression => |expr| if (span.start == span.end) {
                    const inner = ungroup(expr);
                    switch (inner.value) {
                        .call => |call| {
                            for (call.args) |arg| if (arg.span.start <= span.start and span.start < arg.span.end) {
                                child.match = .{ .expression = arg };
                                break;
                            };
                            if (child.match == null) found.completion = inner;
                            continue;
                        },
                        .member => |member| if (member.object.span.end <= span.start) {
                            found.completion = inner;
                        },
                        else => {},
                    }
                },
            }
            ast.walkChildren(&child, node) catch |err| std.debug.assert(err == error.Found);
        }
        return found;
    }

    /// Select one direct child. The outer loop follows the selected branch.
    const Child = struct {
        span: ast.Span,
        match: ?ast.Node = null,

        pub fn enter(self: *Child, node: ast.Node) error{Found}!bool {
            const range = switch (node) {
                inline else => |item| item.span,
            };
            if (self.span.start < range.start or self.span.end > range.end) return false;
            self.match = node;
            return error.Found;
        }
    };
};

test "definition and hover token selection accepts identifier endpoints before punctuation" {
    const source = "fn target()->int return 1 end\nresult:=target()\n";
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const offset = std.mem.lastIndexOf(u8, source, "target()").? + "target".len;
    const token = (try tokenAt(&frontend, source, offset, &.{})).?;
    try std.testing.expectEqualStrings("target", source[token.span.start..token.span.end]);
    const result = (try find(&frontend, arena.allocator(), source, "/tmp/definition.huak", offset)).?;
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 3 }, result.range.start);
}
