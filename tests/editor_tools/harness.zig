//! Helpers shared by the editor-tool tests: running a binary with input, and checking inlay hint labels and semantic token rows.
const std = @import("std");
const tooling = @import("huak_tooling");
const t = std.testing;

pub fn expectSemanticRow(source: []const u8, data: []const u32, line: usize, expected: []const struct { []const u8, tooling.semantic_tokens.Kind }) !void {
    try t.expectEqual(@as(usize, 0), data.len % 5);
    var position: tooling.position.Position = .{ .line = 0, .character = 0 };
    var end: usize = 0;
    var found: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 5) {
        position.line += data[i];
        position.character = if (data[i] == 0) position.character + data[i + 1] else data[i + 1];
        const start = tooling.position.offset(source, position) orelse return error.InvalidTokenPosition;
        try t.expect(start >= end);
        end = tooling.position.offset(source, .{ .line = position.line, .character = position.character + data[i + 2] }) orelse return error.InvalidTokenPosition;
        if (position.line != line) continue;
        try t.expect(found < expected.len);
        try t.expectEqualStrings(expected[found][0], source[start..end]);
        try t.expectEqual(@as(u32, @backingInt(expected[found][1])), data[i + 3]);
        try t.expectEqual(@as(u32, 0), data[i + 4]);
        found += 1;
    }
    try t.expectEqual(expected.len, found);
}

pub fn runWithInput(allocator: std.mem.Allocator, argv: []const []const u8, input: ?std.Io.File) !std.process.RunResult {
    var child = try std.process.spawn(t.io, .{ .argv = argv, .stdin = if (input) |file| .{ .file = file } else .ignore, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(t.io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, t.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(256, .none)) |_| {
        if (reader.reader(0).buffered().len > 1024 * 1024 or reader.reader(1).buffered().len > 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(t.io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    return .{ .term = term, .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
}

pub fn expectHintLabels(response: std.json.Value, expected: []const []const u8) !void {
    const hints = response.object.get("result").?.array.items;
    try t.expectEqual(expected.len, hints.len);
    for (hints, expected) |hint, label| {
        const parts = hint.object.get("label").?.array.items;
        try t.expectEqual(@as(usize, 1), parts.len);
        try t.expectEqualStrings(label, parts[0].object.get("value").?.string);
        try t.expect(parts[0].object.get("location") != null);
        try t.expect(hint.object.get("paddingLeft").?.bool);
    }
}
