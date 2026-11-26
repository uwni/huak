//! End-to-end 3D projection, smooth lighting, color-patch and Type 7/SVG mesh
//! benchmark. Every sample runs a fresh huak CLI process on committed fixtures,
//! reporting median wall time, peak RSS, output size and SHA-256.
const std = @import("std");

const Case = struct {
    name: []const u8,
    script: []const u8,
    extra_args: []const []const u8 = &.{},
    ext: []const u8,
};

const cases = [_]Case{
    .{ .name = "torus-flat-pdf", .script = "tests/space_shading/painter.huak", .extra_args = &.{ "--param", "translucent=false", "--param", "colored=false" }, .ext = "pdf" },
    .{ .name = "torus-trans-pdf", .script = "tests/space_shading/painter.huak", .extra_args = &.{ "--param", "translucent=true", "--param", "colored=false" }, .ext = "pdf" },
    .{ .name = "torus-col-flat-pdf", .script = "tests/space_shading/painter.huak", .extra_args = &.{ "--param", "translucent=false", "--param", "colored=true" }, .ext = "pdf" },
    .{ .name = "torus-flat-svg", .script = "tests/space_shading/painter.huak", .extra_args = &.{ "--param", "translucent=false", "--param", "colored=false" }, .ext = "svg" },
    .{ .name = "fields-pdf", .script = "tests/fixtures/space/fields.huak", .ext = "pdf" },
    .{ .name = "smooth-pdf", .script = "tests/fixtures/space/smooth.huak", .ext = "pdf" },
    .{ .name = "highlight-pdf", .script = "examples/space/highlight.huak", .ext = "pdf" },
};

const Sample = struct { ms: f64, rss: usize, size: usize, digest: [32]u8 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2 or args.len > 3) {
        std.debug.print("usage: {s} HUAK_EXECUTABLE [ROUNDS=3]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();
    const binary = try cwd.realPathFileAlloc(io, args[1], a);
    const rounds: usize = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 3;
    if (rounds == 0) return error.InvalidRounds;

    try cwd.createDirPath(io, "target/bench-space");
    var log = try cwd.createFile(io, "target/bench-space/child.log", .{});
    defer log.close(io);

    std.debug.print("{s:<20} {s:>9} {s:>10} {s:>10} {s}\n", .{ "case", "med_ms", "rss_mib", "bytes", "sha256" });
    for (cases) |case| {
        const out_path = try std.fmt.allocPrint(a, "target/bench-space/{s}.{s}", .{ case.name, case.ext });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ binary, "run", case.script });
        try argv.appendSlice(a, case.extra_args);
        try argv.append(a, try std.fmt.allocPrint(a, "--output={s}", .{out_path}));

        // One untimed warmup, then `rounds` timed samples.
        _ = try runOnce(init.gpa, io, log, argv.items, out_path);
        const times = try a.alloc(f64, rounds);
        var max_rss: usize = 0;
        var out_size: usize = 0;
        var digest: [32]u8 = undefined;
        for (0..rounds) |r| {
            const sample = try runOnce(init.gpa, io, log, argv.items, out_path);
            times[r] = sample.ms;
            max_rss = @max(max_rss, sample.rss);
            out_size = sample.size;
            digest = sample.digest;
        }
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        const med = times[rounds / 2];
        const rss_mib = @as(f64, @floatFromInt(max_rss)) / (1024.0 * 1024.0);
        const hex = std.fmt.bytesToHex(digest[0..6], .lower);
        std.debug.print("{s:<20} {d:>9.1} {d:>10.1} {d:>10} {s}\n", .{ case.name, med, rss_mib, out_size, &hex });
    }
}

fn runOnce(gpa: std.mem.Allocator, io: std.Io, log: std.Io.File, argv: []const []const u8, out_path: []const u8) !Sample {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, out_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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
    if (!term.success()) return error.ChildFailed;
    const bytes = try cwd.readFileAlloc(io, out_path, gpa, .limited(256 * 1024 * 1024));
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .ms = @as(f64, @floatFromInt(start.durationTo(stop).toNanoseconds())) / 1_000_000.0,
        .rss = child.resource_usage_statistics.getMaxRss() orelse 0,
        .size = bytes.len,
        .digest = digest,
    };
}
