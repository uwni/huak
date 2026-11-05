// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see LICENSE.
const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../../geometry.zig");
const curves = @import("curve.zig");
const intersection = @import("intersections.zig");
const Point = types.Point;
const Cubic = geometry.Cubic;
const Allocator = types.Allocator;
const none = std.math.maxInt(usize);

const Cut = struct { time: f64, sample: usize };
const Sample = struct { point: Point, parent: usize, vertex: usize = none };
pub const Vertex = struct { point: Point, sample: usize };
pub const Edge = struct {
    cubic: Cubic,
    from: usize,
    to: usize,
    windings: [2]i32,
    curve: usize,
    time1: f64,
    time2: f64,
    straight: bool,
    length: ?f64 = null,
};
pub const HalfEdge = struct {
    edge: usize,
    cubic: *const Cubic,
    from: usize,
    to: usize,
    next: usize = 0,
    face: usize = none,
};
const Directions = struct { start: f64, width: f64 };
const SortEntry = struct { index: usize, directions: Directions = undefined, point: Point = undefined, angle: f64 = undefined };
const Interval = struct { first: Cut, last: Cut };
const Piece = struct { cubic: Cubic, first: Cut, last: Cut };

/// Arrangement stored in the caller's arena; sources stay borrowed through tracing.
/// Completed edges and vertices do not borrow the construction workspace.
pub const Graph = struct {
    sources: []const types.Source,
    vertices: std.ArrayList(Vertex) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    half_edges: std.ArrayList(HalfEdge) = .empty,

    pub fn init(allocator: Allocator, scratch: Allocator, sources: []const types.Source, candidates: []const std.ArrayList(usize), intersections: []const intersection.Event, epsilon: f64) !Graph {
        var result: Graph = .{ .sources = sources };
        var builder: Builder = .{ .graph = &result, .allocator = scratch, .storage = allocator, .sources = sources, .epsilon = epsilon, .cuts = try scratch.alloc(std.ArrayList(Cut), sources.len) };
        try builder.build(candidates, intersections);
        return result;
    }
};

