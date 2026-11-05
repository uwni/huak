//! Reproducible text-to-editable-path benchmark. This measures label layout
//! reuse, native outline extraction, host copies, traversal, and cleanup.
//! Scene construction and final SVG/PDF export are measured by bench-drawing.
const std = @import("std");
const metrics = @import("metrics");
const milliseconds = metrics.milliseconds;
const peakRssBytes = metrics.peakRssBytes;
const builtin = @import("builtin");
const typst = @import("libtypst");
const options = @import("host_options");
const outlines = @import("huak").text.outline;
const g = @import("huak").core.geometry;

const label_count = 64;
const batch_count = 100;
const sources = [_][]const u8{
    "#text(size: 18pt, fill: rgb(35, 75, 115))[Editable art: office café Ω]",
    "#text(size: 21pt, fill: rgb(35, 75, 115))[Editable art: office café Ω]",
    "#text(size: 24pt, fill: rgb(35, 75, 115))[Editable art: office café Ω]",
    "#text(size: 27pt, fill: rgb(35, 75, 115))[Editable art: office café Ω]",
};
const changed_source: []const u8 = "#text(size: 18pt, fill: rgb(35, 75, 115))[Editable art: office café Ω revised]";

const Consumption = struct {
    labels: usize = 0,
    items: usize = 0,
    segments: usize = 0,
    checksum: f64 = 0,

    fn add(self: *Consumption, other: Consumption) void {
        self.labels += other.labels;
        self.items += other.items;
        self.segments += other.segments;
        self.checksum += other.checksum;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        std.debug.print("usage: {s} [TYPST_LIBRARY]\n", .{args[0]});
        return error.InvalidArguments;
    }
    var requests: [label_count]typst.LayoutRequest = undefined;
    for (&requests, 0..) |*request, index| request.* = .{
        .source = sources[index % sources.len],
        .syntax = .markup,
        .region = null,
    };

    const started = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(if (args.len == 2) args[1] else options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const initialized = std.Io.Clock.awake.now(init.io);

    const cold_start = std.Io.Clock.awake.now(init.io);
    const cold = try run(init.gpa, &engine, &requests);
    const cold_done = std.Io.Clock.awake.now(init.io);

    const hot_start = std.Io.Clock.awake.now(init.io);
    const hot = try run(init.gpa, &engine, &requests);
    const hot_done = std.Io.Clock.awake.now(init.io);

    var bulk: Consumption = .{};
    const batch_start = std.Io.Clock.awake.now(init.io);
    for (0..batch_count) |_| bulk.add(try run(init.gpa, &engine, &requests));
    const batch_done = std.Io.Clock.awake.now(init.io);

    requests[0].source = changed_source;
    const incremental_start = std.Io.Clock.awake.now(init.io);
    const incremental = try run(init.gpa, &engine, &requests);
    const incremental_done = std.Io.Clock.awake.now(init.io);
    const batch_ms = milliseconds(batch_start, batch_done);
    std.debug.print(
        "huak editable text paths / Zig {s} / {s}-{s} / {s} / libtypst ABI {d}.{d}\n" ++
            "scope=label layout + native outlines + huak-owned Path copies + full geometry traversal + cleanup\n" ++
            "scene submission and SVG/PDF export are excluded; peak RSS covers the complete process and resident Typst caches\n" ++
            "labels_per_batch={d}\ndistinct_initial_label_requests=4\n" ++
            "load_engine_init_ms={d:.3}\ncold_workflow_ms={d:.3}\nhot_workflow_ms={d:.3}\n" ++
            "batch_count={d}\nbatch_ms={d:.3}\nbatches_per_second={d:.2}\nlabels_per_second={d:.2}\n" ++
            "incremental_one_label_changed_ms={d:.3}\n",
        .{
            builtin.zig_version_string,              @tagName(builtin.os.tag),                              @tagName(builtin.cpu.arch),                        @tagName(builtin.mode),            library.version >> 16, library.version & 0xffff,
            label_count,                             milliseconds(started, initialized),                    milliseconds(cold_start, cold_done),               milliseconds(hot_start, hot_done), batch_count,           batch_ms,
            @as(f64, batch_count) * 1000 / batch_ms, @as(f64, batch_count * label_count) * 1000 / batch_ms, milliseconds(incremental_start, incremental_done),
        },
    );
    std.debug.print(
        "cold_items={d}\ncold_segments={d}\nincremental_items={d}\nincremental_segments={d}\n" ++
            "batch_consumed_labels={d}\nbatch_consumed_items={d}\nbatch_consumed_segments={d}\n" ++
            "cold_checksum={d:.6}\nhot_checksum={d:.6}\nbatch_checksum={d:.6}\nincremental_checksum={d:.6}\n",
        .{ cold.items, cold.segments, incremental.items, incremental.segments, bulk.labels, bulk.items, bulk.segments, cold.checksum, hot.checksum, bulk.checksum, incremental.checksum },
    );
    std.debug.print("peak_rss_bytes={d}\n", .{peakRssBytes()});
    if (cold.items == 0 or cold.segments == 0 or cold.checksum != hot.checksum or !std.math.isFinite(bulk.checksum)) return error.InvalidBenchmarkResult;
}

fn run(allocator: std.mem.Allocator, engine: *typst.Engine, requests: []const typst.LayoutRequest) !Consumption {
    var measured: [label_count]typst.Metrics = undefined;
    var labels = engine.layoutContent(requests, measured[0..requests.len], null) catch |err| {
        diagnostic(engine.library);
        return err;
    };
    defer labels.deinit();
    var batch = outlines.extract(allocator, &labels) catch |err| {
        diagnostic(engine.library);
        return err;
    };
    defer batch.deinit();
    var result: Consumption = .{ .labels = batch.labels.len };
    for (batch.labels) |label| {
        result.checksum += label.metrics.width + label.metrics.height + label.metrics.baseline;
        result.items += label.parts.len;
        for (label.parts) |part| {
            result.segments += part.path.segments.items.len;
            result.checksum += part.advance.x + part.advance.y + part.transform.e + part.transform.f;
            result.checksum += @as(f64, @floatFromInt(part.cluster_start + part.cluster_end + part.run_text.len));
            for (part.path.segments.items) |segment| switch (segment) {
                .move => |p| result.checksum += sum(p),
                .line => |p| result.checksum += sum(p),
                .cubic => |curve| result.checksum += sum(curve.c1) + sum(curve.c2) + sum(curve.end),
                .close => result.checksum += 1,
            };
        }
    }
    return result;
}

fn sum(point: g.Point) f64 {
    return point.x + point.y * 0.75;
}
fn diagnostic(library: *typst.Library) void {
    var message = library.lastError() catch return;
    defer message.deinit();
    std.debug.print("libtypst outlines: {s}\n", .{message.bytes()});
}
