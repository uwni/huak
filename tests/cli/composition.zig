//! Generic picture clipping through the actual compiler, workers and exporters.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
pub const process_count = 23;

pub fn run(ctx: *h.Harness) !void {
    const script = try ctx.script("composition/main",
        \\import paint.*;import geometry.compound
        \\import assertions.assert
        \\param APPLY:bool=true
        \\source:=picture(120pt,80pt)
        \\alias:=source
        \\drawing source do
        \\    +rectangle((-10pt,-8pt),140pt,96pt) filled rgb(0.1,0.4,0.8,0.6)
        \\    +typ[Source Ω] at (4pt,68pt)
        \\end
        \\result_content:=source
        \\empty_content:=source
        \\all_content:=source
        \\vacant:=picture(50pt,40pt)
        \\if APPLY then
        \\    result_content=source cut rectangle((30pt,20pt),20pt,25pt)
        \\    empty_content=cut(source,compound([]))
        \\    all_content=cut(source,rectangle((-20pt,-20pt),180pt,140pt))
        \\    vacant_content:=cut(vacant,circle((25pt,20pt),5pt));append(vacant, copy(vacant_content))
        \\    assert(len(bounds(all_content))==0,"complete cut must be empty")
        \\end
        \\result:=picture(source.width,source.height);append(result, copy(result_content))
        \\empty:=picture(source.width,source.height);append(empty, copy(empty_content))
        \\all:=picture(source.width,source.height);append(all, copy(all_content))
        \\assert(source.width==120pt and source.height==80pt)
        \\assert(result.width==source.width and result.height==source.height)
        \\assert(empty.width==source.width and all.height==source.height)
        \\assert(vacant.width==50pt and vacant.height==40pt)
        \\assert(not result.animated and not source.animated)
        \\assert(len(bounds(vacant))==0)
        \\box:=bounds(source)
        \\assert(box[0].x<0pt and box[0].y<0pt,"off-canvas source bounds must survive")
        \\cut_box:=bounds(result)
        \\assert(cut_box[0].x<0pt and cut_box[0].y<0pt,"cut must retain off-canvas geometry")
        \\default result
        \\export source,alias,empty,all,vacant
    );
    _ = try ctx.command("check", script, &.{}, true);
    try h.contains((try ctx.command("disassemble", script, &.{}, true)).stdout, "call_builtin");
    try h.output(try ctx.command("run", script, &.{
        "--param=APPLY=false", "--output=source=composition-before.svg", "--output=source=composition-before.pdf",
    }, true), "");
    for ([_][]const u8{ "1", "4" }) |jobs| {
        try h.output(try ctx.command("run", script, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=composition-{s}.svg", .{jobs}),
            try ctx.fmt("--output=composition-{s}.pdf", .{jobs}),
            try ctx.fmt("--output=source=composition-source-{s}.svg", .{jobs}),
            try ctx.fmt("--output=source=composition-source-{s}.pdf", .{jobs}),
            try ctx.fmt("--output=alias=composition-alias-{s}.svg", .{jobs}),
            try ctx.fmt("--output=empty=composition-empty-{s}.svg", .{jobs}),
            try ctx.fmt("--output=all=composition-all-{s}.svg", .{jobs}),
            try ctx.fmt("--output=vacant=composition-vacant-{s}.svg", .{jobs}),
        }, true), "");
        const clipped = try ctx.svg(try ctx.fmt("composition-{s}.svg", .{jobs}));
        try clipped.viewBox("0 0 120 80");
        try t.expectEqual(@as(usize, 1), clipped.count("clipPath"));
        try t.expectEqual(@as(usize, 1), clipReferences(clipped));
        try t.expectEqual(@as(usize, 0), (try ctx.svg(try ctx.fmt("composition-empty-{s}.svg", .{jobs}))).count("clipPath"));
        try t.expectEqual(@as(usize, 0), (try ctx.svg(try ctx.fmt("composition-all-{s}.svg", .{jobs}))).count("path"));
        try t.expectEqual(@as(usize, 0), (try ctx.svg(try ctx.fmt("composition-vacant-{s}.svg", .{jobs}))).count("path"));
        try h.contains(try ctx.pdfText(try ctx.fmt("composition-{s}.pdf", .{jobs}), false), "Source Ω");
        try t.expectEqualStrings(try ctx.read("composition-before.svg"), try ctx.read(try ctx.fmt("composition-source-{s}.svg", .{jobs})));
        try t.expectEqualStrings(try ctx.read("composition-before.svg"), try ctx.read(try ctx.fmt("composition-alias-{s}.svg", .{jobs})));
        try t.expectEqualStrings(try ctx.read("composition-before.pdf"), try ctx.read(try ctx.fmt("composition-source-{s}.pdf", .{jobs})));
    }
    try t.expectEqualStrings(try ctx.read("composition-1.svg"), try ctx.read("composition-4.svg"));
    try t.expectEqualStrings(try ctx.read("composition-1.pdf"), try ctx.read("composition-4.pdf"));
    try nativeClip(ctx);
    try batch(ctx);
    try objectCutters(ctx);
    const tolerance = try ctx.script("composition/tolerance", "import paint.*\np:=cut(picture(),circle((0,0),1),0pt)\n");
    try h.contains((try ctx.command("run", tolerance, &.{}, false)).stderr, "cut tolerance must be positive");
    const angle = try ctx.script("composition/angle", "import paint.*\np:=cut(picture(),circle((0,0),1),1deg)\n");
    try h.contains((try ctx.command("check", angle, &.{}, false)).stderr, "length");
    const elements = try ctx.script("composition/elements", "import paint.circle;import geometry.compound;p:=compound([circle((0,0),1),42])\n");
    try h.contains((try ctx.command("run", elements, &.{}, false)).stderr, "path");
    const missing = try ctx.script("composition/missing", "import paint.*\np:=cut(picture())\n");
    try h.contains((try ctx.command("check", missing, &.{}, false)).stderr, "argument");
    const readonly = try ctx.script("composition/readonly", "import paint.picture;p:=picture(640, 480)\np.width=20pt\n");
    try h.contains((try ctx.command("check", readonly, &.{}, false)).stderr, "no writable field");
    const animated = try ctx.script("composition/animated",
        \\import paint.*;import animation.{timeline, animate}
        \\source:=picture(100,80)
        \\source.timeline(1)
        \\target:=object.append(source, object.fill(circle((25,25),5)))
        \\animate(target,"opacity",[[0,0.3],[1,1]])
        \\export result :=picture(100,80)
        \\default result
        \\append(result, copy(cut(source,circle((25,25),10))))
    );
    const serial = try ctx.command("run", animated, &.{ "--jobs=1", "--output=animated-cut-1.svg" }, false);
    const parallel = try ctx.command("run", animated, &.{ "--jobs=4", "--output=animated-cut-4.svg" }, false);
    try h.contains(serial.stderr, "cut requires a static object");
    try t.expectEqualStrings(serial.stderr, parallel.stderr);
    try ctx.absent("animated-cut-1.svg");
    try ctx.absent("animated-cut-4.svg");
}

