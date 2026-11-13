//! Token-based source formatting. Native Typst, strings and comments keep their
//! original bytes; only Huak whitespace is normalized by the ordinary lexer.
const std = @import("std");
const Lexer = @import("../language/Lexer.zig");
const source = @import("../language/source.zig");
const Frontend = @import("Frontend.zig");
const Token = struct { span: source.Span, kind: ?Lexer.Kind, value_colon: bool = false };
pub const Options = struct { tab_size: usize = 4, insert_spaces: bool = true };

pub fn format(frontend: *const Frontend, input: []const u8, path: []const u8, diagnostic: *?source.Diagnostic) ![]u8 {
    return formatWithOptions(frontend, input, path, diagnostic, .{});
}

pub fn formatWithOptions(frontend: *const Frontend, input: []const u8, path: []const u8, diagnostic: *?source.Diagnostic, options: Options) ![]u8 {
    if (options.tab_size == 0 or options.tab_size > 16) return error.InvalidIndentation;
    var arena = std.heap.ArenaAllocator.init(frontend.allocator);
    defer arena.deinit();
    const graph = try frontend.graph(arena.allocator(), input, path, diagnostic);
    try @import("../language/compiler.zig").checkGraph(frontend.allocator, &graph);
    const unit = graph.units.items[0];
    return formatSource(frontend.allocator, unit.source_text, unit.headers.source_blocks, diagnostic, options);
}

fn formatSource(allocator: std.mem.Allocator, input: []const u8, source_blocks: []const source.Span, diagnostic: *?source.Diagnostic, options: Options) ![]u8 {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    var scanner: Lexer = .{ .source = input, .diagnostic = diagnostic };
    var blocks = source_blocks;
    while (true) {
        const token = try scanner.next();
        if (token.kind == .eof) break;
        if (token.kind == .newline) continue;
        if (blocks.len > 0 and token.span.start == blocks[0].start) {
            try tokens.append(allocator, .{ .span = blocks[0], .kind = null });
            scanner.pos = blocks[0].end;
            blocks = blocks[1..];
        } else try tokens.append(allocator, .{ .span = token.span, .kind = token.kind });
    }
    try markValueColons(allocator, tokens.items);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    // Most output bytes come from the input. Reserving them once avoids the
    // repeated full-buffer reallocations of a growing ArrayList.
    try output.ensureTotalCapacity(allocator, input.len);
    var indentation: Indentation = .{};
    defer indentation.delimiters.deinit(allocator);
    var beginning: usize = 0;
    var token_index: usize = 0;
    while (beginning < input.len) {
        const newline = std.mem.indexOfScalarPos(u8, input, beginning, '\n') orelse input.len;
        const end = if (newline > beginning and input[newline - 1] == '\r' and newline < input.len) newline - 1 else newline;
        while (token_index < tokens.items.len and tokens.items[token_index].span.end <= beginning) token_index += 1;
        var stop = token_index;
        while (stop < tokens.items.len and tokens.items[stop].span.start < end) stop += 1;
        const line_tokens = tokens.items[token_index..stop];
        const protected = line_tokens.len != 0 and line_tokens[0].span.start < beginning;
        const depth = indentation.lineDepth(line_tokens);
        var start = beginning;
        if (!protected) while (start < end and horizontal(input[start])) {
            start += 1;
        };
        if (start < end) {
            if (!protected) try output.appendNTimes(allocator, if (options.insert_spaces) ' ' else '\t', depth * if (options.insert_spaces) options.tab_size else @as(usize, 1));
            try line(&output, allocator, input, start, end, line_tokens);
        }
        // Preserve each existing line ending, including endings inside native
        // content. A final missing newline is added outside the complete input.
        if (newline < input.len) try output.appendSlice(allocator, input[end .. newline + 1]) else try output.append(allocator, '\n');
        try indentation.advance(allocator, line_tokens, depth, beginning);
        beginning = if (newline < input.len) newline + 1 else newline;
    }
    return output.toOwnedSlice(allocator);
}

fn horizontal(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r';
}

fn spaced(kind: ?Lexer.Kind) bool {
    return switch (kind orelse return false) {
        .assign, .declare, .plus_assign, .fat_arrow, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
        else => false,
    };
}

