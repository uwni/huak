//! Semantic colors and inlay hints.
const std = @import("std");
const tooling = @import("huak_tooling");
const typst = @import("libtypst");
const options = @import("test_options");
const t = std.testing;
const Frontend = tooling.Frontend;
const harness = @import("harness.zig");

test "semantic colors follow syntax scopes and mark only Huak reads in embedded content" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        "fn combine(a:int,b:int)->int return a+b end\r\n" ++
        "mixfix(combine) combine from _ as _ in unary\r\n" ++
        "fn twice(v:int)->int return v*2 end\r\n" ++
        "mixfix(twice) twice _ in unary\r\n" ++
        "fn shifted(a:int,b:int)->int return a+b end\r\n" ++
        "mixfix(shifted) _ shifted _ in addition\r\n" ++
        "from:=2;as:=3\r\n" ++
        "label:=\"🙂\"; answer:=combine from twice from as as // from as\r\n" ++
        "if true then\r\n" ++
        " mixfix(combine) combine left _ right _ in unary\r\n" ++
        " inner:=combine left from right (as shifted from)\r\n" ++
        "end\r\n" ++
        "outer:=combine from from as as\r\n";
    const data = try tooling.semantic_tokens.collect(&frontend, a, source, "/tmp/semantic-scopes.huak");
    try harness.expectSemanticRow(source, data, 1, &.{ .{ "combine", .function }, .{ "combine", .keyword }, .{ "from", .keyword }, .{ "_", .operator }, .{ "as", .keyword }, .{ "_", .operator } });
    try harness.expectSemanticRow(source, data, 5, &.{ .{ "shifted", .function }, .{ "_", .operator }, .{ "shifted", .keyword }, .{ "_", .operator } });
    try harness.expectSemanticRow(source, data, 7, &.{ .{ "combine", .function }, .{ "from", .keyword }, .{ "twice", .function }, .{ "from", .variable }, .{ "as", .keyword }, .{ "as", .variable } });
    try harness.expectSemanticRow(source, data, 10, &.{ .{ "combine", .function }, .{ "left", .keyword }, .{ "from", .variable }, .{ "right", .keyword }, .{ "as", .variable }, .{ "shifted", .function }, .{ "from", .variable } });
    try harness.expectSemanticRow(source, data, 12, &.{ .{ "combine", .function }, .{ "from", .keyword }, .{ "from", .variable }, .{ "as", .keyword }, .{ "as", .variable } });

    const qualified = "import paint as p\ncenter:=(0,0); radius:=2\np.circle with center center radius radius\nmixfix(p.circle) disk at _ radius _ in unary\n";
    const qualified_data = try tooling.semantic_tokens.collect(&frontend, a, qualified, "/tmp/semantic-qualified.huak");
    try harness.expectSemanticRow(qualified, qualified_data, 2, &.{ .{ "p", .namespace }, .{ "circle", .function }, .{ "with", .keyword }, .{ "center", .keyword }, .{ "center", .variable }, .{ "radius", .keyword }, .{ "radius", .variable } });
    try harness.expectSemanticRow(qualified, qualified_data, 3, &.{ .{ "p", .namespace }, .{ "circle", .function }, .{ "disk", .keyword }, .{ "at", .keyword }, .{ "_", .operator }, .{ "radius", .keyword }, .{ "_", .operator } });

    // Inside Typst code only the reads of Huak values are colored.
    const reads = "title:=\"T\"\ncaption:=typ[#huak.title #huak.missing $huak.title$ #title]\n";
    const reads_data = try tooling.semantic_tokens.collect(&frontend, a, reads, "/tmp/semantic-reads.huak");
    try harness.expectSemanticRow(reads, reads_data, 1, &.{ .{ "title", .variable }, .{ "title", .variable } });

    const example_path = "examples/language/mixfix.huak";
    const example = try std.Io.Dir.cwd().readFileAlloc(t.io, example_path, a, .unlimited);
    const example_data = try tooling.semantic_tokens.collect(&frontend, a, example, example_path);
    try harness.expectSemanticRow(example, example_data, 4, &.{ .{ "+", .operator }, .{ "draw", .function }, .{ "circle", .function }, .{ "with", .keyword }, .{ "center", .keyword }, .{ "radius", .keyword } });
    try harness.expectSemanticRow(example, example_data, 6, &.{ .{ "+", .operator }, .{ "draw", .function }, .{ "with", .keyword }, .{ "pen", .function }, .{ "with", .keyword }, .{ "color", .keyword }, .{ "blue", .variable }, .{ "width", .keyword } });
    try harness.expectSemanticRow(example, example_data, 7, &.{ .{ "+", .operator }, .{ "at", .function } });
    try t.expectEqual(@as(usize, 0), (try tooling.semantic_tokens.collect(&frontend, a, "x:=(", "/tmp/semantic-incomplete.huak")).len);
}

test "inlay hints use syntax imports native Typst and UTF16 positions across edits" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const uri = "file:///tmp/huak-inlay-root.huak";
    const source =
        \\import drawing.drawing
        \\import "huak-inlay-dependency.huak".{wrap as enclosed}
        \\export fn bad()->int
        \\    if wrap 1 > 0 then
        \\        label:=typ[end #text("end")]
        \\    text:="🙂"; end
        \\end
        \\fn inline() end
        \\drawing pic do
        \\    for i in 1:2 do
        \\        while false do
        \\        end
        \\    end
        \\end
        \\precedence custom
        \\    above addition
        \\end
    ;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = "file:///tmp/huak-inlay-dependency.huak", .version = 1, .text = "export wrap;mixfix(wrap) wrap _ in addition;fn wrap(x:int)->int return x end" } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } }, .{}), &output.writer);
    const range: tooling.position.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(source, source.len) };
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 11, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = range } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 12, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 5, .character = 0 }, .end = .{ .line = 6, .character = 0 } } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 15, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 5, .character = 12 }, .end = .{ .line = 5, .character = 19 } } } }, .{}), &output.writer);
    const changed = "while true do\n break\nend\n";
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = changed }} } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 13, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(changed, changed.len) } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = .{.{ .text = "while true do" }} } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 14, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 13 } } } }, .{}), &output.writer);
    var input = std.Io.Reader.fixed(output.written());
    var responses: usize = 0;
    while (try tooling.lsp.readMessage(t.allocator, &input)) |body| {
        defer t.allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
        defer parsed.deinit();
        const response = parsed.value;
        const id = response.object.get("id") orelse continue;
        responses += 1;
        switch (id.integer) {
            11 => {
                try harness.expectHintLabels(response, &.{ "if", "fn bad", "while", "for i", "drawing pic", "precedence custom" });
                const hint = response.object.get("result").?.array.items[0].object;
                const end = hint.get("position").?.object;
                try t.expectEqual(@as(i64, 5), end.get("line").?.integer);
                try t.expectEqual(@as(i64, 19), end.get("character").?.integer);
                const location = hint.get("label").?.array.items[0].object.get("location").?.object;
                try t.expectEqualStrings(uri, location.get("uri").?.string);
                try t.expectEqual(@as(i64, 3), location.get("range").?.object.get("start").?.object.get("line").?.integer);
            },
            12 => try harness.expectHintLabels(response, &.{"if"}),
            13 => try harness.expectHintLabels(response, &.{"while"}),
            14 => try harness.expectHintLabels(response, &.{}),
            15 => try t.expectEqual(@as(i64, -32602), response.object.get("error").?.object.get("code").?.integer),
            else => return error.UnexpectedResponse,
        }
    }
    try t.expectEqual(@as(usize, 5), responses);
    try t.expect(frontend.overlay == null);
}
