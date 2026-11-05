const std = @import("std");
const h = @import("harness.zig");
pub fn run(ctx: *h.Harness) !void {
    const help = try ctx.invoke(&.{"--help"}, true);
    try h.contains(help.stdout, "huak run");
    try h.contains(help.stdout, "--output");
    const ordinary_typst = try ctx.script("typst_identifier", "typst:=7\nprint(typst)\n");
    try h.output(try ctx.command("run", ordinary_typst, &.{}, true), "7\n");
    const old_block = try ctx.script("old_typst_block", "text:=typst\nHello\nend\n");
    const old_result = try ctx.command("check", old_block, &.{}, false);
    try h.contains(old_result.stderr, "old_typst_block.huak");
    try h.output(old_result, "");
    const native_blocks = try ctx.script("native_typst_blocks",
        \\import assertions.assert
        \\setup_typst { let decorate(body)=strong(body); set text(size:12pt) }
        \\fn caption() -> text
        \\    return typ[#decorate[end] `]` #("]")]
        \\end
        \\assert(caption().width>0pt); assert(typ[A].width>0pt)
        \\print("native blocks")
    );
    try h.output(try ctx.command("run", native_blocks, &.{}, true), "native blocks\n");
    for ([_]struct { name: []const u8, source: []const u8, message: []const u8 }{
        .{ .name = "unclosed_typ", .source = "t=typ[Hello", .message = "cannot parse Typst block" },
        .{ .name = "unclosed_setup", .source = "setup_typst {let x=1", .message = "cannot parse Typst block" },
        .{ .name = "legacy_typ", .source = "t=typ\nHello\nend", .message = "expected '['" },
        .{ .name = "legacy_setup", .source = "setup_typst\nlet x=1\nend", .message = "expected '{'" },
    }) |case| {
        const path = try ctx.script(case.name, case.source);
        const result = try ctx.command("check", path, &.{}, false);
        try h.contains(result.stderr, case.message);
        try h.contains(result.stderr, case.name);
        try h.output(result, "");
    }
    const arithmetic = try ctx.fixture("arithmetic");
    try h.output(try ctx.command("run", arithmetic, &.{}, true), "default\n12\n1.5\n");
    const literal = "\"); panic(\"injected\"); /* 中文 = value";
    try h.output(try ctx.command("run", arithmetic, &.{ "--param", "count=4", "--param", "scale=2.5", try ctx.fmt("--param=title={s}", .{literal}) }, true), try ctx.fmt("{s}\n20\n2.5\n", .{literal}));
    try h.output(try ctx.invoke(&.{ "run", try ctx.fmt("--libtypst={s}", .{ctx.library}), "--param=title=", "--param=scale=-2.5", arithmetic }, true), "\n12\n-2.5\n");
    try h.output(try ctx.command("run", arithmetic, &.{ "--param", "enabled=false" }, true), "");
    try h.output(try ctx.command("check", arithmetic, &.{}, true), "");
    const missing = try ctx.invoke(&.{ "run", arithmetic, "--libtypst", try ctx.path("missing-library") }, false);
    try h.contains(missing.stderr, "LibraryNotFound");
    try h.contains(missing.stderr, "cannot load libtypst");
    const missing_library = try ctx.path("unused-missing-library");
    for ([_][]const u8{ "check", "disassemble" }) |mode| {
        _ = try ctx.invoke(&.{ mode, arithmetic, "--libtypst", missing_library }, true);
    }
    const embedded = try ctx.fixture("drawing");
    const missing_typesetter = try ctx.invoke(&.{ "check", embedded, "--libtypst", missing_library }, false);
    try h.contains(missing_typesetter.stderr, "cannot load libtypst");
    const bytecode = try ctx.command("disassemble", arithmetic, &.{}, true);
    for ([_][]const u8{ "fn ", "call", "jump", "return_value" }) |word| try h.contains(bytecode.stdout, word);
    const invalid = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{ "--param", "count=bad", "--font", "missing.ttf" }, .message = "must be int" },
        .{ .args = &.{ "--param", "scale=nan" }, .message = "must be finite" },
        .{ .args = &.{ "--param", "enabled=yes" }, .message = "true or false" },
        .{ .args = &.{ "--param", "unknown=1" }, .message = "unknown parameter" },
        .{ .args = &.{ "--param", "count=1", "--param", "count=2" }, .message = "duplicate parameter" },
        .{ .args = &.{"--unknown"}, .message = "unknown option" },
        .{ .args = &.{ "--font", "--libtypst", "missing-library" }, .message = "missing value" },
        .{ .args = &.{ "--output", "pic=old.png" }, .message = ".svg or .pdf" },
        .{ .args = &.{ "--output", "--font", "missing.ttf" }, .message = "missing value" },
    };
    for (invalid) |case| {
        const failed = try ctx.command("run", arithmetic, case.args, false);
        try h.contains(failed.stderr, case.message);
        try h.output(failed, "");
        if (std.mem.eql(u8, case.message, "must be int")) {
            try h.contains(failed.stderr, try ctx.fmt("{s}:2:1:", .{arithmetic}));
            try h.excludes(failed.stderr, "cannot read font");
        }
    }
    for ([_][]const []const u8{ &.{try ctx.fmt("--libtypst={s}", .{ctx.library})}, &.{ "--no-bundled-fonts", "--no-bundled-fonts" } }) |args| {
        const failed = try ctx.command("run", arithmetic, args, false);
        try h.contains(failed.stderr, "duplicate option");
        try h.output(failed, "");
    }
    try ctx.absent("old.svg");
    try ctx.absent("old.pdf");
    for ([_][]const u8{ "--output=", "--libtypst=", "--font=" }) |option| {
        const failed = try ctx.invoke(&.{ "run", arithmetic, option }, false);
        try h.contains(failed.stderr, "empty value");
        try h.output(failed, "");
    }
    for ([_]struct { mode: []const u8, option: []const u8 }{ .{ .mode = "check", .option = "--output=pic=unexpected.svg" }, .{ .mode = "disassemble", .option = "--param=count=4" }, .{ .mode = "check", .option = "--font=missing.ttf" }, .{ .mode = "disassemble", .option = "--no-bundled-fonts" } }) |case| {
        const failed = try ctx.command(case.mode, arithmetic, &.{case.option}, false);
        try h.contains(failed.stderr, "only valid with run");
        try h.output(failed, "");
    }
    _ = try ctx.fixture("-leading");
    try h.output(try ctx.invoke(&.{ "run", "--libtypst", ctx.library, "--", "-leading.huak" }, true), "separator path\n");
    const dash = try ctx.command("run", "-leading.huak", &.{}, false);
    try h.contains(dash.stderr, "option");
    try h.contains(dash.stderr, "-leading.huak");
    const extra = try ctx.invoke(&.{ "run", "--libtypst", ctx.library, "--", "-leading.huak", "--font=after-separator.ttf" }, false);
    try h.contains(extra.stderr, "positional");
    try h.output(extra, "");
    const required = try ctx.fixture("required");
    try h.contains((try ctx.command("run", required, &.{}, false)).stderr, "required parameter");
    const broken = try ctx.fixture("compile_error");
    const failure = try ctx.command("check", broken, &.{}, false);
    try h.contains(failure.stderr, try ctx.fmt("{s}:2:", .{broken}));
    try h.contains(failure.stderr, "int");
    for ([_]struct { name: []const u8, args: []const u8 }{ .{ .name = "text", .args = "\"body\"" }, .{ .name = "text_math", .args = "\"x\"" }, .{ .name = "text_code", .args = "\"1\"" } }) |case| {
        const path = try ctx.script(try ctx.fmt("removed_{s}", .{case.name}), try ctx.fmt("value:={s}({s})\n", .{ case.name, case.args }));
        const failed = try ctx.command("check", path, &.{}, false);
        try h.contains(failed.stderr, case.name);
        try h.contains(failed.stderr, "unknown");
        try h.output(failed, "");
        try ctx.absent(try ctx.fmt("removed_{s}.svg", .{case.name}));
    }
    const trace = try ctx.fixture("trace");
    const traced = try ctx.command("run", trace, &.{}, false);
    for ([_][]const u8{ "zero", "inner", "outer" }) |word| try h.contains(traced.stderr, word);
    try h.contains(traced.stderr, try ctx.fmt("{s}:2:", .{trace}));
    const ranges = try ctx.fixture("dynamic_ranges");
    try h.output(try ctx.command("check", ranges, &.{}, true), "");
    try h.output(try ctx.command("run", ranges, &.{}, true), "6\n9007199254740993\n");
    const zero = try ctx.fixture("zero_step");
    const zero_result = try ctx.command("run", zero, &.{}, false);
    try h.contains(zero_result.stderr, "zero");
    try h.output(zero_result, "");
    const invalid_range = try ctx.fixture("invalid_range");
    const range_result = try ctx.command("run", invalid_range, &.{}, false);
    try h.either(range_result.stderr, "range", "number");
    try h.output(range_result, "");
}
