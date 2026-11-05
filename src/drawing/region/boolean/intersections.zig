// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
// Native translation of the upstream paired intersection events. The graph
// consumes both locations; no crossing-only filter or polygon approximation.
const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const curve = @import("curve.zig");
const numerical = @import("numeric.zig");
const Allocator = types.Allocator;
const Cubic = geometry.Cubic;
const Point = types.Point;
const Source = types.Source;
const Location = types.Location;
const CurveError = std.mem.Allocator.Error || error{GeometryWorkLimit};

pub const LocationInfo = struct {
    location: Location,
    offset: f64,
};
pub const Event = struct {
    first: LocationInfo,
    second: LocationInfo,
    point: Point,
};

const CurveLength = struct { offset: f64 = undefined, total: f64 = -1 };

const Builder = struct {
    allocator: Allocator,
    sources: []const Source,
    scratch: Allocator,
    lengths: []CurveLength = &.{},
    events: std.ArrayList(Event) = .empty,
    epsilon: f64,
    // Largest absolute normalized coordinate. Only widens the conservative
    // separation margin; it never participates in event acceptance.
    magnitude: f64 = 0,
    // Reused implicit-polynomial roots scratch; cleared per query.
    roots: std.ArrayList(f64) = .empty,

    fn deinit(self: *Builder) void {
        self.events.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.scratch.free(self.lengths);
    }

    fn ensureLengths(self: *Builder, index: usize) void {
        if (self.lengths[index].total >= 0) return;
        var first = index;
        while (first > 0 and self.sources[first - 1].contour == self.sources[index].contour) first -= 1;
        var end = first;
        var length: f64 = 0;
        while (end < self.sources.len and self.sources[end].contour == self.sources[first].contour) : (end += 1) {
            self.lengths[end].offset = length;
            length += curve.getLength(&self.sources[end].cubic, 0, 1);
        }
        for (self.lengths[first..end]) |*item| item.total = length;
    }

    fn location(self: *Builder, index: usize, time: f64) LocationInfo {
        // CurveLocation.initialize maps an end to the next curve's start.
        const loc: Location = if (time >= 0.99999999)
            .{ .curve = self.sources[index].next, .time = 0 }
        else
            .{ .curve = index, .time = time };
        self.ensureLengths(loc.curve);
        const values = &self.sources[loc.curve].cubic;
        return .{
            .location = loc,
            // A curve start is exactly its contour offset; skip a zero-length
            // integration for the many endpoint locations.
            .offset = if (loc.time == 0) self.lengths[loc.curve].offset else self.lengths[loc.curve].offset + curve.getLength(values, 0, loc.time),
        };
    }

    fn sameLocation(self: *const Builder, a: LocationInfo, b: LocationInfo) bool {
        const source = self.sources[a.location.curve];
        if (source.contour != self.sources[b.location.curve].contour) return false;
        const difference = @abs(a.offset - b.offset);
        return difference < 1e-7 or @abs(self.lengths[a.location.curve].total - difference) < 1e-7;
    }

    fn sameEvent(self: *const Builder, a: Event, b: Event) bool {
        return self.sameLocation(a.first, b.first) and self.sameLocation(a.second, b.second);
    }

    fn hasNearbyEvent(self: *const Builder, event: Event, index: usize, direction: isize) bool {
        const length: isize = @intCast(self.events.items.len);
        var i: isize = @as(isize, @intCast(index)) + direction;
        while (i >= -1 and i <= length) : (i += direction) {
            const k: usize = @intCast(@mod(i, length));
            const candidate = self.events.items[k];
            if (!curve.withinDistance(event.point, candidate.point, 1e-7)) break;
            if (self.sameEvent(event, candidate)) return true;
        }
        return false;
    }

    fn addLocation(self: *Builder, c1: usize, time1: ?f64, c2: usize, time2: ?f64, overlap: bool) !void {
        const t1 = time1 orelse return;
        const t2 = time2 orelse return;
        const exclude_start = !overlap and self.sources[c2].next == c1;
        const exclude_end = !overlap and c1 != c2 and self.sources[c1].next == c2;
        if (!(t1 >= (if (exclude_start) @as(f64, 1e-8) else 0) and
            t1 <= (if (exclude_end) @as(f64, 1 - 1e-8) else 1) and
            t2 >= (if (exclude_end) @as(f64, 1e-8) else 0) and
            t2 <= (if (exclude_start) @as(f64, 1 - 1e-8) else 1))) return;
        if (self.lengths.len == 0) {
            self.lengths = try self.scratch.alloc(CurveLength, self.sources.len);
            @memset(self.lengths, .{});
        }
        const start = self.location(c1, t1);
        const event: Event = .{ .first = start, .second = self.location(c2, t2), .point = curve.getPoint(&self.sources[start.location.curve].cubic, start.location.time) };
        var left: isize = 0;
        var right: isize = @as(isize, @intCast(self.events.items.len)) - 1;
        while (left <= right) {
            const middle: usize = @intCast(@divTrunc(left + right, 2));
            const other = self.events.items[middle];
            if (self.sameEvent(event, other) or self.hasNearbyEvent(event, middle, -1) or self.hasNearbyEvent(event, middle, 1)) return;
            const first = event.first.location;
            const second = other.first.location;
            const contour1 = self.sources[first.curve].contour;
            const contour2 = self.sources[second.curve].contour;
            const before = if (contour1 != contour2) contour1 < contour2 else @as(f64, @floatFromInt(first.curve)) + first.time < @as(f64, @floatFromInt(second.curve)) + second.time;
            if (before) right = @as(isize, @intCast(middle)) - 1 else left = @as(isize, @intCast(middle)) + 1;
        }
        try self.events.insert(self.allocator, @intCast(left), event);
    }

    fn addLineIntersection(self: *Builder, a: *const Cubic, b: *const Cubic, c1: usize, c2: usize) !void {
        if (lineIntersection(a, b)) |point| try self.addLocation(c1, curve.getTimeOf(a, point, null), c2, curve.getTimeOf(b, point, null), false);
    }

    fn addCurveLineIntersections(self: *Builder, a: *const Cubic, b: *const Cubic, c1: usize, c2: usize, flip: bool) !void {
        const times = lineTimes(a, b.p0.x, b.p0.y, b.p3.x - b.p0.x, b.p3.y - b.p0.y);
        for (times.items[0..times.len]) |t1| {
            const point = curve.getPoint(a, t1);
            if (curve.getTimeOf(b, point, null)) |t2| try self.addLocation(if (flip) c2 else c1, if (flip) t2 else t1, if (flip) c1 else c2, if (flip) t1 else t2, false);
        }
    }

    fn addCurveIntersections(self: *Builder, first: Cubic, second: Cubic, c1: usize, c2: usize, flip: bool, depth: usize, calls: *usize, t_min: f64, t_max: f64, u_min_input: f64, u_max_input: f64) CurveError!void {
        calls.* += 1;
        const recursion = depth + 1;
        // Upstream silently stops here. In the native API incomplete work is an error.
        if (calls.* >= 4096 or recursion >= 40) return error.GeometryWorkLimit;
        var a = first;
        var b = second;
        var u_min = u_min_input;
        var u_max = u_max_input;
        const baseline: BaselineDistance = .init(b.p0.x, b.p0.y, b.p3.x - b.p0.x, b.p3.y - b.p0.y);
        const d1 = baseline.at(b.p1.x, b.p1.y);
        const d2 = baseline.at(b.p2.x, b.p2.y);
        const factor: f64 = if (d1 * d2 > 0) 3.0 / 4.0 else 4.0 / 9.0;
        const d_min = factor * @min(0, d1, d2);
        const d_max = factor * @max(0, d1, d2);
        var dp: [4]f64 = undefined;
        inline for ([_]Point{ a.p0, a.p1, a.p2, a.p3 }, 0..) |p, i| {
            dp[i] = baseline.at(p.x, p.y);
        }
        if (d1 == 0 and d2 == 0 and dp[0] == 0 and dp[1] == 0 and dp[2] == 0 and dp[3] == 0) return;
        var hull = convexHull(dp);
        const min_clip = clipHull(hull[0], hull[1], d_min, d_max) orelse return;
        hull[0].reverse();
        hull[1].reverse();
        const max_clip = clipHull(hull[0], hull[1], d_min, d_max) orelse return;
        var t_min_new = t_min + (t_max - t_min) * min_clip;
        var t_max_new = t_min + (t_max - t_min) * max_clip;
        if (@max(u_max - u_min, t_max_new - t_min_new) < 1e-9) {
            const t = (t_min_new + t_max_new) / 2;
            const u = (u_min + u_max) / 2;
            try self.addLocation(if (flip) c2 else c1, if (flip) u else t, if (flip) c1 else c2, if (flip) t else u, false);
            return;
        }
        a = curve.getPart(&a, min_clip, max_clip);
        const u_difference = u_max - u_min;
        if (max_clip - min_clip > 0.8) {
            const is_next = self.epsilon != 0 and t_max_new == 1 and u_min == 0 and self.sources[c1].next == c2;
            const is_previous = self.epsilon != 0 and !is_next and t_min_new == 0 and u_max == 1 and self.sources[c2].next == c1;
            if (is_next or is_previous) {
                const offset = if (is_next) self.epsilon else -self.epsilon;
                const s1 = curve.getTimeAt(&a, -offset, null);
                const s2 = curve.getTimeAt(&b, offset, null);
                if (s1 != null and s2 != null) {
                    const t = t_min_new + (t_max_new - t_min_new) * s1.?;
                    const u = u_min + (u_max - u_min) * s2.?;
                    if (is_next) {
                        a = curve.getPart(&a, 0, s1.?);
                        b = curve.getPart(&b, s2.?, 1);
                        t_max_new = t;
                        u_min = u;
                    } else {
                        a = curve.getPart(&a, s1.?, 1);
                        b = curve.getPart(&b, 0, s2.?);
                        t_min_new = t;
                        u_max = u;
                    }
                    try self.addCurveIntersections(a, b, c1, c2, flip, recursion, calls, t_min_new, t_max_new, u_min, u_max);
                }
            } else if (!(self.epsilon != 0 and try self.addImplicitIntersections(a, b, c1, c2, flip, t_min_new, t_max_new, u_min, u_max))) {
                if (t_max_new - t_min_new > u_difference) {
                    const parts = a.split(0.5);
                    const t = (t_min_new + t_max_new) / 2;
                    try self.addCurveIntersections(b, parts.left, c2, c1, !flip, recursion, calls, u_min, u_max, t_min_new, t);
                    try self.addCurveIntersections(b, parts.right, c2, c1, !flip, recursion, calls, u_min, u_max, t, t_max_new);
                } else {
                    const parts = b.split(0.5);
                    const u = (u_min + u_max) / 2;
                    try self.addCurveIntersections(parts.left, a, c2, c1, !flip, recursion, calls, u_min, u, t_min_new, t_max_new);
                    try self.addCurveIntersections(parts.right, a, c2, c1, !flip, recursion, calls, u, u_max, t_min_new, t_max_new);
                }
            }
        } else if (u_difference == 0 or u_difference >= 1e-9) {
            try self.addCurveIntersections(b, a, c2, c1, !flip, recursion, calls, u_min, u_max, t_min_new, t_max_new);
        } else try self.addCurveIntersections(a, b, c1, c2, flip, recursion, calls, t_min_new, t_max_new, u_min, u_max);
    }

    fn addImplicitIntersections(self: *Builder, a: Cubic, b: Cubic, c1: usize, c2: usize, flip: bool, t_min: f64, t_max: f64, u_min: f64, u_max: f64) !bool {
        const x0 = b.p0.x;
        const y0 = b.p0.y;
        var size: f64 = 0;
        inline for ([_]struct { a: Point, b: Point }{
            .{ .a = a.p0, .b = b.p0 },
            .{ .a = a.p1, .b = b.p1 },
            .{ .a = a.p2, .b = b.p2 },
            .{ .a = a.p3, .b = b.p3 },
        }) |points| {
            size = @max(size, @abs(points.a.x - x0), @abs(points.a.y - y0), @abs(points.b.x - x0), @abs(points.b.y - y0));
        }
        if (size == 0) return false;
        const p = localPoints(a, x0, y0, size);
        const q = localPoints(b, x0, y0, size);
        const dx = b.p3.x - 3 * (b.p2.x - b.p1.x) - x0;
        const dy = b.p3.y - 3 * (b.p2.y - b.p1.y) - y0;
        const is_quadratic = 4.0 / 27.0 * @sqrt(dx * dx + dy * dy) <= self.epsilon;
        const polynomial = if (is_quadratic)
            quadraticImplicit(p, .{ q[0], quadraticHandle(q), q[3] })
        else
            cubicImplicit(p, q);
        var speed: f64 = 0;
        inline for ([_]struct { a: Point, b: Point }{
            .{ .a = a.p0, .b = a.p1 },
            .{ .a = a.p1, .b = a.p2 },
            .{ .a = a.p2, .b = a.p3 },
        }) |segment| {
            const x = segment.b.x - segment.a.x;
            const y = segment.b.y - segment.a.y;
            speed = @max(speed, 3 * @sqrt(x * x + y * y));
        }
        const all_zero = for (polynomial.coefficients[0..polynomial.len], polynomial.errors[0..polynomial.len]) |coefficient, err| {
            if (@abs(coefficient) > err) break false;
        } else true;
        if (all_zero) return false;
        self.roots.clearRetainingCapacity();
        const count = try numerical.solveBernstein(self.allocator, polynomial.coefficients[0..polynomial.len], polynomial.errors[0..polynomial.len], &self.roots, if (speed != 0) self.epsilon / speed else 1);
        for (self.roots.items[0..count]) |root| {
            if (curve.getTimeOf(&b, curve.getPoint(&a, root), self.epsilon)) |other| {
                const t = t_min + (t_max - t_min) * root;
                const u = u_min + (u_max - u_min) * other;
                try self.addLocation(if (flip) c2 else c1, if (flip) u else t, if (flip) c1 else c2, if (flip) t else u, false);
            }
        }
        return true;
    }

    fn pair(self: *Builder, c1: usize, c2: usize) !void {
        const a = &self.sources[c1].cubic;
        const b = &self.sources[c2].cubic;
        const box1 = a.controlBounds();
        const box2 = b.controlBounds();
        const epsilon = numerical.getEpsilon(@max(@abs(box1.min.x), @abs(box1.min.y), @abs(box1.max.x), @abs(box1.max.y), @abs(box2.min.x), @abs(box2.min.y), @abs(box2.max.x), @abs(box2.max.y)), null);
        const bounds_epsilon = @max(epsilon, if (self.epsilon != 0) self.epsilon else 1e-7);
        if (!(box1.max.x + bounds_epsilon > box2.min.x and box1.min.x - bounds_epsilon < box2.max.x and
            box1.max.y + bounds_epsilon > box2.min.y and box1.min.y - bounds_epsilon < box2.max.y)) return;
        const shared = sharedEndpoint(a, b);
        const relation = hullRelation(a, b, shared, if (self.epsilon != 0) self.epsilon else 1e-7, self.magnitude);
        if (relation == .disjoint) return;
        if (relation == .touch) {
            // The certificate proves the shared endpoint is the only common
            // point, so the exact endpoint is the complete intersection.
            const endpoint = shared.?;
            try self.addLocation(c1, endpoint.first_time, c2, endpoint.second_time, false);
            return;
        }
        var queries: Pair = .{ .cubics = .{ a, b }, .epsilon = if (self.epsilon != 0) self.epsilon else 1e-7 };
        if (queries.overlaps()) |overlaps| {
            for (overlaps) |entry| try self.addLocation(c1, entry[0], c2, entry[1], true);
            return;
        }
        const straight1 = curve.isStraight(a);
        const straight2 = curve.isStraight(b);
        const straight = straight1 and straight2;
        const flip = straight1 and !straight2;
        const before = self.events.items.len;
        if (straight) {
            try self.addLineIntersection(a, b, c1, c2);
        } else if (straight1 or straight2) {
            try self.addCurveLineIntersections(if (flip) b else a, if (flip) a else b, if (flip) c2 else c1, if (flip) c1 else c2, flip);
        } else {
            var calls: usize = 0;
            try self.addCurveIntersections(a.*, b.*, c1, c2, false, 0, &calls, 0, 1, 0, 1);
        }
        if (!straight or self.events.items.len == before) {
            const end_epsilon = if (self.epsilon != 0) self.epsilon else epsilon;
            const endpoints = [_]struct { point: Point, other: geometry.BBox, time: f64, second: bool }{
                .{ .point = a.p0, .other = box2, .time = 0, .second = false },
                .{ .point = a.p3, .other = box2, .time = 1, .second = false },
                .{ .point = b.p0, .other = box1, .time = 0, .second = true },
                .{ .point = b.p3, .other = box1, .time = 1, .second = true },
            };
            for (endpoints, 0..) |endpoint, index| {
                if (endpoint.point.x >= endpoint.other.min.x - end_epsilon and endpoint.point.x <= endpoint.other.max.x + end_epsilon and
                    endpoint.point.y >= endpoint.other.min.y - end_epsilon and endpoint.point.y <= endpoint.other.max.y + end_epsilon)
                {
                    if (queries.endpoint(index, end_epsilon)) |u|
                        try self.addLocation(c1, if (endpoint.second) u else endpoint.time, c2, if (endpoint.second) endpoint.time else u, false);
                }
            }
        }
    }
};

