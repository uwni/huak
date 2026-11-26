//! The standard module surface: root namespaces and identities, narrow imports, the paint prelude, clip accumulation, fillets and private functions.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const scene = @import("../support/scene.zig");
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

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
        const names = [_][]const u8{ "math", "geometry", "color", "pen", "transform", "picture", "object", "text", "animation", "solver", "assertions", "collections", "brush", "engraving", "paint", "weave", "regions", "pen_motion", "solving" };
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
