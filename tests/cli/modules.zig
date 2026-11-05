const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
pub fn run(ctx: *h.Harness) !void {
    try dataImports(ctx);
    inline for ([_][]const u8{ "modules/lib/shapes", "modules/lib/second" }) |name| {
        _ = try ctx.fixture(name);
    }
    const imported = try ctx.fixture("modules/drawing");
    _ = try ctx.command("check", imported, &.{}, true);
    _ = try ctx.command("run", imported, &.{ "--output", "imported.svg", "--output", "result=imported.pdf" }, true);
    try (try ctx.svg("imported.svg")).viewBox("0 0 80 40");
    try t.expect(std.mem.startsWith(u8, try ctx.read("imported.pdf"), "%PDF-"));
    const code = try ctx.command("disassemble", imported, &.{}, true);
    try h.contains(code.stdout, "import_module");
    try h.contains(code.stdout, "shapes.huak");
    for ([_]struct { name: []const u8, body: []const u8 }{
        .{ .name = "private_global", .body = "print(shapes.secret)" }, .{ .name = "private_function", .body = "shapes.private_helper()" }, .{ .name = "unknown_member", .body = "print(shapes.missing)" }, .{ .name = "unqualified_private_global", .body = "print(secret)" }, .{ .name = "unqualified_private_function", .body = "private_helper()" }, .{ .name = "assign_import", .body = "shapes.number=1" }, .{ .name = "alias_value", .body = "copy:=shapes" }, .{ .name = "alias_conflict", .body = "import paint.picture;shapes:=picture(640, 480)" }, .{ .name = "private_function_value", .body = "f:=shapes.private_helper" },
    }) |case| {
        const path = try ctx.script(try ctx.fmt("modules/{s}", .{case.name}), try ctx.fmt("import \"lib/shapes.huak\" as shapes\n{s}\n", .{case.body}));
        try h.output(try ctx.command("check", path, &.{}, false), "");
    }
    const private = try ctx.command("run", imported, &.{ "--output", "tile=private-root.svg" }, false);
    try h.contains(private.stderr, "output");
    try ctx.absent("private-root.svg");
    const duplicate = try ctx.fixture("modules/duplicate_alias");
    try h.contains((try ctx.command("check", duplicate, &.{}, false)).stderr, "shapes");
    const nested = try ctx.fixture("modules/nested_import");
    _ = try ctx.command("check", nested, &.{}, true);
    inline for ([_][]const u8{ "modules/lib/shared", "modules/lib/left", "modules/lib/right" }) |name| {
        _ = try ctx.fixture(name);
    }
    const diamond = try ctx.fixture("modules/diamond");
    for ([_][]const u8{ "diamond.svg", "diamond-again.svg" }) |file| {
        try h.output(try ctx.command("run", diamond, &.{ "--output", file }, true), "shared initialized\n");
        try (try ctx.svg(file)).viewBox("0 0 70 35");
    }
    try h.output(try ctx.command("check", diamond, &.{}, true), "");
    const private_namespace = try ctx.fixture("modules/private_namespace");
    _ = try ctx.command("check", private_namespace, &.{}, false);
    _ = try ctx.fixture("modules/cycle-a");
    _ = try ctx.fixture("modules/cycle-b");
    const cycle = try ctx.command("check", try ctx.path("modules/cycle-a.huak"), &.{}, false);
    try h.either(cycle.stderr, "cyclic", "Cyclic");
    try h.contains(cycle.stderr, "cycle-a.huak");
    try h.contains(cycle.stderr, "cycle-b.huak");
    const missing = try ctx.fixture("modules/missing_module");
    try h.contains((try ctx.command("check", missing, &.{}, false)).stderr, "absent.huak");
    const broken = try ctx.fixture("modules/lib/broken");
    const broken_import = try ctx.fixture("modules/broken_import");
    try h.contains((try ctx.command("check", broken_import, &.{}, false)).stderr, try ctx.fmt("{s}:2:", .{broken}));
    _ = try ctx.fixture("modules/lib/dead-invalid");
    const dead = try ctx.fixture("modules/dead_invalid");
    try h.contains((try ctx.command("check", dead, &.{}, false)).stderr, "missing_function");
    const exploding = try ctx.fixture("modules/lib/exploding");
    const traced = try ctx.fixture("modules/runtime_trace");
    const failure = try ctx.command("run", traced, &.{}, false);
    try h.contains(failure.stderr, try ctx.fmt("{s}:3:", .{exploding}));
    try h.contains(failure.stderr, "explode");
    try h.contains(failure.stderr, "outer");
    _ = try ctx.fixture("modules/lib/settings");
    const settings = try ctx.fixture("modules/settings");
    try h.output(try ctx.command("run", settings, &.{ "--param", "amount=11" }, true), "11\n");
    const unknown = try ctx.command("run", settings, &.{ "--param", "dependency_only=8" }, false);
    try h.contains(unknown.stderr, "unknown parameter");
    try h.output(unknown, "");
    _ = try ctx.fixture("modules/lib/required-setting");
    const required = try ctx.fixture("modules/required_import");
    try h.contains((try ctx.command("check", required, &.{}, false)).stderr, "default");
    _ = try ctx.fixture("modules/lib/early");
    for ([_]struct { name: []const u8, expression: []const u8 }{ .{ .name = "early_function", .expression = "early.answer()" }, .{ .name = "early_parameter", .expression = "early.amount" } }) |case| {
        const path = try ctx.script(try ctx.fmt("modules/{s}", .{case.name}), try ctx.fmt("start()\nimport \"lib/early.huak\" as early\nfn start()->int\nreturn {s}\nend\n", .{case.expression}));
        const failed = try ctx.command("run", path, &.{}, false);
        try h.either(failed.stderr, "import", "initializ");
    }
    _ = try ctx.fixture("modules/lib/self-call");
    const self_call = try ctx.fixture("modules/self_call");
    _ = try ctx.command("run", self_call, &.{}, true);
    _ = try ctx.fixture("modules/lib/typography");
    const typography = try ctx.fixture("modules/typography");
    _ = try ctx.command("run", typography, &.{ "--output", "modules-typography.pdf", "--output", "page=modules-typography.svg" }, true);
    const text = try ctx.pdfText("modules-typography.pdf", false);
    try t.expect(std.mem.count(u8, text, "Module Ω") >= 3);
    try (try ctx.svg("modules-typography.svg")).viewBox("0 0 320 180");
    const function = try ctx.fixture("modules/function_export");
    _ = try ctx.command("check", function, &.{}, true);
    const not_picture = try ctx.command("run", function, &.{ "--output", "hello=function.svg" }, false);
    try h.contains(not_picture.stderr, "output 'hello' is not defined");
    try ctx.absent("function.svg");
}

