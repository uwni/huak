//! Lexer for huak syntax only. Embedded Typst is skipped by the parser.
const std = @import("std");
const source_info = @import("source.zig");
pub const Kind = enum {
    eof,
    newline,
    identifier,
    integer,
    float,
    string,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    colon,
    dot,
    ellipsis,
    straight_join,
    smooth_join,
    semicolon,
    plus,
    plus_assign,
    minus,
    star,
    slash,
    percent,
    caret,
    ampersand,
    assign,
    declare,
    arrow,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    kw_fn,
    kw_block,
    kw_expand_block,
    kw_struct,
    kw_end,
    kw_param,
    kw_if,
    kw_then,
    kw_elseif,
    kw_else,
    kw_while,
    kw_for,
    kw_do,
    kw_in,
    kw_break,
    kw_continue,
    kw_return,
    kw_export,
    kw_default,
    kw_import,
    kw_as,
    kw_precedence,
    kw_mixfix,
    kw_and,
    kw_or,
    kw_not,
    kw_true,
    kw_false,
    kw_setup_typst,
    kw_typst_expose,
    kw_typ,
    kw_cycle,
};
pub const Token = struct { kind: Kind, span: source_info.Span };

pub fn isOperator(kind: Kind) bool {
    return switch (kind) {
        .plus, .minus, .star, .slash, .percent, .caret, .ampersand, .arrow, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .straight_join, .smooth_join => true,
        else => false,
    };
}
const Lexer = @This();

source: []const u8,
pos: usize = 0,
nesting: usize = 0,
/// Statement bodies inside expressions establish their own newline boundary.
newline_nesting: usize = 0,
diagnostic: *?source_info.Diagnostic,

