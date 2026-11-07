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
const Direction = @import("../path/Direction.zig");

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
    if (!framed and has_closed) try checkSeam(vertices, budget, motion.at(0), motion.at(1));
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
    var frames: FrameReader = .{ .reader = .{ .segments = path.segments.items }, .path = &path, .max_delta = max_delta };
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

const FrameSpan = struct {
    segment: *const Path.SegmentFrame,
    lo: f64,
    hi: f64,

    fn parameter(self: FrameSpan, fraction: f64) f64 {
        if (fraction == 1) return self.hi;
        return self.lo + (self.hi - self.lo) * fraction;
    }
};

// Walk source segments once, including across pen-up moves. Mark times
// identify the source interval even when a cubic was flattened many times.
const FrameReader = struct {
    reader: Path.CurveReader,
    next: usize = 0,
    cached: Path.SegmentFrame = undefined,
    path: *const Path,
    knot_cursor: usize = 0,
    max_delta: f64,

    fn span(self: *FrameReader, start: f64, stop: f64) !FrameSpan {
        const index: usize = @intFromFloat(start);
        if (index >= self.next) {
            const source = try self.reader.read(index - self.next);
            self.cached = try Path.SegmentFrame.init(source.curve, source.is_cubic);
            if (source.is_cubic and self.path.knots != null) {
                const raw = self.path.segments.items.len - self.reader.segments.len - 1;
                try self.cached.useSolved(self.path.knots.?.directionsForward(self.path.segments.items, raw, source.curve, &self.knot_cursor), self.max_delta);
            }
            self.next = index + 1;
        }
        const base: f64 = @floatFromInt(index);
        return .{ .segment = &self.cached, .lo = start - base, .hi = stop - base };
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
    turn_tracks: std.ArrayList(Motion.Track) = .empty,
    turn_keys: std.ArrayList(Motion.Key) = .empty,

    fn placement(self: *const Builder, progress: f64, ray: ?Direction.Ray) !g.Transform {
        return self.motion.atContext(.{ .progress = progress, .tangent = if (ray) |v| try Direction.narrow(v) else null });
    }

    fn contour(self: *Builder, segments: []const Path.Segment, times: []const f64, frames: *FrameReader) !void {
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
        @memset(self.ends, sheets.Side.all);
        if (length == 0) {
            if (times.len != 0) return error.UndefinedPathFrame;
            try self.finish(self.motion.at(0), start);
            return;
        }
        var distance: Distance = .{};
        last = start;
        var first_tangent: ?Direction.Ray = null;
        var last_tangent: ?Direction.Ray = null;
        var first: ?g.Transform = null;
        var pose: g.Transform = undefined;
        for (segments[1..], 1..) |seg, i| {
            const p = if (seg == .close) start else seg.line;
            if (p.eql(last)) continue;
            var t0 = distance.total / length;
            distance.advance(last.distance(p));
            const end = distance.total / length;
            if (end <= t0) return error.PrecisionRange;
            const begin = t0;
            var from = last;
            const source = if (times.len == 0) null else try frames.span(times[i - 1], times[i]);
            if (source) |s| {
                from = s.segment.point(s.lo);
                if (first == null or s.lo == 0) {
                    const outgoing = s.segment.ray(s.lo);
                    if (last_tangent) |incoming| {
                        if (!Direction.sameRay(incoming, outgoing)) {
                            const after = try self.placement(t0, outgoing);
                            try self.corner(from, t0, incoming, outgoing, pose, after);
                            pose = after;
                        }
                    } else {
                        first_tangent = outgoing;
                        pose = try self.placement(0, outgoing);
                    }
                }
            } else if (first == null) {
                pose = self.motion.at(0);
            }
            if (first == null) first = pose;
            while (t0 < end) {
                const t1 = @min(end, self.motion.nextKey(t0));
                if (t1 <= t0) return error.PrecisionRange;
                const fraction = (t1 - begin) / (end - begin);
                var slab = source;
                if (slab) |*s| {
                    s.lo = source.?.parameter((t0 - begin) / (end - begin));
                    s.hi = source.?.parameter(fraction);
                    if (s.hi <= s.lo) return error.PrecisionRange;
                }
                const to = if (slab) |s| s.segment.point(s.hi) else last.lerp(p, fraction);
                last_tangent = if (slab) |s| s.segment.ray(s.hi) else null;
                const after = try self.placement(t1, last_tangent);
                try self.sweepInterval(self.motion, t0, t1, from, to, slab, pose, after, 0);
                pose = after;
                t0 = t1;
                from = to;
            }
            last = p;
        }
        if (times.len != 0 and segments[segments.len - 1] == .close) {
            const outgoing = first_tangent.?;
            if (!Direction.sameRay(last_tangent.?, outgoing)) {
                if (self.motion.corner == .strict) return error.UndefinedPathFrame;
                const after_turn = try self.placement(1, outgoing);
                try checkSeam(self.vertices, self.options.tolerance / 8, first.?, after_turn);
                // The first stamp already covers the outgoing side of the seam.
                if (self.motion.corner == .overlap) return self.finish(pose, last);
                try self.corner(last, 1, last_tangent.?, outgoing, pose, after_turn);
                return self.finish(after_turn, last);
            }
            try checkSeam(self.vertices, self.options.tolerance / 8, first.?, pose);
        }
        try self.finish(pose, last);
    }

    fn corner(self: *Builder, center: Point, progress: f64, incoming: Direction.Ray, outgoing: Direction.Ray, before: g.Transform, after: g.Transform) !void {
        if (self.motion.corner == .strict) return error.UndefinedPathFrame;
        if (self.motion.corner == .overlap) {
            // Close the arriving coverage and seed the departing stamp. Both
            // contribute to the same winding union and contour-length clock.
            try self.finish(before, center);
            @memset(self.ends, sheets.Side.all);
            return;
        }
        const from = try Direction.narrow(incoming);
        const count = self.motion.tracks.len;
        try self.turn_tracks.resize(self.boundary.allocator, count);
        try self.turn_keys.resize(self.boundary.allocator, try std.math.mul(usize, 2, count));
        const turn = self.motion.cornerTurn(progress, std.math.atan2(from.y, from.x), Direction.turnAngle(incoming, outgoing), self.turn_tracks.items, self.turn_keys.items);
        // Exactly the same swept patches and error bounds as a moving nib.
        // Reuse the adjacent endpoint matrices so their mesh edges coincide.
        try self.sweepInterval(&turn, 0, 1, center, center, null, before, after, 0);
    }

    fn finish(self: *Builder, matrix: g.Transform, center: Point) !void {
        var a = center.add(matrix.apply(self.vertices[self.vertices.len - 1]));
        for (self.vertices, self.ends) |v, side| {
            const b = center.add(matrix.apply(v));
            try sheets.difference(&self.boundary, a, b, side, sheets.Side.none);
            a = b;
        }
    }

    fn sweepInterval(self: *Builder, motion: *const Motion, t0: f64, t1: f64, p0: Point, p1: Point, span: ?FrameSpan, m0: g.Transform, m1: g.Transform, depth: usize) !void {
        if (self.visits >= self.options.max_segments) return error.GeometryWorkLimit;
        self.visits += 1;
        // The middle Bernstein coefficient of det(lerp(m0,m1)) certifies
        // that the transported counterclockwise nib stays oriented.
        const mixed = m0.a * m1.d + m1.a * m0.d - m0.b * m1.c - m1.b * m0.c;
        if (!std.math.isFinite(mixed)) return error.PrecisionRange;
        const bounds: ?Motion.AngularBounds = if (span) |s| s.segment.direction.angularBounds(s.lo, s.hi) else .{};
        const deviation = if (bounds) |b| motion.intervalError(t0, t1, self.radius, b) else std.math.inf(f64);
        if (bounds != null and !std.math.isFinite(deviation)) return error.PrecisionRange;
        if (mixed < 0 or deviation > self.options.tolerance / 4) {
            const mid = (t0 + t1) * 0.5;
            if (depth >= self.options.max_depth or mid <= t0 or mid >= t1) return error.GeometryWorkLimit;
            var left = span;
            var right = span;
            var pm = p0.lerp(p1, 0.5);
            if (span) |s| {
                const u = s.parameter((mid - t0) / (t1 - t0));
                if (u <= s.lo or u >= s.hi) return error.PrecisionRange;
                left.?.hi = u;
                right.?.lo = u;
                pm = s.segment.point(u);
            }
            const middle = try motion.atContext(.{ .progress = mid, .tangent = if (left) |s| try s.segment.direction.at(s.hi) else null });
            try self.sweepInterval(motion, t0, mid, p0, pm, left, m0, middle, depth + 1);
            try self.sweepInterval(motion, mid, t1, pm, p1, right, middle, m1, depth + 1);
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

fn checkSeam(vertices: []const Point, budget: f64, first: g.Transform, last: g.Transform) !void {
    for (vertices) |v| if (first.apply(v).distance(last.apply(v)) > budget) return error.DiscontinuousClosedMotion;
}

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

test "local frame uses the original derivative and honors noncommuting motion order" {
    const curve: g.Cubic = .{ .p0 = .zero, .p1 = .{ .x = 3, .y = 4 }, .p2 = .{ .x = 8, .y = -2 }, .p3 = .{ .x = 9, .y = 2 } };
    const field = try Direction.init(curve, true);
    const motion: Motion = .{
        .tracks = &.{ .{ .kind = .scale_x, .first = 0, .len = 2 }, .{ .kind = .rotate, .first = 2, .len = 2 }, .{ .kind = .path_frame, .first = 4, .len = 0 } },
        .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 1, .value = 3 }, .{ .t = 0, .value = std.math.pi / 2.0 }, .{ .t = 1, .value = std.math.pi / 2.0 } },
    };
    try motion.validate();
    try std.testing.expectError(error.UndefinedPathFrame, motion.atContext(.{ .progress = 0.25 }));
    for ([_]f64{ 0, 0.013, 0.3729, 0.7, 1 }) |u| {
        const m = try motion.atContext(.{ .progress = 0.25, .tangent = try field.at(u) });
        const axis = m.apply(.{ .x = 1, .y = 0 });
        const tangent = try curve.derivative(u).normalized();
        try std.testing.expectApproxEqAbs(@as(f64, 0), axis.dot(tangent), 1e-14);
        try std.testing.expectApproxEqAbs(@as(f64, 1.5), tangent.cross(axis), 1e-14);
    }
}

test "tiny curved centerline sweeps large rotating nib between endpoint directions" {
    // Spatial and arc deficit fit the initial flattening budget. The frame
    // still rotates by 90 degrees, so accepting a single linear slab fails.
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0.0001, .y = 0 }, .{ .x = 0.0002, .y = 0.0001 }, .{ .x = 0.0002, .y = 0.0002 });
    const motion: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var chisel = try Nib.square().transformed(a, .scaling(8, 0.4));
    defer chisel.deinit();
    var out = try expand(a, path, chisel.nib, &motion, .{ .tolerance = 0.02 });
    defer out.deinit();
    try std.testing.expect(try windingAt(out, .{ .x = 2.7, .y = 2.7 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 3, .y = 3 }));
    try std.testing.expectError(error.GeometryWorkLimit, expand(a, path, chisel.nib, &motion, .{ .tolerance = 0.02, .max_depth = 1 }));
}

