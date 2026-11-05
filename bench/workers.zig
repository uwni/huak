//! Same-source serial/worker comparisons. Each configuration gets a fresh
//! process, so RSS peaks are attributable to that configuration alone.
const std = @import("std");
const builtin = @import("builtin");
const huak = @import("huak");
const typst = @import("libtypst");
const defaults = @import("host_options");
const metrics = @import("metrics");
const l = huak.language;
const Digest = [std.crypto.hash.Blake3.digest_length]u8;
const trials = 4;
const Configuration = struct { construct: usize, output: usize };
const configurations = [_]Configuration{
    .{ .construct = 1, .output = 1 },
    .{ .construct = 1, .output = 4 },
    .{ .construct = 2, .output = 1 },
    .{ .construct = 4, .output = 1 },
    .{ .construct = 4, .output = 4 },
};
const Workload = enum { independent, diamond, chain };

const Execution = struct {
    execute_ms: f64,
    handoff_ms: f64,
    export_ms: f64,
    steps: u64,
    tasks: usize,
    regions: usize,
    peak_active: usize,
    export_peak_active: usize,
    svg_bytes: usize,
    svg_hash: Digest,
};
const Report = struct {
    load_ms: f64,
    compile_ms: f64,
    first: Execution,
    hot: Execution,
    peak_rss_bytes: u64,
};
const Sample = struct { child: Report, wall_ms: f64 };

const prelude =
    \\import math.{sin, cos}
    \\import paint.{picture, pen, rgb, draw, label, append, translate}
    \\setup_typst { set text(size: 13pt) }
    \\caption := typ[Shared book illustration $sum_(i=1)^n i^2$ Ω]
    \\ink := pen(rgb(0.16,0.38,0.75),0.4)
    \\fn figure(index:int) -> picture
    \\ p := picture(320,280)
    \\ for stroke in 0:239 do
    \\  y := 8 + stroke * 1.0
    \\  phase := (stroke+index)*0.17
    \\  curve := (10,y) ~~ (100,y+12*sin(phase)) ~~ (210,y-10*cos(phase)) ~~ (310,y)
    \\  object.append(p, object.draw(curve, ink))
    \\ end
    \\ object.append(p, object.label(caption, (12,260)))
    \\ return p
    \\end
    \\fn extended(base:picture,index:int) -> picture
    \\ p := figure(index)
    \\ p.append(copy(base))
    \\ return p
    \\end
    \\fn combined(left:picture,right:picture) -> picture
    \\ p := picture(340,300)
    \\ p.append(copy(left))
    \\ p.append(copy(right), translate((4,4)))
    \\ return p
    \\end
    \\
;

const Fixture = struct {
    source: []u8,
    names: []const []const u8,
};

fn fixture(allocator: std.mem.Allocator, workload: Workload, count: usize) !Fixture {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(prelude);
    const names = try allocator.alloc([]const u8, switch (workload) {
        .independent => count,
        .diamond => count / 4,
        .chain => 1,
    });
    switch (workload) {
        .independent => for (names, 0..) |*name, index| {
            name.* = try std.fmt.allocPrint(allocator, "figure_{d}", .{index});
            try writer.writer.print("export {s}:=figure({d})\n", .{ name.*, index });
        },
        .diamond => for (names, 0..) |*name, index| {
            name.* = try std.fmt.allocPrint(allocator, "diamond_{d}", .{index});
            try writer.writer.print(
                "base_{d}:=figure({d})\nleft_{d}:=extended(base_{d},{d})\nright_{d}:=extended(base_{d},{d})\nexport {s}:=combined(left_{d},right_{d})\n",
                .{ index, index * 3, index, index, index * 3 + 1, index, index, index * 3 + 2, name.*, index, index },
            );
        },
        .chain => {
            try writer.writer.writeAll("chain_0:=figure(0)\n");
            for (1..count) |index| try writer.writer.print("chain_{d}:=extended(chain_{d},{d})\n", .{ index, index - 1, index });
            names[0] = try std.fmt.allocPrint(allocator, "chain_{d}", .{count - 1});
            try writer.writer.print("export {s}\n", .{names[0]});
        },
    }
    return .{ .source = try writer.toOwnedSlice(), .names = names };
}

fn sourceBlock(context: *anyopaque, source: []const u8) !usize {
    const library: *typst.Library = @ptrCast(@alignCast(context));
    return library.sourceBlock(source);
}

