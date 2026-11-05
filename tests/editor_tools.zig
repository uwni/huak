//! Real standalone formatter and stdio language-server acceptance.
const std = @import("std");
const tooling = @import("huak_tooling");
const options = @import("test_options");
const t = std.testing;
const Frontend = tooling.Frontend;

test "formatter preserves Typst bytes comments and semantics and is idempotent" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = options.library_path };
    defer frontend.deinit();
    const native = "[\n    ```typ\n ] end   \n```\n #box[Inner]\n]";
    const input = "setup_typst {let word=[Hello]}\nexport fn make()->text\n// retained comment\nreturn typ" ++ native ++ "\nend   \nexport fn gather(values...)->list\nreturn values\nend\n";
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/format.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expect(std.mem.indexOf(u8, formatted, "    // retained comment\n    return typ" ++ native) != null);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/format.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    var program = try frontend.compile(formatted, "/tmp/format.huak", &diagnostic);
    defer program.deinit();
    try t.expectError(error.LanguageError, tooling.format.format(&frontend, "fn broken(\n", "/tmp/broken.huak", &diagnostic));
}

test "formatter preserves native regions while formatting a closing line suffix" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = options.library_path };
    defer frontend.deinit();
    const input =
        "fn labels()->list\n" ++
        "first:=typ[\n  Keep =  a,b\n]; second:=typ[Second]; values:=[1,2] // retain = a,b   \n" ++
        "return [first,second,typ[Third],typ[\n Keep = c,d\n]]\nend\n";
    const expected =
        "fn labels()->list\n" ++
        "    first := typ[\n  Keep =  a,b\n]; second := typ[Second]; values := [1, 2] // retain = a,b   \n" ++
        "    return [first, second, typ[Third], typ[\n Keep = c,d\n]]\nend\n";
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/opaque-format.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/opaque-format.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    var program = try frontend.compile(formatted, "/tmp/opaque-format.huak", &diagnostic);
    defer program.deinit();
}

test "formatter preserves explicit control headers and inline bodies" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const input =
        \\import paint.*
        \\precedence extra above addition; associativity left end
        \\export fn count()->int
        \\total:=0
        \\for i in 1:3 do
        \\if i==1 then total=total+1
        \\elseif i==2 then total=total+2
        \\else total=total+3 end
        \\end
        \\while total<10 do total=total+1 end
        \\return total
        \\end
        \\fn inline()->int if true then return 1 else return 2 end end
        \\pic:=picture(640, 480);drawing pic do +draw (0,0)--(1,1) end
        \\default drawing picture(20,20) do
        \\for key in {"a":1}.keys() do
        \\+fill (0,0)--(1,0)--(1,1)--cycle
        \\end
        \\end
    ;
    const expected =
        \\import paint.*
        \\precedence extra above addition; associativity left end
        \\export fn count()->int
        \\    total := 0
        \\    for i in 1:3 do
        \\        if i == 1 then total = total+1
        \\        elseif i == 2 then total = total+2
        \\        else total = total+3 end
        \\    end
        \\    while total < 10 do total = total+1 end
        \\    return total
        \\end
        \\fn inline()->int if true then return 1 else return 2 end end
        \\pic := picture(640, 480);drawing pic do +draw (0, 0)--(1, 1) end
        \\default drawing picture(20, 20) do
        \\    for key in {"a": 1}.keys() do
        \\        +fill (0, 0)--(1, 0)--(1, 1)--cycle
        \\    end
        \\end
        \\
    ;
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/control-format.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/control-format.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    try t.expect(frontend.native == null);
}

