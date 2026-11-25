//! Tests of reusing native block ranges across the header scan, Headers.sourceBlockLength and typstBlock.
const std = @import("std");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const Options = Parser.Options;
const scanHeaders = Parser.scanHeaders;

// Fixed provider fixtures test host bookkeeping only. Native block parsing is
// exercised through libtypst by the editor and language integration suites.
const OpaqueBlockFixture = struct {
    pub const code = "[#let word = [end typ[ignored]]; body]";
    pub const default = "[Default [nested]]";
    const body_source = "[Body #let word = \"end\"]";
    pub const record = "[Record /* ] end */ [nested]]";
    const tail = "[Trailing // end\n text]";
    pub const blocks = [_][]const u8{ code, default, body_source, record, tail };
    pub const input = "theme:=typ.module" ++ code ++ "\nfn label(value:text=typ" ++ default ++ ")->text\nreturn typ" ++ body_source ++ "\nend\nstruct Label\nvalue:text=typ" ++ record ++ "\nend\nlast=typ" ++ tail ++ "\n";
    calls: usize = 0,
    failure: ?anyerror = null,

    pub fn block(context: *anyopaque, remaining: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.failure) |err| return err;
        for (blocks) |value| if (std.mem.startsWith(u8, remaining, value)) return value.len;
        return error.UnexpectedTestBlock;
    }

    pub fn options(self: *@This()) Options {
        return .{ .source_parser = .{ .ptr = self, .vtable = &.{ .block = block } } };
    }
};

fn opaqueBlockAllocationExercise(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var fixture: OpaqueBlockFixture = .{};
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, fixture.calls);
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, parser.headers.?.source_blocks.len);
    try std.testing.expectEqualStrings("[Default [nested]]", script.statements[1].value.function.params[0].default.?.value.typst.code);
    try std.testing.expectEqualStrings("[Record /* ] end */ [nested]]", script.statements[2].value.structure.fields[0].default.?.value.typst.code);
    for (parser.headers.?.source_blocks, 0..) |block, index| {
        try std.testing.expectEqualStrings(OpaqueBlockFixture.blocks[index], OpaqueBlockFixture.input[block.start..block.end]);
        if (index != 0) try std.testing.expect(parser.headers.?.source_blocks[index - 1].end <= block.start);
    }
}

test "header scans reuse every native block range including function and record defaults" {
    try opaqueBlockAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), opaqueBlockAllocationExercise, .{});
}

test "native block ranges fall back on a different source identity or a missing entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try arena.allocator().dupe(u8, OpaqueBlockFixture.input);
    for (0..3) |mode| {
        var fixture: OpaqueBlockFixture = .{};
        var diagnostic: ?source.Diagnostic = null;
        var headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        if (mode == 1) headers.source_identity = OpaqueBlockFixture.input[0 .. OpaqueBlockFixture.input.len - 1];
        if (mode == 2) headers.source_blocks = &.{};
        var parser = try Parser.init(arena.allocator(), if (mode == 0) copied else OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        parser.headers = headers;
        _ = try parser.parse();
        try std.testing.expectEqual(2 * OpaqueBlockFixture.blocks.len, fixture.calls);
    }
}

test "reused native block ranges still require a provider context and valid closing range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: OpaqueBlockFixture = .{};
    var diagnostic: ?source.Diagnostic = null;
    const headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
    {
        const options: Options = .{};
        var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, options, &diagnostic);
        parser.headers = headers;
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "requires") != null);
    }
    const blocks = try arena.allocator().dupe(source.Span, headers.source_blocks);
    for ([_]usize{ 0, blocks[0].start + 1, blocks[0].start + 2, std.math.maxInt(usize) }) |invalid_end| {
        blocks[0].end = invalid_end;
        var parser = try Parser.init(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        parser.headers = headers;
        parser.headers.?.source_blocks = blocks;
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expectEqualStrings("Typst source-block provider returned an invalid range", diagnostic.?.text());
    }
    try std.testing.expectEqual(OpaqueBlockFixture.blocks.len, fixture.calls);
}

test "native block fallback preserves provider diagnostics and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copied = try arena.allocator().dupe(u8, OpaqueBlockFixture.input);
    for ([_]anyerror{ error.NativeBlockFailure, error.OutOfMemory }) |failure| {
        var fixture: OpaqueBlockFixture = .{};
        var diagnostic: ?source.Diagnostic = null;
        const headers = try scanHeaders(arena.allocator(), OpaqueBlockFixture.input, fixture.options(), &diagnostic);
        fixture.failure = failure;
        var parser = try Parser.init(arena.allocator(), copied, fixture.options(), &diagnostic);
        parser.headers = headers;
        try std.testing.expectError(if (failure == error.OutOfMemory) error.OutOfMemory else error.LanguageError, parser.parse());
        if (failure == error.OutOfMemory) {
            try std.testing.expect(diagnostic == null);
        } else {
            try std.testing.expectEqualStrings("cannot parse Typst block: NativeBlockFailure", diagnostic.?.text());
            try std.testing.expectEqual(failure, diagnostic.?.cause.?.source_block);
        }
        try std.testing.expectEqual(OpaqueBlockFixture.blocks.len + 1, fixture.calls);
    }
}
