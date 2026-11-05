//! Cold, hot, bulk and incremental native drawing benchmark.
const std = @import("std");
const metrics = @import("metrics");
const milliseconds = metrics.milliseconds;
const peakRssBytes = metrics.peakRssBytes;
const typst = @import("libtypst");
const workflow = @import("drawing_workflow");
const options = @import("host_options");

const OutputFormat = workflow.OutputFormat;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1 and args.len != 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg|OUTPUT.pdf]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const library_path = if (args.len == 3) args[1] else options.library_path;
    const output_path = if (args.len == 3) args[2] else "target/huak-benchmark.svg";
    const format: OutputFormat = if (std.mem.endsWith(u8, output_path, ".svg")) .svg else if (std.mem.endsWith(u8, output_path, ".pdf")) .pdf else {
        std.debug.print("unsupported output path '{s}': use a .svg or .pdf extension\n", .{output_path});
        return error.InvalidOutputFormat;
    };
    const format_label = switch (format) {
        .svg => "SVG",
        .pdf => "PDF",
    };
    const start = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const initialized = std.Io.Clock.awake.now(init.io);
    var first_output = workflow.render(allocator, &engine, 0, format) catch |err| {
        var diagnostic = try library.lastError();
        defer diagnostic.deinit();
        std.debug.print("libtypst: {s}\n", .{diagnostic.bytes()});
        return err;
    };
    defer first_output.deinit();
    const cold_done = std.Io.Clock.awake.now(init.io);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = first_output.bytes() });
    const hot_start = std.Io.Clock.awake.now(init.io);
    var hot = try workflow.render(allocator, &engine, 0, format);
    hot.deinit();
    const hot_done = std.Io.Clock.awake.now(init.io);
    const batch_count: usize = 100;
    for (0..batch_count) |_| {
        var output = try workflow.render(allocator, &engine, 0, format);
        output.deinit();
    }
    const batch_done = std.Io.Clock.awake.now(init.io);
    var changed = try workflow.render(allocator, &engine, 12, format);
    changed.deinit();
    const incremental_done = std.Io.Clock.awake.now(init.io);
    const batch_ms = milliseconds(hot_done, batch_done);
    std.debug.print(
        "huak native scene / libtypst ABI {d}.{d}: {d} {s} bytes at {s}\n" ++
            "timings include label layout, geometry, scene submission and {s} export; file writing is excluded\n" ++
            "load+engine_init_ms={d:.3}\ncold_measure_geometry_submit_export_ms={d:.3}\n" ++
            "hot_measure_geometry_submit_export_ms={d:.3}\nbatch_count={d}\nbatch_ms={d:.3}\n" ++
            "batch_per_second={d:.2}\nincremental_geometry_submit_export_ms={d:.3}\n" ++
            "peak_rss_bytes={d}\n",
        .{ library.version >> 16, library.version & 0xffff, first_output.bytes().len, format_label, output_path, format_label, milliseconds(start, initialized), milliseconds(initialized, cold_done), milliseconds(hot_start, hot_done), batch_count, batch_ms, @as(f64, @floatFromInt(batch_count)) * 1000 / batch_ms, milliseconds(batch_done, incremental_done), peakRssBytes() },
    );
}