test "exposure declarations share formatting navigation completion hints and export services" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = "file:///tmp/expose-editor.huak";
    const input = "title:=\"Figure\"\ncount:=2\ntypst_expose title,count\nfn echo(title:string)->string\ntypst_expose title\nreturn title\nend\nimport paint.*\nexport stage:=picture(640, 480)\n";
    const expected = "title := \"Figure\"\ncount := 2\ntypst_expose title, count\nfn echo(title:string)->string\n    typst_expose title\n    return title\nend\nimport paint.*\nexport stage := picture(640, 480)\n";
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = input } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } }, .{}), writer);
    const offset = std.mem.indexOf(u8, input, "title,count").? + "title,".len;
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
                var found = false;
                for (response.object.get("result").?.object.get("items").?.array.items) |item| {
                    const label = item.object.get("label").?.string;
                    if (std.mem.eql(u8, label, "typst_expose")) {
                        found = true;
                        try t.expectEqual(@as(i64, 14), item.object.get("kind").?.integer);
                    }
                    try t.expect(!std.mem.eql(u8, label, "expose") and !std.mem.eql(u8, label, "using"));
                }
                try t.expect(found);
            },
            4 => {
                const exports = response.object.get("result").?.object.get("outputs").?.array.items;
                try t.expectEqual(@as(usize, 1), exports.len);
                try t.expectEqualStrings("stage", exports[0].object.get("name").?.string);
            },
            5 => try expectHintLabels(response, &.{"fn echo"}),
            else => unreachable,
        }
    }
    for (seen) |received| try t.expect(received);
    try t.expect(frontend.native == null);
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, expected, "/tmp/expose-editor.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
}

test "formatter preserves scoped mixfix declarations and call labels" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const input =
        \\import paint.*
        \\fn combine_digits(left:int,right:int)->int return left*10+right end
        \\mixfix(combine_digits) combine_digits from _ to _ in unary
        \\fn figure()->picture
        \\if true then
        \\mixfix(combine_digits) combine_digits left _ right _ in unary
        \\inside:=combine_digits left 2 right 3
        \\end
        \\outside:=combine_digits from 4 to 5
        \\return picture(640, 480)
        \\end
        \\default figure()
    ;
    const expected =
        \\import paint.*
        \\fn combine_digits(left:int, right:int)->int return left*10+right end
        \\mixfix(combine_digits) combine_digits from _ to _ in unary
        \\fn figure()->picture
        \\    if true then
        \\        mixfix(combine_digits) combine_digits left _ right _ in unary
        \\        inside := combine_digits left 2 right 3
        \\    end
        \\    outside := combine_digits from 4 to 5
        \\    return picture(640, 480)
        \\end
        \\default figure()
        \\
    ;
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/mixfix-format.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/mixfix-format.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    try t.expect(frontend.native == null);
}

test "envelope tooling uses builtin metadata for signatures and preserves imported mixfix formatting" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const source = "import paint.*;import pen.pensquare;import paint.envelope as side\nbrush:=pensquare(4pt)\ncurve:=(0,0)--(20,0)\nedge:=envelope of curve with brush\nplain:=envelope(curve,brush,0.01pt)\n";
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, source, "/tmp/envelope-editor.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expect(std.mem.indexOf(u8, formatted, "edge := envelope of curve with brush") != null);
    try t.expect(std.mem.indexOf(u8, formatted, "plain := envelope(curve, brush, 0.01pt)") != null);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/envelope-editor.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = "file:///tmp/envelope-editor.huak";
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 4, .character = 8 } } }, .{}), &output.writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 4, .character = 8 } } }, .{}), &output.writer);
    var reader = std.Io.Reader.fixed(output.written());
    var completion = false;
    var hover = false;
    const signature = "fn pen.envelope(curve: path, pen: pen, tolerance: length?) -> path";
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value;
        const id = response.object.get("id") orelse continue;
        if (id.integer == 1) {
            for (response.object.get("result").?.object.get("items").?.array.items) |item| if (std.mem.eql(u8, item.object.get("label").?.string, "envelope")) {
                try t.expectEqualStrings(signature, item.object.get("detail").?.string);
                completion = true;
            };
        } else if (id.integer == 2) {
            try t.expectEqualStrings(signature, response.object.get("result").?.object.get("contents").?.object.get("value").?.string);
            hover = true;
        }
    }
    try t.expect(completion and hover and frontend.native == null);
}

