//! Reproducible compiler/VM/native measurements. There is no AST interpreter
//! comparison here, so these measurements do not establish a speedup.
const std = @import("std");
const metrics = @import("metrics");
const ms = metrics.milliseconds;
const peakRss = metrics.peakRssBytes;
const builtin = @import("builtin");
const huak = @import("huak");
const l = huak.language;
const typst = @import("libtypst");
const defaults = @import("host_options");
const arithmetic =
    \\param count: int=10000
    \\fn square(x: float) -> float
    \\ return x*x
    \\end
    \\total:=0.0
    \\for i in 1:count do
    \\ total=total+square(i/10000)
    \\end
;
const drawing =
    \\import paint.{picture, label, smooth, draw, pen, rgb}
    \\param offset: float=0
    \\pic:=picture(320,160)
    \\theme:=typ.module[#let style(body) = {
    \\ set text(size:14pt)
    \\ body
    \\}]
    \\typ.show theme.style
    \\caption:=typ[
    \\ Native $sum_(i=1)^n i^2$ Ω
    \\]
    \\object.append(pic, object.label(caption, (10,130)))
    \\curve:=smooth([(10,20),(80,80+offset),(180,40),(300,100)])
    \\object.append(pic, object.draw(curve, pen(rgb(0.2,0.4,0.8),2)))
