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
    /// Preserve the underlying host error and the operation that produced it.
    cause: ?union(enum) {
        unavailable_source_parser: anyerror,
        source_block: anyerror,
        module_import: anyerror,
    } = null,
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
        result.writeMessage(format, args);
        return result;
    }

    /// Replace the caller's diagnostic in place. Its inline source buffer is
    /// intentionally independent of the parse arena and can outlive it.
    /// Keep the formatter out of the parser's success path, including after inlining.
    pub fn set(slot: *?Diagnostic, span: Span, comptime format: []const u8, args: anytype) *Diagnostic {
        const result = reset(slot, span);
        if (comptime @typeInfo(@TypeOf(args)).@"struct".field_names.len == 0) {
            const message: @Tuple(&.{[]const u8}) = .{comptime std.fmt.comptimePrint(format, .{})};
            @call(.never_inline, writeMessage, .{ result, "{s}", message });
        } else {
            @call(.never_inline, writeMessage, .{ result, format, args });
        }
        return result;
    }

    // Share the in-place reset across format strings.
    noinline fn reset(slot: *?Diagnostic, span: Span) *Diagnostic {
        slot.* = .{ .span = span };
        return &slot.*.?;
    }

    pub fn writeMessage(self: *Diagnostic, comptime format: []const u8, args: anytype) void {
        self.finishMessage(std.mem.print(&self.storage, format, args));
    }

    // All formatters report their bounded write to the same message buffer.
    noinline fn finishMessage(self: *Diagnostic, written: std.mem.PrintError![]u8) void {
        const message = written catch {
            const fallback = "language diagnostic exceeds message capacity";
            @memcpy(self.storage[0..fallback.len], fallback);
            self.len = fallback.len;
            return;
        };
        self.len = message.len;
    }

    /// Borrows the message until the diagnostic is rewritten.
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

test "plain and formatted diagnostic messages preserve braces and buffer limits" {
    const span: Span = .{ .start = 1, .end = 2 };
    var slot: ?Diagnostic = null;
    try std.testing.expectEqualStrings("{x}", Diagnostic.set(&slot, span, "{{x}}", .{}).text());
    try std.testing.expectEqualStrings("{{x}}", Diagnostic.set(&slot, span, "{s}", .{"{{x}}"}).text());

    const full: @FieldType(Diagnostic, "storage") = @splat('x');
    try std.testing.expectEqualStrings(&full, Diagnostic.set(&slot, span, "{s}", .{&full}).text());
    var input = "runtime".*;
    const saved = Diagnostic.set(&slot, span, "{s}", .{&input}).*;
    input[0] = 'X';
    _ = Diagnostic.set(&slot, span, "replacement", .{});
    try std.testing.expectEqualStrings("runtime", saved.text());

    const too_long = full ++ "x";
    try std.testing.expectEqualStrings("language diagnostic exceeds message capacity", Diagnostic.set(&slot, span, too_long, .{}).text());
}

test "source locations fall back to the caller source and can be rebound" {
    var slot: ?Diagnostic = null;
    const diagnostic = Diagnostic.set(&slot, .{ .start = 2, .end = 3 }, "value {d}", .{3});
    try std.testing.expect(diagnostic.fileName() == null);
    try std.testing.expectEqualDeep(Diagnostic.Position{ .line = 2, .column = 1 }, diagnostic.position("a\nx"));
    diagnostic.setSource("one.huak", "abx");
    diagnostic.setSource("two.huak", "a\nx");
    try std.testing.expectEqualStrings("two.huak", diagnostic.fileName().?);
    try std.testing.expectEqualDeep(Diagnostic.Position{ .line = 2, .column = 1 }, diagnostic.position(""));
    diagnostic.cause = .{ .module_import = error.FileNotFound };
    const long_message: [400]u8 = @splat('a');
    const next = Diagnostic.set(&slot, .{ .start = 0, .end = 0 }, "{s}", .{&long_message});
    try std.testing.expect(next.cause == null and next.fileName() == null and next.origin == null);
    try std.testing.expectEqualStrings("language diagnostic exceeds message capacity", next.text());
}
