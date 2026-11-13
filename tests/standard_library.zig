//! Bundled Huak source recipes use the same bytecode and native host as user code.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const scene = @import("support/scene.zig");

fn compile(library: *typst.Library, source: []const u8, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "standard-library-test.huak", .{
        .source_parser = .init(library),
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| {
            std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
            for (detail.trace) |entry| std.debug.print("  {s} in {s}\n", .{ entry.function, machine.program.modules[entry.module].name });
        }
        return err;
    };
}

test "standard root exports module namespaces and preserves nested native and source identities" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import std as library
            \\import std.math as m
            \\import std.math.{sin, PI as pi}
            \\import std.assertions.assert as ensure
            \\import std.collections as data
            \\import std.paint.circle as disk
            \\import geometry.circle as native_disk
            \\import paint.*
            \\fn minus(x:int, y:int) -> int return x-y end
            \\a:=native_disk((0,0),10); b:=native_disk((4,0),10)
            \\remainder:=block
            \\    import regions.minus
            \\    return a minus b
            \\end
            \\import regions.minus as cut_by
            \\ensure(minus(7,3)==4 and len(remainder)>0 and len(a minus b)==len(remainder))
            \\export disk, native_disk
            \\direct:=library.math.sin(library.math.PI/2)
            \\aliased:=m.sin(m.PI/2)
            \\selected:=sin(pi/2)
            \\defaults:=data.defaults({"present":3},{"present":4,"missing":5})
            \\ensure(direct==1 and aliased==1 and selected==1)
            \\ensure(defaults["present"]==3 and defaults["missing"]==5)
            \\plate:=picture(20mm,20mm)
            \\object.append(plate, library.object.fill((circle with center (10mm,10mm) radius 4mm), library.color.rgb(0,0.5,1)))
            \\export plate
        , optimize);
        defer program.deinit();
        try t.expectEqualDeep(program.exports[0].target, program.exports[1].target);
        var root: ?l.bytecode.Module = null;
        for (program.modules) |module| if (std.mem.eql(u8, module.name, "std/std.huak")) {
            try t.expect(root == null);
            root = module;
        };
        try t.expect(root != null);
        const names = [_][]const u8{ "math", "geometry", "color", "pen", "transform", "picture", "object", "text", "animation", "solver", "assertions", "collections", "brush", "engraving", "paint", "weave", "regions", "pen_motion" };
        try t.expectEqual(names.len, root.?.exports.len);
        for (root.?.exports) |exposed| {
            try t.expect(exposed.target == .namespace);
            var known = false;
            for (names) |name| if (std.mem.eql(u8, name, exposed.name)) {
                known = true;
                break;
            };
            try t.expect(known);
        }
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var svg = try runtime.render(machine.getGlobal("plate").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
}

test "narrow assertions import does not load drawing policies or standard root" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, "import assertions.assert\nassert(true)\n", optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 2), program.modules.len);
        try t.expectEqualStrings("std/assertions.huak", program.modules[1].name);
        var machine = try l.Machine.init(t.allocator, &program, .{}, .{});
        defer machine.deinit();
        try execute(&machine);
    }
}

test "standard mixfix defaults preserve native calls bytecode work and repeated executions" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const imports =
        \\import paint.*
        \\import geometry.{region_union, region_intersection, region_difference, region_xor}
        \\import regions.*
        \\
    ;
    const sources = [_][]const u8{
        imports ++
            \\export circle, rectangle, pen, picture, rgb, tapered, rainbow, tube
            \\blue:=rgb(0.1,0.3,0.8)
            \\plate:=picture(60mm,40mm)
            \\object.append(plate, object.draw(circle((40mm,20mm),10mm), pen(blue,0.5mm)))
            \\object.append(plate, object.fill(rectangle((2mm,2mm),20mm,3mm), blue))
            \\curve:=joined(joined((1mm,10mm)--(2mm,10mm),(2mm,10mm)~~(10mm,14mm)~~(20mm,10mm)),(20mm,10mm)--(21mm,10mm))
            \\a:=rectangle((0,0),12,12);b:=rectangle((8,2),12,10);c:=circle((14,7),4)
            \\object.append(plate, object.fill(region_difference(region_xor(region_union(a,region_intersection(b,c)),b),c),blue))
            \\object.append(plate, object.fill(tapered(curve,1mm), blue))
            \\plate.append(copy(rainbow(curve,0.5mm)), translate((0mm,8mm)))
            \\plate.append(copy(tube(curve,2mm)), translate((0mm,16mm)))
        ,
        imports ++
            \\export circle, rectangle, pen, picture, rgb, tapered, rainbow, tube
            \\blue:=rgb with red 0.1 green 0.3 blue 0.8
            \\plate:=picture with width 60mm height 40mm
            \\object.append(plate, object.draw((circle with center (40mm,20mm) radius 10mm), (pen with color blue width 0.5mm)))
            \\object.append(plate, object.fill((rectangle with origin (2mm,2mm) width 20mm height 3mm), blue))
            \\curve:=(1mm,10mm)--(2mm,10mm) & (2mm,10mm)~~(10mm,14mm)~~(20mm,10mm) & (20mm,10mm)--(21mm,10mm)
            \\a:=rectangle((0,0),12,12);b:=rectangle((8,2),12,10);c:=circle((14,7),4)
            \\object.append(plate, object.fill(a union b inter c xor b minus c,blue))
            \\object.append(plate, object.fill((tapered along curve width 1mm), blue))
            \\plate.append(copy((rainbow along curve width 0.5mm)), translate((0mm,8mm)))
            \\plate.append(copy((tube along curve diameter 2mm)), translate((0mm,16mm)))
        ,
    };
    for ([_]bool{ false, true }) |optimize| {
        var expected: ?[]u8 = null;
        defer if (expected) |bytes| t.allocator.free(bytes);
        var steps: ?u64 = null;
        for (sources) |source| {
            var program = try compile(&library, source, optimize);
            defer program.deinit();
            try t.expectEqual(@as(usize, 8), program.exports.len);
            for (program.exports, 0..) |exposed, index| {
                const form = exposed.mixfix[0].?;
                try t.expect(form.parts.len > 0);
                try t.expectEqualStrings(if (index < 5) "with" else "along", form.parts[0].?);
                try t.expect(form.parts[form.parts.len - 1] == null);
                try t.expect((exposed.target == .builtin) == (index < 5));
            }
            for (program.functions) |function| {
                for ([_][]const u8{ "circle", "rectangle", "pen", "picture", "rgb" }) |native|
                    try t.expect(!std.mem.eql(u8, function.name, native));
            }
            for (0..2) |_| {
                var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
                defer runtime.deinit();
                var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
                defer machine.deinit();
                try execute(&machine);
                var svg = try runtime.render(machine.getGlobal("plate").?, .svg);
                defer svg.deinit();
                if (expected) |bytes| {
                    try t.expectEqualSlices(u8, bytes, svg.bytes());
                    try t.expectEqual(steps.?, machine.steps);
                } else {
                    expected = try t.allocator.dupe(u8, svg.bytes());
                    steps = machine.steps;
                }
            }
        }
    }
}

