//! Alternate already-built region benchmarks. No implementation is linked or
//! built here; children run serially with their original default workloads.
const std = @import("std");
const clap = @import("clap");
const results = @import("regions/results.zig");
const Allocator = std.mem.Allocator;

const params = clap.parseParamsComptime(
    \\-h, --help       Show usage.
    \\--cpp <PATH>     Retained C++ reference executable.
    \\--before <PATH>  Zig executable before optimization.
    \\--after <PATH>   Zig executable after optimization.
    \\--rounds <N>     Measured rounds, at least 6 (default: 6).
    \\--output <DIR>   Directory for raw logs, round data and summary.
);

const Engine = enum { cpp, before, after };
const engines = [_]Engine{ .cpp, .before, .after };
const orders = [_][3]Engine{
    .{ .cpp, .before, .after },
    .{ .cpp, .after, .before },
    .{ .before, .cpp, .after },
    .{ .before, .after, .cpp },
    .{ .after, .cpp, .before },
    .{ .after, .before, .cpp },
};

const Configuration = struct {
    executables: [3][]const u8,
    rounds: usize,
    orders: []const [3]Engine = &orders,
    warmups_per_engine: usize = 1,
    child_arguments: []const []const u8 = &.{},
    scheduling: []const u8 = "Serial spawn/wait. Cycle through all six engine permutations. Warmup is excluded from aggregates.",
    rss_scope: []const u8 = "Whole child-process high-water RSS includes fixtures and validation. Per-case RSS is cumulative within that process; it is not an operation or allocator peak.",
    first_call_scope: []const u8 = "First call for each case within a child process, not an independent process cold start.",
};

const Run = struct {
    engine: Engine,
    order: usize,
    stderr_log: []const u8,
    stdout_log: []const u8,
    process_wall_ms: f64,
    process_peak_rss_bytes: ?usize,
    report: results.Report,
};
const Round = struct { number: usize, order: [3]Engine, runs: [3]Run };
const EngineSummary = struct {
    engine: Engine,
    hot_median_us: results.Statistics,
    first_call_us: results.Statistics,
    cumulative_process_peak_rss_bytes: results.Statistics,
    elements: usize,
    cubics: usize,
    lines: usize,
};
const CaseSummary = struct { name: []const u8, operation: []const u8, tolerance: f64, repeats: usize, engines: [3]EngineSummary };

fn writeJson(allocator: Allocator, io: std.Io, directory: std.Io.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try directory.writeFile(io, .{ .sub_path = name, .data = bytes, .flags = .{ .exclusive = true } });
}

fn process(allocator: Allocator, io: std.Io, directory: std.Io.Dir, executable: []const u8, engine: Engine, order: usize, prefix: []const u8) !Run {
    const stderr_name = try std.fmt.allocPrint(allocator, "{s}-{s}.stderr.log", .{ prefix, @tagName(engine) });
    const stdout_name = try std.fmt.allocPrint(allocator, "{s}-{s}.stdout.log", .{ prefix, @tagName(engine) });
    const stderr = try directory.createFile(io, stderr_name, .{ .exclusive = true });
    defer stderr.close(io);
    const stdout = try directory.createFile(io, stdout_name, .{ .exclusive = true });
    defer stdout.close(io);
    std.debug.print("{s}: {s}, order={d}\n", .{ prefix, @tagName(engine), order });
    const started = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{executable},
        .stdin = .ignore,
        .stdout = .{ .file = stdout },
        .stderr = .{ .file = stderr },
        .request_resource_usage_statistics = true,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    const stopped = std.Io.Clock.awake.now(io);
    if (!term.success()) {
        std.debug.print("{s} failed ({f}); raw stderr retained at {s}\n", .{ @tagName(engine), term, stderr_name });
        return error.BenchmarkChildFailed;
    }
    const bytes = try directory.readFileAlloc(io, stderr_name, allocator, .limited(1024 * 1024));
    // Result strings borrow these arena-owned bytes until the final report.
    const report = results.parse(bytes) catch |err| {
        std.debug.print("invalid {s} result: {s}; raw stderr retained at {s}\n", .{ @tagName(engine), @errorName(err), stderr_name });
        return err;
    };
    return .{
        .engine = engine,
        .order = order,
        .stderr_log = stderr_name,
        .stdout_log = stdout_name,
        .process_wall_ms = @as(f64, @floatFromInt(started.durationTo(stopped).toNanoseconds())) / 1_000_000,
        .process_peak_rss_bytes = child.resource_usage_statistics.getMaxRss(),
        .report = report,
    };
}

