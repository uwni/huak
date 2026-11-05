//! Owned text replacement shared by editor services. The caller keeps the old
//! document unchanged until a replacement succeeds, so an invalid request can
//! never leave a partially edited document behind.
const std = @import("std");

/// Replace `text[start..end]` with `replacement` in one allocation. A complete
/// replacement takes ownership of a single copy of the new text instead of
/// duplicating the old text and then copying the replacement again.
pub fn replace(allocator: std.mem.Allocator, text: []const u8, start: usize, end: usize, replacement: []const u8) ![]u8 {
    if (start > end or end > text.len) return error.InvalidRange;
    if (start == 0 and end == text.len) return allocator.dupe(u8, replacement);
    const suffix = text.len - end;
    const prefix = std.math.add(usize, start, replacement.len) catch return error.OutOfMemory;
    const length = std.math.add(usize, prefix, suffix) catch return error.OutOfMemory;
    const result = try allocator.alloc(u8, length);
    @memcpy(result[0..start], text[0..start]);
    @memcpy(result[start..][0..replacement.len], replacement);
    @memcpy(result[start + replacement.len ..], text[end..]);
    return result;
}

test "replace handles full range, insertion, deletion and rejects invalid ranges" {
    const allocator = std.testing.allocator;
    const original = "0123456789";
    const full = try replace(allocator, original, 0, original.len, "new");
    defer allocator.free(full);
    try std.testing.expectEqualStrings("new", full);
    const insertion = try replace(allocator, original, 4, 4, "xy");
    defer allocator.free(insertion);
    try std.testing.expectEqualStrings("0123xy456789", insertion);
    const deletion = try replace(allocator, original, 2, 6, "");
    defer allocator.free(deletion);
    try std.testing.expectEqualStrings("016789", deletion);
    try std.testing.expectError(error.InvalidRange, replace(allocator, original, 8, 4, "x"));
    try std.testing.expectError(error.InvalidRange, replace(allocator, original, 0, original.len + 1, "x"));
}

test "replace releases every allocation on failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const range = try replace(allocator, "012345", 1, 3, "abcd");
            allocator.free(range);
            const full = try replace(allocator, "012345", 0, 6, "replacement");
            allocator.free(full);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