fn nativeClip(ctx: *h.Harness) !void {
    const script = try ctx.script("composition/native-clip",
        \\import paint.*
        \\accumulated:=picture(20pt,20pt)
        \\drawing accumulated do
        \\    +rectangle((0pt,0pt),20pt,20pt) filled rgb(1,0,0)
        \\end
        \\accumulated.clip(rectangle((0pt,0pt),10pt,20pt))
        \\accumulated.clip(rectangle((0pt,0pt),20pt,10pt))
        \\cleared:=picture(20pt,20pt)
        \\drawing cleared do
        \\    +rectangle((0pt,0pt),20pt,20pt) filled rgb(1,0,0)
        \\end
        \\clip(cleared,rectangle((0pt,0pt),10pt,20pt))
        \\reset_clip(cleared)
        \\export accumulated,cleared
    );
    try h.output(try ctx.command("run", script, &.{
        "--output=accumulated=native-clip-accumulated.svg",
        "--output=cleared=native-clip-cleared.svg",
    }, true), "");
    const accumulated = try ctx.svg("native-clip-accumulated.svg");
    try accumulated.viewBox("0 0 20 20");
    try t.expectEqual(@as(usize, 1), accumulated.count("clipPath"));
    try t.expectEqual(@as(usize, 1), clipReferences(accumulated));
    const cleared = try ctx.svg("native-clip-cleared.svg");
    try t.expectEqual(@as(usize, 0), cleared.count("clipPath"));
}