test "paint prelude reexports canonical functions without wrappers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*
            \\import paint.sphere as ball
            \\import "std/paint.huak" as paint_module
            \\export sphere, ball
            \\export pic:=picture(30mm,30mm);append(pic, copy(sphere 4mm))
        , optimize);
        defer program.deinit();
        var paint_modules: usize = 0;
        for (program.modules) |module| if (std.mem.eql(u8, module.name, "std/paint.huak")) {
            paint_modules += 1;
        };
        try t.expectEqual(@as(usize, 1), paint_modules);
        try t.expectEqualDeep(program.exports[0].target, program.exports[1].target);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
}

test "native clip accumulates through UFCS and reset clears the copied scope" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*
            \\pic:=picture(20pt,20pt)
            \\pic.clip(rectangle((0pt,0pt),10pt,20pt))
            \\pic.clip(rectangle((0pt,0pt),20pt,10pt))
            \\copy_pic:=copy(pic)
            \\copy_pic.reset_clip()
            \\export pic, copy_pic
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const clipped = machine.getGlobal("pic").?;
        const cleared = machine.getGlobal("copy_pic").?;
        const clipped_node = try scene.owner(clipped).scene.getNode(clipped.object.index);
        const cleared_node = try scene.owner(cleared).scene.getNode(cleared.object.index);
        try t.expect(clipped_node.picture.clip != null);
        try t.expect(clipped_node.picture.clip.?.count != 0);
        try t.expect(cleared_node.picture.clip == null);
    }
}

test "fillet rounds polygons and rounded_rect accepts per-corner radii" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*
            \\import geometry.fillet
            \\import assertions.assert
            \\tri:=path([(0pt,0pt),(20pt,0pt),(8pt,12pt)],true)
            \\all:=fillet(tri,1pt)
            \\some:=fillet(tri,[1pt,0pt,2pt])
            \\rect:=rounded_rect((0pt,0pt),30pt,20pt,[2pt,4pt,6pt,8pt])
            \\// Each triangle arc takes two cubics; a sharp corner keeps its two
            \\// edges; rectangle corners take one cubic each.
            \\assert(len(all)==9 and len(some)==7 and len(rect)==8)
            \\assert(len(fillet(tri,[1pt]))==len(all))
            \\assert(fillet(tri,0pt)==tri and fillet(tri,[0pt,0pt,0pt])==tri)
            \\p0:=picture(30pt,30pt);append(p0,object(all))
            \\p1:=picture(30pt,30pt);append(p1,object(some))
            \\p2:=picture(30pt,30pt);append(p2,object(rect))
            \\export p0,p1,p2
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][]const u8{ "p0", "p1", "p2" }) |name| {
            var svg = try runtime.render(machine.getGlobal(name).?, .svg);
            defer svg.deinit();
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        }
    }
}

test "standard brushes and engraving compose with user profiles retained text and native exports" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.cos;import paint.{rgb, translate, rectangle, circle, path, smooth, transformed, fill, label, picture};import pen.profile_outline;import math;import brush
        \\import engraving
        \\fn user_outline(curve:path, width:length) -> path
        \\    positions:=[]; widths:=[]
        \\    for i in 0:16 do
        \\        u:=float(i)/16
        \\        positions += u
        \\        widths += width*(0.7+0.2*cos(4*math.PI*u))
        \\    end
        \\    return profile_outline(curve,positions,widths,"round","round")
        \\end
        \\export pic:=picture(160mm,130mm)
        \\ink:=rgb(0.1,0.2,0.35)
        \\curve:=smooth([(10mm,100mm),(55mm,115mm),(100mm,95mm),(150mm,110mm)])
        \\object.append(pic, object.fill(brush.tapered(curve,3mm,24), ink))
        \\object.append(pic, brush.rainbow(transformed(curve,translate((0,-20mm))),2mm,40))
        \\object.append(pic, object.fill(user_outline(path((10mm,70mm),(65mm,70mm)),2mm), ink))
        \\object.append(pic, engraving.hatch(rectangle((80mm,62mm),25mm,15mm),2mm,0.3mm,30deg,ink))
        \\object.append(pic, engraving.dots(circle((130mm,69mm),9mm),2mm,0.3mm,ink))
        \\object.append(pic, engraving.sphere((30mm,35mm),14mm,ink,20))
        \\object.append(pic, engraving.tube(smooth([(65mm,30mm),(100mm,50mm),(140mm,30mm)]),10mm,ink,9,30))
        \\object.append(pic, object.label(typ[Library strokes Ω], (10mm,120mm)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var library_function = false;
        for (program.functions) |function| {
            if (std.mem.eql(u8, function.name, "rainbow")) library_function = true;
        }
        try t.expect(library_function);
        for (0..2) |_| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try execute(&machine);
            var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
            defer svg.deinit();
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
            try t.expect(std.mem.indexOf(u8, svg.bytes(), "<clipPath") != null);
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        }
    }
}

test "standard module private functions and unknown modules remain diagnosed" {
    for ([_]bool{ false, true }) |optimize| {
        for ([_]struct { source: []const u8, message: []const u8 }{
            .{ .source = "import brush\nc:=brush.hue_rgb(1)", .message = "does not export 'hue_rgb'" },
            .{ .source = "import std.circle", .message = "does not export 'circle'" },
            .{ .source = "import std.assert", .message = "does not export 'assert'" },
            .{ .source = "import std.paint.brush", .message = "does not export 'brush'" },
            .{ .source = "import paint.minus", .message = "does not export 'minus'" },
            .{ .source = "import paint.timeline", .message = "does not export 'timeline'" },
            .{ .source = "import \"std/missing.huak\" as missing", .message = "unknown standard library module" },
            .{ .source = "import paint.{path, picture};rainbow(picture(640, 480),path((0,0),(10,0)),1mm,10)", .message = "unknown function 'rainbow'" },
            .{ .source = "import paint.*;p:=picture(transform:translate((0pt,0pt)))", .message = "unknown argument 'transform' for 'picture'" },
            .{ .source = "import paint.*;p:=picture(clip:rectangle((0pt,0pt),1pt,1pt))", .message = "unknown argument 'clip' for 'picture'" },
            .{ .source = "import paint.*;p:=path((0pt,0pt),(1pt,1pt));p.clip(rectangle((0pt,0pt),1pt,1pt))", .message = "expected picture, found path" },
            .{ .source = "import paint.*;p:=path((0pt,0pt),(1pt,1pt));reset_clip(p)", .message = "expected picture, found path" },
        }) |case| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, case.source, "private-standard-library.huak", .{ .optimize = optimize }, &diagnostic));
            if (std.mem.indexOf(u8, diagnostic.?.text(), case.message) == null)
                std.debug.print("expected '{s}' in diagnostic '{s}'\n", .{ case.message, diagnostic.?.text() });
            try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
        }
    }
}

