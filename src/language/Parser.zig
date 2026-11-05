//! Keyword/end parser with native Typst content and code blocks.
const std = @import("std");
const Lexer = @import("Lexer.zig");
const ast = @import("ast.zig");
const source = @import("source.zig");
const units = @import("../drawing/units.zig");

/// Native embedded-language parsing is supplied by the caller.
pub const SourceParser = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub inline fn block(self: SourceParser, input: []const u8) anyerror!usize {
        return self.vtable.block(self.ptr, input);
    }

    pub const VTable = struct {
        block: *const fn (*anyopaque, []const u8) anyerror!usize,
    };
};

/// Lookup can combine local forms with a caller-provided fallback.
pub const MixfixLookup = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Binding = struct { form: ast.MixfixForm, target: ?[]const u8 = null, qualified: ?*const ast.MixfixBinding = null };

    pub inline fn lookup(self: MixfixLookup, name: ast.OperatorName, leading: bool) ?Binding {
        return self.vtable.lookup(self.ptr, name, leading);
    }

    pub const VTable = struct {
        lookup: *const fn (*anyopaque, ast.OperatorName, bool) ?Binding,
    };
};

pub const Options = struct {
    source_parser: ?SourceParser = null,
    mixfix: ?MixfixLookup = null,
    blocks: ?BlockLookup = null,
};

pub const BlockLookup = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const Definition = struct { statement: *ast.Stmt, module: u32 };
    pub const VTable = struct {
        lookup: *const fn (*anyopaque, ast.OperatorName) ?Definition,
        enter: *const fn (*anyopaque, Definition, ScopeId) anyerror!void,
    };
};

/// Declarations needed before parsing expression call forms. These slices,
/// like the AST, belong to the parser arena.
pub const ScopeId = u32;
pub const Local = struct {
    name: []const u8,
    span: source.Span,
    initializer_end: usize = 0,

    pub fn initializingAt(self: Local, position: usize) bool {
        return self.span.end <= position and position < self.initializer_end;
    }
};
pub const Scope = struct {
    parent: ?ScopeId,
    kind: enum { module, function, branch, loop, block, expansion },
    body: source.Span,
    ordinary_names: []Local,
    insertion: ?usize = null,
};
pub const ScopedHeader = struct { scope: ScopeId, statement: *ast.Stmt };
pub const Headers = struct {
    scopes: []const Scope,
    imports: []const ScopedHeader,
    operators: []const ScopedHeader,
    typst_exposures: []const ScopedHeader = &.{},
    records: []const ScopedHeader = &.{},
    expansions: []const ScopedHeader = &.{},
    /// Native-validated block ranges borrow this exact immutable source.
    /// They are reusable only while its address and length remain unchanged.
    source_identity: ?[]const u8 = null,
    source_blocks: []const source.Span = &.{},

    fn sourceBlockLength(self: *const Headers, input: []const u8, beginning: usize) ?usize {
        const original = self.source_identity orelse return null;
        if (original.ptr != input.ptr or original.len != input.len) return null;
        const index = std.sort.partitionPoint(source.Span, self.source_blocks, beginning, blockStartsBefore);
        if (index == self.source_blocks.len or self.source_blocks[index].start != beginning) return null;
        const finish = self.source_blocks[index].end;
        return if (finish >= beginning) finish - beginning else 0;
    }

    fn blockStartsBefore(beginning: usize, block: source.Span) bool {
        return block.start < beginning;
    }

    pub fn scopeAt(self: Headers, offset: usize) ScopeId {
        if (self.scopes.len == 0) return 0;
        // Scanner scopes follow lexical preorder with nondecreasing starts.
        // After the last started scope ends, only its ancestors can contain us.
        // Root is the default result, not a candidate that needs containment.
        var scope: ScopeId = @intCast(std.sort.partitionPoint(Scope, self.scopes[1..], offset, startsAtOrBefore));
        while (scope != 0) : (scope = self.scopes[scope].parent orelse 0) {
            if (offset < self.scopes[scope].body.end) return scope;
        }
        return 0;
    }

    fn startsAtOrBefore(offset: usize, scope: Scope) bool {
        return scope.body.start <= offset;
    }
};

const FunctionHeader = struct { name: []const u8, params: []const ast.Parameter, result: ?ast.Annotation, span: source.Span };

const Parser = @This();

allocator: std.mem.Allocator,
lexer: Lexer,
current: Lexer.Token,
options: Options,
diagnostic: *?source.Diagnostic,
depth: usize = 0,
headers: ?Headers = null,
mixfix_boundary: ?struct { word: []const u8, nesting: usize } = null,
mixfix_argument_nesting: ?usize = null,
source_block_sink: ?*std.ArrayList(source.Span) = null,

pub fn init(allocator: std.mem.Allocator, input: []const u8, options: Options, diagnostic: *?source.Diagnostic) !Parser {
    var lexer: Lexer = .{ .source = input, .diagnostic = diagnostic };
    return .{ .allocator = allocator, .current = try lexer.next(), .lexer = lexer, .options = options, .diagnostic = diagnostic };
}

pub fn parse(self: *Parser) anyerror!ast.Script {
    if (self.headers == null) self.headers = try scanHeaders(self.allocator, self.lexer.source, self.options, self.diagnostic);
    const statements = try self.body();
    if (self.current.kind != .eof) return self.fail(self.current.span, "unexpected block delimiter", .{});
    return .{ .statements = statements };
}

fn body(self: *Parser) anyerror![]const *ast.Stmt {
    var statements: std.array_list.Managed(*ast.Stmt) = .init(self.allocator);
    self.separators() catch |err| return err;
    while (!switch (self.current.kind) {
        .eof, .kw_end, .kw_else, .kw_elseif => true,
        else => false,
    }) {
        try statements.append(try self.statement());
        if (!switch (self.current.kind) {
            .eof, .kw_end, .kw_else, .kw_elseif, .newline, .semicolon => true,
            else => false,
        })
            return self.fail(self.current.span, "expected a newline or ';' between statements", .{});
        try self.separators();
    }
    return statements.toOwnedSlice();
}

fn statement(self: *Parser) anyerror!*ast.Stmt {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > 256) return self.fail(self.current.span, "block nesting exceeds 256", .{});
    const start = self.current.span;
    switch (self.current.kind) {
        .kw_precedence => return self.precedenceGroup(),
        .kw_mixfix => return self.mixfixBinding(),
        .kw_import => {
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
                const expression_ = try self.prefix();
                const literal = ungroup(expression_);
                if (literal.value != .string) return self.fail(expression_.span, "import path must be a string literal or module name", .{});
                finish = expression_.span;
                break :path literal.value.string;
            };
            var namespace_path: std.array_list.Managed([]const u8) = .init(self.allocator);
            const form: ast.ImportForm = if (try self.accept(.dot)) form: {
                while (true) {
                    if (self.current.kind == .star) {
                        finish = self.current.span;
                        try self.advance();
                        break :form .all;
                    }
                    var bindings: std.array_list.Managed(ast.ImportBinding) = .init(self.allocator);
                    if (try self.accept(.lbrace)) {
                        while (true) {
                            const binding = try self.importBinding();
                            try bindings.append(binding);
                            if (!try self.accept(.comma) or self.current.kind == .rbrace) break;
                        }
                        finish = (try self.expect(.rbrace, "expected '}}' after selected imports")).span;
                    } else {
                        const name = self.current;
                        if (name.kind != .identifier) return self.fail(name.span, "expected an exported member name", .{});
                        try self.advance();
                        if (try self.accept(.dot)) {
                            try namespace_path.append(self.text(name));
                            continue;
                        }
                        const binding = try self.importBindingAfter(name);
                        try bindings.append(binding);
                        finish = binding.span;
                    }
                    break :form .{ .selected = try bindings.toOwnedSlice() };
                }
            } else if (try self.importAlias()) |alias| form: {
                finish = alias.span;
                break :form .{ .namespace = self.text(alias) };
            } else .{ .namespace = try self.importNamespace(path, path_span) };
            return self.createStmt(.join(start, finish), .{ .imported = .{ .path = path, .bare = bare, .namespace_path = try namespace_path.toOwnedSlice(), .form = form } });
        },
        .kw_fn, .kw_expand_block => {
            const expanding = self.current.kind == .kw_expand_block;
            const header = try self.functionHeader(null);
            const statements = try self.body();
            const finish = try self.expect(.kw_end, "expected 'end' for function");
            if (expanding) {
                var insertions = struct {
                    count: usize = 0,
                    pub fn enter(visitor: *@This(), node: ast.Node) !bool {
                        if (node == .statement and node.statement.value == .insertion) visitor.count += 1;
                        return true;
                    }
                }{};
                try ast.walkStatements(&insertions, statements);
                if (insertions.count != 1) return self.fail(start, "expand_block requires exactly one '...' insertion", .{});
                const declaration = try self.createStmt(.join(start, finish.span), .{ .expand_block = .{ .name = header.name, .params = header.params, .result = header.result, .body = statements } });
                if (self.headers) |headers| for (headers.expansions) |entry| if (entry.statement.span.start == start.start) {
                    entry.statement.* = declaration.*;
                    return entry.statement;
                };
                return declaration;
            }
            return self.createStmt(.join(start, finish.span), .{ .function = .{ .name = header.name, .params = header.params, .result = header.result, .body = statements } });
        },
        .ellipsis => {
            try self.advance();
            return self.createStmt(start, .insertion);
        },
        .kw_struct => return self.structure(),
        .kw_param => {
            try self.advance();
            const name = try self.expect(.identifier, "expected parameter name");
            const annotation = if (try self.accept(.colon)) try self.parseAnnotation() else null;
            const default = if (try self.accept(.assign)) try self.expression(0) else null;
            if (annotation == null and default == null) return self.fail(name.span, "script parameters need a type annotation or constant default", .{});
            return self.createStmt(.join(start, if (default) |value| value.span else annotation.?.span), .{ .parameter = .{ .name = self.text(name), .annotation = annotation, .default = default } });
        },
        .kw_if => {
            var branches: std.array_list.Managed(ast.Branch) = .init(self.allocator);
            while (true) {
                try self.advance();
                const condition = try self.expression(0);
                try self.controlDelimiter(.kw_then, "expected 'then' after if or elseif condition");
                try branches.append(.{ .condition = condition, .body = try self.body() });
                if (self.current.kind != .kw_elseif) break;
            }
            var otherwise: []const *ast.Stmt = &.{};
            if (try self.accept(.kw_else)) {
                otherwise = try self.body();
            }
            const finish = try self.expect(.kw_end, "expected 'end' for if");
            return self.createStmt(.join(start, finish.span), .{ .conditional = .{ .branches = try branches.toOwnedSlice(), .otherwise = otherwise } });
        },
        .kw_while => {
            try self.advance();
            const condition = try self.expression(0);
            try self.controlDelimiter(.kw_do, "expected 'do' after while condition");
            const statements = try self.body();
            const finish = try self.expect(.kw_end, "expected 'end' for while");
            return self.createStmt(.join(start, finish.span), .{ .while_loop = .{ .condition = condition, .body = statements } });
        },
        .kw_for => {
            try self.advance();
            const name = try self.expect(.identifier, "expected loop variable");
            _ = try self.expect(.kw_in, "expected 'in' after loop variable");
            const first = try self.expression(0);
            const iterable: ast.Iterable = if (self.current.kind == .colon) .{ .range = try self.parseRange(first, false) } else .{ .collection = first };
            try self.controlDelimiter(.kw_do, "expected 'do' after for iterable");
            const statements = try self.body();
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
            }) null else try self.expression(0);
            return self.createStmt(if (value) |expr| .join(start, expr.span) else start, .{ .return_value = value });
        },
        .kw_default => {
            try self.advance();
            const value = try self.expression(0);
            return self.createStmt(.join(start, value.span), .{ .default_output = value });
        },
        .kw_export => {
            try self.advance();
            if (self.current.kind == .kw_fn or self.current.kind == .kw_struct or self.current.kind == .kw_expand_block) {
                const declaration = try self.statement();
                switch (declaration.value) {
                    .function => |*value| value.exported = true,
                    .structure => |*value| value.exported = true,
                    .expand_block => |*value| value.exported = true,
                    else => unreachable,
                }
                declaration.span.start = start.start;
                return declaration;
            }
            var names: std.array_list.Managed(ast.ExportName) = .init(self.allocator);
            const name = try self.expect(.identifier, "expected an exported name");
            try names.append(.{ .name = self.text(name), .span = name.span });
            while (try self.accept(.comma)) {
                while (self.current.kind == .newline) try self.advance();
                const next = try self.expect(.identifier, "expected an exported name after ','");
                try names.append(.{ .name = self.text(next), .span = next.span });
            }
            var value: ?*ast.Expr = null;
            if (self.current.kind == .declare) {
                if (names.items.len != 1) return self.fail(self.current.span, "an initialized export cannot contain multiple names", .{});
                try self.advance();
                value = try self.initializer(name.span);
                if (self.current.kind == .comma) return self.fail(self.current.span, "an initialized export cannot contain multiple names", .{});
            }
            return self.createStmt(.join(start, if (value) |expression_| expression_.span else names.items[names.items.len - 1].span), .{ .exported = .{ .names = try names.toOwnedSlice(), .value = value } });
        },
        .kw_setup_typst => {
            const raw = try self.typstBlock('{');
            return self.createStmt(raw.span, .{ .setup_typst = raw.code });
        },
        .kw_typst_expose => {
            try self.advance();
            var names: std.array_list.Managed(ast.ExportName) = .init(self.allocator);
            const first = try self.expect(.identifier, "expected a Huak variable name after typst_expose");
            try names.append(.{ .name = self.text(first), .span = first.span });
            while (try self.accept(.comma)) {
                while (self.current.kind == .newline) try self.advance();
                const next = try self.expect(.identifier, "expected a Huak variable name after ','");
                try names.append(.{ .name = self.text(next), .span = next.span });
            }
            return self.createStmt(.join(start, names.items[names.items.len - 1].span), .{ .typst_expose = try names.toOwnedSlice() });
        },
        else => {
            const expr = try self.expression(0);
            if (try self.accept(.plus_assign)) {
                if (expr.value == .member or expr.value == .index) {
                    const value = try self.expression(0);
                    return self.createStmt(.join(start, value.span), .{ .append_to = .{ .target = expr, .value = value } });
                }
                const name = switch (expr.value) {
                    .name => |name| name,
                    else => return self.fail(expr.span, "'+=' target must be a list variable name", .{}),
                };
                const value = try self.expression(0);
                return self.createStmt(.join(start, value.span), .{ .list_append = .{ .name = name, .value = value } });
            }
            if (self.current.kind == .colon or self.current.kind == .declare or self.current.kind == .assign) {
                if (self.current.kind == .assign and (expr.value == .member or expr.value == .index)) {
                    try self.advance();
                    const value = try self.expression(0);
                    return self.createStmt(.join(start, value.span), .{ .set = .{ .target = expr, .value = value } });
                }
                const name = switch (expr.value) {
                    .name => |name| name,
                    else => return self.fail(expr.span, "assignment target must be a variable name", .{}),
                };
                const annotation = if (try self.accept(.colon)) try self.parseAnnotation() else null;
                const declaration = self.current.kind == .declare;
                if (annotation != null and !declaration) return self.fail(self.current.span, "expected ':=' after variable annotation", .{});
                if (!declaration and self.current.kind != .assign) return self.fail(self.current.span, "expected ':=' or '='", .{});
                try self.advance();
                const value = if (declaration) try self.initializer(expr.span) else try self.expression(0);
                return self.createStmt(.join(start, value.span), .{ .assignment = .{ .name = name, .annotation = annotation, .value = value, .declaration = declaration } });
            }
            return self.createStmt(expr.span, .{ .expression = expr });
        },
    }
}

