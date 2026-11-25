//! Definitions in the standalone language server: the standard module tree, native identities, unsaved reexports and virtual standard sources.
const std = @import("std");
const tooling = @import("huak_tooling");
const typst = @import("libtypst");
const options = @import("test_options");
const t = std.testing;
const Frontend = tooling.Frontend;
const harness = @import("harness.zig");

test "standalone language server resolves standard module tree and nested native identities" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    const uri = "file:///tmp/huak-standard-tree.huak";
    const source = "import std\nimport std.math.{cos as wave}\nanswer := std.math.sin(wave(0))\n";
    var input: std.Io.Writer.Allocating = .init(a);
    const writer = &input.writer;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(source, std.mem.indexOf(u8, source, "std.math.sin").? + "std.".len) } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(source, std.mem.indexOf(u8, source, "sin(wave").?) } });
    try definitionRequest(a, writer, 4, uri, source, "sin(wave");
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(source, std.mem.indexOf(u8, source, "wave(0)").?) } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 6, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "standard-tree-input", .data = input.written() });
    const file = try temporary.dir.openFile(t.io, "standard-tree-input", .{});
    defer file.close(t.io);
    const result = try harness.runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
    try t.expectEqualStrings("", result.stderr);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    var reader = std.Io.Reader.fixed(result.stdout);
    var received: [6]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value.object;
        const id = response.get("id") orelse {
            const diagnostics = response.get("params").?.object.get("diagnostics").?.array.items;
            try t.expectEqual(@as(usize, 0), diagnostics.len);
            continue;
        };
        const index: usize = @intCast(id.integer);
        try t.expect(index > 0 and index <= received.len and !received[index - 1]);
        received[index - 1] = true;
        switch (index) {
            1 => {},
            2 => {
                const items = response.get("result").?.object.get("items").?.array.items;
                var editor_library = try typst.Library.open(options.library_path);
                defer editor_library.deinit();
                const frontend: Frontend = .{ .allocator = a, .io = t.io, .source_parser = .init(&editor_library) };
                var diagnostic: ?tooling.compiler.Diagnostic = null;
                const graph = try frontend.graph(a, source, "/tmp/huak-standard-tree.huak", &diagnostic);
                const std_module = graph.resolveNamespace(graph.units.items[0], 0, "std") orelse return error.TestUnexpectedResult;
                const expected = &graph.units.items[std_module].public_names;
                try t.expect(expected.contains("weave"));
                for (items) |item| {
                    try t.expectEqual(@as(i64, 9), item.object.get("kind").?.integer);
                    try t.expect(expected.remove(item.object.get("label").?.string));
                }
                try t.expectEqual(@as(usize, 0), expected.count());
            },
            3, 5 => {
                const detail = response.get("result").?.object.get("contents").?.object.get("value").?.string;
                try t.expect(std.mem.startsWith(u8, detail, if (index == 3) "fn math.sin(" else "fn math.cos("));
            },
            4, 6 => try t.expect(response.get("result").? == .null),
            else => unreachable,
        }
    }
    for (received) |seen| try t.expect(seen);
}

test "standalone definitions follow unsaved reexports edits and virtual standard sources" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    const dependency = "file:///tmp/huak-definition-dependency.huak";
    const facade = "file:///tmp/huak-definition-facade.huak";
    const uri = "file:///tmp/huak-definition-root.huak";
    const original = "export fn increment(value:int)->int return value+1 end\n";
    const edited = "// unsaved\n\n" ++ original;
    const root = "import \"huak-definition-facade.huak\".bump as shifted\nimport assertions.assert\nlabel:=typ[Definition #text(\"shifted\")]\nemoji:=\"🙂\";result:=shifted(2)\nassert(true)\n";
    const std_uri = "huak-stdlib:/std/assertions.huak";
    // The public protocol supplies the embedded text; this fixture keeps a
    // matching small document open to verify virtual URI navigation itself.
    const virtual = "export fn assert(condition:bool,message:string)->void\nif not condition then panic(message) end\nend\n";
    var input: std.Io.Writer.Allocating = .init(a);
    const writer = &input.writer;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = dependency, .version = 1, .text = original } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = facade, .version = 1, .text = "import \"huak-definition-dependency.huak\".increment as bump\nexport bump\n" } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = root } } });
    try definitionRequest(a, writer, 2, uri, root, "shifted(2)");
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = dependency, .version = 2 }, .contentChanges = .{.{ .text = edited }} } });
    try definitionRequest(a, writer, 3, uri, root, "shifted(2)");
    try definitionRequest(a, writer, 4, uri, root, "assert(true)");
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 5, .method = "huak/standardSource", .params = .{ .uri = std_uri } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = std_uri, .version = 1, .text = virtual } } });
    try definitionRequest(a, writer, 6, std_uri, virtual, "condition then");
    try definitionRequest(a, writer, 7, uri, root, "shifted\"");
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 8, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 10000 } } });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = 9, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "definitions-input", .data = input.written() });
    const file = try temporary.dir.openFile(t.io, "definitions-input", .{});
    defer file.close(t.io);
    const result = try harness.runWithInput(a, &.{ executable, "--stdio", "--libtypst", options.library_path }, file);
    try t.expectEqualStrings("", result.stderr);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    var reader = std.Io.Reader.fixed(result.stdout);
    var received: [9]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value.object;
        const id = response.get("id") orelse continue;
        const index: usize = @intCast(id.integer);
        try t.expect(index > 0 and index <= received.len and !received[index - 1]);
        received[index - 1] = true;
        switch (index) {
            1 => try t.expect(response.get("result").?.object.get("capabilities").?.object.get("definitionProvider").?.bool),
            2, 3 => {
                const location = response.get("result").?.object;
                try t.expectEqualStrings(dependency, location.get("uri").?.string);
                const range = location.get("range").?.object;
                const start = range.get("start").?.object;
                const end = range.get("end").?.object;
                try t.expectEqual(@as(i64, if (index == 2) 0 else 2), start.get("line").?.integer);
                try t.expectEqual(@as(i64, 10), start.get("character").?.integer);
                try t.expectEqual(@as(i64, 19), end.get("character").?.integer);
            },
            4 => try t.expectEqualStrings(std_uri, response.get("result").?.object.get("uri").?.string),
            5 => {
                const source = response.get("result").?.string;
                try t.expect(std.mem.indexOf(u8, source, "export fn assert(") != null);
                try t.expect(std.mem.indexOf(u8, source, "panic(message)") != null);
            },
            6 => {
                const location = response.get("result").?.object;
                try t.expectEqualStrings(std_uri, location.get("uri").?.string);
                const start = location.get("range").?.object.get("start").?.object;
                try t.expectEqual(@as(i64, 0), start.get("line").?.integer);
                try t.expectEqual(@as(i64, 17), start.get("character").?.integer);
            },
            7, 9 => try t.expect(response.get("result").? == .null),
            8 => try t.expectEqual(@as(i64, -32602), response.get("error").?.object.get("code").?.integer),
            else => unreachable,
        }
    }
    for (received) |seen| try t.expect(seen);
}

fn definitionRequest(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: u32, uri: []const u8, source: []const u8, query: []const u8) !void {
    const offset = std.mem.lastIndexOf(u8, source, query) orelse return error.MissingTestQuery;
    try tooling.lsp.writeMessage(allocator, writer, .{ .jsonrpc = "2.0", .id = id, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(source, offset) } });
}