test "path frames respect seams, lifts, stationary limits and undefined directions" {
    const a = std.testing.allocator;
    const motion: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var path = try Path.circle(a, .zero, 5);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 0 });
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = 12, .y = 0 }, .{ .x = 13, .y = 0 });
    // The derivative of this next segment vanishes at 1/2 with the same
    // positive horizontal limiting tangent on each side.
    try path.cubicTo(.{ .x = 14, .y = 0 }, .{ .x = 13, .y = 0 }, .{ .x = 14, .y = 0 });
    var out = try expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
    defer out.deinit();
    try path.lineTo(.{ .x = 14, .y = 5 });
    try std.testing.expectError(error.UndefinedPathFrame, expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 }));

    var stop = Path.init(a);
    defer stop.deinit();
    try stop.moveTo(.zero);
    try stop.lineTo(.zero);
    try std.testing.expectError(error.UndefinedPathFrame, expand(a, stop, Nib.square(), &motion, .{}));
    try stop.cubicTo(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 }, .zero);
    try std.testing.expectError(error.UndefinedPathFrame, expand(a, stop, Nib.square(), &motion, .{}));
}

test "framed motion key still addresses physical arc length on a nonuniform cubic" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.zero, .zero, .{ .x = 16, .y = 0 });
    const motion: Motion = .{
        .tracks = &.{ .{ .kind = .path_frame, .first = 0, .len = 0 }, .{ .kind = .scale_y, .first = 0, .len = 3 } },
        .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 8 }, .{ .t = 1, .value = 1 } },
    };
    var out = try expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
    defer out.deinit();
    // x = 16u^3, so u=1/2 is at x=2, but the middle key belongs at x=8.
    try std.testing.expect(try windingAt(out, .{ .x = 8, .y = 3.9 }) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(out, .{ .x = 2, .y = 3 }));
}