/// Sources are closed contours in original contour/curve order. Candidates
/// are the sorted, symmetric upstream bounds lists, including each curve itself.
/// Returns owned paired locations; an error never returns partial geometry.
pub fn collect(allocator: Allocator, scratch: Allocator, sources: []const Source, candidates: []const std.ArrayList(usize), epsilon: f64) !std.ArrayList(Event) {
    if (candidates.len != sources.len) return error.InvalidPath;
    var magnitude: f64 = 1;
    for (sources) |*source| {
        inline for ([_]Point{ source.cubic.p0, source.cubic.p1, source.cubic.p2, source.cubic.p3 }) |point| {
            magnitude = @max(magnitude, @abs(point.x), @abs(point.y));
        }
    }
    var builder: Builder = .{ .allocator = allocator, .scratch = scratch, .sources = sources, .epsilon = epsilon, .magnitude = magnitude };
    defer builder.deinit();
    for (sources, 0..) |*source, index| {
        if (curve.selfIntersectionTimes(&source.cubic)) |times|
            try builder.addLocation(index, times[0], index, times[1], false);
        for (candidates[index].items) |other| {
            if (other > index) try builder.pair(index, other);
        }
    }
    const result = builder.events;
    builder.events = .empty;
    return result;
}

const BaselineDistance = struct {
    px: f64,
    py: f64,
    vx: f64,
    vy: f64,
    denominator: f64,

    fn init(px: f64, py: f64, vx: f64, vy: f64) BaselineDistance {
        const denominator = if (vx == 0 or vy == 0) 0 else if (vy > vx)
            @abs(vy) * @sqrt(1 + (vx * vx) / (vy * vy))
        else
            @abs(vx) * @sqrt(1 + (vy * vy) / (vx * vx));
        return .{ .px = px, .py = py, .vx = vx, .vy = vy, .denominator = denominator };
    }

    fn at(self: BaselineDistance, x: f64, y: f64) f64 {
        if (self.vx == 0) return if (self.vy > 0) x - self.px else self.px - x;
        if (self.vy == 0) return if (self.vx < 0) y - self.py else self.py - y;
        return ((x - self.px) * self.vy - (y - self.py) * self.vx) / self.denominator;
    }
};