/// Private construction state, owned by the caller's short-lived workspace.
const Builder = struct {
    graph: *Graph,
    allocator: Allocator,
    storage: Allocator,
    sources: []const types.Source,
    epsilon: f64,
    cuts: []std.ArrayList(Cut),
    samples: std.ArrayList(Sample) = .empty,

    fn build(self: *Builder, candidates: []const std.ArrayList(usize), intersections: []const intersection.Event) !void {
        const allocator = self.allocator;
        const sources = self.sources;
        const epsilon = self.epsilon;
        try self.createSamples(intersections);
        try self.createVertices();
        const marks = try allocator.alloc(usize, self.graph.vertices.items.len);
        @memset(marks, none);
        var pixels: std.ArrayList(usize) = .empty;
        var pieces: std.ArrayList(Interval) = .empty;
        for (sources, 0..) |*source, i| {
            pixels.clearRetainingCapacity();
            const bounds = controlBounds(&source.cubic, 2 * epsilon);
            for (candidates[i].items) |other| for (self.cuts[other].items) |cut| {
                const vertex = self.vertexIndex(cut.sample);
                if (marks[vertex] == i) continue;
                marks[vertex] = i;
                if (inBounds(self.graph.vertices.items[vertex].point, bounds)) try pixels.append(allocator, vertex);
            };
            std.mem.sort(usize, pixels.items, {}, std.sort.asc(usize));
            if (pixels.items.len == 0) continue;
            sortCuts(self.cuts[i].items);
            pieces.clearRetainingCapacity();
            const list = self.cuts[i].items;
            for (list[1..], list[0 .. list.len - 1]) |last, first| try pieces.append(allocator, .{ .first = first, .last = last });
            while (pieces.pop()) |interval| {
                const piece = self.makePiece(i, interval.first, interval.last);
                for (pixels.items) |vertex_index| {
                    const vertex = self.graph.vertices.items[vertex_index];
                    if (self.vertexIndex(piece.first.sample) == vertex_index or self.vertexIndex(piece.last.sample) == vertex_index or !inBounds(vertex.point, controlBounds(&piece.cubic, epsilon))) continue;
                    if (curves.beyondChord(&piece.cubic, vertex.point, epsilon)) continue;
                    const time = curves.getNearestTime(&piece.cubic, vertex.point) orelse continue;
                    if (time > 0 and time < 1 and close(vertex.point, curves.getPoint(&piece.cubic, time), epsilon)) {
                        const original_time = if (hasHandles(&source.cubic)) piece.first.time + (piece.last.time - piece.first.time) * time else curves.getNearestTime(&source.cubic, vertex.point) orelse return error.GeometryFailed;
                        const cut: Cut = .{ .time = original_time, .sample = vertex.sample };
                        try self.cuts[i].append(allocator, cut);
                        try pieces.append(allocator, .{ .first = piece.first, .last = cut });
                        try pieces.append(allocator, .{ .first = cut, .last = piece.last });
                        break;
                    }
                }
            }
        }
        var short: std.ArrayList([2]usize) = .empty;
        var edge_capacity: usize = 0;
        for (self.cuts, 0..) |*cuts, i| {
            edge_capacity = try std.math.add(usize, edge_capacity, cuts.items.len - 1);
            sortCuts(cuts.items);
            for (cuts.items[1..], cuts.items[0 .. cuts.items.len - 1]) |last, first| {
                const first_vertex = self.vertexIndex(first.sample);
                const last_vertex = self.vertexIndex(last.sample);
                if (first_vertex == last_vertex) continue;
                const first_point = self.graph.vertices.items[first_vertex].point;
                const last_point = self.graph.vertices.items[last_vertex].point;
                const delta = last_point.sub(first_point);
                // The vertex chord lower-bounds the piece length. Pieces at
                // least the threshold apart cannot be merged as short.
                if (delta.dot(delta) >= 16 * epsilon * epsilon) continue;
                const part = self.makePiece(i, first, last);
                if (shortLength(&part.cubic, 4 * epsilon)) try short.append(allocator, .{ first.sample, last.sample });
            }
        }
        for (short.items) |pair| self.samples.items[self.root(pair[0])].parent = self.root(pair[1]);
        if (short.items.len != 0) try self.createVertices();
        try self.graph.edges.ensureTotalCapacityPrecise(self.storage, edge_capacity);
        const by_vertex = try allocator.alloc(std.ArrayList(usize), self.graph.vertices.items.len);
        @memset(by_vertex, .empty);
        for (self.cuts, 0..) |cuts, i| for (cuts.items[1..], cuts.items[0 .. cuts.items.len - 1]) |last, first| {
            const from = self.vertexIndex(first.sample);
            const to = self.vertexIndex(last.sample);
            const part = self.makePiece(i, first, last);
            if (from == to and shortLength(&part.cubic, 4 * epsilon)) continue;
            var weights: [2]i32 = .{ 0, 0 };
            weights[sources[i].operand] = 1;
            try self.addEdge(by_vertex, .{ .cubic = part.cubic, .from = from, .to = to, .windings = weights, .curve = i, .time1 = first.time, .time2 = last.time, .straight = !hasHandles(&sources[i].cubic) });
        };
        // Edges are complete before their values are borrowed. Both orientations
        // stay stable for the operation arena's lifetime.
        const half_edge_count = try std.math.mul(usize, self.graph.edges.items.len, 2);
        try self.graph.half_edges.ensureTotalCapacityPrecise(self.storage, half_edge_count);
        const offsets = try allocator.alloc(usize, self.graph.vertices.items.len + 1);
        @memset(offsets, 0);
        for (self.graph.edges.items) |edge| {
            offsets[edge.from + 1] += 1;
            offsets[edge.to + 1] += 1;
        }
        for (offsets[1..], 0..) |*end, i| end.* += offsets[i];
        const outgoing_edges = try allocator.alloc(usize, half_edge_count);
        const cursors = try allocator.dupe(usize, offsets[0..self.graph.vertices.items.len]);
        const reversed = try self.storage.alloc(Cubic, self.graph.edges.items.len);
        for (self.graph.edges.items, reversed, 0..) |*edge, *back, i| {
            back.* = reverse(edge.cubic);
            self.graph.half_edges.appendAssumeCapacity(.{ .edge = i, .cubic = &edge.cubic, .from = edge.from, .to = edge.to });
            self.graph.half_edges.appendAssumeCapacity(.{ .edge = i, .cubic = back, .from = edge.to, .to = edge.from });
            outgoing_edges[cursors[edge.from]] = 2 * i;
            cursors[edge.from] += 1;
            outgoing_edges[cursors[edge.to]] = 2 * i + 1;
            cursors[edge.to] += 1;
        }
        var sort: std.ArrayList(SortEntry) = .empty;
        defer sort.deinit(allocator);
        for (self.graph.vertices.items, 0..) |vertex, i| {
            const outgoing = outgoing_edges[offsets[i]..offsets[i + 1]];
            if (outgoing.len > 2) {
                try sort.resize(allocator, outgoing.len);
                if (!self.sortByDirections(outgoing, sort.items)) self.sortByDistance(outgoing, vertex.point, sort.items);
            }
            for (outgoing, 0..) |index, position| {
                self.graph.half_edges.items[index ^ 1].next = outgoing[(if (position == 0) outgoing.len else position) - 1];
            }
        }
    }

    fn createSamples(self: *Builder, intersections: []const intersection.Event) !void {
        const allocator = self.allocator;
        const sources = self.sources;
        const epsilon = self.epsilon;
        @memset(self.cuts, .empty);
        // Paired parameters are one topological event, even when independently
        // rounded evaluations do not coincide within the coordinate error.
        const Locations = struct {
            events: []const intersection.Event,
            sources: []const types.Source,
            local: []const usize,

            fn at(ctx: @This(), index: usize) *const intersection.LocationInfo {
                const event = &ctx.events[index / 2];
                return if (index % 2 == 0) &event.first else &event.second;
            }
            fn point(ctx: @This(), index: usize) Point {
                const event = &ctx.events[index / 2];
                const location = event.second.location;
                return if (index % 2 == 0) event.point else curves.getPoint(&ctx.sources[location.curve].cubic, location.time);
            }
            fn less(ctx: @This(), i: usize, j: usize) bool {
                const a = ctx.at(i).location;
                const b = ctx.at(j).location;
                const ca = ctx.sources[a.curve].contour;
                const cb = ctx.sources[b.curve].contour;
                return if (ca == cb)
                    @as(f64, @floatFromInt(ctx.local[a.curve])) + a.time < @as(f64, @floatFromInt(ctx.local[b.curve])) + b.time
                else
                    ca < cb;
            }
        };
        const expanded = try allocator.alloc(usize, try std.math.mul(usize, intersections.len, 2));
        defer allocator.free(expanded);
        var indices = try std.ArrayList(usize).initCapacity(allocator, sources.len);
        defer indices.deinit(allocator);
        const local = indices.addManyAsSliceAssumeCapacity(sources.len);
        var contour_start: usize = 0;
        for (sources, 0..) |*source, i| {
            if (i == 0 or sources[i - 1].contour != source.contour) contour_start = i;
            local[i] = i - contour_start;
        }
        for (0..intersections.len) |i| {
            expanded[i] = 2 * i;
            expanded[expanded.len - 1 - i] = 2 * i + 1;
        }
        const locations: Locations = .{ .events = intersections, .sources = sources, .local = local };
        std.mem.sort(usize, expanded, locations, Locations.less);
        // Distinct events may share a curve parameter. Store that cut once;
        // keep all event pairs so their topological connections are preserved.
        @memset(local, 2);
        var sample_count = sources.len;
        for (expanded, 0..) |entry, i| {
            if (i != 0 and sameLocation(locations.at(expanded[i - 1]).location, locations.at(entry).location)) continue;
            const info = locations.at(entry);
            local[info.location.curve] += 1;
            sample_count = try std.math.add(usize, sample_count, 1);
        }
        try self.samples.ensureTotalCapacityPrecise(allocator, sample_count);
        for (sources, self.cuts, local, 0..) |*source, *cuts, count, i| {
            try cuts.ensureTotalCapacityPrecise(allocator, count);
            // Input preparation shares each end exactly with the next start.
            self.samples.appendAssumeCapacity(.{ .point = source.cubic.p0, .parent = i });
            cuts.appendAssumeCapacity(.{ .time = 0, .sample = i });
            cuts.appendAssumeCapacity(.{ .time = 1, .sample = source.next });
        }
        const pairs = try allocator.alloc(usize, intersections.len);
        @memset(pairs, none);
        var sample_index: usize = undefined;
        for (expanded, 0..) |entry, i| {
            const info = locations.at(entry);
            if (i == 0 or !sameLocation(locations.at(expanded[i - 1]).location, info.location)) sample_index = self.addCut(info.location.curve, info.location.time, locations.point(entry));
            const other = pairs[entry / 2];
            if (other != none) self.samples.items[self.root(other)].parent = self.root(sample_index);
            pairs[entry / 2] = sample_index;
        }
        allocator.free(pairs);
        indices.clearRetainingCapacity();
        try indices.ensureTotalCapacityPrecise(allocator, self.samples.items.len);
        const order = indices.addManyAsSliceAssumeCapacity(self.samples.items.len);
        for (order, 0..) |*index, i| index.* = i;
        std.mem.sort(usize, order, self, struct {
            fn less(ctx: *Builder, a: usize, b: usize) bool {
                return ctx.samples.items[a].point.x < ctx.samples.items[b].point.x;
            }
        }.less);
        for (order, 0..) |a, i| {
            for (order[i + 1 ..]) |b| {
                const delta = self.samples.items[b].point.sub(self.samples.items[a].point);
                if (delta.x > epsilon) break;
                if (delta.dot(delta) <= epsilon * epsilon) self.samples.items[self.root(a)].parent = self.root(b);
            }
        }
    }

    fn addCut(self: *Builder, curve: usize, time: f64, p: Point) usize {
        const index = self.samples.items.len;
        self.samples.appendAssumeCapacity(.{ .point = p, .parent = index });
        self.cuts[curve].appendAssumeCapacity(.{ .time = time, .sample = index });
        return index;
    }
    fn sameLocation(a: types.Location, b: types.Location) bool {
        return a.curve == b.curve and @as(u64, @bitCast(a.time)) == @as(u64, @bitCast(b.time));
    }
    fn root(self: *Builder, index: usize) usize {
        var i = index;
        while (self.samples.items[i].parent != i) {
            const parent = self.samples.items[i].parent;
            self.samples.items[i].parent = self.samples.items[parent].parent;
            i = self.samples.items[i].parent;
        }
        return i;
    }
    fn vertexIndex(self: *Builder, index: usize) usize {
        return self.samples.items[index].vertex;
    }
    fn createVertices(self: *Builder) !void {
        self.graph.vertices.clearRetainingCapacity();
        var count: usize = 0;
        for (self.samples.items, 0..) |*sample, i| {
            sample.vertex = none;
            count += @intFromBool(sample.parent == i);
        }
        try self.graph.vertices.ensureTotalCapacityPrecise(self.storage, count);
        // Source ends precede every intersection sample, so the first sample
        // in a component already implements endpoint priority.
        for (0..self.samples.items.len) |i| {
            const sample = self.samples.items[i];
            const root_index = self.root(i);
            var index = self.samples.items[root_index].vertex;
            if (index == none) {
                index = self.graph.vertices.items.len;
                self.samples.items[root_index].vertex = index;
                self.graph.vertices.appendAssumeCapacity(.{ .point = sample.point, .sample = i });
            }
            // All lookups occur between merge passes. Rebuild this mapping
            // for every sample whenever createVertices follows a merge.
            self.samples.items[i].vertex = index;
        }
    }
    fn makePiece(self: *Builder, index: usize, first: Cut, last: Cut) Piece {
        return .{ .cubic = getPart(&self.sources[index].cubic, hasHandles(&self.sources[index].cubic), first.time, last.time, self.graph.vertices.items[self.vertexIndex(first.sample)].point, self.graph.vertices.items[self.vertexIndex(last.sample)].point), .first = first, .last = last };
    }
    fn addEdge(self: *Builder, by_vertex: []std.ArrayList(usize), edge: Edge) !void {
        const first = @min(edge.from, edge.to);
        const last = @max(edge.from, edge.to);
        for (by_vertex[first].items) |other_index| {
            const other = &self.graph.edges.items[other_index];
            if (@max(other.from, other.to) != last) continue;
            const direction = if (other.straight and edge.straight) blk: {
                if (other.cubic.p0.eql(edge.cubic.p0)) break :blk 1;
                if (other.cubic.p0.eql(edge.cubic.p3)) break :blk -1;
                break :blk self.coincidence(&other.cubic, &edge.cubic);
            } else self.coincidence(&other.cubic, &edge.cubic);
            if (direction != 0) {
                for (0..2) |j| other.windings[j] = try std.math.add(i32, other.windings[j], direction * edge.windings[j]);
                return;
            }
        }
        try by_vertex[first].append(self.allocator, self.graph.edges.items.len);
        self.graph.edges.appendAssumeCapacity(edge);
    }
    fn coincidence(self: *Builder, a: *const Cubic, b: *const Cubic) i32 {
        var times: [3]f64 = undefined;
        for (&times, 1..) |*time, i| {
            const p = curves.getPoint(b, @as(f64, @floatFromInt(i)) / 4);
            // The verified adapter uses the upstream tolerance-aware on-curve
            // query; nearest-point search has a different accuracy contract.
            time.* = curves.getTimeOf(a, p, self.epsilon) orelse return 0;
        }
        return if (times[0] < times[2]) 1 else -1;
    }
    fn sortByDirections(self: *Builder, outgoing: []usize, sorted: []SortEntry) bool {
        var distance = std.math.inf(f64);
        for (outgoing, sorted) |index, *entry| {
            const half = &self.graph.half_edges.items[index];
            entry.* = .{ .index = index, .directions = directions(half.cubic) orelse return false };
            const delta = half.cubic.p0.sub(half.cubic.p3);
            distance = @min(distance, @sqrt(delta.dot(delta)) / 2);
        }
        std.mem.sort(SortEntry, sorted, {}, struct {
            fn less(_: void, a: SortEntry, b: SortEntry) bool {
                return a.directions.start < b.directions.start;
            }
        }.less);
        var gap = std.math.inf(f64);
        var width: f64 = 0;
        for (sorted, 0..) |entry, i| {
            const first = entry.directions;
            const second = sorted[(i + 1) % sorted.len].directions;
            gap = @min(gap, second.start - first.start - first.width + (if (i + 1 < sorted.len) @as(f64, 0) else std.math.tau));
            width = @max(width, first.width);
        }
        if (gap > 0 and distance * @cos(width / 2) * @sin(@min(gap, std.math.pi / 2.0)) > 2 * self.epsilon) {
            for (outgoing, sorted) |*index, entry| index.* = entry.index;
            return true;
        }
        return false;
    }
    fn sortByDistance(self: *Builder, outgoing: []usize, origin: Point, sorted: []SortEntry) void {
        var distance = std.math.inf(f64);
        for (outgoing) |index| {
            const edge = &self.graph.edges.items[self.graph.half_edges.items[index].edge];
            edge.length = edge.length orelse curves.getLength(&edge.cubic, 0, 1);
            distance = @min(distance, edge.length.? / 2);
        }
        for (outgoing, sorted) |index, *entry| {
            const half = &self.graph.half_edges.items[index];
            const edge = &self.graph.edges.items[half.edge];
            const time = if (edge.straight) distance / edge.length.? else curves.getTimeAt(half.cubic, distance, 0) orelse 0;
            const p = curves.getPoint(half.cubic, time);
            entry.* = .{ .index = index, .point = p, .angle = std.math.atan2(p.y - origin.y, p.x - origin.x) };
        }
        std.mem.sort(SortEntry, sorted, {}, struct {
            fn less(_: void, a: SortEntry, b: SortEntry) bool {
                return a.angle < b.angle;
            }
        }.less);
        var start: f64 = -std.math.pi;
        var gap: f64 = 0;
        for (sorted, 0..) |entry, i| {
            const angle = entry.angle;
            const previous = sorted[(if (i == 0) sorted.len else i) - 1].angle;
            const delta = @mod(angle - previous + std.math.tau, std.math.tau);
            const difference = if (delta == 0) std.math.tau else delta;
            if (difference > gap) {
                gap = difference;
                start = angle;
            }
        }
        for (sorted) |*entry| entry.angle = @mod(entry.angle - start + std.math.tau, std.math.tau);
        std.mem.sort(SortEntry, sorted, self, struct {
            fn less(ctx: *Builder, first: SortEntry, second: SortEntry) bool {
                if (close(first.point, second.point, ctx.epsilon)) {
                    const orientation = ctx.side(&ctx.graph.half_edges.items[first.index], &ctx.graph.half_edges.items[second.index]);
                    if (orientation != 0) return orientation < 0;
                }
                return first.angle < second.angle;
            }
        }.less);
        for (outgoing, sorted) |*index, entry| index.* = entry.index;
    }
    fn side(self: *Builder, first: *const HalfEdge, second: *const HalfEdge) i32 {
        const edge1 = &self.graph.edges.items[first.edge];
        const edge2 = &self.graph.edges.items[second.edge];
        const length = @min(edge1.length.?, edge2.length.?) / 2;
        const second_time = if (edge2.straight) length / edge2.length.? else curves.getTimeAt(second.cubic, length, 0) orelse 0;
        const p = curves.getPoint(second.cubic, second_time);
        const time = curves.getNearestTime(first.cubic, p) orelse return 0;
        return if (time > 0 and time < 1) (if (curves.getTangent(first.cubic, time).cross(p.sub(curves.getPoint(first.cubic, time))) > 0) @as(i32, -1) else 1) else 0;
    }
};

