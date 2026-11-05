//! Same-source construction benchmark; run before/after an implementation change.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("huak").core;
const g = core.geometry;
const pens = core.pen;
const trials = 7;
const repeats = 40;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var curve = core.Path.init(allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 10, .y = 55 }, .{ .x = 70, .y = -30 }, .{ .x = 100, .y = 10 });
    try curve.cubicTo(.{ .x = 125, .y = 65 }, .{ .x = 155, .y = -40 }, .{ .x = 200, .y = 0 });
    var rectangle = try pens.Nib.square().transformed(allocator, g.Transform.scaling(8, 3).then(g.Transform.rotation(0.4)));
    defer rectangle.deinit();
    var vertices: [16]g.Point = undefined;
    for (&vertices, 0..) |*vertex, index| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / vertices.len;
        vertex.* = .{ .x = 4 * @cos(angle), .y = 2 * @sin(angle) };
    }
    const cases = [_]struct { name: []const u8, nib: pens.Nib }{
        .{ .name = "rotated_rectangle", .nib = rectangle.nib },
        .{ .name = "polygon16", .nib = .{ .polygon = &vertices } },
        .{ .name = "explicit_ellipse_outline", .nib = .{ .ellipse = g.Transform.scaling(8, 3) } },
    };
    std.debug.print("pen-envelope Zig {s} {s} {s}-{s}; trials={d} repeats={d}\n", .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), trials, repeats });
    for (cases) |case| for ([_]f64{ 0.01, 0.001 }) |tolerance| {
        var times: [trials]f64 = undefined;
        var segment_count: usize = 0;
        var cubic_count: usize = 0;
        var checksum: f64 = 0;
        for (&times) |*elapsed| {
            const start = std.Io.Clock.awake.now(init.io);
            for (0..repeats) |_| {
                var result = try @call(.never_inline, pens.strokeOutline, .{ allocator, case.nib, curve, pens.StrokeOptions{ .tolerance = tolerance, .cap = .round, .join = .round } });
                defer result.deinit();
                segment_count = result.segments.items.len;
                cubic_count = 0;
                for (result.segments.items) |segment| if (segment == .cubic) {
                    cubic_count += 1;
                };
                const bounds = result.bounds().?;
                checksum += bounds.min.x + bounds.max.x + bounds.min.y + bounds.max.y;
                std.mem.doNotOptimizeAway(result.segments.items.ptr);
            }
            elapsed.* = @as(f64, @floatFromInt(start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds())) / 1e6 / repeats;
        }
        std.mem.sort(f64, &times, {}, std.sort.asc(f64));
        std.debug.print("{s} tolerance={d} median_ms={d:.6} segments={d} cubics={d} checksum={d:.8}\n", .{ case.name, tolerance, times[trials / 2], segment_count, cubic_count, checksum });
    };
}
