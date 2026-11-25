const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const statements = @import("statements.zig");
const typst = @import("typst.zig");
const declarations = @import("declarations.zig");
const HeaderScanner = @This();
const Scope = Parser.Scope;
const Local = Parser.Local;
const ScopeId = Parser.ScopeId;
const ScopedHeader = Parser.ScopedHeader;
const Options = Parser.Options;
const Headers = Parser.Headers;

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
typst_declarations: std.ArrayList(ScopedHeader) = .empty,
records: std.ArrayList(ScopedHeader) = .empty,
expansions: std.ArrayList(ScopedHeader) = .empty,
source_blocks: std.ArrayList(source.Span) = .empty,
active: ScopeId = 0,
statement_start: bool = true,

pub fn init(allocator: std.mem.Allocator, input: []const u8, options: Options, diagnostic: *?source.Diagnostic) !HeaderScanner {
    var scanner: HeaderScanner = .{ .allocator = allocator, .parser = try Parser.init(allocator, input, options, diagnostic) };
    try scanner.scopes.append(allocator, .{ .value = .{ .parent = null, .kind = .module, .body = .{ .start = 0, .end = input.len }, .ordinary_names = &.{} } });
    return scanner;
}

pub fn scan(self: *HeaderScanner) !Headers {
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
    return .{ .scopes = scopes, .imports = try self.imports.toOwnedSlice(self.allocator), .operators = try self.operators.toOwnedSlice(self.allocator), .typst_declarations = try self.typst_declarations.toOwnedSlice(self.allocator), .records = try self.records.toOwnedSlice(self.allocator), .expansions = try self.expansions.toOwnedSlice(self.allocator), .source_identity = self.parser.lexer.source, .source_blocks = try self.source_blocks.toOwnedSlice(self.allocator) };
}

fn scanToken(self: *HeaderScanner) anyerror!void {
    const token = self.parser.current;
    switch (token.kind) {
        // typ.show is a lexical declaration; typ[…] and typ.module[…] are
        // Typst blocks, and an annotation's typ.module names a type.
        .kw_typ => {
            if (self.parser.lexer.startsMember("show")) {
                try self.typst_declarations.append(self.allocator, .{ .scope = self.active, .statement = try statements.statement(&self.parser) });
            } else if (try typst.acceptTypMember(&self.parser, "module") == null or self.parser.lexer.startsBlock('[')) {
                _ = try typst.typstBlock(&self.parser, '[');
            } else try self.parser.advance();
            self.statement_start = false;
            return;
        },
        .kw_import => {
            try self.imports.append(self.allocator, .{ .scope = self.active, .statement = try statements.statement(&self.parser) });
            self.statement_start = false;
            return;
        },
        .kw_mixfix => {
            const declaration = try statements.statement(&self.parser);
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
            _ = try statements.statement(&self.parser);
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
            const header = try declarations.functionHeader(&self.parser, self);
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
pub fn defaultExpression(self: *HeaderScanner) !*ast.Expr {
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
    if (self.frames.items.len >= ast.max_depth) return self.parser.fail(self.parser.current.span, "block nesting exceeds {d}", .{ast.max_depth});
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
