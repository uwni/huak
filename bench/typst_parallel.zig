//! Same checked Program, serial requests versus adjacent native text batches.
//! Timings include VM and engine creation but exclude final SVG export.
const std = @import("std");
const builtin = @import("builtin");
const huak = @import("huak");
const typst = @import("libtypst");
const metrics = @import("metrics");
const defaults = @import("host_options");
const language = huak.language;
const Digest = [std.crypto.hash.Blake3.digest_length]u8;
const trials = 4;

const Result = struct {
    execute_ms: f64,
    steps: u64,
    metrics_hash: Digest,
    svg_hash: Digest,
    svg_bytes: usize,
    layout_owners: usize,
};

fn script(allocator: std.mem.Allocator, count: usize, trial: usize, exposed: bool) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("import paint.{rgb, picture, label}\n");
    if (exposed) {
        try writer.writer.print("trial:={d}\nfont_size:=13pt\nink:=rgb(0,0,0)\ntypst_expose trial,font_size,ink\nsetup_typst {{ set text(size:huak.font_size,fill:huak.ink) }}\n", .{trial});
    } else try writer.writer.writeAll("setup_typst { set text(size: 13pt) }\n");
    // Sources differ within and between trials. Both modes execute the exact
    // same Program in each trial; alternating their order balances cache reuse.
    for (0..count) |index| {
        if (exposed) {
            try writer.writer.print("label_{d} := typ[Label #(huak.trial)-{d}: $sum_(i=1)^n i^2$ #lorem(40)]\n", .{ index, index });
        } else try writer.writer.print("label_{d} := typ[Label {d}-{d}: $sum_(i=1)^n i^2$ #lorem(40)]\n", .{ index, trial, index });
    }
    try writer.writer.print("pic := picture(24000, {d})\n", .{count * 30 + 50});
    for (0..count) |index| {
        try writer.writer.print("object.append(pic, object.label(label_{d}, (10, {d})))\n", .{ index, index * 30 + 25 });
    }
    return writer.toOwnedSlice();
}

fn compile(allocator: std.mem.Allocator, library: *typst.Library, source: []const u8) !language.bytecode.Program {
    var diagnostic: ?language.compiler.Diagnostic = null;
    return language.compiler.compile(allocator, source, "typst-parallel-benchmark.huak", .{
        .source_parser = .init(library),
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const language.bytecode.Program, batched: bool, count: usize) !Result {
    const start = std.Io.Clock.awake.now(io);
    var runtime = try language.Runtime.init(allocator, allocator, library, .{});
    defer runtime.deinit();
    var host = runtime.host();
    var vtable = host.vtable.*;
    if (!batched) vtable.typst_batch = null;
    host.vtable = &vtable;
    var machine = try language.Machine.init(allocator, program, host, .{});
    defer machine.deinit();
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |failure| std.debug.print("VM: {s}: {s}\n", .{ failure.text(), failure.native_message });
        return err;
    };
    const executed = std.Io.Clock.awake.now(io);
    if (runtime.texts.items.len != count) return error.IncorrectTextCount;
    var checksum: std.crypto.hash.Blake3 = .init(.{});
    for (runtime.texts.items) |text| {
        // Explicit components avoid incorporating unspecified struct padding.
        for ([_]f64{ text.metrics.width, text.metrics.height, text.metrics.baseline }) |component| checksum.update(std.mem.asBytes(&component));
    }
    var metrics_hash: Digest = undefined;
    checksum.final(&metrics_hash);
    var seen: std.AutoHashMapUnmanaged(*const typst.Layout, void) = .empty;
    defer seen.deinit(allocator);
    for (runtime.frames.items) |frame| try seen.put(allocator, frame.layout, {});
    var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
    defer svg.deinit();
    var svg_hash: Digest = undefined;
    std.crypto.hash.Blake3.hash(svg.bytes(), &svg_hash, .{});
    return .{
        .execute_ms = metrics.milliseconds(start, executed),
        .steps = machine.steps,
        .metrics_hash = metrics_hash,
        .svg_hash = svg_hash,
        .svg_bytes = svg.bytes().len,
        .layout_owners = seen.count(),
    };
}

fn expectSame(reference: Result, actual: Result) !void {
    if (reference.steps != actual.steps or reference.svg_bytes != actual.svg_bytes or
        !std.mem.eql(u8, &reference.metrics_hash, &actual.metrics_hash) or
        !std.mem.eql(u8, &reference.svg_hash, &actual.svg_hash)) return error.BatchingChangedResult;
}

fn median(values: [trials]f64) f64 {
    var sorted = values;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    return (sorted[trials / 2 - 1] + sorted[trials / 2]) / 2;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY [TEXT_COUNT=96]]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const count = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 96;
    if (count < 2 or count > 512) return error.InvalidTextCount;
    const start = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(if (args.len > 1) args[1] else defaults.library_path);
    defer library.deinit();
    const loaded = std.Io.Clock.awake.now(init.io);
    std.debug.print(
        "typ[] batch layout / Zig {s} / {s}-{s} / host={s} / libtypst ABI {d}.{d}\n" ++
            "texts={d} trials={d} serial=host batch callback disabled parallel=default batch callback\n" ++
            "execute timing includes VM + engine startup + layout; SVG export/checksums/cleanup excluded\n" ++
            "cold denotes first execution of this source/mode, not a cleared upstream cache\n" ++
            "mode order alternates, each trial uses unique sources; hot repeats the same Program\n" ++
            "load_ms={d:.3}\n",
        .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), library.version >> 16, library.version & 0xffff, count, trials, metrics.milliseconds(start, loaded) },
    );
    for ([_]bool{ false, true }) |exposed| try compare(init, &library, count, exposed);
}