test "rotate and overlap treat open frame corners and closed seams on the same contour" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    const law: Motion = .{
        .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }},
        .keys = &.{},
    };
    var chisel = try Nib.square().transformed(a, .scaling(0.5, 8));
    defer chisel.deinit();
    var open = Path.init(a);
    defer open.deinit();
    try open.moveTo(.{ .x = -12, .y = 0 });
    try open.lineTo(.zero);
    try open.lineTo(.{ .x = 0, .y = 12 });
    var closed = Path.init(a);
    defer closed.deinit();
    try closed.moveTo(.zero);
    try closed.lineTo(.{ .x = 12, .y = 0 });
    try closed.lineTo(.{ .x = 12, .y = 12 });
    try closed.lineTo(.{ .x = 0, .y = 12 });
    try closed.close();
    for ([_]Motion.Corner{ .rotate, .overlap }) |mode| {
        var motion = law;
        motion.corner = mode;
        var corner = try expand(a, open, chisel.nib, &motion, .{ .tolerance = 0.02 });
        defer corner.deinit();
        var seam = try expand(a, closed, chisel.nib, &motion, .{ .tolerance = 0.02 });
        defer seam.deinit();
        try std.testing.expectEqual(mode == .rotate, (try windingAt(corner, .{ .x = 2.6, .y = -2.6 })) != 0);
        try std.testing.expectEqual(mode == .rotate, (try windingAt(seam, .{ .x = -2.6, .y = -2.6 })) != 0);
        try std.testing.expectEqual(@as(i32, 0), try windingAt(corner, .{ .x = 3.1, .y = -3.1 }));
        // The shared coverage is painted once; the source remains one contour.
        try std.testing.expectEqual(@as(u32, 1), @abs(try windingAt(corner, .{ .x = -0.1, .y = 0.1 })));
    }
}