test "standard drawing recipes return whole-object handles including empty strokes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*;import animation.{timeline, animate}
        \\import brush
        \\import engraving
        \\pic:=picture(100,100)
        \\curve:=(0,0)--(10,0)
        \\area:=rectangle((0,0),20,20)
        \\ink:=rgb(0,0,0)
        \\objects:=[object.append(pic, brush.rainbow(curve,1pt,3)),object.append(pic, brush.rainbow(curve,0pt,3)),
        \\    object.append(pic, engraving.hatch(area,10pt,1pt,0deg,ink)),object.append(pic, engraving.hatch(area,10pt,0pt,0deg,ink)),
        \\    object.append(pic, engraving.dots(area,10pt,1pt,ink)),object.append(pic, engraving.sphere((30pt,30pt),5pt,ink,4)),
        \\    object.append(pic, engraving.tube(curve,3pt,ink,3,3))]
        \\pic.timeline(1)
        \\for i in 0:len(objects)-1 do
        \\    obj:object:=objects[i]
        \\    animate(obj,"opacity",[[0,0],[1,1]])
        \\end
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    // Seven whole objects animate; their identical tracks share one class.
    try t.expectEqual(@as(usize, 7), std.mem.count(u8, svg.bytes(), "class=\"huak-a"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), ".huak-a"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "@keyframes "));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg.bytes(), "stroke=\"url(#"));
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<linearGradient") != null);
}

test "standard brushes avoid pen-up bridges and zero-width PDF hairlines" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{rgb, rectangle, circle, path, picture};import geometry.clipped;import brush
        \\import engraving
        \\ink:=rgb(0,0,0); pic:=picture(640, 480)
        \\curve:=path((0,0),(10,0))
        \\object.append(pic, brush.rainbow(curve,0pt,10))
        \\object.append(pic, engraving.hatch(rectangle((0,0),20,20),2,0pt,0deg,ink))
        \\closed:=brush.tapered(circle((50,50),10),2pt,20)
        \\compound:=clipped(path([(-10,0),(10,0),(10,10),(-10,10)]),(0,-1),(5,11))
        \\gap:=picture(640, 480); object.append(gap, brush.rainbow(compound,1pt,5))
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var picture = try scene.view(machine.getGlobal("pic").?);
    defer picture.deinit();
    try t.expect((try picture.picture.bounds()) == null);
    const closed = runtime.path_values.items[machine.getGlobal("closed").?.handle.index];
    try t.expect(closed.segments.items.len > 0);
    var gap = try scene.view(machine.getGlobal("gap").?);
    defer gap.deinit();
    var strokes: usize = 0;
    for (gap.picture.commands.items) |command| {
        if (command != .path) continue;
        strokes += 1;
        const range = command.path.path;
        const segment = try gap.picture.range(range);
        try t.expectApproxEqAbs(segment[0].move.y, segment[1].line.y, 1e-10);
        try t.expect(segment[0].move.y == 0 or segment[0].move.y == 10);
    }
    try t.expectEqual(@as(usize, 8), strokes);
}

test "standard directional envelope mixfix aliases and ordinary calls share the native builtin" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_][]const u8{
        \\import paint.{rgb, rectangle, fill, picture};import pen.pensquare;import paint.envelope as side
        \\export side
        \\brush:=pensquare(4pt)
        \\curve:=rectangle((20,20),60,40)
        \\boundary:=side(curve,brush)
        \\pic:=picture(100,80)
        \\object.append(pic, object.fill(boundary, rgb(0.1,0.4,0.8)))
        ,
        \\import paint.{rgb, rectangle, fill, picture};import pen.pensquare;import paint.envelope as side
        \\export side
        \\brush:=pensquare(4pt)
        \\curve:=rectangle((20,20),60,40)
        \\boundary:=envelope of curve with brush
        \\pic:=picture(100,80)
        \\object.append(pic, object.fill(boundary, rgb(0.1,0.4,0.8)))
        ,
    };
    for ([_]bool{ false, true }) |optimize| {
        var expected_svg: ?[]u8 = null;
        defer if (expected_svg) |bytes| t.allocator.free(bytes);
        var expected_steps: ?u64 = null;
        for (sources) |source| {
            var program = try compile(&library, source, optimize);
            defer program.deinit();
            const exposed = program.exports[0];
            try t.expect(exposed.target == .builtin);
            try t.expect(exposed.target.builtin == .envelope);
            try t.expectEqualStrings("of", exposed.mixfix[0].?.parts[0].?);
            try t.expectEqualStrings("with", exposed.mixfix[0].?.parts[2].?);
            for (0..2) |_| {
                var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
                defer runtime.deinit();
                var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
                defer machine.deinit();
                try execute(&machine);
                var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
                defer svg.deinit();
                if (expected_svg) |bytes| {
                    try t.expectEqualStrings(bytes, svg.bytes());
                    try t.expectEqual(expected_steps.?, machine.steps);
                } else {
                    expected_svg = try t.allocator.dupe(u8, svg.bytes());
                    expected_steps = machine.steps;
                }
            }
        }
    }
}

test "standard brush policies validate their own style parameters" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        for ([_]struct { call: []const u8, message: []const u8 }{
            .{ .call = "brush.tapered(curve,-1mm,12)", .message = "width must be nonnegative" },
            .{ .call = "object.append(pic, brush.rainbow(curve,1mm,1))", .message = "at least two samples" },
            .{ .call = "object.append(pic, engraving.hatch(region,0pt,1pt,0deg,ink))", .message = "spacing must be positive" },
            .{ .call = "object.append(pic, engraving.dots(region,1mm,0pt,ink))", .message = "radius must be positive" },
            .{ .call = "object.append(pic, engraving.sphere((0,0),1mm,ink,2))", .message = "at least four" },
            .{ .call = "object.append(pic, engraving.tube(curve,1mm,ink,2,12))", .message = "at least three" },
        }) |case| {
            const source = try std.fmt.allocPrint(t.allocator,
                \\import paint.{{rgb, rectangle, path, picture}};import brush
                \\import engraving
                \\pic:=picture(640, 480); ink:=rgb(0,0,0)
                \\curve:=path((0,0),(10mm,0)); region:=rectangle((0,0),10mm,10mm)
                \\{s}
            , .{case.call});
            defer t.allocator.free(source);
            var program = try compile(&library, source, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, case.message) != null);
        }
    }
}