fn signedDistance(px: f64, py: f64, vx: f64, vy: f64, x: f64, y: f64) f64 {
    return BaselineDistance.init(px, py, vx, vy).at(x, y);
}

const HullRelation = enum { disjoint, touch, overlap };
const SharedEndpoint = struct { point: Point, first_time: f64, second_time: f64 };

fn sharedEndpoint(a: *const Cubic, b: *const Cubic) ?SharedEndpoint {
    var found: ?SharedEndpoint = null;
    var count: usize = 0;
    if (a.p0.eql(b.p0)) {
        found = .{ .point = a.p0, .first_time = 0, .second_time = 0 };
        count += 1;
    }
    if (a.p3.eql(b.p0)) {
        found = .{ .point = a.p3, .first_time = 1, .second_time = 0 };
        count += 1;
    }
    if (a.p0.eql(b.p3)) {
        found = .{ .point = a.p0, .first_time = 0, .second_time = 1 };
        count += 1;
    }
    if (a.p3.eql(b.p3)) {
        found = .{ .point = a.p3, .first_time = 1, .second_time = 1 };
        count += 1;
    }
    // A second shared endpoint can be a second intersection; keep the general
    // path for that case.
    if (count != 1 or found == null) return null;
    return found;
}

const HalfPlane = enum { positive, negative, zero, ambiguous };