fn compile(allocator: std.mem.Allocator, library: *typst.Library, source: []const u8) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(allocator, source, "worker-benchmark.huak", .{ .source_parser = .{ .ptr = library, .vtable = &.{ .block = sourceBlock } } }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

const Prepared = struct {
    batch: l.OutputBatch,
    executed: std.Io.Timestamp,
    steps: u64,
    tasks: usize,
    regions: usize,
    peak_active: usize,
};

fn prepare(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program, jobs: usize, names: []const []const u8) !Prepared {
    var runtime = try l.Runtime.init(allocator, allocator, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(allocator, program, runtime.host(), .{});
    defer machine.deinit();
    var executor: l.tasks.Executor = .{ .allocator = allocator, .io = io, .runtime = &runtime, .jobs = jobs };
    executor.attach(&machine);
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |failure| std.debug.print("VM: {s}: {s}\n", .{ failure.text(), failure.native_message });
        return err;
    };
    const executed = std.Io.Clock.awake.now(io);
    const targets = try allocator.alloc(l.types.Value, names.len);
    defer allocator.free(targets);
    for (names, targets) |name, *target| target.* = machine.getGlobal(name) orelse return error.MissingExpectedGlobal;
    return .{
        .batch = try runtime.takeOutputs(targets),
        .executed = executed,
        .steps = machine.steps,
        .tasks = executor.stats.tasks,
        .regions = executor.stats.regions,
        .peak_active = executor.stats.peak_active,
    };
}

const Exported = struct {
    hash: Digest = undefined,
    length: usize = 0,
    cause: ?anyerror = null,
    diagnostic: ?typst.Buffer = null,
};
const Exports = struct {
    batch: *l.OutputBatch,
    results: []Exported,
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn one(self: *Exports, index: usize) bool {
        const active = self.active.fetchAdd(1, .acq_rel) + 1;
        _ = self.peak.fetchMax(active, .monotonic);
        defer _ = self.active.fetchSub(1, .release);
        defer self.batch.library.clearError();
        defer self.batch.release(index);
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const result = &self.results[index];
        var svg = self.batch.render(scratch.allocator(), index, .svg, &result.diagnostic) catch |err| {
            result.cause = err;
            return false;
        };
        defer svg.deinit();
        if (result.diagnostic) |*detail| detail.deinit();
        result.diagnostic = null;
        if (!std.mem.startsWith(u8, svg.bytes(), "<svg")) {
            result.cause = error.InvalidSvg;
            return false;
        }
        std.crypto.hash.Blake3.hash(svg.bytes(), &result.hash, .{});
        result.length = svg.bytes().len;
        return true;
    }
};

fn execute(allocator: std.mem.Allocator, io: std.Io, library: *typst.Library, program: *const l.bytecode.Program, config: Configuration, names: []const []const u8) !Execution {
    const start = std.Io.Clock.awake.now(io);
    var prepared = try prepare(allocator, io, library, program, config.construct, names);
    defer prepared.batch.deinit();
    const detached = std.Io.Clock.awake.now(io);
    const results = try allocator.alloc(Exported, prepared.batch.len());
    defer allocator.free(results);
    @memset(results, .{});
    defer for (results) |*result| if (result.diagnostic) |*detail| detail.deinit();
    var exports: Exports = .{ .batch = &prepared.batch, .results = results };
    try huak.worker.run(io, results.len, config.output, &exports, Exports.one);
    // Workers keep their native diagnostic owners; only the caller prints.
    for (results, 0..) |result, index| if (result.cause) |cause| {
        std.debug.print("output {d}: {s}\n", .{ index, @errorName(cause) });
        if (result.diagnostic) |detail| std.debug.print("native: {s}\n", .{detail.bytes()});
        return error.ExportFailed;
    };
    var hash: std.crypto.hash.Blake3 = .init(.{});
    var bytes: usize = 0;
    for (results) |result| {
        if (result.length == 0) return error.MissingOutput;
        hash.update(std.mem.asBytes(&result.length));
        hash.update(&result.hash);
        bytes += result.length;
    }
    const exported = std.Io.Clock.awake.now(io);
    var digest: Digest = undefined;
    hash.final(&digest);
    return .{
        .execute_ms = metrics.milliseconds(start, prepared.executed),
        .handoff_ms = metrics.milliseconds(prepared.executed, detached),
        .export_ms = metrics.milliseconds(detached, exported),
        .steps = prepared.steps,
        .tasks = prepared.tasks,
        .regions = prepared.regions,
        .peak_active = prepared.peak_active,
        .export_peak_active = exports.peak.load(.acquire),
        .svg_bytes = bytes,
        .svg_hash = digest,
    };
}

fn expectSame(expected: Execution, actual: Execution) !void {
    if (expected.steps != actual.steps or expected.svg_bytes != actual.svg_bytes or
        !std.mem.eql(u8, &expected.svg_hash, &actual.svg_hash)) return error.WorkersChangedResult;
}

fn child(init: std.process.Init, library_path: []const u8, workload: Workload, config: Configuration, count: usize) !void {
    const allocator = std.heap.smp_allocator;
    var fixture_arena: std.heap.ArenaAllocator = .init(allocator);
    defer fixture_arena.deinit();
    const input = try fixture(fixture_arena.allocator(), workload, count);
    const started = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    const loaded = std.Io.Clock.awake.now(init.io);
    var program = try compile(allocator, &library, input.source);
    defer program.deinit();
    const compiled = std.Io.Clock.awake.now(init.io);
    const first = try execute(allocator, init.io, &library, &program, config, input.names);
    const hot = try execute(allocator, init.io, &library, &program, config, input.names);
    try expectSame(first, hot);
    if (first.peak_active > config.construct or hot.peak_active > config.construct or
        first.export_peak_active > config.output or hot.export_peak_active > config.output) return error.ExceededWorkerLimit;
    const report: Report = .{
        .load_ms = metrics.milliseconds(started, loaded),
        .compile_ms = metrics.milliseconds(loaded, compiled),
        .first = first,
        .hot = hot,
        .peak_rss_bytes = metrics.peakRssBytes(),
    };
    const json = try std.json.Stringify.valueAlloc(allocator, report, .{});
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}

fn measure(allocator: std.mem.Allocator, io: std.Io, executable: []const u8, library: []const u8, workload: Workload, config: Configuration, count: usize) !Sample {
    const construct_arg = try std.fmt.allocPrint(allocator, "{d}", .{config.construct});
    defer allocator.free(construct_arg);
    const output_arg = try std.fmt.allocPrint(allocator, "{d}", .{config.output});
    defer allocator.free(output_arg);
    const count_arg = try std.fmt.allocPrint(allocator, "{d}", .{count});
    defer allocator.free(count_arg);
    const start = std.Io.Clock.awake.now(io);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "--sample", library, @tagName(workload), construct_arg, output_arg, count_arg },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const end = std.Io.Clock.awake.now(io);
    if (!result.term.success()) {
        std.debug.print("worker sample failed: {f}\n{s}\n", .{ result.term, result.stderr });
        return error.ChildFailed;
    }
    const parsed = try std.json.parseFromSlice(Report, allocator, result.stdout, .{});
    defer parsed.deinit();
    return .{ .child = parsed.value, .wall_ms = metrics.milliseconds(start, end) };
}

