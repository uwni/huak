//! Embedded Typst: block ranges from the native provider, huak members read inside them, typ.module and typ.show.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const typst_namespace = Parser.typst_namespace;

/// A block's Typst code with the places where it reads `huak` members. The
/// native parser finds them; Huak reads no Typst syntax itself.
fn typstCode(self: *Parser, block: TypstBlock) anyerror!ast.Typst {
    const provider = (self.options.source_parser catch unreachable).?;
    // The provider's records are temporary. A block reads few names, so they
    // fit this buffer instead of staying behind in the syntax arena.
    var storage: [1024]u8 = undefined;
    var scratch: std.heap.BufferFirstAllocator = .init(&storage, self.allocator);
    const found = provider.memberUses(scratch.allocator(), block.code, typst_namespace) catch |err| {
        if (err == error.OutOfMemory) return err;
        const failure = self.fail(block.span, "cannot read the Huak names in a Typst block: {s}", .{@errorName(err)});
        self.diagnostic.*.?.cause = .{ .source_block = err };
        return failure;
    };
    if (found.uses.len == 0) return .{ .code = block.code, .rebound = found.rebound, .whole = found.whole };
    const uses = try self.allocator.alloc(ast.TypstUse, found.uses.len);
    for (uses, found.uses) |*use, member| {
        if (member.start > member.end or member.end > block.code.len) return self.fail(block.span, "Typst source-block provider returned an invalid range", .{});
        // A member is named by its identifier in the code. The AST borrows it
        // from the module source, as it borrows the code.
        const written = block.code[member.start..member.end];
        if (!std.mem.eql(u8, written, member.member)) return self.fail(block.span, "Typst source-block provider returned an invalid range", .{});
        use.* = .{ .name = written, .span = .{ .start = block.start + member.start, .end = block.start + member.end } };
    }
    return .{ .code = block.code, .uses = uses, .rebound = found.rebound, .whole = found.whole };
}

const TypstBlock = struct { span: source.Span, code: []const u8, start: usize };

pub fn typstBlock(self: *Parser, opening: u8) anyerror!TypstBlock {
    const start = self.current.span;
    var beginning = self.lexer.pos;
    while (beginning < self.lexer.source.len and (self.lexer.source[beginning] == ' ' or self.lexer.source[beginning] == '\t' or self.lexer.source[beginning] == '\r')) beginning += 1;
    if (beginning == self.lexer.source.len or self.lexer.source[beginning] != opening) {
        return self.fail(start, "expected '{c}' after {s}", .{ opening, self.text(self.current) });
    }
    const configured = self.options.source_parser catch |err| {
        const failure = self.fail(start, "cannot parse Typst block: {s}", .{@errorName(err)});
        self.diagnostic.*.?.cause = .{ .unavailable_source_parser = err };
        return if (err == error.OutOfMemory) err else failure;
    };
    const provider = configured orelse return self.fail(start, "embedded Typst requires a native source-block provider", .{});
    const remaining = self.lexer.source[beginning..];
    const known = if (self.headers) |*headers| headers.sourceBlockLength(self.lexer.source, beginning) else null;
    const length = known orelse provider.block(remaining) catch |err| {
        if (err == error.OutOfMemory) return err;
        const failure = self.fail(start, "cannot parse Typst block: {s}", .{@errorName(err)});
        self.diagnostic.*.?.cause = .{ .source_block = err };
        return failure;
    };
    const closing: u8 = if (opening == '[') ']' else '}';
    if (length < 2 or length > remaining.len or remaining[length - 1] != closing) {
        return self.fail(start, "Typst source-block provider returned an invalid range", .{});
    }
    const finish = beginning + length;
    if (self.source_block_sink) |sink| try sink.append(self.allocator, .{ .start = beginning, .end = finish });
    self.lexer.pos = finish;
    self.current = try self.lexer.next();
    return .{ .span = .{ .start = start.start, .end = finish }, .code = self.lexer.source[beginning..finish], .start = beginning };
}

/// Consumes `typ.` when `member` follows, leaving the member as the current
/// token, and returns its span. A Typst block may begin right after it.
pub fn acceptTypMember(self: *Parser, member: []const u8) anyerror!?source.Span {
    if (self.current.kind != .kw_typ or !self.lexer.startsMember(member)) return null;
    try self.advance();
    try self.advance();
    return self.current.span;
}

/// `typ[markup]` or `typ.module[file content]`.
pub fn typstExpression(self: *Parser) anyerror!*ast.Expr {
    const keyword = self.current;
    const module = try acceptTypMember(self, "module") != null;
    if (!module and self.lexer.startsMember("show")) return self.fail(keyword.span, "typ.show is a declaration, not an expression", .{});
    const block = try typstBlock(self, '[');
    const code = try typstCode(self, block);
    const span: source.Span = .join(keyword.span, block.span);
    return self.createExpr(span, if (module) .{ .typst_module = code } else .{ .typst = code });
}

/// `typ.show value.member`: Huak names, then the Typst members of the module.
pub fn typstShow(self: *Parser) anyerror!*ast.Stmt {
    const keyword = self.current;
    _ = try acceptTypMember(self, "show") orelse return self.fail(keyword.span, "expected typ.show", .{});
    try self.advance();
    var path: std.ArrayList(ast.ExportName) = .empty;
    const first = try self.expect(.identifier, "expected a typ.module value after typ.show");
    try path.append(self.allocator, .{ .name = self.text(first), .span = first.span });
    while (try self.accept(.dot)) {
        const next = try self.expect(.identifier, "expected a member name after '.' in typ.show");
        try path.append(self.allocator, .{ .name = self.text(next), .span = next.span });
    }
    if (path.items.len < 2) return self.fail(first.span, "typ.show needs a member of a typ.module value, such as {s}.style", .{self.text(first)});
    const names = try path.toOwnedSlice(self.allocator);
    return self.createStmt(.join(keyword.span, names[names.len - 1].span), .{ .typst_show = names });
}
