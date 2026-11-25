//! Which pictures workers build: ordering, independence, constant propagation, mixfix builders, object handles and detached subtrees.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const pdf_text = @import("../support/pdf.zig");
const harness = @import("harness.zig");

fn expectSelectableText(bytes: []const u8) !void {
    const text = try pdf_text.text(bytes, .{ .raw = true });
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "Shared worker text") != null);
    try t.expect(std.mem.indexOf(u8, text, "Ω") != null);
}

test "random drawing stays ordered while independent special function pictures use workers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import math.{random as uniform,randint,randn,seed}
        \\import paint.{draw,circle}
        \\fn noise() -> float
        \\    return uniform()+randint(1,3)+randn()
        \\end
        \\fn scattered() -> picture
        \\    p:=picture(100,100)
        \\    for i in 0:7 do object.append(p, object.draw(circle((40+noise(),40+noise()),1))) end
        \\    return p
        \\end
        \\fn fixed(x: float) -> picture
        \\    p:=picture(100,100)
        \\    object.append(p, object.draw(circle((math.gamma(x),40),1+math.erfc(x))))
        \\    return p
        \\end
        \\seed(42)
        \\export first:=scattered()
        \\export fixed_a:=fixed(4)
        \\export fixed_b:=fixed(5)
        \\export second:=scattered()
    ;
    const names: []const []const u8 = &.{ "first", "fixed_a", "fixed_b", "second" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try harness.render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
        var first = try harness.render(&serial.outputs, 0, .svg);
        defer first.deinit();
        var second = try harness.render(&serial.outputs, 3, .svg);
        defer second.deinit();
        try t.expect(!std.mem.eql(u8, first.bytes(), second.bytes()));
    }
}

test "automatic workers preserve independent and diamond pictures with shared native text" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source = harness.drawing ++
        \\import paint.{rgb, pen, draw};export first := figure(1)
        \\export second := figure(2)
        \\export left := combined(first,second)
        \\export right := combined(first,second)
        \\export diamond := combined(left,right)
        \\object.append(diamond, object.draw((2,2)--(250,170), pen(rgb(0.1,0.1,0.1),1)))
        \\default diamond
    ;
    const names: []const []const u8 = &.{ "first", "second", "left", "right", "diamond", "<default>" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        try t.expectEqual(@as(usize, 0), serial.stats.tasks);
        for ([_]usize{ 2, 4, 4 }) |jobs| {
            var parallel = try harness.evaluate(&library, &program, jobs, names);
            defer parallel.outputs.deinit();
            try t.expect(parallel.stats.tasks >= 2);
            try t.expect(parallel.stats.peak_active <= jobs);
            try t.expectEqual(serial.steps, parallel.steps);
            for (0..names.len) |index| {
                var expected = try harness.render(&serial.outputs, index, .svg);
                defer expected.deinit();
                var actual = try harness.render(&parallel.outputs, index, .svg);
                defer actual.deinit();
                try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
            }
            var pdf = try harness.render(&parallel.outputs, 4, .pdf);
            defer pdf.deinit();
            try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
            try t.expect(std.mem.indexOf(u8, pdf.bytes(), "/ToUnicode") != null);
            if (optimize and jobs == 2) try expectSelectableText(pdf.bytes());
        }
    }
}

test "constant propagation keeps worker output and instruction budgets consistent" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{draw, label, picture};caption:=typ[Propagation workers Ω]
        \\fn figure(index:int)->picture
        \\    SCALE:=2*3; EDGE:=SCALE+4
        \\    left:=0; if EDGE>8 then left=EDGE else left=-500 end
        \\    p:=picture(120,80)
        \\    for stroke in 0:4 do
        \\        y:=10+stroke*8
        \\        object.append(p, object.draw((left,y)--(100,y+index)))
        \\    end
        \\    object.append(p, object.label(caption, (5,65)))
        \\    return p
        \\end
        \\export first:=figure(1)
        \\export second:=figure(2)
    ;
    var reference: [2]?[]u8 = .{ null, null };
    defer for (reference) |bytes| if (bytes) |value| t.allocator.free(value);
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        for (0..2) |index| {
            var svg = try harness.render(&serial.outputs, index, .svg);
            defer svg.deinit();
            if (reference[index]) |expected| {
                try t.expectEqualSlices(u8, expected, svg.bytes());
            } else reference[index] = try t.allocator.dupe(u8, svg.bytes());
        }
        for ([_]usize{ 2, 4 }) |jobs| {
            var parallel = try harness.evaluate(&library, &program, jobs, &.{ "first", "second" });
            defer parallel.outputs.deinit();
            try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
            try t.expect(parallel.stats.peak_active <= jobs);
            try t.expectEqual(serial.steps, parallel.steps);
            for (0..2) |index| {
                var svg = try harness.render(&parallel.outputs, index, .svg);
                defer svg.deinit();
                try t.expectEqualSlices(u8, reference[index].?, svg.bytes());
            }
            var serial_pdf = try harness.render(&serial.outputs, 0, .pdf);
            defer serial_pdf.deinit();
            var parallel_pdf = try harness.render(&parallel.outputs, 0, .pdf);
            defer parallel_pdf.deinit();
            try t.expectEqualSlices(u8, serial_pdf.bytes(), parallel_pdf.bytes());
            const text = try pdf_text.text(parallel_pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            try t.expect(std.mem.indexOf(u8, text, "Propagation workers Ω") != null);
        }
    }
}

