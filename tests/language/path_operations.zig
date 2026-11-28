//! Operations on existing paths: subpaths, queries and clipping, Hobby and the linear solver, and directional envelopes.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const scene = @import("../support/scene.zig");
const harness = @import("harness.zig");
const compileModulesOptimized = harness.compileModulesOptimized;
const execute = harness.execute;
const compile = harness.compile;

test "subpaths preserve contour chains through namespaces UFCS lists and native color rendering" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*;import geometry.{compound, subpaths, region_difference};import object.region;import assertions.assert
        \\import geometry as geo
        \\import geometry.subpaths as split
        \\open:=bezier((0pt,0pt),(0pt,8pt),(12pt,8pt),(12pt,0pt))
        \\outer:=rectangle((20pt,0pt),12pt,12pt)
        \\hole:=reverse(rectangle((23pt,3pt),6pt,6pt))
        \\stationary:=path((50pt,7pt))
        \\multi:=compound([open,outer,hole,stationary])
        \\parts:=geo.subpaths(curve:multi)
        \\assert(len(parts)==4)
        \\assert(len(parts[0])==1 and len(parts[1])==4 and len(parts[2])==4 and len(parts[3])==0)
        \\assert(bounds(parts[0])==bounds(open) and bounds(parts[1])==bounds(outer))
        \\assert(bounds(parts[2])==bounds(hole) and bounds(parts[3])==bounds(stationary))
        \\assert(len(multi.split())==4 and len(subpaths(multi))==4)
        \\assert(len(geo.subpaths(compound([])))==0)
        \\rejoined:=compound(parts)
        \\parts[0]=transformed(parts[0],translate((100pt,0pt)))
        \\parts+=outer
        \\assert(len(parts)==5 and bounds(parts[0])[0].x==100pt)
        \\assert(bounds(open)[0].x==0pt and bounds(rejoined)==bounds(multi))
        \\letter_style:=typ.module[#let style(body) = {set text(font:"Libertinus Serif",size:30pt); body}]
        \\typ.show letter_style.style
        \\letter:=region(typ[O])
        \\loops:=letter.split()
        \\assert(len(loops)==2)
        \\plate:=rectangle((0pt,0pt),30pt,20pt)
        \\cuts:=compound([rectangle((8pt,-1pt),2pt,22pt),rectangle((20pt,-1pt),2pt,22pt)])
        \\regions:=subpaths(region_difference(plate,cuts))
        \\assert(len(regions)==3)
        \\colors:=[rgb(1,0,0),rgb(0,1,0),rgb(0,0,1)]
        \\pic:=picture(30pt,20pt)
        \\for i in 0:len(regions)-1 do object.append(pic, fill(regions[i], colors[i])) end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const original = runtime.path_values.items[machine.getGlobal("multi").?.handle.index];
        const rejoined = runtime.path_values.items[machine.getGlobal("rejoined").?.handle.index];
        try t.expectEqualDeep(original.segments.items, rejoined.segments.items);
        const loops = machine.getGlobal("loops").?.list.items();
        const outside = runtime.path_values.items[loops[0].handle.index];
        const inside = runtime.path_values.items[loops[1].handle.index];
        try t.expect(outside.signedArea() * inside.signedArea() < 0);
        try t.expect(!outside.open and !inside.open);
        const letter = runtime.path_values.items[machine.getGlobal("letter").?.handle.index];
        try t.expect(outside.segments.items.ptr != letter.segments.items.ptr);
        try t.expect(inside.segments.items.ptr != outside.segments.items.ptr);
        const pic = machine.getGlobal("pic").?;
        try t.expectEqual(@as(usize, 3), try scene.childCount(pic));
        var svg = try runtime.render(pic, .svg);
        defer svg.deinit();
        for ([_][]const u8{ "<svg", "#ff0000", "#00ff00", "#0000ff" }) |marker|
            try t.expect(std.mem.find(u8, svg.bytes(), marker) != null);
        var pdf = try runtime.render(pic, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
    }
    for ([_][]const u8{ "geometry.subpaths(1)", "geometry.subpaths()", "geometry.subpaths(path((0,0)),path((1,1)))" }) |invalid| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, l.compiler.compile(t.allocator, invalid, "invalid-subpaths.huak", .{}, &diagnostic));
        try t.expect(diagnostic != null);
    }
}

