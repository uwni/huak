//! Word notation built on mixfix: default forms, directional envelope aliases, composed pictures and target checking.
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
