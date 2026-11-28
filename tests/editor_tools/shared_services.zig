//! Services sharing one analysis: Typst reads across formatting, navigation, completion, hints and export, and mixfix metadata across unsaved imports.
const std = @import("std");
const tooling = @import("huak_tooling");
const typst = @import("libtypst");
const options = @import("test_options");
const t = std.testing;
const Frontend = tooling.Frontend;
const harness = @import("harness.zig");

test "Typst reads share formatting navigation completion hints and export services" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = "file:///tmp/typst-editor.huak";
    const input = "title:=\"Figure\"\ncount:=2\ncaption:=typ[#huak.title #huak.count]\nfn echo(title:string)->text\nreturn typ[#huak.title]\nend\nimport paint.*\nexport stage:=picture(640, 480)\n";
    const expected = "title := \"Figure\"\ncount := 2\ncaption := typ[#huak.title #huak.count]\nfn echo(title:string)->text\n    return typ[#huak.title]\nend\nimport paint.*\nexport stage := picture(640, 480)\n";
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = input } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } }, .{}), writer);
    const offset = std.mem.find(u8, input, "count]").?;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, offset) } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 0 } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 4, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(input, input.len) } } }, .{}), writer);
    var reader = std.Io.Reader.fixed(output.written());
    var seen: [5]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value;
        const id = response.object.get("id") orelse continue;
        const index: usize = @intCast(id.integer);
        try t.expect(index > 0 and index <= seen.len and !seen[index - 1]);
        seen[index - 1] = true;
        switch (index) {
            1 => try t.expectEqualStrings(expected, response.object.get("result").?.array.items[0].object.get("newText").?.string),
            2 => {
                const location = response.object.get("result").?.object;
                try t.expectEqualStrings(uri, location.get("uri").?.string);
                const start = location.get("range").?.object.get("start").?.object;
                try t.expectEqual(@as(i64, 1), start.get("line").?.integer);
                try t.expectEqual(@as(i64, 0), start.get("character").?.integer);
            },
            3 => {
                var found: [2]bool = @splat(false);
                for (response.object.get("result").?.object.get("items").?.array.items) |item| {
                    const label = item.object.get("label").?.string;
                    for ([_][]const u8{ "typ.module", "typ.show" }, &found) |form, *seen_form| if (std.mem.eql(u8, label, form)) {
                        seen_form.* = true;
                        try t.expectEqual(@as(i64, 14), item.object.get("kind").?.integer);
                    };
                    try t.expect(!std.mem.eql(u8, label, "typst_expose") and !std.mem.eql(u8, label, "typst_fn"));
                }
                try t.expect(found[0] and found[1]);
            },
            4 => {
                const exports = response.object.get("result").?.object.get("outputs").?.array.items;
                try t.expectEqual(@as(usize, 1), exports.len);
                try t.expectEqualStrings("stage", exports[0].object.get("name").?.string);
            },
            5 => try harness.expectHintLabels(response, &.{"fn echo"}),
            else => unreachable,
        }
    }
    for (seen) |received| try t.expect(received);
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, expected, "/tmp/typst-editor.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
}

test "language server shares mixfix metadata across unsaved imports formatting and picture discovery" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    var directory = t.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(t.io, .{ .sub_path = "mixfix-editor-library.huak", .data = "export old_disk_value := 0" });
    try directory.dir.symLink(t.io, "mixfix-editor-library.huak", "editor-alias.huak", .{});
    const base = try directory.dir.realPathFileAlloc(t.io, ".", a);
    const dependency = try tooling.definition.uriForPath(a, try std.Io.Dir.path.join(a, &.{ base, "editor-alias.huak" }));
    const uri = try tooling.definition.uriForPath(a, try std.Io.Dir.path.join(a, &.{ base, "mixfix-editor-root.huak" }));
    const module = "export fn combine_digits(left:int,right:int)->int return left*10+right end\nmixfix(combine_digits) digits from _ to _ in unary\n";
    const changed_module = "export fn combine_digits(left:int,right:int)->int return left*10+right end\nmixfix(combine_digits) digits from _ plus _ in unary\n";
    const source = "import paint.*;import \"mixfix-editor-library.huak\".combine_digits as digits\nfn figure()->picture\nvalue:=digits from 2 to 3\nreturn picture(640, 480)\nend\nexport circle\nexport plate:=figure();default plate\n";
    const changed_source = "import paint.*;import \"mixfix-editor-library.huak\".combine_digits as digits\nfn figure()->picture\nvalue:=digits from 2 plus 3\nreturn picture(640, 480)\nend\nexport circle\nexport plate:=figure();default plate\n";
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = dependency, .version = 1, .text = module } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.Position{ .line = 0, .character = 0 } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 3, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 6, .method = "textDocument/semanticTokens/full", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = dependency, .version = 2 }, .contentChanges = .{.{ .text = changed_module }} } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 4, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = changed_source }} } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 5, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 7, .method = "textDocument/semanticTokens/full", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), &output.writer);
    var input = std.Io.Reader.fixed(output.written());
    var received: [7]bool = @splat(false);
    var diagnosed = false;
    var recovered = false;
    while (try tooling.lsp.readMessage(a, &input)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value.object;
        if (response.get("id")) |id| {
            const index: usize = @intCast(id.integer);
            if (index == 0 or index > received.len or received[index - 1]) return error.UnexpectedResponse;
            received[index - 1] = true;
            switch (index) {
                1 => {
                    var found = false;
                    for (response.get("result").?.object.get("items").?.array.items) |item| {
                        const label = item.object.get("label").?.string;
                        if (std.mem.eql(u8, label, "mixfix")) {
                            found = true;
                            try t.expectEqual(@as(i64, 14), item.object.get("kind").?.integer);
                        }
                    }
                    try t.expect(found);
                },
                2 => try t.expect(std.mem.find(u8, response.get("result").?.array.items[0].object.get("newText").?.string, "    value := digits from 2 to 3\n") != null),
                3, 5 => {
                    const exports = response.get("result").?.object.get("outputs").?.array.items;
                    try t.expectEqual(@as(usize, 1), exports.len);
                    try t.expectEqualStrings("plate", exports[0].object.get("label").?.string);
                    try t.expect(exports[0].object.get("default").?.bool);
                },
                4 => try t.expectEqual(@as(i64, -32603), response.get("error").?.object.get("code").?.integer),
                6, 7 => {
                    const values = response.get("result").?.object.get("data").?.array.items;
                    const data = try a.alloc(u32, values.len);
                    for (values, data) |value, *number| number.* = @intCast(value.integer);
                    try harness.expectSemanticRow(if (index == 6) source else changed_source, data, 2, &.{ .{ "digits", .function }, .{ "from", .keyword }, .{ if (index == 6) "to" else "plus", .keyword } });
                },
                else => unreachable,
            }
        } else {
            const params = response.get("params").?.object;
            if (std.mem.eql(u8, params.get("uri").?.string, uri)) {
                if (params.get("diagnostics").?.array.items.len != 0) diagnosed = true else if (diagnosed) recovered = true;
            }
        }
    }
    for (received) |seen| try t.expect(seen);
    try t.expect(diagnosed and recovered);
    try t.expect(frontend.overlay == null);
}