/// A declaration enters scope after its initializer. Record the exact range
/// here, where expression grammar (including nested blocks) is authoritative.
fn initializer(self: *Parser, name: source.Span) anyerror!*ast.Expr {
    const headers = self.headers.?;
    for (headers.scopes[headers.scopeAt(name.start)].ordinary_names) |*local| {
        if (local.span.start != name.start) continue;
        local.initializer_end = self.lexer.source.len;
        const value = try self.expression(0);
        local.initializer_end = value.span.end;
        return value;
    }
    unreachable;
}

fn expression(self: *Parser, minimum: u8) anyerror!*ast.Expr {
    self.depth += 1;
    defer self.depth -= 1;
    if (self.depth > 256) return self.fail(self.current.span, "expression nesting exceeds 256", .{});
    var left = try self.prefix();
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
            left = try self.parseCall(left);
            continue;
        }
        if (try self.accept(.lbracket)) {
            const index = try self.expression(0);
            if (self.current.kind == .colon) {
                const range = try self.parseRange(index, true);
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
            const operator = try self.operatorName();
            const form = try self.mixfixName(self.current, operator, true, false) orelse unresolved: {
                if (self.options.mixfix != null) return self.fail(operator.span, "no matching mixfix declaration for '{s}'", .{operator.name});
                // Standalone syntax parsing can leave word operators for the precedence pass.
                break :unresolved MixfixLookup.Binding{ .form = .{ .head = operator.name, .parts = &.{null}, .group = operator, .leading = true } };
            };
            left = try self.mixfixCall(operator, form, left);
            continue;
        }
        if (Lexer.isOperator(self.current.kind)) {
            const token = self.current;
            const name: ast.OperatorName = .{ .name = self.text(token), .span = token.span };
            if (try self.mixfixName(token, name, true, true)) |form| {
                if (minimum != 0) break;
                try self.advance();
                left = try self.mixfixCall(name, form, left);
                continue;
            }
        }
        if (self.current.kind == .straight_join or self.current.kind == .smooth_join) {
            // Like word operators, path joins are rebound using the
            // precedence table after all imported groups are available.
            if (minimum > 5) break;
            const kind: ast.PathJoin = if (self.current.kind == .straight_join) .straight else .smooth;
            try self.advance();
            while (self.current.kind == .newline) try self.advance();
            const right = try self.expression(6);
            left = try self.createExpr(.join(left.span, right.span), .{ .path_join = .{ .left = left, .right = right, .kind = kind } });
            continue;
        }
        const operation = binary(self.current.kind) orelse break;
        if (operation.precedence < minimum) break;
        try self.advance();
        const right = try self.expression(operation.precedence + @as(u8, if (operation.op == .power) 0 else 1));
        left = try self.createExpr(.join(left.span, right.span), .{ .binary = .{ .op = operation.op, .left = left, .right = right } });
    }
    return left;
}

fn parseCall(self: *Parser, left: *ast.Expr) anyerror!*ast.Expr {
    var args: std.array_list.Managed(*ast.Expr) = .init(self.allocator);
    var argument_names: std.array_list.Managed(?[]const u8) = .init(self.allocator);
    var named = false;
    const callee = ungroup(left);
    const name = switch (callee.value) {
        .name => |name| name,
        .member => |member| call_name: {
            try args.append(member.object);
            break :call_name member.name;
        },
        else => return self.fail(left.span, "only named functions can be called", .{}),
    };
    try self.advance();
    if (self.current.kind != .rparen) while (true) {
        var argument_name: ?[]const u8 = null;
        if (self.current.kind == .identifier) {
            if ((try self.peek()).kind == .colon) {
                const token = self.current;
                argument_name = self.text(token);
                for (argument_names.items) |earlier| if (earlier) |name_| {
                    if (std.mem.eql(u8, name_, argument_name.?)) return self.fail(token.span, "duplicate named argument '{s}'", .{name_});
                };
                if (!named) {
                    for (0..args.items.len) |_| try argument_names.append(null);
                    named = true;
                }
                try self.advance();
                try self.advance();
            }
        }
        if (argument_name == null and named) return self.fail(self.current.span, "positional arguments cannot follow named arguments", .{});
        try args.append(try self.expression(0));
        if (named) try argument_names.append(argument_name);
        if (self.current.kind == .ellipsis) return self.fail(self.current.span, "call argument spreading is not supported", .{});
        if (!try self.accept(.comma)) break;
        if (self.current.kind == .rparen) break;
    };
    const finish = try self.expect(.rparen, "expected ')' after arguments");
    return self.createExpr(.join(left.span, finish.span), .{ .call = .{ .name = name, .args = try args.toOwnedSlice(), .argument_names = if (named) try argument_names.toOwnedSlice() else &.{}, .dot = callee.value == .member } });
}

fn parseRange(self: *Parser, start: *ast.Expr, allow_open_end: bool) anyerror!ast.Range {
    _ = try self.expect(.colon, "expected start:stop or start:step:stop range");
    if (allow_open_end and self.current.kind == .rbracket) return .{ .start = start, .stop = null };
    const second = try self.expression(0);
    if (try self.accept(.colon)) return .{ .start = start, .step = second, .stop = try self.expression(0) };
    return .{ .start = start, .stop = second };
}

fn prefix(self: *Parser) anyerror!*ast.Expr {
    const token = self.current;
    const literal = self.text(token);
    if (Lexer.isOperator(token.kind)) {
        try self.advance();
        const name: ast.OperatorName = .{ .name = literal, .span = token.span };
        if (try self.mixfixName(self.current, name, false, true)) |form| return self.mixfixCall(name, form, null);
        if (token.kind != .plus and token.kind != .minus) return self.fail(token.span, "operator '{s}' has no prefix mixfix declaration", .{literal});
        const operand = try self.expression(7);
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
                    return self.expansion(head, definition);
                };
                if (try self.mixfixName(current, head, false, false)) |form| {
                    self.lexer = lexer;
                    self.current = current;
                    return self.mixfixCall(head, form, null);
                }
            }
            try self.advance();
            return self.createExpr(token.span, .{ .name = literal });
        },
        .kw_not => {
            try self.advance();
            const operand = try self.expression(if (token.kind == .kw_not) 3 else 7);
            return self.createExpr(.join(token.span, operand.span), .{ .unary = .{ .op = switch (token.kind) {
                .minus => .negate,
                .plus => .positive,
                else => .logical_not,
            }, .operand = operand } });
        },
        .lparen => {
            try self.advance();
            const x = try self.expression(0);
            if (try self.accept(.comma)) {
                const y = try self.expression(0);
                const finish = try self.expect(.rparen, "expected ')' after pair");
                return self.createExpr(.join(token.span, finish.span), .{ .pair = .{ .x = x, .y = y } });
            }
            const finish = try self.expect(.rparen, "expected ')' after expression");
            return self.createExpr(.join(token.span, finish.span), .{ .grouped = x });
        },
        .lbracket => {
            try self.advance();
            var values: std.array_list.Managed(*ast.Expr) = .init(self.allocator);
            if (self.current.kind != .rbracket) while (true) {
                try values.append(try self.expression(0));
                if (!try self.accept(.comma)) break;
                if (self.current.kind == .rbracket) break;
            };
            const finish = try self.expect(.rbracket, "expected ']' after array");
            return self.createExpr(.join(token.span, finish.span), .{ .list = try values.toOwnedSlice() });
        },
        .lbrace => {
            try self.advance();
            var entries: std.array_list.Managed(ast.DictEntry) = .init(self.allocator);
            if (self.current.kind != .rbrace) while (true) {
                if (self.current.kind != .string) return self.fail(self.current.span, "dictionary keys must be string literals", .{});
                const key = try self.prefix();
                for (entries.items) |entry| if (std.mem.eql(u8, entry.key, key.value.string))
                    return self.fail(key.span, "duplicate dictionary key '{s}'", .{entry.key});
                _ = try self.expect(.colon, "expected ':' after dictionary key");
                const value = try self.expression(0);
                try entries.append(.{ .key = key.value.string, .value = value, .span = .join(key.span, value.span) });
                if (!try self.accept(.comma)) break;
                if (self.current.kind == .rbrace) break;
            };
            const finish = try self.expect(.rbrace, "expected '}}' after dictionary");
            return self.createExpr(.join(token.span, finish.span), .{ .dict = try entries.toOwnedSlice() });
        },
        .kw_block => {
            const newline_nesting = self.lexer.newline_nesting;
            self.lexer.newline_nesting = self.lexer.nesting;
            defer self.lexer.newline_nesting = newline_nesting;
            try self.advance();
            const statements = try self.body();
            self.lexer.newline_nesting = newline_nesting;
            const finish = try self.expect(.kw_end, "expected 'end' for block");
            return self.createExpr(.join(token.span, finish.span), .{ .block = statements });
        },
        .kw_typ => {
            const value = try self.typstBlock('[');
            return self.createExpr(value.span, .{ .typst = value.code });
        },
        .ellipsis => return self.fail(token.span, "spread expressions are not supported; '...' is only valid as a parameter suffix or block insertion", .{}),
        else => return self.fail(token.span, "expected an expression", .{}),
    }
}

