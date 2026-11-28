//! End hints and picture export metadata from the standalone language server, without executing pictures.
const std = @import("std");
const tooling = @import("huak_tooling");
const options = @import("test_options");
const t = std.testing;
const harness = @import("harness.zig");

test "standalone language server returns end hints and picture export metadata without execution" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    const uri = "file:///tmp/huak-hints-exports.huak";
    const invalid = "export fn foo()->int\n if true then\n  return \"wrong\"\n else\n  return 2\n end\nend\n";
    const valid = "import paint.*;export fn foo()->int\n if true then\n  return 1\n else\n  return 2\n end\nend\nunexecuted:=1%0\nnot_picture:=3\nframe:=picture(640, 480)\nexport frame,not_picture\ndefault [frame][0]\n";
    var messages: std.Io.Writer.Allocating = .init(a);
    const writer = &messages.writer;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = invalid } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(invalid, invalid.len) } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 3, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = valid }} } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 4, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(valid, valid.len) } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 5, .character = 0 }, .end = .{ .line = 6, .character = 0 } } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 6, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 7, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "messages", .data = messages.written() });
    const file = try temporary.dir.openFile(t.io, "messages", .{});
    defer file.close(t.io);
    const result = try harness.runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try t.expectEqualStrings("", result.stderr);
    var input = std.Io.Reader.fixed(result.stdout);
    var seen: [8]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &input)) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const response = parsed.value;
        const id = response.object.get("id") orelse continue;
        const index: usize = @intCast(id.integer);
        if (index == 0 or index >= seen.len or seen[index]) return error.UnexpectedResponse;
        seen[index] = true;
        switch (index) {
            1 => try t.expect(response.object.get("result").?.object.get("capabilities").?.object.get("inlayHintProvider").?.bool),
            2, 4 => try harness.expectHintLabels(response, &.{ "if", "fn foo" }),
            3 => {
                const failure = response.object.get("error").?.object;
                try t.expectEqual(@as(i64, -32603), failure.get("code").?.integer);
                try t.expect(std.mem.find(u8, failure.get("message").?.string, "expected int") != null);
            },
            5 => try harness.expectHintLabels(response, &.{"if"}),
            6 => {
                const exports = response.object.get("result").?.object.get("outputs").?.array.items;
                try t.expectEqual(@as(usize, 2), exports.len);
                try t.expectEqualStrings("frame", exports[0].object.get("name").?.string);
                try t.expectEqualStrings("frame", exports[0].object.get("label").?.string);
                try t.expect(!exports[0].object.get("default").?.bool);
                try t.expectEqualStrings("default", exports[1].object.get("name").?.string);
                try t.expectEqualStrings("Default picture", exports[1].object.get("label").?.string);
                try t.expect(exports[1].object.get("default").?.bool);
            },
            7 => try t.expect(response.object.get("result").? == .null),
            else => unreachable,
        }
    }
    for (seen[1..]) |received| try t.expect(received);
}

test "standalone language server combines stable default aliases without executing pictures" {
    const Candidate = tooling.outputs.Candidate;
    const cases = [_]struct { source: []const u8, expected: []const Candidate }{
        .{ .source = "import paint.*;export chart:=picture(640, 480);default chart;export small:=picture(640, 480)", .expected = &.{
            .{ .name = "default", .label = "chart", .default = true },
            .{ .name = "small", .label = "small", .default = false },
        } },
        .{ .source = "import paint.*;export chart:=picture(640, 480);default chart", .expected = &.{
            .{ .name = "default", .label = "chart", .default = true },
        } },
        .{ .source = "import paint.*;export chart:=picture(640, 480);default chart;chart=picture(640, 480)", .expected = &.{
            .{ .name = "chart", .label = "chart", .default = false },
            .{ .name = "default", .label = "Default picture", .default = true },
        } },
        .{ .source = "import paint.*;default picture(640, 480)", .expected = &.{
            .{ .name = "default", .label = "Default picture", .default = true },
        } },
        .{ .source = "import paint.*;export chart:=picture(640, 480);default [chart][0]", .expected = &.{
            .{ .name = "chart", .label = "chart", .default = false },
            .{ .name = "default", .label = "Default picture", .default = true },
        } },
        .{ .source = "import \"default-metadata-library.huak\".{chart as figure};export figure;default figure", .expected = &.{
            .{ .name = "default", .label = "figure", .default = true },
        } },
    };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    var messages: std.Io.Writer.Allocating = .init(a);
    const writer = &messages.writer;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = "file:///tmp/default-metadata-library.huak", .version = 1, .text = "import paint.*;export chart:=picture(640, 480)" } } });
    for (cases, 0..) |case, index| {
        const uri = try a.print("file:///tmp/default-metadata-{d}.huak", .{index});
        const source = try a.print("{s};unexecuted:=1%0", .{case.source});
        try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } });
        try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = index + 2, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } });
    }
    const shutdown_id = cases.len + 2;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = shutdown_id, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "messages", .data = messages.written() });
    const file = try temporary.dir.openFile(t.io, "messages", .{});
    defer file.close(t.io);
    const result = try harness.runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try t.expectEqualStrings("", result.stderr);
    var input = std.Io.Reader.fixed(result.stdout);
    var seen: [cases.len]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &input)) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const response = parsed.value;
        const id = response.object.get("id") orelse continue;
        if (id.integer == 1 or id.integer == shutdown_id) continue;
        const index: usize = @intCast(id.integer - 2);
        if (index >= seen.len or seen[index]) return error.UnexpectedResponse;
        seen[index] = true;
        const exports = response.object.get("result").?.object.get("outputs").?.array.items;
        try t.expectEqual(cases[index].expected.len, exports.len);
        for (exports, cases[index].expected) |actual, expected| {
            try t.expectEqualStrings(expected.name, actual.object.get("name").?.string);
            try t.expectEqualStrings(expected.label, actual.object.get("label").?.string);
            try t.expectEqual(expected.default, actual.object.get("default").?.bool);
        }
    }
    for (seen) |received| try t.expect(received);
}
