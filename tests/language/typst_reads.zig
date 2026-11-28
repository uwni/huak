//! Typst reads of huak data: typed values, whole-value use, shadowing, templates and error order.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const ModuleSource = @import("../support/modules.zig").ModuleSource;
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const compile = harness.compile;
const execute = harness.execute;

test "exposed data preserves typed values immutable text snapshots and repeated Program execution" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, label, picture};param initial:int=9007199254740993
        \\count:=initial
        \\scale:=1.25
        \\enabled:=true
        \\title:="Ω #panic(\"not evaluated\")"
        \\font_size:=12pt
        \\ink:=rgb(0.2,0.4,0.6,0.5)
        \\theme:=typ.module[#let style(body) = {
        \\  assert(type(huak)==module)
        \\  assert(type(huak.count)==int)
        \\  assert(type(huak.scale)==float and huak.scale==1.25)
        \\  assert(type(huak.enabled)==bool and huak.enabled)
        \\  assert(type(huak.title)==str and huak.title=="Ω #panic(\"not evaluated\")")
        \\  assert(type(huak.font_size)==length and huak.font_size==12pt)
        \\  assert(type(huak.ink)==color and huak.ink==rgb(20%,40%,60%,50%))
        \\  set text(size:huak.font_size,fill:huak.ink)
        \\  body
        \\}]
        \\typ.show theme.style
        \\first:=typ[Count #huak.count; #huak.title]
        \\again:=typ[Count #huak.count; #huak.title]
        \\count=count+2
        \\changed:=typ[Count #huak.count; #huak.title]
        \\pic:=picture(650,130)
        \\object.append(pic, object.label(first, (10,100)))
        \\object.append(pic, object.label(again, (10,65)))
        \\object.append(pic, object.label(changed, (10,30)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        for ([_]bool{ false, true }) |batched| for ([_][]const u8{ "9007199254740993", "42" }) |initial| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var host = runtime.host();
            var vtable = host.vtable.*;
            if (!batched) vtable.typstBatch = null;
            host.vtable = &vtable;
            var machine = try l.Machine.init(t.allocator, &program, host, .{});
            defer machine.deinit();
            _ = machine.execute(&.{.{ .name = "initial", .value = initial }}) catch |err| {
                if (machine.failure) |failure| std.debug.print("exposure VM: {s}: {s}\n", .{ failure.text(), failure.native_message });
                return err;
            };
            const first = runtime.texts.items[machine.getGlobal("first").?.handle.index];
            const again = runtime.texts.items[machine.getGlobal("again").?.handle.index];
            try t.expectEqualDeep(first.metrics, again.metrics);
            if (batched) try t.expect(first.layout == again.layout);
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "#336699") != null);
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
            const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            const first_number = if (std.mem.eql(u8, initial, "42")) "Count 42" else "Count 9007199254740993";
            const changed_number = if (std.mem.eql(u8, initial, "42")) "Count 44" else "Count 9007199254740995";
            try t.expect(std.mem.indexOf(u8, text, first_number) != null);
            try t.expect(std.mem.indexOf(u8, text, changed_number) != null);
            try t.expect(std.mem.indexOf(u8, text, "Ω #panic(\"not evaluated\")") != null);
        };
    }
}