test "language server applies sequential ranged changes to the evolving document" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
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
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 3 }, .contentChanges = .{.{ .range = invalid, .text = "Z" }} } }, .{}), &output.writer);
    try t.expectEqualStrings("XaYcdef\n", session.documents.get(uri).?.text);
    try t.expectEqual(@as(i64, 2), session.documents.get(uri).?.version);
}

test "language server shares mixfix metadata across unsaved imports formatting and picture discovery" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const dependency = "file:///tmp/mixfix-editor-library.huak";
    const uri = "file:///tmp/mixfix-editor-root.huak";
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
                2 => try t.expect(std.mem.indexOf(u8, response.get("result").?.array.items[0].object.get("newText").?.string, "    value := digits from 2 to 3\n") != null),
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
                    try expectSemanticRow(if (index == 6) source else changed_source, data, 2, &.{ .{ "digits", .function }, .{ "from", .keyword }, .{ if (index == 6) "to" else "plus", .keyword } });
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
    try t.expect(frontend.native == null);
    try t.expect(frontend.overlay == null);
}

test "mixfix semantic colors follow syntax scopes and leave embedded content untouched" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = options.library_path };
    defer frontend.deinit();
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
    try expectSemanticRow(source, data, 1, &.{ .{ "combine", .function }, .{ "combine", .keyword }, .{ "from", .keyword }, .{ "_", .operator }, .{ "as", .keyword }, .{ "_", .operator } });
    try expectSemanticRow(source, data, 5, &.{ .{ "shifted", .function }, .{ "_", .operator }, .{ "shifted", .keyword }, .{ "_", .operator } });
    try expectSemanticRow(source, data, 7, &.{ .{ "combine", .function }, .{ "from", .keyword }, .{ "twice", .function }, .{ "from", .variable }, .{ "as", .keyword }, .{ "as", .variable } });
    try expectSemanticRow(source, data, 10, &.{ .{ "combine", .function }, .{ "left", .keyword }, .{ "from", .variable }, .{ "right", .keyword }, .{ "as", .variable }, .{ "shifted", .function }, .{ "from", .variable } });
    try expectSemanticRow(source, data, 12, &.{ .{ "combine", .function }, .{ "from", .keyword }, .{ "from", .variable }, .{ "as", .keyword }, .{ "as", .variable } });

    const qualified = "import paint as p\ncenter:=(0,0); radius:=2\np.circle with center center radius radius\nmixfix(p.circle) disk at _ radius _ in unary\n";
    const qualified_data = try tooling.semantic_tokens.collect(&frontend, a, qualified, "/tmp/semantic-qualified.huak");
    try expectSemanticRow(qualified, qualified_data, 2, &.{ .{ "p", .namespace }, .{ "circle", .function }, .{ "with", .keyword }, .{ "center", .keyword }, .{ "center", .variable }, .{ "radius", .keyword }, .{ "radius", .variable } });
    try expectSemanticRow(qualified, qualified_data, 3, &.{ .{ "p", .namespace }, .{ "circle", .function }, .{ "disk", .keyword }, .{ "at", .keyword }, .{ "_", .operator }, .{ "radius", .keyword }, .{ "_", .operator } });

    const example_path = "examples/language/mixfix.huak";
    const example = try std.Io.Dir.cwd().readFileAlloc(t.io, example_path, a, .unlimited);
    const example_data = try tooling.semantic_tokens.collect(&frontend, a, example, example_path);
    try expectSemanticRow(example, example_data, 4, &.{ .{ "+", .operator }, .{ "draw", .function }, .{ "circle", .function }, .{ "with", .keyword }, .{ "center", .keyword }, .{ "radius", .keyword } });
    try expectSemanticRow(example, example_data, 6, &.{ .{ "+", .operator }, .{ "draw", .function }, .{ "with", .keyword }, .{ "pen", .function }, .{ "with", .keyword }, .{ "color", .keyword }, .{ "blue", .variable }, .{ "width", .keyword } });
    try expectSemanticRow(example, example_data, 7, &.{ .{ "+", .operator }, .{ "at", .function } });
    try t.expectEqual(@as(usize, 0), (try tooling.semantic_tokens.collect(&frontend, a, "x:=(", "/tmp/semantic-incomplete.huak")).len);
}

