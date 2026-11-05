//! Independent native/MetaPost processes, matched numeric inputs and contracts.
//! MetaPost timings include its parser/VM, assignment and final control export.
//! N/2N differences remove fixed costs; they are not a pure C-kernel timer.
const std = @import("std");
const builtin = @import("builtin");
const metrics = @import("metrics");
const inputs = @import("pen_compare/cases.zig");
const mp = @import("pen_compare/metapost.zig");
const core = inputs.core;
const Sample = struct { wall_ms: f64, cpu_ms: f64, rss: u64 };
const NativeReport = struct { setup_ms: f64, loop_ms: f64, export_ms: f64, setup_rss: u64, loop_rss: u64, segments: usize, checksum: f64 };

fn native(init: std.process.Init, case: inputs.Case, repeats: usize) !void {
    const a = init.gpa;
    const start = std.Io.Clock.awake.now(init.io);
    var source = try inputs.path(a, case);
    defer source.deinit();
    var vertices: [16]inputs.Point = undefined;
    const nib: core.pen.Nib = .{ .polygon = inputs.vertices(case, &vertices) };
    var result = try source.clone(a);
    defer result.deinit();
    const setup_rss = metrics.peakRssBytes();
    const ready = std.Io.Clock.awake.now(init.io);
    for (0..repeats) |_| {
        const next = switch (case.mode) {
            .envelope => try @call(.never_inline, core.pen.envelope, .{ a, nib, source, core.pen.EnvelopeOptions{ .join = .round } }),
            .stroke => try @call(.never_inline, core.pen.strokeOutline, .{ a, nib, source, core.pen.StrokeOptions{ .join = .round, .cap = .round } }),
        };
        result.deinit();
        result = next;
        std.mem.doNotOptimizeAway(result.segments.items.ptr);
    }
    const done = std.Io.Clock.awake.now(init.io);
    const loop_rss = metrics.peakRssBytes();
    const export_start = std.Io.Clock.awake.now(init.io);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var current: inputs.Point = .zero;
    var first: inputs.Point = .zero;
    var checksum: f64 = 0;
    var count: usize = 0;
    for (result.segments.items) |segment| {
        const curve: inputs.Cubic = switch (segment) {
            .move => |point| {
                current = point;
                first = point;
                continue;
            },
            .line => |point| .line(current, point),
            .cubic => |value| .{ .p0 = current, .p1 = value.c1, .p2 = value.c2, .p3 = value.end },
            .close => if (current.x == first.x and current.y == first.y) continue else .line(current, first),
        };
        if (!curve.isFinite()) return error.NonFiniteResult;
        try output.writer.print("{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17},{d:.17}\n", .{ curve.p0.x, curve.p0.y, curve.p1.x, curve.p1.y, curve.p2.x, curve.p2.y, curve.p3.x, curve.p3.y });
        checksum += curve.p0.x + curve.p1.y + curve.p2.x + curve.p3.y;
        count += 1;
        current = curve.p3;
    }
    if (count == 0 or !std.math.isFinite(checksum)) return error.InvalidResult;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "native-result.csv", .data = output.written() });
    const report: NativeReport = .{ .setup_ms = metrics.milliseconds(start, ready), .loop_ms = metrics.milliseconds(ready, done), .export_ms = metrics.milliseconds(export_start, std.Io.Clock.awake.now(init.io)), .setup_rss = setup_rss, .loop_rss = loop_rss, .segments = count, .checksum = checksum };
    const json = try std.json.Stringify.valueAlloc(a, report, .{});
    defer a.free(json);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "native-report.json", .data = json });
}

