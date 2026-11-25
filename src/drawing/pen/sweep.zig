//! Sweep material continuously between placements. The centerline and the
//! motion have separate spatial, arc-length, nib and interpolation budgets.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const regions = @import("../region/root.zig");
const flattening = @import("../path/flatten.zig");
const outline = @import("outline.zig");
const Nib = @import("nib.zig").Nib;
const Motion = @import("Motion.zig");
const sheets = @import("sweep_patch.zig");
const Point = g.Point;
const Builder = @import("sweep/Builder.zig");
const framing = @import("sweep/framing.zig");

fn flatten(a: std.mem.Allocator, path: Path, opts: flattening.Options, times: ?*std.ArrayList(f64)) !Path {
    if (times) |out| return flattening.withTimes(a, path, opts, out);
    return flattening.flatten(a, path, opts);
}

pub fn radius(nib: Nib) !f64 {
    const box = try nib.bounds();
    return std.math.hypot(@max(@abs(box.min.x), @abs(box.max.x)), @max(@abs(box.min.y), @abs(box.max.y)));
}

pub fn expand(a: std.mem.Allocator, path: Path, nib: Nib, motion: *const Motion, options: outline.Options) !Path {
    try motion.validate();
    try outline.validateOptions(options);
    const r = try radius(nib);
    const b = motion.bounds();
    if (!std.math.isFinite(b.scale * r) or !std.math.isFinite(b.speed * r)) return error.PrecisionRange;
    const budget = options.tolerance / 8;
    // Require the reserved budget to resolve arithmetic at this coordinate
    // scale, including argument rounding of unwrapped rotation tracks.
    if (motion.keys.len > options.max_vertices or motion.tracks.len > options.max_vertices) return error.GeometryWorkLimit;
    var magnitude = @max(b.scale, b.speed) * r;
    for (motion.tracks) |track| {
        if (track.kind == .rotate) for (motion.keys[track.first..][0..track.len]) |k| {
            magnitude = @max(magnitude, b.scale * r * @abs(k.value));
        };
    }
    var has_closed = false;
    for (path.segments.items) |segment| switch (segment) {
        .move, .line => |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y)),
        .cubic => |c| {
            for ([_]Point{ c.c1, c.c2, c.end }) |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y));
        },
        .close => has_closed = true,
    };
    const roundoff = magnitude * std.math.floatEps(f64) * 64 * @as(f64, @floatFromInt(motion.tracks.len));
    if (budget == 0 or !std.math.isFinite(b.uncertainty) or roundoff + r * b.uncertainty > budget) return error.PrecisionRange;
    var flat_options: flattening.Options = .{ .tolerance = budget, .length_tolerance = budget, .preserve_travel = true, .max_segments = options.max_segments, .max_depth = options.max_depth };
    const framed = motion.usesPathFrame();
    var mesh_options = options;
    mesh_options.tolerance = options.tolerance / @max(1, b.scale);
    mesh_options.cap = .round;
    mesh_options.join = .round;
    const vertices = try outline.nibVertices(a, nib, Path.init(a), mesh_options);
    defer if (nib == .ellipse) a.free(vertices);
    if (!framed and has_closed) try Builder.checkSeam(vertices, budget, motion.at(0), motion.at(1));
    flat_options.straight_as_line = framed and motion.constantInProgress();
    var times: std.ArrayList(f64) = .empty;
    defer times.deinit(a);
    const time_output = if (framed) &times else null;
    // Key and motion cuts may choose both endpoints inside this chord.
    // Their interpolant and the true center are each within delta of it.
    if (framed) flat_options.parameter_tolerance = budget / 2;
    var flat = try flatten(a, path, flat_options, time_output);
    defer flat.deinit();
    // Normalizing a contour length with deficit d changes its fractional
    // distance by at most 2d/L. Convert that change to nib displacement.
    const shortest = try flattening.minimumContourLength(flat);
    // At source parameter u, the partial arc length differs from the same
    // chord fraction by at most the slab's parameter error + length deficit.
    const sensitivity = (if (framed) @as(f64, 3) else 2) * b.speed * r;
    if (sensitivity > shortest and shortest > 0) {
        flat_options.length_tolerance = budget * (shortest / sensitivity);
        if (framed) flat_options.parameter_tolerance = @min(budget / 2, flat_options.length_tolerance);
        flat.deinit();
        flat = Path.init(a);
        times.clearRetainingCapacity();
        flat = try flatten(a, path, flat_options, time_output);
    }
    const ends = try a.alloc(sheets.Side, vertices.len);
    defer a.free(ends);
    // First stamp + oriented material entering at each edge counts coverage.
    // A global nonzero union removes parts covered elsewhere in the contour.
    var builder: Builder = .{ .ends = ends, .boundary = .{ .allocator = a, .limit = options.max_vertices }, .motion = motion, .vertices = vertices, .radius = r, .options = options };

    defer builder.boundary.deinit();
    defer builder.turn_tracks.deinit(a);
    defer builder.turn_keys.deinit(a);
    var i: usize = 0;
    const segments = flat.segments.items;
    const extent = r * b.scale;
    const max_delta = if (extent == 0) std.math.inf(f64) else (budget - roundoff - r * b.uncertainty) / extent / @as(f64, @floatFromInt(motion.tracks.len));
    var frames: framing.FrameReader = .{ .reader = .{ .segments = path.segments.items }, .path = &path, .max_delta = max_delta };
    while (i < segments.len) {
        if (segments[i] != .move) return error.InvalidPath;
        var end = i + 1;
        while (end < segments.len and segments[end] != .move) end += 1;
        try builder.contour(segments[i..end], if (framed) times.items[i..end] else &.{}, &frames);
        i = end;
    }
    var boundary = try builder.boundary.contours();
    defer boundary.deinit();
    return regions.normalizeStroke(a, boundary, .{
        .tolerance = budget,
        .max_vertices = options.max_vertices,
        .max_depth = options.max_depth,
    });
}