/// Conservative half-plane classification. A value outside the rounded dot
/// product's error bound has a reliable sign. Only zero operands establish a
/// structural zero; rounded products may underflow and must remain ambiguous.
fn halfPlane(x: f64, y: f64, origin: Point, nx: f64, ny: f64) HalfPlane {
    const dx = x - origin.x;
    const dy = y - origin.y;
    const first = dx * nx;
    const second = dy * ny;
    const zero: @Vector(2, f64) = @splat(0);
    const delta: @Vector(2, f64) = .{ dx, dy };
    const normal: @Vector(2, f64) = .{ nx, ny };
    const structural_zero = @select(bool, normal == zero, @as(@Vector(2, bool), @splat(true)), delta == zero);
    if (@reduce(.And, structural_zero)) return .zero;
    const value = first + second;
    // Round the bound outward; the absolute term also covers subnormal
    // subtraction and multiplication.
    const bound = 256 * numerical.MACHINE_EPSILON *
        ((@abs(x) + @abs(origin.x)) * @abs(nx) + (@abs(y) + @abs(origin.y)) * @abs(ny) + 1);
    if (value > bound) return .positive;
    if (value < -bound) return .negative;
    return .ambiguous;
}

/// Sufficient control-hull relation for two cubics. A cubic lies inside the
/// convex hull of its controls, so a separating line proves disjointness. For
/// a single shared endpoint, a line through it with all controls of one curve
/// on one side and all controls of the other on the other side proves the
/// curves meet only there: the Bernstein basis keeps each curve strictly on
/// its side for all interior parameters, and neither other endpoint is shared.
/// Every control-point pair supplies a candidate normal; the convex hull's
/// edge normals are a subset, so a separating hull edge is always tried.
/// Projection gaps are rounded outward. A disjoint result can only reject
/// work that cannot contribute an accepted event; a touch result replaces a
/// provably unique endpoint search with that exact endpoint.
fn hullRelation(a: *const Cubic, b: *const Cubic, shared: ?SharedEndpoint, threshold: f64, magnitude: f64) HullRelation {
    const coordinate_error = 256 * numerical.MACHINE_EPSILON * magnitude;
    for ([_]*const Cubic{ a, b }) |values| {
        const candidates = [_]struct { a: Point, b: Point }{
            .{ .a = values.p0, .b = values.p1 },
            .{ .a = values.p0, .b = values.p2 },
            .{ .a = values.p0, .b = values.p3 },
            .{ .a = values.p1, .b = values.p2 },
            .{ .a = values.p1, .b = values.p3 },
            .{ .a = values.p2, .b = values.p3 },
        };
        for (candidates) |candidate| {
            {
                const dx = candidate.a.x - candidate.b.x;
                const dy = candidate.a.y - candidate.b.y;
                if (dx != 0 or dy != 0) {
                    const nx = -dy;
                    const ny = dx;
                    var first = [4]f64{ undefined, undefined, undefined, undefined };
                    var second = [4]f64{ undefined, undefined, undefined, undefined };
                    var low_a = std.math.inf(f64);
                    var high_a = -std.math.inf(f64);
                    var low_b = std.math.inf(f64);
                    var high_b = -std.math.inf(f64);
                    var largest: f64 = 0;
                    inline for ([_]struct { a: Point, b: Point }{
                        .{ .a = a.p0, .b = b.p0 },
                        .{ .a = a.p1, .b = b.p1 },
                        .{ .a = a.p2, .b = b.p2 },
                        .{ .a = a.p3, .b = b.p3 },
                    }, 0..) |points, k| {
                        first[k] = points.a.x * nx + points.a.y * ny;
                        second[k] = points.b.x * nx + points.b.y * ny;
                        low_a = @min(low_a, first[k]);
                        high_a = @max(high_a, first[k]);
                        low_b = @min(low_b, second[k]);
                        high_b = @max(high_b, second[k]);
                        largest = @max(largest, @abs(first[k]), @abs(second[k]));
                    }
                    const span = @abs(nx) + @abs(ny);
                    const margin = (threshold + coordinate_error) * span + 256 * numerical.MACHINE_EPSILON * largest;
                    if (high_a + margin < low_b or high_b + margin < low_a) return .disjoint;
                    if (shared) |endpoint| {
                        var a_nonpositive = true;
                        var a_nonnegative = true;
                        var a_negative = false;
                        var a_positive = false;
                        var b_nonpositive = true;
                        var b_nonnegative = true;
                        var b_negative = false;
                        var b_positive = false;
                        var ambiguous = false;
                        inline for ([_]struct { a: Point, b: Point }{
                            .{ .a = a.p0, .b = b.p0 },
                            .{ .a = a.p1, .b = b.p1 },
                            .{ .a = a.p2, .b = b.p2 },
                            .{ .a = a.p3, .b = b.p3 },
                        }) |points| {
                            switch (halfPlane(points.a.x, points.a.y, endpoint.point, nx, ny)) {
                                .positive => {
                                    a_nonpositive = false;
                                    a_positive = true;
                                },
                                .negative => {
                                    a_nonnegative = false;
                                    a_negative = true;
                                },
                                .zero => {},
                                .ambiguous => ambiguous = true,
                            }
                            switch (halfPlane(points.b.x, points.b.y, endpoint.point, nx, ny)) {
                                .positive => {
                                    b_nonpositive = false;
                                    b_positive = true;
                                },
                                .negative => {
                                    b_nonnegative = false;
                                    b_negative = true;
                                },
                                .zero => {},
                                .ambiguous => ambiguous = true,
                            }
                        }
                        if (!ambiguous and ((a_nonpositive and a_negative and b_nonnegative and b_positive) or
                            (b_nonpositive and b_negative and a_nonnegative and a_positive))) return .touch;
                    }
                }
            }
        }
    }
    return .overlap;
}

