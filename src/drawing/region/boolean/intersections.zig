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
const Point = types.Point;
const Source = types.Source;
const Location = types.Location;
const lines = @import("intersections/lines.zig");
const clipping = @import("intersections/clipping.zig");
const certificates = @import("intersections/certificates.zig");
const pair_overlap = @import("intersections/overlap.zig");
const sharedEndpoint = certificates.sharedEndpoint;
const hullRelation = certificates.hullRelation;
const Pair = pair_overlap.Pair;

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

pub const Builder = struct {
    allocator: Allocator,
    sources: []const Source,
    scratch: Allocator,
    lengths: []CurveLength = &.{},
    events: std.ArrayList(Event) = .empty,
    /// The graph's resolution: it unites samples closer than this into one
    /// vertex. Upstream's Boolean operations pass the same kind of value as
    /// the tolerance of the intersection code.
    epsilon: f64,
    // Largest absolute normalized coordinate. Only widens the conservative
    // separation margin; it never participates in event acceptance.
    magnitude: f64 = 0,
    // Reused implicit-polynomial roots scratch; cleared per query.
    roots: std.ArrayList(f64) = .empty,

    pub fn deinit(self: *Builder) void {
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

    pub fn location(self: *Builder, index: usize, time: f64) LocationInfo {
        // CurveLocation.initialize maps an end to the next curve's start.
        const loc: Location = if (time >= 1 - numerical.CURVETIME_EPSILON)
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
        // As CurveLocation.equals: compare offsets along the contour rather
        // than curve times, also across the contour's start.
        const difference = @abs(a.offset - b.offset);
        return difference < numerical.GEOMETRIC_EPSILON or @abs(self.lengths[a.location.curve].total - difference) < numerical.GEOMETRIC_EPSILON;
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
            // As CurveLocation.insert: a neighbour farther away ends the search.
            if (!curve.withinDistance(event.point, candidate.point, numerical.GEOMETRIC_EPSILON)) break;
            if (self.sameEvent(event, candidate)) return true;
        }
        return false;
    }

    pub fn addLocation(self: *Builder, c1: usize, time1: ?f64, c2: usize, time2: ?f64, overlap: bool) !void {
        const t1 = time1 orelse return;
        const t2 = time2 orelse return;
        // Neighbouring curves meet at their shared end, which is not an
        // intersection: as upstream, times within CURVETIME_EPSILON of it are
        // left out.
        const exclude_start = !overlap and self.sources[c2].next == c1;
        const exclude_end = !overlap and c1 != c2 and self.sources[c1].next == c2;
        const t_min = numerical.CURVETIME_EPSILON;
        const t_max = 1 - t_min;
        if (!(t1 >= (if (exclude_start) t_min else 0) and
            t1 <= (if (exclude_end) t_max else 1) and
            t2 >= (if (exclude_end) t_min else 0) and
            t2 <= (if (exclude_start) t_max else 1))) return;
        // The graph unites both locations into one vertex, as it does any two
        // samples within `epsilon`, its resolution. A loop read from rounding
        // noise, or a clipping that narrowed to where the other curve merely
        // touched a fat line, gives two points farther apart; neither is an
        // intersection.
        if (!curve.withinDistance(curve.getPoint(&self.sources[c1].cubic, t1), curve.getPoint(&self.sources[c2].cubic, t2), self.epsilon)) return;
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

    fn pair(self: *Builder, c1: usize, c2: usize) !void {
        const a = &self.sources[c1].cubic;
        const b = &self.sources[c2].cubic;
        const box1 = a.controlBounds();
        const box2 = b.controlBounds();
        const epsilon = numerical.getEpsilon(@max(@abs(box1.min.x), @abs(box1.min.y), @abs(box1.max.x), @abs(box1.max.y), @abs(box2.min.x), @abs(box2.min.y), @abs(box2.max.x), @abs(box2.max.y)), null);
        const bounds_epsilon = @max(epsilon, self.epsilon);
        if (!(box1.max.x + bounds_epsilon > box2.min.x and box1.min.x - bounds_epsilon < box2.max.x and
            box1.max.y + bounds_epsilon > box2.min.y and box1.min.y - bounds_epsilon < box2.max.y)) return;
        const shared = sharedEndpoint(a, b);
        const relation = hullRelation(a, b, shared, self.epsilon, self.magnitude);
        if (relation == .disjoint) return;
        if (relation == .touch) {
            // The certificate proves the shared endpoint is the only common
            // point, so the exact endpoint is the complete intersection.
            const endpoint = shared.?;
            try self.addLocation(c1, endpoint.first_time, c2, endpoint.second_time, false);
            return;
        }
        var queries: Pair = .{ .cubics = .{ a, b }, .epsilon = self.epsilon };
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
            try lines.addLineIntersection(self, a, b, c1, c2);
        } else if (straight1 or straight2) {
            try lines.addCurveLineIntersections(self, if (flip) b else a, if (flip) a else b, if (flip) c2 else c1, if (flip) c1 else c2, flip);
        } else {
            var calls: usize = 0;
            try clipping.addCurveIntersections(self, a.*, b.*, c1, c2, false, 0, &calls, 0, 1, 0, 1);
        }
        if (!straight or self.events.items.len == before) {
            const endpoints = [_]struct { point: Point, other: geometry.BBox, time: f64, second: bool }{
                .{ .point = a.p0, .other = box2, .time = 0, .second = false },
                .{ .point = a.p3, .other = box2, .time = 1, .second = false },
                .{ .point = b.p0, .other = box1, .time = 0, .second = true },
                .{ .point = b.p3, .other = box1, .time = 1, .second = true },
            };
            for (endpoints, 0..) |endpoint, index| {
                if (endpoint.point.x >= endpoint.other.min.x - self.epsilon and endpoint.point.x <= endpoint.other.max.x + self.epsilon and
                    endpoint.point.y >= endpoint.other.min.y - self.epsilon and endpoint.point.y <= endpoint.other.max.y + self.epsilon)
                {
                    if (queries.endpoint(index)) |u|
                        try self.addLocation(c1, if (endpoint.second) u else endpoint.time, c2, if (endpoint.second) endpoint.time else u, false);
                }
            }
        }
    }
};