fn line(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8, start: usize, end: usize, tokens: []const Token) !void {
    var cursor = start;
    var previous: ?Lexer.Kind = null;
    var after_value_colon = false;
    for (tokens) |token| {
        if (token.span.end <= start) continue;
        const token_start = @max(start, token.span.start);
        if (token_start > cursor or (cursor != start and token_start == cursor))
            try gap(output, allocator, input[cursor..token_start], previous, token.kind, false, after_value_colon);
        const finish = @min(end, token.span.end);
        try output.appendSlice(allocator, input[token_start..finish]);
        cursor = finish;
        previous = token.kind;
        after_value_colon = token.value_colon;
    }
    if (cursor < end) try gap(output, allocator, input[cursor..end], previous, null, true, after_value_colon);
}

/// Colons in dictionary entries and ordinary calls introduce values. Type
/// annotations and range/slice colons retain their compact spelling. Native
/// Typst is one opaque token and cannot affect this delimiter stack.
fn markValueColons(allocator: std.mem.Allocator, tokens: []Token) !void {
    var calls: std.ArrayList(bool) = .empty;
    defer calls.deinit(allocator);
    for (tokens, 0..) |*token, index| {
        switch (token.kind orelse continue) {
            .lparen => {
                const callable = index != 0 and tokens[index - 1].kind == .identifier and
                    !(index >= 2 and (tokens[index - 2].kind == .kw_fn or tokens[index - 2].kind == .kw_expand_block));
                try calls.append(allocator, callable);
            },
            .lbracket, .lbrace => try calls.append(allocator, false),
            .rparen, .rbracket, .rbrace => _ = calls.pop(),
            .colon => token.value_colon = (index != 0 and tokens[index - 1].kind == .string) or
                (calls.items.len != 0 and calls.items[calls.items.len - 1]),
            else => {},
        }
    }
}

/// A lexer gap on one physical line is horizontal whitespace followed, at
/// most, by an opaque line comment. Never rewrite the comment's own bytes.
fn gap(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8, left: ?Lexer.Kind, right: ?Lexer.Kind, trailing: bool, after_value_colon: bool) !void {
    var whitespace: usize = 0;
    while (whitespace < input.len and horizontal(input[whitespace])) whitespace += 1;
    const comment = whitespace < input.len;
    if (right == .comma or right == .colon or (left == .comma and Indentation.closes(right))) return;
    if ((after_value_colon or left == .comma or spaced(left) or spaced(right)) and (!trailing or comment)) {
        try output.append(allocator, ' ');
        if (comment) try output.appendSlice(allocator, input[whitespace..]);
    } else if (trailing and !comment) {
        // Horizontal trivia after code is neither a comment nor native text.
    } else try output.appendSlice(allocator, input);
}

const Indentation = struct {
    blocks: usize = 0,
    // Anchor to the opening line rather than counting delimiters. A function
    // header already opens a block, but its argument list needs only one indent.
    delimiters: std.ArrayList(usize) = .empty,
    continuation: ?usize = null,

    fn lineDepth(self: *const Indentation, tokens: []const Token) usize {
        if (tokens.len != 0) {
            var closing: usize = 0;
            for (tokens) |token| {
                if (!closes(token.kind)) break;
                closing += 1;
            }
            if (closing != 0 and closing <= self.delimiters.items.len)
                return self.delimiters.items[self.delimiters.items.len - closing];
            if (tokens[0].kind) |kind| switch (kind) {
                .kw_end, .kw_else, .kw_elseif, .kw_then => return self.blocks -| 1,
                else => {},
            };
        }
        if (self.delimiters.items.len != 0) return self.delimiters.items[self.delimiters.items.len - 1] + 1;
        return self.continuation orelse self.blocks;
    }

    fn advance(self: *Indentation, allocator: std.mem.Allocator, tokens: []const Token, depth: usize, beginning: usize) !void {
        var last: ?Token = null;
        var previous: ?Lexer.Kind = null;
        for (tokens) |token| {
            // A native region may span many physical lines; it has no Huak
            // delimiters or keywords and must not reopen any indentation scope.
            if (token.span.start < beginning) continue;
            previous = if (last) |item| item.kind else null;
            last = token;
            const kind = token.kind orelse continue;
            switch (kind) {
                .kw_fn, .kw_expand_block, .kw_block, .kw_struct, .kw_if, .kw_do, .kw_precedence => self.blocks += 1,
                .kw_end => self.blocks -|= 1,
                .lparen, .lbracket, .lbrace => try self.delimiters.append(allocator, depth),
                .rparen, .rbracket, .rbrace => _ = self.delimiters.pop(),
                else => {},
            }
        }
        if (last) |token| self.continuation = if (continues(token.kind, previous)) self.continuation orelse depth + 1 else null;
    }

    fn closes(kind: ?Lexer.Kind) bool {
        return switch (kind orelse return false) {
            .rparen, .rbracket, .rbrace => true,
            else => false,
        };
    }

    fn continues(kind: ?Lexer.Kind, previous: ?Lexer.Kind) bool {
        // In the validated grammar, star after dot ends a wildcard import;
        // unlike multiplication it does not require a following operand.
        if (kind == .star and previous == .dot) return false;
        return switch (kind orelse return false) {
            .assign, .declare, .plus_assign, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .plus, .minus, .star, .slash, .percent, .caret, .ampersand, .straight_join, .smooth_join, .kw_and, .kw_or, .comma => true,
            else => false,
        };
    }
};

