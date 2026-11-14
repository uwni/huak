//! Native typography batching preserves ordinary script order and ownership.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const language = huak.language;
const options = @import("test_options");
const pdf_text = @import("support/pdf.zig");

fn compile(library: *typst.Library, source: []const u8, optimize: bool, resolver: ?language.compiler.ImportResolver) !language.bytecode.Program {
    var diagnostic: ?language.compiler.Diagnostic = null;
    return language.compiler.compile(t.allocator, source, "parallel-text.huak", .{
        .source_parser = .init(library),
        .optimize = optimize,
        .import_resolver = resolver,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

fn host(runtime: *language.Runtime, batched: bool, table: *language.Machine.Host.VTable) language.Machine.Host {
    var result = runtime.host();
    table.* = result.vtable.*;
    if (!batched) table.typst_batch = null;
    result.vtable = table;
    return result;
}

const LayoutCalls = struct {
    var original: @TypeOf(&typst.c.typst_context_layout_many) = undefined;
    var calls: usize = 0;
    var requests: usize = 0;
    const arguments = @typeInfo(@TypeOf(typst.c.typst_context_layout_many)).@"fn".param_types;

    fn run(context: arguments[0].?, inputs: arguments[1].?, count: arguments[2].?, outputs: arguments[3].?, diagnostic: arguments[4].?) callconv(.c) typst.c.TypstStatus {
        calls += 1;
        requests += count;
        return original(context, inputs, count, outputs, diagnostic);
    }
};

fn allocatingExecution(allocator: std.mem.Allocator, library: *typst.Library, program: *const language.bytecode.Program) !void {
    // Arena/ArrayList growth can remap in place or allocate according to heap
    // placement. Force the standard allocation fallback so failure indices are
    // repeatable; production allocators keep their normal resize behavior.
    var allocation_only = t.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable_allocator = allocation_only.allocator();
    var runtime = try language.Runtime.init(stable_allocator, stable_allocator, library, .{});
    defer runtime.deinit();
    var machine = try language.Machine.init(stable_allocator, program, runtime.host(), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try t.expectEqual(@as(usize, 1), runtime.layouts.items.len);
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "<svg") != null);
}

test "batched layout registration outlines and rendering release every allocation failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{fill, label, picture};import geometry.compound;import object.outlines;a := typ[A]
        \\b := typ[WWWW]
        \\curve := compound(outlines(b).paths)
        \\pic := picture(120,80)
        \\object.append(pic, object.fill(curve))
        \\object.append(pic, object.label(a, (5,30)))
    , true, null);
    defer program.deinit();
    t.checkAllAllocationFailures(t.allocator, allocatingExecution, .{ &library, &program }) catch |err| {
        std.debug.print("allocation failure verification: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn execute(machine: *language.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

fn metric(runtime: *const language.Runtime, machine: *const language.Machine, name: []const u8) !huak.core.DisplayList.Metrics {
    const value = machine.getGlobal(name) orelse return error.MissingExpectedGlobal;
    try t.expect(value.valueType() == .text);
    return runtime.texts.items[value.handle.index].metrics;
}

const styled_source =
    \\import math.abs;import paint.{label, picture};import assertions.assert
    \\helpers := typ.module[#let decorate(body) = strong(body)]
    \\tokens := typ.module[#let style(body) = { show "token": "MMMM"; body }]
    \\size := typ.module[#let style(body) = { set text(size: 10pt); body }]
    \\typ.show tokens.style
    \\typ.show size.style
    \\a := typ[MMMM]
    \\b := typ[#set text(size: 30pt); MMMM]
    \\c := typ[MMMM]
    \\assert(abs(b.width - 3*a.width) < 0.000001pt)
    \\assert(abs(c.width - a.width) < 0.000001pt)
    \\size = typ.module[#let style(body) = { set text(size: 20pt); body }]
    \\d := typ[MMMM]
    \\e := typ[token]
    \\f := typ[#huak.helpers.decorate[MMMM]]
    \\assert(abs(d.width - 2*a.width) < 0.000001pt)
    \\assert(e.width == d.width)
    \\fn local_pair() -> length
    \\ first := typ[MMMM]
    \\ second := typ[MMMM]
    \\ assert(first.width == second.width)
    \\ return second.width
    \\end
    \\local_width := local_pair()
    \\assert(local_width == d.width)
    \\pic := picture(300,180)
    \\object.append(pic, object.label(a, (5,20))); object.append(pic, object.label(b, (5,55))); object.append(pic, object.label(c, (5,80)))
    \\object.append(pic, object.label(d, (5,115))); object.append(pic, object.label(e, (5,150)))
;

const StyledResult = struct {
    metrics: [5]huak.core.DisplayList.Metrics,
    steps: u64,
    svg: []u8,

    fn deinit(self: *StyledResult) void {
        t.allocator.free(self.svg);
    }
};

fn styled(library: *typst.Library, source: []const u8, optimize: bool, batched: bool) !StyledResult {
    var program = try compile(library, source, optimize, null);
    defer program.deinit();
    var runtime = try language.Runtime.init(t.allocator, t.allocator, library, .{});
    defer runtime.deinit();
    var vtable: language.Machine.Host.VTable = undefined;
    var machine = try language.Machine.init(t.allocator, &program, host(&runtime, batched, &vtable), .{});
    defer machine.deinit();
    try execute(&machine);
    if (batched) {
        // These adjacent independent inputs share one native owner. Reading a
        // result ends the group, and local assignments are also batched.
        try t.expect(runtime.frames.items[0].layout == runtime.frames.items[1].layout);
        try t.expect(runtime.frames.items[1].layout == runtime.frames.items[2].layout);
        try t.expect(runtime.frames.items[2].layout != runtime.frames.items[3].layout);
        try t.expect(runtime.frames.items[6].layout == runtime.frames.items[7].layout);
    }
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    return .{
        .metrics = .{
            try metric(&runtime, &machine, "a"), try metric(&runtime, &machine, "b"),
            try metric(&runtime, &machine, "c"), try metric(&runtime, &machine, "d"),
            try metric(&runtime, &machine, "e"),
        },
        .steps = machine.steps,
        .svg = try t.allocator.dupe(u8, svg.bytes()),
    };
}

test "native text batches preserve show rule snapshots local scope local bindings and execution steps" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var serial = try styled(&library, styled_source, optimize, false);
        defer serial.deinit();
        var parallel = try styled(&library, styled_source, optimize, true);
        defer parallel.deinit();
        try t.expectEqualDeep(serial.metrics, parallel.metrics);
        try t.expectEqual(serial.steps, parallel.steps);
        try t.expectEqualSlices(u8, serial.svg, parallel.svg);
    }
}

test "native errors retain the first source position successful prefix and stop later effects" {
    const input =
        \\before := typ[Successful prefix]
        \\first := typ[#for i in range(150) { [work ] }; #missing_first]
        \\second := typ[#missing_second]
        \\print("must not run")
    ;
    const no_leak =
        \\before := typ[#let private_name = 7; Local definition]
        \\first := typ[#private_name]
        \\second := typ[#missing_second]
        \\print("must not run")
    ;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    LayoutCalls.original = library.functions.context_layout_many;
    library.functions.context_layout_many = &LayoutCalls.run;
    defer library.functions.context_layout_many = LayoutCalls.original;
    for ([_]bool{ false, true }) |optimize| for ([_]bool{ false, true }) |batched| {
        for ([_]struct { source: []const u8, marker: []const u8 }{
            .{ .source = input, .marker = "missing_first" },
            .{ .source = no_leak, .marker = "private_name" },
        }) |scenario| {
            var program = try compile(&library, scenario.source, optimize, null);
            defer program.deinit();
            var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var vtable: language.Machine.Host.VTable = undefined;
            var machine = try language.Machine.init(t.allocator, &program, host(&runtime, batched, &vtable), .{});
            defer machine.deinit();
            LayoutCalls.calls = 0;
            LayoutCalls.requests = 0;
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            // A failed batch already owns its successful prefix. Do not invoke
            // the native engine again to reconstruct the earlier assignment.
            try t.expectEqual(@as(usize, if (batched) 1 else 2), LayoutCalls.calls);
            try t.expectEqual(@as(usize, if (batched) 3 else 2), LayoutCalls.requests);
            const failure = machine.failure orelse return error.MissingDiagnostic;
            try t.expectEqual(@as(usize, 2), failure.diagnostic.position(scenario.source).line);
            try t.expect(std.mem.indexOf(u8, failure.native_message, scenario.marker) != null);
            try t.expect(std.mem.indexOf(u8, failure.native_message, "missing_second") == null);
            try t.expect(machine.getGlobal("before") != null);
            try t.expect(machine.getGlobal("first") == null);
            try t.expect(machine.getGlobal("second") == null);
            try t.expect((try metric(&runtime, &machine, "before")).width > 0);
            try t.expectEqualStrings("", runtime.printedText());
        }
    };
}

test "batched nonzero text frames use their own outlines and metrics are execution barriers" {
    const input =
        \\import paint.{bounds, draw, label, picture};import geometry.compound;import object.outlines;import assertions.assert
        \\narrow := typ[i]
        \\wide := typ[WWWW]
        \\narrow_path := compound(outlines(narrow).paths)
        \\wide_path := compound(outlines(wide).paths)
        \\narrow_box := bounds(narrow_path)
        \\wide_box := bounds(wide_path)
        \\assert(wide_box[1].x - wide_box[0].x > 4*(narrow_box[1].x - narrow_box[0].x))
        \\measured := typ[Dimension barrier].width
        \\after := typ[After the measurement]
        \\pic := picture(300,100)
        \\object.append(pic, object.label(wide, (5,25)))
        \\object.append(pic, object.draw(wide_path))
        \\assert(measured > 0pt)
    ;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, input, optimize, null);
        defer program.deinit();
        var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expect(runtime.frames.items[0].layout == runtime.frames.items[1].layout);
        try t.expect(runtime.frames.items[2].layout != runtime.frames.items[3].layout);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
}

const Modules = struct {
    const small =
        \\theme := typ.module[#let style(body) = { set text(size: 10pt); body }]
        \\typ.show theme.style
        \\export first := typ[MMMM]
        \\export second := typ[MMMM]
    ;
    const large =
        \\theme := typ.module[#let style(body) = { set text(size: 20pt); body }]
        \\typ.show theme.style
        \\export first := typ[MMMM]
        \\export second := typ[MMMM]
    ;
    fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !language.compiler.ResolvedSource {
        if (std.mem.eql(u8, path, "small")) return .{ .name = "small.huak", .source = small };
        if (std.mem.eql(u8, path, "large")) return .{ .name = "large.huak", .source = large };
        return error.UnknownModule;
    }
};

test "imported typography keeps independent module show rules across batched requests" {
    const input =
        \\import math.abs;import assertions.assert
        \\theme := typ.module[#let style(body) = { set text(size: 30pt); body }]
        \\typ.show theme.style
        \\root_first := typ[MMMM]
        \\root_second := typ[MMMM]
        \\import "small" as small
        \\import "large" as large
        \\assert(small.first.width == small.second.width)
        \\assert(large.first.width == large.second.width)
        \\assert(abs(large.first.width - 2*small.first.width) < 0.000001pt)
        \\assert(abs(root_first.width - 3*small.first.width) < 0.000001pt)
        \\root_after := typ[MMMM]
        \\root_after_second := typ[MMMM]
        \\assert(root_after.width == root_first.width)
    ;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compile(&library, input, optimize, .{ .ptr = &context, .vtable = &.{ .resolve = Modules.resolve } });
        defer program.deinit();
        var runtime = try language.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(usize, 8), runtime.frames.items.len);
    }
}

fn detached(library: *typst.Library, optimize: bool) !language.OutputBatch {
    const input =
        \\import paint.{label, picture};a := typ[First batched label]
        \\b := typ[Second batched label]
        \\c := typ[Third shared label]
        \\unused := typ[Unused in the same layout]
        \\first := picture(240,100)
        \\object.append(first, object.label(a, (5,25))); object.append(first, object.label(c, (5,65)))
        \\second := picture(240,100)
        \\object.append(second, object.label(b, (5,25))); object.append(second, object.label(c, (5,65)))
    ;
    var program = try compile(library, input, optimize, null);
    defer program.deinit();
    var runtime = try language.Runtime.init(t.allocator, t.allocator, library, .{});
    defer runtime.deinit();
    var machine = try language.Machine.init(t.allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    try execute(&machine);
    try t.expect(runtime.frames.items[0].layout == runtime.frames.items[3].layout);
    const first = machine.getGlobal("first").?;
    return runtime.takeOutputs(&.{ first, first, machine.getGlobal("second").? });
}

test "shared native layout batches survive ownership handoff and preserve selectable PDF text" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]bool{ false, true }) |optimize| for (0..3) |_| {
        var batch = try detached(&library, optimize);
        defer batch.deinit();
        var diagnostic: ?typst.Buffer = null;
        defer if (diagnostic) |*buffer| buffer.deinit();
        var first = try batch.render(t.allocator, 0, .svg, &diagnostic);
        defer first.deinit();
        batch.release(0);
        var alias = try batch.render(t.allocator, 1, .svg, &diagnostic);
        defer alias.deinit();
        try t.expectEqualSlices(u8, first.bytes(), alias.bytes());
        batch.release(1);
        var second = try batch.render(t.allocator, 2, .pdf, &diagnostic);
        defer second.deinit();
        batch.release(2);
        const text = try pdf_text.text(second.bytes(), .{});
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "Second batched label") != null);
        try t.expect(std.mem.indexOf(u8, text, "Third shared label") != null);
        try t.expect(std.mem.indexOf(u8, text, "First batched label") == null);
        try t.expect(std.mem.indexOf(u8, text, "Unused") == null);
    };
}

fn request(source: []const u8) typst.LayoutRequest {
    return .{
        .source = source,
        .syntax = .markup,
        .region = null,
    };
}

test "batch diagnostics carry a stable failure index and failed host outputs stay empty" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        request("#for i in range(80) { [work ] }; #first_diagnostic"),
        request("#second_diagnostic"),
    };
    var measured: [requests.len]typst.Metrics = @splat(.{ .width = 100, .height = 100, .baseline = 100 });
    var diagnostic: typst.Diagnostic = .{};
    defer diagnostic.deinit();
    try t.expectError(error.CompileFailed, engine.layoutContent(&requests, &measured, &diagnostic));
    for (measured) |value| try t.expectEqualDeep(typst.Metrics{ .width = 0, .height = 0, .baseline = 0 }, value);
    try t.expectEqual(@as(?usize, 0), diagnostic.request_index);
    try t.expect(std.mem.indexOf(u8, diagnostic.text(), "first_diagnostic") != null);
    try t.expect(std.mem.indexOf(u8, diagnostic.text(), "second_diagnostic") == null);
    const copied = try t.allocator.dupe(u8, diagnostic.text());
    defer t.allocator.free(copied);
    // A later successful operation cannot invalidate this independently owned
    // diagnostic.
    var document = try engine.compile("Successful intervening document");
    defer document.deinit();
    try t.expectEqualStrings(copied, diagnostic.text());
    var good_metrics: [1]typst.Metrics = undefined;
    var good = try engine.layoutContent(&.{request("Successful layout")}, &good_metrics, &diagnostic);
    defer good.deinit();
    try t.expect(diagnostic.request_index == null);
    try t.expect(diagnostic.message == null);
    try t.expectEqualStrings("", diagnostic.text());
}