/// Consume a possible callable head using only its lexical cursor. A member such as
/// Module member access belongs to the ordinary postfix parser.
fn callHead(allocator: std.mem.Allocator, lexer: *Lexer, current: *Lexer.Token) !?ast.OperatorName {
    const first = current.*;
    var name = first;
    var namespace: ?[]const u8 = null;
    current.* = try lexer.next();
    while (current.kind == .dot) {
        current.* = try lexer.next();
        if (current.kind != .identifier) return null;
        const word = lexer.source[name.span.start..name.span.end];
        namespace = if (namespace) |parent|
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent, word })
        else
            word;
        name = current.*;
        current.* = try lexer.next();
    }
    return .{ .namespace = namespace, .name = lexer.source[name.span.start..name.span.end], .span = .join(first.span, name.span) };
}

fn mixfixBinding(self: *Parser) !*ast.Stmt {
    const start = self.current.span;
    try self.advance();
    _ = try self.expect(.lparen, "expected '(' before mixfix target");
    const target = try self.operatorName();
    _ = try self.expect(.rparen, "expected ')' after mixfix target");
    const leading = self.current.kind == .identifier and std.mem.eql(u8, self.text(self.current), "_");
    if (leading) try self.advance();
    const head = try self.templateToken();
    if (std.mem.eql(u8, self.text(head), "_")) return self.fail(head.span, "expected a mixfix word or symbol before the next argument", .{});
    var parts: std.array_list.Managed(?[]const u8) = .init(self.allocator);
    while (self.current.kind != .kw_in) {
        while (self.current.kind == .newline) try self.advance();
        if (self.current.kind == .kw_in) break;
        if (parts.items.len == 256) return self.fail(self.current.span, "mixfix template exceeds 256 parts", .{});
        const token = try self.templateToken();
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
    const group = try self.operatorName();
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

fn mixfixName(self: *Parser, current: Lexer.Token, name: ast.OperatorName, leading: bool, symbolic: bool) !?MixfixLookup.Binding {
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
    if (form.leading != leading or form.parts.len == 0 or form.parts.len > 256 or form.parts[form.parts.len - 1] != null)
        return self.fail(name.span, "invalid mixfix template", .{});
    for (form.parts, 0..) |part, index| {
        if (part == null and index != 0 and form.parts[index - 1] == null) return self.fail(name.span, "invalid mixfix template", .{});
    }
    if (form.parts[0]) |word| {
        if (!leading and !std.mem.eql(u8, self.text(current), word)) return null;
    }
    return found;
}

fn expansion(self: *Parser, name: ast.OperatorName, definition: BlockLookup.Definition) anyerror!*ast.Expr {
    var args: []const *ast.Expr = &.{};
    var names: []const ?[]const u8 = &.{};
    if (self.current.kind == .lparen) {
        const invocation = try self.parseCall(try self.createExpr(name.span, .{ .name = name.name }));
        args = invocation.value.call.args;
        names = invocation.value.call.argument_names;
    } else if (self.current.kind != .kw_do) {
        const values = try self.allocator.alloc(*ast.Expr, 1);
        values[0] = try self.expression(0);
        args = values;
    }
    const newline_nesting = self.lexer.newline_nesting;
    self.lexer.newline_nesting = self.lexer.nesting;
    defer self.lexer.newline_nesting = newline_nesting;
    try self.controlDelimiter(.kw_do, "expected 'do' after block arguments");
    const scope = self.headers.?.scopeAt(self.current.span.start);
    if (self.options.blocks) |lookup| try lookup.vtable.enter(lookup.ptr, definition, scope);
    const body_ = try self.body();
    self.lexer.newline_nesting = newline_nesting;
    const finish = try self.expect(.kw_end, "expected 'end' for expanded block");
    return self.createExpr(.join(name.span, finish.span), .{ .expansion = .{ .name = name, .definition = definition.statement, .module = definition.module, .args = args, .argument_names = names, .body = body_, .scope = scope } });
}

fn mixfixCall(self: *Parser, head: ast.OperatorName, binding: MixfixLookup.Binding, left: ?*ast.Expr) anyerror!*ast.Expr {
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
            try arguments.append(try self.expression(if (index + 1 == form.parts.len) 1 else 0));
        }
    }
    return self.createExpr(.join(if (left) |operand| operand.span else name.span, arguments.items[arguments.items.len - 1].span), .{ .mixfix_call = .{ .operator = name, .args = try arguments.toOwnedSlice(), .leading = form.leading, .qualified = binding.qualified } });
}

fn functionHeader(self: *Parser, scanner: ?*HeaderScanner) !FunctionHeader {
    const start = self.current.span;
    try self.advance();
    const name = try self.expect(.identifier, "expected function name");
    _ = try self.expect(.lparen, "expected '(' after function name");
    var params: std.array_list.Managed(ast.Parameter) = .init(self.allocator);
    var optional = false;
    if (self.current.kind != .rparen) while (true) {
        const param = try self.expect(.identifier, "expected parameter name");
        const annotation: ast.Annotation = if (try self.accept(.colon))
            try self.parseAnnotation()
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
            const value = if (scanner) |headers| try headers.defaultExpression() else try self.expression(0);
            finish = value.span;
            break :value value;
        } else null;
        if (!variadic and optional and default == null) return self.fail(param.span, "required parameters cannot follow parameters with defaults", .{});
        try params.append(.{ .name = self.text(param), .annotation = annotation, .span = .join(param.span, finish), .variadic = variadic, .default = default });
        if (!try self.accept(.comma)) break;
    };
    const closing = try self.expect(.rparen, "expected ')' after parameters");
    const result = if (try self.accept(.arrow)) try self.parseAnnotation() else null;
    return .{ .name = self.text(name), .params = try params.toOwnedSlice(), .result = result, .span = .join(start, if (result) |annotation| annotation.span else closing.span) };
}

fn structure(self: *Parser) !*ast.Stmt {
    const start = (try self.expect(.kw_struct, "expected 'struct'")).span;
    const name = try self.expect(.identifier, "expected struct name");
    var fields: std.array_list.Managed(ast.RecordField) = .init(self.allocator);
    try self.separators();
    while (self.current.kind != .kw_end) {
        if (self.current.kind == .eof) return self.fail(self.current.span, "expected 'end' for struct", .{});
        const field = try self.expect(.identifier, "expected a typed struct field");
        for (fields.items) |earlier| if (std.mem.eql(u8, earlier.name, self.text(field)))
            return self.fail(field.span, "duplicate struct field '{s}'", .{earlier.name});
        _ = try self.expect(.colon, "struct fields need an explicit type annotation");
        const annotation = try self.parseAnnotation();
        const default = if (try self.accept(.assign)) try self.expression(0) else null;
        try fields.append(.{ .name = self.text(field), .annotation = annotation, .default = default, .span = .join(field.span, if (default) |value| value.span else annotation.span) });
        if (self.current.kind != .kw_end and self.current.kind != .newline and self.current.kind != .semicolon)
            return self.fail(self.current.span, "expected a newline or ';' between struct fields", .{});
        try self.separators();
    }
    const finish = try self.expect(.kw_end, "expected 'end' for struct");
    return self.createStmt(.join(start, finish.span), .{ .structure = .{ .name = self.text(name), .fields = try fields.toOwnedSlice() } });
}

fn precedenceGroup(self: *Parser) !*ast.Stmt {
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
            const target = try self.operatorName();
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

fn operatorName(self: *Parser) !ast.OperatorName {
    if (self.current.kind != .identifier) return self.fail(self.current.span, "expected an operator or precedence group name", .{});
    return try callHead(self.allocator, &self.lexer, &self.current) orelse self.fail(self.current.span, "expected a name after namespace '.'", .{});
}

fn typstBlock(self: *Parser, opening: u8) anyerror!struct { span: source.Span, code: []const u8 } {
    const start = self.current.span;
    var beginning = self.lexer.pos;
    while (beginning < self.lexer.source.len and (self.lexer.source[beginning] == ' ' or self.lexer.source[beginning] == '\t' or self.lexer.source[beginning] == '\r')) beginning += 1;
    if (beginning == self.lexer.source.len or self.lexer.source[beginning] != opening) {
        return self.fail(start, "expected '{c}' after {s}", .{ opening, self.text(self.current) });
    }
    const provider = self.options.source_parser orelse return self.fail(start, "embedded Typst requires a native source-block provider", .{});
    const remaining = self.lexer.source[beginning..];
    const known = if (self.headers) |*headers| headers.sourceBlockLength(self.lexer.source, beginning) else null;
    const length = known orelse provider.block(remaining) catch |err| {
        if (err == error.OutOfMemory) return err;
        return self.fail(start, "cannot parse Typst block: {s}", .{@errorName(err)});
    };
    const closing: u8 = if (opening == '[') ']' else '}';
    if (length < 2 or length > remaining.len or remaining[length - 1] != closing) {
        return self.fail(start, "Typst source-block provider returned an invalid range", .{});
    }
    const finish = beginning + length;
    if (self.source_block_sink) |sink| try sink.append(self.allocator, .{ .start = beginning, .end = finish });
    self.lexer.pos = finish;
    self.current = try self.lexer.next();
    return .{ .span = .{ .start = start.start, .end = finish }, .code = self.lexer.source[beginning + 1 .. finish - 1] };
}

fn parseAnnotation(self: *Parser) !ast.Annotation {
    const first = try self.expect(.identifier, "expected a type name");
    var name = self.text(first);
    var finish = first.span;
    while (try self.accept(.dot)) {
        const part = try self.expect(.identifier, "expected a type name after '.'");
        name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, self.text(part) });
        finish = part.span;
    }
    return .{ .name = name, .span = .join(first.span, finish) };
}
fn importBinding(self: *Parser) !ast.ImportBinding {
    const name = self.current;
    if (name.kind != .identifier) return self.fail(name.span, "expected an exported member name", .{});
    try self.advance();
    return self.importBindingAfter(name);
}
fn importBindingAfter(self: *Parser, name: Lexer.Token) !ast.ImportBinding {
    const alias = try self.importAlias() orelse name;
    return .{ .name = self.text(name), .alias = self.text(alias), .span = .join(name.span, alias.span) };
}
fn importAlias(self: *Parser) !?Lexer.Token {
    if (self.current.kind != .identifier or !std.mem.eql(u8, self.text(self.current), "as")) return null;
    try self.advance();
    return try self.expect(.identifier, "expected a local name after 'as'");
}
fn importNamespace(self: *Parser, path: []const u8, span: source.Span) ![]const u8 {
    const name = std.fs.path.stem(path);
    var diagnostic: ?source.Diagnostic = null;
    var lexer: Lexer = .{ .source = name, .diagnostic = &diagnostic };
    const first = lexer.next() catch return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    const last = lexer.next() catch return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    if (first.kind != .identifier or last.kind != .eof or first.span.end != name.len)
        return self.fail(span, "import filename needs an explicit namespace alias with 'as'", .{});
    return name;
}
fn controlDelimiter(self: *Parser, kind: Lexer.Kind, comptime message: []const u8) !void {
    while (self.current.kind == .newline) try self.advance();
    _ = try self.expect(kind, message);
}
fn separators(self: *Parser) !void {
    while (self.current.kind == .newline or self.current.kind == .semicolon) try self.advance();
}
fn advance(self: *Parser) !void {
    self.current = try self.lexer.next();
}
fn peek(self: *const Parser) !Lexer.Token {
    var lexer = self.lexer;
    return lexer.next();
}
fn accept(self: *Parser, kind: Lexer.Kind) !bool {
    if (self.current.kind != kind) return false;
    try self.advance();
    return true;
}
fn expect(self: *Parser, kind: Lexer.Kind, comptime message: []const u8) !Lexer.Token {
    if (self.current.kind != kind) return self.fail(self.current.span, message, .{});
    const token = self.current;
    try self.advance();
    return token;
}
fn text(self: *const Parser, token: Lexer.Token) []const u8 {
    return self.lexer.source[token.span.start..token.span.end];
}
fn fail(self: *Parser, span: source.Span, comptime format: []const u8, args: anytype) error{LanguageError} {
    self.diagnostic.* = source.Diagnostic.init(span, format, args);
    return error.LanguageError;
}
fn createStmt(self: *Parser, span: source.Span, value: @FieldType(ast.Stmt, "value")) !*ast.Stmt {
    const result = try self.allocator.create(ast.Stmt);
    result.* = .{ .span = span, .value = value };
    return result;
}
fn createExpr(self: *Parser, span: source.Span, value: @FieldType(ast.Expr, "value")) !*ast.Expr {
    const result = try self.allocator.create(ast.Expr);
    result.* = .{ .span = span, .value = value };
    return result;
}