test "mixfix builders retain automatic workers native output and instruction accounting" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*
        \\caption:=typ[Mixfix workers]
        \\fn figure(offset:length)->picture
        \\    p:=picture with width 80mm height 50mm
        \\    curve:=circle with center (30mm+offset,20mm) radius 10mm
        \\    ink:=pen with color rgb(0.1,0.3,0.8) width 0.5mm
        \\    object.append(p, object.draw(curve, ink))
        \\    object.append(p, object.label(caption, (5mm,40mm)))
        \\    return p
        \\end
        \\export first:=figure(0mm)
        \\export second:=figure(10mm)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var expected = try harness.render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try harness.render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
    }
}

test "object handles allow independent construction before continuous animation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library, harness.drawing ++
        \\import paint.{rgb, pen, circle, draw, fill};import animation.{timeline, animate};export first := figure(1)
        \\export second := figure(2)
        \\id := object.append(first, object.fill(circle((20,20),6), rgb(0.8,0.1,0.2)))
        \\first.timeline(2,false)
        \\animate(id,"translate",[[0,(0,0)],[1,(40,0)]])
        \\animate(id,"opacity",[[0,0.2],[1,1]])
        \\object.append(second, object.draw((2,2)--(235,155), pen(rgb(0,0,0),2)))
        \\default first
    , true);
    defer program.deinit();
    var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second", "<default>" });
    defer serial.outputs.deinit();
    var parallel = try harness.evaluate(&library, &program, 4, &.{ "first", "second", "<default>" });
    defer parallel.outputs.deinit();
    try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
    for (0..3) |index| {
        var expected = try harness.render(&serial.outputs, index, .svg);
        defer expected.deinit();
        var actual = try harness.render(&parallel.outputs, index, .svg);
        defer actual.deinit();
        try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        if (index != 1) try t.expect(std.mem.indexOf(u8, actual.bytes(), "transform:translate(") != null);
    }
    try t.expectError(error.AnimationRequiresSvg, parallel.outputs.validate(0, .pdf));
}

test "workers publish detached object subtrees and retain text through dependent composition" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*
        \\fn item(x:length)->object
        \\    root:=picture()
        \\    group:=picture()
        \\    object.transform(group, translate((x,0pt)))
        \\    object.append(root, group)
        \\    object.append(group, fill(rectangle((0pt,0pt),12pt,12pt), rgb(0.2,0.5,0.8)))
        \\    title:=typ[Worker object]
        \\    subtitle:=typ[Shared layout owner]
        \\    object.append(group, label(subtitle, (0pt,35pt)))
        \\    object.append(group, label(title, (0pt,25pt)))
        \\    for i in 0:2 do
        \\        object.append(group, label(typ[Independent layout owner], (0pt,40pt+i*10pt)))
        \\    end
        \\    unused:=object.append(root, label(typ[Discarded object], (0pt,50pt)))
        \\    object.remove(unused)
        \\    object.remove(group)
        \\    return group
        \\end
        \\fn combined(a:object,b:object)->object
        \\    root:=picture()
        \\    append(root, copy(a))
        \\    append(root, copy(b))
        \\    return root
        \\end
        \\first:=item(10pt)
        \\second:=item(80pt)
        \\pair:=combined(first,second)
        \\other:=combined(first,second)
        \\export plate:=picture(180pt,80pt)
        \\append(plate, copy(pair))
        \\append(plate, copy(other), translate((0pt,35pt)))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        var serial = try harness.evaluate(&library, &program, 1, &.{"plate"});
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, &.{"plate"});
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 4), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for ([_]huak.render.Format{ .svg, .pdf }) |format| {
            var before = try harness.render(&serial.outputs, 0, format);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, 0, format);
            defer after.deinit();
            try t.expectEqualSlices(u8, before.bytes(), after.bytes());
        }
    }
}