test "frame corner rotation takes the short signed turn and positive half-turn on reversal" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    const turn: Motion = .{ .corner = .rotate, .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var eccentric = try Nib.square().transformed(a, g.Transform.scaling(0.5, 0.5).then(.translation(4, 0)));
    defer eccentric.deinit();
    var track = Path.init(a);
    defer track.deinit();
    try track.moveTo(.{ .x = -8, .y = 0 });
    try track.lineTo(.zero);
    try track.lineTo(.{ .x = 0, .y = -8 });
    var clockwise = try expand(a, track, eccentric.nib, &turn, .{ .tolerance = 0.02 });
    defer clockwise.deinit();
    try std.testing.expect((try windingAt(clockwise, .{ .x = 2.82, .y = -2.82 })) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(clockwise, .{ .x = 0, .y = 4 }));
    var reversed = Path.init(a);
    defer reversed.deinit();
    try reversed.moveTo(.{ .x = -8, .y = 0 });
    try reversed.lineTo(.zero);
    try reversed.lineTo(.{ .x = -8, .y = 0 });
    var half = try expand(a, reversed, eccentric.nib, &turn, .{ .tolerance = 0.02 });
    defer half.deinit();
    try std.testing.expect((try windingAt(half, .{ .x = 0, .y = 4 })) != 0);
    try std.testing.expectEqual(@as(i32, 0), try windingAt(half, .{ .x = 0, .y = -4 }));
}