/// Scan only declarations which affect expression grammar. The same lexer and
/// Typst boundary provider are used by the full parser; embedded source is never
/// interpreted as huak declarations.
pub fn scanHeaders(allocator: std.mem.Allocator, input: []const u8, options: Options, diagnostic: *?source.Diagnostic) !Headers {
    var scanner = try HeaderScanner.init(allocator, input, options, diagnostic);
    return scanner.scan();
}

const HeaderScanner = struct {
    const ScopeDraft = struct {
        value: Scope,
        names: std.ArrayList(Local) = .empty,
    };
    const Frame = struct {
        kind: enum { function, conditional, loop, block },
        parent: ScopeId,
        scope: ?ScopeId = null,
        variable: ?ast.ExportName = null,
        nesting: usize = 0,
        newline_nesting: usize = 0,
    };

    allocator: std.mem.Allocator,
    parser: Parser,
    scopes: std.ArrayList(ScopeDraft) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    imports: std.ArrayList(ScopedHeader) = .empty,
    operators: std.ArrayList(ScopedHeader) = .empty,
    typst_exposures: std.ArrayList(ScopedHeader) = .empty,
    records: std.ArrayList(ScopedHeader) = .empty,
    expansions: std.ArrayList(ScopedHeader) = .empty,
    source_blocks: std.ArrayList(source.Span) = .empty,
    active: ScopeId = 0,
    statement_start: bool = true,

    fn init(allocator: std.mem.Allocator, input: []const u8, options: Options, diagnostic: *?source.Diagnostic) !HeaderScanner {
        var scanner: HeaderScanner = .{ .allocator = allocator, .parser = try Parser.init(allocator, input, options, diagnostic) };
        try scanner.scopes.append(allocator, .{ .value = .{ .parent = null, .kind = .module, .body = .{ .start = 0, .end = input.len }, .ordinary_names = &.{} } });
        return scanner;
    }

    fn scan(self: *HeaderScanner) !Headers {
        // Attach only after the scanner reaches its final address. Calls made
        // inside function defaults and record fields use this sink too.
        self.parser.source_block_sink = &self.source_blocks;
        defer self.parser.source_block_sink = null;
        while (self.parser.current.kind != .eof) try self.scanToken();
        const scopes = try self.allocator.alloc(Scope, self.scopes.items.len);
        for (self.scopes.items, scopes) |*draft, *scope| {
            scope.* = draft.value;
            scope.ordinary_names = try draft.names.toOwnedSlice(self.allocator);
        }
        return .{ .scopes = scopes, .imports = try self.imports.toOwnedSlice(self.allocator), .operators = try self.operators.toOwnedSlice(self.allocator), .typst_exposures = try self.typst_exposures.toOwnedSlice(self.allocator), .records = try self.records.toOwnedSlice(self.allocator), .expansions = try self.expansions.toOwnedSlice(self.allocator), .source_identity = self.parser.lexer.source, .source_blocks = try self.source_blocks.toOwnedSlice(self.allocator) };
    }

    fn scanToken(self: *HeaderScanner) anyerror!void {
        const token = self.parser.current;
        switch (token.kind) {
            .kw_typ, .kw_setup_typst => {
                _ = try self.parser.typstBlock(if (token.kind == .kw_typ) '[' else '{');
                self.statement_start = false;
                return;
            },
            .kw_import => {
                try self.imports.append(self.allocator, .{ .scope = self.active, .statement = try self.parser.statement() });
                self.statement_start = false;
                return;
            },
            .kw_typst_expose => {
                try self.typst_exposures.append(self.allocator, .{ .scope = self.active, .statement = try self.parser.statement() });
                self.statement_start = false;
                return;
            },
            .kw_mixfix => {
                const declaration = try self.parser.statement();
                try self.operators.append(self.allocator, .{ .scope = self.active, .statement = declaration });
                self.statement_start = false;
                return;
            },
            .ellipsis => {
                var scope: ?ScopeId = self.active;
                while (scope) |id| : (scope = self.scopes.items[id].value.parent) {
                    if (self.scopes.items[id].value.kind == .function) break;
                    if (self.scopes.items[id].value.kind == .expansion) {
                        self.scopes.items[id].value.insertion = token.span.start;
                        break;
                    }
                }
                self.statement_start = false;
            },
            .kw_precedence => {
                _ = try self.parser.statement();
                self.statement_start = false;
                return;
            },
            .kw_block => {
                try self.push(.block);
                const index = self.frames.items.len - 1;
                self.frames.items[index].scope = try self.open(.block, token.span.end);
                self.frames.items[index].newline_nesting = self.parser.lexer.newline_nesting;
                self.parser.lexer.newline_nesting = self.parser.lexer.nesting;
                self.statement_start = true;
            },
            .kw_fn, .kw_expand_block => {
                const expanding = token.kind == .kw_expand_block;
                const header = try self.parser.functionHeader(self);
                try self.push(.function);
                const scope = try self.open(if (expanding) .expansion else .function, header.span.end);
                if (expanding) try self.expansions.append(self.allocator, .{ .scope = scope, .statement = try self.parser.createStmt(header.span, .{ .expand_block = .{ .name = header.name, .params = header.params, .result = header.result, .body = &.{} } }) });
                for (header.params) |parameter| try self.nameInScope(.{ .name = parameter.name, .span = .{ .start = parameter.span.start, .end = parameter.span.start + parameter.name.len } });
                self.frames.items[self.frames.items.len - 1].scope = scope;
                self.statement_start = true;
                return;
            },
            .kw_struct => {
                try self.recordHeader(false);
                self.statement_start = false;
                return;
            },
            .kw_if => {
                try self.push(.conditional);
                self.statement_start = false;
            },
            .kw_for, .kw_while => {
                try self.push(.loop);
                if (token.kind == .kw_for) {
                    const name = try self.parser.peek();
                    if (name.kind == .identifier) self.frames.items[self.frames.items.len - 1].variable = .{ .name = self.parser.text(name), .span = name.span };
                }
                self.statement_start = false;
            },
            .kw_then, .kw_do => {
                if (token.kind == .kw_do and (self.frames.items.len == 0 or self.frames.items[self.frames.items.len - 1].scope != null or self.frames.items[self.frames.items.len - 1].kind != .loop or self.frames.items[self.frames.items.len - 1].nesting != self.parser.lexer.nesting)) {
                    try self.push(.block);
                    self.frames.items[self.frames.items.len - 1].scope = try self.open(.block, token.span.end);
                    self.parser.lexer.newline_nesting = self.parser.lexer.nesting;
                }
                if (self.frames.items.len != 0) {
                    const index = self.frames.items.len - 1;
                    const frame = self.frames.items[index];
                    if (frame.scope == null and ((token.kind == .kw_then and frame.kind == .conditional) or
                        (token.kind == .kw_do and frame.kind == .loop)))
                    {
                        const scope = try self.open(if (frame.kind == .conditional) .branch else .loop, token.span.end);
                        self.frames.items[index].scope = scope;
                        if (frame.variable) |name| try self.nameInScope(.{ .name = name.name, .span = name.span });
                        self.frames.items[index].newline_nesting = self.parser.lexer.newline_nesting;
                        self.parser.lexer.newline_nesting = self.parser.lexer.nesting;
                    }
                }
                self.statement_start = true;
            },
            .kw_elseif, .kw_else => {
                if (self.frames.items.len != 0) {
                    const index = self.frames.items.len - 1;
                    if (self.frames.items[index].kind == .conditional) {
                        self.closeBody(index, token.span.start);
                        if (token.kind == .kw_else) {
                            const scope = try self.open(.branch, token.span.end);
                            self.frames.items[index].scope = scope;
                        }
                    }
                }
                self.statement_start = token.kind == .kw_else;
            },
            .kw_end => {
                if (self.frames.items.len != 0) {
                    self.parser.lexer.newline_nesting = self.frames.items[self.frames.items.len - 1].newline_nesting;
                    self.closeBody(self.frames.items.len - 1, token.span.end);
                    _ = self.frames.pop();
                }
                self.statement_start = false;
            },
            .kw_param => {
                const name = try self.parser.peek();
                if (name.kind == .identifier) try self.nameInScope(.{ .name = self.parser.text(name), .span = name.span });
                self.statement_start = false;
            },
            .kw_export => {
                if ((try self.parser.peek()).kind == .kw_struct) {
                    try self.parser.advance();
                    try self.recordHeader(true);
                    self.records.items[self.records.items.len - 1].statement.span.start = token.span.start;
                    self.statement_start = false;
                    return;
                }
                try self.exportNames();
                self.statement_start = false;
            },
            .identifier => {
                if (self.statement_start) {
                    const next = try self.parser.peek();
                    if (next.kind == .declare or next.kind == .colon)
                        try self.nameInScope(.{ .name = self.parser.text(token), .span = token.span });
                }
                self.statement_start = false;
            },
            .newline, .semicolon => {
                self.statement_start = true;
            },
            else => self.statement_start = false,
        }
        try self.parser.advance();
    }

    // Default expressions have their own activation. Header scanning only
    // records scopes/imports; expressions are parsed after names are resolved.
    fn defaultExpression(self: *HeaderScanner) !*ast.Expr {
        const start = self.parser.current.span.start;
        const parent = self.active;
        const depth = self.frames.items.len;
        const nesting = self.parser.lexer.nesting - @as(usize, @intFromBool(switch (self.parser.current.kind) {
            .lparen, .lbracket, .lbrace => true,
            else => false,
        }));
        const scope = try self.open(.function, start);
        self.statement_start = false;
        while (true) {
            const token = self.parser.current;
            if (token.kind == .eof) return self.parser.fail(token.span, "expected ')' after parameters", .{});
            if (self.frames.items.len == depth and
                ((token.kind == .comma and self.parser.lexer.nesting == nesting) or
                    (token.kind == .rparen and self.parser.lexer.nesting + 1 == nesting))) break;
            try self.scanToken();
        }
        const span: source.Span = .{ .start = start, .end = self.parser.current.span.start };
        self.scopes.items[scope].value.body.end = span.end;
        self.active = parent;
        return self.parser.createExpr(span, .{ .block = &.{} });
    }

    // Each field default executes in its own function. Scan its nested blocks
    // with the same rules as script/function bodies, without binding field names.
    fn recordHeader(self: *HeaderScanner, exported: bool) !void {
        const start = (try self.parser.expect(.kw_struct, "expected 'struct'")).span;
        const name = try self.parser.expect(.identifier, "expected struct name");
        const parent = self.active;
        const depth = self.frames.items.len;
        const nesting = self.parser.lexer.nesting;
        var field: ?ScopeId = null;
        self.statement_start = true;
        while (self.parser.current.kind != .kw_end or self.frames.items.len != depth) {
            const token = self.parser.current;
            if (token.kind == .eof) return self.parser.fail(token.span, "expected 'end' for struct", .{});
            if (self.frames.items.len == depth and self.parser.lexer.nesting == nesting and
                self.statement_start and token.kind == .identifier and (try self.parser.peek()).kind == .colon)
            {
                if (field) |scope| self.scopes.items[scope].value.body.end = token.span.start;
                self.active = parent;
                field = try self.open(.function, token.span.start);
                self.statement_start = false;
            }
            try self.scanToken();
        }
        if (field) |scope| self.scopes.items[scope].value.body.end = self.parser.current.span.start;
        self.active = parent;
        const finish = try self.parser.expect(.kw_end, "expected 'end' for struct");
        const declaration = try self.parser.createStmt(.join(start, finish.span), .{ .structure = .{ .name = self.parser.text(name), .fields = &.{}, .exported = exported } });
        try self.records.append(self.allocator, .{ .scope = parent, .statement = declaration });
    }

    fn push(self: *HeaderScanner, kind: @FieldType(Frame, "kind")) !void {
        if (self.frames.items.len >= 256) return self.parser.fail(self.parser.current.span, "block nesting exceeds 256", .{});
        try self.frames.append(self.allocator, .{ .kind = kind, .parent = self.active, .nesting = self.parser.lexer.nesting, .newline_nesting = self.parser.lexer.newline_nesting });
    }

    fn open(self: *HeaderScanner, kind: @FieldType(Scope, "kind"), start: usize) !ScopeId {
        const index = std.math.cast(ScopeId, self.scopes.items.len) orelse return self.parser.fail(self.parser.current.span, "too many lexical scopes", .{});
        try self.scopes.append(self.allocator, .{ .value = .{ .parent = self.active, .kind = kind, .body = .{ .start = start, .end = self.parser.lexer.source.len }, .ordinary_names = &.{} } });
        self.active = index;
        return index;
    }

    fn closeBody(self: *HeaderScanner, frame_index: usize, end: usize) void {
        const frame = &self.frames.items[frame_index];
        if (frame.scope) |scope| self.scopes.items[scope].value.body.end = end;
        self.active = frame.parent;
        frame.scope = null;
    }

    fn nameInScope(self: *HeaderScanner, name: Local) !void {
        for (self.scopes.items[self.active].names.items) |existing| if (std.mem.eql(u8, existing.name, name.name))
            return self.parser.fail(name.span, "duplicate declaration '{s}'", .{name.name});
        const draft = &self.scopes.items[self.active];
        try draft.names.append(self.allocator, name);
    }

    fn exportNames(self: *HeaderScanner) !void {
        var lexer = self.parser.lexer;
        var current = try lexer.next();
        if (current.kind == .identifier) {
            const name = current;
            current = try lexer.next();
            if (current.kind == .declare) try self.nameInScope(.{ .name = self.parser.text(name), .span = name.span });
        }
    }
};