test {
    _ = @import("sweep_patch.zig");
    _ = @import("sweep/frame_test.zig");
    _ = @import("sweep/corner_test.zig");
}

test "continuous growing disk includes tangent contacts outside the transverse width" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var line = Path.init(a);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    const motion: Motion = .{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 2 }}, .keys = &.{ .{ .t = 0, .value = 2 }, .{ .t = 1, .value = 10 } } };
    var out = try expand(a, line, Nib.circle(), &motion, .{ .tolerance = 0.001 });
    defer out.deinit();
    // r(x)=1+0.4x. The common tangent rises as r(x)/sqrt(1-0.4²).
    for (0..8) |i| {
        const x: f64 = @floatFromInt(i);
        const y = (1 + 0.4 * x) / @sqrt(@as(f64, 1 - 0.4 * 0.4));
        try std.testing.expect(try windingAt(out, .{ .x = x, .y = y - 0.002 }) != 0);
        try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = x, .y = y + 0.002 }));
    }
    try std.testing.expect(try windingAt(out, .{ .x = 14.9, .y = 0.1 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 15.1, .y = 0.1 }));
    try std.testing.expectError(error.InvalidTolerance, expand(a, line, Nib.square(), &motion, .{ .tolerance = 0 }));
    try std.testing.expectError(error.PrecisionRange, expand(a, line, Nib.square(), &motion, .{ .tolerance = 1e-16 }));
    var uncertain = motion;
    uncertain.tracks = &.{.{ .kind = .scale, .first = 0, .len = 2, .uncertainty = 1 }};
    try std.testing.expectError(error.PrecisionRange, expand(a, line, Nib.square(), &uncertain, .{ .tolerance = 0.01 }));
    try line.close();
    try std.testing.expectError(error.DiscontinuousClosedMotion, expand(a, line, Nib.circle(), &motion, .{}));
}