test "drawing word notation composes the same pictures as ordinary calls" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import drawing.drawing
        \\import paint.{rgb, pen, smooth, bounds, picture, append};import pen.profile_outline;import assertions.assert
        \\import paint
        \\fn draw(value:int)->int return value+1 end
        \\fn pulsed(curve:path, width:length) -> path
        \\    return profile_outline(curve,[0,0.5,1],[width/2,width,width/2],"round","round")
        \\end
        \\mixfix(pulsed) _ pulsed _ in path
        \\curve:=smooth([(5mm,20mm),(20mm,28mm),(40mm,18mm)])
        \\ink:=rgb(0.1,0.3,0.6)
        \\outline_pen:=pen(ink,0.5mm)
        \\caption:=typ[Drawing notation Ω]
        \\words:=picture(100mm,70mm)
        \\ordinary:=picture(100mm,70mm)
        \\drawing words do
        \\    assert(draw(7)==8)
        \\    +fill curve
        \\    +curve paint.tapered 2mm paint.filled ink
        \\    +curve paint.rainbow 1mm paint.shifted (0,-8mm)
        \\    +paint.sphere 4mm paint.shifted (65mm,30mm)
        \\    +curve paint.tube 3mm paint.shifted (0,15mm)
        \\    +curve pulsed 1mm paint.filled ink
        \\    +draw curve with outline_pen
        \\    +caption paint.at (5mm,60mm)
        \\end
        \\append(ordinary, paint.fill(curve))
        \\append(ordinary, copy(paint.filled(paint.tapered(curve,2mm),ink)))
        \\append(ordinary, copy(paint.shifted(paint.rainbow(curve,1mm),(0,-8mm))))
        \\append(ordinary, copy(paint.shifted(paint.sphere(4mm),(65mm,30mm))))
        \\append(ordinary, copy(paint.shifted(paint.tube(curve,3mm),(0,15mm))))
        \\append(ordinary, copy(paint.filled(pulsed(curve,1mm),ink)))
        \\append(ordinary, copy(paint.draw(curve,outline_pen)))
        \\append(ordinary, copy(paint.at(caption,(5mm,60mm))))
        \\assert(bounds(words)==bounds(ordinary))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const words_value = machine.getGlobal("words").?;
        const ordinary_value = machine.getGlobal("ordinary").?;
        var words = try scene.view(words_value);
        defer words.deinit();
        var ordinary = try scene.view(ordinary_value);
        defer ordinary.deinit();
        var ordinary_owned = try ordinary.picture.copy(t.allocator);
        defer ordinary_owned.deinit();
        var words_owned = try words.picture.copy(t.allocator);
        defer words_owned.deinit();
        try t.expectEqualDeep(ordinary_owned.commands.items, words_owned.commands.items);
        try t.expectEqualDeep(ordinary_owned.storage.segments.items, words_owned.storage.segments.items);
        try t.expectEqual(@as(usize, 0), words.picture.scope_depth);
        var svg = try runtime.render(words_value, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(words_value, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
    }
}

test "composed pictures are independent snapshots and word roles preserve target checking" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import drawing.drawing
            \\import paint.{rgb, rectangle, bounds, fill, picture, append};import assertions.assert
            \\import paint
            \\source:=picture()
            \\append(source, copy(rectangle((0,0),10mm,10mm) paint.filled rgb(0,0,0)))
            \\shifted:=source paint.shifted (20mm,0)
            \\snapshot:=picture(640, 480); untouched:=picture(640, 480)
            \\drawing snapshot do
            \\    +shifted
            \\end
            \\before:=bounds(snapshot)
            \\object.append(source, fill(rectangle((100mm,100mm),20mm,20mm)))
            \\assert(bounds(snapshot)==before)
            \\assert(bounds(shifted)==before)
            \\assert(len(bounds(untouched))==0)
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][]const u8{
            "import drawing.drawing; drawing picture() do draw((0,0)--(1,1)) end",
            "import drawing.drawing; drawing picture() do fill(geometry.circle((0,0),1)) end",
            "import drawing.drawing; drawing picture() do filldraw(geometry.circle((0,0),1),color.rgb(0,0,0),pen(color.rgb(1,0,0))) end",
            "import drawing.drawing; drawing picture() do label(typ[Title],(0,0)) end",
            "import paint.append;import paint\nmixfix(append) append _ in logical_or\nappend paint.sphere 1mm",
            "import drawing.drawing;import paint.{path, fill, picture};import paint\npic:=picture(640, 480); drawing pic do; fill path((0,0),(1,1)) paint.shifted (0,0);end",
            "import drawing.drawing;import paint.picture;import paint\npic:=picture(640, 480); drawing pic do; paint.at typ[Missing position];end",
            "import paint\nvalue:=paint.brush.rainbow",
        }) |invalid| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, invalid, "invalid-drawing-notation.huak", .{ .optimize = optimize, .source_parser = .init(&library) }, &diagnostic));
            try t.expect(diagnostic != null);
        }
    }
}

test "cut composes many holes in one clip and preserves native text canvas and off-canvas geometry" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const input =
        \\import paint.{translate, fill, label, append};import paint.*;import geometry.compound
        \\source:=picture(120pt,40pt)
        \\alias:=source
        \\object.append(source, object.fill(rectangle((-10pt,-5pt),150pt,50pt), rgb(0.1,0.3,0.7)))
        \\caption:=typ[Retained native text]
        \\object.append(source, object.label(caption, (5pt,25pt)))
        \\holes:=[]
        \\for i in 0:139 do
        \\    holes+=rectangle((float(i)*0.75pt,2pt),0.3pt,2pt)
        \\end
        \\hole:=compound(holes)
        \\ordinary:=cut(source,hole)
        \\words:=source cut hole
        \\method:=source.cut(hole)
        \\noholes:=cut(source,compound([]))
        \\removed:=cut(source,rectangle((-1000pt,-1000pt),2000pt,2000pt))
        \\empty:=cut(picture(),hole)
        \\reused:=picture(300pt,100pt)
        \\reused.append(copy(ordinary), translate((50pt,20pt)))
        \\object.append(source, object.fill(rectangle((200pt,0pt),10pt,10pt)))
        \\current_width:length:=source.width
        \\current_height:length:=source.height
        \\animated:bool:=source.animated
        \\output:=picture(source.width,source.height);append(output, copy(ordinary))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, input, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var result = try scene.view(machine.getGlobal("ordinary").?);
        defer result.deinit();
        try t.expectEqual(@as(usize, 1), scene.count(&result, .label));
        var clip_count: usize = 0;
        var label_count: usize = 0;
        for (result.picture.commands.items) |command| switch (command) {
            .push => |group| if (group.clip != null) {
                clip_count += 1;
            },
            .label => label_count += 1,
            else => {},
        };
        try t.expectEqual(@as(usize, 1), clip_count);
        try t.expectEqual(@as(usize, 1), label_count);
        for ([_][]const u8{ "words", "method" }) |name| {
            var other = try scene.view(machine.getGlobal(name).?);
            defer other.deinit();
            try t.expectEqualDeep(result.picture.commands.items, other.picture.commands.items);
            try t.expectEqualDeep(result.picture.storage.segments.items, other.picture.storage.segments.items);
        }
        const box = (try result.picture.bounds()).?;
        try t.expectApproxEqAbs(@as(f64, -10), box.min.x, 1e-8);
        try t.expectApproxEqAbs(@as(f64, -5), box.min.y, 1e-8);
        try t.expectApproxEqAbs(@as(f64, 140), box.max.x, 1e-8);
        try t.expectApproxEqAbs(@as(f64, 45), box.max.y, 1e-8);
        var reused = try scene.view(machine.getGlobal("reused").?);
        defer reused.deinit();
        const reused_box = (try reused.picture.bounds()).?;
        try t.expectApproxEqAbs(@as(f64, 40), reused_box.min.x, 1e-8);
        try t.expectApproxEqAbs(@as(f64, 190), reused_box.max.x, 1e-8);
        var original = try scene.view(machine.getGlobal("source").?);
        defer original.deinit();
        try t.expectEqualDeep(machine.getGlobal("source").?, machine.getGlobal("alias").?);
        try t.expectEqual(@as(usize, 2), scene.count(&original, .path));
        try t.expectEqual(@as(usize, 1), scene.count(&original, .label));
        var noholes = try scene.view(machine.getGlobal("noholes").?);
        defer noholes.deinit();
        try t.expectEqual(@as(usize, 1), scene.count(&noholes, .path));
        try t.expectEqual(@as(usize, 1), scene.count(&noholes, .label));
        var removed = try scene.view(machine.getGlobal("removed").?);
        defer removed.deinit();
        try t.expect((try removed.picture.bounds()) == null);
        var empty = try scene.view(machine.getGlobal("empty").?);
        defer empty.deinit();
        try t.expect((try empty.picture.bounds()) == null);
        try t.expect(!machine.getGlobal("animated").?.boolean);
        try t.expectEqual(@as(usize, 0), runtime.outline_cache.count());
        var svg = try runtime.render(machine.getGlobal("output").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<clipPath") != null);
        var pdf = try runtime.render(machine.getGlobal("output").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        const extracted = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(extracted);
        try t.expect(std.mem.indexOf(u8, extracted, "Retained native text") != null);
    }
}