fn sortCuts(cuts: []Cut) void {
    std.mem.sort(Cut, cuts, {}, struct {
        fn less(_: void, a: Cut, b: Cut) bool {
            return a.time < b.time;
        }
    }.less);
}
pub const hasHandles = curves.hasHandles;
pub fn reverse(v: Cubic) Cubic {
    return v.reversed();
}
/// The chord is a lower bound on arc length, so a chord at least the length
/// threshold already proves the threshold cannot match. Only pieces with a
/// short chord run the length integration.
fn shortLength(v: *const Cubic, threshold: f64) bool {
    const dx = v.p3.x - v.p0.x;
    const dy = v.p3.y - v.p0.y;
    if (dx * dx + dy * dy >= threshold * threshold) return false;
    return curves.getLength(v, 0, 1) < threshold;
}
fn close(a: Point, b: Point, epsilon: f64) bool {
    const d = a.sub(b);
    return d.dot(d) <= epsilon * epsilon;
}
pub inline fn controlBounds(v: *const Cubic, epsilon: f64) geometry.BBox {
    return v.controlBounds().expanded(epsilon);
}
fn inBounds(p: Point, bounds: geometry.BBox) bool {
    return bounds.contains(p);
}

fn directions(v: *const Cubic) ?Directions {
    var angles: [3]f64 = undefined;
    var count: usize = 0;
    inline for ([_]struct { a: Point, b: Point }{
        .{ .a = v.p0, .b = v.p1 },
        .{ .a = v.p1, .b = v.p2 },
        .{ .a = v.p2, .b = v.p3 },
    }) |pair| {
        const dx = pair.b.x - pair.a.x;
        const dy = pair.b.y - pair.a.y;
        if (dx != 0 or dy != 0) {
            angles[count] = std.math.atan2(dy, dx);
            count += 1;
        }
    }
    if (count == 0) return null;
    var from: f64 = 0;
    var to: f64 = 0;
    for (angles[1..count]) |angle| {
        const difference = @mod(angle - angles[0] + 3 * std.math.pi, std.math.tau) - std.math.pi;
        from = @min(from, difference);
        to = @max(to, difference);
    }
    return if (to - from < std.math.pi) .{ .start = @mod(angles[0] + from + std.math.tau, std.math.tau), .width = to - from } else null;
}
pub fn getPart(v: *const Cubic, handles: bool, first: f64, last: f64, a: Point, b: Point) Cubic {
    if (!handles) return .{ .p0 = a, .p1 = a, .p2 = b, .p3 = b };
    var part = curves.getPart(v, first, last);
    const da = a.sub(part.p0);
    const db = b.sub(part.p3);
    part.p0 = part.p0.add(da);
    part.p1 = part.p1.add(da);
    part.p2 = part.p2.add(db);
    part.p3 = part.p3.add(db);
    return part;
}