fn startsOperand(kind: Lexer.Kind) bool {
    return Lexer.isOperator(kind) or switch (kind) {
        .identifier, .integer, .float, .string, .kw_true, .kw_false, .kw_cycle, .minus, .plus, .kw_not, .lparen, .lbracket, .lbrace, .kw_typ, .kw_block => true,
        else => false,
    };
}

test "native path joins preserve kinds units cycle and operator-line continuation" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\curve:=(15mm,120mm)~~
        \\// The next knot belongs to this path.
        \\(50mm,132mm)--corner~~cycle
        \\size:=(a~~b).bounds()
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    const final = script.statements[0].value.assignment.value.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.smooth, final.kind);
    try std.testing.expect(final.right.value == .cycle);
    const middle = final.left.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.straight, middle.kind);
    try std.testing.expectEqualStrings("corner", middle.right.value.name);
    const first = middle.left.value.path_join;
    try std.testing.expectEqual(ast.PathJoin.smooth, first.kind);
    try std.testing.expectEqual(units.Unit.mm, first.left.value.pair.x.value.quantity.unit);
    const postfix = script.statements[1].value.assignment.value.value.call;
    try std.testing.expect(postfix.dot);
    try std.testing.expectEqualStrings("bounds", postfix.name);
    try std.testing.expect(postfix.args[0].value.grouped.value == .path_join);
}

test "dangling path joins fail at the missing operand" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "p:=a~~", "p:=a--\n", "p:=a~~;", "p:=a~~--b", "p:=~~a", "p:=a..b", "cycle=1" }) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

fn ungroup(node: *ast.Expr) *ast.Expr {
    var current = node;
    while (current.value == .grouped) current = current.value.grouped;
    return current;
}

test "native unit syntax accepts horizontal spacing and preserves identifier boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\a:=1cm; b:=1 cm
        \\c:=2pi rad; d:=2 pi rad; e:=(2*pi) rad
        \\inch:=1in
        \\separate:=2
        \\cm:=3
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(units.Unit.cm, script.statements[0].value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(units.Unit.cm, script.statements[1].value.assignment.value.value.quantity.unit);
    for (script.statements[2..5]) |stmt| try std.testing.expectEqual(units.Unit.rad, stmt.value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(units.Unit.in, script.statements[5].value.assignment.value.value.quantity.unit);
    try std.testing.expectEqual(@as(usize, 8), script.statements.len);
    for ([_][]const u8{ "angle:=2pirad", "length:=2unknown" }) |input| {
        parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "identifiers are not split") != null);
    }
}

test "prefix declarations are available before their source position and preserve explicit calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=wrap 1+2
        \\mixfix(wrap) wrap _ in addition
        \\ordinary:=wrap(1+2)
        \\spaced:=wrap (1+2)
        \\grouped:=(wrap)(1)
        \\mixed:=wrap a shifted b+2
        \\wrap:=3
    , .{}, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("wrap", first.operator.name);
    try std.testing.expectEqual(ast.Binary.add, first.args[0].value.binary.op);
    try std.testing.expectEqualStrings("wrap", script.statements[1].value.mixfix_binding.target.name);
    try std.testing.expectEqualStrings("wrap", script.statements[2].value.assignment.value.value.call.name);
    try std.testing.expectEqualStrings("wrap", script.statements[3].value.assignment.value.value.mixfix_call.operator.name);
    try std.testing.expect(script.statements[3].value.assignment.value.value.mixfix_call.args[0].value == .grouped);
    try std.testing.expectEqualStrings("wrap", script.statements[4].value.assignment.value.value.call.name);
    const mixed = script.statements[5].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("wrap", mixed.args[0].value.mixfix_call.operator.name);
    try std.testing.expectEqualStrings("shifted", mixed.operator.name);
    try std.testing.expectEqualStrings("wrap", script.statements[6].value.assignment.name);
}

test "spaced prefix coordinate groups work in drawing and qualified calls" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            if (leading) return null;
            const matches = if (name.namespace) |ns|
                std.mem.eql(u8, ns, "paint") and std.mem.eql(u8, name.name, "sphere")
            else
                std.mem.eql(u8, name.name, "draw") or std.mem.eql(u8, name.name, "fill");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(),
        \\block
        \\    draw (0,0)--(10,10)
        \\    fill (0,0)--(10,0)--(10,10)--cycle
        \\    object.append(pic, draw(curve))
        \\end
        \\spaced:=paint.sphere (1+2)
        \\ordinary:=paint.sphere(1+2)
        \\unbound:=plain (1+2)
    , .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const statements = script.statements[0].value.expression.value.block;
    for (statements[0..2]) |stmt| {
        const call = stmt.value.expression.value.mixfix_call;
        try std.testing.expect(call.args[0].value == .path_join);
    }
    try std.testing.expect(statements[2].value.expression.value == .call);
    const spaced = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("paint", spaced.operator.namespace.?);
    try std.testing.expectEqualStrings("sphere", spaced.operator.name);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .call);
}

test "qualified prefix lookup preserves namespaced ordinary calls" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            const matches = !leading and name.namespace != null and std.mem.eql(u8, name.namespace.?, "tools") and std.mem.eql(u8, name.name, "wrap");
            return if (matches) .{ .form = .{ .head = name.name, .parts = &.{null}, .group = .{ .name = "unary", .span = name.span } } } else null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(),
        \\x:=tools.wrap -2^2
        \\y:=tools.wrap(2)
        \\z:=tools.image
    , .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("tools", first.operator.namespace.?);
    try std.testing.expectEqualStrings("wrap", first.operator.name);
    try std.testing.expectEqual(ast.Unary.negate, first.args[0].value.unary.op);
    try std.testing.expect(script.statements[1].value.assignment.value.value.call.dot);
    try std.testing.expectEqualStrings("image", script.statements[2].value.assignment.value.value.member.name);
}

test "header scans reuse native Typst block ranges and ignore embedded declarations" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = if (input[0] == '{') "{\nimport \"ignored\" as ignored\nmixfix(hidden) hidden _ in addition\n}" else "[\n#let prefix = \"@\"\n]";
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
        \\setup_typst {
        \\import "ignored" as ignored
        \\mixfix(hidden) hidden _ in addition
        \\}
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

fn sameOperatorName(a: ast.OperatorName, b: ast.OperatorName) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace) |left| return if (b.namespace) |right| std.mem.eql(u8, left, right) else false;
    return b.namespace == null;
}

fn binary(kind: Lexer.Kind) ?struct { op: ast.Binary, precedence: u8 } {
    return switch (kind) {
        .kw_or => .{ .op = .logical_or, .precedence = 1 },
        .kw_and => .{ .op = .logical_and, .precedence = 2 },
        .equal => .{ .op = .equal, .precedence = 3 },
        .not_equal => .{ .op = .not_equal, .precedence = 3 },
        .less => .{ .op = .less, .precedence = 4 },
        .less_equal => .{ .op = .less_equal, .precedence = 4 },
        .greater => .{ .op = .greater, .precedence = 4 },
        .greater_equal => .{ .op = .greater_equal, .precedence = 4 },
        .plus => .{ .op = .add, .precedence = 5 },
        .minus => .{ .op = .subtract, .precedence = 5 },
        .star => .{ .op = .multiply, .precedence = 6 },
        .slash => .{ .op = .divide, .precedence = 6 },
        .percent => .{ .op = .remainder, .precedence = 6 },
        .caret => .{ .op = .power, .precedence = 8 },
        else => null,
    };
}

test "precedence declarations use contextual attributes and qualified names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\precedence transform
        \\ above path
        \\ below arithmetic.addition
        \\ associativity left
        \\end
        \\mixfix(scaled) _ scaled _ in transform
        \\mixfix(shifted) _ shifted _ in common.transform
        \\left:=1;right:=2;none:=3;above:=4;below:=5;associativity:=6
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 9), script.statements.len);
    const group = script.statements[0].value.precedence_group;
    try std.testing.expectEqualStrings("transform", group.name);
    try std.testing.expectEqual(ast.Associativity.left, group.associativity);
    try std.testing.expectEqual(@as(usize, 2), group.relations.len);
    try std.testing.expectEqual(.above, group.relations[0].direction);
    try std.testing.expect(group.relations[0].target.namespace == null);
    try std.testing.expectEqualStrings("path", group.relations[0].target.name);
    try std.testing.expectEqualStrings("above path", parser.lexer.source[group.relations[0].span.start..group.relations[0].span.end]);
    try std.testing.expectEqual(.below, group.relations[1].direction);
    try std.testing.expectEqualStrings("arithmetic", group.relations[1].target.namespace.?);
    try std.testing.expectEqualStrings("addition", group.relations[1].target.name);
    try std.testing.expectEqualStrings("scaled", script.statements[1].value.mixfix_binding.target.name);
    try std.testing.expectEqualStrings("common", script.statements[2].value.mixfix_binding.form.group.namespace.?);
    const contextual = [_][]const u8{ "left", "right", "none", "above", "below", "associativity" };
    for (contextual, script.statements[3..]) |name, stmt| try std.testing.expectEqualStrings(name, stmt.value.assignment.name);
}

test "precedence groups support none by default and explicit right association" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\precedence a;end
        \\precedence b;associativity right;end
        \\precedence c;associativity none;end
    , .{}, &diagnostic);
    const script = try parser.parse();
    for ([_]ast.Associativity{ .none, .right, .none }, script.statements) |expected, stmt|
        try std.testing.expectEqual(expected, stmt.value.precedence_group.associativity);
}

test "precedence syntax rejects malformed duplicated and unknown attributes" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "precedence g\nassociativity left\nassociativity right\nend", .message = "duplicate associativity" },
        .{ .code = "precedence g\nabove common.g\nabove common.g\nend", .message = "duplicate 'above' relation" },
        .{ .code = "precedence g\nassociativity middle\nend", .message = "left, right, or none" },
        .{ .code = "precedence g\nunknown x\nend", .message = "unknown precedence attribute" },
        .{ .code = "precedence g\nabove x below y\nend", .message = "between precedence attributes" },
        .{ .code = "precedence g\nabove x\n", .message = "unterminated precedence group" },
        .{ .code = "mixfix(f) _ f _", .message = "expected a mixfix word" },
        .{ .code = "mixfix(f) _ f _ in", .message = "operator or precedence group name" },
        .{ .code = "mixfix(f) _ f _ in x.", .message = "name after namespace" },
        .{ .code = "mixfix(f) _ ns.f _ in x", .message = "expected a mixfix word" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "word operator chains remain unresolved while grouping stays explicit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=1+2 scaled 3*4 shifted (5+6)
        \\y:=(a shifted b) tools.scaled -c^2
        \\ordinary:=scaled(1,2)
        \\method:=shapes.item.norm()
    , .{}, &diagnostic);
    const script = try parser.parse();
    const outer = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("shifted", outer.operator.name);
    try std.testing.expectEqual(ast.Binary.add, outer.args[1].value.grouped.value.binary.op);
    const inner = outer.args[0].value.mixfix_call;
    try std.testing.expectEqualStrings("scaled", inner.operator.name);
    try std.testing.expectEqual(ast.Binary.add, inner.args[0].value.binary.op);
    try std.testing.expectEqual(ast.Binary.multiply, inner.args[1].value.binary.op);
    const qualified = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("tools", qualified.operator.namespace.?);
    try std.testing.expectEqualStrings("scaled", qualified.operator.name);
    try std.testing.expectEqualStrings("shifted", qualified.args[0].value.grouped.value.mixfix_call.operator.name);
    try std.testing.expectEqual(ast.Unary.negate, qualified.args[1].value.unary.op);
    try std.testing.expectEqual(ast.Binary.power, qualified.args[1].value.unary.operand.value.binary.op);
    const ordinary = script.statements[2].value.assignment.value.value.call;
    try std.testing.expect(!ordinary.dot);
    try std.testing.expectEqual(@as(usize, 2), ordinary.args.len);
    const method = script.statements[3].value.assignment.value.value.call;
    try std.testing.expect(method.dot);
    try std.testing.expectEqualStrings("item", method.args[0].value.member.name);
}