fn process(io: std.Io, work: std.Io.Dir, argv: []const []const u8) !Sample {
    const log = try work.createFile(io, "child.log", .{});
    defer log.close(io);
    const start = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = .{ .dir = work }, .stdin = .ignore, .stdout = .{ .file = log }, .stderr = .{ .file = log }, .request_resource_usage_statistics = true });
    defer child.kill(io);
    const term = try child.wait(io);
    const done = std.Io.Clock.awake.now(io);
    if (!term.success()) {
        const diagnostic = try work.readFileAlloc(io, "child.log", std.heap.page_allocator, .limited(1024 * 1024));
        defer std.heap.page_allocator.free(diagnostic);
        std.debug.print("benchmark child failed: {f}\n{s}\n", .{ term, diagnostic });
        return error.ChildFailed;
    }
    const usage = child.resource_usage_statistics;
    const cpu_ms: f64 = switch (builtin.os.tag) {
        .macos, .linux => if (usage.rusage) |value|
            @as(f64, @floatFromInt(value.utime.sec + value.stime.sec)) * 1000 + @as(f64, @floatFromInt(value.utime.usec + value.stime.usec)) / 1000
        else
            return error.ResourceUsageUnavailable,
        else => return error.UnsupportedPlatform,
    };
    return .{ .wall_ms = metrics.milliseconds(start, done), .cpu_ms = cpu_ms, .rss = usage.getMaxRss() orelse return error.ResourceUsageUnavailable };
}

fn readCurves(allocator: std.mem.Allocator, io: std.Io, work: std.Io.Dir, file: []const u8) ![]inputs.Cubic {
    const bytes = try work.readFileAlloc(io, file, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var curves: std.ArrayList(inputs.Cubic) = .empty;
    errdefer curves.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ',');
        var values: [8]f64 = undefined;
        for (&values) |*value| {
            value.* = try std.fmt.parseFloat(f64, fields.next() orelse return error.InvalidResult);
            if (!std.math.isFinite(value.*)) return error.NonFiniteResult;
        }
        if (fields.next() != null) return error.InvalidResult;
        try curves.append(allocator, .{ .p0 = .{ .x = values[0], .y = values[1] }, .p1 = .{ .x = values[2], .y = values[3] }, .p2 = .{ .x = values[4], .y = values[5] }, .p3 = .{ .x = values[6], .y = values[7] } });
    }
    if (curves.items.len == 0) return error.InvalidResult;
    return curves.toOwnedSlice(allocator);
}

fn winding(curves: []const inputs.Cubic, point: inputs.Point) i32 {
    var total: i32 = 0;
    for (curves) |curve| {
        var previous = curve.p0;
        for (1..65) |index| {
            const next = curve.at(@as(f64, @floatFromInt(index)) / 64);
            const cross = next.sub(previous).cross(point.sub(previous));
            if (previous.y <= point.y and next.y > point.y and cross > 0) total += 1;
            if (previous.y > point.y and next.y <= point.y and cross < 0) total -= 1;
            previous = next;
        }
    }
    return total;
}

fn bounds(curves: []const inputs.Cubic) core.geometry.BBox {
    var box = curves[0].bounds();
    for (curves[1..]) |curve| box = box.unite(curve.bounds());
    return box;
}

fn verify(allocator: std.mem.Allocator, io: std.Io, work: std.Io.Dir) !void {
    const actual = try readCurves(allocator, io, work, "native-result.csv");
    defer allocator.free(actual);
    const reference = try readCurves(allocator, io, work, "mp-result.csv");
    defer allocator.free(reference);
    const left = bounds(actual);
    const right = bounds(reference);
    const tolerance: f64 = 1e-7;
    if (@abs(left.min.x - right.min.x) > tolerance or @abs(left.min.y - right.min.y) > tolerance or @abs(left.max.x - right.max.x) > tolerance or @abs(left.max.y - right.max.y) > tolerance) return error.DifferentResultBounds;
    const box = left.unite(right).expanded(1);
    var checksum: i64 = 0;
    for (0..23) |y| for (0..27) |x| {
        const point: inputs.Point = .{ .x = box.min.x + (box.max.x - box.min.x) * (@as(f64, @floatFromInt(x)) + 0.371) / 27, .y = box.min.y + (box.max.y - box.min.y) * (@as(f64, @floatFromInt(y)) + 0.613) / 23 };
        const one = winding(actual, point);
        const two = winding(reference, point);
        if ((one != 0) != (two != 0)) return error.DifferentResultCoverage;
        checksum += one;
    };
    std.debug.print(" verified_bounds=({d:.6},{d:.6},{d:.6},{d:.6}) coverage_samples=621 coverage_checksum={d} controls_native={d} controls_mp={d}\n", .{ left.min.x, left.min.y, left.max.x, left.max.y, checksum, actual.len, reference.len });
}

