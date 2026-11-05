//! Data imports produce ordinary Program constants. Strings borrow the Program's
//! source buffer unless decoding escapes requires a separate allocation.
const std = @import("std");
const csvzero = @import("csvzero");
const types = @import("types.zig");
const Value = types.Value;
const Allocator = std.mem.Allocator;

pub const Format = enum {
    json,
    csv,

    pub fn fromPath(path: []const u8) ?Format {
        const ext = std.fs.path.extension(path);
        return if (ext.len > 1) std.meta.stringToEnum(Format, ext[1..]) else null;
    }

    pub fn decode(format: Format, memory: Allocator, source: []const u8, offset: *usize) !Value {
        const bom = "\xef\xbb\xbf";
        const start: usize = if (std.mem.startsWith(u8, source, bom)) bom.len else 0;
        defer offset.* += start;
        const contents = source[start..];
        switch (format) {
            .json => {
                var scanner = std.json.Scanner.initCompleteInput(memory, contents);
                defer scanner.deinit();
                defer offset.* = scanner.cursor;
                const value = try jsonValue(memory, &scanner, try jsonToken(memory, &scanner), 0);
                if (try jsonToken(memory, &scanner) != .end_of_document) return error.SyntaxError;
                return value;
            },
            .csv => return csvRows(memory, contents, offset),
        }
    }
};

fn jsonToken(memory: Allocator, scanner: *std.json.Scanner) !std.json.Token {
    return scanner.nextAllocMax(memory, .alloc_if_needed, scanner.input.len);
}

fn jsonValue(memory: Allocator, scanner: *std.json.Scanner, token: std.json.Token, depth: usize) anyerror!Value {
    switch (token) {
        .null => return .unit,
        .true, .false => return .{ .boolean = token == .true },
        .string, .allocated_string => |bytes| return .{ .string = bytes },
        .number, .allocated_number => |bytes| return switch (std.json.Value.parseFromNumberSlice(bytes)) {
            .integer => |n| .{ .int = n },
            .float => |n| .{ .number = n },
            else => error.NumberOutOfRange,
        },
        .array_begin => {
            if (depth > 256) return error.NestingTooDeep;
            var items: std.ArrayList(Value) = .empty;
            while (true) {
                const next = try jsonToken(memory, scanner);
                if (next == .array_end) return types.listView(try items.toOwnedSlice(memory));
                try items.append(memory, try jsonValue(memory, scanner, next, depth + 1));
            }
        },
        .object_begin => {
            if (depth > 256) return error.NestingTooDeep;
            const dict = try memory.create(types.Dict);
            dict.* = .{};
            while (true) {
                const key = switch (try jsonToken(memory, scanner)) {
                    .object_end => return .{ .dict = dict },
                    .string, .allocated_string => |bytes| bytes,
                    else => return error.SyntaxError,
                };
                const slot = try dict.entries.getOrPut(memory, key);
                if (slot.found_existing) return error.DuplicateField;
                slot.value_ptr.* = try jsonValue(memory, scanner, try jsonToken(memory, scanner), depth + 1);
            }
        },
        else => return error.SyntaxError,
    }
}

fn csvRows(memory: Allocator, source: []const u8, offset: *usize) !Value {
    var reader = std.Io.Reader.fixed(source);
    var iterator = csvzero.Iterator.init(&reader);
    var rows: std.ArrayList(Value) = .empty;
    var row: std.ArrayList(Value) = .empty;
    while (reader.seek < source.len) {
        offset.* = reader.seek;
        const field = try iterator.next();
        const text = try csvText(memory, field, source[offset.*..reader.seek]);
        try row.append(memory, .{ .string = text });
        if (field.last_column) try rows.append(memory, types.listView(try row.toOwnedSlice(memory)));
    }
    // A delimiter at EOF introduces a final empty field.
    if (row.items.len != 0) {
        try row.append(memory, .{ .string = "" });
        try rows.append(memory, types.listView(try row.toOwnedSlice(memory)));
    }
    return types.listView(try rows.toOwnedSlice(memory));
}

fn csvText(memory: Allocator, parsed: csvzero.Iterator.Field, consumed: []const u8) ![]const u8 {
    var field = parsed;
    if (field.data.ptr != consumed.ptr) {
        // csv-zero can accept a stray CR after a closing quote or consume an
        // escaped quote as the closing quote at EOF. Verify the field boundary.
        if (consumed[0] != '"' or field.data.len + 2 > consumed.len) return error.InvalidQuotes;
        const suffix = consumed[field.data.len + 1 ..];
        if (suffix[0] != '"') return error.InvalidQuotes;
        const ending = suffix[1..];
        if (ending.len != 0 and !std.mem.eql(u8, ending, ",") and !std.mem.eql(u8, ending, "\n") and !std.mem.eql(u8, ending, "\r\n")) return error.InvalidQuotes;
        const trailing = field.data.len - std.mem.trimEnd(u8, field.data, "\"").len;
        if (trailing % 2 != 0) return error.InvalidQuotes;
    }
    if (!std.unicode.utf8ValidateSlice(field.data)) return error.InvalidUtf8;
    if (field.needs_unescape) field.data = try memory.dupe(u8, field.data);
    return field.unescaped();
}
