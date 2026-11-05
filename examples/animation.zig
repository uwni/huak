//! Export one typeset scene as continuous SVG animation.
const std = @import("std");
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
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [scene.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&scene.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var prepared = try scene.Prepared.init(init.gpa, &measured);
    defer prepared.deinit();
    var picture = try scene.buildBase(init.gpa, &measured);
    defer picture.deinit();
    const ids = try picture.objectIds(init.gpa);
    defer init.gpa.free(ids);
    var document = try backend.submit(init.gpa, &library, &picture.picture, scene.width, scene.height, .{ .frames = &frames, .object_ids = ids });
    defer document.deinit();
    var static_svg = try document.exportSvg(0);
    defer static_svg.deinit();
    const tracks = prepared.tracks();
    const animation: a.Animation = .{ .duration_seconds = scene.duration, .tracks = &tracks };
    const output = try native_svg.encodeAnimatedSvg(init.gpa, static_svg.bytes(), &animation);
    defer init.gpa.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });
    std.debug.print("wrote {s} ({d} bytes, {d} tracks)\n", .{ output_path, output.len, tracks.len });
}
