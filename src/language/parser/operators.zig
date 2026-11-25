//! User-defined operator syntax: precedence groups, mixfix templates, mixfix lookup and argument parsing.
const std = @import("std");
const Lexer = @import("../Lexer.zig");
const ast = @import("../ast.zig");
const units = @import("../../drawing/units.zig");
const Parser = @import("../Parser.zig");
const expressions = @import("expressions.zig");
const calls = @import("calls.zig");
const MixfixLookup = Parser.MixfixLookup;
const ScopeId = Parser.ScopeId;
const callHead = calls.callHead;

pub fn mixfixBinding(self: *Parser) !*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    _ = try self.expect(.lparen, "expected '(' before mixfix target");
    const target = try operatorName(self);
    _ = try self.expect(.rparen, "expected ')' after mixfix target");
    const leading = self.current.kind == .identifier and std.mem.eql(u8, self.text(self.current), "_");
    if (leading) try self.advance();
    const head = try templateToken(self);
    if (std.mem.eql(u8, self.text(head), "_")) return self.fail(head.span, "expected a mixfix word or symbol before the next argument", .{});
    var parts: std.array_list.Managed(?[]const u8) = .init(self.allocator);
    while (self.current.kind != .kw_in) {
        while (self.current.kind == .newline) try self.advance();
        if (self.current.kind == .kw_in) break;
        if (parts.items.len == ast.MixfixForm.max_parts) return self.fail(self.current.span, "mixfix template exceeds {d} parts", .{ast.MixfixForm.max_parts});
        const token = try templateToken(self);
        const word = self.text(token);
        if (std.mem.eql(u8, word, "_")) {
            if (parts.items.len != 0 and parts.items[parts.items.len - 1] == null)
                return self.fail(token.span, "mixfix arguments must be preceded by a word", .{});
            try parts.append(null);
        } else {
            try parts.append(word);
        }
    }
    if (parts.items.len == 0 or parts.items[parts.items.len - 1] != null)
        return self.fail(self.current.span, "mixfix template must end with an '_' argument", .{});
    try self.advance();
    while (self.current.kind == .newline) try self.advance();
    const group = try operatorName(self);
    return self.createStmt(.join(start, group.span), .{ .mixfix_binding = .{ .target = target, .form = .{ .head = self.text(head), .parts = try parts.toOwnedSlice(), .group = group, .leading = leading } } });
}

fn templateToken(self: *Parser) !Lexer.Token {
    const token = self.current;
    if (token.kind != .identifier and !Lexer.isOperator(token.kind))
        return self.fail(token.span, "expected a mixfix word, symbol or '_' argument", .{});
    if (units.unitNamed(self.text(token)) != null)
        return self.fail(token.span, "unit '{s}' cannot be a mixfix word", .{self.text(token)});
    try self.advance();
    return token;
}

pub fn mixfixName(self: *Parser, current: Lexer.Token, name: ast.OperatorName, leading: bool, symbolic: bool) !?MixfixLookup.Binding {
    if (!leading and (!startsOperand(current.kind) or (!symbolic and current.kind == .lparen and current.span.start == name.span.end))) return null;
    const found = if (self.options.mixfix) |lookup| form: {
        break :form lookup.lookup(name, leading) orelse return null;
    } else form: {
        if (name.namespace != null) return null;
        const headers = self.headers orelse return null;
        var scope: ?ScopeId = headers.scopeAt(name.span.start);
        while (scope) |id| : (scope = headers.scopes[id].parent) {
            for (headers.operators) |declaration| {
                if (declaration.scope != id or declaration.statement.value != .mixfix_binding) continue;
                const binding = &declaration.statement.value.mixfix_binding;
                if (binding.form.leading == leading and std.mem.eql(u8, binding.form.head, name.name))
                    break :form MixfixLookup.Binding{ .form = binding.form, .target = binding.target.name, .qualified = if (binding.target.namespace != null) binding else null };
            }
        }
        return null;
    };
    const form = found.form;
    if (form.leading != leading or form.parts.len == 0 or form.parts.len > ast.MixfixForm.max_parts or form.parts[form.parts.len - 1] != null)
        return self.fail(name.span, "invalid mixfix template", .{});
    for (form.parts, 0..) |part, index| {
        if (part == null and index != 0 and form.parts[index - 1] == null) return self.fail(name.span, "invalid mixfix template", .{});
    }
    if (form.parts[0]) |word| {
        if (!leading and !std.mem.eql(u8, self.text(current), word)) return null;
    }
    return found;
}

