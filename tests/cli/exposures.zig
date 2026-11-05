//! Typed request data through the real CLI, native layout and vector exports.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

pub const process_count = 10;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("exposures/library",
        \\export name:="module"
        \\typst_expose name
        \\export caption:=typ[#assert(huak.keys()==("name",))#huak.name]
    );
    const source = try ctx.script("exposures/main",
        \\import paint.{rgb, label, picture};import "library.huak".{name as imported,caption as module_text}
        \\param title="default"
        \\param count:int=42
        \\current:=count
        \\font_size:=12pt
        \\ink:=rgb(0.2,0.4,0.6,0.5)
        \\typst_expose title,count,current,font_size,ink,imported
        \\setup_typst {
        \\  assert(type(huak.count)==int)
        \\  assert(type(huak.font_size)==length and huak.font_size==12pt)
        \\  assert(type(huak.ink)==color)
        \\  assert(not ("name" in huak))
        \\  set text(size:huak.font_size,fill:huak.ink)
        \\}
        \\first:=typ[#huak.title: #huak.current #huak.imported]
        \\current=current+2
        \\second:=typ[#huak.title: #huak.current #huak.imported]
        \\export plate :=picture(700,130)
        \\default plate
        \\object.append(plate, object.label(module_text, (10,105)))
        \\object.append(plate, object.label(first, (10,70)))
        \\object.append(plate, object.label(second, (10,35)))
    );
    try h.output(try ctx.command("check", source, &.{}, true), "");
    const literal = "Ω #panic(\"not evaluated\")";
    for ([_][]const u8{ "1", "4" }) |jobs| {
        const result = try ctx.command("run", source, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--param=title={s}", .{literal}),
            "--param=count=9007199254740993",
            try ctx.fmt("--output=exposed-{s}.svg", .{jobs}),
            try ctx.fmt("--output=exposed-{s}.pdf", .{jobs}),
        }, true);
        try h.output(result, "");
        _ = try ctx.svg(try ctx.fmt("exposed-{s}.svg", .{jobs}));
        const pdf = try ctx.read(try ctx.fmt("exposed-{s}.pdf", .{jobs}));
        try h.contains(pdf, "/ToUnicode");
        const text = try ctx.pdfText(try ctx.fmt("exposed-{s}.pdf", .{jobs}), false);
        try h.contains(text, literal);
        try h.contains(text, "9007199254740993 module");
        try h.contains(text, "9007199254740995 module");
    }
    try t.expectEqualStrings(try ctx.read("exposed-1.svg"), try ctx.read("exposed-4.svg"));
    try t.expectEqualStrings(try ctx.read("exposed-1.pdf"), try ctx.read("exposed-4.pdf"));
    const bytecode = try ctx.command("disassemble", source, &.{}, true);
    try h.contains(bytecode.stdout, "typst");
    try h.contains(bytecode.stdout, "load_global");

    const invalid_static = try ctx.script("exposures/static_list", "items:=[1]\ntypst_expose items\n");
    try h.contains((try ctx.command("check", invalid_static, &.{}, false)).stderr, "numeric, bool, string, length, and color");
    const unknown = try ctx.script("exposures/unknown", "typst_expose missing\n");
    try h.contains((try ctx.command("check", unknown, &.{}, false)).stderr, "readable Huak variable");
    const dynamic = try ctx.script("exposures/dynamic",
        \\fn make_caption(value:any)->text
        \\ typst_expose value
        \\ return typ[]
        \\end
        \\caption:=make_caption([1])
    );
    try h.contains((try ctx.command("run", dynamic, &.{}, false)).stderr, "typst_expose requires");
    const implicit = try ctx.script("exposures/no_implicit", "title:=\"private\"\ncaption:=typ[#huak.title]\n");
    try h.contains((try ctx.command("run", implicit, &.{}, false)).stderr, "unknown variable: huak");

    const ordered = try ctx.script("exposures/ordered",
        \\huge:=1e308mm
        \\first:=typ[#missing_first]
        \\if true then typst_expose huge;second:=typ[] end
    );
    const ordered_failure = try ctx.command("run", ordered, &.{"--jobs=4"}, false);
    try h.contains(ordered_failure.stderr, "missing_first");
    try h.excludes(ordered_failure.stderr, "typst_expose requires");
    const early = try ctx.script("exposures/early",
        \\typst_expose imported
        \\caption:=typ[#missing_native]
        \\import "library.huak".name as imported
    );
    const early_failure = try ctx.command("run", early, &.{}, false);
    try h.contains(early_failure.stderr, "readable Huak variable");
    try h.excludes(early_failure.stderr, "unknown variable: missing_native");
}
