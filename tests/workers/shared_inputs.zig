//! What a task may capture and share: guides, measures, nested lists, list writes and identity, captured paths and pure path operations.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const harness = @import("harness.zig");

test "bending shares immutable guides across workers and retains detached outputs" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import geometry.{bezier,rectangle}
        \\import object.{fill, draw, append}
        \\import transform.bent
        \\guide:=bezier((10,10),(20,10),(30,20),(30,30))
        \\shape:=picture()
        \\object.append(shape, fill(rectangle((0,-1),5,2)))
        \\fn figure(distance: length) -> picture
        \\    p:=picture(60,60);append(p, copy(bent(shape,guide,distance)))
        \\    object.append(p, draw(bent(path((0,0),(5,0)),guide,distance)))
        \\    return p
        \\end
        \\export first:=figure(5pt)
        \\export second:=figure(15pt)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var before = try harness.render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
}

test "mapping workers share immutable measures and reject callbacks mutating shared pictures" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |mutating| {
        const source = try std.fmt.allocPrint(t.allocator,
            \\import geometry.{{measure,sample_at_fraction}}
            \\import transform.mapped
            \\import object.draw
            \\guide:=measure(path((0pt,0pt),(2pt,0pt)))
            \\shared:=picture(10pt,10pt)
            \\fn position(p:vec2,m:measure)->vec2
            \\    {s}
            \\    sample:=sample_at_fraction(m,0.5)
            \\    origin:vec2:=sample[1]
            \\    return p+origin
            \\end
            \\fn figure()->picture
            \\    p:=picture(10pt,10pt)
            \\    object.append(p, draw(mapped(path((0pt,0pt),(1pt,1pt)),position,guide)))
            \\    return p
            \\end
            \\export first:=figure()
            \\export second:=figure()
        , .{if (mutating) "object.append(shared, draw(path((0pt,0pt),(1pt,1pt))))" else ""});
        defer t.allocator.free(source);
        var program = try harness.compile(&library, source, true);
        defer program.deinit();
        var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, if (mutating) 0 else 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var before = try harness.render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
}

test "workers reuse nested list inputs and shallow slices for native path and style construction" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import drawing.drawing
        \\import paint.{rgb, pen, path, draw, picture};points:=[(5,5),(90,50),(180,5)]
        \\configuration:=[points,["smooth","smooth"]]
        \\pattern:=[3,2]
        \\fn figure(settings:list,dashes:list,index:int)->picture
        \\    p:=picture(200,100)
        \\    selected:=settings[0][0:]
        \\    curve:=path(selected[0:2],false,settings[1])
        \\    ink:=pen(rgb(0.2,0.4,0.7),1,"round","round",10,dashes[0:1:1])
        \\    drawing p do
        \\        +draw curve
        \\    end
        \\    object.append(p, object.draw((5,index*10)--(180,index*10), ink))
        \\    return p
        \\end
        \\export first:=figure(configuration,pattern,1)
        \\export second:=figure(configuration,pattern,2)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try harness.evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        for ([_]usize{ 2, 4 }) |jobs| {
            var parallel = try harness.evaluate(&library, &program, jobs, &.{ "first", "second" });
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
}

test "list writes remain ordered when pictures share a captured collection" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{draw, picture};values:=[0]
        \\fn figure(index:int)->picture
        \\    values+=index
        \\    p:=picture(100,80)
        \\    object.append(p, object.draw((0,0)--(index*10,50)))
        \\    return p
        \\end
        \\first:=figure(1)
        \\second:=figure(2)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 0), program.task_regions.len);
        for ([_]usize{ 1, 4 }) |jobs| {
            var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, jobs) }, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
            executor.attach(&machine);
            _ = try machine.execute(&.{});
            try t.expectEqual(@as(usize, 0), executor.stats.tasks);
            const items = l.types.sequence(machine.getGlobal("values").?).?;
            try t.expectEqual(@as(usize, 3), items.len);
            for (items, 0..) |value, index| try t.expectEqual(@as(i64, @intCast(index)), value.int);
        }
    }
}

