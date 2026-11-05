//! End-to-end geometry only: continuous stroke construction and Boolean trim.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("huak").core;
const Motion = core.pen.Motion;

// Hash commands and coordinates separately so union padding never enters
// comparisons between builds on the same target.
fn pathHash(path: core.Path) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (path.segments.items) |segment| {
        hash.update(&.{@backingInt(segment)});
        switch (segment) {
            .move, .line => |p| hash.update(std.mem.asBytes(&p)),
            .cubic => |c| inline for (.{ c.c1, c.c2, c.end }) |p| hash.update(std.mem.asBytes(&p)),
            .close => {},
        }
    }
    return hash.final();
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var path = core.Path.init(a);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.cubicTo(.{ .x = 30, .y = 40 }, .{ .x = 70, .y = -35 }, .{ .x = 100, .y = 0 });
    const scale: Motion = .{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 3 }}, .keys = &.{ .{ .t = 0, .value = 2 }, .{ .t = 0.4, .value = 12 }, .{ .t = 1, .value = 1 } } };
    const twist: Motion = .{ .tracks = &.{ .{ .kind = .scale_x, .first = 0, .len = 3, .polynomial = true }, .{ .kind = .rotate, .first = 3, .len = 2 } }, .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 1 }, .{ .t = 1, .value = 2 }, .{ .t = 0, .value = 0 }, .{ .t = 1, .value = 2.2 } } };
    std.debug.print("Zig {s} {s}, median of 5, cubic centerline 100pt\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
    var chisel = try core.pen.Nib.square().transformed(a, core.geometry.Transform.scaling(7, 3));
    defer chisel.deinit();
    for ([_]struct { name: []const u8, pen: core.DisplayList.Pen }{ .{ .name = "pressure", .pen = .{ .motion = &scale } }, .{ .name = "scale+turn", .pen = .{ .motion = &twist, .nib = chisel.nib } } }) |spec| {
        for ([_]f64{ 0.02, 0.001 }) |tol| {
            var times: [5]i64 = undefined;
            var hash: u64 = 0;
            var count: usize = 0;
            for (&times, 0..) |*time, i| {
                const before = std.Io.Clock.awake.now(init.io);
                var out = try core.pen.motionOutline(a, path, &spec.pen, .{ .tolerance = tol });
                defer out.deinit();
                count = out.segments.items.len;
                time.* = @intCast(before.durationTo(std.Io.Clock.awake.now(init.io)).toMicroseconds());
                if (i + 1 == times.len) hash = pathHash(out);
            }
            std.mem.sort(i64, &times, {}, std.sort.asc(i64));
            std.debug.print("{s} tolerance={d}pt median={d}us segments={d} hash={x}\n", .{ spec.name, tol, times[2], count, hash });
        }
    }
}