;
fn compile(a: std.mem.Allocator, library: *typst.Library, source: []const u8) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(a, source, "benchmark.huak", .{ .source_parser = .init(library) }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
        return err;
    };
}
fn execute(a: std.mem.Allocator, program: *const l.bytecode.Program, host: l.Machine.Host, parameters: []const l.Machine.Override) !void {
    var machine = try l.Machine.init(a, program, host, .{});
    defer machine.deinit();
    _ = machine.execute(parameters) catch |err| {
        if (machine.failure) |failure| std.debug.print("{s}: {s}\n", .{ failure.text(), failure.native_message });
        return err;
    };
}
fn image(a: std.mem.Allocator, library: *typst.Library, program: *const l.bytecode.Program, changed: bool) !usize {
    var runtime = try l.Runtime.init(a, a, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(a, program, runtime.host(), .{});
    defer machine.deinit();
    _ = machine.execute(if (changed) &.{.{ .name = "offset", .value = "12" }} else &.{}) catch |err| {
        if (machine.failure) |failure| std.debug.print("{s}: {s}\n", .{ failure.text(), failure.native_message });
        return err;
    };
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    return svg.bytes().len;
}

/// Compare real bytecode executions of the same checked source. These counters
/// isolate work removed by compilation without attributing native layout time.
fn compareOptimization(a: std.mem.Allocator, io: std.Io) !void {
    const source =
        \\param count=20000
        \\total:=0
        \\for i in 1:count do
        \\ total=total+(2*3+4)
        \\ if false then
        \\  total=total+1000
        \\ end
        \\ if true then
        \\  total=total+(8-5)
        \\ end
        \\end
    ;
    var diagnostic: ?l.compiler.Diagnostic = null;
    const started = std.Io.Clock.awake.now(io);
    var plain = try l.compiler.compile(a, source, "optimization-benchmark.huak", .{ .optimize = false }, &diagnostic);
    defer plain.deinit();
    const plain_compiled = std.Io.Clock.awake.now(io);
    var optimized = try l.compiler.compile(a, source, "optimization-benchmark.huak", .{ .optimize = true }, &diagnostic);
    defer optimized.deinit();
    const optimized_compiled = std.Io.Clock.awake.now(io);
    var plain_vm = try l.Machine.init(a, &plain, .{}, .{});
    defer plain_vm.deinit();
    _ = try plain_vm.execute(&.{});
    const plain_executed = std.Io.Clock.awake.now(io);
    var optimized_vm = try l.Machine.init(a, &optimized, .{}, .{});
    defer optimized_vm.deinit();
    _ = try optimized_vm.execute(&.{});
    const optimized_executed = std.Io.Clock.awake.now(io);
    const expected: i64 = 20000 * 13;
    if (plain_vm.getGlobal("total").?.int != expected or optimized_vm.getGlobal("total").?.int != expected)
        return error.OptimizationChangedResult;
    var plain_instructions: usize = 0;
    for (plain.functions) |function| plain_instructions += function.code.len;
    var optimized_instructions: usize = 0;
    for (optimized.functions) |function| optimized_instructions += function.code.len;
    std.debug.print(
        "optimization_comparison=same_source_same_result\n" ++
            "unoptimized_instructions={d}\noptimized_instructions={d}\n" ++
            "unoptimized_vm_steps={d}\noptimized_vm_steps={d}\n" ++
            "unoptimized_compile_ms={d:.3}\noptimized_compile_ms={d:.3}\n" ++
            "unoptimized_execute_ms={d:.3}\noptimized_execute_ms={d:.3}\n" ++
            "optimization_result={d}\n",
        .{ plain_instructions, optimized_instructions, plain_vm.steps, optimized_vm.steps, ms(started, plain_compiled), ms(plain_compiled, optimized_compiled), ms(optimized_compiled, plain_executed), ms(plain_executed, optimized_executed), expected },
    );
}

/// Named immutable values and a propagated condition exercise the data-flow
/// pass independently of host calls, layout and the literal-folding case.
fn comparePropagation(a: std.mem.Allocator, io: std.Io) !void {
    const source =
        \\param count:int=20000
        \\FACTOR:=2*3+4
        \\FLAG:=FACTOR>8
        \\BIAS:=8-5
        \\total:=0
        \\for i in 1:count do
        \\    total=total+FACTOR
        \\    if FLAG then total=total+BIAS else total=total+1000 end
        \\end
    ;
    const Measurement = struct {
        compile_ms: f64,
        first_ms: f64,
        warm_ms: f64,
        instructions: usize,
        steps: u64,
    };
    const expected: i64 = 20000 * 13;
    const repetitions: usize = 20;
    var measurements: [2]Measurement = undefined;
    for ([_]bool{ false, true }, &measurements) |optimize, *measurement| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        const started = std.Io.Clock.awake.now(io);
        var program = try l.compiler.compile(a, source, "propagation-benchmark.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const compiled = std.Io.Clock.awake.now(io);
        var machine = try l.Machine.init(a, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const first = std.Io.Clock.awake.now(io);
        if (machine.getGlobal("total").?.int != expected) return error.PropagationChangedResult;
        var instructions: usize = 0;
        for (program.functions) |function| instructions += function.code.len;
        const warm_started = std.Io.Clock.awake.now(io);
        for (0..repetitions) |_| {
            var repeated = try l.Machine.init(a, &program, .{}, .{});
            defer repeated.deinit();
            _ = try repeated.execute(&.{});
            if (repeated.getGlobal("total").?.int != expected) return error.PropagationChangedRepeatedResult;
        }
        const warm_finished = std.Io.Clock.awake.now(io);
        measurement.* = .{
            .compile_ms = ms(started, compiled),
            .first_ms = ms(compiled, first),
            .warm_ms = ms(warm_started, warm_finished),
            .instructions = instructions,
            .steps = machine.steps,
        };
    }
    const plain = measurements[0];
    const optimized = measurements[1];
    std.debug.print(
        "propagation_comparison=same_named_bindings_same_result\n" ++
            "propagation_unoptimized_instructions={d}\npropagation_optimized_instructions={d}\n" ++
            "propagation_unoptimized_vm_steps={d}\npropagation_optimized_vm_steps={d}\n" ++
            "propagation_unoptimized_compile_ms={d:.3}\npropagation_optimized_compile_ms={d:.3}\n" ++
            "propagation_unoptimized_first_ms={d:.3}\npropagation_optimized_first_ms={d:.3}\n" ++
            "propagation_warm_runs={d}\npropagation_unoptimized_warm_ms={d:.3}\npropagation_optimized_warm_ms={d:.3}\n" ++
            "propagation_unoptimized_warm_mean_ms={d:.3}\npropagation_optimized_warm_mean_ms={d:.3}\n" ++
            "propagation_result={d}\n",
        .{ plain.instructions, optimized.instructions, plain.steps, optimized.steps, plain.compile_ms, optimized.compile_ms, plain.first_ms, optimized.first_ms, repetitions, plain.warm_ms, optimized.warm_ms, plain.warm_ms / @as(f64, @floatFromInt(repetitions)), optimized.warm_ms / @as(f64, @floatFromInt(repetitions)), expected },
    );
}

/// Infix notation must lower to the same runtime work as an ordinary call of
/// the same user function. Compare both with and without bytecode optimization.
fn compareInfixCalls(a: std.mem.Allocator) !void {
    const header =
        \\precedence accumulating
        \\ below addition
        \\ above path
        \\ associativity left
        \\end
        \\fn combine(a:int,b:int)->int;return a+b;end
        \\mixfix(combine) _ combine _ in accumulating
        \\param count=10000
        \\total:=0
        \\for i in 1:count do
    ;
    const ordinary_source = header ++ "\ntotal=combine(total,2*3+4)\nend\n";
    const infix_source = header ++ "\ntotal=total combine (2*3+4)\nend\n";
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?l.compiler.Diagnostic = null;
        var ordinary = try l.compiler.compile(a, ordinary_source, "ordinary-calls.huak", .{ .optimize = optimize }, &diagnostic);
        defer ordinary.deinit();
        var infix = try l.compiler.compile(a, infix_source, "infix-calls.huak", .{ .optimize = optimize }, &diagnostic);
        defer infix.deinit();
        var ordinary_vm = try l.Machine.init(a, &ordinary, .{}, .{});
        defer ordinary_vm.deinit();
        _ = try ordinary_vm.execute(&.{});
        var infix_vm = try l.Machine.init(a, &infix, .{}, .{});
        defer infix_vm.deinit();
        _ = try infix_vm.execute(&.{});
        var ordinary_instructions: usize = 0;
        for (ordinary.functions) |function| ordinary_instructions += function.code.len;
        var infix_instructions: usize = 0;
        for (infix.functions) |function| infix_instructions += function.code.len;
        const expected: i64 = 100000;
        if (ordinary_vm.getGlobal("total").?.int != expected or infix_vm.getGlobal("total").?.int != expected)
            return error.InfixChangedResult;
        if (ordinary_instructions != infix_instructions or ordinary_vm.steps != infix_vm.steps)
            return error.InfixAddedRuntimeWork;
        std.debug.print(
            "infix_comparison=same_function_same_result optimize={any}\n" ++
                "ordinary_instructions={d}\ninfix_instructions={d}\n" ++
                "ordinary_vm_steps={d}\ninfix_vm_steps={d}\ninfix_result={d}\n",
            .{ optimize, ordinary_instructions, infix_instructions, ordinary_vm.steps, infix_vm.steps, expected },
        );
    }
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) return error.InvalidArguments;
    const start = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(if (args.len == 2) args[1] else defaults.library_path);
    defer library.deinit();
    const loaded = std.Io.Clock.awake.now(init.io);
    var numeric = try compile(a, &library, arithmetic);
    defer numeric.deinit();
    const compiled_numeric = std.Io.Clock.awake.now(init.io);
    try execute(a, &numeric, .{}, &.{});
    const first_numeric = std.Io.Clock.awake.now(init.io);
    const repetitions: usize = 30;
    for (0..repetitions) |_| try execute(a, &numeric, .{}, &.{});
    const numeric_batch = std.Io.Clock.awake.now(init.io);
    try execute(a, &numeric, .{}, &.{.{ .name = "count", .value = "10001" }});
    const parameter_changed = std.Io.Clock.awake.now(init.io);
    var graphic = try compile(a, &library, drawing);
    defer graphic.deinit();
    const compiled_drawing = std.Io.Clock.awake.now(init.io);
    const size = try image(a, &library, &graphic, false);
    const first_drawing = std.Io.Clock.awake.now(init.io);
    _ = try image(a, &library, &graphic, false);
    const hot_drawing = std.Io.Clock.awake.now(init.io);
    const images: usize = 100;
    for (0..images) |_| _ = try image(a, &library, &graphic, false);
    const drawing_batch = std.Io.Clock.awake.now(init.io);
    _ = try image(a, &library, &graphic, true);
    const incremental = std.Io.Clock.awake.now(init.io);
    std.debug.print(
        "Zig={s} mode={s} target={s}-{s} ABI={d}.{d}\n" ++
            "source->AST->bytecode and execution timed separately; no file I/O or AST interpreter baseline\n" ++
            "load_ms={d:.3}\nnumeric_compile_ms={d:.3}\nnumeric_first_execute_ms={d:.3}\n" ++
            "numeric_runs={d}\nnumeric_batch_ms={d:.3}\nparameter_changed_execute_ms={d:.3}\n" ++
            "drawing_compile_ms={d:.3}\ndrawing_cold_ms={d:.3}\ndrawing_hot_ms={d:.3}\n" ++
            "drawing_count={d}\ndrawing_batch_ms={d:.3}\ndrawing_per_second={d:.2}\n" ++
            "incremental_geometry_ms={d:.3}\nsvg_bytes={d}\npeak_rss_bytes={d}\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), library.version >> 16, library.version & 0xffff, ms(start, loaded), ms(loaded, compiled_numeric), ms(compiled_numeric, first_numeric), repetitions, ms(first_numeric, numeric_batch), ms(numeric_batch, parameter_changed), ms(parameter_changed, compiled_drawing), ms(compiled_drawing, first_drawing), ms(first_drawing, hot_drawing), images, ms(hot_drawing, drawing_batch), @as(f64, @floatFromInt(images)) * 1000 / ms(hot_drawing, drawing_batch), ms(drawing_batch, incremental), size, peakRss() },
    );
    try compareOptimization(a, init.io);
    try comparePropagation(a, init.io);
    try compareInfixCalls(a);
}