test "cut validates static input and tolerance without changing aliases" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        const cases = [_]struct { setup: []const u8 = "", call: []const u8, message: []const u8 }{
            .{ .call = "cut(source,hole,0pt)", .message = "cut tolerance must be positive" },
            .{ .call = "cut(source,hole,-1pt)", .message = "cut tolerance must be positive" },
            .{ .call = "cut(source,42)", .message = "region requires a path, text, or object" },
            .{ .call = "region(source,0pt)", .message = "region tolerance must be positive" },
            .{ .setup = "import animation.{timeline, animate};source.timeline(2); animate(id,\"opacity\",[[0,0],[1,1]])", .call = "cut(source,hole)", .message = "cut requires a static object" },
            .{ .setup = "import paint.{circle, fill, picture};import animation.{timeline, animate};cutter:=picture(640, 480); id=object.append(cutter, object.fill(circle((5pt,5pt),2pt))); cutter.timeline(2); animate(id,\"opacity\",[[0,0],[1,1]])", .call = "cut(source,cutter)", .message = "operation requires a static object" },
        };
        for (cases) |fixture| {
            const input = try std.fmt.allocPrint(t.allocator,
                \\import paint.*
                \\import object.region
                \\source:=picture(80pt,60pt); alias:=source
                \\id:=object.append(source, object.fill(rectangle((0pt,0pt),20pt,20pt)))
                \\hole:=rectangle((5pt,5pt),2pt,2pt)
                \\{s}
                \\result:={s}
            , .{ fixture.setup, fixture.call });
            defer t.allocator.free(input);
            var program = try compile(&library, input, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try t.expect(std.mem.indexOf(u8, machine.failure.?.native_message, fixture.message) != null);
            var source = try scene.view(machine.getGlobal("source").?);
            defer source.deinit();
            try t.expectEqual(@as(usize, 1), scene.count(&source, .path));
            try t.expectEqualDeep(machine.getGlobal("source").?, machine.getGlobal("alias").?);
            try t.expect(machine.getGlobal("result") == null);
        }
        var program = try compile(&library,
            \\import paint.*
            \\import animation.timeline
            \\source:=picture(80pt,60pt)
            \\object.append(source, object.fill(rectangle((0pt,0pt),20pt,20pt)))
            \\source.timeline(2)
            \\result:=source cut rectangle((5pt,5pt),2pt,2pt)
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var result = try scene.view(machine.getGlobal("result").?);
        defer result.deinit();
        var clips: usize = 0;
        for (result.picture.commands.items) |command| if (command == .push and command.push.clip != null) {
            clips += 1;
        };
        try t.expectEqual(@as(usize, 1), clips);
    }
}

test "cut outlines independent picture primitives without cancelling overlaps or filling holes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const input =
        \\import paint.*
        \\import geometry.{compound, region_intersection}
        \\import object.{outlines, region}
        \\import assertions.assert
        \\source:=picture(120pt,60pt); alias:=source
        \\object.append(source, object.fill(rectangle((0pt,0pt),80pt,60pt), rgb(0.1,0.3,0.7)))
        \\object.append(source, object.label(typ[Native source text], (4pt,45pt)))
        \\cutter:=picture(80pt,60pt); cutter_alias:=cutter
        \\object.append(cutter, object.fill(rectangle((5pt,5pt),20pt,20pt)))
        \\object.append(cutter, object.fill(reverse(rectangle((10pt,5pt),20pt,20pt))))
        \\ring:=compound([rectangle((40pt,5pt),20pt,20pt),reverse(rectangle((45pt,10pt),10pt,10pt))])
        \\object.append(cutter, object.fill(ring))
        \\object.append(cutter, object.fill(rectangle((65pt,5pt),10pt,20pt), rgb(0,0,0,0)))
        \\parts:=outlines(cutter).paths
        \\result:=source cut cutter
        \\remaining:=region(result)
        \\assert(len(parts)==4)
        \\assert(len(region_intersection(remaining,rectangle((14pt,14pt),1pt,1pt)))==0,"independent reversed paint must not cancel")
        \\assert(len(region_intersection(remaining,rectangle((41pt,14pt),1pt,1pt)))==0,"ring wall must cut")
        \\assert(len(region_intersection(remaining,rectangle((49pt,14pt),1pt,1pt)))>0,"ring hole must remain")
        \\assert(len(region_intersection(remaining,rectangle((69pt,14pt),1pt,1pt)))>0,"alpha zero must not cut")
        \\letter:=typ[O]
        \\direct:=compound(outlines(letter).paths)
        \\again:=compound(outlines(letter).paths)
        \\placed:=picture(80pt,60pt)
        \\object.append(placed, object.label(letter, (30pt,20pt)))
        \\placed_path:=compound(outlines(placed).paths)
        \\text_cut:=source cut placed
        \\baseline_cut:=source cut letter
        \\output:=picture(source.width,source.height);append(output, copy(result))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, input, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var original = try scene.view(machine.getGlobal("source").?);
        defer original.deinit();
        try t.expectEqual(@as(usize, 1), scene.count(&original, .path));
        try t.expectEqual(@as(usize, 1), scene.count(&original, .label));
        try t.expectEqualDeep(machine.getGlobal("source").?, machine.getGlobal("alias").?);
        try t.expectEqualDeep(machine.getGlobal("cutter").?, machine.getGlobal("cutter_alias").?);
        var original_cutter = try scene.view(machine.getGlobal("cutter").?);
        defer original_cutter.deinit();
        try t.expectEqual(@as(usize, 4), scene.count(&original_cutter, .path));
        const direct = runtime.path_values.items[machine.getGlobal("direct").?.handle.index];
        const again = runtime.path_values.items[machine.getGlobal("again").?.handle.index];
        try t.expectEqualDeep(direct.segments.items, again.segments.items);
        const placed = runtime.path_values.items[machine.getGlobal("placed_path").?.handle.index];
        const expected = direct.bounds().?;
        const actual = placed.bounds().?;
        try t.expectApproxEqAbs(expected.min.x + 30, actual.min.x, 0.002);
        try t.expectApproxEqAbs(expected.max.x + 30, actual.max.x, 0.002);
        try t.expectApproxEqAbs(expected.min.y + 20, actual.min.y, 0.002);
        try t.expectApproxEqAbs(expected.max.y + 20, actual.max.y, 0.002);
        for ([_][]const u8{ "result", "text_cut", "baseline_cut" }) |name| {
            var target = try scene.view(machine.getGlobal(name).?);
            defer target.deinit();
            var clip_count: usize = 0;
            var labels: usize = 0;
            for (target.picture.commands.items) |command| switch (command) {
                .push => |group| if (group.clip != null) {
                    clip_count += 1;
                },
                .label => labels += 1,
                else => {},
            };
            try t.expectEqual(@as(usize, 1), clip_count);
            try t.expectEqual(@as(usize, 1), labels);
        }
        var pdf = try runtime.render(machine.getGlobal("output").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
        const extracted = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(extracted);
        try t.expect(std.mem.indexOf(u8, extracted, "Native source text") != null);
    }
}