fn expectFormat(input: []const u8, expected: []const u8, options: Options) !void {
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var diagnostic: ?source.Diagnostic = null;
    const result = try formatWithOptions(&frontend, input, "/tmp/format.huak", &diagnostic, options);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
    const again = try formatWithOptions(&frontend, result, "/tmp/format.huak", &diagnostic, options);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(result, again);
}

test "formatter normalizes assignment comparisons and comma gaps without changing expressions" {
    try expectFormat("param count:int=2\nfn f(a:int,b:int=3)->list\n xs := [a ,b]\nxs+=1\nif a>=b then return xs end\nreturn [1,2] // x = y,z   \nend\nx:=f(count,3)\n", "param count:int = 2\nfn f(a:int, b:int = 3)->list\n    xs := [a, b]\n    xs += 1\n    if a >= b then return xs end\n    return [1, 2] // x = y,z   \nend\nx := f(count, 3)\n", .{});
    try expectFormat("import math.PI as pi\ns:=\"a=b,c\"\nx:=-1\ny:=2*pi\na:=x!=y\nb:=x<y\nc:=x<=y\nd:=x>y\ne:=x==y", "import math.PI as pi\ns := \"a=b,c\"\nx := -1\ny := 2*pi\na := x != y\nb := x < y\nc := x <= y\nd := x > y\ne := x == y\n", .{});
}

test "formatter retains semantic validation without executing the checked script" {
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var diagnostic: ?source.Diagnostic = null;
    try std.testing.expectError(error.LanguageError, format(&frontend, "value:int:=\"wrong\"", "/tmp/invalid-format.huak", &diagnostic));
    const formatted = try format(&frontend, "panic(\"formatting must not execute\")", "/tmp/checked-format.huak", &diagnostic);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("panic(\"formatting must not execute\")\n", formatted);
}

test "formatter anchors nested delimiter continuation and closes to the opening line" {
    const input = "fn f(\na:int,\nb:int=2\n)->list\nxs:=[\na,\n[\nb,3\n]\n]\nreturn xs\nend\ny:=f(\n1,\n2\n)\n";
    const expected = "fn f(\n  a:int,\n  b:int = 2\n)->list\n  xs := [\n    a,\n    [\n      b, 3\n    ]\n  ]\n  return xs\nend\ny := f(\n  1,\n  2\n)\n";
    try expectFormat(input, expected, .{ .tab_size = 2 });
    try expectFormat("x:=[\n[\n1,2\n]\n]\n", "x := [\n\t[\n\t\t1, 2\n\t]\n]\n", .{ .insert_spaces = false });
}

test "formatter preserves prefix adjacency units unary signs and statement separators" {
    try expectFormat("import math.PI as pi\nfn wrap(x:int)->int return 2*x end\nmixfix(wrap) wrap _ in addition\na:=wrap (2)+3\nb:=wrap(2)+3\npoints:=(1cm,2mm)--(-2cm,+4mm); turn:=2 pi rad\n", "import math.PI as pi\nfn wrap(x:int)->int return 2*x end\nmixfix(wrap) wrap _ in addition\na := wrap (2)+3\nb := wrap(2)+3\npoints := (1cm, 2mm)--(-2cm, +4mm); turn := 2 pi rad\n", .{});
}