fn compare(init: std.process.Init, library: *typst.Library, count: usize, exposed: bool) !void {
    std.debug.print("scenario_exposed_data={any}\n", .{exposed});
    var first_times: [2][trials]f64 = undefined;
    var hot_times: [2][trials]f64 = undefined;
    var compile_times: [trials]f64 = undefined;
    for (0..trials) |trial| {
        const source = try script(init.gpa, count, trial, exposed);
        defer init.gpa.free(source);
        const before_compile = std.Io.Clock.awake.now(init.io);
        var program = try compile(init.gpa, library, source);
        defer program.deinit();
        const compiled = std.Io.Clock.awake.now(init.io);
        compile_times[trial] = metrics.milliseconds(before_compile, compiled);
        var reference: ?Result = null;
        for (0..2) |order| {
            const setting = if (trial % 2 == 0) order else 1 - order;
            const batched = setting != 0;
            const first = try run(init.gpa, init.io, library, &program, batched, count);
            const hot = try run(init.gpa, init.io, library, &program, batched, count);
            try expectSame(first, hot);
            if (reference) |expected| try expectSame(expected, first) else reference = first;
            first_times[setting][trial] = first.execute_ms;
            hot_times[setting][trial] = hot.execute_ms;
            std.debug.print("trial={d} order={d} batched={any} compile_ms={d:.3} first_execute_ms={d:.3} hot_execute_ms={d:.3} vm_steps={d} layout_owners={d} svg_bytes={d}\n", .{
                trial + 1, order + 1, batched, compile_times[trial], first.execute_ms, hot.execute_ms, first.steps, first.layout_owners, first.svg_bytes,
            });
        }
    }
    std.debug.print("compile_median_ms={d:.3}\n", .{median(compile_times)});
    for (0..2) |setting| std.debug.print("batched={any} first_execute_median_ms={d:.3} hot_execute_median_ms={d:.3}\n", .{ setting != 0, median(first_times[setting]), median(hot_times[setting]) });
    std.debug.print("all_metrics_and_svg_hashes_equal=true peak_process_rss_bytes={d}\n", .{metrics.peakRssBytes()});
}
