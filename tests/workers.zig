//! Automatic drawing-task execution through real native typography and export.
const scene = @import("support/scene.zig");
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const options = @import("test_options");
const l = huak.language;
const pdf_text = @import("support/pdf.zig");

fn sourceBlock(context: *anyopaque, source: []const u8) !usize {
    const library: *typst.Library = @ptrCast(@alignCast(context));
    return library.sourceBlock(source);
}

fn compile(library: *typst.Library, source: []const u8, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "workers.huak", .{
        .source_parser = .{ .ptr = library, .vtable = &.{ .block = sourceBlock } },
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

const drawing =
    \\import math.{sin, cos};import paint.{rgb, pen, translate, draw, label, picture, append};setup_typst { set text(size: 13pt) }
    \\caption := typ[Shared worker text Ω $x^2$]
    \\ink := pen(rgb(0.15,0.35,0.7),0.4)
    \\fn figure(index: int) -> picture
    \\ p := picture(240,160)
    \\ for stroke in 0:119 do
    \\  y := 4 + stroke * 1.0
    \\  phase := (stroke + index) * 0.17
    \\  curve := (5,y) ~~ (80,y+8*sin(phase)) ~~ (160,y-7*cos(phase)) ~~ (235,y)
    \\  object.append(p, object.draw(curve, ink))
    \\ end
    \\ object.append(p, object.label(caption, (8,140)))
    \\ return p
    \\end
    \\fn combined(left: picture, right: picture) -> picture
    \\ p := picture(260,180)
    \\ p.append(copy(left))
    \\ p.append(copy(right), translate((5,5)))
    \\ return p
    \\end
    \\
;

const Evaluation = struct {
    outputs: l.OutputBatch,
    stats: @FieldType(l.tasks.Executor, "stats"),
    steps: u64,
};

/// Only detached picture/layout owners survive; all task VMs and construction
/// arenas are gone before either native exporter is called by the tests.
fn evaluate(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, names: []const []const u8) !Evaluation {
    var runtime = try l.Runtime.init(t.allocator, t.allocator, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
    executor.attach(&machine);
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
    const targets = try t.allocator.alloc(l.types.Value, names.len);
    defer t.allocator.free(targets);
    for (names, targets) |name, *target| target.* = machine.getGlobal(name) orelse return error.MissingExpectedGlobal;
    return .{ .outputs = try runtime.takeOutputs(targets), .stats = executor.stats, .steps = machine.steps };
}

fn render(batch: *const l.OutputBatch, index: usize, format: huak.render.Format) !huak.render.Output {
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*detail| detail.deinit();
    return batch.render(t.allocator, index, format, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("native: {s}\n", .{detail.bytes()});
        return err;
    };
}

fn expectSelectableText(bytes: []const u8) !void {
    const text = try pdf_text.text(bytes, .{ .raw = true });
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "Shared worker text") != null);
    try t.expect(std.mem.indexOf(u8, text, "Ω") != null);
}

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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var serial = try evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var before = try render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try render(&parallel.outputs, index, .svg);
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
            \\fn position(p:pair,m:measure)->pair
            \\    {s}
            \\    sample:=sample_at_fraction(m,0.5)
            \\    origin:pair:=sample[1]
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
        var program = try compile(&library, source, true);
        defer program.deinit();
        var serial = try evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, if (mutating) 0 else 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var before = try render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var serial = try evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
        var first = try render(&serial.outputs, 0, .svg);
        defer first.deinit();
        var second = try render(&serial.outputs, 3, .svg);
        defer second.deinit();
        try t.expect(!std.mem.eql(u8, first.bytes(), second.bytes()));
    }
}

