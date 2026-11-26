//! Cut outlines of picture primitives, and outline workers with borrowed owners.
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
        const extracted = try @import("../support/pdf.zig").text(pdf.bytes(), .{ .raw = true });
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
            var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, jobs) }, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
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
            const extracted = try @import("../support/pdf.zig").text(source_pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(extracted);
            try t.expect(std.mem.indexOf(u8, extracted, "Worker Ω") != null);
        }
    }
}