fn lineIntersection(a: *const Cubic, b: *const Cubic) ?Point {
    const vx1 = a.p3.x - a.p0.x;
    const vy1 = a.p3.y - a.p0.y;
    const vx2 = b.p3.x - b.p0.x;
    const vy2 = b.p3.y - b.p0.y;
    const cross = vx1 * vy2 - vy1 * vx2;
    if (@abs(cross) <= 1.12e-16) return null;
    const dx = a.p0.x - b.p0.x;
    const dy = a.p0.y - b.p0.y;
    var first_parameter = (vx2 * dy - vy2 * dx) / cross;
    const second_parameter = (vx1 * dy - vy1 * dx) / cross;
    if (!(-1e-12 < first_parameter and first_parameter < 1 + 1e-12 and -1e-12 < second_parameter and second_parameter < 1 + 1e-12)) return null;
    first_parameter = numerical.clamp(first_parameter, 0, 1);
    return .{ .x = a.p0.x + first_parameter * vx1, .y = a.p0.y + first_parameter * vy1 };
}

const LineTimes = struct { items: [5]f64 = undefined, len: usize = 0 };
fn lineTimes(v: *const Cubic, px: f64, py: f64, vx: f64, vy: f64) LineTimes {
    var result: LineTimes = .{};
    if (numerical.isZero(vx) and numerical.isZero(vy)) {
        if (curve.getTimeOf(v, .{ .x = px, .y = py }, null)) |time| {
            result.items[0] = time;
            result.len = 1;
        }
        return result;
    }
    const angle = std.math.atan2(-vy, vx);
    const sine = @sin(angle);
    const cosine = @cos(angle);
    var rotated = Cubic{
        .p0 = undefined,
        .p1 = undefined,
        .p2 = undefined,
        .p3 = undefined,
    };
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }, 0..) |point, i| {
        const x = point.x - px;
        const y = point.y - py;
        const rx = x * cosine - y * sine;
        const ry = x * sine + y * cosine;
        switch (i) {
            0 => rotated.p0 = .{ .x = rx, .y = ry },
            1 => rotated.p1 = .{ .x = rx, .y = ry },
            2 => rotated.p2 = .{ .x = rx, .y = ry },
            3 => rotated.p3 = .{ .x = rx, .y = ry },
            else => unreachable,
        }
    }
    var roots: [3]f64 = undefined;
    const count = curve.solveCubic(&rotated, 1, 0, &roots, 0, 1);
    result.len = @intCast(@max(0, count));
    @memcpy(result.items[0..result.len], roots[0..result.len]);
    if (@abs(rotated.p0.y) < 1e-7) {
        result.items[result.len] = 0;
        result.len += 1;
    }
    if (@abs(rotated.p3.y) < 1e-7) {
        result.items[result.len] = 1;
        result.len += 1;
    }
    return result;
}

fn squaredLineLength(v: *const Cubic) f64 {
    const x = v.p3.x - v.p0.x;
    const y = v.p3.y - v.p0.y;
    return x * x + y * y;
}