fn expectSemanticRow(source: []const u8, data: []const u32, line: usize, expected: []const struct { []const u8, tooling.semantic_tokens.Kind }) !void {
    try t.expectEqual(@as(usize, 0), data.len % 5);
    var position: tooling.position.Position = .{ .line = 0, .character = 0 };
    var end: usize = 0;
    var found: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 5) {
        position.line += data[i];
        position.character = if (data[i] == 0) position.character + data[i + 1] else data[i + 1];
        const start = tooling.position.offset(source, position) orelse return error.InvalidTokenPosition;
        try t.expect(start >= end);
        end = tooling.position.offset(source, .{ .line = position.line, .character = position.character + data[i + 2] }) orelse return error.InvalidTokenPosition;
        if (position.line != line) continue;
        try t.expect(found < expected.len);
        try t.expectEqualStrings(expected[found][0], source[start..end]);
        try t.expectEqual(@as(u32, @backingInt(expected[found][1])), data[i + 3]);
        try t.expectEqual(@as(u32, 0), data[i + 4]);
        found += 1;
    }
    try t.expectEqual(expected.len, found);
}

fn runWithInput(allocator: std.mem.Allocator, argv: []const []const u8, input: ?std.Io.File) !std.process.RunResult {
    var child = try std.process.spawn(t.io, .{ .argv = argv, .stdin = if (input) |file| .{ .file = file } else .ignore, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(t.io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, t.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(256, .none)) |_| {
        if (reader.reader(0).buffered().len > 1024 * 1024 or reader.reader(1).buffered().len > 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(t.io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    return .{ .term = term, .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
}

test "document ownership survives transport failure after opening and editing" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
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
    try t.expect(frontend.native == null);
}

test "language server checks unsaved imports and rechecks dependants after edits" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    try session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/huak-unsaved-module.huak","version":1,"text":"export value:=1"}}}
    , &output.writer);
    try session.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/huak-unsaved-root.huak","version":1,"text":"import \"huak-unsaved-module.huak\" as module\nx:=module.value+1"}}}
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
    try t.expect(frontend.overlay == null);
}

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
    const result = try runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
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
                var frontend: Frontend = .{ .allocator = a, .io = t.io, .library_path = options.library_path };
                defer frontend.deinit();
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

fn expectHintLabels(response: std.json.Value, expected: []const []const u8) !void {
    const hints = response.object.get("result").?.array.items;
    try t.expectEqual(expected.len, hints.len);
    for (hints, expected) |hint, label| {
        const parts = hint.object.get("label").?.array.items;
        try t.expectEqual(@as(usize, 1), parts.len);
        try t.expectEqualStrings(label, parts[0].object.get("value").?.string);
        try t.expect(parts[0].object.get("location") != null);
        try t.expect(hint.object.get("paddingLeft").?.bool);
    }
}

test "inlay hints use syntax imports native Typst and UTF16 positions across edits" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = options.library_path };
    defer frontend.deinit();
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
                try expectHintLabels(response, &.{ "if", "fn bad", "while", "for i", "drawing pic", "precedence custom" });
                const hint = response.object.get("result").?.array.items[0].object;
                const end = hint.get("position").?.object;
                try t.expectEqual(@as(i64, 5), end.get("line").?.integer);
                try t.expectEqual(@as(i64, 19), end.get("character").?.integer);
                const location = hint.get("label").?.array.items[0].object.get("location").?.object;
                try t.expectEqualStrings(uri, location.get("uri").?.string);
                try t.expectEqual(@as(i64, 3), location.get("range").?.object.get("start").?.object.get("line").?.integer);
            },
            12 => try expectHintLabels(response, &.{"if"}),
            13 => try expectHintLabels(response, &.{"while"}),
            14 => try expectHintLabels(response, &.{}),
            15 => try t.expectEqual(@as(i64, -32602), response.object.get("error").?.object.get("code").?.integer),
            else => return error.UnexpectedResponse,
        }
    }
    try t.expectEqual(@as(usize, 5), responses);
    try t.expect(frontend.native != null);
    try t.expect(frontend.overlay == null);
}