fn median(allocator: std.mem.Allocator, samples: []const Sample, comptime field: []const u8) !f64 {
    const values = try allocator.alloc(f64, samples.len);
    defer allocator.free(values);
    for (samples, values) |sample, *value| value.* = if (comptime std.mem.eql(u8, field, "rss")) @floatFromInt(sample.rss) else @field(sample, field);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--empty")) return;
    if (args.len == 4 and std.mem.eql(u8, args[1], "--native")) {
        const index = try std.fmt.parseInt(usize, args[2], 10);
        if (index >= inputs.cases.len) return error.InvalidArguments;
        return native(init, inputs.cases[index], try std.fmt.parseInt(usize, args[3], 10));
    }
    if (args.len < 2 or args.len > 5) {
        std.debug.print("usage: bench-pen-compare MPOST [REPEATS=200] [TRIALS=3] [DIRECTORY=target/bench-pen-compare]\n", .{});
        return;
    }
    const count = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 200;
    const trials = if (args.len >= 4) try std.fmt.parseInt(usize, args[3], 10) else 3;
    if (count == 0 or count > 10000 or trials == 0 or trials > 9) return error.InvalidArguments;
    const benchmark_start = std.Io.Clock.awake.now(init.io);
    const cwd = std.Io.Dir.cwd();
    const executable = try cwd.realPathFileAlloc(init.io, args[0], a);
    const metapost = try cwd.realPathFileAlloc(init.io, args[1], a);
    const version = try std.process.run(a, init.io, .{ .argv = &.{ metapost, "--version" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    if (!version.term.success()) return error.MetaPostVersionFailed;
    var version_lines = std.mem.splitScalar(u8, version.stdout, '\n');
    const directory = if (args.len == 5) args[4] else "target/bench-pen-compare";
    try cwd.createDirPath(init.io, directory);
    var parent = try cwd.openDir(init.io, directory, .{});
    defer parent.close(init.io);
    var random: [8]u8 = undefined;
    try init.io.randomSecure(&random);
    const name = try std.fmt.allocPrint(a, "run-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try parent.createDir(init.io, name, .default_dir);
    var work = try parent.openDir(init.io, name, .{});
    defer work.close(init.io);
    try work.writeFile(init.io, .{ .sub_path = "empty.mp", .data = "end\n" });
    std.debug.print("pen-compare Zig {s} {s} {s}-{s} cpu_target={s}; N={d} 2N={d} trials={d}\nlogs={s}/{s}\n", .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), builtin.cpu.model.name, count, count * 2, trials, directory, name });
    std.debug.print("native_executable={s}\nmetapost_executable={s}\nmetapost_version={s}\n", .{ executable, metapost, version_lines.next() orelse return error.MetaPostVersionFailed });
    std.debug.print("MetaPost: --numbersystem=double; all cases rounded join/cap, limit=4. Single envelopes use the original closed path/direction; full closed strokes select an existing smooth knot first, otherwise cut t=0.5, with round construction caps in both engines. Selection/opening remains inside each timed loop.\nProcess wall includes startup/input parse/VM/loop/control export. Native setup/loop/export are separately clocked; MP N-to-2N slopes include VM/operator/assignment/free and are NOT pure kernel timings. MP input reading/setup/export cannot be individually clocked by this CLI; slopes cancel their fixed cost. No SVG/PDF rendering is measured.\nRSS is whole-process peak; baseline subtraction is a process high-water difference, not an allocator peak. Filesystem caches are not flushed.\n", .{});
    for ([_][]const u8{ "native", "mpost" }, 0..) |engine, e| {
        const samples = try a.alloc(Sample, trials);
        for (samples) |*sample| sample.* = if (e == 0) try process(init.io, work, &.{ executable, "--empty" }) else try process(init.io, work, &.{ metapost, "--numbersystem=double", "--interaction=nonstopmode", "empty.mp" });
        std.debug.print("empty_startup engine={s} median_wall_ms={d:.4} median_cpu_ms={d:.4} median_peak_rss_bytes={d:.0}\n", .{ engine, try median(a, samples, "wall_ms"), try median(a, samples, "cpu_ms"), try median(a, samples, "rss") });
    }
    for (inputs.cases, 0..) |case, index| {
        const storage = try a.alloc(Sample, 2 * 3 * trials);
        const reports = try a.alloc(NativeReport, 3 * trials);
        const label = try std.fmt.allocPrint(a, "{d}", .{index});
        for (0..trials) |trial| for (0..3) |batch_order| {
            const batch = if (trial % 2 == 0) batch_order else 2 - batch_order;
            const repeats = batch * count;
            const repeat_arg = try std.fmt.allocPrint(a, "{d}", .{repeats});
            const source = try mp.source(init.gpa, case, repeats);
            defer init.gpa.free(source);
            try work.writeFile(init.io, .{ .sub_path = "batch.mp", .data = source });
            for (0..2) |order| {
                const engine = if ((trial + batch) % 2 == 0) order else 1 - order;
                const sample = if (engine == 0) try process(init.io, work, &.{ executable, "--native", label, repeat_arg }) else try process(init.io, work, &.{ metapost, "--numbersystem=double", "--interaction=nonstopmode", "batch.mp" });
                storage[(engine * 3 + batch) * trials + trial] = sample;
                std.debug.print("sample mode={s} case={s} engine={s} trial={d} order={d} repeats={d} process_ms={d:.4} process_cpu_ms={d:.4} peak_rss_bytes={d}", .{ @tagName(case.mode), case.name, if (engine == 0) "native" else "mpost", trial + 1, order + 1, repeats, sample.wall_ms, sample.cpu_ms, sample.rss });
                if (engine == 0) {
                    const bytes = try work.readFileAlloc(init.io, "native-report.json", a, .limited(4096));
                    const parsed = try std.json.parseFromSlice(NativeReport, a, bytes, .{});
                    const report = parsed.value;
                    reports[batch * trials + trial] = report;
                    std.debug.print(" setup_ms={d:.4} loop_ms={d:.4} export_ms={d:.4} loop_peak_rss_bytes={d} setup_peak_rss_bytes={d} controls={d} checksum={d:.6}", .{ report.setup_ms, report.loop_ms, report.export_ms, report.loop_rss, report.setup_rss, report.segments, report.checksum });
                }
                std.debug.print("\n", .{});
            }
            if (repeats != 0) try verify(init.gpa, init.io, work);
        };
        for ([_][]const u8{ "native", "mpost" }, 0..) |engine, e| {
            const baseline = storage[(e * 3) * trials ..][0..trials];
            const small = storage[(e * 3 + 1) * trials ..][0..trials];
            const large = storage[(e * 3 + 2) * trials ..][0..trials];
            const base_ms = try median(a, baseline, "wall_ms");
            const one_ms = try median(a, small, "wall_ms");
            const two_ms = try median(a, large, "wall_ms");
            const one_cpu = try median(a, small, "cpu_ms");
            const two_cpu = try median(a, large, "cpu_ms");
            const base_rss = try median(a, baseline, "rss");
            const peak_rss = try median(a, large, "rss");
            std.debug.print("summary mode={s} case={s} engine={s} baseline_ms={d:.4} N_ms={d:.4} twoN_ms={d:.4} baseline_subtracted_N_us={d:.4} slope_us={d:.4} cpu_slope_us={d:.4} baseline_rss_bytes={d:.0} whole_rss_bytes={d:.0} rss_increment_bytes={d:.0}\n", .{ @tagName(case.mode), case.name, engine, base_ms, one_ms, two_ms, (one_ms - base_ms) * 1000 / @as(f64, @floatFromInt(count)), (two_ms - one_ms) * 1000 / @as(f64, @floatFromInt(count)), (two_cpu - one_cpu) * 1000 / @as(f64, @floatFromInt(count)), base_rss, peak_rss, @max(0, peak_rss - base_rss) });
        }
        const loop_samples = try a.alloc(Sample, trials);
        for (reports[2 * trials ..][0..trials], loop_samples) |report, *sample| sample.* = .{ .wall_ms = report.loop_ms, .cpu_ms = 0, .rss = report.loop_rss };
        std.debug.print("native_loop mode={s} case={s} median_us_per_item={d:.4} count={d}; includes allocation/replacement/free, excludes final validation/control export\n", .{ @tagName(case.mode), case.name, try median(a, loop_samples, "wall_ms") * 1000 / @as(f64, @floatFromInt(count * 2)), count * 2 });
    }
    std.debug.print("benchmark_total_wall_ms={d:.3}\n", .{metrics.milliseconds(benchmark_start, std.Io.Clock.awake.now(init.io))});
}
