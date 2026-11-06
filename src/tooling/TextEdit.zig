//! A request's sequential text changes. Borrow the original until the first
//! edit, then reuse one mutable buffer. The caller commits only after success.
const std = @import("std");
const TextEdit = @This();

source: []const u8,
buffer: ?std.ArrayList(u8) = null,

pub fn deinit(self: *TextEdit, allocator: std.mem.Allocator) void {
    if (self.buffer) |*buffer| buffer.deinit(allocator);
    self.buffer = null;
}

pub fn bytes(self: *const TextEdit) []const u8 {
    return if (self.buffer) |buffer| buffer.items else self.source;
}

/// Replacement bytes must not alias the mutable buffer, as for ArrayList.
pub fn replace(self: *TextEdit, allocator: std.mem.Allocator, start: usize, end: usize, replacement: []const u8) !void {
    const text = self.bytes();
    if (start > end or end > text.len) return error.InvalidRange;
    if (self.buffer) |*buffer| return buffer.replaceRange(allocator, start, end - start, replacement);
    const suffix = text.len - end;
    const prefix = std.math.add(usize, start, replacement.len) catch return error.OutOfMemory;
    const length = std.math.add(usize, prefix, suffix) catch return error.OutOfMemory;
    var buffer = try std.ArrayList(u8).initCapacity(allocator, length);
    buffer.appendSliceAssumeCapacity(text[0..start]);
    buffer.appendSliceAssumeCapacity(replacement);
    buffer.appendSliceAssumeCapacity(text[end..]);
    self.buffer = buffer;
}

/// Null means no edits; otherwise the caller owns the returned text.
pub fn take(self: *TextEdit, allocator: std.mem.Allocator) !?[]u8 {
    const buffer = if (self.buffer) |*buffer| buffer else return null;
    const result = try buffer.toOwnedSlice(allocator);
    self.buffer = null;
    return result;
}

test "text edits preserve the source and apply changes to the evolving buffer" {
    const allocator = std.testing.allocator;
    var source = "0123456789".*;
    var edit: TextEdit = .{ .source = &source };
    defer edit.deinit(allocator);
    try std.testing.expect(try edit.take(allocator) == null);
    try edit.replace(allocator, 4, 4, "xy");
    try std.testing.expectEqualStrings("0123xy456789", edit.bytes());
    try edit.replace(allocator, 2, 6, "");
    try std.testing.expectEqualStrings("01456789", edit.bytes());
    try std.testing.expectError(error.InvalidRange, edit.replace(allocator, 8, 4, "x"));
    try std.testing.expectError(error.InvalidRange, edit.replace(allocator, 0, edit.bytes().len + 1, "x"));
    try std.testing.expectEqualStrings("01456789", edit.bytes());
    try edit.replace(allocator, 0, edit.bytes().len, "new");
    const result = (try edit.take(allocator)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("new", result);
    try std.testing.expectEqualStrings("0123456789", &source);
}

test "text edits release every allocation on failure before commit" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var source = "012345".*;
            defer std.debug.assert(std.mem.eql(u8, &source, "012345"));
            var edit: TextEdit = .{ .source = &source };
            defer edit.deinit(allocator);
            try edit.replace(allocator, 1, 3, "abcd");
            try edit.replace(allocator, 0, 0, "a longer replacement requiring buffer growth");
            try edit.replace(allocator, 0, edit.bytes().len, "short");
            allocator.free((try edit.take(allocator)).?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