fn median(comptime T: type, values: [trials]T) T {
    var sorted = values;
    std.mem.sort(T, &sorted, {}, std.sort.asc(T));
    return sorted[trials / 2 - 1] + (sorted[trials / 2] - sorted[trials / 2 - 1]) / 2;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 7 and std.mem.eql(u8, args[1], "--sample")) {
        const count = try std.fmt.parseInt(usize, args[6], 10);
        try validateCount(count);
        const config: Configuration = .{
            .construct = try std.fmt.parseInt(usize, args[4], 10),
            .output = try std.fmt.parseInt(usize, args[5], 10),
        };
        if (config.construct == 0 or config.output == 0) return error.InvalidWorkerCount;
        return child(init, args[2], std.meta.stringToEnum(Workload, args[3]) orelse return error.InvalidWorkload, config, count);
    }
    if (args.len > 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY [TASKS=24, multiple of four]]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const count = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 24;
    try validateCount(count);
    const allocator = init.gpa;
    const library = try std.Io.Dir.cwd().realPathFileAlloc(init.io, if (args.len > 1) args[1] else defaults.library_path, allocator);
    defer allocator.free(library);
    const executable = try std.process.executablePathAlloc(init.io, allocator);
    defer allocator.free(executable);
    std.debug.print(
        "drawing workers / Zig {s} / {s}-{s} / host={s}\n" ++
            "tasks={d} curves_per_figure=240 trials_per_configuration={d}\n" ++
            "each sample is a fresh process; each child compiles once and runs the same Program twice\n" ++
            "first/hot execution include VM + runtime + text + geometry; handoff includes construction cleanup\n" ++
            "configurations=construct/output 1/1,1/4,2/1,4/1,4/4; each SVG buffer is released immediately\n" ++
            "RSS is the child process peak, including compile, first/hot execution and export\n" ++
            "construct=1 uses ordinary serial VM; construct=2/4 uses automatic dependency scheduling\n" ++
            "native_library={s}\n",
        .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), count, trials, library },
    );
    for (std.enums.values(Workload)) |workload| {
        var samples: [configurations.len][trials]Sample = undefined;
        var reference: ?Execution = null;
        for (0..trials) |trial| for (0..configurations.len) |order| {
            const setting = if (trial % 2 == 0) order else configurations.len - 1 - order;
            const config = configurations[setting];
            const sample = try measure(allocator, init.io, executable, library, workload, config, count);
            samples[setting][trial] = sample;
            if (reference) |expected| try expectSame(expected, sample.child.first) else reference = sample.child.first;
            try expectSame(sample.child.first, sample.child.hot);
            std.debug.print(
                "workload={s} trial={d} order={d} construct={d} output={d} compile_ms={d:.3} first_execute_ms={d:.3} hot_execute_ms={d:.3} handoff_ms={d:.3} export_ms={d:.3} wall_ms={d:.3} peak_rss_bytes={d} tasks={d} regions={d} peak_active={d} export_peak_active={d}\n",
                .{ @tagName(workload), trial + 1, order + 1, config.construct, config.output, sample.child.compile_ms, sample.child.first.execute_ms, sample.child.hot.execute_ms, sample.child.hot.handoff_ms, sample.child.hot.export_ms, sample.wall_ms, sample.child.peak_rss_bytes, sample.child.hot.tasks, sample.child.hot.regions, sample.child.hot.peak_active, sample.child.hot.export_peak_active },
            );
        };
        var baseline: f64 = 0;
        var baseline_wall: f64 = 0;
        for (configurations, samples) |config, series| {
            var first: [trials]f64 = undefined;
            var hot: [trials]f64 = undefined;
            var compiled: [trials]f64 = undefined;
            var exports: [trials]f64 = undefined;
            var wall: [trials]f64 = undefined;
            var rss: [trials]u64 = undefined;
            for (series, 0..) |sample, index| {
                first[index] = sample.child.first.execute_ms;
                hot[index] = sample.child.hot.execute_ms;
                compiled[index] = sample.child.compile_ms;
                exports[index] = sample.child.hot.export_ms;
                wall[index] = sample.wall_ms;
                rss[index] = sample.child.peak_rss_bytes;
            }
            const hot_median = median(f64, hot);
            const wall_median = median(f64, wall);
            if (config.construct == 1 and config.output == 1) {
                baseline = hot_median;
                baseline_wall = wall_median;
            }
            std.debug.print(
                "summary workload={s} construct={d} output={d} compile_median_ms={d:.3} first_execute_median_ms={d:.3} hot_execute_median_ms={d:.3} hot_execution_speedup={d:.3} export_median_ms={d:.3} process_wall_median_ms={d:.3} process_speedup={d:.3} peak_rss_median_bytes={d}\n",
                .{ @tagName(workload), config.construct, config.output, median(f64, compiled), median(f64, first), hot_median, baseline / hot_median, median(f64, exports), wall_median, baseline_wall / wall_median, median(u64, rss) },
            );
        }
        std.debug.print("workload={s} all_svg_hashes_and_steps_equal=true total_svg_bytes={d}\n", .{ @tagName(workload), reference.?.svg_bytes });
    }
}

fn validateCount(count: usize) !void {
    // Each chain extension appends its predecessor, adding one picture group.
    // Keep the common four-node diamond workload within the same public limit.
    const maximum = (huak.core.DisplayList.max_scope_depth + 1) / 4 * 4;
    if (count < 4 or count > maximum or count % 4 != 0) return error.InvalidTaskCount;
}
