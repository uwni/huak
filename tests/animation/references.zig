//! Generate native static reference scenes for browser animation verification.
const std = @import("std");
const typst = @import("libtypst");
const options = @import("host_options");
const huak = @import("huak");
const a = huak.animation;
const native_svg = huak.svg.animation;
const backend = huak.backend;
const scene = @import("animation_scene");

const marker_id = scene.marker_id;
const duration = scene.duration;
const verification_times = [_]f64{ 0, 0.017, 0.137, 0.333, 0.777, 1.234, 1.9375, 2 };
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
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [scene.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&scene.requests, &measured, null);
    defer labels.deinit();
    var references: [measured.len]typst.FrameRef = undefined;
    for (&references, 0..) |*frame, index| frame.* = try labels.frame(index);
    var prepared = try scene.Prepared.init(init.gpa, &measured);
    defer prepared.deinit();
    var picture = try scene.buildBase(init.gpa, &measured);
    defer picture.deinit();
    const ids = try picture.objectIds(init.gpa);
    defer init.gpa.free(ids);
    var document = try backend.submit(init.gpa, &library, &picture.picture, scene.width, scene.height, .{ .frames = &references, .object_ids = ids });
    defer document.deinit();
    var static_svg = try document.exportSvg(0);
    defer static_svg.deinit();
    const tracks = prepared.tracks();
    // CSS is the default; a copy with every track marked smil lets browsers
    // compare both.
    for ([_]bool{ false, true }) |smil| {
        var marked_tracks = tracks;
        for (&marked_tracks) |*track| track.smil = smil;
        const output = try native_svg.encodeAnimatedSvg(init.gpa, static_svg.bytes(), &.{ .duration_seconds = scene.duration, .tracks = &marked_tracks });
        defer init.gpa.free(output);
        const path = if (smil) try std.fmt.allocPrint(init.arena.allocator(), "{s}-smil.svg", .{output_path[0 .. output_path.len - ".svg".len]}) else output_path;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = output });
    }
    try writeReferences(init, &library, &references, &measured, &prepared, ids);
    try writePropertyFixture(init, static_svg.bytes());
}
fn writePropertyFixture(init: std.process.Init, static_svg: []const u8) !void {
    const fixture_tracks = [_]a.Track{
        .{ .target = marker_id, .property = .{ .translate = &.{ .{ .time = 0, .value = .{ .x = 100, .y = 100 } }, .{ .time = 1, .value = .{ .x = 200, .y = 200 } } } }, .easing = .{ .spline = .{ .x1 = 0.42, .y1 = 0, .x2 = 0.58, .y2 = 1 } } },
        .{ .target = marker_id, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } },
        .{ .target = marker_id, .property = .{ .scale = &.{ .{ .time = 0, .value = .{ .x = 1, .y = 2 } }, .{ .time = 1, .value = .{ .x = 2, .y = 1 } } } } },
        .{ .target = marker_id, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0.25 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = marker_id, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 5 } } } },
        .{ .target = marker_id, .property = .{ .stroke = &.{ .{ .time = 0, .value = .{ .r = 0, .g = 0, .b = 1, .a = 0.4 } }, .{ .time = 1, .value = .{ .r = 1, .g = 0, .b = 0 } } } } },
    };
    for ([_]bool{ false, true }) |smil| {
        var marked_tracks = fixture_tracks;
        for (&marked_tracks) |*track| track.smil = smil;
        const output = try native_svg.encodeAnimatedSvg(init.gpa, static_svg, &.{ .duration_seconds = duration, .repeat = false, .tracks = &marked_tracks });
        defer init.gpa.free(output);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = if (smil) "target/animation-properties-smil.svg" else "target/animation-properties.svg", .data = output });
    }
}

fn writeReferences(init: std.process.Init, library: *typst.Library, references: []const typst.FrameRef, measured: []const typst.Metrics, prepared: *const scene.Prepared, ids: []const u64) !void {
    for (verification_times, 0..) |time, index| {
        var picture = try scene.pictureAt(init.gpa, measured, prepared, time / duration);
        defer picture.deinit();
        var document = try backend.submit(init.gpa, library, &picture.picture, scene.width, scene.height, .{ .frames = references, .object_ids = ids });
        defer document.deinit();
        var svg = try document.exportSvg(0);
        defer svg.deinit();
        var scratch: [96]u8 = undefined;
        const filename = try std.fmt.bufPrint(&scratch, "target/animation-reference-{d}.svg", .{index});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = filename, .data = svg.bytes() });
    }
    const metadata = try std.json.Stringify.valueAlloc(init.gpa, .{ .duration = duration, .times = verification_times }, .{});
    defer init.gpa.free(metadata);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "target/animation-reference-times.json", .data = metadata });
}