test "frame corner transitions preserve contour progress and the closed motion contract" {
    const a = std.testing.allocator;
    const windingAt = @import("../region/pathops/winding.zig").windingAt;
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.{ .x = -20, .y = 0 });
    try path.lineTo(.zero);
    try path.lineTo(.{ .x = 0, .y = 20 });
    var loop = try path.clone(a);
    defer loop.deinit();
    try loop.close();
    for ([_]Motion.Corner{ .rotate, .overlap }) |mode| {
        var motion: Motion = .{
            .corner = mode,
            .tracks = &.{ .{ .kind = .scale_y, .first = 0, .len = 3 }, .{ .kind = .path_frame, .first = 3, .len = 0 } },
            .keys = &.{ .{ .t = 0, .value = 1 }, .{ .t = 0.5, .value = 8 }, .{ .t = 1, .value = 2 } },
        };
        var footprint = try expand(a, path, Nib.square(), &motion, .{ .tolerance = 0.05 });
        defer footprint.deinit();
        try std.testing.expectEqual(@as(i32, 0), try windingAt(footprint, .{ .x = -10, .y = 3 }));
        try std.testing.expect((try windingAt(footprint, .{ .x = 3.5, .y = 1 })) != 0);
        try std.testing.expectEqual(mode == .rotate, (try windingAt(footprint, .{ .x = 2.6, .y = -2.6 })) != 0);
        try std.testing.expectError(error.DiscontinuousClosedMotion, expand(a, loop, Nib.square(), &motion, .{ .tolerance = 0.05 }));
    }
}

test "a constant framed nib sweeps a monotone straight cubic under the line budget" {
    const a = std.testing.allocator;
    const law: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    var line = Path.init(a);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 16, .y = 0 });
    var curve = Path.init(a);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.zero, .zero, .{ .x = 16, .y = 0 });
    const opts: outline.Options = .{ .tolerance = 0.001, .max_segments = 64 };
    var reference = try expand(a, line, Nib.square(), &law, opts);
    defer reference.deinit();
    var actual = try expand(a, curve, Nib.square(), &law, opts);
    defer actual.deinit();
    try std.testing.expectEqualDeep(reference.segments.items, actual.segments.items);
    // A nonzero transverse component must never earn the chord certificate.
    try std.testing.expect(!Direction.monotoneLine(.{ .p0 = .zero, .p1 = .zero, .p2 = .{ .x = 0, .y = 1e-100 }, .p3 = .{ .x = 16, .y = 0 } }));
    try std.testing.expect(!Direction.monotoneLine(.{ .p0 = .zero, .p1 = .{ .x = 3, .y = 0 }, .p2 = .{ .x = -3, .y = 0 }, .p3 = .{ .x = 1, .y = 0 } }));
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

test "strict frame honors solved Hobby knots and still rejects a hand-made or edited corner" {
    const a = std.testing.allocator;
    const construct = @import("../path/construct.zig");
    const points = [_]Point{ .zero, .{ .x = 60, .y = 80 }, .{ .x = 130, .y = 20 }, .{ .x = 210, .y = 90 } };
    const strict: Motion = .{ .tracks = &.{.{ .kind = .path_frame, .first = 0, .len = 0 }}, .keys = &.{} };
    for ([_]bool{ false, true }) |closed| {
        const joins = [_]construct.Join{ .smooth, .smooth, .smooth, .smooth };
        var path = try construct.construct(a, &points, joins[0..if (closed) @as(usize, 4) else 3], .{ .closed = closed });
        defer path.deinit();
        var ink = try expand(a, path, Nib.square(), &strict, .{ .tolerance = 0.02 });
        defer ink.deinit();
        try std.testing.expect(ink.segments.items.len > 0);
        var reverse = try path.reverse(a);
        defer reverse.deinit();
        try reverse.transform(g.Transform.rotation(0.31).then(.translation(12, 7)));
        var cut = try reverse.trimmed(a, 0.25, 2.5);
        defer cut.deinit();
        var cut_ink = try expand(a, cut, Nib.square(), &strict, .{ .tolerance = 0.02 });
        defer cut_ink.deinit();
        path.segments.items[2].cubic.c1.y += 0.1;
        try std.testing.expectError(error.UndefinedPathFrame, expand(a, path, Nib.square(), &strict, .{ .tolerance = 0.02 }));
    }
    var hand = Path.init(a);
    defer hand.deinit();
    try hand.moveTo(.zero);
    try hand.cubicTo(.{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 });
    try hand.cubicTo(.{ .x = 4, .y = 1e-16 }, .{ .x = 5, .y = 0 }, .{ .x = 6, .y = 0 });
    try std.testing.expectError(error.UndefinedPathFrame, expand(a, hand, Nib.square(), &strict, .{ .tolerance = 0.02 }));
}
