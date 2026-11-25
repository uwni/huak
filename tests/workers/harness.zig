//! Compiling, evaluating and rendering scripts with and without automatic workers, and the drawing prelude the topics share.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;

pub fn compile(library: *typst.Library, source: []const u8, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "workers.huak", .{
        .source_parser = .init(library),
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

pub const drawing =
    \\import math.{sin, cos};import paint.{rgb, pen, translate, draw, label, picture, append}
    \\theme := typ.module[#let style(body) = { set text(size: 13pt); body }]
    \\typ.show theme.style
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
pub fn evaluate(library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, names: []const []const u8) !Evaluation {
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

pub fn render(batch: *const l.OutputBatch, index: usize, format: huak.render.Format) !huak.render.Output {
    var diagnostic: ?typst.Buffer = null;
    defer if (diagnostic) |*detail| detail.deinit();
    return batch.render(t.allocator, index, format, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("native: {s}\n", .{detail.bytes()});
        return err;
    };
}
