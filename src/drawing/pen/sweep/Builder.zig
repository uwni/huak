//! The contour walk of a moving nib: placements along each flattened span, the corners between spans, and the adaptive interval sweep whose boundary becomes one region.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const outline = @import("../outline.zig");
const Motion = @import("../Motion.zig");
const sheets = @import("../sweep_patch.zig");
const Patch = sheets.Patch;
const Point = g.Point;
const Boundary = @import("../SweepBoundary.zig");
const Direction = @import("../../path/Direction.zig");
const framing = @import("framing.zig");
const Builder = @This();

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

pub fn contour(self: *Builder, segments: []const Path.Segment, times: []const f64, frames: *framing.FrameReader) !void {
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

pub fn corner(self: *Builder, center: Point, progress: f64, incoming: Direction.Ray, outgoing: Direction.Ray, before: g.Transform, after: g.Transform) !void {
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

fn sweepInterval(self: *Builder, motion: *const Motion, t0: f64, t1: f64, p0: Point, p1: Point, span: ?framing.FrameSpan, m0: g.Transform, m1: g.Transform, depth: usize) !void {
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

pub fn checkSeam(vertices: []const Point, budget: f64, first: g.Transform, last: g.Transform) !void {
    for (vertices) |v| if (first.apply(v).distance(last.apply(v)) > budget) return error.DiscontinuousClosedMotion;
}