const Pair = struct {
    cubics: [2]*const Cubic,
    epsilon: f64,
    times: [4]?f64 = undefined,
    computed: [4]bool = .{ false, false, false, false },

    // Indices name a0, a1, b0, b1 tested against the opposite curve. A cached
    // null is a completed miss. Results from different tolerances never mix.
    fn endpoint(self: *const Pair, index: usize, epsilon: f64) ?f64 {
        return if (epsilon == self.epsilon and self.computed[index]) self.times[index] else self.query(index, epsilon);
    }

    fn query(self: *const Pair, index: usize, epsilon: f64) ?f64 {
        const source = index >> 1;
        const v = self.cubics[source];
        const point = if (index & 1 != 0) v.p3 else v.p0;
        return curve.getTimeOf(self.cubics[source ^ 1], point, epsilon);
    }

    fn overlaps(self: *Pair) ?[2][2]f64 {
        const a = self.cubics[0];
        const b = self.cubics[1];
        const epsilon = self.epsilon;
        var straight1 = curve.isStraight(a);
        var straight2 = curve.isStraight(b);
        var both = straight1 and straight2;
        const flip = squaredLineLength(a) < squaredLineLength(b);
        const l1 = if (flip) b else a;
        const l2 = if (flip) a else b;
        const px = l1.p0.x;
        const py = l1.p0.y;
        const vx = l1.p3.x - px;
        const vy = l1.p3.y - py;
        if (@abs(signedDistance(px, py, vx, vy, l2.p0.x, l2.p0.y)) < epsilon and
            @abs(signedDistance(px, py, vx, vy, l2.p3.x, l2.p3.y)) < epsilon)
        {
            if (!both and @abs(signedDistance(px, py, vx, vy, l1.p1.x, l1.p1.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l1.p2.x, l1.p2.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l2.p1.x, l2.p1.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l2.p2.x, l2.p2.y)) < epsilon)
            {
                straight1 = true;
                straight2 = true;
                both = true;
            }
        } else if (both) return null;
        if (straight1 != straight2) return null;
        var pairs: [2][2]f64 = undefined;
        var length: usize = 0;
        var i: usize = 0;
        while (i < 4 and length < 2) : (i += 1) {
            const first_index = i & 1;
            const second_index = first_index ^ 1;
            const t1: f64 = @floatFromInt(i >> 1);
            const endpoint_index = (second_index << 1) | (i >> 1);
            const time = self.query(endpoint_index, epsilon);
            self.times[endpoint_index] = time;
            self.computed[endpoint_index] = true;
            if (time) |t2| {
                const pair_: [2]f64 = if (first_index != 0) .{ t1, t2 } else .{ t2, t1 };
                if (length == 0 or (@abs(pair_[0] - pairs[0][0]) > 1e-8 and @abs(pair_[1] - pairs[0][1]) > 1e-8)) {
                    pairs[length] = pair_;
                    length += 1;
                }
            }
            if (i > 2 and length == 0) break;
        }
        if (length != 2) return null;
        if (!both) {
            const first = curve.getPart(a, pairs[0][0], pairs[1][0]);
            const second = curve.getPart(b, pairs[0][1], pairs[1][1]);
            if (@abs(second.p1.x - first.p1.x) > epsilon or @abs(second.p1.y - first.p1.y) > epsilon or
                @abs(second.p2.x - first.p2.x) > epsilon or @abs(second.p2.y - first.p2.y) > epsilon) return null;
        }
        return pairs;
    }
};

test "pair endpoint memo separates completed misses and tolerance changes" {
    const t = std.testing;
    const a: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 0 }, .p2 = .{ .x = 10, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    const b: Cubic = .{ .p0 = .{ .x = 5, .y = 0 }, .p1 = .{ .x = 5, .y = 0 }, .p2 = .{ .x = 15, .y = 0 }, .p3 = .{ .x = 15, .y = 0 } };
    var pair: Pair = .{ .cubics = .{ &a, &b }, .epsilon = 1e-12 };
    _ = pair.overlaps();
    const expected = [_]?f64{ null, 0.5, 0.5, null };
    for (expected, 0..) |time, index| {
        try t.expectEqual(time, pair.endpoint(index, 1e-12));
        try t.expect(pair.computed[index]);
        try t.expectEqual(time, pair.endpoint(index, 1e-12));
    }
    const nearby: Cubic = .{ .p0 = .{ .x = 0, .y = 1e-8 }, .p1 = .{ .x = 0, .y = 1e-8 }, .p2 = .{ .x = 10, .y = 1e-8 }, .p3 = .{ .x = 10, .y = 1e-8 } };
    var distinct_tolerances: Pair = .{ .cubics = .{ &a, &nearby }, .epsilon = 1e-7 };
    _ = distinct_tolerances.overlaps();
    try t.expectEqual(@as(?f64, 0), distinct_tolerances.endpoint(2, 1e-7));
    try t.expectEqual(@as(?f64, null), distinct_tolerances.endpoint(2, 1e-12));
    try t.expectEqual(@as(?f64, 0), distinct_tolerances.endpoint(2, 1e-7));
}

const Hull = struct {
    points: [4]Point = undefined,
    len: usize,
    fn init(points: []const Point) Hull {
        var result: Hull = .{ .len = points.len };
        @memcpy(result.points[0..points.len], points);
        return result;
    }
    fn reverse(self: *Hull) void {
        std.mem.reverse(Point, self.points[0..self.len]);
    }
};

fn convexHull(d: [4]f64) [2]Hull {
    const p0: Point = .{ .x = 0, .y = d[0] };
    const p1: Point = .{ .x = 1.0 / 3.0, .y = d[1] };
    const p2: Point = .{ .x = 2.0 / 3.0, .y = d[2] };
    const p3: Point = .{ .x = 1, .y = d[3] };
    const dist1 = d[1] - (2 * d[0] + d[3]) / 3;
    const dist2 = d[2] - (d[0] + 2 * d[3]) / 3;
    var result: [2]Hull = undefined;
    if (dist1 * dist2 < 0) {
        result = .{ Hull.init(&.{ p0, p1, p3 }), Hull.init(&.{ p0, p2, p3 }) };
    } else {
        const ratio = dist1 / dist2;
        result = .{ if (ratio >= 2) Hull.init(&.{ p0, p1, p3 }) else if (ratio <= 0.5) Hull.init(&.{ p0, p2, p3 }) else Hull.init(&.{ p0, p1, p2, p3 }), Hull.init(&.{ p0, p3 }) };
    }
    if ((if (dist1 != 0) dist1 else dist2) < 0) std.mem.swap(Hull, &result[0], &result[1]);
    return result;
}

