//! Typst show rules: frame snapshots, raw markup, module namespaces and block imports.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const ModuleSource = @import("../support/modules.zig").ModuleSource;
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;
const compileModulesOptimized = harness.compileModulesOptimized;
const compileModules = harness.compileModules;
const linkedModule = harness.linkedModule;

test "Typst show rules keep frame snapshots and body-local changes isolated" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, fill, label, picture};import geometry.compound;import object.outlines;import text.width;import assertions.assert
        \\words:=typ.module[#let word(s) = {
        \\ strong(s)
        \\ /*
        \\ end
        \\ */
        \\}]
        \\small:=typ.module[#let style(body) = {
        \\ set text(size:10pt)
        \\ body
        \\}]
        \\typ.show small.style
        \\a:=typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\b:=typ[
        \\ #set text(size:30pt)
        \\ #huak.words.word("Same Ω")
        \\]
        \\c:=typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\assert(width(a)==width(c))
        \\assert(width(b)>2*width(a))
        \\large:=typ.module[#let style(body) = {
        \\ set text(size:20pt)
        \\ body
        \\}]
        \\d:=block
        \\ typ.show large.style
        \\ return typ[
        \\ #huak.words.word("Same Ω")
        \\]
        \\end
        \\assert(width(d)>1.9*width(a))
        \\assert(width(a)==width(c))
        \\pic:=picture(640, 480)
        \\object.append(pic, object.label(a, (10,20))); object.append(pic, object.label(b, (10,50))); object.append(pic, object.label(d, (10,90)))
        \\p:=compound(outlines(c).paths); object.append(pic, object.fill(p, rgb(0,0,0), translate((100,20))))
        \\raw:=pic.paths
        \\expanded:=outlines(pic).paths
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 4), runtime.frames.items.len);
    const raw = machine.getGlobal("raw").?.list.items();
    const expanded = machine.getGlobal("expanded").?.list.items();
    try t.expect(raw.len > 0);
    try t.expectEqual(raw.len, expanded.len);
    for (raw, expanded) |actual, expected| {
        try t.expectEqualDeep(runtime.path_values.items[expected.handle.index].segments.items, runtime.path_values.items[actual.handle.index].segments.items);
    }
    var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
}

test "a shown style preserves raw markup with embedded math code and trailing comments" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.abs;import paint.{picture, label};import text.width;import assertions.assert
        \\plain:=typ[
        \\\[
        \\]
        \\math_plain:=typ[
        \\$x // trailing comment
        \\$
        \\]
        \\code_plain:=typ[
        \\#{ 1 // trailing comment
        \\}
        \\]
        \\words:=typ.module[#let strong_word(s) = strong(s)]
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:11pt)
        \\ show "before": "after"
        \\ body
        \\}]
        \\pic:=picture(640, 480)
        \\block
        \\typ.show theme.style
        \\bracket:=typ[
        \\\[
        \\]
        \\math_shared:=typ[
        \\$x // trailing comment
        \\$
        \\]
        \\code_shared:=typ[
        \\#{ 1 // trailing comment
        \\}
        \\]
        \\assert(abs(width(bracket)-width(plain))<0.00001pt)
        \\assert(abs(width(math_shared)-width(math_plain))<0.00001pt)
        \\assert(abs(width(code_shared)-width(code_plain))<0.00001pt)
        \\rich:=typ[
        \\#huak.words.strong_word[Hello] before
        \\]
        \\object.append(pic, object.label(rich, (10,20))); object.append(pic, object.label(bracket, (10,40)))
        \\end
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
}

test "block imports retain the settings of each text source module" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{
        .{ .name = "/native/large.huak", .source = "theme:=typ.module[#let style(body) = {set text(size:24pt); body}]\ntyp.show theme.style\nexport caption:=typ[Scope Ω]" },
        .{ .name = "/native/small.huak", .source = "theme:=typ.module[#let style(body) = {set text(size:8pt); body}]\ntyp.show theme.style\nexport caption:=typ[Scope Ω]" },
    };
    const source =
        \\import math.abs;import assertions.assert
        \\theme:=typ.module[#let style(body) = {set text(size:12pt); body}]
        \\typ.show theme.style
        \\before:=typ[Scope Ω]
        \\fn captions()->list
        \\    import "large.huak".caption as label
        \\    large:=label; small:=label
        \\    if true then
        \\        import "small.huak".caption as label
        \\        small=label
        \\    end
        \\    restored:=label
        \\    own:=typ[Scope Ω]
        \\    return [large,small,restored,own]
        \\end
        \\texts:=captions()
        \\outside:=typ[Scope Ω]
        \\assert(texts[0]==texts[2])
        \\assert(texts[0].width>1.9*before.width)
        \\assert(texts[1].width<0.8*before.width)
        \\assert(abs(texts[3].width-before.width)<0.000001pt)
        \\assert(abs(outside.width-before.width)<0.000001pt)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
}

test "module namespaces share native frames while isolating Typst show rules by function source" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const imported_source =
        \\import paint.{label, picture}
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:24pt)
        \\ body
        \\}]
        \\typ.show theme.style
        \\export caption:=typ[
        \\Same Ω
        \\]
        \\export tile:=picture(200,80)
        \\object.append(tile, object.label(caption, (5,30)))
        \\fn make_caption()->text
        \\ return typ[
        \\Same Ω
        \\]
        \\end
        \\export make_caption
    ;
    var program = try compileModules(&library,
        \\import math.abs;import paint.{label, picture, append};import assertions.assert
        \\theme:=typ.module[#let style(body) = {
        \\ set text(size:8pt)
        \\ body
        \\}]
        \\typ.show theme.style
        \\before:=typ[
        \\Same Ω
        \\]
        \\import "typography.huak" as typography
        \\after:=typ[
        \\Same Ω
        \\]
        \\assert(abs(before.width-after.width)<0.000001pt)
        \\child:=typography.make_caption()
        \\assert(child.width>2.9*before.width)
        \\assert(abs(child.width-typography.caption.width)<0.000001pt)
        \\last:=typ[
        \\Same Ω
        \\]
        \\assert(abs(before.width-last.width)<0.000001pt)
        \\export page:=picture(320,180)
        \\page.append(copy(typography.tile))
        \\object.append(page, object.label(before, (5,110))); object.append(page, object.label(child, (5,160)))
    , &.{.{ .name = "/native/typography.huak", .source = imported_source }});
    defer program.deinit();
    _ = try linkedModule(&program, "/native/typography.huak");
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expectEqual(@as(usize, 5), runtime.frames.items.len);
    const page = machine.getGlobal("page").?;
    var svg = try runtime.render(page, .svg);
    defer svg.deinit();
    var pdf = try runtime.render(page, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "viewBox=\"0 0 320 180\"") != null);
    try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    try t.expectEqual(@as(usize, 5), runtime.frames.items.len);
}