test "automatic workers preserve independent and diamond pictures with shared native text" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source = drawing ++
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        try t.expectEqual(@as(usize, 0), serial.stats.tasks);
        for ([_]usize{ 2, 4, 4 }) |jobs| {
            var parallel = try evaluate(&library, &program, jobs, names);
            defer parallel.outputs.deinit();
            try t.expect(parallel.stats.tasks >= 2);
            try t.expect(parallel.stats.peak_active <= jobs);
            try t.expectEqual(serial.steps, parallel.steps);
            for (0..names.len) |index| {
                var expected = try render(&serial.outputs, index, .svg);
                defer expected.deinit();
                var actual = try render(&parallel.outputs, index, .svg);
                defer actual.deinit();
                try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
            }
            var pdf = try render(&parallel.outputs, 4, .pdf);
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        for (0..2) |index| {
            var svg = try render(&serial.outputs, index, .svg);
            defer svg.deinit();
            if (reference[index]) |expected| {
                try t.expectEqualSlices(u8, expected, svg.bytes());
            } else reference[index] = try t.allocator.dupe(u8, svg.bytes());
        }
        for ([_]usize{ 2, 4 }) |jobs| {
            var parallel = try evaluate(&library, &program, jobs, &.{ "first", "second" });
            defer parallel.outputs.deinit();
            try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
            try t.expect(parallel.stats.peak_active <= jobs);
            try t.expectEqual(serial.steps, parallel.steps);
            for (0..2) |index| {
                var svg = try render(&parallel.outputs, index, .svg);
                defer svg.deinit();
                try t.expectEqualSlices(u8, reference[index].?, svg.bytes());
            }
            var serial_pdf = try render(&serial.outputs, 0, .pdf);
            defer serial_pdf.deinit();
            var parallel_pdf = try render(&parallel.outputs, 0, .pdf);
            defer parallel_pdf.deinit();
            try t.expectEqualSlices(u8, serial_pdf.bytes(), parallel_pdf.bytes());
            const text = try pdf_text.text(parallel_pdf.bytes(), .{ .raw = true });
            defer t.allocator.free(text);
            try t.expect(std.mem.indexOf(u8, text, "Propagation workers Ω") != null);
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        for ([_]usize{ 2, 4 }) |jobs| {
            var parallel = try evaluate(&library, &program, jobs, &.{ "first", "second" });
            defer parallel.outputs.deinit();
            try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
            try t.expectEqual(serial.steps, parallel.steps);
            for (0..2) |index| {
                var expected = try render(&serial.outputs, index, .svg);
                defer expected.deinit();
                var actual = try render(&parallel.outputs, index, .svg);
                defer actual.deinit();
                try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
            }
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var serial = try evaluate(&library, &program, 1, &.{ "first", "second" });
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, &.{ "first", "second" });
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..2) |index| {
            var expected = try render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 0), program.task_regions.len);
        for ([_]usize{ 1, 4 }) |jobs| {
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
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

test "object handles allow independent construction before continuous animation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library, drawing ++
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
    var serial = try evaluate(&library, &program, 1, &.{ "first", "second", "<default>" });
    defer serial.outputs.deinit();
    var parallel = try evaluate(&library, &program, 4, &.{ "first", "second", "<default>" });
    defer parallel.outputs.deinit();
    try t.expectEqual(@as(usize, 2), parallel.stats.tasks);
    for (0..3) |index| {
        var expected = try render(&serial.outputs, index, .svg);
        defer expected.deinit();
        var actual = try render(&parallel.outputs, index, .svg);
        defer actual.deinit();
        try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        if (index != 1) try t.expect(std.mem.indexOf(u8, actual.bytes(), "<animateTransform") != null);
    }
    try t.expectError(error.AnimationRequiresSvg, parallel.outputs.validate(0, .pdf));
}

