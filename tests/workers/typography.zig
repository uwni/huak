//! Typst work under workers: typ.show module changes, imported builders' text, typed reads and typ.module values.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const pdf_text = @import("../support/pdf.zig");
const harness = @import("harness.zig");

test "typ.show module changes delimit task snapshots and shared Program runs stay isolated" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try harness.compile(&library,
        \\import paint.{label, picture}
        \\small := typ.module[#let style(body) = { set text(size: 10pt); body }]
        \\large := typ.module[#let style(body) = { set text(size: 24pt); body }]
        \\theme := small
        \\fn figure() -> picture
        \\ typ.show theme.style
        \\ p := picture(200,100)
        \\ object.append(p, object.label(typ[MMMM Ω], (5,40)))
        \\ return p
        \\end
        \\first := figure()
        \\second := figure()
        \\theme = large
        \\third := figure()
        \\fourth := figure()
    , true);
    defer program.deinit();
    const names: []const []const u8 = &.{ "first", "second", "third", "fourth" };
    var serial = try harness.evaluate(&library, &program, 1, names);
    defer serial.outputs.deinit();
    for (0..3) |_| {
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 4);
        for (0..names.len) |index| {
            var expected = try harness.render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try harness.render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
    }
}

test "imported builders share module text while initialization and local settings remain ordered" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const module =
        \\import paint.{draw, label, picture};print("worker library initialized")
        \\theme:=typ.module[#let style(body) = { set text(size: 24pt); body }]
        \\typ.show theme.style
        \\export caption:=typ[Imported worker Ω]
        \\fn figure(index:int) -> picture
        \\ p:=picture(200,100)
        \\ object.append(p, object.draw((0,0)~~(index*10.0,40)~~(190,20)))
        \\ object.append(p, object.label(caption, (5,75)))
        \\ return p
        \\end
        \\export figure
    ;
    const Resolver = struct {
        fn resolve(_: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !l.compiler.ResolvedSource {
            const name = try std.Io.Dir.path.resolveAlloc(allocator, &.{ std.Io.Dir.path.dirname(importer).?, path });
            if (!std.mem.eql(u8, name, "/workers/figures.huak")) return error.ModuleNotFound;
            return .{ .name = name, .source = try allocator.dupe(u8, module) };
        }
    };
    const source =
        \\import paint.{label, picture}
        \\theme:=typ.module[#let style(body) = { set text(size: 8pt); body }]
        \\typ.show theme.style
        \\import "figures.huak" as art
        \\import "./figures.huak" as again
        \\fn local() -> picture
        \\ p:=picture(200,100)
        \\ object.append(p, object.label(typ[Local worker Ω], (5,50)))
        \\ return p
        \\end
        \\first:=art.figure(1)
        \\second:=again.figure(2)
        \\third:=local()
        \\fourth:=local()
    ;
    var context: u8 = 0;
    var diagnostic: ?l.compiler.Diagnostic = null;
    var program = try l.compiler.compile(t.allocator, source, "/workers/main.huak", .{
        .source_parser = .init(&library),
        .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } },
    }, &diagnostic);
    defer program.deinit();
    var figures_modules: usize = 0;
    for (program.modules) |imported| {
        if (std.mem.eql(u8, imported.name, "/workers/figures.huak")) figures_modules += 1;
    }
    try t.expectEqual(@as(usize, 1), figures_modules);
    const names: []const []const u8 = &.{ "first", "second", "third", "fourth" };
    var reference: [names.len]?[]u8 = @splat(null);
    defer for (reference) |bytes| if (bytes) |value| t.allocator.free(value);
    for ([_]usize{ 1, 4, 4 }) |jobs| {
        var runtime = try l.Runtime.initWithBackends(t.allocator, t.allocator, .{ .typst = &library, .workers = .init(t.io, jobs) }, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .runtime = &runtime };
        executor.attach(&machine);
        _ = try machine.execute(&.{});
        try t.expectEqualStrings("worker library initialized\n", runtime.printedText());
        if (jobs != 1) try t.expect(executor.stats.tasks >= 4);
        for (names, &reference) |name, *expected| {
            var svg = try runtime.render(machine.getGlobal(name).?, .svg);
            defer svg.deinit();
            if (expected.*) |bytes| {
                try t.expectEqualSlices(u8, bytes, svg.bytes());
            } else expected.* = try t.allocator.dupe(u8, svg.bytes());
        }
    }
}

test "typed Typst reads retain construction workers capture dependencies and grouped root typography" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, draw, label, picture, append};title:="Data workers Ω"
        \\font_size:=11pt
        \\ink:=rgb(0.1,0.3,0.7,0.75)
        \\theme:=typ.module[#let style(body) = { set text(size:huak.font_size,fill:huak.ink); body }]
        \\typ.show theme.style
        \\shared:=typ[#huak.title]
        \\shared_again:=typ[#huak.title]
        \\fn figure(index:int)->picture
        \\    caption:=typ[#huak.title: #huak.index]
        \\    p:=picture(220,100)
        \\    object.append(p, object.draw((5,5)--(200,index*10)))
        \\    object.append(p, object.label(shared, (5,70)))
        \\    object.append(p, object.label(shared_again, (5,50)))
        \\    object.append(p, object.label(caption, (5,30)))
        \\    return p
        \\end
        \\fn combined(left:picture,right:picture)->picture
        \\    p:=picture(220,200)
        \\    p.append(copy(left))
        \\    p.append(copy(right), translate((0,100)))
        \\    return p
        \\end
        \\export first:=figure(1)
        \\export second:=figure(2)
        \\export plate:=combined(first,second)
    ;
    const names: []const []const u8 = &.{ "first", "second", "plate" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var observed_capture_reads = false;
        var observed_picture_dependencies = false;
        for (program.task_regions) |region| for (region.tasks) |task| {
            const target = program.global_names[task.global];
            if (std.mem.eql(u8, target, "first")) {
                try t.expect(task.uses_typst);
                // The module already holds the size and ink it read when made.
                var title_read = false;
                var theme_read = false;
                for (task.reads) |read| {
                    title_read = title_read or std.mem.eql(u8, program.global_names[read], "title");
                    theme_read = theme_read or std.mem.eql(u8, program.global_names[read], "theme");
                    try t.expect(!std.mem.eql(u8, program.global_names[read], "font_size") and !std.mem.eql(u8, program.global_names[read], "ink"));
                }
                try t.expect(title_read and theme_read);
                observed_capture_reads = true;
            }
            if (std.mem.eql(u8, target, "plate")) {
                var first_read = false;
                var second_read = false;
                for (task.reads) |read| {
                    first_read = first_read or std.mem.eql(u8, program.global_names[read], "first");
                    second_read = second_read or std.mem.eql(u8, program.global_names[read], "second");
                }
                try t.expect(first_read and second_read);
                observed_picture_dependencies = true;
            }
        };
        try t.expect(observed_capture_reads and observed_picture_dependencies);
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 3);
        try t.expectEqual(serial.steps, parallel.steps);
        // The independent root requests remain a single native layout owner;
        // the owner survives runtime destruction and worker result transfer.
        const frames = parallel.outputs.entries[0].?.frames;
        try t.expect(frames.len >= 3);
        try t.expect(frames[0].layout == frames[1].layout);
        for (0..names.len) |index| {
            var expected = try harness.render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try harness.render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
        var serial_pdf = try harness.render(&serial.outputs, 2, .pdf);
        defer serial_pdf.deinit();
        var parallel_pdf = try harness.render(&parallel.outputs, 2, .pdf);
        defer parallel_pdf.deinit();
        try t.expectEqualSlices(u8, serial_pdf.bytes(), parallel_pdf.bytes());
        const text = try pdf_text.text(parallel_pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expect(std.mem.find(u8, text, "Data workers Ω: 1") != null);
        try t.expect(std.mem.find(u8, text, "Data workers Ω: 2") != null);
    }
}

test "typ.module values made before and inside workers keep parallel typography identical" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{label, picture}
        \\shout:=typ.module[#let shout(it) = upper(it)]
        \\loud:=typ.module[#let style(body) = { set text(size: 14pt); huak.shout.shout(body) }]
        \\fn figure(index:int)->picture
        \\    tint:=typ.module[#let style(body) = { set text(fill: rgb(huak.index * 100, 0, 0)); body }]
        \\    typ.show loud.style
        \\    typ.show tint.style
        \\    caption:=typ[Worker #huak.index]
        \\    p:=picture(220,60)
        \\    object.append(p, object.label(caption, (5,30)))
        \\    return p
        \\end
        \\export first:=figure(1)
        \\export second:=figure(2)
    ;
    const names: []const []const u8 = &.{ "first", "second" };
    for ([_]bool{ false, true }) |optimize| {
        var program = try harness.compile(&library, source, optimize);
        defer program.deinit();
        var serial = try harness.evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try harness.evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 2);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var expected = try harness.render(&serial.outputs, index, .pdf);
            defer expected.deinit();
            var actual = try harness.render(&parallel.outputs, index, .pdf);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
            const text = try pdf_text.text(actual.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            try t.expect(std.mem.find(u8, text, if (index == 0) "WORKER 1" else "WORKER 2") != null);
        }
        var svg = try harness.render(&parallel.outputs, 1, .svg);
        defer svg.deinit();
        try t.expect(std.mem.find(u8, svg.bytes(), "#c80000") != null);
    }
}
