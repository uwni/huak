//! Typed request data through the real CLI, native layout and vector exports.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

pub const process_count = 12;

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.script("exposures/library",
        \\export name:="module"
        \\export caption:=typ[#assert(dictionary(huak).keys()==("name",))#huak.name]
    );
    const source = try ctx.script("exposures/main",
        \\import paint.{rgb, label, picture};import "library.huak".{name as imported,caption as module_text}
        \\param title="default"
        \\param count:int=42
        \\current:=count
        \\font_size:=12pt
        \\ink:=rgb(0.2,0.4,0.6,0.5)
        \\theme:=typ.module[#let style(body) = {
        \\  assert(type(huak.count)==int)
        \\  assert(type(huak.font_size)==length and huak.font_size==12pt)
        \\  assert(type(huak.ink)==color)
        \\  assert(dictionary(huak).keys()==("count","font_size","ink"))
        \\  set text(size:huak.font_size,fill:huak.ink)
        \\  body
        \\}]
        \\typ.show theme.style
        \\first:=typ[#assert(dictionary(huak).keys()==("title","current","imported"))#huak.title: #huak.current #huak.imported]
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

    const invalid_static = try ctx.script("exposures/static_list", "items:=[1]\ncaption:=typ[#huak.items]\n");
    try h.contains((try ctx.command("check", invalid_static, &.{}, false)).stderr, "numeric, bool, string, length, color, and typ.module");
    const unknown = try ctx.script("exposures/unknown", "caption:=typ[#huak.missing]\n");
    try h.contains((try ctx.command("check", unknown, &.{}, false)).stderr, "names no readable Huak value");
    const dynamic = try ctx.script("exposures/dynamic",
        \\fn make_caption(value:any)->text
        \\ return typ[#huak.value]
        \\end
        \\caption:=make_caption([1])
    );
    try h.contains((try ctx.command("run", dynamic, &.{}, false)).stderr, "Typst code can read");
    // `huak` holds only the members the code reads, and exists only in code
    // that mentions it.
    const written = try ctx.script("exposures/written", "title:=\"private\"\nother:=1\ncaption:=typ[#assert(dictionary(huak).keys()==(\"title\",))#huak.title]\n");
    try h.output(try ctx.command("run", written, &.{}, true), "");
    const whole = try ctx.script("exposures/whole", "title:=\"private\"\ncaption:=typ[#assert(dictionary(huak) == (:))#repr(huak)]\n");
    try h.output(try ctx.command("run", whole, &.{}, true), "");
    const unread = try ctx.script("exposures/unread", "title:=\"private\"\ncaption:=typ[#eval(\"huak\")]\n");
    try h.contains((try ctx.command("run", unread, &.{}, false)).stderr, "unknown variable: huak");

    const ordered = try ctx.script("exposures/ordered",
        \\huge:=1e308mm
        \\first:=typ[#missing_first]
        \\if true then second:=typ[#huak.huge] end
    );
    const ordered_failure = try ctx.command("run", ordered, &.{"--jobs=4"}, false);
    try h.contains(ordered_failure.stderr, "missing_first");
    try h.excludes(ordered_failure.stderr, "Typst code can read");
    const early = try ctx.script("exposures/early",
        \\caption:=typ[#huak.imported #missing_native]
        \\import "library.huak".name as imported
    );
    const early_failure = try ctx.command("run", early, &.{}, false);
    try h.contains(early_failure.stderr, "names no readable Huak value");
    try h.excludes(early_failure.stderr, "unknown variable: missing_native");
}