test "builders mutating shared pictures and printing remain ordered serial barriers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, picture, append};shared:=picture(100,80)
        \\fn changed(index:int) -> picture
        \\ object.append(shared, object.draw((0,index*1.0)--(90,index*1.0)))
        \\ print(index)
        \\ p:=picture(100,80)
        \\ p.append(copy(shared))
        \\ return p
        \\end
        \\first:=changed(1)
        \\second:=changed(2)
    , true);
    defer program.deinit();
    for ([_]usize{ 1, 4 }) |jobs| {
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
        executor.attach(&machine);
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 0), executor.stats.tasks);
        try t.expectEqualStrings("1\n2\n", runtime.printedText());
        const first = machine.getGlobal("first").?;
        const second = machine.getGlobal("second").?;
        var first_svg = try runtime.render(first, .svg);
        defer first_svg.deinit();
        var second_svg = try runtime.render(second, .svg);
        defer second_svg.deinit();
        try t.expect(first_svg.bytes().len < second_svg.bytes().len);
    }
}

const Failure = struct {
    span: l.bytecode.Span,
    message: []u8,
    native_message: []u8,
    first_initialized: bool,
    second_initialized: bool,
    third_initialized: bool,
    steps: u64,

    fn deinit(self: *Failure) void {
        t.allocator.free(self.message);
        t.allocator.free(self.native_message);
    }
};

fn failing(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, limits: l.Machine.Limits) !Failure {
    return failingOptions(library, program, jobs, limits, .{});
}

fn failingOptions(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, limits: l.Machine.Limits, runtime_options: l.Runtime.Options) !Failure {
    var runtime = try l.Runtime.init(t.allocator, t.allocator, library, runtime_options);
    defer runtime.deinit();
    var machine = try l.Machine.init(t.allocator, program, runtime.host(), limits);
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
    executor.attach(&machine);
    try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
    const detail = machine.failure orelse return error.MissingExpectedDiagnostic;
    const message = try t.allocator.dupe(u8, detail.text());
    errdefer t.allocator.free(message);
    return .{
        .span = detail.diagnostic.span,
        .message = message,
        .native_message = try t.allocator.dupe(u8, detail.native_message),
        .first_initialized = machine.getGlobal("first") != null,
        .second_initialized = machine.getGlobal("second") != null,
        .third_initialized = machine.getGlobal("third") != null,
        .steps = machine.steps,
    };
}

test "speculative typography preparation preserves earlier errors and successful prefixes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const builders =
        \\import paint.{draw, label, picture};fn early(divisor:int) -> picture
        \\ p:=picture(100,80)
        \\ y:=10/divisor
        \\ object.append(p, object.draw((0,0)--(50,y*1.0)))
        \\ return p
        \\end
        \\fn late() -> picture
        \\ p:=picture(100,80)
        \\ object.append(p, object.label(typ[Late text], (5,30)))
        \\ return p
        \\end
        \\
    ;
    for ([_]i64{ 0, 1 }) |divisor| {
        const source = try std.fmt.allocPrint(t.allocator, "{s}first:=early({d})\nsecond:=late()\n", .{ builders, divisor });
        defer t.allocator.free(source);
        var program = try compile(&library, source, true);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        const runtime_options: l.Runtime.Options = .{ .font_sources = &.{.{ .data = "invalid font bytes" }} };
        var serial = try failingOptions(&library, &program, 1, .{}, runtime_options);
        defer serial.deinit();
        var parallel = try failingOptions(&library, &program, 4, .{}, runtime_options);
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
        try t.expectEqual(divisor != 0, parallel.first_initialized);
    }
}

fn expectSameFailure(expected: Failure, actual: Failure) !void {
    try t.expectEqualDeep(expected.span, actual.span);
    try t.expectEqualSlices(u8, expected.message, actual.message);
    try t.expectEqualSlices(u8, expected.native_message, actual.native_message);
    try t.expectEqual(expected.first_initialized, actual.first_initialized);
    try t.expectEqual(expected.second_initialized, actual.second_initialized);
    try t.expectEqual(expected.third_initialized, actual.third_initialized);
    try t.expectEqual(expected.steps, actual.steps);
}