fn quoteCsv(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

fn writeRoundCsv(allocator: Allocator, io: std.Io, directory: std.Io.Dir, round: Round) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("round,order,engine,case,operation,tolerance,repeats,first_call_us,hot_median_us,trial_1_us,trial_2_us,trial_3_us,elements,cubics,lines,cumulative_process_peak_rss_bytes,checksum,process_wall_ms,child_process_peak_rss_bytes\n");
    for (round.runs) |run| for (run.report.cases) |case| {
        try writer.print("{d},{d},{s},", .{ round.number, run.order, @tagName(run.engine) });
        try quoteCsv(writer, case.name);
        try writer.writeByte(',');
        try quoteCsv(writer, case.operation);
        try writer.print(",{e},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d},{d:.6},", .{ case.tolerance, case.repeats, case.first_call_us, case.hot_median_us, case.trials_us[0], case.trials_us[1], case.trials_us[2], case.elements, case.cubics, case.lines, case.peak_rss_bytes, case.checksum, run.process_wall_ms });
        if (run.process_peak_rss_bytes) |rss| try writer.print("{d}", .{rss});
        try writer.writeByte('\n');
    };
    const name = try std.fmt.allocPrint(allocator, "round-{d:0>4}.csv", .{round.number});
    defer allocator.free(name);
    try directory.writeFile(io, .{ .sub_path = name, .data = output.written(), .flags = .{ .exclusive = true } });
}

fn summarize(allocator: Allocator, rounds: []const Round, warmups: [3]Run) ![results.case_count]CaseSummary {
    var summary: [results.case_count]CaseSummary = undefined;
    const scratch = try allocator.alloc(f64, rounds.len);
    defer allocator.free(scratch);
    for (&summary, warmups[0].report.cases, 0..) |*entry, case, case_index| {
        entry.* = .{ .name = case.name, .operation = case.operation, .tolerance = case.tolerance, .repeats = case.repeats, .engines = undefined };
        for (engines, &entry.engines) |engine, *aggregate| {
            aggregate.* = .{ .engine = engine, .hot_median_us = undefined, .first_call_us = undefined, .cumulative_process_peak_rss_bytes = undefined, .elements = warmups[@backingInt(engine)].report.cases[case_index].elements, .cubics = warmups[@backingInt(engine)].report.cases[case_index].cubics, .lines = warmups[@backingInt(engine)].report.cases[case_index].lines };
            inline for (.{ "hot_median_us", "first_call_us", "cumulative_process_peak_rss_bytes" }) |field| {
                for (rounds, scratch) |round, *value| {
                    const measurement = round.runs[@backingInt(engine)].report.cases[case_index];
                    value.* = if (comptime std.mem.eql(u8, field, "cumulative_process_peak_rss_bytes")) @floatFromInt(measurement.peak_rss_bytes) else @field(measurement, field);
                }
                @field(aggregate.*, field) = results.statistics(scratch);
            }
        }
    }
    return summary;
}

