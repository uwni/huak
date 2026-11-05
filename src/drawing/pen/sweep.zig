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
const Patch = sheets.Patch;
const Point = g.Point;
const Boundary = @import("SweepBoundary.zig");

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
    if (motion.keys.len > options.max_vertices) return error.GeometryWorkLimit;
    var magnitude = @max(b.scale, b.speed) * r;
    for (motion.tracks) |track| {
        if (track.kind == .rotate) for (motion.keys[track.first..][0..track.len]) |k| {
            magnitude = @max(magnitude, b.scale * r * @abs(k.value));
        };
    }
    for (path.segments.items) |segment| switch (segment) {
        .move, .line => |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y)),
        .cubic => |c| {
            for ([_]Point{ c.c1, c.c2, c.end }) |p| magnitude = @max(magnitude, @abs(p.x), @abs(p.y));
        },
        .close => {},
    };
    const roundoff = magnitude * std.math.floatEps(f64) * 64 * @as(f64, @floatFromInt(motion.tracks.len));
    if (budget == 0 or !std.math.isFinite(b.uncertainty) or roundoff + r * b.uncertainty > budget) return error.PrecisionRange;
    var flat_options: flattening.Options = .{ .tolerance = budget, .length_tolerance = budget, .preserve_travel = true, .max_segments = options.max_segments, .max_depth = options.max_depth };
    var flat = try flattening.flatten(a, path, flat_options);
    defer flat.deinit();
    // Normalizing a contour length with deficit d changes its fractional
    // distance by at most 2d/L. Convert that change to nib displacement.
    const shortest = try flattening.minimumContourLength(flat);
    if (2 * b.speed * r > shortest and shortest > 0) {
        flat_options.length_tolerance = budget * (shortest / (2 * b.speed * r));
        var finer = try flattening.flatten(a, path, flat_options);
        std.mem.swap(Path, &flat, &finer);
        finer.deinit();
    }
    var mesh_options = options;
    mesh_options.tolerance = options.tolerance / @max(1, b.scale);
    mesh_options.cap = .round;
    mesh_options.join = .round;
    const vertices = try outline.nibVertices(a, nib, Path.init(a), mesh_options);
    defer if (nib == .ellipse) a.free(vertices);
    const ends = try a.alloc(sheets.Side, vertices.len);
    defer a.free(ends);
    // First stamp + oriented material entering at each edge counts coverage.
    // A global nonzero union removes parts covered elsewhere in the contour.
    var builder: Builder = .{ .ends = ends, .boundary = .{ .allocator = a, .limit = options.max_vertices }, .motion = motion, .vertices = vertices, .radius = r, .options = options };

    defer builder.boundary.deinit();
    var i: usize = 0;
    const segments = flat.segments.items;
    while (i < segments.len) {
        if (segments[i] != .move) return error.InvalidPath;
        var end = i + 1;
        while (end < segments.len and segments[end] != .move) end += 1;
        try builder.contour(segments[i..end]);
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

// Compensate arc-length sums. Both traversals must use identical arithmetic
// so that repeated vertices and the endpoint retain the same progress.
const Distance = struct {
    total: f64 = 0,
    correction: f64 = 0,
    fn advance(self: *Distance, delta: f64) void {
        const adjusted = delta - self.correction;
        const next = self.total + adjusted;
        self.correction = (next - self.total) - adjusted;
        self.total = next;
    }
};

const Builder = struct {
    ends: []sheets.Side,
    boundary: Boundary,
    motion: *const Motion,
    vertices: []const Point,
    radius: f64,
    options: outline.Options,
    visits: usize = 0,
    faces: usize = 0,

    fn contour(self: *Builder, segments: []const Path.Segment) !void {
        const start = segments[0].move;
        var last = start;
        var measured: Distance = .{};
        for (segments[1..]) |seg| {
            const p = if (seg == .close) start else seg.line;
            if (!p.eql(last)) measured.advance(p.distance(last));
            last = p;
        }
        const length = measured.total;
        if (!std.math.isFinite(length)) return error.NonFinite;
        const first = self.motion.at(0);
        if (segments[segments.len - 1] == .close) {
            const end = self.motion.at(1);
            for (self.vertices) |v| if (first.apply(v).distance(end.apply(v)) > self.options.tolerance / 8) return error.DiscontinuousClosedMotion;
        }
        @memset(self.ends, sheets.Side.all);
        if (length == 0) {
            try self.finish(first, start);
            return;
        }
        var distance: Distance = .{};
        last = start;
        for (segments[1..]) |seg| {
            const p = if (seg == .close) start else seg.line;
            if (p.eql(last)) continue;
            var t0 = distance.total / length;
            distance.advance(last.distance(p));
            const end = distance.total / length;
            if (end <= t0) return error.PrecisionRange;
            const begin = t0;
            var from = last;
            while (t0 < end) {
                const t1 = @min(end, self.motion.nextKey(t0));
                if (t1 <= t0) return error.PrecisionRange;
                const to = last.lerp(p, (t1 - begin) / (end - begin));
                try self.interval(t0, t1, from, to, 0);
                t0 = t1;
                from = to;
            }
            last = p;
        }
        try self.finish(self.motion.at(1), last);
    }

    fn finish(self: *Builder, matrix: g.Transform, center: Point) !void {
        var a = center.add(matrix.apply(self.vertices[self.vertices.len - 1]));
        for (self.vertices, self.ends) |v, side| {
            const b = center.add(matrix.apply(v));
            try sheets.difference(&self.boundary, a, b, side, sheets.Side.none);
            a = b;
        }
    }

    fn interval(self: *Builder, t0: f64, t1: f64, p0: Point, p1: Point, depth: usize) !void {
        if (self.visits >= self.options.max_segments) return error.GeometryWorkLimit;
        self.visits += 1;
        const m0 = self.motion.at(t0);
        const m1 = self.motion.at(t1);
        // The middle Bernstein coefficient of det(lerp(m0,m1)) certifies
        // that the transported counterclockwise nib stays oriented.
        const mixed = m0.a * m1.d + m1.a * m0.d - m0.b * m1.c - m1.b * m0.c;
        if (!std.math.isFinite(mixed)) return error.PrecisionRange;
        const deviation = self.motion.chordError(t0, t1, self.radius);
        if (!std.math.isFinite(deviation)) return error.PrecisionRange;
        if (mixed < 0 or deviation > self.options.tolerance / 4) {
            const mid = (t0 + t1) * 0.5;
            if (depth >= self.options.max_depth or mid <= t0 or mid >= t1) return error.GeometryWorkLimit;
            const pm = p0.lerp(p1, 0.5);
            try self.interval(t0, mid, p0, pm, depth + 1);
            try self.interval(mid, t1, pm, p1, depth + 1);
            return;
        }
        if (self.vertices.len > (self.options.max_vertices *| 8) -| self.faces) return error.GeometryWorkLimit;
        self.faces += self.vertices.len;
        var a = p0.add(m0.apply(self.vertices[self.vertices.len - 1]));
        var c = p1.add(m1.apply(self.vertices[self.vertices.len - 1]));
        var incoming: sheets.Side = undefined;
        var first_left: sheets.Side = undefined;
        const seam_start = a;
        const seam_end = c;
        for (self.vertices, self.ends, 0..) |v, *prev, i| {
            const b = p0.add(m0.apply(v));
            const d = p1.add(m1.apply(v));
            const patch: Patch = .{ .a = a, .b = b, .c = c, .d = d };
            const s = try patch.sides();
            try sheets.difference(&self.boundary, a, b, prev.*, sheets.Sides.interior(s.bottom, s.top));
            prev.* = sheets.Sides.interior(s.top, s.bottom);
            const left = sheets.Sides.interior(s.left, s.right);
            if (i > 0) try sheets.difference(&self.boundary, a, c, left, incoming) else first_left = left;
            incoming = sheets.Sides.interior(s.right, s.left);
            try patch.fold(s, &self.boundary);
            a = b;
            c = d;
        }
        try sheets.difference(&self.boundary, seam_start, seam_end, first_left, incoming);
    }
};

test {
    _ = @import("sweep_patch.zig");
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