test "a full unwrapped turn sweeps interior placements and has closed seam" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var loop = Path.init(a);
    defer loop.deinit();
    try loop.moveTo(.zero);
    try loop.lineTo(.{ .x = 0.2, .y = 0 });
    try loop.close();
    const motion: Motion = .{ .tracks = &.{.{ .kind = .rotate, .first = 0, .len = 2 }}, .keys = &.{ .{ .t = 0, .value = 0 }, .{ .t = 1, .value = std.math.tau } } };
    var chisel = try Nib.square().transformed(a, .scaling(8, 1));
    defer chisel.deinit();
    var out = try expand(a, loop, chisel.nib, &motion, .{ .tolerance = 0.01 });
    defer out.deinit();
    try std.testing.expect(try windingAt(out, .{ .x = 0.15, .y = 3.8 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 0.2, .y = 4.2 }));
    try std.testing.expectError(error.GeometryWorkLimit, expand(a, loop, chisel.nib, &motion, .{ .tolerance = 0.01, .max_depth = 1 }));
}

test "scale and turn covers intermediate placements within physical tolerance" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var track = Path.init(a);
    defer track.deinit();
    try track.moveTo(.zero);
    try track.lineTo(.{ .x = 9, .y = 0 });
    const law: Motion = .{
        .tracks = &.{ .{ .kind = .scale_x, .first = 0, .len = 3, .polynomial = true }, .{ .kind = .rotate, .first = 3, .len = 2 } },
        .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 1 }, .{ .t = 1, .value = 2 }, .{ .t = 0, .value = 0 }, .{ .t = 1, .value = 2.7 } },
    };
    var chisel = try Nib.square().transformed(a, .scaling(4, 1));
    defer chisel.deinit();
    var out = try expand(a, track, chisel.nib, &law, .{ .tolerance = 0.01 });
    defer out.deinit();
    // Independent membership oracle: inverse-rotate each probe into each
    // rectangle. The Lipschitz bound on corner motion is < 26 pt per turn
    // parameter, so the missed distance between samples is < 0.013 pt.
    for (0..27) |ix| for (0..17) |iy| {
        const x = @as(f64, @floatFromInt(ix)) * 0.5 - 2.1;
        const y = @as(f64, @floatFromInt(iy)) * 0.5 - 4.1;
        var best = std.math.inf(f64);
        for (0..1025) |step| {
            const u = @as(f64, @floatFromInt(step)) / 1024;
            const angle = 2.7 * u;
            const dx = x - 9 * u;
            const local_x = @cos(angle) * dx + @sin(angle) * y;
            const local_y = -@sin(angle) * dx + @cos(angle) * y;
            best = @min(best, @max(@abs(local_x) - 2 * (1 + u * u), @abs(local_y) - 0.5));
        }
        if (@abs(best) > 0.04) try std.testing.expectEqual(best < 0, (try windingAt(out, .{ .x = x, .y = y })) != 0);
    };
}

test "sub-tolerance centerline loops still traverse the whole motion" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var loop = Path.init(a);
    defer loop.deinit();
    try loop.moveTo(.zero);
    try loop.cubicTo(.{ .x = 1e-5, .y = 0 }, .{ .x = 0, .y = 1e-5 }, .zero);
    const motion: Motion = .{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 3 }}, .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 5 }, .{ .t = 1, .value = 1 } } };
    var out = try expand(a, loop, Nib.square(), &motion, .{ .tolerance = 0.01 });
    defer out.deinit();
    try std.testing.expect((try windingAt(out, .{ .x = 2.4, .y = 2.3 })) != 0);
}

test "context independent invalid seam is diagnosed before geometry work" {
    const a = std.testing.allocator;
    var loop = Path.init(a);
    defer loop.deinit();
    try loop.moveTo(.zero);
    try loop.lineTo(.{ .x = 16, .y = 0 });
    try loop.close();
    const motion: Motion = .{ .tracks = &.{.{ .kind = .rotate, .first = 0, .len = 2 }}, .keys = &.{ .{ .t = 0, .value = 0 }, .{ .t = 1, .value = 2.1 } } };
    try std.testing.expectError(error.DiscontinuousClosedMotion, expand(a, loop, Nib.square(), &motion, .{ .tolerance = 0.001, .max_depth = 1 }));
}