test "worker failures publish the same successful prefix and first source diagnostic" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, picture};import assertions.assert
        \\fn figure(index:int) -> picture
        \\ p := picture(100,80)
        \\ for stroke in 0:80 do
        \\  object.append(p, object.draw((0,stroke)--(90,stroke)))
        \\ end
        \\ assert(index != 2)
        \\ return p
        \\end
        \\first := figure(1)
        \\second := figure(2)
        \\third := figure(2)
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    try t.expect(serial.first_initialized);
    try t.expect(!serial.second_initialized);
    try t.expect(!serial.third_initialized);
    for ([_]usize{ 2, 4 }) |jobs| {
        var parallel = try failing(&library, &program, jobs, .{});
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
    }
}

test "native worker diagnostics survive temporary layout and task arenas" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{label, picture};fn good() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.label(typ[Good Ω], (5,25)))
        \\ return p
        \\end
        \\fn broken() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.label(typ[#unknown_worker_symbol], (5,25)))
        \\ return p
        \\end
        \\first := good()
        \\second := broken()
        \\third := broken()
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    var parallel = try failing(&library, &program, 4, .{});
    defer parallel.deinit();
    try expectSameFailure(serial, parallel);
    try t.expect(std.mem.indexOf(u8, parallel.native_message, "unknown_worker_symbol") != null);
}

test "instruction budgets preserve serial source locations and initialized bindings" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library, drawing ++
        \\first := figure(1)
        \\second := figure(2)
        \\third := figure(3)
    , true);
    defer program.deinit();
    for ([_]u64{ 20, 100, 1000, 10000 }) |budget| {
        var serial = try failing(&library, &program, 1, .{ .instructions = budget });
        defer serial.deinit();
        var parallel = try failing(&library, &program, 4, .{ .instructions = budget });
        defer parallel.deinit();
        try expectSameFailure(serial, parallel);
    }
}

test "future globals remain uninitialized reads instead of introducing future writer dependencies" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, picture, append};fn reader() -> picture
        \\ p := picture(100,80)
        \\ p.append(copy(third))
        \\ return p
        \\end
        \\fn fresh() -> picture
        \\ p := picture(100,80)
        \\ object.append(p, object.draw((0,0)--(90,70)))
        \\ return p
        \\end
        \\first := reader()
        \\second := fresh()
        \\third := fresh()
    , true);
    defer program.deinit();
    var serial = try failing(&library, &program, 1, .{});
    defer serial.deinit();
    var parallel = try failing(&library, &program, 4, .{});
    defer parallel.deinit();
    try expectSameFailure(serial, parallel);
    try t.expect(!parallel.first_initialized);
    try t.expect(!parallel.third_initialized);
}

test "Typst setup changes delimit task snapshots and shared Program runs stay isolated" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{label, picture};setup_typst { set text(size: 10pt) }
        \\fn figure() -> picture
        \\ p := picture(200,100)
        \\ object.append(p, object.label(typ[MMMM Ω], (5,40)))
        \\ return p
        \\end
        \\first := figure()
        \\second := figure()
        \\setup_typst { set text(size: 24pt) }
        \\third := figure()
        \\fourth := figure()
    , true);
    defer program.deinit();
    const names: []const []const u8 = &.{ "first", "second", "third", "fourth" };
    var serial = try evaluate(&library, &program, 1, names);
    defer serial.outputs.deinit();
    for (0..3) |_| {
        var parallel = try evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 4);
        for (0..names.len) |index| {
            var expected = try render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
    }
}

