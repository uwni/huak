//! LSP uses zero-based line and UTF-16 code-unit coordinates.
const std = @import("std");
pub const Position = struct { line: usize, character: usize };
pub const Range = struct { start: Position, end: Position };

pub fn at(source: []const u8, byte_offset: usize) Position {
    var position: Position = .{ .line = 0, .character = 0 };
    var i: usize = 0;
    const end = @min(byte_offset, source.len);
    while (i < end) {
        if (source[i] == '\n' or source[i] == '\r') {
            const length: usize = if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') 2 else 1;
            if (length > end - i) break;
            position.line += 1;
            position.character = 0;
            i += length;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
        if (i + length > end) break;
        const cp = std.unicode.utf8Decode(source[i..][0..length]) catch 0xfffd;
        position.character += if (cp > 0xffff) @as(usize, 2) else 1;
        i += length;
    }
    return position;
}

pub fn offset(source: []const u8, position: Position) ?usize {
    var line: usize = 0;
    var i: usize = 0;
    while (line < position.line) {
        while (i < source.len and source[i] != '\n' and source[i] != '\r') i += 1;
        if (i == source.len) return null;
        const length: usize = if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') 2 else 1;
        i += length;
        line += 1;
    }
    var character: usize = 0;
    while (i < source.len and source[i] != '\n' and source[i] != '\r') {
        if (character == position.character) return i;
        const length = std.unicode.utf8ByteSequenceLength(source[i]) catch return null;
        if (length > source.len - i) return null;
        const cp = std.unicode.utf8Decode(source[i..][0..length]) catch return null;
        character += if (cp > 0xffff) @as(usize, 2) else 1;
        if (character > position.character) return null;
        i += length;
    }
    return if (character == position.character) i else null;
}

test "UTF-16 positions handle astral characters and CRLF" {
    const text = "A🙂中\r\nb";
    try std.testing.expectEqualDeep(Position{ .line = 0, .character = 3 }, at(text, 5));
    try std.testing.expectEqual(@as(?usize, 5), offset(text, .{ .line = 0, .character = 3 }));
    try std.testing.expect(offset(text, .{ .line = 0, .character = 2 }) == null);
    try std.testing.expectEqualDeep(Position{ .line = 1, .character = 1 }, at(text, text.len));
    try std.testing.expectEqualDeep(Position{ .line = 0, .character = 4 }, at(text, 9));
    try std.testing.expectEqual(@as(?usize, 2), offset("a\rb", .{ .line = 1, .character = 0 }));
}
