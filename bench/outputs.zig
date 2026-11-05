//! End-to-end multi-output CLI benchmark. Every sample starts a new huak
//! process; compilation, script execution, native export and file I/O are timed.
const std = @import("std");
const builtin = @import("builtin");

const trials = 4;
const job_counts = [_]usize{ 1, 4 };
const Sample = struct { wall_ms: f64, peak_rss: ?usize };
const Digest = [std.crypto.hash.Blake3.digest_length]u8;

const source =
    \\import math.{sin, cos}
    \\import paint.{picture, pen, rgb, draw, label}
    \\setup_typst {
    \\ set text(size: 14pt)
    \\}
    \\title := typ[Huak batch $sum_(i=1)^n i^2$ Ω]
    \\fn figure(index: int) -> picture
    \\ pic := picture(320, 200)
    \\ ink := pen(rgb(0.16, 0.38, 0.75), 0.4)
    \\ for stroke in 0:159 do
    \\  y := 10 + stroke * 1.0
    \\  phase := (stroke + index) * 0.17
    \\  curve := (10, y) ~~ (100, y + 12 * sin(phase)) ~~ (210, y - 10 * cos(phase)) ~~ (310, y)
    \\  object.append(pic, object.draw(curve, ink))
    \\ end
    \\ object.append(pic, object.label(title, (12, 180)))
    \\ return pic
    \\end
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3 or args.len > 4) {
        std.debug.print("usage: {s} HUAK_EXECUTABLE TYPST_LIBRARY [PICTURES=64]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], allocator);
    const library = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], allocator);
    const count = if (args.len == 4) try std.fmt.parseInt(usize, args[3], 10) else 64;
    if (count == 0 or count > 512) return error.InvalidPictureCount;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, "target/bench-outputs");
    var parent = try cwd.openDir(init.io, "target/bench-outputs", .{});
    defer parent.close(init.io);
    const name = try privateDirectory(allocator, init.io, parent);
    defer parent.deleteTree(init.io, name) catch |err|
        std.debug.print("cannot remove benchmark directory '{s}': {s}\n", .{ name, @errorName(err) });
    var work = try parent.openDir(init.io, name, .{});
    defer work.close(init.io);

    var script: std.Io.Writer.Allocating = .init(init.gpa);
    defer script.deinit();
    try script.writer.writeAll(source);
    for (0..count) |index| try script.writer.print("export fig_{d} := figure({d})\n", .{ index, index });
    try work.writeFile(init.io, .{ .sub_path = "batch.huak", .data = script.written() });

    const output_names = try allocator.alloc([]const u8, count);
    const output_args = try allocator.alloc([]const u8, count);
    for (output_names, output_args, 0..) |*output_name, *output_arg, index| {
        output_name.* = try std.fmt.allocPrint(allocator, "figure-{d}.svg", .{index});
        output_arg.* = try std.fmt.allocPrint(allocator, "--output=fig_{d}={s}", .{ index, output_name.* });
    }
    const argv = try allocator.alloc([]const u8, 6 + count);
    @memcpy(argv[0..5], &[_][]const u8{ executable, "run", "batch.huak", "--libtypst", library });
    @memcpy(argv[6..], output_args);
    const reference = try allocator.alloc(Digest, count);
    var samples: [job_counts.len][trials]Sample = undefined;
    var output_bytes: u64 = 0;
    std.debug.print(
        "multi-output CLI / Zig {s} / {s}-{s} / driver={s}\n" ++
            "pictures={d} curves_per_picture=160 trials_per_jobs={d}\n" ++
            "timing=process startup + compile + script + native render + file writes\n" ++
            "each sample is a fresh process; OS filesystem caches are not cleared\n",
        .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), count, trials },
    );

    // Reversing each trial gives both settings equal opportunities to run first.
    for (0..trials) |trial| for (0..job_counts.len) |order| {
        const setting = if (trial % 2 == 0) order else job_counts.len - 1 - order;
        const jobs = job_counts[setting];
        argv[5] = if (jobs == 1) "--jobs=1" else "--jobs=4";
        const sample = try measure(init.io, work, argv);
        samples[setting][trial] = sample;
        std.debug.print("trial={d} order={d} jobs={d} wall_ms={d:.3} peak_rss_bytes={?d}\n", .{ trial + 1, order + 1, jobs, sample.wall_ms, sample.peak_rss });
        for (output_names, reference) |output_name, *expected| {
            const bytes = try work.readFileAlloc(init.io, output_name, init.gpa, .limited(64 * 1024 * 1024));
            defer init.gpa.free(bytes);
            if (!std.mem.containsAtLeast(u8, bytes, 1, "<svg")) return error.InvalidSvgOutput;
            var digest: Digest = undefined;
            std.crypto.hash.Blake3.hash(bytes, &digest, .{});
            if (trial == 0 and order == 0) {
                expected.* = digest;
                output_bytes += bytes.len;
            } else if (!std.mem.eql(u8, expected, &digest)) {
                std.debug.print("output changed: jobs={d} file={s}\n", .{ jobs, output_name });
                return error.NonDeterministicOutput;
            }
            try work.deleteFile(init.io, output_name);
        }
    };

    for (job_counts, samples) |jobs, batch| {
        var times: [trials]f64 = undefined;
        var rss: [trials]usize = undefined;
        var rss_available = true;
        for (batch, 0..) |sample, index| {
            times[index] = sample.wall_ms;
            rss[index] = sample.peak_rss orelse missing: {
                rss_available = false;
                break :missing 0;
            };
        }
        std.mem.sort(f64, &times, {}, std.sort.asc(f64));
        std.mem.sort(usize, &rss, {}, std.sort.asc(usize));
        const median_ms = (times[trials / 2 - 1] + times[trials / 2]) / 2;
        const median_rss: ?usize = if (rss_available) rss[trials / 2 - 1] + (rss[trials / 2] - rss[trials / 2 - 1]) / 2 else null;
        std.debug.print("jobs={d} median_ms={d:.3} median_peak_rss_bytes={?d}\n", .{ jobs, median_ms, median_rss });
    }
    std.debug.print("all_output_hashes_equal=true total_svg_bytes={d}\n", .{output_bytes});
}

fn measure(io: std.Io, work: std.Io.Dir, argv: []const []const u8) !Sample {
    const log = try work.createFile(io, "child.log", .{});
    defer log.close(io);
    const start = std.Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = work },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .request_resource_usage_statistics = true,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    const end = std.Io.Clock.awake.now(io);
    if (!term.success()) {
        const diagnostic = try work.readFileAlloc(io, "child.log", std.heap.page_allocator, .limited(1024 * 1024));
        defer std.heap.page_allocator.free(diagnostic);
        std.debug.print("huak failed: {f}\n{s}\n", .{ term, diagnostic });
        return error.ChildFailed;
    }
    return .{
        .wall_ms = @as(f64, @floatFromInt(start.durationTo(end).toNanoseconds())) / 1_000_000,
        .peak_rss = child.resource_usage_statistics.getMaxRss(),
    };
}

fn privateDirectory(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir) ![]const u8 {
    for (0..8) |_| {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const name = try std.fmt.allocPrint(allocator, "run-{s}", .{std.fmt.bytesToHex(random, .lower)});
        parent.createDir(io, name, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return name;
    }
    return error.TemporaryDirectoryCollision;
}