pub fn next(self: *Lexer) error{LanguageError}!Token {
    while (self.pos < self.source.len) {
        const start = self.pos;
        const ch = self.source[self.pos];
        self.pos += 1;
        switch (ch) {
            ' ', '\t', '\r' => continue,
            '\n' => if (self.nesting == self.newline_nesting) return self.token(.newline, start) else continue,
            '#' => {
                self.skipComment();
                continue;
            },
            '/' => {
                if (self.take('/')) {
                    self.skipComment();
                    continue;
                }
                return self.token(.slash, start);
            },
            '(' => {
                self.nesting += 1;
                return self.token(.lparen, start);
            },
            '[' => {
                self.nesting += 1;
                return self.token(.lbracket, start);
            },
            '{' => {
                self.nesting += 1;
                return self.token(.lbrace, start);
            },
            ')' => {
                self.nesting -|= 1;
                return self.token(.rparen, start);
            },
            ']' => {
                self.nesting -|= 1;
                return self.token(.rbracket, start);
            },
            '}' => {
                self.nesting -|= 1;
                return self.token(.rbrace, start);
            },
            ',' => return self.token(.comma, start),
            ':' => return self.token(if (self.take('=')) .declare else .colon, start),
            '.' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and self.source[self.pos + 1] == '.') {
                    self.pos += 2;
                    return self.token(.ellipsis, start);
                }
                return self.token(.dot, start);
            },
            '~' => {
                if (self.take('~')) return self.token(.smooth_join, start);
                return self.fail(start, "expected '~~' for a smooth path connection");
            },
            ';' => return self.token(.semicolon, start),
            '+' => return self.token(if (self.take('=')) .plus_assign else .plus, start),
            '-' => return self.token(if (self.take('>')) .arrow else if (self.take('-')) .straight_join else .minus, start),
            '&' => return self.token(.ampersand, start),
            '*' => return self.token(.star, start),
            '%' => return self.token(.percent, start),
            '^' => return self.token(.caret, start),
            '=' => return self.token(if (self.take('=')) .equal else .assign, start),
            '<' => return self.token(if (self.take('=')) .less_equal else .less, start),
            '>' => return self.token(if (self.take('=')) .greater_equal else .greater, start),
            '!' => {
                if (self.take('=')) return self.token(.not_equal, start);
                return self.fail(start, "expected '=' after '!'");
            },
            '"' => {
                while (self.pos < self.source.len) {
                    const byte = self.source[self.pos];
                    self.pos += 1;
                    if (byte == '"') return self.token(.string, start);
                    if (byte == '\n' or byte == '\r') return self.fail(start, "newline in string literal");
                    if (byte == '\\') {
                        if (self.pos == self.source.len) break;
                        self.pos += 1;
                    }
                }
                return self.fail(start, "unterminated string literal");
            },
            '0'...'9' => {
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
                var kind: Kind = .integer;
                if (self.pos + 1 < self.source.len and self.source[self.pos] == '.' and std.ascii.isDigit(self.source[self.pos + 1])) {
                    kind = .float;
                    self.pos += 1;
                    while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
                }
                if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
                    kind = .float;
                    self.pos += 1;
                    if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) self.pos += 1;
                    const exponent = self.pos;
                    while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
                    if (self.pos == exponent) return self.fail(start, "missing exponent digits");
                }
                return self.token(kind, start);
            },
            'a'...'z', 'A'...'Z', '_' => {
                while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
                const word = self.source[start..self.pos];
                const keywords = std.StaticStringMap(Kind).initComptime(.{
                    .{ "fn", .kw_fn },                     .{ "block", .kw_block },             .{ "end", .kw_end },               .{ "param", .kw_param },   .{ "if", .kw_if },
                    .{ "expand_block", .kw_expand_block }, .{ "elseif", .kw_elseif },           .{ "else", .kw_else },             .{ "while", .kw_while },   .{ "for", .kw_for },
                    .{ "then", .kw_then },                 .{ "do", .kw_do },                   .{ "in", .kw_in },                 .{ "break", .kw_break },   .{ "continue", .kw_continue },
                    .{ "return", .kw_return },             .{ "and", .kw_and },                 .{ "or", .kw_or },                 .{ "not", .kw_not },       .{ "true", .kw_true },
                    .{ "false", .kw_false },               .{ "setup_typst", .kw_setup_typst }, .{ "typ", .kw_typ },               .{ "export", .kw_export }, .{ "default", .kw_default },
                    .{ "import", .kw_import },             .{ "as", .kw_as },                   .{ "precedence", .kw_precedence }, .{ "cycle", .kw_cycle },   .{ "mixfix", .kw_mixfix },
                    .{ "typst_expose", .kw_typst_expose }, .{ "struct", .kw_struct },
                });
                return self.token(keywords.get(word) orelse .identifier, start);
            },
            else => return self.fail(start, "unexpected character"),
        }
    }
    return .{ .kind = .eof, .span = .{ .start = self.pos, .end = self.pos } };
}

fn take(self: *Lexer, byte: u8) bool {
    if (self.pos < self.source.len and self.source[self.pos] == byte) {
        self.pos += 1;
        return true;
    }
    return false;
}
fn token(self: *const Lexer, kind: Kind, start: usize) Token {
    return .{ .kind = kind, .span = .{ .start = start, .end = self.pos } };
}
fn skipComment(self: *Lexer) void {
    while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
}
fn fail(self: *Lexer, start: usize, comptime message: []const u8) error{LanguageError} {
    self.diagnostic.* = source_info.Diagnostic.init(.{ .start = start, .end = self.pos }, message, .{});
    return error.LanguageError;
}

test "separators and comments do not depend on indentation" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "a:=(1,\n2);#x\n// y\nb:=3", .diagnostic = &diagnostic };
    const expected = [_]Kind{ .identifier, .declare, .lparen, .integer, .comma, .integer, .rparen, .semicolon, .newline, .newline, .identifier, .declare, .integer, .eof };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
}

test "typ is the content keyword while typst remains an identifier" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "typ typst setup_typst typology", .diagnostic = &diagnostic };
    for ([_]Kind{ .kw_typ, .identifier, .kw_setup_typst, .identifier, .eof }) |kind| {
        try std.testing.expectEqual(kind, (try lexer.next()).kind);
    }
}

