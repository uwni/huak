//! Language-server documents: failures belonging to requests, ranged changes, ownership across transport failure, and editor buffers over host imports.
const std = @import("std");
const tooling = @import("huak_tooling");
const t = std.testing;
const Frontend = tooling.Frontend;

test "embedded parser and import failures belong to the request that tried to use them" {
    const filename = "/tmp/huak-provider.huak";
    for ([_]anyerror{ error.LibraryNotFound, error.OutOfMemory }) |reason| {
        const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = reason };
        var first: ?tooling.compiler.Diagnostic = null;
        try t.expectError(if (reason == error.OutOfMemory) reason else error.LanguageError, frontend.check("x:=typ[hello]", filename, &first));
        var next: ?tooling.compiler.Diagnostic = null;
        try frontend.check("x:=1", filename, &next);
        try t.expect(next == null);
        try t.expectError(error.LanguageError, frontend.check("x:=typ nope", filename, &next));
        try t.expect(next.?.cause == null);
        try t.expectError(error.LanguageError, frontend.check("import \"missing-test-input/module.huak\" as module", filename, &next));
        try t.expectEqual(error.FileNotFound, next.?.cause.?.module_import);
        try t.expectEqual(reason, first.?.cause.?.unavailable_source_parser);
        try t.expectEqualStrings(filename, first.?.fileName().?);
    }
}

test "language server applies sequential ranged changes to the evolving document" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const uri = "file:///tmp/sequential-ranged-edits.huak";
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = "abcdef\n" } } }, .{}), &output.writer);
    const first = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    const second = tooling.position.Range{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 3 } };
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{ .{ .range = first, .text = "X" }, .{ .range = second, .text = "Y" } } } }, .{}), &output.writer);
    try t.expectEqualStrings("XaYcdef\n", session.documents.get(uri).?.text);
    try t.expectEqual(@as(i64, 2), session.documents.get(uri).?.version);
    const invalid = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 99 } };
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = .{ .{ .range = first, .text = "😀" }, .{ .range = invalid, .text = "Z" } } } }, .{}), &output.writer);
    try t.expectEqualStrings("XaYcdef\n", session.documents.get(uri).?.text);
    try t.expectEqual(@as(i64, 2), session.documents.get(uri).?.version);
    const astral = tooling.position.Range{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } };
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 4 }, .contentChanges = .{ .{ .text = "a😀b\n" }, .{ .range = astral, .text = "中" } } } }, .{}), &output.writer);
    try t.expectEqualStrings("a中b\n", session.documents.get(uri).?.text);
    try t.expectEqual(@as(i64, 4), session.documents.get(uri).?.version);
}

test "document ownership survives transport failure after opening and editing" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var broken_writer = std.Io.Writer.fixed(&.{});
    try t.expectError(error.WriteFailed, session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/owned.huak","version":1,"text":"x:=1"}}}
    , &broken_writer));
    try t.expectEqualStrings("x:=1", session.documents.get("file:///tmp/owned.huak").?.text);
    broken_writer = .fixed(&.{});
    try t.expectError(error.WriteFailed, session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/owned.huak","version":2},"contentChanges":[{"text":"x:=2"}]}}
    , &broken_writer));
    try t.expectEqualStrings("x:=2", session.documents.get("file:///tmp/owned.huak").?.text);
}

test "language server resolves editor buffers before host imports and rechecks dependants" {
    const Imports = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !tooling.compiler.ResolvedSource {
            if (std.mem.eql(u8, path, "host-input.huak")) return .{ .name = path, .source = "export offset:=1" };
            if (std.mem.eql(u8, path, "huak-unsaved-module.huak")) return .{ .name = path, .source = "export value:=\"shadowed\"" };
            return error.FileNotFound;
        }
    };
    var context: u8 = 0;
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .overlay = .{ .ptr = &context, .vtable = &.{ .resolve = Imports.resolve } } };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    try session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/huak-unsaved-module.huak","version":1,"text":"export value:=1"}}}
    , &output.writer);
    try session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/huak-unsaved-root.huak","version":1,"text":"import \"huak-unsaved-module.huak\" as module\nimport \"host-input.huak\" as host\nx:=module.value+host.offset"}}}
    , &output.writer);
    var input = std.Io.Reader.fixed(output.written());
    while (try tooling.lsp.readMessage(t.allocator, &input)) |body| {
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        try t.expectEqual(@as(usize, 0), parsed.value.object.get("params").?.object.get("diagnostics").?.array.items.len);
    }
    output.clearRetainingCapacity();
    try session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/huak-unsaved-module.huak","version":2},"contentChanges":[{"text":"export value:=\"bad\""}]}}
    , &output.writer);
    input = .fixed(output.written());
    var root_diagnostic = false;
    while (try tooling.lsp.readMessage(t.allocator, &input)) |body| {
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?.object;
        if (std.mem.eql(u8, params.get("uri").?.string, "file:///tmp/huak-unsaved-root.huak")) root_diagnostic = params.get("diagnostics").?.array.items.len != 0;
    }
    try t.expect(root_diagnostic);
}