fn dataImports(ctx: *h.Harness) !void {
    _ = try ctx.script("data/lib/config", "import \"plot.json\" as settings; export settings");
    try ctx.write("data/lib/plot.json", "{\"width\":81,\"values\":[1.5,true,null],\"title\":\"A\\u03a9\"}");
    try ctx.write("data/points.csv", "\xef\xbb\xbfid,y,note\r\n001,20,\"line 1\r\nline \"\"2\"\"\"\r\n002,40,");
    const script = try ctx.script("data/render",
        \\import assertions.assert
        \\import "lib/config.huak".settings
        \\import "lib/./plot.json" as same
        \\import "points.csv"
        \\assert(settings["title"] == "AΩ")
        \\assert(settings["values"] == [1.5,true,block end])
        \\same["width"] = 80
        \\assert(settings["width"] == 80)
        \\assert(points[0] == ["id","y","note"])
        \\assert(points[1] == ["001","20","line 1\r\nline \"2\""])
        \\assert(points[2][2] == "")
        \\default picture(settings["width"],int(points[2][1]))
    );
    _ = try ctx.command("run", script, &.{ "--output", "from-data.svg" }, true);
    try (try ctx.svg("from-data.svg")).viewBox("0 0 80 40");
    for ([_]struct { file: []const u8, contents: []const u8, diagnostic: []const u8 }{
        .{ .file = "bad.json", .contents = "[1,\n?]", .diagnostic = "SyntaxError" },
        .{ .file = "bad.json", .contents = "{\"a\":1,\"a\":2}", .diagnostic = "DuplicateField" },
        .{ .file = "bad.json", .contents = "9223372036854775808", .diagnostic = "NumberOutOfRange" },
        .{ .file = "bad.csv", .contents = "x\n\"open", .diagnostic = "InvalidQuotes" },
        .{ .file = "bad.csv", .contents = "\"a\"\"", .diagnostic = "InvalidQuotes" },
        .{ .file = "bad.csv", .contents = "\"a\"\rXb\n", .diagnostic = "InvalidQuotes" },
    }) |case| {
        try ctx.write(try ctx.fmt("data/{s}", .{case.file}), case.contents);
        const bad = try ctx.script("data/bad-import", try ctx.fmt("import \"{s}\" as records", .{case.file}));
        const failure = try ctx.command("check", bad, &.{}, false);
        try h.contains(failure.stderr, case.file);
        try h.contains(failure.stderr, case.diagnostic);
    }
}
