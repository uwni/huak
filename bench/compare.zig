//! Paired CLI measurements. Run: zig run bench/compare.zig -- BEFORE AFTER CASES.json
//! Cases provide a name, full CLI arguments and optional output paths to compare.
//! When the language changes, `before_args` and `after_args` give each binary
//! its own arguments, such as the same script in old and new syntax.
//! Each child is a fresh process. No engine or allocator instrumentation is used.
const std = @import("std");
const builtin = @import("builtin");
const rounds = 16;
const warmups = 2;
const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const Case = struct {
    name: []const u8,
    args: []const []const u8 = &.{},
    before_args: ?[]const []const u8 = null,
    after_args: ?[]const []const u8 = null,
    outputs: []const []const u8 = &.{},

    fn argv(case: Case, a: std.mem.Allocator, binary: []const u8, version: usize) ![]const []const u8 {
        const args = (if (version == 0) case.before_args else case.after_args) orelse case.args;
        const result = try a.alloc([]const u8, args.len + 1);
        result[0] = binary;
        @memcpy(result[1..], args);
        return result;
    }
};
const Sample = struct { ms: f64, rss: usize };
const Comparison = struct {
    name: []const u8,
    samples: [rounds][2]Sample,
    milliseconds: Difference,
    rss_bytes: Difference,
};
const Difference = struct {
    before: f64,
    after: f64,
    mean_delta: f64,
    ci95: [2]f64,

    fn of(samples: [rounds][2]Sample, comptime field: std.meta.FieldEnum(Sample)) Difference {
        var before: [rounds]f64 = undefined;
        var after: [rounds]f64 = undefined;
        var delta: [rounds]f64 = undefined;
        var sum: f64 = 0;
        for (samples, 0..) |pair, i| {
            before[i] = switch (field) {
                .ms => pair[0].ms,
                .rss => @floatFromInt(pair[0].rss),
            };
            after[i] = switch (field) {
                .ms => pair[1].ms,
                .rss => @floatFromInt(pair[1].rss),
            };
            delta[i] = after[i] - before[i];
            sum += delta[i];
        }
        const mean = sum / rounds;
        var squares: f64 = 0;
        for (delta) |value| squares += (value - mean) * (value - mean);
        // Two-sided Student t interval: 16 paired samples, 15 degrees of freedom.
        const margin = 2.131449545559323 * @sqrt(squares / (rounds - 1) / rounds);
        std.mem.sort(f64, &before, {}, std.sort.asc(f64));
        std.mem.sort(f64, &after, {}, std.sort.asc(f64));
        return .{ .before = (before[7] + before[8]) / 2, .after = (after[7] + after[8]) / 2, .mean_delta = mean, .ci95 = .{ mean - margin, mean + margin } };
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.ExpectedBeforeAfterAndCases;
    const binaries = [2][]const u8{
        try cwd.realPathFileAlloc(io, args[1], a),
        try cwd.realPathFileAlloc(io, args[2], a),
    };
    const source = try cwd.readFileAlloc(io, args[3], a, .limited(1024 * 1024));
    const cases = try std.json.parseFromSlice([]const Case, a, source, .{});
    const results = try a.alloc(Comparison, cases.value.len);
    try cwd.createDirPath(io, "target");
    var log = try cwd.createFile(io, "target/compare-child.log", .{});
    defer log.close(io);
    const hashes = [2]Digest{ try digest(a, io, binaries[0]), try digest(a, io, binaries[1]) };
    for (cases.value, results) |case, *result| {
        result.name = case.name;
        const argv = [2][]const []const u8{ try case.argv(a, binaries[0], 0), try case.argv(a, binaries[1], 1) };
        const expected = try a.alloc(Digest, case.outputs.len);
        for (0..warmups + rounds) |trial| {
            for (0..2) |order| {
                const version = (trial + order) % 2;
                for (case.outputs) |file| cwd.deleteFile(io, file) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                const sample = try measure(io, log, argv[version]);
                if (trial >= warmups) result.samples[trial - warmups][version] = sample;
                for (case.outputs, expected) |file, *reference| {
                    const actual = try digest(init.gpa, io, file);
                    if (trial == 0 and order == 0) reference.* = actual else if (!std.mem.eql(u8, reference, &actual)) {
                        std.debug.print("{s}: output changed: {s}, trial={d}, version={d}\n", .{ case.name, file, trial, version });
                        return error.OutputChanged;
                    }
                }
            }
        }
        result.milliseconds = Difference.of(result.samples, .ms);
        result.rss_bytes = Difference.of(result.samples, .rss);
        std.debug.print("{s}: ms {d:.3} -> {d:.3}; RSS {d:.0} -> {d:.0}; paired delta CI95 ms={any}, bytes={any}\n", .{ case.name, result.milliseconds.before, result.milliseconds.after, result.rss_bytes.before, result.rss_bytes.after, result.milliseconds.ci95, result.rss_bytes.ci95 });
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(.{
        .driver_zig = builtin.zig_version_string,
        .before = binaries[0],
        .after = binaries[1],
        .before_sha256 = std.fmt.bytesToHex(hashes[0], .lower),
        .after_sha256 = std.fmt.bytesToHex(hashes[1], .lower),
        .warmups = warmups,
        .rounds = rounds,
        .cases = cases.value,
        .results = results,
    }, .{ .whitespace = .indent_2 }, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn measure(io: std.Io, log: std.Io.File, argv: []const []const u8) !Sample {
    const start = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .request_resource_usage_statistics = true,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    const stop = std.Io.Clock.awake.now(io);
    if (!term.success()) {
        std.debug.print("child failed: {f}, argv={any}; see target/compare-child.log\n", .{ term, argv });
        return error.ChildFailed;
    }
    return .{
        .ms = @as(f64, @floatFromInt(start.durationTo(stop).toNanoseconds())) / 1_000_000,
        .rss = child.resource_usage_statistics.getMaxRss() orelse return error.ResourceUsageUnavailable,
    };
}

fn digest(a: std.mem.Allocator, io: std.Io, file: []const u8) !Digest {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(256 * 1024 * 1024));
    defer a.free(bytes);
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
