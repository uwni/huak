//! Declarations and type annotations: functions and block expansions, records, script parameters and exports.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const statements = @import("statements.zig");
const expressions = @import("expressions.zig");
const typst = @import("typst.zig");
const HeaderScanner = @import("HeaderScanner.zig");

const FunctionHeader = struct { name: []const u8, params: []const ast.Parameter, result: ?ast.Annotation, span: source.Span };

/// `fn` or `expand_block`: a header, a body and `end`.
pub fn functionDeclaration(self: *Parser) anyerror!*ast.Stmt {
    const start = self.current.span;
    const expanding = self.current.kind == .kw_expand_block;
    const header = try functionHeader(self, null);
    const body_ = try statements.body(self);
    const finish = try self.expect(.kw_end, "expected 'end' for function");
    if (expanding) {
        var insertions = struct {
            count: usize = 0,
            pub fn enter(visitor: *@This(), node: ast.Node) !bool {
                if (node == .statement and node.statement.value == .insertion) visitor.count += 1;
                return true;
            }
        }{};
        try ast.walkStatements(&insertions, body_);
        if (insertions.count != 1) return self.fail(start, "expand_block requires exactly one '...' insertion", .{});
        const declaration = try self.createStmt(.join(start, finish.span), .{ .expand_block = .{ .name = header.name, .params = header.params, .result = header.result, .body = body_ } });
        if (self.headers) |headers| for (headers.expansions) |entry| if (entry.statement.span.start == start.start) {
            entry.statement.* = declaration.*;
            return entry.statement;
        };
        return declaration;
    }
    return self.createStmt(.join(start, finish.span), .{ .function = .{ .name = header.name, .params = header.params, .result = header.result, .body = body_ } });
}

/// `param name: Type = default`; either part may be left out, not both.
pub fn scriptParameter(self: *Parser) anyerror!*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    const name = try self.expect(.identifier, "expected parameter name");
    const annotation = if (try self.accept(.colon)) try parseAnnotation(self) else null;
    const default = if (try self.accept(.assign)) try expressions.expression(self, 0) else null;
    if (annotation == null and default == null) return self.fail(name.span, "script parameters need a type annotation or constant default", .{});
    return self.createStmt(.join(start, if (default) |value| value.span else annotation.?.span), .{ .parameter = .{ .name = self.text(name), .annotation = annotation, .default = default } });
}

/// `export` of a declaration, or of names with an optional initializer.
pub fn exportStatement(self: *Parser) anyerror!*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    if (self.current.kind == .kw_fn or self.current.kind == .kw_struct or self.current.kind == .kw_expand_block) {
        const declaration = try statements.statement(self);
        switch (declaration.value) {
            .function => |*value| value.exported = true,
            .structure => |*value| value.exported = true,
            .expand_block => |*value| value.exported = true,
            else => unreachable,
        }
        declaration.span.start = start.start;
        return declaration;
    }
    var names: std.ArrayList(ast.ExportName) = .empty;
    const name = try self.expect(.identifier, "expected an exported name");
    try names.append(self.allocator, .{ .name = self.text(name), .span = name.span });
    while (try self.accept(.comma)) {
        while (self.current.kind == .newline) try self.advance();
        const next = try self.expect(.identifier, "expected an exported name after ','");
        try names.append(self.allocator, .{ .name = self.text(next), .span = next.span });
    }
    var value: ?*ast.Expr = null;
    if (self.current.kind == .declare) {
        if (names.items.len != 1) return self.fail(self.current.span, "an initialized export cannot contain multiple names", .{});
        try self.advance();
        value = try statements.initializer(self, name.span);
        if (self.current.kind == .comma) return self.fail(self.current.span, "an initialized export cannot contain multiple names", .{});
    }
    return self.createStmt(.join(start, if (value) |expression_| expression_.span else names.items[names.items.len - 1].span), .{ .exported = .{ .names = try names.toOwnedSlice(self.allocator), .value = value } });
}