/// Sources are closed contours in original contour/curve order. Candidates
/// are the sorted, symmetric upstream bounds lists, including each curve itself.
/// `epsilon` is the graph's resolution and the tolerance of every test here.
/// Upstream's Boolean operations always pass a tolerance; its defaults for
/// calls without one serve only `Curve#getIntersections` and are not ported.
/// Returns owned paired locations; an error never returns partial geometry.
pub fn collect(allocator: Allocator, scratch: Allocator, sources: []const Source, candidates: []const std.ArrayList(usize), epsilon: f64) !std.ArrayList(Event) {
    std.debug.assert(epsilon > 0);
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

test "an event joins only locations where both curves pass through one point" {
    const t = std.testing;
    // Curves in the coordinates the region kernel gave them. A straight cubic
    // of a projected rim, which the classification reads as a loop at
    // t = (2 ∓ √3)/5, 10.8 units apart. A side of a curved triangle whose
    // corner lies on the chord of a circle's arc: clipping shrinks the side
    // to that corner, then narrows the arc to where it crosses the corner's
    // x, 12 694 units above it.
    const sources = [_]Source{
        .{ .cubic = .{ .p0 = .{ .x = 10652.415095407923, .y = 14686.415504676315 }, .p1 = .{ .x = 10656.809096489189, .y = 14683.636527923307 }, .p2 = .{ .x = 10661.203097570455, .y = 14680.857551170295 }, .p3 = .{ .x = 10665.59709865172, .y = 14678.078574417286 } }, .next = 0, .contour = 0, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = -22528.000000000004, .y = 8192 }, .p1 = .{ .x = -21407.30161923488, .y = 8192 }, .p2 = .{ .x = -20300.61959722793, .y = 8131.988834333268 }, .p3 = .{ .x = -19210.992112449192, .y = 8015.00468146984 } }, .next = 1, .contour = 1, .operand = 0 },
        .{ .cubic = .{ .p0 = .{ .x = 0, .y = 30720 }, .p1 = .{ .x = -16966.187514801975, .y = 30720 }, .p2 = .{ .x = -30720, .y = 16966.187514801975 }, .p3 = .{ .x = -30720, .y = 0 } }, .next = 2, .contour = 2, .operand = 1 },
    };
    var builder: Builder = .{ .allocator = t.allocator, .scratch = t.allocator, .sources = &sources, .epsilon = 0.008688928127220295 };
    defer builder.deinit();
    const loop = curve.selfIntersectionTimes(&sources[0].cubic) orelse return error.TestUnexpectedResult;
    try builder.addLocation(0, loop[0], 0, loop[1], false);
    var calls: usize = 0;
    try clipping.addCurveIntersections(&builder, sources[1].cubic, sources[2].cubic, 1, 2, false, 0, &calls, 0, 1, 0, 1);
    try t.expectEqual(@as(usize, 0), builder.events.items.len);
}

test {
    _ = @import("intersections/certificates.zig");
    _ = @import("intersections/clipping.zig");
    _ = @import("intersections/overlap.zig");
}