test "parenthesized names keep ordinary calls and import literals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=((foo))(1)
        \\y:=(point.x)()
        \\import ("source.huak") as shapes
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("foo", script.statements[0].value.assignment.value.value.call.name);
    const member = script.statements[1].value.assignment.value.value.call;
    try std.testing.expect(member.dot);
    try std.testing.expectEqualStrings("x", member.name);
    try std.testing.expectEqualStrings("point", member.args[0].value.name);
    try std.testing.expectEqualStrings("source.huak", script.statements[2].value.imported.path);
}

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
        \\export fn points(label:string, points:pair...)->list return points end
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
    try std.testing.expectEqualStrings("pair", typed.params[1].annotation.name);
    try std.testing.expectEqualStrings("points:pair...", input[typed.params[1].span.start..typed.params[1].span.end]);
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
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "call spread is rejected explicitly rather than treated as a member or path" {
    for ([_][]const u8{ "collect(points...)", "collect(1,points...)", "picture.collect(points...)", "collect(...points)" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "spread") != null);
        try std.testing.expectEqualStrings("...", input[diagnostic.?.span.start..diagnostic.?.span.end]);
    }
}

test "native Typst ellipses remain opaque inside variadic functions" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = "[#f(..args) ... end]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    const input = "export fn label(args...) return typ[#f(..args) ... end] end\nimport paint.*";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    var parser = try Parser.init(arena.allocator(), input, options, &diagnostic);
    const script = try parser.parse();
    const declaration = script.statements[0].value.function;
    try std.testing.expect(declaration.params[0].variadic);
    try std.testing.expectEqualStrings("#f(..args) ... end", declaration.body[0].value.return_value.?.value.typst);
    try std.testing.expect(script.statements[1].value.imported.form == .all);
    const headers = try scanHeaders(arena.allocator(), input, options, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), headers.imports.len);
    try std.testing.expectEqualStrings("paint", headers.imports[0].statement.value.imported.path);
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
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.indexOf(u8, input, "condition").?));
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.indexOf(u8, input, "alternative").?));
    try std.testing.expectEqual(function, headers.scopeAt(std.mem.indexOf(u8, input, "lower").?));
    const loop = headers.scopeAt(std.mem.indexOf(u8, input, "ready").?);
    try std.testing.expect(headers.scopes[loop].kind == .loop);
    try std.testing.expectEqual(function, headers.scopes[loop].parent.?);
    const while_body = headers.scopeAt(std.mem.indexOf(u8, input, "block").?);
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
    const function = headers.scopeAt(std.mem.indexOf(u8, input, "return argument").?);
    try std.testing.expect(headers.scopes[function].kind == .function);
    try std.testing.expectEqual(@as(usize, 2), headers.scopes[function].ordinary_names.len);
    try std.testing.expectEqualStrings("argument", headers.scopes[function].ordinary_names[0].name);
    try std.testing.expectEqualStrings("later", headers.scopes[function].ordinary_names[1].name);
}

test "standalone prefix discovery respects block boundaries and callable data namespaces" {
    const input =
        \\fn f()
        \\    if true then
        \\        mixfix(decorate) decorate _ in unary
        \\        decorate:=1
        \\        first:=decorate (2)
        \\    else
        \\        second:=decorate (3)
        \\    end
        \\    third:=decorate (4)
        \\end
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try parser.parse();
    const statements = script.statements[0].value.function.body;
    const conditional = statements[0].value.conditional;
    try std.testing.expect(conditional.branches[0].body[2].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(conditional.otherwise[0].value.assignment.value.value == .call);
    try std.testing.expect(statements[1].value.assignment.value.value == .call);
}

test "mixfix callback null cannot be bypassed by header or drawing shortcuts" {
    const Lookup = struct {
        fn lookup(_: *anyopaque, _: ast.OperatorName, _: bool) ?MixfixLookup.Binding {
            return null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    var parser = try Parser.init(arena.allocator(), "mixfix(decorate) decorate _ in unary\nx:=decorate (1)\nblock draw (curve) end", .{ .mixfix = .{ .ptr = &context, .vtable = &.{ .lookup = Lookup.lookup } } }, &diagnostic);
    const script = try parser.parse();
    try std.testing.expect(script.statements[1].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[2].value.expression.value.block[0].value.expression.value == .call);
}

test "default and export are reserved while defer is an ordinary name" {
    const invalid = [_][]const u8{
        "default=1", "fn default();end", "fn f(default:int);end", "param default=1", "export default picture()", "default", "export foo.bar", "export foo(1)", "param missing",
    };
    for (invalid) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "defer:=1\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("defer", script.statements[0].value.assignment.name);
}

test "list append assignment is a statement with an existing named target" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "items+=value;items += [1,2]\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    const first = script.statements[0].value.list_append;
    try std.testing.expectEqualStrings("items", first.name);
    try std.testing.expectEqualStrings("value", first.value.value.name);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].span.start);
    try std.testing.expectEqual(@as(usize, 12), script.statements[0].span.end);
    try std.testing.expect(script.statements[1].value.list_append.value.value == .list);
}

test "list append assignment cannot be annotated chained or used as an expression" {
    for ([_][]const u8{
        "(items)+=1",        "items:list+=1",
        "value:=(items+=1)", "items+=other+=1",
        "items+=",           "param items+=1",
        "export items+=1",
    }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "script functions control flow arrays pairs and source positions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "param n: int = 4\nfn foo(x: int) -> int\nif x <= 1 then return 1; else return x * foo(x-1); end\nend\na := [foo(n), (2,\n3)]\nfor i in 1:2:9 do\ncontinue\nend\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), script.statements.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].span.start);
    try std.testing.expectEqualStrings("foo", script.statements[1].value.function.name);
    try std.testing.expect(script.statements[3].value.for_loop.iterable.range.step != null);
}

test "explicit control delimiters support nested bodies on one line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "for i in 1:2:9 do while i<5 do if i==1 then continue elseif i==3 then break else i=i+1 end end end", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), script.statements.len);
    const loop = script.statements[0].value.for_loop;
    try std.testing.expectEqual(@as(u64, 2), loop.iterable.range.step.?.value.integer);
    const nested = loop.body[0].value.while_loop.body[0].value.conditional;
    try std.testing.expectEqual(@as(usize, 2), nested.branches.len);
    try std.testing.expect(nested.branches[0].body[0].value == .continue_loop);
    try std.testing.expect(nested.branches[1].body[0].value == .break_loop);
    try std.testing.expectEqual(@as(usize, 1), nested.otherwise.len);
}

test "all block heads accept inline and multiline bodies without line-boundary rules" {
    const Statement = std.meta.Tag(@FieldType(ast.Stmt, "value"));
    const cases = [_]struct { inline_: []const u8, multiline: []const u8, kind: Statement }{
        .{ .inline_ = "fn f(x:int)->int return x end", .multiline = "fn f(x:int)->int\nreturn x\nend", .kind = .function },
        .{ .inline_ = "fn empty() end", .multiline = "fn empty()\nend", .kind = .function },
        .{ .inline_ = "precedence custom above addition;associativity left end", .multiline = "precedence custom\nabove addition\nassociativity left\nend", .kind = .precedence_group },
        .{ .inline_ = "precedence empty end", .multiline = "precedence empty\nend", .kind = .precedence_group },
        .{ .inline_ = "block mixfix(draw) draw _ in logical_or;draw curve end", .multiline = "block\nmixfix(draw) draw _ in logical_or\ndraw curve\nend", .kind = .expression },
        .{ .inline_ = "if ready then end", .multiline = "if ready\nthen\nend", .kind = .conditional },
        .{ .inline_ = "for i in 1:3 do end", .multiline = "for i in 1:3\ndo\nend", .kind = .for_loop },
        .{ .inline_ = "while ready do end", .multiline = "while ready\ndo\nend", .kind = .while_loop },
    };
    for (cases) |case| for ([_][]const u8{ case.inline_, case.multiline }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        const script = try parser.parse();
        try std.testing.expectEqual(@as(usize, 1), script.statements.len);
        try std.testing.expectEqual(case.kind, std.meta.activeTag(script.statements[0].value));
    };
}

test "control bodies allow empty blocks and optional separators after their delimiters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\if ready then end
        \\if first
        \\then;
        \\elseif second
        \\then
        \\else
        \\end
        \\while ready
        \\do;end
        \\for i in 1:3
        \\do
        \\end
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 4), script.statements.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[0].value.conditional.branches[0].body.len);
    try std.testing.expectEqual(@as(usize, 2), script.statements[1].value.conditional.branches.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[1].value.conditional.otherwise.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[2].value.while_loop.body.len);
    try std.testing.expectEqual(@as(usize, 0), script.statements[3].value.for_loop.body.len);
}

test "control delimiters are required and do not remove ordinary statement boundaries" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "if true\nend", .message = "expected 'then'" },
        .{ .code = "if true do end", .message = "expected 'then'" },
        .{ .code = "if true then elseif false\nend", .message = "expected 'then'" },
        .{ .code = "if true;then end", .message = "expected 'then'" },
        .{ .code = "while true\nend", .message = "expected 'do'" },
        .{ .code = "while true then end", .message = "expected 'do'" },
        .{ .code = "for i in 1:3\nend", .message = "expected 'do'" },
        .{ .code = "for i in 1:3 then end", .message = "expected 'do'" },
        .{ .code = "for i in 1:3;do end", .message = "expected 'do'" },
        .{ .code = "if true then print(1) if true then end end", .message = "between statements" },
        .{ .code = "fn f() return 1 return 2 end", .message = "between statements" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "then and do cannot be used as declaration names" {
    for ([_][]const u8{ "then=1", "do=1", "param do=1", "fn then();end", "fn f(do:int);end", "import \"other\" as then" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "embedded source requires a native source-block provider" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "t:=typ[Hello]\n", .{}, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "source-block") != null);
}

test "native Typst blocks preserve their source and resume host expressions" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = if (input[0] == '{') "{let x=2}" else "[Hello]";
            try std.testing.expect(std.mem.startsWith(u8, input, fixture));
            return fixture.len;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var context: u8 = 0;
    const options: Options = .{ .source_parser = .{ .ptr = &context, .vtable = &.{ .block = Blocks.block } } };
    var parser = try Parser.init(arena.allocator(), "typst:=2\nvalue:=typ[Hello]\n", options, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), script.statements.len);
    try std.testing.expectEqualStrings("typst", script.statements[0].value.assignment.name);
    try std.testing.expectEqualStrings("Hello", script.statements[1].value.assignment.value.value.typst);
    parser = try Parser.init(arena.allocator(), "setup_typst {let x=2}; value:=measure(typ [Hello],2)", options, &diagnostic);
    const inline_script = try parser.parse();
    try std.testing.expectEqualStrings("let x=2", inline_script.statements[0].value.setup_typst);
    const call = inline_script.statements[1].value.assignment.value.value.call;
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqualStrings("Hello", call.args[0].value.typst);
    parser = try Parser.init(arena.allocator(), "value:=typst\nHello\nend\n", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    for ([_][]const u8{ "value=typ\nHello\nend\n", "value=typ;\nend\n", "value=typ{Hello}", "setup_typst[let x=2]" }) |input| {
        diagnostic = null;
        parser = try Parser.init(arena.allocator(), input, options, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "expected '") != null);
    }
}