pub fn functionHeader(self: *Parser, scanner: ?*HeaderScanner) !FunctionHeader {
    const start = self.current.span;
    try self.advance();
    const name = try self.expect(.identifier, "expected function name");
    _ = try self.expect(.lparen, "expected '(' after function name");
    var params: std.ArrayList(ast.Parameter) = .empty;
    var optional = false;
    if (self.current.kind != .rparen) while (true) {
        const param = try self.expect(.identifier, "expected parameter name");
        const annotation: ast.Annotation = if (try self.accept(.colon))
            try parseAnnotation(self)
        else if (self.current.kind == .ellipsis)
            .{ .name = "any", .span = param.span }
        else
            return self.fail(param.span, "fixed function parameters need a type annotation", .{});
        var finish = annotation.span;
        const variadic = self.current.kind == .ellipsis;
        if (variadic) {
            finish = self.current.span;
            try self.advance();
            if (self.current.kind == .assign) return self.fail(param.span, "a variadic parameter cannot have a default", .{});
            if (self.current.kind != .rparen) return self.fail(self.current.span, "a variadic parameter must be the last function parameter", .{});
        }
        const default = if (try self.accept(.assign)) value: {
            if (variadic) return self.fail(param.span, "a variadic parameter cannot have a default", .{});
            optional = true;
            const value = if (scanner) |headers| try headers.defaultExpression() else try expressions.expression(self, 0);
            finish = value.span;
            break :value value;
        } else null;
        if (!variadic and optional and default == null) return self.fail(param.span, "required parameters cannot follow parameters with defaults", .{});
        try params.append(self.allocator, .{ .name = self.text(param), .annotation = annotation, .span = .join(param.span, finish), .variadic = variadic, .default = default });
        if (!try self.accept(.comma)) break;
    };
    const closing = try self.expect(.rparen, "expected ')' after parameters");
    const result = if (try self.accept(.arrow)) try parseAnnotation(self) else null;
    return .{ .name = self.text(name), .params = try params.toOwnedSlice(self.allocator), .result = result, .span = .join(start, if (result) |annotation| annotation.span else closing.span) };
}

pub fn structure(self: *Parser) !*ast.Stmt {
    const start = (try self.expect(.kw_struct, "expected 'struct'")).span;
    const name = try self.expect(.identifier, "expected struct name");
    var fields: std.ArrayList(ast.RecordField) = .empty;
    try self.separators();
    while (self.current.kind != .kw_end) {
        if (self.current.kind == .eof) return self.fail(self.current.span, "expected 'end' for struct", .{});
        const field = try self.expect(.identifier, "expected a typed struct field");
        for (fields.items) |earlier| if (std.mem.eql(u8, earlier.name, self.text(field)))
            return self.fail(field.span, "duplicate struct field '{s}'", .{earlier.name});
        _ = try self.expect(.colon, "struct fields need an explicit type annotation");
        const annotation = try parseAnnotation(self);
        const default = if (try self.accept(.assign)) try expressions.expression(self, 0) else null;
        try fields.append(self.allocator, .{ .name = self.text(field), .annotation = annotation, .default = default, .span = .join(field.span, if (default) |value| value.span else annotation.span) });
        if (self.current.kind != .kw_end and self.current.kind != .newline and self.current.kind != .semicolon)
            return self.fail(self.current.span, "expected a newline or ';' between struct fields", .{});
        try self.separators();
    }
    const finish = try self.expect(.kw_end, "expected 'end' for struct");
    return self.createStmt(.join(start, finish.span), .{ .structure = .{ .name = self.text(name), .fields = try fields.toOwnedSlice(self.allocator) } });
}

pub fn parseAnnotation(self: *Parser) !ast.Annotation {
    if (self.current.kind == .kw_typ) {
        const keyword = self.current;
        const member = try typst.acceptTypMember(self, "module") orelse return self.fail(keyword.span, "expected typ.module", .{});
        try self.advance();
        return .{ .name = "typ.module", .span = .join(keyword.span, member) };
    }
    const first = try self.expect(.identifier, "expected a type name");
    var name = self.text(first);
    var finish = first.span;
    while (try self.accept(.dot)) {
        const part = try self.expect(.identifier, "expected a type name after '.'");
        name = try self.allocator.print("{s}.{s}", .{ name, self.text(part) });
        finish = part.span;
    }
    return .{ .name = name, .span = .join(first.span, finish) };
}