fn allocationScenario(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program) !void {
    // Force allocation fallback for reproducible failure indices. The actual
    // worker path still runs; this backend supplies no additional threads.
    var allocation_only = t.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable = allocation_only.allocator();
    var scene_allocator = t.FailingAllocator.init(stable, .{ .resize_fail_index = 0 });
    defer std.debug.assert(scene_allocator.allocated_bytes == scene_allocator.freed_bytes);
    var runtime = try l.Runtime.init(stable, scene_allocator.allocator(), library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(stable, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = stable, .io = io, .runtime = &runtime, .jobs = 4 };
    executor.attach(&machine);
    _ = try machine.execute(&.{});
    var batch = try runtime.takeOutputs(&.{ machine.getGlobal("first").?, machine.getGlobal("second").? });
    defer batch.deinit();
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*detail| detail.deinit();
    var svg = try batch.render(stable, 0, .svg, &diagnostic);
    defer svg.deinit();
    try t.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
    try t.expect(executor.stats.tasks >= 2);
}

test "worker snapshots publication diagnostics and moved owners survive every allocation failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, label, picture};caption:=typ[Owned worker text Ω]
        \\fn figure(index:int) -> picture
        \\ typst_expose index
        \\ local:=typ[Worker #huak.index]
        \\ p:=picture(100,80)
        \\ object.append(p, object.draw((0,0)~~(25,index*1.0)~~(75,50)))
        \\ object.append(p, object.label(caption, (5,60)))
        \\ object.append(p, object.label(local, (5,40)))
        \\ return p
        \\end
        \\first:=figure(1)
        \\second:=figure(2)
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    // Initialize native shared resources before counting host allocations.
    var warmup = try evaluate(&library, &program, 1, &.{"first"});
    warmup.outputs.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{ threaded.io(), &library, &program });
}

fn failureAllocationScenario(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program) !void {
    var allocation_only = t.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    const stable = allocation_only.allocator();
    var runtime = try l.Runtime.init(stable, stable, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(stable, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = stable, .io = io, .runtime = &runtime, .jobs = 4 };
    executor.attach(&machine);
    _ = machine.execute(&.{}) catch |err| {
        // A failed diagnostic copy must not publish a handle and then roll
        // its owner back. Check even on OOM, before any further allocation.
        for (machine.globals, machine.initialized) |value, initialized| {
            if (initialized and value == .object) {
                const owner = scene.owner(value);
                try t.expect(owner.owner_index < runtime.scene_values.items.len);
                try t.expectEqual(owner, runtime.scene_values.items[owner.owner_index]);
            }
        }
        if (err == error.OutOfMemory) return err;
        try t.expectEqual(error.RuntimeFailed, err);
        try t.expect(machine.failure != null);
        try t.expect(machine.getGlobal("first") != null);
        try t.expect(machine.getGlobal("second") == null);
        var batch = try runtime.takeOutputs(&.{machine.getGlobal("first").?});
        defer batch.deinit();
        try batch.validate(0, .svg);
        return;
    };
    return error.ExpectedArithmeticFailure;
}

test "diagnostic copy allocation failures never publish rolled-back picture handles" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, picture};fn figure(index:int) -> picture
        \\ p:=picture(100,80)
        \\ y:=10.0/(2-index)
        \\ object.append(p, object.draw((0,0)--(50,y)))
        \\ return p
        \\end
        \\first:=figure(1)
        \\second:=figure(2)
        \\third:=figure(3)
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    try t.checkAllAllocationFailures(t.allocator, failureAllocationScenario, .{ threaded.io(), &library, &program });
}

test "imported builders share module text while initialization and local settings remain ordered" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const module =
        \\import paint.{draw, label, picture};print("worker library initialized")
        \\setup_typst { set text(size: 24pt) }
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
            const name = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer).?, path });
            if (!std.mem.eql(u8, name, "/workers/figures.huak")) return error.ModuleNotFound;
            return .{ .name = name, .source = try allocator.dupe(u8, module) };
        }
    };
    const source =
        \\import paint.{label, picture};setup_typst { set text(size: 8pt) }
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
        .source_parser = .{ .ptr = &library, .vtable = &.{ .block = sourceBlock } },
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
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
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