test "bytecode calls existing Hobby and linear solver and exports a true native scene" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.abs;import solver.{unknown, equation, solve, value};import paint.{rgb, pen, translate, smooth, reverse, transformed, bounds, draw, picture};import geometry.trimmed;import assertions.assert
        \\pic:=picture(200,100)
        \\s:=solver(); x:=unknown(s); y:=unknown(s)
        \\equation(s,2*x+y,8); equation(s,x-y,1)
        \\result:=solve(s)
        \\assert(result.status=="unique"); assert(result.rank==2)
        \\assert(abs(value(result,x)-3)<0.000001)
        \\assert(abs(value(result,y)-2)<0.000001)
        \\tiny:=(1e-320*x)/1e-320; positive:=+x
        \\assert(positive==x)
        \\equation(s,tiny,3)
        \\p:=smooth([(10,10),(50,70),(100,20)])
        \\q:=transformed(reverse(p),translate((20,0)))
        \\object.append(pic, object.draw(p)); object.append(pic, draw(q, pen(rgb(0,0.2,0.8),2)))
        \\box:=bounds(p); assert(box[0].x<=10pt)
        \\assert(len(trimmed(p,0,1))==1)
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    const knots = [_]huak.core.hobby.Knot{ .{ .point = .{ .x = 10, .y = 10 } }, .{ .point = .{ .x = 50, .y = 70 } }, .{ .point = .{ .x = 100, .y = 20 } } };
    const reference = try huak.core.hobby.interpolate(t.allocator, &knots, .{});
    defer t.allocator.free(reference);
    const first = runtime.path_values.items[machine.getGlobal("p").?.handle.index].segments.items[1].cubic;
    try t.expectApproxEqAbs(reference[0].p1.x, first.c1.x, 1e-12);
    try t.expectApproxEqAbs(reference[0].p2.y, first.c2.y, 1e-12);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.find(u8, svg.bytes(), "<svg") != null);
    try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
}

test "path queries clipping picture copies and animation motion reuse core operations" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.norm;import paint.{rgb, translate, circle, path, joined, draw, fill, picture, append};import geometry.{point_at, tangent_at, intersections, clipped};import animation.{timeline, motion};import assertions.assert
        \\pic:=picture(100,100)
        \\p:=path((0,0),(10,0)); q:=path((10,0),(20,0))
        \\joined_path:=joined(p,q)
        \\assert(point_at(joined_path,1.5)==(15pt,0))
        \\assert(norm(tangent_at(joined_path,0.5))>0pt)
        \\assert(len(clipped(joined_path,(5,-1),(15,1)))==2)
        \\cross:=intersections(p,path((5,-5),(5,5)))
        \\assert(len(cross)==1); assert(norm(cross[0]-(5pt,0))<0.00001pt)
        \\child:=picture(640, 480); object.append(child, object.draw(joined_path)); pic.append(copy(child)); pic.append(copy(child), translate((0,20)))
        \\ball:=object.append(pic, object.fill(circle((0,0),2), rgb(0,0,1)))
        \\pic.timeline(1); motion(ball,joined_path,[[0,0],[1,1]],"none")
    ;
    var program = try compile(&library, source);
    defer program.deinit();
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.find(u8, svg.bytes(), "offset-path:path(") != null);
}

