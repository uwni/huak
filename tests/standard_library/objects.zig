//! Object instances: native text and copies, erase in paint order, and standalone path and text objects.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");
const compile = harness.compile;
const execute = harness.execute;

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
        try t.expectEqualDeep(huak.core.DisplayList.Paint{ .color = .{ .r = 0, .g = 1, .b = 0 } }, (try original_owner.scene.getNode(original.index)).path.style.fill.?);
        try t.expectEqualDeep(huak.core.DisplayList.Paint{ .color = .{ .r = 1, .g = 0, .b = 0 } }, (try cloned_owner.scene.getNode(cloned.index)).path.style.fill.?);
        const output = machine.getGlobal("plate").?;
        var svg = try runtime.render(output, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(output, .pdf);
        defer pdf.deinit();
        const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
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
        try t.expect(std.mem.find(u8, pressure_svg.bytes(), "<clipPath") != null);
        var svg = try runtime.render(page, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "<clipPath") != null);
        var pdf = try runtime.render(page, .pdf);
        defer pdf.deinit();
        const words = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(words);
        try t.expect(std.mem.find(u8, words, "Live label") != null);
        // The PDF backend must keep a fully erased node invisible even
        // when its unmasked source path would cover the inspected pixels.
        var covered = try runtime.render(machine.getGlobal("covered").?, .pdf);
        defer covered.deinit();
        const image = try @import("../support/pdf.zig").raster(covered.bytes(), .{});
        defer t.allocator.free(image);
        const header = "P6\n8 8\n255\n";
        try t.expectEqual(header.len + 8 * 8 * 3, image.len);
        try t.expect(std.mem.startsWith(u8, image, header));
        try t.expect(std.mem.allEqual(u8, image[header.len..], 255));
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
        const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Standalone objects"));
    }
}
