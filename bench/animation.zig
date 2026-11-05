//! Measure continuous SVG export, hot encoding and incremental track changes.
const std = @import("std");
const metrics = @import("metrics");
const milliseconds = metrics.milliseconds;
const peakRssBytes = metrics.peakRssBytes;
const builtin = @import("builtin");
const typst = @import("libtypst");
const options = @import("host_options");
const huak = @import("huak");
const a = huak.animation;
const native_svg = huak.svg.animation;
const backend = huak.backend;
const scene = @import("animation_scene");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const first: usize = 1;
    const count = args.len - first;
    if (count != 0 and count != 2) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const library_path = if (count == 2) args[first] else options.library_path;
    const output_path = if (count == 2) args[first + 1] else "target/huak-animation.svg";
    if (!std.mem.endsWith(u8, output_path, ".svg")) return error.InvalidOutputFormat;
    const started = std.Io.Clock.awake.now(init.io);
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const initialized = std.Io.Clock.awake.now(init.io);
    var measured: [scene.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&scene.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    const measured_at = std.Io.Clock.awake.now(init.io);
    var prepared = try scene.Prepared.init(init.gpa, &measured);
    defer prepared.deinit();
    var picture = try scene.buildBase(init.gpa, &measured);
    defer picture.deinit();
    const ids = try picture.objectIds(init.gpa);
    defer init.gpa.free(ids);
    const geometry_at = std.Io.Clock.awake.now(init.io);
    var document = try backend.submit(init.gpa, &library, &picture.picture, scene.width, scene.height, .{ .frames = &frames, .object_ids = ids });
    defer document.deinit();
    var static_svg = try document.exportSvg(0);
    defer static_svg.deinit();
    const exported_at = std.Io.Clock.awake.now(init.io);
    const tracks = prepared.tracks();
    const animation: a.Animation = .{ .duration_seconds = scene.duration, .tracks = &tracks };
    const output = try native_svg.encodeAnimatedSvg(init.gpa, static_svg.bytes(), &animation);
    defer init.gpa.free(output);
    const animated_at = std.Io.Clock.awake.now(init.io);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
    std.debug.print(
        "huak continuous SVG / Zig {s} / {s}-{s} / {s} / libtypst ABI {d}.{d}\n" ++
            "duration_seconds={d}\ntracks={d}\npath_key_states={d}\ngeometry_evaluations={d}\nmax_checked_control_error_pt={d:.6}\n" ++
            "static_svg_bytes={d}\nanimated_svg_bytes={d}\noutput={s}\n" ++
            "load_engine_init_ms={d:.3}\nfixed_label_layout_ms={d:.3}\nadaptive_geometry_scene_ms={d:.3}\n" ++
            "one_scene_submit_svg_ms={d:.3}\nanimation_encode_ms={d:.3}\n" ++
            "peak_rss_bytes={d}\n",
        .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), library.version >> 16, library.version & 0xffff, scene.duration, tracks.len, prepared.samples.keys.len, prepared.samples.evaluations, prepared.samples.max_accepted_error, static_svg.bytes().len, output.len, output_path, milliseconds(started, initialized), milliseconds(initialized, measured_at), milliseconds(measured_at, geometry_at), milliseconds(geometry_at, exported_at), milliseconds(exported_at, animated_at), peakRssBytes() },
    );
    try benchmarks(init, &prepared, &animation, static_svg.bytes());
}

fn benchmarks(init: std.process.Init, prepared: *const scene.Prepared, animation: *const a.Animation, static_svg: []const u8) !void {
    const trials: usize = 100;
    const started = std.Io.Clock.awake.now(init.io);
    var consumed: usize = 0;
    for (0..trials) |_| {
        const bytes = try native_svg.encodeAnimatedSvg(init.gpa, static_svg, animation);
        consumed +%= bytes.len;
        init.gpa.free(bytes);
    }
    const packaged = std.Io.Clock.awake.now(init.io);
    // A changed animation parameter reuses the same static SVG and text.
    var changed_tracks = prepared.tracks();
    changed_tracks[4].property.scale = &.{ .{ .time = 0, .value = .{ .x = 1, .y = 1 } }, .{ .time = 1, .value = .{ .x = 2, .y = 2 } } };
    const changed = try native_svg.encodeAnimatedSvg(init.gpa, static_svg, &.{ .duration_seconds = scene.duration, .tracks = &changed_tracks });
    init.gpa.free(changed);
    const incremental = std.Io.Clock.awake.now(init.io);
    std.debug.print("hot_encode_count={d}\nhot_encode_total_ms={d:.3}\nhot_encode_average_ms={d:.3}\nconsumed_output_bytes={d}\nincremental_track_encode_ms={d:.3}\nbenchmark_peak_rss_bytes={d}\n", .{ trials, milliseconds(started, packaged), milliseconds(started, packaged) / trials, consumed, milliseconds(packaged, incremental), peakRssBytes() });
}
