//! Real language/native integration for quantities, coordinates and angles.
const std = @import("std");
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const t = std.testing;

test "unit syntax and dimensions reach native geometry and typography with identical optimized results" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import drawing.drawing
        \\import math.{sin, sqrt, abs, norm};import paint.{rotate, circle, bounds, draw, label, picture};import transform.apply;import text.width;import math.PI as pi;import assertions.assert
        \\param radius:length=1 cm
        \\param turn:angle=2 pi rad
        \\assert(1cm==10mm); assert(turn==360deg)
        \\assert(2pi rad==2 pi rad); assert((2*pi)rad==360 deg)
        \\assert(1in==25.4mm); assert(abs(72pt-1in)<1e-12mm)
        \\assert(2cm/1mm==20)
        \\area:=(2cm)*(3cm)
        \\assert(area==600mm*mm)
        \\assert(abs(sqrt(area)-sqrt(600)*1mm)<1e-10mm)
        \\assert(abs(sin(90deg)-1)<1e-12)
        \\offset:=(1cm,0); assert(offset.x==10mm)
        \\assert(norm((3mm,4mm))==5mm)
        \\import math.{dot, unit, lerp}
        \\fn lift(v:vec2, z:length) -> vec3
        \\    return (v.x, v.y, z)
        \\end
        \\w := lift(vec2(2cm,0), 0mm)
        \\assert(w == vec3(20mm,0,0)); assert(w.z == 0mm)
        \\assert((w + w)/2 == w); assert(-w == (-20mm,0,0))
        \\assert(norm((2mm,3mm,6mm)) == 7mm)
        \\assert(dot(w,w) == 400mm*mm); assert(unit(w) == (1,0,0))
        \\assert(lerp(w,-w,0.25) == w/2)
        \\export pic:=picture(8cm,5cm)
        \\curve:=circle((2cm,2cm),radius)
        \\drawing pic do;+draw curve;end
        \\caption:=typ[
        \\Native units Ω $x^2$
        \\]
        \\object.append(pic, object.label(caption, (5mm,4cm)))
        \\assert(width(caption)>1mm)
        \\box:=bounds(curve); assert(abs(box[0].x-1cm)<1e-10mm)
        \\rotated:=apply(rotate(90deg),(1cm,0))
        \\assert(abs(rotated.x)<1e-10mm); assert(abs(rotated.y-1cm)<1e-10mm)
        \\sum:=0mm
        \\for x in 0mm:1mm:3mm do;sum=sum+x;end
        \\assert(sum==6mm)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var program = l.compiler.compile(t.allocator, source, "native-units.huak", .{ .optimize = optimize, .source_parser = .init(&library) }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("units compiler: {s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        _ = machine.execute(&.{}) catch |err| {
            if (machine.failure) |detail| std.debug.print("units VM at {d}: {s} {s}\n", .{ detail.diagnostic.position(source).line, detail.text(), detail.native_message });
            return err;
        };
        const target = machine.getGlobal("pic").?;
        var svg = try runtime.render(target, .svg);
        defer svg.deinit();
        var pdf = try runtime.render(target, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/FontFile") != null);
    }
}

test "known incompatible dimensions fail during compilation including dead code" {
    const invalid = [_][]const u8{
        "x:=(0,1cm,1deg)",                 "fn f(v:vec2) -> vec2; return v; end; x:=f((1,2,3))",
        "x:=1cm+1deg",                     "x:=1cm+1",
        "x:=1cm<1deg",                     "x:=1cm==1deg",
        "x:=(1cm,1deg)",                   "x:=(1,1cm)",
        "if false then;x:=1cm+1deg;end",   "param length:length=90deg",
        "import math.floor;x:=floor(1cm)", "import math.ceil;x:=ceil(90deg)",
        "import math.round;x:=round(1mm)",
    };
    for (invalid) |source| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, source, "invalid-units.huak", .{}, &diagnostic));
        try t.expect(diagnostic != null);
    }
}