pub fn mixfixCall(self: *Parser, head: ast.OperatorName, binding: MixfixLookup.Binding, left: ?*ast.Expr) anyerror!*ast.Expr {
    const form = binding.form;
    var name = head;
    if (binding.target) |target| name.name = target;
    // The lexer has already entered a first operand's opening delimiter.
    // Clause words belong to the level before that token, not its group.
    const nesting = self.lexer.nesting - @as(usize, @intFromBool(switch (self.current.kind) {
        .lparen, .lbracket, .lbrace => true,
        else => false,
    }));
    if (form.parts.len > 1 and self.mixfix_argument_nesting == nesting)
        return self.fail(name.span, "nested mixfix arguments require parentheses", .{});
    var arguments: std.array_list.Managed(*ast.Expr) = .init(self.allocator);
    if (left) |operand| try arguments.append(operand);
    for (form.parts, 0..) |part, index| {
        if (part != null and arguments.items.len != 0) {
            // Trailing clauses can be omitted at a statement boundary;
            // the ordinary callable's defaults/arity remain authoritative.
            // Continue across a newline when the next clause is present.
            var look = self.lexer;
            var token = self.current;
            while (token.kind == .newline) token = try look.next();
            const matches = std.mem.eql(u8, self.text(token), part.?);
            if (!matches and switch (self.current.kind) {
                .newline, .semicolon, .eof, .kw_end, .kw_else, .kw_elseif, .kw_then, .kw_do, .comma, .rparen, .rbracket, .rbrace => true,
                else => false,
            }) break;
        }
        while (self.current.kind == .newline) try self.advance();
        if (part) |word| {
            if (!std.mem.eql(u8, self.text(self.current), word))
                return self.fail(self.current.span, "expected mixfix word '{s}'", .{word});
            try self.advance();
        } else {
            const previous_boundary = self.mixfix_boundary;
            const previous_nesting = self.mixfix_argument_nesting;
            defer self.mixfix_boundary = previous_boundary;
            defer self.mixfix_argument_nesting = previous_nesting;
            if (form.parts.len > 1) self.mixfix_argument_nesting = nesting;
            self.mixfix_boundary = if (index + 1 < form.parts.len)
                .{ .word = form.parts[index + 1].?, .nesting = nesting }
            else
                previous_boundary;
            try arguments.append(try expressions.expression(self, if (index + 1 == form.parts.len) 1 else 0));
        }
    }
    return self.createExpr(.join(if (left) |operand| operand.span else name.span, arguments.items[arguments.items.len - 1].span), .{ .mixfix_call = .{ .operator = name, .args = try arguments.toOwnedSlice(), .leading = form.leading, .qualified = binding.qualified } });
}

pub fn precedenceGroup(self: *Parser) !*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    const name = try self.expect(.identifier, "expected a precedence group name");
    try self.separators();
    var relations: std.array_list.Managed(ast.Relation) = .init(self.allocator);
    var associativity: ast.Associativity = .none;
    var association_seen = false;
    while (self.current.kind != .kw_end) {
        if (self.current.kind == .eof) return self.fail(start, "unterminated precedence group; expected 'end'", .{});
        const attribute = try self.expect(.identifier, "expected 'above', 'below', or 'associativity' in precedence group");
        const word = self.text(attribute);
        if (std.mem.eql(u8, word, "associativity")) {
            if (association_seen) return self.fail(attribute.span, "duplicate associativity declaration", .{});
            const value = try self.expect(.identifier, "expected left, right, or none after associativity");
            associativity = std.meta.stringToEnum(ast.Associativity, self.text(value)) orelse
                return self.fail(value.span, "associativity must be left, right, or none", .{});
            association_seen = true;
        } else if (std.mem.eql(u8, word, "above") or std.mem.eql(u8, word, "below")) {
            const target = try operatorName(self);
            const direction: @FieldType(ast.Relation, "direction") = if (std.mem.eql(u8, word, "above")) .above else .below;
            for (relations.items) |earlier| {
                if (earlier.direction == direction and sameOperatorName(earlier.target, target))
                    return self.fail(attribute.span, "duplicate '{s}' relation for precedence group '{s}'", .{ word, target.name });
            }
            try relations.append(.{ .direction = direction, .target = target, .span = .join(attribute.span, target.span) });
        } else return self.fail(attribute.span, "unknown precedence attribute '{s}'", .{word});
        if (self.current.kind != .newline and self.current.kind != .semicolon and self.current.kind != .kw_end)
            return self.fail(self.current.span, "expected a newline or ';' between precedence attributes", .{});
        try self.separators();
    }
    const finish = try self.expect(.kw_end, "expected 'end' for precedence group");
    return self.createStmt(.join(start, finish.span), .{ .precedence_group = .{ .name = self.text(name), .relations = try relations.toOwnedSlice(), .associativity = associativity } });
}

pub fn operatorName(self: *Parser) !ast.OperatorName {
    if (self.current.kind != .identifier) return self.fail(self.current.span, "expected an operator or precedence group name", .{});
    return try callHead(self.allocator, &self.lexer, &self.current) orelse self.fail(self.current.span, "expected a name after namespace '.'", .{});
}

fn startsOperand(kind: Lexer.Kind) bool {
    return Lexer.isOperator(kind) or switch (kind) {
        .identifier, .integer, .float, .string, .kw_true, .kw_false, .kw_cycle, .minus, .plus, .kw_not, .lparen, .lbracket, .lbrace, .kw_typ, .kw_block => true,
        else => false,
    };
}

fn sameOperatorName(a: ast.OperatorName, b: ast.OperatorName) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace) |left| return if (b.namespace) |right| std.mem.eql(u8, left, right) else false;
    return b.namespace == null;
}
