//! Cutting holes: many holes in one clip, static input and tolerance validation, overflowing object content.
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
        try t.expect(std.mem.find(u8, svg.bytes(), "<clipPath") != null);
        var pdf = try runtime.render(machine.getGlobal("output").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.find(u8, pdf.bytes(), "/ToUnicode") != null);
        const extracted = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(extracted);
        try t.expect(std.mem.find(u8, extracted, "Retained native text") != null);
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
            const input = try t.allocator.print(
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
            try t.expect(std.mem.find(u8, machine.failure.?.native_message, fixture.message) != null);
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
        try t.expect(std.mem.find(u8, svg.bytes(), "<image") != null);
        try t.expect(std.mem.find(u8, svg.bytes(), "<linearGradient") != null);
        var pdf = try runtime.render(machine.getGlobal("plate").?, .pdf);
        defer pdf.deinit();
        const text = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expect(std.mem.find(u8, text, "WWW") != null);
    }
}