test "directional envelope preserves orientation subpaths and strict zero-line semantics through the VM" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, pen, envelope, rectangle, circle, path, reverse};import geometry.{clipped, region_union};import pen.{pensquare, stroke_outline};shape:=pensquare(4pt)
        \\ink:=rgb(0.2,0.4,0.7)
        \\curve:=circle((40,40),15)
        \\outside:=envelope(curve,shape)
        \\inside:=envelope(reverse(curve),shape)
        \\complete:=stroke_outline(curve,shape)
        \\compound:=region_union(rectangle((0,0),10,10),rectangle((30,0),10,10))
        \\multiple:=envelope(compound,shape)
        \\split:=clipped(path([(-10,0),(10,0),(10,10),(-10,10)]),(0,-1),(5,11))
        \\open_multiple:=envelope(split,shape)
        \\dashed_pen:=pen(ink,1pt,"square","bevel",4,[3pt,2pt],0pt,shape)
        \\plain_pen:=pen(ink,1pt,"square","bevel",4,[],0pt,shape)
        \\line:=path((0,0),(20,0))
        \\dashed:=envelope(line,dashed_pen)
        \\plain:=envelope(line,plain_pen)
        \\singleton:=envelope(path((5,7)),shape)
        \\zero:=envelope(path((5,7),(5,7)),shape)
        \\dot:=stroke_outline(path((5,7),(5,7)),shape)
    ;
    const Inspect = struct {
        fn path(runtime: *l.Runtime, machine: *l.Machine, name: []const u8) huak.core.Path {
            return runtime.path_values.items[machine.getGlobal(name).?.handle.index];
        }
        fn closed(curve: huak.core.Path) usize {
            var count: usize = 0;
            for (curve.segments.items) |segment| if (segment == .close) {
                count += 1;
            };
            return count;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const outside = Inspect.path(&runtime, &machine, "outside");
        const inside = Inspect.path(&runtime, &machine, "inside");
        try t.expectEqual(@as(usize, 1), Inspect.closed(outside));
        try t.expectEqual(@as(usize, 1), Inspect.closed(inside));
        try t.expect(outside.bounds().?.width() > inside.bounds().?.width());
        try t.expect((Inspect.path(&runtime, &machine, "complete")).segmentCount() > outside.segmentCount());
        try t.expectEqual(@as(usize, 2), Inspect.closed(Inspect.path(&runtime, &machine, "multiple")));
        try t.expectEqual(@as(usize, 2), Inspect.closed(Inspect.path(&runtime, &machine, "open_multiple")));
        // Envelope consumes the geometric pen, not its optional dash pattern.
        try t.expectEqualDeep((Inspect.path(&runtime, &machine, "plain")).segments.items, (Inspect.path(&runtime, &machine, "dashed")).segments.items);
        try t.expect((Inspect.path(&runtime, &machine, "singleton")).bounds().?.width() > 0);
        if ((Inspect.path(&runtime, &machine, "zero")).bounds()) |box| try t.expect(box.width() == 0 and box.height() == 0);
        try t.expect((Inspect.path(&runtime, &machine, "dot")).bounds().?.width() > 0);
    }
}

test "directional envelope rejects elliptical pens with source-located actionable diagnostics" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| for ([_]struct { expression: []const u8, message: []const u8 }{
        .{ .expression = "envelope(curve,pencircle(4pt))", .message = "EllipticalPen" },
        .{ .expression = "envelope(curve,pensquare(4pt),0pt)", .message = "InvalidTolerance" },
    }) |case| {
        const source = try t.allocator.print("import paint.{{envelope, path}};import pen.{{pencircle, pensquare}};curve:=path((0,0),(20,0))\nresult:={s}\nafter:=1\n", .{case.expression});
        defer t.allocator.free(source);
        var program = try compileModulesOptimized(&library, source, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const failure = machine.failure.?;
        try t.expect(std.mem.find(u8, failure.text(), case.message) != null);
        try t.expectEqual(@as(usize, 2), failure.diagnostic.position(source).line);
        if (std.mem.eql(u8, case.message, "EllipticalPen")) try t.expect(std.mem.find(u8, failure.native_message, "polygonal pen") != null);
        try t.expect(machine.getGlobal("result") == null and machine.getGlobal("after") == null);
    };
}