test "Typst block providers cannot return ranges outside the source" {
    const Blocks = struct {
        fn block(context: *anyopaque, _: []const u8) !usize {
            const length: *usize = @ptrCast(@alignCast(context));
            return length.*;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 0, 1, 3, std.math.maxInt(usize) }) |invalid_length| {
        var length = invalid_length;
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), "value:=typ[Hello]", .{ .source_parser = .{ .ptr = &length, .vtable = &.{ .block = Blocks.block } } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "invalid range") != null);
    }
}

test "strings use JSON escapes and preserve unicode" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), "a:=\"中文\\n\\u03bb\"\n", .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("中文\nλ", script.statements[0].value.assignment.value.value.string);
    parser = try Parser.init(arena.allocator(), "a:=1\nb:=\"\\q\"", .{}, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    const position = diagnostic.?.position("a:=1\nb:=\"\\q\"");
    try std.testing.expectEqual(@as(usize, 2), position.line);
    try std.testing.expectEqual(@as(usize, 4), position.column);
}

test "dot calls lower arbitrary receivers and chains to named calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\value:=(1+2).combine(3,4).finish()
        \\indexed:=items[0].combine(3)
        \\member:=point.x
        \\called:=point.x()
        \\created:=make().finish()
    , .{}, &diagnostic);
    const script = try parser.parse();
    const finish = script.statements[0].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("finish", finish.name);
    try std.testing.expectEqual(@as(usize, 1), finish.args.len);
    const combine = finish.args[0].value.call;
    try std.testing.expectEqualStrings("combine", combine.name);
    try std.testing.expectEqual(@as(usize, 3), combine.args.len);
    try std.testing.expectEqual(ast.Binary.add, combine.args[0].value.grouped.value.binary.op);
    try std.testing.expectEqual(@as(u64, 3), combine.args[1].value.integer);
    try std.testing.expectEqual(@as(u64, 4), combine.args[2].value.integer);
    const indexed = script.statements[1].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("items", indexed.args[0].value.index.object.value.name);
    try std.testing.expectEqual(@as(u64, 0), indexed.args[0].value.index.index.value.integer);
    const member = script.statements[2].value.assignment.value.value.member;
    try std.testing.expectEqualStrings("x", member.name);
    const called = script.statements[3].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("x", called.name);
    try std.testing.expectEqualStrings("point", called.args[0].value.name);
    const created = script.statements[4].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("make", created.args[0].value.call.name);
    try std.testing.expectEqual(@as(usize, 0), created.args[0].value.call.args.len);
}

test "dot calls do not introduce callable values" {
    for ([_][]const u8{ "make()(1)", "[make][0](1)", "(1+2)(3)" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expectEqualStrings("only named functions can be called", diagnostic.?.text());
    }
}

test "list slice forms share the loop range grammar and compose with postfix calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\element:=items[2]
        \\tail:=items[1:]
        \\window:=items[1:3]
        \\stride:=items[5:-2:1]
        \\chained:=make()[first():delta():last()][0].finish()
        \\for i in first():delta():last() do end
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(u64, 2), script.statements[0].value.assignment.value.value.index.index.value.integer);
    const tail = script.statements[1].value.assignment.value.value.slice;
    try std.testing.expectEqualStrings("items", tail.object.value.name);
    try std.testing.expectEqual(@as(u64, 1), tail.range.start.value.integer);
    try std.testing.expect(tail.range.step == null and tail.range.stop == null);
    const window = script.statements[2].value.assignment.value.value.slice.range;
    try std.testing.expect(window.step == null);
    try std.testing.expectEqual(@as(u64, 3), window.stop.?.value.integer);
    const stride = script.statements[3].value.assignment.value.value.slice.range;
    try std.testing.expectEqual(ast.Unary.negate, stride.step.?.value.unary.op);
    try std.testing.expectEqual(@as(u64, 2), stride.step.?.value.unary.operand.value.integer);
    try std.testing.expectEqual(@as(u64, 1), stride.stop.?.value.integer);
    const chained = script.statements[4].value.assignment.value.value.call.args[0].value.index.object.value.slice;
    try std.testing.expectEqualStrings("make", chained.object.value.call.name);
    const loop = script.statements[5].value.for_loop;
    try std.testing.expectEqualStrings(loop.iterable.range.start.value.call.name, chained.range.start.value.call.name);
    try std.testing.expectEqualStrings(loop.iterable.range.step.?.value.call.name, chained.range.step.?.value.call.name);
    try std.testing.expectEqualStrings(loop.iterable.range.stop.?.value.call.name, chained.range.stop.?.value.call.name);
}

test "list slices require a start and do not add multi-index or extra open forms" {
    for ([_][]const u8{ "items[:]", "items[:3]", "items[1,2]", "items[1::3]", "items[1:2:]", "items[1:2:3:4]", "for i in 1: do end" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(diagnostic != null);
    }
}

test "mixfix forms delimit multiple arguments and preserve ordinary calls and labels as names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\first:=construct with center (1,2) radius (3+4)
        \\mixfix(construct) construct with center _ radius _ in unary
        \\ordinary:=construct((1,2),7)
        \\with:=1;center:=2;radius:=3
        \\last:=construct with center center radius radius
        \\member:=library.image
    , .{}, &diagnostic);
    const script = try parser.parse();
    const mixed = script.statements[0].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("construct", mixed.operator.name);
    try std.testing.expectEqual(@as(usize, 2), mixed.args.len);
    try std.testing.expect(mixed.args[0].value == .pair);
    try std.testing.expect(mixed.args[1].value == .grouped);
    const form = script.statements[1].value.mixfix_binding.form;
    try std.testing.expectEqual(@as(usize, 2), form.arity());
    try std.testing.expectEqualStrings("with", form.parts[0].?);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .call);
    const variable_args = script.statements[6].value.assignment.value.value.mixfix_call.args;
    try std.testing.expectEqualStrings("center", variable_args[0].value.name);
    try std.testing.expectEqualStrings("radius", variable_args[1].value.name);
    try std.testing.expectEqualStrings("image", script.statements[7].value.assignment.value.value.member.name);
}

test "mixfix labels stop only their current argument and parentheses isolate nested forms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\mixfix(combine) combine from _ onto _ in unary
        \\first:=combine from f(onto)+p.onto onto [1,2][0]
        \\second:=combine from (combine from p onto q) onto q
        \\if true then
        \\    mixfix(combine) combine with left _ right _ in unary
        \\    inside:=combine with left 3 right 4
        \\end
        \\outside:=combine from 5 onto 6
    , .{}, &diagnostic);
    const script = try parser.parse();
    const first = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expect(first.args[0].value == .binary);
    try std.testing.expect(first.args[1].value == .index);
    const second = script.statements[2].value.assignment.value.value.mixfix_call;
    try std.testing.expect(second.args[0].value.grouped.value == .mixfix_call);
    const branch = script.statements[3].value.conditional.branches[0].body;
    try std.testing.expectEqual(@as(u64, 3), branch[1].value.assignment.value.value.mixfix_call.args[0].value.integer);
    try std.testing.expectEqual(@as(u64, 5), script.statements[4].value.assignment.value.value.mixfix_call.args[0].value.integer);
}

test "mixfix incomplete words and arguments continue lines without swallowing complete statements" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\mixfix(combine) combine with first _
        \\    second _ in
        \\    unary
        \\result:=combine with
        \\    first
        \\    (1+2)
        \\    second
        \\    4
        \\following:=5
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(@as(usize, 3), script.statements.len);
    const args = script.statements[1].value.assignment.value.value.mixfix_call.args;
    try std.testing.expect(args[0].value == .grouped);
    try std.testing.expectEqual(@as(u64, 4), args[1].value.integer);
    try std.testing.expectEqualStrings("following", script.statements[2].value.assignment.name);
}

test "mixfix declarations reject ambiguous templates and unparenthesized nested forms" {
    const invalid = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "mixfix(f) f with _ _ in unary", .message = "preceded by a word" },
        .{ .input = "mixfix(f) f with _ ending in unary", .message = "must end" },
        .{ .input = "mixfix(f) f with center in unary", .message = "must end" },
        .{ .input = "mixfix(f) f in unary", .message = "must end" },
        .{ .input = "mixfix(f) f cm _ in unary", .message = "unit 'cm'" },
        .{ .input = "mixfix(f) f then _ in unary", .message = "expected a mixfix word" },
        .{ .input = "mixfix(f) f from _ until _ in unary; x:=f from 1 true 2", .message = "expected mixfix word 'until'" },
        .{ .input = "mixfix(f) f from _ until _ in unary; x:=f from f from 1 until 2 until 3", .message = "require parentheses" },
        .{ .input = "mixfix(crop) _ crop from _ to _ in addition; x:=1 crop 2", .message = "expected mixfix word 'from'" },
        .{ .input = "mixfix(crop) _ crop from _ to _ in addition; x:=1 crop(2)", .message = "expected mixfix word 'from'" },
    };
    for (invalid) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), case.input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "mixfix providers support qualified names and reject malformed external templates" {
    const Lookup = struct {
        fn lookup(context: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            if (leading) return null;
            const form: *const ast.MixfixForm = @ptrCast(@alignCast(context));
            if (name.namespace != null and std.mem.eql(u8, name.namespace.?, "shapes") and std.mem.eql(u8, name.name, "make")) return .{ .form = form.* };
            return null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var form: ast.MixfixForm = .{ .head = "make", .parts = &.{ "with", "center", null, "radius", null }, .group = .{ .name = "unary", .span = .{ .start = 0, .end = 0 } } };
    const options: Options = .{ .mixfix = .{ .ptr = &form, .vtable = &.{ .lookup = Lookup.lookup } } };
    var parser = try Parser.init(arena.allocator(), "x:=shapes.make with center (0,0) radius 1", options, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("shapes", script.statements[0].value.assignment.value.value.mixfix_call.operator.namespace.?);
    form.parts = &.{ "with", null, null };
    parser = try Parser.init(arena.allocator(), "x:=shapes.make with 1", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, parser.parse());
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "invalid mixfix template") != null);
}

test "Typst exposure declarations retain exact names and lexical header scopes" {
    const input = "typst_expose title,\ncount\nfn label(value:int)->void\ntypst_expose value\nif true then\ntypst_expose inside\nelse\ntypst_expose other\nend\nend\n";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), input, .{}, &diagnostic);
    try std.testing.expectEqual(@as(usize, 4), headers.typst_exposures.len);
    try std.testing.expectEqual(@as(ScopeId, 0), headers.typst_exposures[0].scope);
    try std.testing.expect(headers.scopes[headers.typst_exposures[1].scope].kind == .function);
    try std.testing.expect(headers.scopes[headers.typst_exposures[2].scope].kind == .branch);
    try std.testing.expect(headers.typst_exposures[2].scope != headers.typst_exposures[3].scope);
    var frontend = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
    const script = try frontend.parse();
    const names = script.statements[0].value.typst_expose;
    try std.testing.expectEqual(@as(usize, 2), names.len);
    for (names, [_][]const u8{ "title", "count" }) |name, expected| {
        try std.testing.expectEqualStrings(expected, name.name);
        try std.testing.expectEqualStrings(expected, input[name.span.start..name.span.end]);
    }
    for ([_][]const u8{ "typst_expose", "typst_expose value,", "typst_expose module.value", "typst_expose 42", "typst_expose value=1" }) |invalid| {
        var broken = try Parser.init(arena.allocator(), invalid, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, broken.parse());
    }
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

test "dictionaries and named calls preserve order decoded keys and nested assignment targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var frontend = try Parser.init(arena.allocator(),
        \\options:={"line-width": 2mm, "nested": {"value": [1,2]},}
        \\empty:={}
        \\style:=Style(1, width: 2mm, options: options)
        \\other:=palette.Style(width: 3mm,)
        \\plain:=f(1,2)
        \\data[0].items["key"].width=4mm
        \\data[lookup("key")]=style
        \\name:=2
        \\values += [3]
    , .{}, &diagnostic);
    const script = try frontend.parse();
    const dict = script.statements[0].value.assignment.value.value.dict;
    try std.testing.expectEqual(@as(usize, 2), dict.len);
    try std.testing.expectEqualStrings("line-width", dict[0].key);
    try std.testing.expect(dict[0].value.value == .quantity);
    try std.testing.expect(dict[1].value.value.dict[0].value.value == .list);
    try std.testing.expectEqual(@as(usize, 0), script.statements[1].value.assignment.value.value.dict.len);
    const call = script.statements[2].value.assignment.value.value.call;
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expect(call.argument_names[0] == null);
    try std.testing.expectEqualStrings("width", call.argument_names[1].?);
    try std.testing.expectEqualStrings("options", call.argument_names[2].?);
    const qualified = script.statements[3].value.assignment.value.value.call;
    try std.testing.expect(qualified.dot);
    try std.testing.expect(qualified.argument_names[0] == null);
    try std.testing.expectEqualStrings("width", qualified.argument_names[1].?);
    try std.testing.expectEqual(@as(usize, 0), script.statements[4].value.assignment.value.value.call.argument_names.len);
    const target = script.statements[5].value.set.target.value.member;
    try std.testing.expectEqualStrings("width", target.name);
    try std.testing.expect(target.object.value.index.object.value == .member);
    try std.testing.expect(script.statements[6].value.set.target.value.index.index.value == .call);
    try std.testing.expect(script.statements[7].value == .assignment);
    try std.testing.expect(script.statements[8].value == .list_append);
}