fn batch(ctx: *h.Harness) !void {
    const script = try ctx.script("composition/batch",
        \\import paint.*;import geometry.compound
        \\theme := typ.module[#let style(body) = { set text(size:4pt); body }]
        \\typ.show theme.style
        \\caption:=typ[Tile]
        \\source:=picture(400pt,180pt)
        \\drawing source do
        \\    +rectangle((0pt,0pt),400pt,180pt) filled rgb(0.1,0.4,0.8,0.5)
        \\end
        \\holes:=[]
        \\upper:=picture(400pt,180pt)
        \\for row in 0:15 do
        \\    for column in 0:15 do
        \\        x:=8pt+column*24pt
        \\        y:=8pt+row*10pt
        \\        holes+=rectangle((x-1pt,y-1pt),20pt,7pt)
        \\        drawing upper do
        \\            +caption at (x,y)
        \\            +circle((x+15pt,y+2pt),1pt) filled rgb(0.8,0.1,0.2)
        \\        end
        \\    end
        \\end
        \\export result :=picture(400pt,180pt)
        \\default result
        \\append(result, copy(cut(source,compound(holes))))
        \\append(result, copy(upper))
    );
    for ([_][]const u8{ "1", "4" }) |jobs| {
        try h.output(try ctx.command("run", script, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=composition-batch-{s}.svg", .{jobs}),
            try ctx.fmt("--output=composition-batch-{s}.pdf", .{jobs}),
        }, true), "");
        const svg = try ctx.svg(try ctx.fmt("composition-batch-{s}.svg", .{jobs}));
        try t.expectEqual(@as(usize, 1), svg.count("clipPath"));
        try t.expectEqual(@as(usize, 1), clipReferences(svg));
        try t.expectEqual(@as(usize, 256), std.mem.count(u8, try ctx.pdfText(try ctx.fmt("composition-batch-{s}.pdf", .{jobs}), false), "Tile"));
    }
    try t.expectEqualStrings(try ctx.read("composition-batch-1.svg"), try ctx.read("composition-batch-4.svg"));
    try t.expectEqualStrings(try ctx.read("composition-batch-1.pdf"), try ctx.read("composition-batch-4.pdf"));
}

fn clipReferences(svg: h.Svg) usize {
    var count: usize = 0;
    for (svg.elements) |element| if (element.attr("clip-path") != null) {
        count += 1;
    };
    return count;
}