test "custom host callbacks retain their behavior when construction workers are requested" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var program = try compile(&library,
        \\import paint.{draw, picture};fn figure() -> picture
        \\ p:=picture(100,80)
        \\ object.append(p, object.draw((0,0)--(50,50)))
        \\ return p
        \\end
        \\first:=figure()
        \\second:=figure()
    , true);
    defer program.deinit();
    try t.expect(program.task_regions.len > 0);
    const Callback = std.meta.Child(@FieldType(l.Machine.Host.VTable, "call_builtin"));
    const BuiltinId = @FieldType(std.meta.ArgsTuple(std.meta.Child(Callback)), "2");
    const Wrapped = struct {
        var calls: std.atomic.Value(usize) = .init(0);

        fn call(context: ?*anyopaque, allocator: std.mem.Allocator, id: BuiltinId, arguments: []const l.types.Value, machine: ?*l.Machine) !l.types.Value {
            _ = calls.fetchAdd(1, .monotonic);
            const runtime: *l.Runtime = @ptrCast(@alignCast(context.?));
            const original = runtime.host();
            if (id == .picture) return original.callBuiltin(allocator, id, &.{ .{ .int = 137 }, .{ .int = 83 } }, machine);
            return original.callBuiltin(allocator, id, arguments, machine);
        }
    };
    var expected: ?[]u8 = null;
    defer if (expected) |bytes| t.allocator.free(bytes);
    var expected_calls: ?usize = null;
    for ([_]usize{ 1, 4 }) |jobs| {
        Wrapped.calls.store(0, .monotonic);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var host = runtime.host();
        var vtable = host.vtable.*;
        vtable.call_builtin = Wrapped.call;
        host.vtable = &vtable;
        var machine = try l.Machine.init(t.allocator, &program, host, .{});
        defer machine.deinit();
        var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = jobs };
        executor.attach(&machine);
        _ = try machine.execute(&.{});
        const calls = Wrapped.calls.load(.monotonic);
        if (expected_calls) |count| try t.expectEqual(count, calls) else expected_calls = calls;
        try t.expect(calls > 0);
        try t.expectEqual(@as(usize, 0), executor.stats.tasks);
        var svg = try runtime.render(machine.getGlobal("first").?, .svg);
        defer svg.deinit();
        if (expected) |bytes| try t.expectEqualSlices(u8, bytes, svg.bytes()) else expected = try t.allocator.dupe(u8, svg.bytes());
    }
    const Existing = struct {
        fn task(context: ?*anyopaque, _: *l.Machine, _: *const l.bytecode.TaskRegion) l.Machine.Error!bool {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
            return false;
        }
    };
    var calls: usize = 0;
    var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
    defer runtime.deinit();
    var host = runtime.host();
    host.tasks = .{ .ptr = &calls, .vtable = &.{ .dispatch = Existing.task } };
    var machine = try l.Machine.init(t.allocator, &program, host, .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = t.allocator, .io = t.io, .runtime = &runtime, .jobs = 4 };
    executor.attach(&machine);
    _ = try machine.execute(&.{});
    try t.expect(calls > 0);
    try t.expectEqual(@as(usize, 0), executor.stats.tasks);
}

