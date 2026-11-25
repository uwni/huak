//! Symbol services from builtin and record metadata: envelope signatures, record fields and nominal exports, native domain members.
const std = @import("std");
const tooling = @import("huak_tooling");
const t = std.testing;
const Frontend = tooling.Frontend;
const harness = @import("harness.zig");

test "envelope tooling uses builtin metadata for signatures and preserves imported mixfix formatting" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
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
    try t.expect(completion and hover);
}

test "record editor services share fields named arguments formatting and nominal type exports" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
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
            5 => try harness.expectHintLabels(.{ .object = response }, &.{ "struct Widget", "fn read" }),
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
}

test "native domain editor services expose coherent members without duplicate constructors" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
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
}