test "outline picture workers retain independent geometry after their borrowed owners join" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const input =
        \\import paint.{rgb, circle, fill, label, picture, append};import object.outlines;caption:=typ[Worker Ω]
        \\source:=picture(100pt,60pt)
        \\object.append(source, object.label(caption, (10pt,30pt)))
        \\object.append(source, object.fill(circle((70pt,25pt),8pt), rgb(0.2,0.4,0.8)))
        \\first:=figure(source)
        \\second:=figure(source)
        \\fn figure(input:picture)->picture
        \\    result:=picture(input.width,input.height)
        \\    result.append(copy(outlines(input)))
        \\    return result
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, input, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 1), program.task_regions.len);
        try t.expectEqual(@as(usize, 2), program.task_regions[0].tasks.len);
        for (program.task_regions[0].tasks) |task| try t.expect(task.uses_typst);
        var expected: ?[]u8 = null;
        defer if (expected) |bytes| t.allocator.free(bytes);
        var steps: ?u64 = null;
        for ([_]usize{ 1, 4 }) |jobs| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
            executor.attach(&machine);
            try execute(&machine);
            if (jobs == 4) try t.expectEqual(@as(usize, 2), executor.stats.tasks);
            if (steps) |count| try t.expectEqual(count, machine.steps) else steps = machine.steps;
            for ([_][]const u8{ "first", "second" }) |name| {
                var svg = try runtime.render(machine.getGlobal(name).?, .svg);
                defer svg.deinit();
                if (expected) |bytes| try t.expectEqualStrings(bytes, svg.bytes()) else expected = try t.allocator.dupe(u8, svg.bytes());
            }
            var original = try scene.view(machine.getGlobal("source").?);
            defer original.deinit();
            try t.expectEqual(@as(usize, 1), scene.count(&original, .path));
            try t.expectEqual(@as(usize, 1), scene.count(&original, .label));
            var source_pdf = try runtime.render(machine.getGlobal("source").?, .pdf);
            defer source_pdf.deinit();
            const extracted = try @import("support/pdf.zig").text(source_pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(extracted);
            try t.expect(std.mem.indexOf(u8, extracted, "Worker Ω") != null);
        }
    }
}

test "object cut retains overflowing native text images and paint without outlining the source" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*;import geometry.region_xor;import object.region;import assertions.assert
            \\source:=picture()
            \\words:=typ[#box(width:1pt,height:20pt)[#text(size:20pt)[WWW]]]
            \\object.append(source, label(words, (10pt,30pt)))
            \\assert(words.width==1pt and bounds(source)[1].x>60pt)
            \\kept:=cut(source,circle((100pt,30pt),1pt))
            \\assert(len(region_xor(region(source),region(kept)))==0,"a distant cut must preserve all overflowing ink")
            \\native:=typ[#box(width:1pt,height:1pt)[#move(dx:-20pt,dy:-10pt)[
            \\ #image(bytes("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='30'><rect width='40' height='30' fill='red'/></svg>"),width:40pt,height:30pt)
            \\ #rect(width:40pt,height:30pt,fill:gradient.linear(red,blue))
            \\]]]
            \\art:=picture()
            \\object.append(art, label(native, (40pt,40pt)))
            \\art_cut:=cut(art,circle((110pt,30pt),1pt))
            \\assert(bounds(art)==bounds(art_cut))
            \\export plate:=picture(120pt,100pt)
            \\append(plate, copy(kept))
            \\append(plate, copy(art_cut))
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var svg = try runtime.render(machine.getGlobal("plate").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<image") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<linearGradient") != null);
        var pdf = try runtime.render(machine.getGlobal("plate").?, .pdf);
        defer pdf.deinit();
        const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "WWW") != null);
    }
}

test "object instances retain native text local copies world snapshots and independent styles" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*;import assertions.assert
            \\root:=picture()
            \\g:=picture()
            \\object.transform(g, translate((20pt,0pt)))
            \\object.append(root, g)
            \\curve:=rectangle((0pt,0pt),10pt,10pt)
            \\a:=object.append(g, fill(curve, rgb(1,0,0)))
            \\b:=object.append(g, fill(curve, rgb(0,0,1), translate((15pt,0pt))))
            \\words:=object.append(g, label(typ[Retained objects], (0pt,30pt)))
            \\assert(a.kind=="path" and words.kind=="text" and g.kind=="picture")
            \\assert(a.parent==g and words.parent==g and g.parent==root)
            \\assert(g.children==[a,b,words])
            \\saved:=object.snapshot(a)
            \\local:=copy(a)
            \\assert(local.kind=="path")
            \\assert(bounds(saved)[0]==(20pt,0pt) and bounds(local)[0]==(0pt,0pt))
            \\object.style(a,fill:rgb(0,1,0))
            \\assert(local.pen==false)
            \\object.transform(g,translate((5pt,0pt)))
            \\assert(bounds(a)[0]==(25pt,0pt) and bounds(saved)[0]==(20pt,0pt))
            \\object.show(words,false)
            \\cloned:=copy(g)
            \\assert(not cloned.children[2].visible)
            \\object.show(words,true)
            \\assert(words.visible and not cloned.children[2].visible)
            \\object.before(words,a)
            \\assert(g.children==[words,a,b])
            \\other:=append(root, copy(g), translate((0pt,40pt)))
            \\assert(other.kind=="picture" and len(other.children)==3 and other.children[0].kind=="text")
            \\object.remove(b)
            \\assert(len(g.children)==2 and len(other.children)==3)
            \\export plate:=picture(120pt,100pt)
            \\append(plate, copy(root))
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const original = machine.getGlobal("a").?.object;
        const cloned = machine.getGlobal("local").?.object;
        const original_owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(original.owner));
        const cloned_owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(cloned.owner));
        try t.expectEqualDeep(huak.core.DisplayList.Color{ .r = 0, .g = 1, .b = 0 }, (try original_owner.scene.getNode(original.index)).path.style.fill.?);
        try t.expectEqualDeep(huak.core.DisplayList.Color{ .r = 1, .g = 0, .b = 0 }, (try cloned_owner.scene.getNode(cloned.index)).path.style.fill.?);
        const output = machine.getGlobal("plate").?;
        var svg = try runtime.render(output, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(output, .pdf);
        defer pdf.deinit();
        const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expectEqual(@as(usize, 2), std.mem.count(u8, text, "Retained objects"));
    }
}

