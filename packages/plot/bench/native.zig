//! One fresh process per sample; compilation, construction, export and RSS
//! are separate. Run from the repository root with zig build bench-plot.
const std = @import("std");
const huak = @import("huak");
const typst = @import("libtypst");
const metrics = @import("metrics");
const options = @import("host_options");
const l = huak.language;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 5) return sample(init, args[1], args[2], args[3], args[4]);
    if (args.len > 2) return error.InvalidArguments;
    const library = if (args.len == 2) args[1] else options.library_path;
    var log: std.ArrayList(u8) = .empty;
    for ([_]struct { kind: []const u8, count: []const u8, batch: []const u8 = "1" }{
        .{ .kind = "lines", .count = "1000" },    .{ .kind = "lines", .count = "10000" },               .{ .kind = "lines", .count = "100000" },
        .{ .kind = "scatter", .count = "1000" },  .{ .kind = "scatter", .count = "10000" },             .{ .kind = "scatter", .count = "100000" },
        .{ .kind = "heatmap", .count = "10000" }, .{ .kind = "lines", .count = "100", .batch = "100" },
    }) |case| {
        for (0..3) |_| {
            const result = try std.process.run(a, init.io, .{ .argv = &.{ args[0], library, case.kind, case.count, case.batch }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
            if (result.term != .exited or result.term.exited != 0) {
                std.debug.print("{s} {s}: {s}\n", .{ case.kind, case.count, result.stderr });
                return error.BenchmarkFailed;
            }
            try log.appendSlice(a, result.stdout);
            try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
        }
    }
    try std.Io.Dir.cwd().createDirPath(init.io, "packages/plot/target");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "packages/plot/target/benchmark.jsonl", .data = log.items });
}

fn sample(init: std.process.Init, library_path: []const u8, kind: []const u8, count: []const u8, batch: []const u8) !void {
    const a = std.heap.smp_allocator;
    const io = init.io;
    const start = std.Io.Clock.awake.now(io);
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    const loaded = std.Io.Clock.awake.now(io);
    const frontend: huak.tooling.Frontend = .{ .allocator = a, .io = io, .source_parser = .init(&library) };
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, "packages/plot/bench/workload.huak", a);
    defer a.free(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(source);
    var diagnostic: ?l.compiler.Diagnostic = null;
    var program = frontend.compile(source, path, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
        return err;
    };
    defer program.deinit();
    const compiled = std.Io.Clock.awake.now(io);
    var outputs = blk: {
        var runtime = try l.Runtime.init(a, a, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(a, &program, runtime.host(), .{});
        defer machine.deinit();
        _ = machine.execute(&.{ .{ .name = "kind", .value = kind }, .{ .name = "count", .value = count }, .{ .name = "batch", .value = batch } }) catch |err| {
            if (machine.failure) |failure| std.debug.print("{s}: {s}\n", .{ failure.text(), failure.native_message });
            return err;
        };
        break :blk try runtime.takeOutputs(machine.getGlobal("plots").?.list.items());
    };
    defer outputs.deinit();
    const constructed = std.Io.Clock.awake.now(io);
    var bytes: usize = 0;
    var hash: std.crypto.hash.Blake3 = .init(.{});
    for (0..outputs.entries.len) |i| {
        var detail: ?typst.Buffer = null;
        defer if (detail) |*message| message.deinit();
        var output = try outputs.render(a, i, .svg, &detail);
        defer output.deinit();
        bytes += output.bytes().len;
        hash.update(output.bytes());
    }
    const exported = std.Io.Clock.awake.now(io);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .kind = kind,
        .count = try std.fmt.parseInt(usize, count, 10),
        .batch = try std.fmt.parseInt(usize, batch, 10),
        .load_ms = metrics.milliseconds(start, loaded),
        .compile_ms = metrics.milliseconds(loaded, compiled),
        .construct_ms = metrics.milliseconds(compiled, constructed),
        .export_ms = metrics.milliseconds(constructed, exported),
        .peak_rss_bytes = metrics.peakRssBytes(),
        .svg_bytes = bytes,
        .blake3 = std.fmt.bytesToHex(digest, .lower),
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(io, json);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
