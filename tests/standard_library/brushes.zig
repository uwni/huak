//! Brushes and engraving: composition with user profiles, whole-object handles, pen-up bridges and hairlines, policy validation.
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
            try t.expect(std.mem.find(u8, svg.bytes(), "<path") != null);
            try t.expect(std.mem.find(u8, svg.bytes(), "<clipPath") != null);
            var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
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
    try t.expect(std.mem.find(u8, svg.bytes(), "<linearGradient") != null);
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
            const source = try t.allocator.print(
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
            try t.expect(std.mem.find(u8, machine.failure.?.native_message, case.message) != null);
        }
    }
}