test "exposed typed data retains construction workers capture dependencies and grouped root typography" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, draw, label, picture, append};title:="Data workers Ω"
        \\font_size:=11pt
        \\ink:=rgb(0.1,0.3,0.7,0.75)
        \\typst_expose title,font_size,ink
        \\setup_typst { set text(size:huak.font_size,fill:huak.ink) }
        \\shared:=typ[#huak.title]
        \\shared_again:=typ[#huak.title]
        \\fn figure(index:int)->picture
        \\    typst_expose index
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        try t.expect(program.task_regions.len > 0);
        var observed_capture_reads = false;
        var observed_picture_dependencies = false;
        for (program.task_regions) |region| for (region.tasks) |task| {
            const target = program.global_names[task.global];
            if (std.mem.eql(u8, target, "first")) {
                try t.expect(task.uses_typst);
                var title_read = false;
                var size_read = false;
                var ink_read = false;
                for (task.reads) |read| {
                    title_read = title_read or std.mem.eql(u8, program.global_names[read], "title");
                    size_read = size_read or std.mem.eql(u8, program.global_names[read], "font_size");
                    ink_read = ink_read or std.mem.eql(u8, program.global_names[read], "ink");
                }
                try t.expect(title_read and size_read and ink_read);
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
        var serial = try evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 3);
        try t.expectEqual(serial.steps, parallel.steps);
        // The independent root requests remain a single native layout owner;
        // the owner survives runtime destruction and worker result transfer.
        const frames = parallel.outputs.entries[0].?.frames;
        try t.expect(frames.len >= 3);
        try t.expect(frames[0].layout == frames[1].layout);
        for (0..names.len) |index| {
            var expected = try render(&serial.outputs, index, .svg);
            defer expected.deinit();
            var actual = try render(&parallel.outputs, index, .svg);
            defer actual.deinit();
            try t.expectEqualSlices(u8, expected.bytes(), actual.bytes());
        }
        var serial_pdf = try render(&serial.outputs, 2, .pdf);
        defer serial_pdf.deinit();
        var parallel_pdf = try render(&parallel.outputs, 2, .pdf);
        defer parallel_pdf.deinit();
        try t.expectEqualSlices(u8, serial_pdf.bytes(), parallel_pdf.bytes());
        const text = try pdf_text.text(parallel_pdf.bytes(), .{ .raw = true });
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "Data workers Ω: 1") != null);
        try t.expect(std.mem.indexOf(u8, text, "Data workers Ω: 2") != null);
    }
}

test "directional envelope keeps captured paths pens and builder results safe for automatic workers" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.{rgb, translate, bezier, fill, picture};import pen.pensquare;import paint.envelope as side
        \\shared_curve:=bezier((5,10),(20,70),(70,0),(90,60))
        \\shared_nib:=pensquare(4pt)
        \\fn figure(offset:pair)->picture
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
        var program = try compile(&library, source, optimize);
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
        var serial = try evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expect(parallel.stats.tasks >= 2);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try render(&parallel.outputs, index, .svg);
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
        var program = try compile(&library, source, optimize);
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
        var serial = try evaluate(&library, &program, 1, names);
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, names);
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 0), serial.stats.tasks);
        try t.expect(parallel.stats.tasks >= 2);
        try t.expectEqual(serial.steps, parallel.steps);
        for (0..names.len) |index| {
            var before = try render(&serial.outputs, index, .svg);
            defer before.deinit();
            var after = try render(&parallel.outputs, index, .svg);
            defer after.deinit();
            try t.expectEqualStrings(before.bytes(), after.bytes());
        }
    }
}

test "workers publish detached object subtrees and retain text through dependent composition" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const source =
        \\import paint.*
        \\fn item(x:length)->object
        \\    root:=picture()
        \\    group:=object.append(root, picture(transform: translate((x,0pt))))
        \\    object.append(group, fill(rectangle((0pt,0pt),12pt,12pt), rgb(0.2,0.5,0.8)))
        \\    object.append(group, label(typ[Worker object], (0pt,25pt)))
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
        var program = try compile(&library, source, optimize);
        defer program.deinit();
        var serial = try evaluate(&library, &program, 1, &.{"plate"});
        defer serial.outputs.deinit();
        var parallel = try evaluate(&library, &program, 4, &.{"plate"});
        defer parallel.outputs.deinit();
        try t.expectEqual(@as(usize, 4), parallel.stats.tasks);
        try t.expectEqual(serial.steps, parallel.steps);
        for ([_]huak.render.Format{ .svg, .pdf }) |format| {
            var before = try render(&serial.outputs, 0, format);
            defer before.deinit();
            var after = try render(&parallel.outputs, 0, format);
            defer after.deinit();
            try t.expectEqualSlices(u8, before.bytes(), after.bytes());
        }
    }
}