test "formatter leaves the distinct execution results of spaced prefixes and adjacent calls intact" {
    const input = "fn wrap(x:int)->int return 2*x end\nmixfix(wrap) wrap _ in addition\na:=wrap (2)+3\nb:=wrap(2)+3\n";
    const frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var diagnostic: ?source.Diagnostic = null;
    const result = try format(&frontend, input, "/tmp/format.huak", &diagnostic);
    defer std.testing.allocator.free(result);
    var before: [2]i64 = undefined;
    for ([_][]const u8{ input, result }, 0..) |text, pass| {
        var program = try frontend.compile(text, "/tmp/format.huak", &diagnostic);
        defer program.deinit();
        var machine = try @import("../language/Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const values: [2]i64 = .{ machine.getGlobal("a").?.int, machine.getGlobal("b").?.int };
        if (pass == 0) before = values else try std.testing.expectEqualDeep(before, values);
        try std.testing.expect(values[0] != values[1]);
    }
}

test "formatter indents branches and explicit header delimiters without changing line boundaries" {
    try expectFormat("fn f(x:int)->int\nif x>0\nthen\nreturn x\nelseif x<0 then\nreturn -x\nelse\nreturn 0\nend\nend\n", "fn f(x:int)->int\n    if x > 0\n    then\n        return x\n    elseif x < 0 then\n        return -x\n    else\n        return 0\n    end\nend\n", .{});
    try expectFormat("x:=(1,2)\n\n# a=b,c  \n", "x := (1, 2)\n\n# a=b,c  \n", .{});
}

test "formatter preserves CRLF endings and comments between multiline arguments" {
    try expectFormat("fn f(a:int,b:int)->int return a+b end\r\nx:=f(\r\n1,  // a=b,c  \r\n2\r\n)\r\n", "fn f(a:int, b:int)->int return a+b end\r\nx := f(\r\n    1, // a=b,c  \r\n    2\r\n)\r\n", .{});
}

test "formatter distinguishes wildcard imports from multiplication continuation" {
    try expectFormat("import paint.*\n// next declaration\nfn foo()->path\nreturn circle with center (0mm,0mm) radius 4cm\nend\nvalue:=(2*\n3)\n", "import paint.*\n// next declaration\nfn foo()->path\n    return circle with center (0mm, 0mm) radius 4cm\nend\nvalue := (2*\n    3)\n", .{});
    try expectFormat("fn foo()->path\nimport \"std/paint.huak\".*\nvalue:=(2*\n3)\nreturn circle with center (0mm,0mm) radius 4cm\nend\n", "fn foo()->path\n    import \"std/paint.huak\".*\n    value := (2*\n        3)\n    return circle with center (0mm, 0mm) radius 4cm\nend\n", .{});
}

test "formatter leaves trailing list and import commas next to their closing delimiter" {
    try expectFormat("import paint.{circle,}\npoints:=[1,2 , ]\n", "import paint.{circle,}\npoints := [1, 2,]\n", .{});
}

test "formatter releases token indentation and result owners on allocation failures" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var diagnostic: ?source.Diagnostic = null;
            const result = try formatSource(allocator, "x:=[\n1,2\n]\n", &.{}, &diagnostic, .{});
            allocator.free(result);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "formatter indents structs and distinguishes value colons from types and slices" {
    var diagnostic: ?source.Diagnostic = null;
    const input = "export struct Options\nwidth:int=2\nvalues:list=[1,2]\nend\nvalue:=Options(width :3,values:[1,2])\nvalue.width=4\nvalue.values+=5\nsettings:={\"label\" :\"Ω\",\"range\":value.values[0:1]}\n";
    const expected = "export struct Options\n    width:int = 2\n    values:list = [1, 2]\nend\nvalue := Options(width: 3, values: [1, 2])\nvalue.width = 4\nvalue.values += 5\nsettings := {\"label\": \"Ω\", \"range\": value.values[0:1]}\n";
    const result = try formatSource(std.testing.allocator, input, &.{}, &diagnostic, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
    const again = try formatSource(std.testing.allocator, result, &.{}, &diagnostic, .{});
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(result, again);
}