fn compare(allocator: Allocator, io: std.Io, directory: std.Io.Dir, config: Configuration) !void {
    var warmups: [3]Run = undefined;
    for (engines, 0..) |engine, index| {
        warmups[index] = try process(allocator, io, directory, config.executables[index], engine, index + 1, "warmup");
        if (index != 0) try results.verifyMetadata(warmups[0].report, warmups[index].report);
    }
    try writeJson(allocator, io, directory, "warmups.json", warmups);
    const rounds = try allocator.alloc(Round, config.rounds);
    for (rounds, 0..) |*round, index| {
        round.* = .{ .number = index + 1, .order = orders[index % orders.len], .runs = undefined };
        const prefix = try std.fmt.allocPrint(allocator, "round-{d:0>4}", .{round.number});
        defer allocator.free(prefix);
        for (round.order, 0..) |engine, position| {
            const engine_index = @backingInt(engine);
            const run = try process(allocator, io, directory, config.executables[engine_index], engine, position + 1, prefix);
            try results.verifyMetadata(warmups[0].report, run.report);
            try results.verifyOutput(warmups[engine_index].report, run.report);
            round.runs[engine_index] = run;
        }
        try writeRoundCsv(allocator, io, directory, round.*);
        const name = try std.fmt.allocPrint(allocator, "{s}.json", .{prefix});
        defer allocator.free(name);
        try writeJson(allocator, io, directory, name, round.*);
    }
    const summary = try summarize(allocator, rounds, warmups);
    try writeJson(allocator, io, directory, "summary.json", .{
        .status = "complete",
        .configuration = config,
        .balanced_complete_order_cycles = config.rounds % orders.len == 0,
        .aggregation = "For each case and engine, median/min/max of per-process hot_median_us across measured rounds. Each process reports the median of its three original trials. Even-sized round sets use the mean of the middle two observations.",
        .cases = summary,
        .warmups = warmups,
        .rounds = rounds,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    var diagnostic: clap.Diagnostic = .{};
    const args = clap.parse(clap.Help, &params, .{ .PATH = clap.parsers.string, .DIR = clap.parsers.string, .N = clap.parsers.int(usize, 10) }, init.minimal.args, .{ .allocator = allocator, .diagnostic = &diagnostic }) catch |err| {
        try diagnostic.reportToFile(io, .stderr(), err);
        return err;
    };
    defer args.deinit();
    if (args.args.help != 0) return clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
    const paths = [_][]const u8{ args.args.cpp orelse return error.MissingCppExecutable, args.args.before orelse return error.MissingBeforeExecutable, args.args.after orelse return error.MissingAfterExecutable };
    const destination = args.args.output orelse return error.MissingOutputDirectory;
    const count = args.args.rounds orelse 6;
    if (count < orders.len) return error.TooFewRounds;
    const cwd = std.Io.Dir.cwd();
    var executables: [3][]const u8 = undefined;
    for (paths, &executables) |path, *resolved| resolved.* = try cwd.realPathFileAlloc(io, path, allocator);
    try cwd.createDirPath(io, destination);
    var directory = try cwd.openDir(io, destination, .{});
    defer directory.close(io);
    const config: Configuration = .{ .executables = executables, .rounds = count };
    // Exclusive files reject accidental overwrites or two runners sharing a
    // directory. On failure, completed rounds and raw child logs remain.
    try writeJson(allocator, io, directory, "run.json", config);
    compare(allocator, io, directory, config) catch |err| {
        try writeJson(allocator, io, directory, "failure.json", .{ .status = "rejected", .error_name = @errorName(err), .summary_accepted = false });
        return err;
    };
    std.debug.print("comparison accepted: {d} measured rounds, {d} cases; logs and summary in {s}\n", .{ count, results.case_count, destination });
}

test "all six serial engine orders occur once per complete cycle" {
    for (orders, 0..) |order, index| {
        var seen: [engines.len]bool = @splat(false);
        for (order) |engine| {
            try std.testing.expect(!seen[@backingInt(engine)]);
            seen[@backingInt(engine)] = true;
        }
        for (orders[0..index]) |previous| try std.testing.expect(!std.mem.eql(Engine, &order, &previous));
    }
    for (engines) |engine| for (0..engines.len) |position| {
        var count: usize = 0;
        for (orders) |order| if (order[position] == engine) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), count);
    };
    _ = results;
}