test "Typst code that uses huak as a whole value sees exactly the members it reads" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\title:="private"
        \\other:=1
        \\bare:=typ[#assert(type(huak) == module and dictionary(huak) == (:))ok]
        \\imported:=typ[#import huak: *
        \\ok]
        \\passed:=typ[#let count(m) = dictionary(m).len()
        \\#assert(count(huak) == 0)ok]
        \\one:=typ[#assert(dictionary(huak).keys() == ("title",))#huak.title]
        \\theme:=typ.module[#let members = dictionary(huak).len()]
        \\checked:=typ[#assert(huak.theme.members == 0 and dictionary(huak).keys() == ("theme",))ok]
        \\fn local()->text return typ[#assert(dictionary(huak) == (:))ok] end
        \\made:=local()
    ;
    {
        var program = try compile(&library, source);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
    }
    // Code that does not mention `huak` has none to see.
    var program = try compile(&library, "title:=\"private\"\ncaption:=typ[#eval(\"huak\")]");
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, "unknown variable: huak") != null);
}

test "Typst reads respect local shadowing aliases block restoration and module boundaries" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{.{ .name = "/native/reads-library.huak", .source =
        \\export item:="module"
        \\export caption:=typ[#assert(dictionary(huak).keys()==("item",))#huak.item]
    }};
    const source =
        \\import paint.{label, picture};import "reads-library.huak".{item as imported,caption as module_text}
        \\title:="root"
        \\fn make_caption(title:string)->text
        \\    return typ[#assert(huak.title=="local")#assert(huak.imported=="module")#huak.title]
        \\end
        \\local_text:=make_caption("local"); branch_text:=local_text
        \\if true then
        \\    branch:="branch"
        \\    branch_text=typ[#assert(dictionary(huak).keys()==("branch",))#huak.branch]
        \\end
        \\root_text:=typ[#assert(dictionary(huak).keys()==("title","imported"))#huak.title #huak.imported]
        \\pic:=picture(240,160)
        \\object.append(pic, object.label(module_text, (5,135)))
        \\object.append(pic, object.label(local_text, (5,100)))
        \\object.append(pic, object.label(branch_text, (5,65)))
        \\object.append(pic, object.label(root_text, (5,30)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        for ([_][]const u8{ "module", "local", "branch", "root module" }) |expected|
            try t.expect(std.mem.indexOf(u8, text, expected) != null);
    }
}

test "Typst reads in template call bodies match ordinary reads" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    // Huak assertions check the ordinary reads; Typst assertions check that the
    // same template parameters and locals reach the request, also in a function.
    const source =
        \\import assertions.assert
        \\expand_block foo(width:length = 2pt)
        \\    a := 1
        \\    ...
        \\end
        \\expand_block bar(gap:length = 1pt)
        \\    c := 3
        \\    foo do
        \\        e := "five"
        \\        ...
        \\    end
        \\end
        \\gap := 9pt
        \\caption := typ[placeholder]
        \\bar do
        \\    assert(gap == 1pt and c == 3 and width == 2pt and a == 1 and e == "five")
        \\    caption = typ[#assert.eq(huak.gap, 1pt)#assert.eq(huak.c, 3)#assert.eq(huak.width, 2pt)#assert.eq(huak.a, 1)#assert.eq(huak.e, "five")#huak.e]
        \\end
        \\fn framed()->text
        \\    result := typ[placeholder]
        \\    bar do
        \\        result = typ[#assert.eq(huak.gap, 1pt)#huak.gap]
        \\    end
        \\    return result
        \\end
        \\framed_caption := framed()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expect(machine.getGlobal("caption") != null);
        try t.expect(machine.getGlobal("framed_caption") != null);
    }
}

test "Typst read batches preserve earlier native errors before later length conversion failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source = "huge:=1e308mm\nfirst:=typ[#missing]\nif true then second:=typ[#huak.huge] end\n";
    for ([_]bool{ false, true }) |optimize| for ([_]bool{ false, true }) |batched| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var host = runtime.host();
        var vtable = host.vtable.*;
        if (!batched) vtable.typstBatch = null;
        host.vtable = &vtable;
        var machine = try l.Machine.init(t.allocator, &program, host, .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, "missing") != null);
        try t.expect(machine.getGlobal("first") == null);
        try t.expect(machine.getGlobal("second") == null);
    };
    for ([_][]const u8{ "[1]", "1deg", "picture(640, 480)" }) |bad| {
        const input = try std.fmt.allocPrint(t.allocator, "import paint.picture;fn read_any(value:any)->text\nreturn typ[#huak.value]\nend\ncaption:=read_any({s})\n", .{bad});
        defer t.allocator.free(input);
        var program = try compile(&library, input);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try t.expect(machine.getGlobal("caption") == null);
        try t.expect(std.mem.indexOf(u8, machine.failure.?.text(), "Typst code can read") != null);
    }
}