test "standalone formatter check stdin and invalid-file protection use the actual binary" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(t.io, &directory_buffer);
    const path = try std.fs.path.join(a, &.{ directory_buffer[0..n], "script.huak" });
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.formatter_path, a);
    const input = "fn foo()->list\nvalues:=[1,2]\nvalues+=3\nreturn values\nend\n";
    const expected = "fn foo()->list\n    values := [1, 2]\n    values += 3\n    return values\nend\n";
    try temporary.dir.writeFile(t.io, .{ .sub_path = "script.huak", .data = input });
    const check = try runWithInput(a, &.{ executable, "--libtypst", "/missing-unused-library", "--check", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 1 }, check.term);
    try t.expectEqualStrings(input, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const displayed = try runWithInput(a, &.{ executable, "--stdout", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, displayed.term);
    try t.expectEqualStrings(expected, displayed.stdout);
    try t.expectEqualStrings(input, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const fixed = try runWithInput(a, &.{ executable, path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, fixed.term);
    try t.expectEqualStrings(expected, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const clean = try runWithInput(a, &.{ executable, "--check", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, clean.term);
    const file = try temporary.dir.openFile(t.io, "script.huak", .{});
    defer file.close(t.io);
    const stdin = try runWithInput(a, &.{ executable, "--stdin" }, file);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, stdin.term);
    try t.expectEqualStrings(expected, stdin.stdout);
    const invalid = "fn broken(\n";
    try temporary.dir.writeFile(t.io, .{ .sub_path = "script.huak", .data = invalid });
    const failure = try runWithInput(a, &.{ executable, path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 1 }, failure.term);
    try t.expectEqualStrings(invalid, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
}

test "standalone language server implements lifecycle diagnostics UTF16 edits completion hover and formatting" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.language_server_path, a);
    const help = try runWithInput(a, &.{ executable, "--help" }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try t.expectEqualStrings("", help.stdout);
    try t.expect(std.mem.indexOf(u8, help.stderr, "usage: huak-lsp") != null);
    const invalid = try runWithInput(a, &.{ executable, "--help", "--unknown" }, null);
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
    const result = try runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
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
            3 => try t.expect(std.mem.indexOf(u8, response.get("result").?.object.get("contents").?.object.get("value").?.string, "fn print(") != null),
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
                        try t.expectEqualStrings("fn path(any...) -> path", item.object.get("detail").?.string);
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
    const result = try runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
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
            2, 4 => try expectHintLabels(response, &.{ "if", "fn foo" }),
            3 => {
                const failure = response.object.get("error").?.object;
                try t.expectEqual(@as(i64, -32603), failure.get("code").?.integer);
                try t.expect(std.mem.indexOf(u8, failure.get("message").?.string, "expected int") != null);
            },
            5 => try expectHintLabels(response, &.{"if"}),
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
        const uri = try std.fmt.allocPrint(a, "file:///tmp/default-metadata-{d}.huak", .{index});
        const source = try std.fmt.allocPrint(a, "{s};unexecuted:=1%0", .{case.source});
        try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = source } } });
        try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = index + 2, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } });
    }
    const shutdown_id = cases.len + 2;
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .id = shutdown_id, .method = "shutdown", .params = @as(?bool, null) });
    try tooling.lsp.writeMessage(a, writer, .{ .jsonrpc = "2.0", .method = "exit", .params = @as(?bool, null) });
    try temporary.dir.writeFile(t.io, .{ .sub_path = "messages", .data = messages.written() });
    const file = try temporary.dir.openFile(t.io, "messages", .{});
    defer file.close(t.io);
    const result = try runWithInput(a, &.{ executable, "--stdio", "--libtypst", "/missing-unused-library" }, file);
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
    const result = try runWithInput(a, &.{ executable, "--stdio", "--libtypst", options.library_path }, file);
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