test "erase keeps live siblings in paint order with parent-space dashed strokes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*;import geometry.region_intersection;import pen.{pensquare, profile_outline};import object.region;import assertions.assert
            \\fn ink(obj:object, x:length, y:length) -> bool
            \\    return len(region_intersection(region(obj),rectangle((x,y),0.5pt,0.5pt)))>0
            \\end
            \\export page:=picture(90pt,40pt)
            \\g:=picture()
            \\object.transform(g,translate((2pt,3pt)))
            \\append(page,g)
            \\band:=fill(rectangle((0pt,0pt),40pt,20pt),rgb(1,0,0))
            \\grid:=copy(band); curve:=copy(band); later:=copy(band)
            \\sweep:=(0pt,10pt)--(40pt,10pt)
            \\brush:=pen(rgb(0,0,0,0),cap:"butt",dash:[8pt,8pt],nib:pensquare(4pt))
            \\drawing g do
            \\    +band; +grid; +curve
            \\    erase sweep from [curve,band,curve] with brush
            \\    erase ((20pt,0pt)--(20pt,20pt)) from [band] with pensquare(3pt)
            \\    erase sweep from [] with brush
            \\    +later
            \\end
            \\assert(g.children==[band,grid,curve,later] and band.parent==g)
            \\assert(not ink(band,6pt,13pt) and not ink(curve,6pt,13pt))
            \\assert(ink(grid,6pt,13pt) and ink(later,6pt,13pt))
            \\assert(ink(curve,14pt,13pt) and not ink(band,22pt,7pt))
            \\object.before(curve,band)
            \\assert(g.children[0]==curve and not ink(curve,6pt,13pt))
            \\saved:=copy(g); assert(not ink(saved.children[0],6pt,13pt))
            \\object.transform(curve,translate((45pt,0pt)))
            \\assert(ink(curve,51pt,13pt))
            \\object.remove(band); assert(ink(band,4pt,10pt))
            \\tile:=fill(rectangle((1pt,1pt),2pt,2pt),rgb(1,0,0))
            \\drawing page do
            \\    +tile
            \\    erase ((0pt,2pt)--(5pt,2pt)) from [tile] with pensquare(8pt)
            \\end
            \\assert(len(bounds(tile))==0 and len(region(tile))==0)
            \\export covered:=picture(8pt,8pt)
            \\append(covered,object.snapshot(tile))
            \\object.transform(tile,translate((60pt,0pt)))
            \\assert(ink(tile,61pt,1pt))
            \\plate:=rectangle((0pt,0pt),44pt,20pt) filled rgb(0,0,1)
            \\centerline:=(2pt,10pt)--(42pt,10pt)
            \\footprint:=profile_outline(centerline,[0,0.5,1],[2pt,14pt,2pt],"butt","round")
            \\drawing page do
            \\    +plate
            \\    erase footprint from [plate]
            \\end
            \\assert(not ink(plate,5pt,10pt) and ink(plate,5pt,14pt))
            \\assert(not ink(plate,22pt,14pt) and ink(plate,22pt,19pt))
            \\stops:=[[0,2pt],[0.5,14pt],[1,2pt]]
            \\pressure:=pen(rgb(0,0,1),profile:stops,join:"round")
            \\stops += [1,99pt]
            \\reference_mask:=rectangle((0pt,0pt),44pt,20pt) filled rgb(1,0,0)
            \\export profiled:=picture(44pt,20pt)
            \\drawing profiled do
            \\    painted:=draw centerline with pressure
            \\    +painted
            \\    +reference_mask
            \\    erase centerline from [reference_mask] with painted.pen
            \\    assert(ink(painted,22pt,14pt) and not ink(painted,5pt,14pt))
            \\    assert(not ink(reference_mask,22pt,14pt) and ink(reference_mask,5pt,14pt))
            \\end
            \\label_obj:=typ[Live label] at (0pt,25pt)
            \\drawing page do
            \\    +label_obj
            \\    erase ((6pt,22pt)--(6pt,36pt)) from [label_obj] with pensquare(3pt)
            \\end
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const page = machine.getGlobal("page").?;
        var pressure_svg = try runtime.render(machine.getGlobal("profiled").?, .svg);
        defer pressure_svg.deinit();
        try t.expect(std.mem.indexOf(u8, pressure_svg.bytes(), "<clipPath") != null);
        var svg = try runtime.render(page, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<clipPath") != null);
        var pdf = try runtime.render(page, .pdf);
        defer pdf.deinit();
        const words = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(words);
        try t.expect(std.mem.indexOf(u8, words, "Live label") != null);
        // The PDF backend must keep a fully erased node invisible even
        // when its unmasked source path would cover the inspected pixels.
        var covered = try runtime.render(machine.getGlobal("covered").?, .pdf);
        defer covered.deinit();
        var temporary = t.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(t.io, .{ .sub_path = "covered.pdf", .data = covered.bytes() });
        const raster = try std.process.run(t.allocator, t.io, .{
            .argv = &.{ "pdftoppm", "-r", "72", "-singlefile", "covered.pdf" },
            .cwd = .{ .dir = temporary.dir },
        });
        defer t.allocator.free(raster.stdout);
        defer t.allocator.free(raster.stderr);
        try t.expect(raster.term.success());
        const header = "P6\n8 8\n255\n";
        try t.expectEqual(header.len + 8 * 8 * 3, raster.stdout.len);
        try t.expect(std.mem.startsWith(u8, raster.stdout, header));
        try t.expect(std.mem.allEqual(u8, raster.stdout[header.len..], 255));
    }
}

