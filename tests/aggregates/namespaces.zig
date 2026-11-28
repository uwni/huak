//! Aggregates with native defaults and namespaces: color defaults, the math namespace, drawing domains, struct imports and reexports.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");
const modules = @import("../support/modules.zig");

test "aggregate constructors run native color defaults and sparse builtin defaults through SVG and PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\import color.rgb
        \\import object.{draw, label}
        \\struct Style
        \\    color:color=rgb(0.1,0.2,0.3)
        \\    width:length=0.5mm
        \\end
        \\style:=Style()
        \\another:=Style(width:1mm)
        \\pic:=picture(height:40mm, width:640pt)
        \\object.append(pic, draw(path((2mm,2mm),(30mm,15mm)), pen(style.color,style.width)))
        \\caption:=typ[Aggregates Ω]
        \\object.append(pic, label(caption, (3mm,20mm)))
        \\canvas_width:=pic.width
        \\canvas_height:=pic.height
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        const style = machine.getGlobal("style").?.record;
        const another = machine.getGlobal("another").?.record;
        try t.expectEqual(l.types.Type.color, style.fields[0].handle.kind);
        try t.expectEqual(l.types.Type.color, another.fields[0].handle.kind);
        try t.expect(style.fields[0].handle.index != another.fields[0].handle.index);
        try t.expectEqual(@as(f64, 0.5), style.fields[1].quantity.value);
        try t.expectEqual(@as(f64, 1), another.fields[1].quantity.value);
        try t.expectEqual(l.types.units.fromPoints(640), machine.getGlobal("canvas_width").?.quantity);
        try t.expectEqual(@as(f64, 40), machine.getGlobal("canvas_height").?.quantity.value);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<svg") != null);
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        const extracted = try @import("../support/pdf.zig").text(pdf.bytes(), .{});
        defer t.allocator.free(extracted);
        try t.expect(std.mem.find(u8, extracted, "Aggregates") != null);
    }
}

test "aggregate programs expose the native math namespace without leaking mathematical globals" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const variants = [_][]const u8{
        "angle:=math.sin(0); root:=math.sqrt(9); circle_constant:=math.PI; param heading:angle=(2*math.PI)rad; fn f(x:float=math.PI)->float return x end; defaulted:=f()",
        "import math as mathematics; angle:=mathematics.sin(0); root:=mathematics.sqrt(9); circle_constant:=mathematics.PI",
        "import math.{sin, sqrt, PI}; angle:=sin(0); root:=sqrt(9); circle_constant:=PI",
    };
    for ([_]bool{ false, true }) |optimize| for (variants, 0..) |text, variant| {
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        try t.expectEqual(@as(f64, 0), machine.getGlobal("angle").?.number);
        try t.expectEqual(@as(f64, 3), machine.getGlobal("root").?.number);
        try t.expectApproxEqAbs(std.math.pi, machine.getGlobal("circle_constant").?.number, 1e-15);
        if (variant == 0) {
            try t.expectEqual(@as(usize, 1), program.modules.len);
            try t.expectApproxEqAbs(std.math.pi, machine.getGlobal("defaulted").?.number, 1e-15);
        }
        if (variant != 2) try t.expect(machine.getGlobal("PI") == null);
        for ([_][]const u8{ "answer:=sin(0)", "answer:=PI", "answer:=rgb(0,0,0)", "import math as mathematics\nanswer:=cos(0)", "answer:=math.rgb(0,0,0)", "math:=(1,2); answer:=math.PI" }) |invalid| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, harness.compile(t.allocator, &library, invalid, &.{}, optimize, &diagnostic));
            try t.expect(diagnostic != null);
        }
    };
}

test "native drawing domains are available independently of source standard modules" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\ink:=color.rgb(0.2,0.4,0.7)
        \\nib:=pen.pensquare(1mm,ink)
        \\curve:=geometry.circle((15mm,15mm),5mm)
        \\matrix:=transform.translate((1mm,0mm))
        \\pic:=picture(40mm,30mm)
        \\object.append(pic, object.draw(curve, nib, matrix))
        \\body:=typ[Domain text]
        \\measured:=text.width(body)
        \\object.append(pic, object.label(body, (2mm,2mm)))
        \\editable:=object.outlines(body)
        \\system:=solver()
        \\x:=solver.unknown(system)
        \\solver.equation(system,x,2)
        \\solution:=solver.solve(system)
        \\answer:=solver.value(solution,x)
        \\animation.timeline(pic,1)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 1), program.modules.len);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        try t.expectEqual(@as(f64, 2), machine.getGlobal("answer").?.number);
        try t.expect(machine.getGlobal("measured").?.quantity.value > 0);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<svg") != null);
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
    }
}

test "aggregate struct imports aliases and reexports retain one nominal identity" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]modules.ModuleSource{
        .{ .name = "/aggregates/models.huak", .source = "export struct Point\n x:int=1\n y:int=2\nend" },
        .{ .name = "/aggregates/bridge.huak", .source = "import \"models.huak\".Point as Renamed\nexport Renamed" },
    };
    const text =
        \\import "models.huak" as models
        \\import "models.huak".Point as Direct
        \\import "bridge.huak".Renamed as Alias
        \\fn total(value:models.Point)->int return value.x+value.y end
        \\first:Alias:=Direct(y:5)
        \\second:models.Point:=Alias(x:7)
        \\answer:=total(first)+total(second)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compileValid(&library, text, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        try t.expectEqual(machine.getGlobal("first").?.record.kind, machine.getGlobal("second").?.record.kind);
        try t.expectEqual(@as(i64, 15), machine.getGlobal("answer").?.int);
        try t.expectEqual(@as(usize, 1), program.records.len);
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, harness.compile(t.allocator, &library,
            \\struct First value:int end
            \\struct Second value:int end
            \\fn consume(value:First)->int return value.value end
            \\bad:=consume(Second(1))
        , &.{}, optimize, &diagnostic));
        try t.expect(std.mem.find(u8, diagnostic.?.text(), "First") != null);
        try t.expect(std.mem.find(u8, diagnostic.?.text(), "Second") != null);
    }
}