test "record editor services share fields named arguments formatting and nominal type exports" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = "file:///tmp/record-editor.huak";
    const input = "export struct Widget\nwidth:int=2\nvalues:list=[1]\nend\nitem:=Widget(width:3)\nitem.width=4\nitem.values+=2\noptions:={\"title\":\"Ω\"}\noptions[\"title\"]=\"changed\"\nvalue:=item.width\nfn read(target:Widget)->int\nreturn target.width\nend\nresult:=read(target:item)\nangle:=math.PI\ncomputed:=math.sin(0)\n";
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = input } } }, .{}), writer);
    const field_offset = std.mem.indexOf(u8, input, "width:3").?;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, field_offset) } }, .{}), writer);
    const label_offset = std.mem.lastIndexOf(u8, input, "target:item").?;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, label_offset) } }, .{}), writer);
    const member_offset = std.mem.indexOf(u8, input, "value:=item.width").? + "value:=item.width".len;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, member_offset) } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 4, .method = "huak/outputs", .params = .{ .textDocument = .{ .uri = uri } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/inlayHint", .params = .{ .textDocument = .{ .uri = uri }, .range = tooling.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = tooling.position.at(input, input.len) } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 6, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 7, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 0 } } }, .{}), writer);
    const math_offset = std.mem.indexOf(u8, input, "sin(0)").?;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 8, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, math_offset) } }, .{}), writer);
    const math_member = std.mem.indexOf(u8, input, "math.PI").? + "math.PI".len;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 9, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, math_member) } }, .{}), writer);
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 10, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, math_offset) } }, .{}), writer);
    var reader = std.Io.Reader.fixed(output.written());
    var seen: [10]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value.object;
        const id = response.get("id") orelse continue;
        const index: usize = @intCast(id.integer);
        try t.expect(index > 0 and index <= seen.len and !seen[index - 1]);
        seen[index - 1] = true;
        const result = response.get("result") orelse return error.UnexpectedErrorResponse;
        switch (index) {
            1 => try t.expectEqualStrings("Widget.width: int", result.object.get("contents").?.object.get("value").?.string),
            2 => {
                const destination = std.mem.indexOf(u8, input, "target:Widget").?;
                const position = tooling.position.at(input, destination);
                const start = result.object.get("range").?.object.get("start").?.object;
                try t.expectEqualStrings(uri, result.object.get("uri").?.string);
                try t.expectEqual(@as(i64, @intCast(position.line)), start.get("line").?.integer);
                try t.expectEqual(@as(i64, @intCast(position.character)), start.get("character").?.integer);
            },
            3 => {
                var width = false;
                var values = false;
                for (result.object.get("items").?.array.items) |item| {
                    const label = item.object.get("label").?.string;
                    width = width or std.mem.eql(u8, label, "width");
                    values = values or std.mem.eql(u8, label, "values");
                }
                try t.expect(width and values);
            },
            4 => try t.expectEqual(@as(usize, 0), result.object.get("outputs").?.array.items.len),
            5 => try expectHintLabels(.{ .object = response }, &.{ "struct Widget", "fn read" }),
            6 => {
                const formatted = result.array.items[0].object.get("newText").?.string;
                try t.expect(std.mem.indexOf(u8, formatted, "    width:int = 2") != null);
                try t.expect(std.mem.indexOf(u8, formatted, "Widget(width: 3)") != null);
                try t.expect(std.mem.indexOf(u8, formatted, "{\"title\": \"Ω\"}") != null);
            },
            7 => {
                var copy = false;
                var record = false;
                for (result.object.get("items").?.array.items) |item| {
                    const label = item.object.get("label").?.string;
                    copy = copy or std.mem.eql(u8, label, "copy");
                    record = record or std.mem.eql(u8, label, "Widget");
                    try t.expect(!std.mem.eql(u8, label, "sin") and !std.mem.eql(u8, label, "cos") and !std.mem.eql(u8, label, "circle"));
                }
                try t.expect(copy and record);
            },
            8 => try t.expect(std.mem.startsWith(u8, result.object.get("contents").?.object.get("value").?.string, "fn math.sin(")),
            9 => {
                var sin = false;
                var pi = false;
                for (result.object.get("items").?.array.items) |item| {
                    const label = item.object.get("label").?.string;
                    sin = sin or std.mem.eql(u8, label, "sin");
                    pi = pi or std.mem.eql(u8, label, "PI");
                    try t.expect(!std.mem.eql(u8, label, "print") and !std.mem.eql(u8, label, "picture"));
                }
                try t.expect(sin and pi);
            },
            10 => try t.expect(result == .null),
            else => unreachable,
        }
    }
    for (seen) |received| try t.expect(received);
    try t.expect(frontend.native == null);
}