fn clipHull(top: Hull, bottom: Hull, minimum: f64, maximum: f64) ?f64 {
    return if (top.points[0].y < minimum) clipHullPart(top, true, minimum) else if (bottom.points[0].y > maximum) clipHullPart(bottom, false, maximum) else top.points[0].x;
}

fn clipHullPart(part: Hull, top: bool, threshold: f64) ?f64 {
    var p = part.points[0];
    for (part.points[1..part.len]) |q| {
        if (if (top) q.y >= threshold else q.y <= threshold)
            return if (q.y == threshold) q.x else p.x + (threshold - p.y) * (q.x - p.x) / (q.y - p.y);
        p = q;
    }
    return null;
}

const ErrorPoint = struct { x: f64, y: f64, ex: f64, ey: f64 };
const Polynomial = struct { coefficients: [10]f64 = undefined, errors: [10]f64 = undefined, len: usize };
const roundoff = 1.12e-16;

fn localPoints(v: Cubic, x0: f64, y0: f64, size: f64) [4]ErrorPoint {
    var points: [4]ErrorPoint = undefined;
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }, 0..) |source, i| {
        const x = (source.x - x0) / size;
        const y = (source.y - y0) / size;
        points[i] = .{ .x = x, .y = y, .ex = 2 * roundoff * @abs(x), .ey = 2 * roundoff * @abs(y) };
    }
    return points;
}

fn productError(a: f64, ea: f64, b: f64, eb: f64) f64 {
    return @abs(a) * eb + @abs(b) * ea + ea * eb + roundoff * @abs(a * b);
}

fn linearFactor(p: [4]ErrorPoint, q: []const ErrorPoint, i: usize, j: usize, factor: f64) Polynomial {
    var result: Polynomial = .{ .len = 4 };
    for (p, 0..) |r, k| {
        const dx1 = q[i].x - r.x;
        const dy1 = q[j].y - r.y;
        const dx2 = q[j].x - r.x;
        const dy2 = q[i].y - r.y;
        const error1 = productError(dx1, q[i].ex + r.ex + roundoff * @abs(dx1), dy1, q[j].ey + r.ey + roundoff * @abs(dy1));
        const error2 = productError(dx2, q[j].ex + r.ex + roundoff * @abs(dx2), dy2, q[i].ey + r.ey + roundoff * @abs(dy2));
        const difference = dx1 * dy1 - dx2 * dy2;
        const value = factor * difference;
        result.coefficients[k] = value;
        result.errors[k] = factor * (error1 + error2 + roundoff * @abs(difference)) + roundoff * @abs(value);
    }
    return result;
}

const binomials = blk: {
    var rows: [10][10]f64 = @splat(@splat(0));
    rows[0][0] = 1;
    for (1..10) |i| {
        rows[i][0] = 1;
        for (1..i) |j| rows[i][j] = rows[i - 1][j - 1] + rows[i - 1][j];
        rows[i][i] = 1;
    }
    break :blk rows;
};

fn multiply(a: Polynomial, b: Polynomial) Polynomial {
    const m = a.len - 1;
    const n = b.len - 1;
    var result: Polynomial = .{ .len = m + n + 1 };
    for (0..result.len) |k| {
        var sum: f64 = 0;
        var err: f64 = 0;
        var i = k -| n;
        while (i <= @min(m, k)) : (i += 1) {
            const factor = binomials[m][i] * binomials[n][k - i] / binomials[m + n][k];
            const a1 = a.coefficients[i];
            const b1 = b.coefficients[k - i];
            const term = factor * (a1 * b1);
            sum += term;
            err += factor * productError(a1, a.errors[i], b1, b.errors[k - i]) + roundoff * (2 * @abs(term) + @abs(sum));
        }
        result.coefficients[k] = sum;
        result.errors[k] = err;
    }
    return result;
}

fn add(a: Polynomial, b: Polynomial, sign: f64) Polynomial {
    std.debug.assert(a.len == b.len);
    var result: Polynomial = .{ .len = a.len };
    for (0..a.len) |i| {
        const sum = a.coefficients[i] + sign * b.coefficients[i];
        result.coefficients[i] = sum;
        result.errors[i] = a.errors[i] + b.errors[i] + roundoff * @abs(sum);
    }
    return result;
}

fn cubicImplicit(p: [4]ErrorPoint, q: [4]ErrorPoint) Polynomial {
    const l32 = linearFactor(p, &q, 3, 2, 3);
    const l31 = linearFactor(p, &q, 3, 1, 3);
    const l30 = linearFactor(p, &q, 3, 0, 1);
    const l21 = linearFactor(p, &q, 2, 1, 9);
    const l20 = linearFactor(p, &q, 2, 0, 3);
    const l10 = linearFactor(p, &q, 1, 0, 3);
    const m = add(l30, l21, 1);
    return add(add(multiply(l32, add(multiply(m, l10), multiply(l20, l20), -1)), multiply(l31, add(multiply(l31, l10), multiply(l20, l30), -1)), -1), multiply(l30, add(multiply(l31, l20), multiply(m, l30), -1)), 1);
}

fn quadraticHandle(q: [4]ErrorPoint) ErrorPoint {
    const x = (3 * q[1].x - q[0].x) / 2;
    const y = (3 * q[1].y - q[0].y) / 2;
    return .{ .x = x, .y = y, .ex = (3 * q[1].ex + q[0].ex) / 2 + 2 * roundoff * @abs(x), .ey = (3 * q[1].ey + q[0].ey) / 2 + 2 * roundoff * @abs(y) };
}