test "standalone path and text objects need no drawing container" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*;import assertions.assert
            \\curve:=rectangle((0pt,0pt),20pt,10pt)
            \\plain:=object(curve)
            \\assert(plain.kind=="path" and plain.parent==false)
            \\assert(plain.fill!=false and plain.pen==false)
            \\fill_obj:=curve filled rgb(0.2,0.4,0.8)
            \\stroke_obj:=draw(curve,pen(rgb(0.8,0.2,0.1),1pt))
            \\words:=typ[Standalone objects]
            \\caption:=object(words)
            \\placed:=words at (0pt,35pt)
            \\assert(fill_obj.kind=="path" and stroke_obj.kind=="path")
            \\assert(fill_obj.parent==false and stroke_obj.parent==false)
            \\assert(stroke_obj.fill==false and stroke_obj.pen!=false)
            \\assert(caption.kind=="text" and placed.kind=="text")
            \\assert(caption.parent==false and placed.parent==false)
            \\assert(math.abs(bounds(placed)[0].y-bounds(caption)[0].y-35pt)<1e-10pt)
            \\local:=copy(fill_obj)
            \\assert(local.kind=="path" and local.parent==false)
            \\export plate:=picture(150pt,60pt)
            \\assert(len(plate.children)==0)
            \\inserted:=append(plate, copy(fill_obj))
            \\append(plate, copy(stroke_obj), translate((30pt,0pt)))
            \\append(plate, copy(placed))
            \\assert(inserted.parent==plate and fill_obj.parent==false)
            \\assert(len(plate.children)==3)
            \\other:=picture(150pt,60pt)
            \\other.append(copy(plate))
            \\mixfix(append) _ append _ in path
            \\drawing other do
            \\    +fill_obj
            \\    object.append(other, stroke_obj)
            \\end
            \\assert(len(other.children)==3)
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        var pdf = try runtime.render(machine.getGlobal("plate").?, .pdf);
        defer pdf.deinit();
        const text = try @import("support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Standalone objects"));
    }
}

test "motion expressions retain units and composition order through painted and erased strokes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library,
            \\import paint.*; import std.pen_motion.*; import pen.pensquare; import assertions.assert
            \\t := 7
            \\turn := moving() do
            \\    return (scaling x (1 + t * t) y (1 - t / 2)) followed by (rotation by (90deg * t))
            \\end
            \\assert(t + 3 == 10)
            \\nib := pen(rgb(0.2,0.4,0.7), nib:pensquare(4pt), motion:turn, tolerance:0.01pt)
            \\p := (4pt,8pt) -- (24pt,8pt)
            \\export page := drawing picture(30pt,16pt) do
            \\    mask := rectangle((0pt,0pt),30pt,16pt) filled rgb(1,0,0)
            \\    +draw p with nib; +mask
            \\    erase p from [mask] with nib
            \\end
            \\export painted := page.children[0]
        , optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const obj = machine.getGlobal("painted").?.object;
        const owner: *const l.Runtime.SceneOwner = @ptrCast(@alignCast(obj.owner));
        const motion = (try owner.scene.getNode(obj.index)).path.style.pen.?.motion.?;
        const halfway = motion.at(0.5);
        const expected = huak.core.geometry.Transform.scaling(1.25, 0.75).then(huak.core.geometry.Transform.rotation(std.math.pi / 4.0));
        inline for (.{ "a", "b", "c", "d" }) |field| try t.expectApproxEqAbs(@field(expected, field), @field(halfway, field), 1e-14);
        var svg = try runtime.render(machine.getGlobal("page").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<clipPath") != null);
    }
}

test "standard library normal motion composes with scale in SVG and PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import std.pen_motion.*; import pen.pensquare
        \\turn := (scaling x 4 y 1) followed by along_normal()
        \\ink := pen(rgb(0.2,0.4,0.7), nib:pensquare(2pt), motion:turn, tolerance:0.05pt)
        \\p := (10pt,4pt) -- (10pt,20pt)
        \\export page := drawing picture(25pt,25pt) do +draw p with ink end
        \\guide := bezier((5pt,8pt),(18pt,30pt),(32pt,2pt),(45pt,20pt))
        \\export curved := drawing picture(50pt,32pt) do +draw guide with ink end
        \\import object.region
        \\export footprint := region(page.children[0])
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const footprint = try runtime.path(machine.getGlobal("footprint").?);
    const box = footprint.bounds().?;
    try t.expectApproxEqAbs(@as(f64, 8), box.width(), 1e-10);
    try t.expectApproxEqAbs(@as(f64, 18), box.height(), 1e-10);
    var svg = try runtime.render(machine.getGlobal("curved").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(machine.getGlobal("curved").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "normal nib corner choices share one guide but yield distinct painted regions" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import pen_motion.*; import pen.pensquare
        \\import object.region; import geometry.region_intersection; import assertions.assert
        \\guide := (2pt,14pt) -- (14pt,14pt) -- (14pt,26pt)
        \\fn brush(mode:string) -> pen
        \\    turn := (scaling x 4 y 0.25) followed by along_normal(corner:mode)
        \\    return pen(rgb(0,0,0),nib:pensquare(2pt),motion:turn,tolerance:0.02pt)
        \\end
        \\pivot := draw(guide,brush("rotate"))
        \\jump := draw(guide,brush("overlap"))
        \\probe := rectangle((16.5pt,11.4pt),0.1pt,0.1pt)
        \\assert(len(region_intersection(region(pivot,0.02pt),probe))>0)
        \\assert(len(region_intersection(region(jump,0.02pt),probe))==0)
        \\import pen.{makepen,stroke_outline}; import geometry.{subpaths,region_difference}
        \\blade := makepen((-1.1pt,0pt) -- (1.1pt,0pt) -- cycle)
        \\seal := stroke_outline(rectangle((2.6pt,2.6pt),94.8pt,94.8pt),pen(rgb(0,0,0),nib:blade,motion:along_normal(corner:"rotate")))
        \\assert(len(subpaths(seal))==2)
        \\assert(len(region_difference(circle((2.2pt,2.2pt),0.1pt),seal))==0)
        \\assert(len(region_intersection(circle((50pt,50pt),1pt),seal))==0)
        \\export page := drawing picture(32pt,32pt) do +pivot; +jump end
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var svg = try runtime.render(machine.getGlobal("page").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(machine.getGlobal("page").?, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}

test "Hobby knot directions survive picture storage, region extraction and both exports" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.*; import pen.pensquare; import pen_motion.*; import object.region; import assertions.assert
        \\knots := [(0pt,0pt),(60pt,80pt),(130pt,20pt),(210pt,90pt)]
        \\motion := (scaling x 3 y 1) followed by along_normal()
        \\brush := pen(rgb(0.2,0.4,0.7),nib:pensquare(2pt),motion:motion,tolerance:0.02pt)
        \\spine := knots[0] ~~ knots[1] ~~ knots[2] ~~ knots[3]
        \\export page := drawing picture(240pt,130pt) do +draw spine with brush; +draw smooth(knots) with brush end
        \\assert(len(region(page.children[0],0.02pt))>0)
    , true);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const page = machine.getGlobal("page").?;
    var svg = try runtime.render(page, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    var pdf = try runtime.render(page, .pdf);
    defer pdf.deinit();
    try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
}
