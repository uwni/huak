//! Fresh CLI processes versus the actual persistent watch protocol. Source
//! edits only append comments to a private copy of the brushes example.
const std = @import("std");
const metrics = @import("metrics");
const Event = struct { event: []const u8, duration_ms: ?i64 = null, message: ?[]const u8 = null };
const Digest = [std.crypto.hash.Blake3.digest_length]u8;

fn next(reader: *std.Io.File.MultiReader, allocator: std.mem.Allocator, io: std.Io) !Event {
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake }) };
    while (true) {
        const stream = reader.reader(0);
        if (std.mem.indexOfScalar(u8, stream.buffered(), '\n')) |end| {
            const parsed = try std.json.parseFromSlice(Event, allocator, stream.buffered()[0..end], .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
            stream.toss(end + 1);
            return parsed.value;
        }
        try reader.fill(128, timeout);
    }
}

fn verify(allocator: std.mem.Allocator, io: std.Io, path: []const u8, expected: *?Digest) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    if (!std.mem.startsWith(u8, bytes, "<svg")) return error.InvalidSvg;
    var hash: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &hash, .{});
    if (expected.*) |previous| {
        if (!std.mem.eql(u8, &previous, &hash)) return error.OutputChanged;
    } else expected.* = hash;
    std.debug.print("bytes={d} svg_paths={d} hash={s}\n", .{ bytes.len, std.mem.count(u8, bytes, "<path"), std.fmt.bytesToHex(hash, .lower) });
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1) {
        std.debug.print("usage: bench-brushes-process HUAK LIBTYPST SCRIPT OUTPUT_PREFIX REPETITIONS\n", .{});
        return;
    }
    if (args.len != 6) return error.InvalidArguments;
    const executable = try cwd.realPathFileAlloc(io, args[1], a);
    const library = try cwd.realPathFileAlloc(io, args[2], a);
    const source_path = try cwd.realPathFileAlloc(io, args[3], a);
    const source = try cwd.readFileAlloc(io, source_path, a, .unlimited);
    const count = try std.fmt.parseInt(usize, args[5], 10);
    if (count == 0 or count > 20) return error.InvalidArguments;
    const output = try std.fmt.allocPrint(a, "{s}-process.svg", .{args[4]});
    const watched = try std.fmt.allocPrint(a, "{s}-watch.huak", .{args[4]});
    const child_log = try std.fmt.allocPrint(a, "{s}-child.log", .{args[4]});
    var expected: ?Digest = null;
    std.debug.print("executable={s} library={s} source={s} trials={d} OS_caches_not_flushed=true\n", .{ executable, library, source_path, count });
    for (0..count) |iteration| {
        const log = try cwd.createFile(io, child_log, .{});
        defer log.close(io);
        const start = std.Io.Clock.awake.now(io);
        var child = try std.process.spawn(io, .{ .argv = &.{ executable, "run", source_path, "--libtypst", library, "--output", output }, .stdin = .ignore, .stdout = .ignore, .stderr = .{ .file = log }, .request_resource_usage_statistics = true });
        defer child.kill(io);
        const term = try child.wait(io);
        const finished = std.Io.Clock.awake.now(io);
        if (!term.success()) return error.CliFailed;
        std.debug.print("fresh_iteration={d} wall_ms={d:.3} peak_rss_bytes={?d} ", .{ iteration, metrics.milliseconds(start, finished), child.resource_usage_statistics.getMaxRss() });
        try verify(a, io, output, &expected);
    }
    try cwd.writeFile(io, .{ .sub_path = watched, .data = source });
    const log = try cwd.createFile(io, child_log, .{});
    defer log.close(io);
    const start = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{ .argv = &.{ executable, "watch", watched, "--json", "--libtypst", library, "--output", output }, .stdin = .ignore, .stdout = .pipe, .stderr = .{ .file = log } });
    defer child.kill(io);
    var buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{child.stdout.?});
    defer reader.deinit();
    var changed = start;
    for (0..count) |iteration| {
        if (iteration != 0) {
            const changed_source = try std.fmt.allocPrint(a, "{s}\n// watch measurement {d}\n", .{ source, iteration });
            changed = std.Io.Clock.awake.now(io);
            try cwd.writeFile(io, .{ .sub_path = watched, .data = changed_source });
        }
        if (!std.mem.eql(u8, (try next(&reader, a, io)).event, "build_start")) return error.InvalidWatchEvent;
        const result = try next(&reader, a, io);
        if (!std.mem.eql(u8, result.event, "success")) {
            std.debug.print("watch failure: {s}\n", .{result.message orelse result.event});
            return error.WatchFailed;
        }
        const finished = std.Io.Clock.awake.now(io);
        std.debug.print("watch_iteration={d} build_ms={d} change_to_success_ms={d:.3} ", .{ iteration, result.duration_ms.?, metrics.milliseconds(changed, finished) });
        try verify(a, io, output, &expected);
    }
    try std.posix.kill(child.id.?, .TERM);
    try reader.fillRemaining(.{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake }) });
    if (!(try child.wait(io)).success()) return error.WatchStopFailed;
}
