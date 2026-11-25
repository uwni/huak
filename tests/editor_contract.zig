//! The editor files follow what the language and its tools define: the VS
//! Code grammar and language configuration hold the patterns made from the
//! lexer, units and formatter, and the extension's JavaScript asks only for
//! commands, options, watch events, requests and names that the command
//! line, the language server and the language define.
const std = @import("std");
const tooling = huak.tooling;
const huak = @import("huak");
const cli = @import("cli_options");
const t = std.testing;

test "the editor grammars hold the language's words and indentation" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grammar = tooling.editor_grammar;
    if (!try grammar.holds(a, @embedFile("editor_grammar"), &try grammar.grammarEntries(a)) or
        !try grammar.holds(a, @embedFile("editor_configuration"), &try grammar.configurationEntries(a)))
    {
        std.debug.print("the editor grammars are out of date; run `zig build editor-grammar`\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "the extension runs the command line as it defines its commands and options" {
    for ([_][]const u8{ @embedFile("extension_render"), @embedFile("extension_preview") }) |js| {
        var literals: Literals = .{ .js = js };
        while (literals.next()) |literal| {
            if (std.mem.startsWith(u8, literal.text, "--")) {
                try expectNamed(cli.Option, literal.text[2..]);
            } else if (std.mem.endsWith(u8, std.mem.trimEnd(u8, js[0..literal.start], " \t\n"), "[")) {
                // An array of arguments with options in it starts with the command.
                const end = std.mem.indexOfScalarPos(u8, js, literal.start, ']') orelse continue;
                var rest: Literals = .{ .js = js[0..end], .at = literal.end };
                while (rest.next()) |argument| if (std.mem.startsWith(u8, argument.text, "--")) {
                    try expectNamed(cli.Command, literal.text);
                    break;
                };
            }
        }
    }
}

test "the extension reads the watch events the command line writes" {
    const watch = @embedFile("extension_watch");
    const list = std.mem.indexOf(u8, watch, "].includes(value.event)") orelse return error.ContractNotFound;
    const start = std.mem.lastIndexOfScalar(u8, watch[0..list], '[') orelse return error.ContractNotFound;
    var listed: Literals = .{ .js = watch[0..list], .at = start };
    var count: usize = 0;
    while (listed.next()) |literal| : (count += 1) try expectNamed(cli.WatchEvent, literal.text);
    try t.expectEqual(@typeInfo(cli.WatchEvent).@"enum".field_names.len, count);
    for ([_][]const u8{ watch, @embedFile("extension_preview") }) |js| {
        var compared: usize = 0;
        while (std.mem.indexOfPos(u8, js, compared, "event === ")) |at| : (compared = at + 1) {
            var literals: Literals = .{ .js = js, .at = at };
            try expectNamed(cli.WatchEvent, (literals.next() orelse return error.ContractNotFound).text);
        }
    }
}

test "the extension asks the language server what it answers" {
    for ([_][]const u8{ @embedFile("extension_main"), @embedFile("extension_outputs") }) |js| {
        var literals: Literals = .{ .js = js };
        while (literals.next()) |literal| if (std.mem.startsWith(u8, literal.text, "huak/")) {
            const known = inline for (@typeInfo(tooling.lsp.requests).@"struct".decl_names) |name| {
                if (std.mem.eql(u8, literal.text, @field(tooling.lsp.requests, name))) break true;
            } else false;
            if (!known) {
                std.debug.print("the language server answers no request '{s}'\n", .{literal.text});
                return error.TestUnexpectedResult;
            }
        };
    }
    try t.expect(std.mem.indexOf(u8, @embedFile("extension_main"), "'" ++ tooling.lsp.standard_scheme ++ "'") != null);
}

test "the extension names the default picture and the formats as the language and renderer do" {
    const outputs = @embedFile("extension_outputs");
    const compared = std.mem.indexOf(u8, outputs, "name === ") orelse return error.ContractNotFound;
    var literals: Literals = .{ .js = outputs, .at = compared };
    try t.expectEqualStrings(huak.language.bytecode.Output.default_name, (literals.next() orelse return error.ContractNotFound).text);
    const render = @embedFile("extension_render");
    const offered = std.mem.indexOf(u8, render, "].map(format =>") orelse return error.ContractNotFound;
    const start = std.mem.lastIndexOfScalar(u8, render[0..offered], '[') orelse return error.ContractNotFound;
    var formats: Literals = .{ .js = render[0..offered], .at = start };
    var count: usize = 0;
    while (formats.next()) |format| : (count += 1) try expectNamed(huak.render.Format, format.text);
    try t.expectEqual(@typeInfo(huak.render.Format).@"enum".field_names.len, count);
}

fn expectNamed(comptime Names: type, text: []const u8) !void {
    if (std.meta.stringToEnum(Names, text) == null) {
        std.debug.print("'{s}' is not one of the {s} the tools define\n", .{ text, @typeName(Names) });
        return error.TestUnexpectedResult;
    }
}

/// The single-quoted strings of JavaScript source in its code, past its
/// comments, double-quoted strings and template text, which hold none the
/// extension sends; `start` and `end` are the quotes' places.
const Literals = struct {
    js: []const u8,
    at: usize = 0,

    const Literal = struct { text: []const u8, start: usize, end: usize };

    fn next(self: *Literals) ?Literal {
        const js = self.js;
        while (self.at < js.len) {
            const character = js[self.at];
            if (std.mem.startsWith(u8, js[self.at..], "//")) {
                self.at = std.mem.indexOfScalarPos(u8, js, self.at, '\n') orelse js.len;
            } else if (std.mem.startsWith(u8, js[self.at..], "/*")) {
                self.at = if (std.mem.indexOfPos(u8, js, self.at + 2, "*/")) |close| close + 2 else js.len;
            } else if (character == '"' or character == '`' or character == '\'') {
                const start = self.at;
                self.at += 1;
                while (self.at < js.len and js[self.at] != character) : (self.at += 1) {
                    if (js[self.at] == '\\') self.at += 1;
                }
                self.at = @min(self.at + 1, js.len);
                if (character == '\'') return .{ .text = js[start + 1 .. self.at - 1], .start = start, .end = self.at };
            } else self.at += 1;
        }
        return null;
    }
};