test "aggregate syntax rejects malformed fields dictionaries calls and lvalues" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "struct end", .message = "expected struct name" },
        .{ .code = "struct A x:int", .message = "expected 'end'" },
        .{ .code = "struct A x:=1 end", .message = "explicit type annotation" },
        .{ .code = "struct A x: end", .message = "expected a type name" },
        .{ .code = "struct A x:int; x:int end", .message = "duplicate struct field" },
        .{ .code = "struct A x:int y:int end", .message = "between struct fields" },
        .{ .code = "struct A fn method() end end", .message = "typed struct field" },
        .{ .code = "x: lib. = 1", .message = "type name after '.'" },
        .{ .code = "x:={key:1}", .message = "keys must be string literals" },
        .{ .code = "x:={1:2}", .message = "keys must be string literals" },
        .{ .code = "x:={\"a\":1,\"\\u0061\":2}", .message = "duplicate dictionary key" },
        .{ .code = "x:={\"a\" 1}", .message = "':' after dictionary key" },
        .{ .code = "x:={\"a\":}", .message = "expected an expression" },
        .{ .code = "x:=f(a:1,2)", .message = "positional arguments cannot follow" },
        .{ .code = "x:=f(a:1,a:2)", .message = "duplicate named argument" },
        .{ .code = "x:=f(a:)", .message = "expected an expression" },
        .{ .code = "x:=f(\"a\":1)", .message = "')' after arguments" },
        .{ .code = "a+b=2", .message = "assignment target" },
        .{ .code = "data.x:int=2", .message = "assignment target" },
        .{ .code = "data[0:2]=[]", .message = "assignment target" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var frontend = try Parser.init(arena.allocator(), case.code, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, frontend.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "record headers ignore fields and opaque Typst while retaining their containing scope" {
    const Blocks = struct {
        fn block(_: *anyopaque, input: []const u8) !usize {
            const fixture = "[end struct Bogus import fake typst_expose field]";
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
        \\    label:text=typ[end struct Bogus import fake typst_expose field]
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
    try std.testing.expectEqual(@as(usize, 0), headers.typst_exposures.len);
    var frontend = try Parser.init(arena.allocator(), input, options, &diagnostic);
    const script = try frontend.parse();
    try std.testing.expectEqualStrings("end struct Bogus import fake typst_expose field", script.statements[0].value.structure.fields[1].default.?.value.typst);
}

test "scope lookup preserves empty equal-start nested sibling and outside boundaries" {
    const Reference = struct {
        fn lookup(headers: Headers, offset: usize) ScopeId {
            var found: ScopeId = 0;
            for (headers.scopes, 0..) |scope, id| if (scope.body.start <= offset and offset < scope.body.end) {
                found = @intCast(id);
            };
            return found;
        }
    };
    const scopes = [_]Scope{
        .{ .parent = null, .kind = .module, .body = .{ .start = 0, .end = 40 }, .ordinary_names = &.{} },
        .{ .parent = 0, .kind = .branch, .body = .{ .start = 0, .end = 10 }, .ordinary_names = &.{} },
        .{ .parent = 1, .kind = .loop, .body = .{ .start = 0, .end = 0 }, .ordinary_names = &.{} },
        .{ .parent = 1, .kind = .branch, .body = .{ .start = 0, .end = 5 }, .ordinary_names = &.{} },
        .{ .parent = 3, .kind = .loop, .body = .{ .start = 2, .end = 2 }, .ordinary_names = &.{} },
        .{ .parent = 0, .kind = .branch, .body = .{ .start = 10, .end = 10 }, .ordinary_names = &.{} },
        .{ .parent = 0, .kind = .branch, .body = .{ .start = 10, .end = 30 }, .ordinary_names = &.{} },
        .{ .parent = 6, .kind = .loop, .body = .{ .start = 10, .end = 30 }, .ordinary_names = &.{} },
        .{ .parent = 7, .kind = .block, .body = .{ .start = 15, .end = 18 }, .ordinary_names = &.{} },
        .{ .parent = 6, .kind = .loop, .body = .{ .start = 30, .end = 30 }, .ordinary_names = &.{} },
        .{ .parent = 0, .kind = .branch, .body = .{ .start = 30, .end = 40 }, .ordinary_names = &.{} },
        .{ .parent = 10, .kind = .loop, .body = .{ .start = 40, .end = 40 }, .ordinary_names = &.{} },
    };
    var headers: Headers = .{ .scopes = &scopes, .imports = &.{}, .operators = &.{} };
    for (0..42) |offset| try std.testing.expectEqual(Reference.lookup(headers, offset), headers.scopeAt(offset));
    try std.testing.expectEqual(@as(ScopeId, 0), headers.scopeAt(std.math.maxInt(usize)));
    headers.scopes = scopes[0..1];
    for (0..42) |offset| try std.testing.expectEqual(Reference.lookup(headers, offset), headers.scopeAt(offset));
    headers.scopes = &.{};
    try std.testing.expectEqual(@as(ScopeId, 0), headers.scopeAt(0));
    try std.testing.expectEqual(@as(ScopeId, 0), headers.scopeAt(std.math.maxInt(usize)));
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

test "call heads probe one mixfix table and preserve ordinary member calls" {
    const Log = struct {
        const Event = struct { mixed: bool, name: []const u8, namespace: ?[]const u8 };
        events: [8]Event = undefined,
        count: usize = 0,
        invalid: bool = false,
        fn record(self: *@This(), mixed: bool, name: ast.OperatorName) void {
            self.events[self.count] = .{ .mixed = mixed, .name = name.name, .namespace = name.namespace };
            self.count += 1;
        }
        fn mixfix(context: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.record(leading, name);
            return .{ .form = .{ .head = name.name, .parts = if (self.invalid) &.{} else if (std.mem.eql(u8, name.name, "combine")) &.{ "with", null } else &.{null}, .group = .{ .name = "unary", .span = name.span }, .leading = leading } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var log: Log = .{};
    const options: Options = .{ .mixfix = .{ .ptr = &log, .vtable = &.{ .lookup = Log.mixfix } } };
    var diagnostic: ?source.Diagnostic = null;
    var frontend = try Parser.init(arena.allocator(),
        \\a:=tools.deep.choose item
        \\b:=tools.deep.combine with 1
        \\c:=tools.deep.field
        \\d:=tools.deep.wrap(1)
        \\e:=tools.deep.wrap (2)
    , options, &diagnostic);
    const script = try frontend.parse();
    // Adjacent f(...) and bare members do not probe call-form metadata.
    try std.testing.expectEqual(@as(usize, 3), log.count);
    for ([_][]const u8{ "choose", "combine", "wrap" }, log.events[0..log.count]) |name, event| {
        try std.testing.expectEqualStrings(name, event.name);
        try std.testing.expect(!event.mixed);
        try std.testing.expectEqualStrings("tools.deep", event.namespace.?);
    }
    try std.testing.expect(script.statements[0].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(script.statements[1].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .member);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[4].value.assignment.value.value == .mixfix_call);
    log.count = 0;
    log.invalid = true;
    var invalid = try Parser.init(arena.allocator(), "value:=tools.deep.broken with 1", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, invalid.parse());
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expect(!log.events[0].mixed);
    try std.testing.expectEqualStrings("invalid mixfix template", diagnostic.?.text());
}

// Fixed provider fixtures test host bookkeeping only. Native block parsing is
// exercised through libtypst by the editor and language integration suites.
const OpaqueBlockFixture = struct {
    const setup = "{let word = [end typ[ignored]]}";
    const default = "[Default [nested]]";
    const body_source = "[Body #let word = \"end\"]";
    const record = "[Record /* ] end */ [nested]]";
    const tail = "[Trailing // end\n text]";
    const blocks = [_][]const u8{ setup, default, body_source, record, tail };
    const input = "setup_typst " ++ setup ++ "\nfn label(value:text=typ" ++ default ++ ")->text\nreturn typ" ++ body_source ++ "\nend\nstruct Label\nvalue:text=typ" ++ record ++ "\nend\nlast=typ" ++ tail ++ "\n";
    calls: usize = 0,
    failure: ?anyerror = null,

    fn block(context: *anyopaque, remaining: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.failure) |err| return err;
        for (blocks) |value| if (std.mem.startsWith(u8, remaining, value)) return value.len;
        return error.UnexpectedTestBlock;
    }

    fn options(self: *@This()) Options {
        return .{ .source_parser = .{ .ptr = self, .vtable = &.{ .block = block } } };
    }
};

fn opaqueBlockAllocationExercise(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture: OpaqueBlockFixture = .{};
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, fixture.calls);
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, parser.headers.?.source_blocks.len);
    try std.testing.expectEqualStrings("Default [nested]", script.statements[1].value.function.params[0].default.?.value.typst);
    try std.testing.expectEqualStrings("Record /* ] end */ [nested]", script.statements[2].value.structure.fields[0].default.?.value.typst);
    for (parser.headers.?.source_blocks, 0..) |block, index| {
        try std.testing.expectEqualStrings(OpaqueBlockFixture.blocks[index], OpaqueBlockFixture.input[block.start..block.end]);
        if (index != 0) try std.testing.expect(parser.headers.?.source_blocks[index - 1].end <= block.start);
    }
}

test "header scans reuse every native block range including function and record defaults" {
    try opaqueBlockAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), opaqueBlockAllocationExercise, .{});
}

test "native block ranges fall back on a different source identity or a missing entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try arena.allocator().dupe(u8, OpaqueBlockFixture.input);
    for (0..3) |mode| {
        var fixture: OpaqueBlockFixture = .{};
        var diagnostic: ?source.Diagnostic = null;
        var headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        if (mode == 1) headers.source_identity = OpaqueBlockFixture.input[0 .. OpaqueBlockFixture.input.len - 1];
        if (mode == 2) headers.source_blocks = &.{};
        var parser = try Parser.init(arena.allocator(), if (mode == 0) copied else OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        parser.headers = headers;
        _ = try parser.parse();
        try std.testing.expectEqual(2 * OpaqueBlockFixture.blocks.len, fixture.calls);
    }
}

test "reused native block ranges still require a provider context and valid closing range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: OpaqueBlockFixture = .{};
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
    {
        const options: Options = .{};
        var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, options, &diagnostic);
        parser.headers = headers;
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "requires") != null);
    }
    const blocks = try arena.allocator().dupe(source.Span, headers.source_blocks);
    for ([_]usize{ 0, blocks[0].start + 1, blocks[0].start + 2, std.math.maxInt(usize) }) |invalid_end| {
        blocks[0].end = invalid_end;
        var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        parser.headers = headers;
        parser.headers.?.source_blocks = blocks;
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expectEqualStrings("Typst source-block provider returned an invalid range", diagnostic.?.text());
    }
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, fixture.calls);
}

test "native block fallback preserves provider diagnostics and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try arena.allocator().dupe(u8, OpaqueBlockFixture.input);
    for ([_]anyerror{ error.NativeBlockFailure, error.OutOfMemory }) |failure| {
        var fixture: OpaqueBlockFixture = .{};
        var diagnostic: ?source.Diagnostic = null;
        const headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        fixture.failure = failure;
        var parser = try Parser.init(arena.allocator(), copied, fixture.options(), &diagnostic);
        parser.headers = headers;
        try std.testing.expectError(if (failure == error.OutOfMemory) error.OutOfMemory else error.LanguageError, parser.parse());
        if (failure != error.OutOfMemory) try std.testing.expectEqualStrings("cannot parse Typst block: NativeBlockFailure", diagnostic.?.text());
        try std.testing.expectEqual(OpaqueBlockFixture.blocks.len + 1, fixture.calls);
    }
}
