//! The parts of the editor grammars that the language defines elsewhere: its
//! reserved words, units and operators, and the words by which the formatter
//! indents. They are made here from the lexer, the units and the formatter.
//! `zig build editor-grammar` writes them into the VS Code grammar and
//! language configuration, which the Playground copies; the editor tests fail
//! while those files hold other patterns.
const std = @import("std");
const Lexer = @import("../language/Lexer.zig");
const source = @import("../language/source.zig");
const units = @import("../drawing/units.zig");
const format = @import("format.zig");
const Allocator = std.mem.Allocator;

/// A string in a JSON file that is made here: the keys and array indices that
/// lead to it from the file's root, and its value.
pub const Entry = struct { path: []const []const u8, value: []const u8 };

/// The TextMate grammar's patterns for the reserved words, for numbers with
/// their units, and for operators. A number is written as the lexer reads it,
/// and may be followed by `pi`, as the parser reads `2pi`.
pub fn grammarEntries(allocator: Allocator) ![4]Entry {
    return .{
        .{ .path = &.{ "repository", "keywords", "patterns", "0", "match" }, .value = try allocator.print("\\b(?:{s})\\b", .{try reserved(allocator, false)}) },
        .{ .path = &.{ "repository", "keywords", "patterns", "1", "match" }, .value = try allocator.print("\\b(?:{s})\\b", .{try reserved(allocator, true)}) },
        .{ .path = &.{ "repository", "numbers", "patterns", "0", "match" }, .value = try allocator.print("(?<![\\w.])(?:[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)(?:\\s*pi)?(?:\\s*(?:{s})\\b)?", .{try unitNames(allocator)}) },
        .{ .path = &.{ "repository", "operators", "patterns", "0", "match" }, .value = try operators(allocator) },
    };
}

/// The language configuration's indentation patterns, as the formatter
/// indents: a line that leads out of its block goes one level out; the line
/// after one that opens a block without closing it, or that goes on with a
/// block after leading out of its head, goes one level in.
pub fn configurationEntries(allocator: Allocator) ![2]Entry {
    var going_on: std.ArrayList(Lexer.Kind) = .empty;
    for (format.leads_out) |kind| if (kind != format.closes_block) try going_on.append(allocator, kind);
    return .{
        .{ .path = &.{ "indentationRules", "increaseIndentPattern" }, .value = try allocator.print("^\\s*(?:(?:{s})\\b|.*\\b(?:{s})\\b)(?!.*\\b{s}\\b).*$", .{
            try words(allocator, going_on.items),
            try words(allocator, &format.opens_block),
            word(format.closes_block),
        }) },
        .{ .path = &.{ "indentationRules", "decreaseIndentPattern" }, .value = try allocator.print("^\\s*(?:{s})\\b", .{try words(allocator, &format.leads_out)}) },
    };
}

/// Whether the JSON text holds every entry's value.
pub fn holds(allocator: Allocator, json: []const u8, entries: []const Entry) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    for (entries) |entry| {
        const held = stringAt(parsed.value, entry.path) orelse return error.MissingEntry;
        if (!std.mem.eql(u8, held, entry.value)) return false;
    }
    return true;
}

/// The JSON text with each entry's string replaced by its value and the rest
/// of the text as it was. The string must stand in the text once, as JSON
/// writes it.
pub fn apply(allocator: Allocator, json: []const u8, entries: []const Entry) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    var text = try allocator.dupe(u8, json);
    for (entries) |entry| {
        const held = stringAt(parsed.value, entry.path) orelse return error.MissingEntry;
        const from = try std.json.Stringify.valueAlloc(allocator, held, .{});
        const to = try std.json.Stringify.valueAlloc(allocator, entry.value, .{});
        const at = std.mem.find(u8, text, from) orelse return error.EntryNotFound;
        if (std.mem.findPos(u8, text, at + from.len, from) != null) return error.EntryNotUnique;
        text = try std.mem.concat(allocator, u8, &.{ text[0..at], to, text[at + from.len ..] });
    }
    return text;
}

