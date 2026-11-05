//! Cold, hot, bulk and incremental Typst typesetting benchmark.
const std = @import("std");
const metrics = @import("metrics");
const milliseconds = metrics.milliseconds;
const peakRssBytes = metrics.peakRssBytes;
const typst = @import("libtypst");
const sample = @import("typst_sample");
const options = @import("host_options");
const workflow = @import("typst_workflow");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1 and args.len != 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const library_path = if (args.len == 3) args[1] else options.library_path;
    const output_path = if (args.len == 3) args[2] else "target/typst-benchmark.svg";
    const start = std.Io.Clock.awake.now(init.io);
    var library = typst.Library.open(library_path) catch |err| {
        std.debug.print("Cannot load libtypst: {s}\n", .{@errorName(err)});
        return err;
    };
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const initialized = std.Io.Clock.awake.now(init.io);

    var first_svg = try workflow.render(&engine, sample.source);
    defer first_svg.deinit();
    const cold_done = std.Io.Clock.awake.now(init.io);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = first_svg.bytes() });

    const hot_start = std.Io.Clock.awake.now(init.io);
    var hot_svg = try workflow.render(&engine, sample.source);
    hot_svg.deinit();
    const hot_done = std.Io.Clock.awake.now(init.io);

    const batch_count: usize = 100;
    const batch_start = std.Io.Clock.awake.now(init.io);
    for (0..batch_count) |_| {
        var svg = try workflow.render(&engine, sample.source);
        svg.deinit();
    }
    const batch_done = std.Io.Clock.awake.now(init.io);
    var changed_svg = try workflow.render(&engine, sample.modified_source);
    changed_svg.deinit();
    const incremental_done = std.Io.Clock.awake.now(init.io);
    const batch_ms = milliseconds(batch_start, batch_done);

    std.debug.print(
        "libtypst ABI {d}.{d}: generated {d} SVG bytes at {s}\n" ++
            "load+engine_init_ms={d:.3}\ncold_compile_export_ms={d:.3}\n" ++
            "hot_compile_export_ms={d:.3}\nbatch_count={d}\nbatch_ms={d:.3}\n" ++
            "batch_per_second={d:.2}\nincremental_compile_export_ms={d:.3}\n" ++
            "peak_rss_bytes={d}\n",
        .{
            library.version >> 16,
            library.version & 0xffff,
            first_svg.bytes().len,
            output_path,
            milliseconds(start, initialized),
            milliseconds(initialized, cold_done),
            milliseconds(hot_start, hot_done),
            batch_count,
            batch_ms,
            @as(f64, @floatFromInt(batch_count)) * 1000.0 / batch_ms,
            milliseconds(batch_done, incremental_done),
            peakRssBytes(),
        },
    );
}