test "task snapshots borrow list identity and reject writes to the parent owner" {
    var diagnostic: ?l.compiler.Diagnostic = null;
    var program = try l.compiler.compile(t.allocator,
        \\values:=[1]
        \\fn changed()->int
        \\    values+=2
        \\    return len(values)
        \\end
        \\result:=changed()
    , "borrowed-list-worker.huak", .{ .optimize = false }, &diagnostic);
    defer program.deinit();
    var parent = try l.Machine.init(t.allocator, &program, .{}, .{});
    defer parent.deinit();
    _ = try parent.execute(&.{});
    var child = try l.Machine.init(t.allocator, &program, .{}, .{});
    defer child.deinit();
    try child.inherit(&parent);
    const original = parent.getGlobal("values").?.list.owned;
    try t.expect(original == child.getGlobal("values").?.list.owned);
    const code = program.functions[program.entry].code;
    var call: ?u32 = null;
    for (code, 0..) |instruction, index| {
        if (instruction.op == .call and index + 1 < code.len and code[index + 1].op == .store_global) {
            call = @intCast(index);
            break;
        }
    }
    const start = call orelse return error.MissingExpectedCall;
    const store = code[start + 1];
    try t.expectError(error.RuntimeFailed, child.executeTask(.{
        .function = program.entry,
        .start = start,
        .end = start + 1,
        .global = store.a,
        .reads = &.{},
    }));
    try t.expectEqual(@as(usize, 2), original.values.items.len);
    try t.expectEqual(@as(i64, 2), original.values.items[1].int);
}

test "directional envelope keeps captured paths pens and builder results safe for automatic workers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, bezier, fill, picture};import pen.pensquare;import paint.envelope as side
        \\shared_curve:=bezier((5,10),(20,70),(70,0),(90,60))
        \\shared_nib:=pensquare(4pt)
        \\fn figure(offset:vec2)->picture
        \\    edge:=envelope of shared_curve with shared_nib
        \\    p:=picture(130,110)
        \\    object.append(p, object.fill(edge, rgb(0.2,0.4,0.7), translate(offset)))
        \\    return p
        \\end
        \\export first:=figure((5,10))
        \\export second:=figure((15,20))
    ;
    const names: []const []const u8 = &.{ "first", "second" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var found = false;
        for (program.task_regions) |region| for (region.tasks) |task| {
            if (!std.mem.eql(u8, program.global_names[task.global], "first")) continue;
            var path_read = false;
            var pen_read = false;
            for (task.reads) |read| {
                path_read = path_read or std.mem.eql(u8, program.global_names[read], "shared_curve");
                pen_read = pen_read or std.mem.eql(u8, program.global_names[read], "shared_nib");
            }
            try t.expect(path_read and pen_read and !task.uses_typst);
            found = true;
        };
        try t.expect(found);
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 2);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try harness.render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
}

test "path closure intersection times and length samples remain pure worker operations" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import geometry.{path,closed,intersection_times,sample_at_fraction,sample_at_length,samples_at_length}
        \\import picture.{picture}; import object.{draw}
        \\shared:=path((5pt,10pt),(55pt,10pt),(55pt,60pt))
        \\cross:=path((30pt,0pt),(30pt,20pt))
        \\fn figure(distance:length)->picture
        \\    border:=closed(shared)
        \\    halfway:=sample_at_fraction(shared,0.5)
        \\    along:=sample_at_length(shared,distance)
        \\    samples:=samples_at_length(shared,[distance,100pt,0pt])
        \\    hits:=intersection_times(shared,cross)
        \\    p:=picture(80pt,70pt)
        \\    object.append(p, object.draw(border))
        \\    object.append(p, object.draw(path(halfway[1],along[1],(len(samples)*1pt,len(hits)*1pt))))
        \\    return p
        \\end
        \\export first:=figure(20pt)
        \\export second:=figure(40pt)
    ;
    const names: []const []const u8 = &.{ "first", "second" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var found = false;
        for (program.task_regions) |region| for (region.tasks) |task| {
            if (!std.mem.eql(u8, program.global_names[task.global], "first")) continue;
            var shared_read = false;
            var cross_read = false;
            for (task.reads) |read| {
                shared_read = shared_read or std.mem.eql(u8, program.global_names[read], "shared");
                cross_read = cross_read or std.mem.eql(u8, program.global_names[read], "cross");
            }
            try t.expect(shared_read and cross_read and !task.uses_typst);
            found = true;
        };
        try t.expect(found);
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 0), serial.stats.tasks);
        try t.expect(parallel.stats.tasks >= 2);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try harness.render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try harness.render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
}