fn stringAt(root: std.json.Value, path: []const []const u8) ?[]const u8 {
    var value = root;
    for (path) |key| value = switch (value) {
        .object => |object| object.get(key) orelse return null,
        .array => |array| array: {
            const index = std.fmt.parseInt(usize, key, 10) catch return null;
            break :array if (index < array.items.len) array.items[index] else return null;
        },
        else => return null,
    };
    return if (value == .string) value.string else null;
}

/// The reserved words that are the literals `true` and `false`, or the others,
/// in alphabetical order.
fn reserved(allocator: Allocator, literals: bool) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (Lexer.keywords.keys(), Lexer.keywords.values()) |text, kind|
        if ((kind == .kw_true or kind == .kw_false) == literals) try list.append(allocator, text);
    std.mem.sort([]const u8, list.items, {}, alphabetical);
    return std.mem.join(allocator, "|", list.items);
}

fn unitNames(allocator: Allocator) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (std.enums.values(units.Unit)) |unit| try list.append(allocator, @tagName(unit));
    return std.mem.join(allocator, "|", list.items);
}

/// The operators, as a pattern: every spelling of up to three punctuation
/// characters that the lexer reads as one operator or assignment, longest
/// first, so that a longer one is not taken as a shorter one and the rest.
fn operators(allocator: Allocator) ![]const u8 {
    const punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
    var found: std.ArrayList([]const u8) = .empty;
    var candidate: [3]u8 = undefined;
    for (1..candidate.len + 1) |length| {
        var digits: [candidate.len]usize = @splat(0);
        next: while (true) {
            for (candidate[0..length], digits[0..length]) |*character, digit| character.* = punctuation[digit];
            if (spellsOperator(candidate[0..length])) try found.append(allocator, try allocator.dupe(u8, candidate[0..length]));
            for (digits[0..length]) |*digit| {
                digit.* += 1;
                if (digit.* < punctuation.len) continue :next;
                digit.* = 0;
            }
            break;
        }
    }
    std.mem.sort([]const u8, found.items, {}, longestFirst);
    var pattern: std.ArrayList(u8) = .empty;
    for (found.items, 0..) |spelling, index| {
        if (index != 0) try pattern.append(allocator, '|');
        for (spelling) |character| {
            if (std.mem.findScalar(u8, "\\^$.|?*+()[]{}", character) != null) try pattern.append(allocator, '\\');
            try pattern.append(allocator, character);
        }
    }
    return pattern.toOwnedSlice(allocator);
}

fn spellsOperator(text: []const u8) bool {
    var diagnostic: ?source.Diagnostic = null;
    var lexer: Lexer = .{ .source = text, .diagnostic = &diagnostic };
    const token = lexer.next() catch return false;
    if (token.span.start != 0 or token.span.end != text.len) return false;
    const after = lexer.next() catch return false;
    if (after.kind != .eof) return false;
    return Lexer.isOperator(token.kind) or switch (token.kind) {
        .assign, .declare, .plus_assign => true,
        else => false,
    };
}

fn word(kind: Lexer.Kind) []const u8 {
    for (Lexer.keywords.keys(), Lexer.keywords.values()) |text, each| if (each == kind) return text;
    unreachable;
}

fn words(allocator: Allocator, kinds: []const Lexer.Kind) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (kinds) |kind| try list.append(allocator, word(kind));
    return std.mem.join(allocator, "|", list.items);
}

fn alphabetical(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn longestFirst(_: void, a: []const u8, b: []const u8) bool {
    return if (a.len != b.len) a.len > b.len else std.mem.lessThan(u8, a, b);
}

test "operators are the lexer's, longest first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("!=|\\+=|--|->|:=|<=|==|>=|~~|%|&|\\*|\\+|-|/|<|=|>|\\^", try operators(arena.allocator()));
}

test "a rewrite replaces only the made strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{ \"a\": { \"b\": [\"x\\\\b\", \"keep\"] } }";
    const entries = [_]Entry{.{ .path = &.{ "a", "b", "0" }, .value = "y\\s" }};
    try std.testing.expect(!try holds(a, json, &entries));
    const written = try apply(a, json, &entries);
    try std.testing.expectEqualStrings("{ \"a\": { \"b\": [\"y\\\\s\", \"keep\"] } }", written);
    try std.testing.expect(try holds(a, written, &entries));
}