test "struct is reserved without splitting longer identifiers" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "struct structure struct_name end", .diagnostic = &diagnostic };
    for ([_]Kind{ .kw_struct, .identifier, .identifier, .kw_end, .eof }) |kind| {
        try std.testing.expectEqual(kind, (try lexer.next()).kind);
    }
}

test "control body delimiters are reserved without splitting identifiers" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "then do then_value doing", .diagnostic = &diagnostic };
    for ([_]Kind{ .kw_then, .kw_do, .identifier, .identifier, .eof }) |kind| {
        try std.testing.expectEqual(kind, (try lexer.next()).kind);
    }
}

test "import selector braces suppress only their internal newlines" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "import paint.{\nfoo as first,\nbar,\n}\nnext:=1", .diagnostic = &diagnostic };
    const expected = [_]Kind{
        .kw_import,  .identifier, .dot,        .lbrace,
        .identifier, .kw_as,      .identifier, .comma,
        .identifier, .comma,      .rbrace,     .newline,
        .identifier, .declare,    .integer,    .eof,
    };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
}

test "ellipsis uses longest match and preserves dots decimals and path joins" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = ". .. ... .... 1... 1.25... point.x a--b a~~b", .diagnostic = &diagnostic };
    const expected = [_]Kind{
        .dot,        .dot,        .dot,           .ellipsis,   .ellipsis,   .dot,
        .integer,    .ellipsis,   .float,         .ellipsis,   .identifier, .dot,
        .identifier, .identifier, .straight_join, .identifier, .identifier, .smooth_join,
        .identifier, .eof,
    };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
}

test "list append assignment uses longest match without changing plus or assignment" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "a+=b+a + =c", .diagnostic = &diagnostic };
    for ([_]Kind{ .identifier, .plus_assign, .identifier, .plus, .identifier, .plus, .assign, .identifier, .eof }) |kind| {
        try std.testing.expectEqual(kind, (try lexer.next()).kind);
    }
}

test "a smooth path connection requires a complete double tilde token" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "~", .diagnostic = &diagnostic };
    try std.testing.expectError(error.LanguageError, lexer.next());
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "~~") != null);
    diagnostic = null;
    lexer = .{ .source = "~~~", .diagnostic = &diagnostic };
    try std.testing.expectEqual(Kind.smooth_join, (try lexer.next()).kind);
    try std.testing.expectError(error.LanguageError, lexer.next());
}

test "path joins use longest match without changing arithmetic decimals or members" {
    var diagnostic: ?source_info.Diagnostic = null;
    var lexer: Lexer = .{ .source = "a--b a- -b a~~b 1~~2 1.25~~2e-3 p.x fn f()->path cycle", .diagnostic = &diagnostic };
    const expected = [_]Kind{
        .identifier, .straight_join, .identifier,
        .identifier, .minus,         .minus,
        .identifier, .identifier,    .smooth_join,
        .identifier, .integer,       .smooth_join,
        .integer,    .float,         .smooth_join,
        .float,      .identifier,    .dot,
        .identifier, .kw_fn,         .identifier,
        .lparen,     .rparen,        .arrow,
        .identifier, .kw_cycle,      .eof,
    };
    for (expected) |kind| try std.testing.expectEqual(kind, (try lexer.next()).kind);
}

test "domain keywords leave ordinary template words available as identifiers" {
    var diagnostic: ?source_info.Diagnostic = null;
    var scanner: Lexer = .{ .source = "typst_expose expose using to typst_exposure mixfix prefix infix with", .diagnostic = &diagnostic };
    for ([_]Kind{ .kw_typst_expose, .identifier, .identifier, .identifier, .identifier, .kw_mixfix, .identifier, .identifier, .identifier, .eof }) |kind|
        try std.testing.expectEqual(kind, (try scanner.next()).kind);
}
