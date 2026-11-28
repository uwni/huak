//! Operands, postfix forms, builtin binary operators and path joins.
const std = @import("std");
const Lexer = @import("../Lexer.zig");
const ast = @import("../ast.zig");
const precedence = @import("../precedence.zig");
const units = @import("../../drawing/units.zig");
const Parser = @import("../Parser.zig");
const calls = @import("calls.zig");
const operators = @import("operators.zig");
const statements = @import("statements.zig");
const typst = @import("typst.zig");
const MixfixLookup = Parser.MixfixLookup;
const callHead = calls.callHead;

pub fn expression(self: *Parser, minimum: u8) anyerror!*ast.Expr {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > ast.max_depth) return self.fail(self.current.span, "expression nesting exceeds {d}", .{ast.max_depth});
    var left = try prefix(self);
    while (true) {
        if (self.mixfix_boundary) |boundary| {
            if (self.lexer.nesting == boundary.nesting and
                std.mem.eql(u8, self.text(self.current), boundary.word)) break;
        }
        if (self.current.kind == .identifier or self.current.kind == .kw_in) {
            if (units.unitNamed(self.text(self.current))) |unit| {
                const finish = self.current.span;
                try self.advance();
                left = try self.createExpr(.join(left.span, finish), .{ .quantity = .{ .operand = left, .unit = unit } });
                continue;
            }
            if ((left.value == .integer or left.value == .float) and std.mem.eql(u8, self.text(self.current), "pi")) {
                const token = self.current;
                try self.advance();
                const factor = try self.createExpr(token.span, .{ .name = "pi" });
                left = try self.createExpr(.join(left.span, token.span), .{ .binary = .{ .op = .multiply, .left = left, .right = factor } });
                continue;
            }
            if ((left.value == .integer or left.value == .float) and left.span.end == self.current.span.start)
                return self.fail(self.current.span, "unknown unit suffix '{s}'; identifiers are not split (write '2pi rad')", .{self.text(self.current)});
        }
        if (self.current.kind == .lparen) {
            left = try calls.parseCall(self, left);
            continue;
        }
        if (try self.accept(.lbracket)) {
            const index = try expression(self, 0);
            if (self.current.kind == .colon) {
                const range = try parseRange(self, index, true);
                const finish = try self.expect(.rbracket, "expected ']' after slice range");
                left = try self.createExpr(.join(left.span, finish.span), .{ .slice = .{ .object = left, .range = range } });
                continue;
            }
            const finish = try self.expect(.rbracket, "expected ']' after index");
            left = try self.createExpr(.join(left.span, finish.span), .{ .index = .{ .object = left, .index = index } });
            continue;
        }
        if (try self.accept(.dot)) {
            const name = self.current;
            if (name.kind != .identifier) return self.fail(name.span, "expected member name after '.'", .{});
            try self.advance();
            left = try self.createExpr(.join(left.span, name.span), .{ .member = .{ .object = left, .name = self.text(name) } });
            continue;
        }
        if (self.current.kind == .identifier and minimum == 0) {
            const operator = try operators.operatorName(self);
            const form = try operators.mixfixName(self, self.current, operator, true, false) orelse unresolved: {
                if (self.options.mixfix != null) return self.fail(operator.span, "no matching mixfix declaration for '{s}'", .{operator.name});
                // Standalone syntax parsing can leave word operators for the precedence pass.
                break :unresolved MixfixLookup.Binding{ .form = .{ .head = operator.name, .parts = &.{null}, .group = operator, .leading = true } };
            };
            left = try operators.mixfixCall(self, operator, form, left);
            continue;
        }
        if (Lexer.isOperator(self.current.kind)) {
            const token = self.current;
            const name: ast.OperatorName = .{ .name = self.text(token), .span = token.span };
            if (try operators.mixfixName(self, token, name, true, true)) |form| {
                if (minimum != 0) break;
                try self.advance();
                left = try operators.mixfixCall(self, name, form, left);
                continue;
            }
        }
        if (self.current.kind == .straight_join or self.current.kind == .smooth_join) {
            // Like word operators, path joins are rebound using the
            // precedence table after all imported groups are available.
            const level = precedence.builtinLevel(.path);
            if (minimum > level) break;
            const kind: ast.PathJoin = if (self.current.kind == .straight_join) .straight else .smooth;
            try self.advance();
            while (self.current.kind == .newline) try self.advance();
            const right = try expression(self, level + 1);
            left = try self.createExpr(.join(left.span, right.span), .{ .path_join = .{ .left = left, .right = right, .kind = kind } });
            continue;
        }
        const op = binary(self.current.kind) orelse break;
        const group = precedence.binaryBuiltin(op);
        const level = precedence.builtinLevel(group);
        if (level < minimum) break;
        try self.advance();
        const right = try expression(self, level + @intFromBool(precedence.builtinAssociativity(group) == .left));
        left = try self.createExpr(.join(left.span, right.span), .{ .binary = .{ .op = op, .left = left, .right = right } });
    }
    return left;
}

