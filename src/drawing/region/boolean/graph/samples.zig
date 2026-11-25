// Copyright 2011–2020 Jürg Lehni and Jonathan Puckey. MIT license.
// Paper.js v0.16.0 PathItem.Boolean.createGraph; see ../LICENSE.
//! Events to samples and vertices: one sample per event location, the cuts on each source, and vertices as the roots of merged samples.
const std = @import("std");
const types = @import("../types.zig");
const curves = @import("../curve.zig");
const intersection = @import("../intersections.zig");
const Point = types.Point;
const graph = @import("../graph.zig");

pub fn createSamples(self: *graph.Builder, intersections: []const intersection.Event) !void {
    const allocator = self.allocator;
    const sources = self.graph.sources;
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
    @memset(pairs, graph.none);
    var sample_index: usize = undefined;
    for (expanded, 0..) |entry, i| {
        const info = locations.at(entry);
        if (i == 0 or !sameLocation(locations.at(expanded[i - 1]).location, info.location)) sample_index = addCut(self, info.location.curve, info.location.time, locations.point(entry));
        const other = pairs[entry / 2];
        if (other != graph.none) self.samples.items[self.root(other)].parent = self.root(sample_index);
        pairs[entry / 2] = sample_index;
    }
    allocator.free(pairs);
    indices.clearRetainingCapacity();
    try indices.ensureTotalCapacityPrecise(allocator, self.samples.items.len);
    const order = indices.addManyAsSliceAssumeCapacity(self.samples.items.len);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, self, struct {
        fn less(ctx: *graph.Builder, a: usize, b: usize) bool {
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

fn addCut(self: *graph.Builder, curve: usize, time: f64, p: Point) usize {
    const index = self.samples.items.len;
    self.samples.appendAssumeCapacity(.{ .point = p, .parent = index });
    self.cuts[curve].appendAssumeCapacity(.{ .time = time, .sample = index });
    return index;
}

fn sameLocation(a: types.Location, b: types.Location) bool {
    return a.curve == b.curve and @as(u64, @bitCast(a.time)) == @as(u64, @bitCast(b.time));
}

pub fn createVertices(self: *graph.Builder) !void {
    self.graph.vertices.clearRetainingCapacity();
    var count: usize = 0;
    for (self.samples.items, 0..) |*sample, i| {
        sample.vertex = graph.none;
        count += @intFromBool(sample.parent == i);
    }
    try self.graph.vertices.ensureTotalCapacityPrecise(self.storage, count);
    // Source ends precede every intersection sample, so the first sample
    // in a component already implements endpoint priority.
    for (0..self.samples.items.len) |i| {
        const sample = self.samples.items[i];
        const root_index = self.root(i);
        var index = self.samples.items[root_index].vertex;
        if (index == graph.none) {
            index = self.graph.vertices.items.len;
            self.samples.items[root_index].vertex = index;
            self.graph.vertices.appendAssumeCapacity(.{ .point = sample.point, .sample = i });
        }
        // All lookups occur between merge passes. Rebuild this mapping
        // for every sample whenever createVertices follows a merge.
        self.samples.items[i].vertex = index;
    }
}

pub fn sortCuts(cuts: []graph.Cut) void {
    std.mem.sort(graph.Cut, cuts, {}, struct {
        fn less(_: void, a: graph.Cut, b: graph.Cut) bool {
            return a.time < b.time;
        }
    }.less);
}
