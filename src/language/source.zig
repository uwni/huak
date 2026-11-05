//! Source locations and allocation-free diagnostics shared by the language stages.
const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn join(a: Span, b: Span) Span {
        return .{ .start = a.start, .end = b.end };
    }
};

pub const Diagnostic = struct {
    span: Span,
    storage: [384]u8 = undefined,
    len: usize = 0,
    // Compilation may release the module source on failure. Keep its location
    // inline so a diagnostic never borrows a failed compilation's arena.
    file_storage: [4096]u8 = undefined,
    file_len: usize = 0,
    origin: ?Position = null,
    pub const Position = struct { line: usize, column: usize };

    pub fn init(span: Span, comptime format: []const u8, args: anytype) Diagnostic {
        var result: Diagnostic = .{ .span = span };
        const message = std.fmt.bufPrint(&result.storage, format, args) catch {
            const fallback = "language diagnostic exceeds message capacity";
            @memcpy(result.storage[0..fallback.len], fallback);
            result.len = fallback.len;
            return result;
        };
        result.len = message.len;
        return result;
    }

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn setSource(self: *Diagnostic, name: []const u8, source: []const u8) void {
        self.file_len = @min(name.len, self.file_storage.len);
        if (name.len <= self.file_storage.len) {
            @memcpy(self.file_storage[0..self.file_len], name);
        } else {
            @memcpy(self.file_storage[0..3], "...");
            @memcpy(self.file_storage[3..], name[name.len - (self.file_storage.len - 3) ..]);
        }
        self.origin = locate(self.span, source);
    }

    pub fn fileName(self: *const Diagnostic) ?[]const u8 {
        return if (self.file_len == 0) null else self.file_storage[0..self.file_len];
    }

    pub fn position(self: *const Diagnostic, source: []const u8) Position {
        return self.origin orelse locate(self.span, source);
    }

    fn locate(span: Span, source: []const u8) Position {
        var line: usize = 1;
        var column: usize = 1;
        for (source[0..@min(span.start, source.len)]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        return .{ .line = line, .column = column };
    }
};

test "module diagnostics retain locations after the source buffers are released" {
    const allocator = std.testing.allocator;
    var diagnostic = Diagnostic.init(.{ .start = 7, .end = 8 }, "invalid operation", .{});
    {
        const name = try allocator.dupe(u8, "/modules/shapes.huak");
        defer allocator.free(name);
        const content = try allocator.dupe(u8, "first\n abc");
        defer allocator.free(content);
        diagnostic.setSource(name, content);
    }
    try std.testing.expectEqualStrings("/modules/shapes.huak", diagnostic.fileName().?);
    try std.testing.expectEqualDeep(Diagnostic.Position{ .line = 2, .column = 2 }, diagnostic.position("unrelated root source"));
    try std.testing.expectEqualStrings("invalid operation", diagnostic.text());
}

test "source locations fall back to the caller source and can be rebound" {
    var diagnostic: Diagnostic = .{ .span = .{ .start = 2, .end = 3 } };
    try std.testing.expect(diagnostic.fileName() == null);
    try std.testing.expectEqualDeep(Diagnostic.Position{ .line = 2, .column = 1 }, diagnostic.position("a\nx"));
    diagnostic.setSource("one.huak", "abx");
    diagnostic.setSource("two.huak", "a\nx");
    try std.testing.expectEqualStrings("two.huak", diagnostic.fileName().?);
    try std.testing.expectEqualDeep(Diagnostic.Position{ .line = 2, .column = 1 }, diagnostic.position(""));
}