pub fn parseRange(self: *Parser, start: *ast.Expr, allow_open_end: bool) anyerror!ast.Range {
    _ = try self.expect(.colon, "expected start:stop or start:step:stop range");
    if (allow_open_end and self.current.kind == .rbracket) return .{ .start = start, .stop = null };
    const second = try expression(self, 0);
    if (try self.accept(.colon)) return .{ .start = start, .step = second, .stop = try expression(self, 0) };
    return .{ .start = start, .stop = second };
}

pub fn prefix(self: *Parser) anyerror!*ast.Expr {
    const token = self.current;
    const literal = self.text(token);
    if (Lexer.isOperator(token.kind)) {
        try self.advance();
        const name: ast.OperatorName = .{ .name = literal, .span = token.span };
        if (try operators.mixfixName(self, self.current, name, false, true)) |form| return operators.mixfixCall(self, name, form, null);
        if (token.kind != .plus and token.kind != .minus) return self.fail(token.span, "operator '{s}' has no prefix mixfix declaration", .{literal});
        const operand = try expression(self, precedence.builtinLevel(.unary));
        return self.createExpr(.join(token.span, operand.span), .{ .unary = .{ .op = if (token.kind == .plus) .positive else .negate, .operand = operand } });
    }
    switch (token.kind) {
        .integer => {
            try self.advance();
            return self.createExpr(token.span, .{ .integer = std.fmt.parseInt(u64, literal, 10) catch return self.fail(token.span, "integer literal magnitude is too large", .{}) });
        },
        .float => {
            try self.advance();
            const value = std.fmt.parseFloat(f64, literal) catch return self.fail(token.span, "invalid float literal", .{});
            if (!std.math.isFinite(value)) return self.fail(token.span, "float literal must be finite", .{});
            return self.createExpr(token.span, .{ .float = value });
        },
        .string => {
            try self.advance();
            const parsed = std.json.parseFromSlice([]const u8, self.allocator, literal, .{ .allocate = .alloc_always }) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.fail(token.span, "invalid string encoding or escape", .{});
            };
            defer parsed.deinit();
            if (!std.unicode.utf8ValidateSlice(parsed.value)) return self.fail(token.span, "string literal must be valid UTF-8", .{});
            return self.createExpr(token.span, .{ .string = try self.allocator.dupe(u8, parsed.value) });
        },
        .kw_true, .kw_false => {
            try self.advance();
            return self.createExpr(token.span, .{ .boolean = token.kind == .kw_true });
        },
        .kw_cycle => {
            try self.advance();
            return self.createExpr(token.span, .cycle);
        },
        .identifier => {
            var lexer = self.lexer;
            var current = self.current;
            if (try callHead(self.allocator, &lexer, &current)) |head| {
                if (self.options.blocks) |lookup| if (lookup.vtable.lookup(lookup.ptr, head)) |definition| {
                    self.lexer = lexer;
                    self.current = current;
                    return calls.expansion(self, head, definition);
                };
                if (try operators.mixfixName(self, current, head, false, false)) |form| {
                    self.lexer = lexer;
                    self.current = current;
                    return operators.mixfixCall(self, head, form, null);
                }
            }
            try self.advance();
            return self.createExpr(token.span, .{ .name = literal });
        },
        .kw_not => {
            try self.advance();
            const operand = try expression(self, precedence.builtinLevel(if (token.kind == .kw_not) .logical_not else .unary));
            return self.createExpr(.join(token.span, operand.span), .{ .unary = .{ .op = switch (token.kind) {
                .minus => .negate,
                .plus => .positive,
                else => .logical_not,
            }, .operand = operand } });
        },
        .lparen => {
            try self.advance();
            const x = try expression(self, 0);
            if (try self.accept(.comma)) {
                const y = try expression(self, 0);
                const z = if (try self.accept(.comma)) try expression(self, 0) else null;
                const finish = try self.expect(.rparen, "expected ')' after vector");
                return self.createExpr(.join(token.span, finish.span), .{ .vector = .{ .x = x, .y = y, .z = z } });
            }
            const finish = try self.expect(.rparen, "expected ')' after expression");
            return self.createExpr(.join(token.span, finish.span), .{ .grouped = x });
        },
        .lbracket => {
            try self.advance();
            var values: std.ArrayList(*ast.Expr) = .empty;
            if (self.current.kind != .rbracket) while (true) {
                try values.append(self.allocator, try expression(self, 0));
                if (!try self.accept(.comma)) break;
                if (self.current.kind == .rbracket) break;
            };
            const finish = try self.expect(.rbracket, "expected ']' after array");
            return self.createExpr(.join(token.span, finish.span), .{ .list = try values.toOwnedSlice(self.allocator) });
        },
        .lbrace => {
            try self.advance();
            var entries: std.ArrayList(ast.DictEntry) = .empty;
            if (self.current.kind != .rbrace) while (true) {
                if (self.current.kind != .string) return self.fail(self.current.span, "dictionary keys must be string literals", .{});
                const key = try prefix(self);
                for (entries.items) |entry| if (std.mem.eql(u8, entry.key, key.value.string))
                    return self.fail(key.span, "duplicate dictionary key '{s}'", .{entry.key});
                _ = try self.expect(.colon, "expected ':' after dictionary key");
                const value = try expression(self, 0);
                try entries.append(self.allocator, .{ .key = key.value.string, .value = value, .span = .join(key.span, value.span) });
                if (!try self.accept(.comma)) break;
                if (self.current.kind == .rbrace) break;
            };
            const finish = try self.expect(.rbrace, "expected '}' after dictionary");
            return self.createExpr(.join(token.span, finish.span), .{ .dict = try entries.toOwnedSlice(self.allocator) });
        },
        .kw_block => {
            const newline_nesting = self.lexer.newline_nesting;
            self.lexer.newline_nesting = self.lexer.nesting;
            defer self.lexer.newline_nesting = newline_nesting;
            try self.advance();
            const body_ = try statements.body(self);
            self.lexer.newline_nesting = newline_nesting;
            const finish = try self.expect(.kw_end, "expected 'end' for block");
            return self.createExpr(.join(token.span, finish.span), .{ .block = body_ });
        },
        .kw_typ => return typst.typstExpression(self),
        .ellipsis => return self.fail(token.span, "spread expressions are not supported; '...' is only valid as a parameter suffix or block insertion", .{}),
        else => return self.fail(token.span, "expected an expression", .{}),
    }
}

/// The binary operator a token spells; how it binds is its group's, in
/// `precedence`.
fn binary(kind: Lexer.Kind) ?ast.Binary {
    return switch (kind) {
        .kw_or => .logical_or,
        .kw_and => .logical_and,
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => .divide,
        .percent => .remainder,
        .caret => .power,
        else => null,
    };
}
