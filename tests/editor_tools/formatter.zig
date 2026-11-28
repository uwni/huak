//! The formatter: Typst bytes and comments, typ.module code, native regions, control headers, scoped mixfix, and the standalone binary.
const std = @import("std");
const tooling = @import("huak_tooling");
const typst = @import("libtypst");
const options = @import("test_options");
const t = std.testing;
const Frontend = tooling.Frontend;
const harness = @import("harness.zig");

test "formatter preserves Typst bytes comments and semantics and is idempotent" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
    const native = "[\n    ```typ\n ] end   \n```\n #box[Inner]\n]";
    const input = "word:=typ.module[#let hello = [Hello]]\nexport fn make()->text\n// retained comment\nreturn typ" ++ native ++ "\nend   \nexport fn gather(values...)->list\nreturn values\nend\n";
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/format.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expect(std.mem.find(u8, formatted, "    // retained comment\n    return typ" ++ native) != null);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/format.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
    var program = try frontend.compile(formatted, "/tmp/format.huak", &diagnostic);
    defer program.deinit();
    const offset = std.mem.find(u8, program.source_text, native).?;
    for (program.constants) |constant| {
        if (constant == .string and std.mem.eql(u8, constant.string, native)) {
            try t.expect(constant.string.ptr == program.source_text[offset..].ptr);
            break;
        }
    } else return error.MissingEmbeddedSource;
    try t.expectError(error.LanguageError, tooling.format.format(&frontend, "fn broken(\n", "/tmp/broken.huak", &diagnostic));
}

test "formatter keeps typ.module code bytes and spaces typ.show declarations" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
    const module = "[\n  #let style(body) = {\n    set text(fill: red)   // keep = a,b\n    body\n  }\n]";
    const input = "fn style()->typ.module\nreturn typ.module" ++ module ++ "\nend\nloud:=style()\ntyp.show loud.style\nmarked:=typ.module[#let style(it) = [*#it*]]\nx:=typ[hi #huak.marked.style[x]]\n";
    const expected = "fn style()->typ.module\n    return typ.module" ++ module ++ "\nend\nloud := style()\ntyp.show loud.style\nmarked := typ.module[#let style(it) = [*#it*]]\nx := typ[hi #huak.marked.style[x]]\n";
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    const formatted = try tooling.format.format(&frontend, input, "/tmp/modules.huak", &diagnostic);
    defer t.allocator.free(formatted);
    try t.expectEqualStrings(expected, formatted);
    const again = try tooling.format.format(&frontend, formatted, "/tmp/modules.huak", &diagnostic);
    defer t.allocator.free(again);
    try t.expectEqualStrings(formatted, again);
}

test "formatter preserves native regions while formatting a closing line suffix" {
    var editor_library = try typst.Library.open(options.library_path);
    defer editor_library.deinit();
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io, .source_parser = .init(&editor_library) };
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
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
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
}

test "formatter preserves scoped mixfix declarations and call labels" {
    const frontend: Frontend = .{ .allocator = t.allocator, .io = t.io };
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
}

test "standalone formatter check stdin and invalid-file protection use the actual binary" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(t.io, &directory_buffer);
    const path = try std.Io.Dir.path.join(a, &.{ directory_buffer[0..n], "script.huak" });
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.formatter_path, a);
    const input = "fn foo()->list\nvalues:=[1,2]\nvalues+=3\nreturn values\nend\n";
    const expected = "fn foo()->list\n    values := [1, 2]\n    values += 3\n    return values\nend\n";
    try temporary.dir.writeFile(t.io, .{ .sub_path = "script.huak", .data = input });
    const check = try harness.runWithInput(a, &.{ executable, "--libtypst", "/missing-unused-library", "--check", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 1 }, check.term);
    try t.expectEqualStrings(input, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const displayed = try harness.runWithInput(a, &.{ executable, "--stdout", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, displayed.term);
    try t.expectEqualStrings(expected, displayed.stdout);
    try t.expectEqualStrings(input, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const fixed = try harness.runWithInput(a, &.{ executable, path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, fixed.term);
    try t.expectEqualStrings(expected, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
    const clean = try harness.runWithInput(a, &.{ executable, "--check", path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, clean.term);
    const file = try temporary.dir.openFile(t.io, "script.huak", .{});
    defer file.close(t.io);
    const stdin = try harness.runWithInput(a, &.{ executable, "--stdin" }, file);
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, stdin.term);
    try t.expectEqualStrings(expected, stdin.stdout);
    const invalid = "fn broken(\n";
    try temporary.dir.writeFile(t.io, .{ .sub_path = "script.huak", .data = invalid });
    const failure = try harness.runWithInput(a, &.{ executable, path }, null);
    try t.expectEqual(std.process.Child.Term{ .exited = 1 }, failure.term);
    try t.expectEqualStrings(invalid, try temporary.dir.readFileAlloc(t.io, "script.huak", a, .unlimited));
}