test "native domain editor services expose coherent members without duplicate constructors" {
    var frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend, .initialized = true };
    defer session.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = "file:///tmp/native-domains.huak";
    const input = "curve:=geometry.circle((0,0),2)\nbrush:=pen.pencircle(3)\nink:=color.rgb(1,0,0)\npic:=picture(640, 480)\n";
    var output: std.Io.Writer.Allocating = .init(t.allocator);
    defer output.deinit();
    const writer = &output.writer;
    try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = input } } }, .{}), writer);
    const requests = [_]struct { method: []const u8, offset: usize }{
        .{ .method = "textDocument/hover", .offset = std.mem.indexOf(u8, input, "circle((").? },
        .{ .method = "textDocument/completion", .offset = "curve:=geometry.circle".len },
        .{ .method = "textDocument/definition", .offset = std.mem.indexOf(u8, input, "circle((").? },
        .{ .method = "textDocument/completion", .offset = 0 },
        .{ .method = "textDocument/hover", .offset = std.mem.indexOf(u8, input, "pencircle(3)").? },
        .{ .method = "textDocument/hover", .offset = std.mem.indexOf(u8, input, "rgb(1,").? },
    };
    for (requests, 1..) |request, id| try session.handle(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .method = request.method, .params = .{ .textDocument = .{ .uri = uri }, .position = tooling.position.at(input, request.offset) } }, .{}), writer);
    var reader = std.Io.Reader.fixed(output.written());
    var seen: [requests.len]bool = @splat(false);
    while (try tooling.lsp.readMessage(a, &reader)) |body| {
        const response = (try std.json.parseFromSlice(std.json.Value, a, body, .{})).value.object;
        const id = response.get("id") orelse continue;
        const index: usize = @intCast(id.integer);
        try t.expect(index > 0 and index <= seen.len and !seen[index - 1]);
        seen[index - 1] = true;
        const result = response.get("result") orelse return error.UnexpectedErrorResponse;
        switch (index) {
            1, 5, 6 => {
                const prefix = switch (index) {
                    1 => "fn geometry.circle(",
                    5 => "fn pen.pencircle(",
                    else => "fn color.rgb(",
                };
                try t.expect(std.mem.startsWith(u8, result.object.get("contents").?.object.get("value").?.string, prefix));
            },
            2 => {
                var circle = false;
                for (result.object.get("items").?.array.items) |candidate| {
                    const name = candidate.object.get("label").?.string;
                    circle = circle or std.mem.eql(u8, name, "circle");
                    try t.expect(!std.mem.eql(u8, name, "pencircle") and !std.mem.eql(u8, name, "rgb") and !std.mem.eql(u8, name, "draw"));
                }
                try t.expect(circle);
            },
            3 => try t.expect(result == .null),
            4 => {
                var picture: usize = 0;
                for (result.object.get("items").?.array.items) |candidate| if (std.mem.eql(u8, candidate.object.get("label").?.string, "picture")) {
                    picture += 1;
                };
                try t.expectEqual(@as(usize, 1), picture);
            },
            else => unreachable,
        }
    }
    for (seen) |present| try t.expect(present);
    try t.expect(frontend.native == null);
}
