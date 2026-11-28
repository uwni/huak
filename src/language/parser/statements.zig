//! Statement lists and statement forms: the dispatcher, control flow, return and default output, insertions, assignments and expression statements.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const typst = @import("typst.zig");
const operators = @import("operators.zig");
const imports = @import("imports.zig");
const declarations = @import("declarations.zig");
const expressions = @import("expressions.zig");

pub fn body(self: *Parser) anyerror![]const *ast.Stmt {
    var statements: std.ArrayList(*ast.Stmt) = .empty;
    self.separators() catch |err| return err;
    while (!switch (self.current.kind) {
        .eof, .kw_end, .kw_else, .kw_elseif => true,
        else => false,
    }) {
        try statements.append(self.allocator, try statement(self));
        if (!switch (self.current.kind) {
            .eof, .kw_end, .kw_else, .kw_elseif, .newline, .semicolon => true,
            else => false,
        })
            return self.fail(self.current.span, "expected a newline or ';' between statements", .{});
        try self.separators();
    }
    return statements.toOwnedSlice(self.allocator);
}

pub fn statement(self: *Parser) anyerror!*ast.Stmt {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > ast.max_depth) return self.fail(self.current.span, "block nesting exceeds {d}", .{ast.max_depth});
    const start = self.current.span;
    if (self.current.kind == .kw_typ and self.lexer.startsMember("show")) return typst.typstShow(self);
    switch (self.current.kind) {
        .kw_precedence => return operators.precedenceGroup(self),
        .kw_mixfix => return operators.mixfixBinding(self),
        .kw_import => return imports.importStatement(self),
        .kw_fn, .kw_expand_block => return declarations.functionDeclaration(self),
        .ellipsis => {
            try self.advance();
            return self.createStmt(start, .insertion);
        },
        .kw_struct => return declarations.structure(self),
        .kw_param => return declarations.scriptParameter(self),
        .kw_if => {
            var branches: std.ArrayList(ast.Branch) = .empty;
            while (true) {
                try self.advance();
                const condition = try expressions.expression(self, 0);
                try self.controlDelimiter(.kw_then, "expected 'then' after if or elseif condition");
                try branches.append(self.allocator, .{ .condition = condition, .body = try body(self) });
                if (self.current.kind != .kw_elseif) break;
            }
            var otherwise: []const *ast.Stmt = &.{};
            if (try self.accept(.kw_else)) {
                otherwise = try body(self);
            }
            const finish = try self.expect(.kw_end, "expected 'end' for if");
            return self.createStmt(.join(start, finish.span), .{ .conditional = .{ .branches = try branches.toOwnedSlice(self.allocator), .otherwise = otherwise } });
        },
        .kw_while => {
            try self.advance();
            const condition = try expressions.expression(self, 0);
            try self.controlDelimiter(.kw_do, "expected 'do' after while condition");
            const statements = try body(self);
            const finish = try self.expect(.kw_end, "expected 'end' for while");
            return self.createStmt(.join(start, finish.span), .{ .while_loop = .{ .condition = condition, .body = statements } });
        },
        .kw_for => {
            try self.advance();
            const name = try self.expect(.identifier, "expected loop variable");
            _ = try self.expect(.kw_in, "expected 'in' after loop variable");
            const first = try expressions.expression(self, 0);
            const iterable: ast.Iterable = if (self.current.kind == .colon) .{ .range = try expressions.parseRange(self, first, false) } else .{ .collection = first };
            try self.controlDelimiter(.kw_do, "expected 'do' after for iterable");
            const statements = try body(self);
            const finish = try self.expect(.kw_end, "expected 'end' for for");
            return self.createStmt(.join(start, finish.span), .{ .for_loop = .{ .name = self.text(name), .name_span = name.span, .iterable = iterable, .body = statements } });
        },
        .kw_break => {
            try self.advance();
            return self.createStmt(start, .break_loop);
        },
        .kw_continue => {
            try self.advance();
            return self.createStmt(start, .continue_loop);
        },
        .kw_return => {
            try self.advance();
            const value = if (switch (self.current.kind) {
                .newline, .semicolon, .eof, .kw_end, .kw_else, .kw_elseif => true,
                else => false,
            }) null else try expressions.expression(self, 0);
            return self.createStmt(if (value) |expr| .join(start, expr.span) else start, .{ .return_value = value });
        },
        .kw_default => {
            try self.advance();
            const value = try expressions.expression(self, 0);
            return self.createStmt(.join(start, value.span), .{ .default_output = value });
        },
        .kw_export => return declarations.exportStatement(self),
        else => {
            const expr = try expressions.expression(self, 0);
            if (try self.accept(.plus_assign)) {
                if (expr.value == .member or expr.value == .index) {
                    const value = try expressions.expression(self, 0);
                    return self.createStmt(.join(start, value.span), .{ .append_to = .{ .target = expr, .value = value } });
                }
                const name = switch (expr.value) {
                    .name => |name| name,
                    else => return self.fail(expr.span, "'+=' target must be a list variable name", .{}),
                };
                const value = try expressions.expression(self, 0);
                return self.createStmt(.join(start, value.span), .{ .list_append = .{ .name = name, .value = value } });
            }
            if (self.current.kind == .colon or self.current.kind == .declare or self.current.kind == .assign) {
                if (self.current.kind == .assign and (expr.value == .member or expr.value == .index)) {
                    try self.advance();
                    const value = try expressions.expression(self, 0);
                    return self.createStmt(.join(start, value.span), .{ .set = .{ .target = expr, .value = value } });
                }
                const name = switch (expr.value) {
                    .name => |name| name,
                    else => return self.fail(expr.span, "assignment target must be a variable name", .{}),
                };
                const annotation = if (try self.accept(.colon)) try declarations.parseAnnotation(self) else null;
                const declaration = self.current.kind == .declare;
                if (annotation != null and !declaration) return self.fail(self.current.span, "expected ':=' after variable annotation", .{});
                if (!declaration and self.current.kind != .assign) return self.fail(self.current.span, "expected ':=' or '='", .{});
                try self.advance();
                const value = if (declaration) try initializer(self, expr.span) else try expressions.expression(self, 0);
                return self.createStmt(.join(start, value.span), .{ .assignment = .{ .name = name, .annotation = annotation, .value = value, .declaration = declaration } });
            }
            return self.createStmt(expr.span, .{ .expression = expr });
        },
    }
}

/// A declaration enters scope after its initializer. Record the exact range
/// here, where expression grammar (including nested blocks) is authoritative.
pub fn initializer(self: *Parser, name: source.Span) anyerror!*ast.Expr {
    const headers = self.headers.?;
    for (headers.scopes[headers.scopeAt(name.start)].ordinary_names) |*local| {
        if (local.span.start != name.start) continue;
        local.initializer_end = self.lexer.source.len;
        const value = try expressions.expression(self, 0);
        local.initializer_end = value.span.end;
        return value;
    }
    unreachable;
}
