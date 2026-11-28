//! The standalone language server's lifecycle, diagnostics, edits, completion, hover and formatting.
const std = @import("std");
const tooling = @import("huak_tooling");
const options = @import("test_options");
const t = std.testing;
const harness = @import("harness.zig");

test "standalone language server implements lifecycle diagnostics UTF16 edits completion hover and formatting" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    const help = try harness.runWithInput(a, &.{ executable, "--help" }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try t.expectEqualStrings("", help.stdout);
    try t.expect(std.mem.find(u8, help.stderr, "usage: huak-lsp") != null);
    const invalid = try harness.runWithInput(a, &.{ executable, "--help", "--unknown" }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 1 }, invalid.term);
    try t.expectEqualStrings("", invalid.stdout);
    const uri = "file:///tmp/huak-editor-%F0%9F%99%82.huak";
    var input: std.Io.Writer.Allocating = .init(a);
    const writer = &input.writer;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 0, .method = "textDocument/hover", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .languageId = "huak", .version = 1, .text = "fn f()->void\nvalue:=\"🙂\"; missing(1)\nend\n" } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .range = tooling.position.Range{ .start = .{ .line = 1, .character = 13 }, .end = .{ .line = 1, .character = 20 } }, .text = "print" }} } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 1, .character = 14 } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 4, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 1, .character = 14 } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/formatting", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didClose", .params = .{ .textDocument = .{ .uri = uri } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 6, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "input", .data = input.written() });
    const file = try temporary.dir.openFile(t.io, "input", .{});
    defer file.close(t.io);
    const result = try harness.runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
    try t.expectEqualStrings("", result.stderr);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    var reader = std.Io.Reader.fixed(result.stdout);
    var count: usize = 0;
    var first_diagnostic = false;
    var cleared_diagnostic = false;
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        count += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const response = parsed.value.object;
        if (response.get("id")) |id| switch (id.integer) {
            0 => try t.expectEqual(@as(i64, -32002), response.get("error").?.object.get("code").?.integer),
            1 => {
                const capabilities = response.get("result").?.object.get("capabilities").?.object;
                try t.expectEqualStrings("utf-16", capabilities.get("positionEncoding").?.string);
                const semantic = capabilities.get("semanticTokensProvider").?.object;
                try t.expect(semantic.get("full").?.bool);
                const kinds = semantic.get("legend").?.object.get("tokenTypes").?.array.items;
                try t.expectEqual(tooling.semantic_tokens.legend.tokenTypes.len, kinds.len);
                for (kinds, tooling.semantic_tokens.legend.tokenTypes) |kind, name| try t.expectEqualStrings(name, kind.string);
            },
            2 => try t.expectEqualStrings("fn f()->void\n    value := \"🙂\"; print(1)\nend\n", response.get("result").?.array.items[0].object.get("newText").?.string),
            3 => try t.expect(std.mem.find(u8, response.get("result").?.object.get("contents").?.object.get("value").?.string, "fn print(") != null),
            4 => {
                const items = response.get("result").?.object.get("items").?.array.items;
                try t.expect(items.len > 30);
                var has_do = false;
                var has_then = false;
                var has_math = false;
                var has_path = false;
                var has_mixfix = false;
                for (items) |item| {
                    const label = item.object.get("label").?.string;
                    try t.expect(!std.mem.eql(u8, label, "list") and !std.mem.eql(u8, label, "array") and !std.mem.eql(u8, label, "push") and !std.mem.eql(u8, label, "line"));
                    has_do = has_do or std.mem.eql(u8, label, "do");
                    has_then = has_then or std.mem.eql(u8, label, "then");
                    try t.expect(!std.mem.eql(u8, label, "paint") and !std.mem.eql(u8, label, "std"));
                    try t.expect(!std.mem.startsWith(u8, label, "std/"));
                    has_math = has_math or std.mem.eql(u8, label, "math");
                    has_mixfix = has_mixfix or std.mem.eql(u8, label, "mixfix");
                    if (std.mem.eql(u8, label, "path")) {
                        try t.expectEqualStrings("fn path(any...) -> path | shape", item.object.get("detail").?.string);
                        has_path = true;
                    }
                }
                try t.expect(has_do and has_then and has_math and has_path and has_mixfix);
            },
            5 => try t.expectEqual(@as(i64, -32602), response.get("error").?.object.get("code").?.integer),
            6 => try t.expect(response.get("result").? == .null),
            else => return error.UnexpectedResponse,
        } else {
            try t.expectEqualStrings("textDocument/publishDiagnostics", response.get("method").?.string);
            const p = response.get("params").?.object;
            const errors = p.get("diagnostics").?.array.items;
            if (errors.len != 0) {
                first_diagnostic = true;
                const start = errors[0].object.get("range").?.object.get("start").?.object;
                try t.expectEqual(@as(i64, 1), start.get("line").?.integer);
                try t.expectEqual(@as(i64, 13), start.get("character").?.integer);
            } else cleared_diagnostic = true;
        }
    }
    try t.expectEqual(@as(usize, 10), count);
    try t.expect(first_diagnostic and cleared_diagnostic);
}
