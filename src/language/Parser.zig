//! Keyword/end parser with native Typst content and code blocks.
const std = @import("std");
const Lexer = @import("Lexer.zig");
const ast = @import("ast.zig");
const source = @import("source.zig");
const statements = @import("parser/statements.zig");
const HeaderScanner = @import("parser/HeaderScanner.zig");

/// Native embedded-language parsing is supplied by the caller.
pub const SourceParser = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Borrow a host that implements sourceBlock(input) and
    /// sourceMemberUses(allocator, code, syntax, name). The host must outlive
    /// parsing.
    pub fn init(provider: anytype) SourceParser {
        const Adapter = struct {
            fn parse(context: *anyopaque, input: []const u8) anyerror!usize {
                const host: @TypeOf(provider) = @ptrCast(@alignCast(context));
                return host.sourceBlock(input);
            }
            fn uses(context: *anyopaque, allocator: std.mem.Allocator, code: []const u8, name: []const u8) anyerror!MemberUses {
                const host: @TypeOf(provider) = @ptrCast(@alignCast(context));
                const found = try host.sourceMemberUses(allocator, code, .code, name);
                const copied = try allocator.alloc(MemberUse, found.uses.len);
                for (copied, found.uses) |*use, native| use.* = .{ .member = native.member, .start = native.start, .end = native.end };
                allocator.free(found.uses);
                return .{ .uses = copied, .rebound = found.rebound, .whole = found.whole };
            }
        };
        return .{ .ptr = provider, .vtable = &.{ .block = Adapter.parse, .uses = Adapter.uses } };
    }

    pub inline fn block(self: SourceParser, input: []const u8) anyerror!usize {
        return self.vtable.block(self.ptr, input);
    }

    /// Where Typst code, given as a code-mode block, reads members of `name`;
    /// none when the provider does not report them. Results live in `allocator`.
    pub fn memberUses(self: SourceParser, allocator: std.mem.Allocator, code: []const u8, name: []const u8) anyerror!MemberUses {
        const query = self.vtable.uses orelse return .{ .uses = &.{}, .rebound = false, .whole = false };
        return query(self.ptr, allocator, code, name);
    }

    /// `start` and `end` are byte offsets into the queried code.
    pub const MemberUse = struct { member: []const u8, start: usize, end: usize };
    /// `rebound`: the code binds the name itself. `whole`: it also uses the
    /// name as a whole value rather than through a member.
    pub const MemberUses = struct { uses: []const MemberUse, rebound: bool, whole: bool };

    pub const VTable = struct {
        block: *const fn (*anyopaque, []const u8) anyerror!usize,
        uses: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!MemberUses = null,
    };
};

/// A stand-in for the native source parser in unit tests: a block runs to
/// its matching bracket, `huak.name` is found by text, `#let huak` marks a
/// rebinding and any other `huak` is a whole-value use. Native parsing is
/// covered by the integration suites.
pub const TestSourceParser = struct {
    var marker: u8 = 0;
    pub const parser: SourceParser = .{ .ptr = &marker, .vtable = &.{ .block = block, .uses = uses } };

    pub fn block(_: *anyopaque, input: []const u8) !usize {
        if (input.len == 0 or input[0] != '[') return error.UnexpectedTestBlock;
        var depth: usize = 0;
        for (input, 0..) |byte, index| switch (byte) {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return index + 1;
            },
            else => {},
        };
        return error.UnexpectedTestBlock;
    }
    pub fn word(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }
    pub fn uses(_: *anyopaque, allocator: std.mem.Allocator, code: []const u8, name: []const u8) !SourceParser.MemberUses {
        var found: std.ArrayList(SourceParser.MemberUse) = .empty;
        errdefer found.deinit(allocator);
        var from: usize = 0;
        var whole = false;
        const binding = "#let ";
        while (std.mem.findPos(u8, code, from, name)) |at| {
            from = at + name.len;
            if ((at > 0 and word(code[at - 1])) or (from < code.len and word(code[from]))) continue;
            var end = from + 1;
            while (end < code.len and word(code[end])) end += 1;
            if (from < code.len and code[from] == '.' and end > from + 1) {
                try found.append(allocator, .{ .member = code[from + 1 .. end], .start = from + 1, .end = end });
            } else if (!std.mem.endsWith(u8, code[0..at], binding)) whole = true;
        }
        return .{ .uses = try found.toOwnedSlice(allocator), .rebound = std.mem.find(u8, code, "#let huak") != null, .whole = whole };
    }
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
    /// An omitted provider or a failed host initialization matters only at an embedded block.
    source_parser: anyerror!?SourceParser = null,
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
    /// typ.show statements, in source order.
    typst_declarations: []const ScopedHeader = &.{},
    records: []const ScopedHeader = &.{},
    expansions: []const ScopedHeader = &.{},
    /// Native-validated block ranges borrow this exact immutable source.
    /// They are reusable only while its address and length remain unchanged.
    source_identity: ?[]const u8 = null,
    source_blocks: []const source.Span = &.{},

    pub fn sourceBlockLength(self: *const Headers, input: []const u8, beginning: usize) ?usize {
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
    const body_ = try statements.body(self);
    if (self.current.kind != .eof) return self.fail(self.current.span, "unexpected block delimiter", .{});
    return .{ .statements = body_ };
}

/// The name under which Typst code reads Huak values.
pub const typst_namespace = "huak";

pub fn controlDelimiter(self: *Parser, kind: Lexer.Kind, message: []const u8) !void {
    while (self.current.kind == .newline) try self.advance();
    _ = try self.expect(kind, message);
}
pub fn separators(self: *Parser) !void {
    while (self.current.kind == .newline or self.current.kind == .semicolon) try self.advance();
}
pub fn advance(self: *Parser) !void {
    self.current = try self.lexer.next();
}
pub fn peek(self: *const Parser) !Lexer.Token {
    var lexer = self.lexer;
    return lexer.next();
}
pub fn accept(self: *Parser, kind: Lexer.Kind) !bool {
    if (self.current.kind != kind) return false;
    try self.advance();
    return true;
}
pub noinline fn expect(self: *Parser, kind: Lexer.Kind, message: []const u8) !Lexer.Token {
    if (self.current.kind != kind) return self.fail(self.current.span, "{s}", .{message});
    const token = self.current;
    try self.advance();
    return token;
}
pub fn text(self: *const Parser, token: Lexer.Token) []const u8 {
    return self.lexer.source[token.span.start..token.span.end];
}
pub fn fail(self: *Parser, span: source.Span, comptime format: []const u8, args: anytype) error{LanguageError} {
    _ = source.Diagnostic.set(self.diagnostic, span, format, args);
    return error.LanguageError;
}
pub fn createStmt(self: *Parser, span: source.Span, value: @FieldType(ast.Stmt, "value")) !*ast.Stmt {
    const result = try self.allocator.create(ast.Stmt);
    result.* = .{ .span = span, .value = value };
    return result;
}
pub fn createExpr(self: *Parser, span: source.Span, value: @FieldType(ast.Expr, "value")) !*ast.Expr {
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

test {
    _ = @import("parser/imports.zig");
    _ = @import("parser/calls.zig");
    _ = @import("parser/expressions_test.zig");
    _ = @import("parser/statements_test.zig");
    _ = @import("parser/declarations_test.zig");
    _ = @import("parser/operators_test.zig");
    _ = @import("parser/mixfix_lookup_test.zig");
    _ = @import("parser/typst_test.zig");
    _ = @import("parser/headers_test.zig");
    _ = @import("parser/source_blocks_test.zig");
}
