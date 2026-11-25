//! Native Typst blocks: wrapping, embedded code and math, and labeled elements as anchors.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

test "native Typst blocks control wrapping and embed code and math without DSL wrappers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const scripts = [_][]const u8{
        \\import paint.{label, picture};import text.{width, height};import assertions.assert
        \\x:=typ[
        \\#block(width:35pt)[#text(size:12pt)[word word word word]]
        \\]
        \\assert(width(x)<=35.1pt); assert(height(x)>20pt); pic:=picture(640, 480); object.append(pic, object.label(x, (10,20)))
        ,
        \\import paint.{label, picture};x:=typ[
        \\#{ let v=3; [#v] }
        \\]
        \\y:=typ[
        \\$frac(1,2)$
        \\]
        \\pic:=picture(640, 480); object.append(pic, object.label(x, (10,20))); object.append(pic, object.label(y, (30,20)))
        ,
        \\import paint.{label, picture};import assertions.assert
        \\typst:=12
        \\assert(typst==12)
        \\x:=typ[
        \\#let s = "first
        \\end
        \\last"
        \\#s
        \\```typ
        \\end
        \\```
        \\#[
        \\end
        \\]
        \\]
        \\pic:=picture(640, 480); object.append(pic, object.label(x, (10,20)))
        ,
        \\import paint.{label, picture};import text.{width, height};import assertions.assert
        \\helpers:=typ.module[#let wrap(body) = strong(body)]
        \\theme:=typ.module[#let style(body) = {set text(size:11pt); body}]
        \\typ.show theme.style
        \\x:=typ[#huak.helpers.wrap[Inline] #("]") `]` /* ] */ #[#{ let v="}"; [#v] }]]
        \\end_text:=typ[
        \\end
        \\]
        \\assert(width(x)>0pt); assert(height(end_text)>0pt)
        \\assert(typ[A].width==width(typ[A]))
        \\items:=[typ[A],typ[B]]; assert(items[0].width>0pt)
        \\blank:=typ.module[]; empty:=typ[]; assert(empty.width>=0pt)
        \\pic:=picture(640, 480); object.append(pic, object.label(typ[#strong[Argument]], (10,20))); after:=7
        \\assert(after==7)
        ,
        \\import math.abs;import paint.{label, picture};import assertions.assert
        \\words:=typ.module[#let word(body) = strong(body)]
        \\theme:=typ.module[#let style(body) = {set text(size:10pt); show "seed": "leaf"; body}]
        \\typ.show theme.style
        \\a:=typ[#huak.words.word[seed]]; b:=typ[#strong[leaf]]
        \\assert(abs(a.width-b.width)<0.000001pt)
        \\large:=typ.module[#let style(body) = {set text(size:20pt); body}]
        \\c:=block
        \\    typ.show large.style
        \\    return typ[#huak.words.word[seed]]
        \\end
        \\assert(c.width>1.9*a.width)
        \\pic:=picture(640, 480); object.append(pic, object.label(a, (10,20))); object.append(pic, object.label(c, (10,50)))
        ,
    };
    for (scripts) |source| {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    const failures = [_][]const u8{
        "import solver.{unknown, equation};s:=solver(); t:=solver(); x:=unknown(s); y:=unknown(t); equation(s,x,y)",
        "import solver.{unknown, equation, solve, value};s:=solver(); x:=unknown(s); equation(s,x,1); equation(s,x,2); result:=solve(s); value(result,x)",
        \\x:=typ[
        \\#does-not-exist
        \\]
        ,
        "import solver.{unknown, solve, value};s:=solver(); x:=unknown(s); result:=solve(s); value(result,x)",
    };
    for (failures) |source| {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.failure != null);
    }
}

test "labeled typeset elements become anchors in the text's own coordinates" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import assertions.assert
        \\import math.{abs, norm}
        \\import text.anchors
        \\import object.bounds
        \\parts:=typ.module[#let mark(name, body) = [#box($body$)#label(name)]]
        \\m:=typ[$ M = mat(huak.parts.mark("a", a), huak.parts.mark("b", b); huak.parts.mark("c", c), huak.parts.mark("d", d^2)) $]
        \\// Typst lays out matrices column by column.
        \\assert(m.anchors.keys()==["a","c","b","d"])
        \\assert(text.anchors(m).keys()==m.anchors().keys() and anchors(m)==m.anchors)
        \\a:anchor:=m.anchors["a"]
        \\d:=m.anchors["d"]
        \\assert(a.min.x<a.max.x and a.min.y<a.max.y)
        \\assert(norm(a.center-(a.min+a.max)/2)<0.000001pt)
        \\// y points up: the first row lies above the second.
        \\assert(a.position.y>d.position.y and a.center.y>d.center.y and a.center.x<d.center.x)
        \\// Anchors use the coordinates in which object(m) places the text.
        \\box:=bounds(object(m))
        \\for name in m.anchors.keys() do
        \\  entry:anchor:=m.anchors[name]
        \\  assert(entry.min.x>=box[0].x and entry.min.y>=box[0].y and entry.max.x<=box[1].x and entry.max.y<=box[1].y)
        \\end
        \\// Reads share the anchors, but each returns its own dictionary.
        \\assert(m.anchors["a"]==a)
        \\copy_:=m.anchors; copy_["z"]=1
        \\assert(not dict_contains(m.anchors, "z") and len(m.anchors)==4)
        \\inline:=typ[Hi #box[X] <x> and #metadata(1) <meta>]
        \\x:=inline.anchors["x"]
        \\assert(abs(x.position.y)<0.001pt and x.min.y<0.001pt and x.max.y>5pt)
        \\assert(abs(x.position.x-x.min.x)<0.001pt and x.position.x>inline.width/10)
        \\meta:=inline.anchors["meta"]
        \\assert(meta.min==meta.position and meta.max==meta.position and norm(meta.center-meta.position)<0.000001pt)
        \\assert(len(typ[Plain].anchors)==0)
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);

    const failures = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "x:=typ[#box[A] <same> and #box[B] <same>].anchors", .message = "label <same> occurs more than once" },
        .{ .source = "x:=typ[#box[A] <a>].anchors[\"b\"]", .message = "dictionary has no key 'b'" },
    };
    for (failures) |failure| {
        var failing = try compile(&library, failure.source);
        defer failing.deinit();
        var failing_runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer failing_runtime.deinit();
        var failing_machine = try l.Machine.init(t.allocator, &failing, failing_runtime.host(), .{});
        defer failing_machine.deinit();
        try t.expectError(error.RuntimeFailed, failing_machine.execute(&.{}));
        const detail = failing_machine.failure.?;
        try t.expect(std.mem.indexOf(u8, detail.text(), failure.message) != null or std.mem.indexOf(u8, detail.native_message, failure.message) != null);
    }
    var diagnostic: ?l.compiler.Diagnostic = null;
    try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, "p:=picture(); x:=p.anchors", "anchors-invalid.huak", .{ .source_parser = .init(&library) }, &diagnostic));
}