fn checkConstructionLifetime(allocator: Allocator) !void {
    const t = std.testing;
    const contours = [_][4]Point{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } },
        .{ .{ .x = 2, .y = -1 }, .{ .x = 6, .y = -1 }, .{ .x = 6, .y = 3 }, .{ .x = 2, .y = 3 } },
    };
    var sources: [12]types.Source = undefined;
    for (contours, 0..) |points, contour| for (points, 0..) |point, i| {
        const end = points[(i + 1) % 4];
        sources[4 * contour + i] = .{
            .cubic = .{ .p0 = point, .p1 = point, .p2 = end, .p3 = end },
            .next = 4 * contour + (i + 1) % 4,
            .contour = contour,
            .operand = if (contour < 2) 0 else 1,
        };
    };
    var result = traced: {
        var storage = std.heap.ArenaAllocator.init(allocator);
        defer storage.deinit();
        var g = built: {
            var workspace = std.heap.ArenaAllocator.init(allocator);
            defer workspace.deinit();
            const scratch = workspace.allocator();
            const candidates = try @import("collisions.zig").curveCandidates(scratch, &sources, 2e-8);
            const events = try intersection.collect(scratch, scratch, &sources, candidates, 1e-8);
            break :built try Graph.init(storage.allocator(), scratch, &sources, candidates, events.items, 1e-8);
        };
        try t.expectEqual(@as(usize, 10), g.vertices.items.len);
        try t.expectEqual(@as(usize, 12), g.edges.items.len);
        var incoming: [24]usize = @splat(0);
        for (g.half_edges.items) |half| {
            try t.expect(half.cubic.isFinite());
            try t.expectEqual(g.vertices.items[half.from].point, half.cubic.p0);
            try t.expectEqual(g.vertices.items[half.to].point, half.cubic.p3);
            try t.expect(half.next < g.half_edges.items.len);
            try t.expectEqual(half.to, g.half_edges.items[half.next].from);
            incoming[half.next] += 1;
        }
        for (incoming) |count| try t.expectEqual(@as(usize, 1), count);
        // Repeated contours retain their winding even when sharing cuts.
        for (g.edges.items) |edge| try t.expectEqual(if (edge.curve < 8) @as(i32, 2) else 0, edge.windings[0]);
        break :traced try @import("regions.zig").trace(&g, allocator, .unite, .nonzero);
    };
    defer result.deinit();
    try t.expectEqual(@as(f64, 26), result.signedArea());
}

test "graph and output outlive construction workspaces with duplicate intersections" {
    try checkConstructionLifetime(std.testing.allocator);
    // Remapping can change the number of allocations across failure-injection
    // runs. Force growth to allocate so every failure point is exercised.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), checkConstructionLifetime, .{});
}