fn quadraticImplicit(p: [4]ErrorPoint, q: [3]ErrorPoint) Polynomial {
    const l21 = linearFactor(p, &q, 2, 1, 2);
    const l20 = linearFactor(p, &q, 2, 0, 1);
    const l10 = linearFactor(p, &q, 1, 0, 2);
    return add(multiply(l21, l10), multiply(l20, l20), -1);
}

test "paired intersections: fat-line and implicit Bernstein retain both quadratic crossings" {
    const t = std.testing;
    // x=3t in both curves, y=6t(1-t) and y=1-6t(1-t).
    // Intersections solve t(1-t)=1/12 and therefore have y=1/2.
    const sources = [_]Source{
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 1, .y = 2 }, .p2 = .{ .x = 2, .y = 2 }, .p3 = .{ .x = 3, .y = 0 } }, .next = 0, .contour = 0, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 1 }, .p1 = .{ .x = 1, .y = -1 }, .p2 = .{ .x = 2, .y = -1 }, .p3 = .{ .x = 3, .y = 1 } }, .next = 1, .contour = 1, .operand = 1 },
    };
    for ([_]bool{ false, true }) |implicit| {
        var builder: Builder = .{ .allocator = t.allocator, .scratch = t.allocator, .sources = &sources, .epsilon = 1e-10 };
        defer builder.deinit();
        if (implicit) {
            try t.expect(try builder.addImplicitIntersections(sources[0].cubic, sources[1].cubic, 0, 1, false, 0, 1, 0, 1));
        } else {
            var calls: usize = 0;
            try builder.addCurveIntersections(sources[0].cubic, sources[1].cubic, 0, 1, false, 0, &calls, 0, 1, 0, 1);
        }
        try t.expectEqual(@as(usize, 2), builder.events.items.len);
        for (builder.events.items, [_]f64{ (1 - @sqrt(@as(f64, 2.0 / 3.0))) / 2, (1 + @sqrt(@as(f64, 2.0 / 3.0))) / 2 }) |event, expected| {
            try t.expectApproxEqAbs(expected, event.first.location.time, 1e-9);
            try t.expectApproxEqAbs(expected, event.second.location.time, 1e-9);
            try t.expectApproxEqAbs(@as(f64, 0.5), event.point.y, 1e-9);
        }
    }
}

test "half-plane certificate keeps underflow ambiguous" {
    const t = std.testing;
    const tiny: f64 = @bitCast(@as(u64, 1));
    for ([_]f64{ tiny, -tiny }) |value| {
        try t.expectEqual(HalfPlane.ambiguous, halfPlane(value, 0, .zero, 0.5, 0));
        try t.expectEqual(HalfPlane.ambiguous, halfPlane(0, value, .zero, 0, 0.5));
    }
    try t.expectEqual(HalfPlane.zero, halfPlane(0, tiny, .zero, 0.5, 0));
    try t.expectEqual(HalfPlane.zero, halfPlane(tiny, 0, .zero, 0, 0.5));
}

test "control-hull certificate separates disjoint curves and leaves crossings" {
    const t = std.testing;
    const above: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 3 }, .p2 = .{ .x = 10, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    const below: Cubic = .{ .p0 = .{ .x = 0, .y = -10 }, .p1 = .{ .x = 0, .y = -7 }, .p2 = .{ .x = 10, .y = -7 }, .p3 = .{ .x = 10, .y = -10 } };
    try t.expectEqual(HullRelation.disjoint, hullRelation(&above, &below, null, 0.01, 10));
    const diagonal: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 3, .y = 3 }, .p2 = .{ .x = 7, .y = 7 }, .p3 = .{ .x = 10, .y = 10 } };
    const crossing: Cubic = .{ .p0 = .{ .x = 0, .y = 10 }, .p1 = .{ .x = 3, .y = 7 }, .p2 = .{ .x = 7, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expectEqual(HullRelation.overlap, hullRelation(&diagonal, &crossing, null, 0.01, 10));
}

test "shared-endpoint certificate recognizes a single tangency" {
    const t = std.testing;
    const first: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 1 }, .p2 = .{ .x = 1, .y = 1 }, .p3 = .{ .x = 1, .y = 0 } };
    const second: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = -1 }, .p2 = .{ .x = -1, .y = -1 }, .p3 = .{ .x = -1, .y = 0 } };
    const endpoint = sharedEndpoint(&first, &second) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(f64, 0), endpoint.first_time);
    try t.expectEqual(@as(f64, 0), endpoint.second_time);
    try t.expectEqual(HullRelation.touch, hullRelation(&first, &second, endpoint, 1e-6, 1));
    const closed: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 1 }, .p2 = .{ .x = 1, .y = 1 }, .p3 = .{ .x = 1, .y = 0 } };
    try t.expect(sharedEndpoint(&first, &closed) == null);
}

test "chord strip keeps tolerance contacts on both sides and for a zero chord" {
    const t = std.testing;
    const arch: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 3 }, .p2 = .{ .x = 10, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expect(curve.outsideChordStrip(&arch, .{ .x = 5, .y = -1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&arch, .{ .x = 5, .y = -0.1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&arch, .{ .x = 5, .y = 2 }, 0.5));
    var s = arch;
    s.p1.y = -2;
    try t.expect(curve.outsideChordStrip(&s, .{ .x = 5, .y = 4 }, 0.5));
    try t.expect(curve.outsideChordStrip(&s, .{ .x = 5, .y = -3 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&s, .{ .x = 5, .y = 3.5 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&s, .{ .x = 5, .y = -2.5 }, 0.5));
    s.p3 = s.p0;
    try t.expect(!curve.outsideChordStrip(&s, s.at(0.4), 0));
    const tiny = Cubic.line(.zero, .{ .x = 1e-200, .y = 0 });
    try t.expect(!curve.outsideChordStrip(&tiny, .{ .x = 0, .y = 0.1 }, 0.5));
    const line: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 0 }, .p2 = .{ .x = 10, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expect(curve.outsideChordStrip(&line, .{ .x = 5, .y = 1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&line, .{ .x = 5, .y = 0.25 }, 0.5));
}