fn objectCutters(ctx: *h.Harness) !void {
    const script = try ctx.script("composition/object-cutters",
        \\import math.abs;import paint.*;import geometry.{compound, region_intersection};import pen.pensquare;import object.{outlines, region}
        \\import assertions.assert
        \\fn covered(region:path,at:vec2)->bool
        \\    return len(region_intersection(region,rectangle(at,0.2pt,0.2pt),0.01pt))>0
        \\end
        \\source:=picture(200pt,140pt)
        \\drawing source do
        \\    +rectangle((0pt,0pt),200pt,140pt) filled rgb(0.1,0.4,0.8,0.6)
        \\    +typ[Source Ω] at (4pt,130pt)
        \\end
        \\cutter:=picture(200pt,140pt)
        \\object.append(cutter, object.fill(rectangle((-100pt,-100pt),400pt,400pt), rgb(0,0,0,0)))
        \\object.append(cutter, object.fill(reverse(rectangle((20pt,20pt),40pt,25pt)), rgb(0.7,0.1,0.2)))
        \\object.append(cutter, object.fill(rectangle((40pt,25pt),40pt,25pt), rgb(0.1,0.5,0.2)))
        \\ring:=compound([rectangle((100pt,20pt),35pt,35pt),reverse(rectangle((110pt,30pt),15pt,15pt))])
        \\object.append(cutter, object.fill(ring))
        \\nib:=transformed(pensquare(5pt),rotate(25deg))
        \\ink:=pen(rgb(0.2,0.2,0.2),1pt,"round","miter",4,[6pt,3pt],1pt,nib)
        \\object.append(cutter, draw(bezier((5pt,80pt),(50pt,130pt),(70pt,75pt),(95pt,115pt)), ink, translate((10pt,0pt))))
        \\child:=picture()
        \\outer:=picture()
        \\object.transform(outer, translate((5pt,5pt)))
        \\object.clip(outer, rectangle((0pt,0pt),25pt,25pt))
        \\object.append(child, outer)
        \\inner:=picture()
        \\object.transform(inner, translate((5pt,0pt)))
        \\object.clip(inner, rectangle((0pt,0pt),20pt,20pt))
        \\object.append(outer, inner)
        \\object.append(inner, object.fill(rectangle((-20pt,-20pt),60pt,60pt)))
        \\append(cutter, copy(child), translate((110pt,75pt)))
        \\object.append(cutter, object.filldraw(circle((165pt,95pt),8pt), rgb(0.6,0.1,0.2), pen(rgb(0,0,0),3pt)))
        \\evenodd_content:=typ[
        \\ #curve(fill:blue,stroke:none,fill-rule:"even-odd",
        \\   curve.move((0pt,0pt)),curve.line((30pt,0pt)),curve.line((30pt,30pt)),curve.line((0pt,30pt)),curve.close(),
        \\   curve.move((10pt,10pt)),curve.line((20pt,10pt)),curve.line((20pt,20pt)),curve.line((10pt,20pt)),curve.close())
        \\]
        \\object.append(cutter, object.label(evenodd_content, (150pt,60pt)))
        \\native_clipped:=typ[
        \\ #box(width:20pt,height:12pt,clip:true)[
        \\   #box(width:30pt,height:20pt,clip:true)[#rect(width:40pt,height:30pt,fill:red,stroke:none)]
        \\ ]
        \\]
        \\native_clip_box:=bounds(region(native_clipped,0.01pt))
        \\assert(native_clip_box[1].x-native_clip_box[0].x<=20.01pt and native_clip_box[1].y-native_clip_box[0].y<=12.01pt,"Typst nested clips must limit the ink region")
        \\object.append(cutter, object.label(native_clipped, (115pt,110pt)))
        \\native_content:=typ[Cutter Ω $x^2+y^2$]
        \\object.append(cutter, object.label(native_content, (15pt,120pt)))
        \\parts:=outlines(cutter).paths
        \\first:=bounds(parts[1])
        \\second:=bounds(parts[2])
        \\assert(abs(first[0].x-20pt)<0.01pt and abs(second[0].x-40pt)<0.01pt,"outlines preserve all primitive geometry in order")
        \\ink_region:=region(cutter,0.01pt)
        \\assert(covered(ink_region,(50pt,30pt)),"independent reversed fills must not cancel")
        \\assert(covered(ink_region,(102pt,22pt)) and not covered(ink_region,(117pt,37pt)),"nonzero ring must retain its hole")
        \\assert(covered(ink_region,(130pt,90pt)) and not covered(ink_region,(115pt,90pt)),"nested transformed clips must constrain outlines")
        \\assert(covered(ink_region,(153pt,60pt+evenodd_content.baseline-3pt)))
        \\assert(not covered(ink_region,(165pt,60pt+evenodd_content.baseline-15pt)),"Typst evenodd must retain its hole")
        \\ignored:=picture(640, 480)
        \\object.append(ignored, object.fill(circle((0,0),10), rgb(0,0,0,0)))
        \\assert(len(outlines(ignored).paths)==1)
        \\assert(len(region(ignored))==0)
        \\assert(len(outlines(compound([])).paths)==0)
        \\assert(len(outlines(native_content).paths)>0)
        \\export geometry:=picture(200pt,140pt)
        \\object.append(geometry, object.fill(ink_region, rgb(0,0,0)))
        \\export result :=picture(200pt,140pt)
        \\default result
        \\append(result, copy(cut(source,cutter,0.01pt)))
        \\export text_result:=picture(200pt,140pt)
        \\append(text_result, copy(cut(source,typ[O],0.01pt)))
        \\export source,cutter
    );
    _ = try ctx.command("check", script, &.{}, true);
    for ([_][]const u8{ "1", "4" }) |jobs| {
        try h.output(try ctx.command("run", script, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=object-cutters-{s}.svg", .{jobs}),
            try ctx.fmt("--output=object-cutters-{s}.pdf", .{jobs}),
            try ctx.fmt("--output=geometry=object-geometry-{s}.svg", .{jobs}),
            try ctx.fmt("--output=cutter=object-cutter-{s}.pdf", .{jobs}),
            try ctx.fmt("--output=text_result=text-cutters-{s}.svg", .{jobs}),
        }, true), "");
        const svg = try ctx.svg(try ctx.fmt("object-cutters-{s}.svg", .{jobs}));
        try t.expectEqual(@as(usize, 1), svg.count("clipPath"));
        try t.expectEqual(@as(usize, 1), clipReferences(svg));
        try t.expect((try ctx.svg(try ctx.fmt("object-geometry-{s}.svg", .{jobs}))).count("path") > 0);
        try t.expectEqual(@as(usize, 1), (try ctx.svg(try ctx.fmt("text-cutters-{s}.svg", .{jobs}))).count("clipPath"));
        try h.contains(try ctx.pdfText(try ctx.fmt("object-cutters-{s}.pdf", .{jobs}), false), "Source Ω");
        const cutter_text = try ctx.pdfText(try ctx.fmt("object-cutter-{s}.pdf", .{jobs}), false);
        try h.contains(cutter_text, "Cutter Ω");
        try h.contains(cutter_text, "𝑥");
        try h.contains(cutter_text, "𝑦");
    }
    for ([_][]const u8{ "object-cutters", "object-geometry", "text-cutters" }) |prefix| {
        try t.expectEqualStrings(try ctx.read(try ctx.fmt("{s}-1.svg", .{prefix})), try ctx.read(try ctx.fmt("{s}-4.svg", .{prefix})));
    }
    for ([_][]const u8{ "object-cutters", "object-cutter" }) |prefix| {
        try t.expectEqualStrings(try ctx.read(try ctx.fmt("{s}-1.pdf", .{prefix})), try ctx.read(try ctx.fmt("{s}-4.pdf", .{prefix})));
    }
    const tolerance = try ctx.script("composition/outline-tolerance", "import paint.circle;import object.region;p:=region(circle((0,0),1),0pt)\n");
    try h.contains((try ctx.command("run", tolerance, &.{}, false)).stderr, "region tolerance must be positive");
    const angle = try ctx.script("composition/outline-angle", "import paint.circle;import object.region;p:=region(circle((0,0),1),1deg)\n");
    try h.contains((try ctx.command("check", angle, &.{}, false)).stderr, "length");
    const removed = try ctx.script("composition/no-outline-tolerance", "import paint.circle;import object.outlines;p:=outlines(circle((0,0),1),0.01pt)\n");
    try h.contains((try ctx.command("check", removed, &.{}, false)).stderr, "argument");
    const object_type = try ctx.script("composition/outline-type", "import object.outlines;p:=outlines(42)\n");
    try h.contains((try ctx.command("run", object_type, &.{}, false)).stderr, "outlines requires a path, text, or object");
    const animated = try ctx.script("composition/animated-cutter",
        \\import paint.*;import animation.{timeline, animate}
        \\cutter:=picture(100,80)
        \\cutter.timeline(1)
        \\target:=object.append(cutter, object.fill(circle((25,25),5)))
        \\animate(target,"opacity",[[0,0.3],[1,1]])
        \\source:=picture(100,80)
        \\object.append(source, object.fill(rectangle((0,0),100,80)))
        \\export result :=picture(100,80)
        \\default result
        \\append(result, copy(cut(source,cutter)))
    );
    const serial = try ctx.command("run", animated, &.{ "--jobs=1", "--output=animated-cutter-1.svg" }, false);
    const parallel = try ctx.command("run", animated, &.{ "--jobs=4", "--output=animated-cutter-4.svg" }, false);
    try h.contains(serial.stderr, "operation requires a static object");
    try t.expectEqualStrings(serial.stderr, parallel.stderr);
    try ctx.absent("animated-cutter-1.svg");
    try ctx.absent("animated-cutter-4.svg");
}
