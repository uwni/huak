//! Adaptive halving of tensor-product patch cells until the field is within tolerance, with nodes shared on the edges between neighbouring patches.
const std = @import("std");
const g = @import("../geometry.zig");
const patches = @import("../patches.zig");
const Builder = @This();

allocator: std.mem.Allocator,
points: []const [16]g.Point,
values: []const [16]f64,
options: patches.Options,
sides: std.ArrayList([4]Side) = .empty,
edges: std.AutoHashMapUnmanaged(EdgeKey, u32) = .empty,
edge_count: u32 = 0,
/// Canonical geometric points placed on shared edges (keyed by edge id and
/// canonical lattice step), so neighbouring patches share identical edge
/// subdivisions even when their field values jump across the edge.
edge_points: std.AutoHashMapUnmanaged(u64, g.Point) = .empty,
/// Nodes by place: patch corners by position and value, points on a
/// side by (edge_step, value), others by patch and lattice point.
corner: std.AutoHashMapUnmanaged([3]u64, u32) = .empty,
along: std.AutoHashMapUnmanaged([2]u64, u32) = .empty,
inside: std.AutoHashMapUnmanaged(u64, u32) = .empty,
cells: std.ArrayList(Cell) = .empty,
pending: std.ArrayList(Pending) = .empty,
ring: std.ArrayList(u32) = .empty,
nodes: std.ArrayList(g.Point) = .empty,
fields: std.ArrayList(f64) = .empty,
triangles: std.ArrayList([3]u32) = .empty,

pub fn deinit(self: *Builder) void {
    self.sides.deinit(self.allocator);
    self.edges.deinit(self.allocator);
    self.edge_points.deinit(self.allocator);
    self.corner.deinit(self.allocator);
    self.along.deinit(self.allocator);
    self.inside.deinit(self.allocator);
    self.cells.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.ring.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.fields.deinit(self.allocator);
    self.triangles.deinit(self.allocator);
}

pub fn finish(self: *Builder) patches.Error!patches.Triangulated {
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(nodes);
    const fields = try self.fields.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(fields);
    return .{ .points = nodes, .values = fields, .triangles = try self.triangles.toOwnedSlice(self.allocator) };
}

pub fn identifyEdges(self: *Builder) !void {
    try self.sides.ensureTotalCapacity(self.allocator, self.points.len);
    for (self.points) |*patch| {
        var result: [4]Side = undefined;
        for (side_controls, &result) |indices, *side| {
            const p0 = patch[indices[0]];
            if (p0.eql(patch[indices[1]]) and p0.eql(patch[indices[2]]) and p0.eql(patch[indices[3]])) {
                side.* = .{ .edge = self.edge_count, .reversed = false };
                self.edge_count += 1;
                continue;
            }
            const forward = edgeKey(patch, indices, false);
            const backward = edgeKey(patch, indices, true);
            const reversed = std.mem.order(u8, &backward, &forward) == .lt;
            const entry = try self.edges.getOrPut(self.allocator, if (reversed) backward else forward);
            if (!entry.found_existing) {
                entry.value_ptr.* = self.edge_count;
                self.edge_count += 1;
            }
            side.* = .{ .edge = entry.value_ptr.*, .reversed = reversed };
        }
        self.sides.appendAssumeCapacity(result);
    }
}

pub fn split(self: *Builder, patch: u32) !void {
    self.pending.clearRetainingCapacity();
    const whole: Cell = .{ .patch = patch, .i = 0, .j = 0, .wide = lattice, .high = lattice };
    try self.pending.append(self.allocator, .{ .cell = whole, .err = self.cellError(whole) });
    while (self.pending.pop()) |item| {
        const cell = item.cell;
        if (item.err > self.options.tolerance and (cell.wide > 2 or cell.high > 2)) {
            // Each cell yields at least two triangles.
            if (self.cells.items.len + self.pending.items.len + 2 > self.options.max_triangles / 2) return error.GeometryWorkLimit;
            // Halve the direction whose halves follow the field better.
            var best: [2]Pending = undefined;
            var worst = std.math.inf(f64);
            for ([2]bool{ true, false }) |across| {
                if ((if (across) cell.wide else cell.high) <= 2) continue;
                var halves: [2]Pending = undefined;
                for (&halves, 0..) |*half, k| {
                    var part = cell;
                    if (across) {
                        part.wide /= 2;
                        part.i += @as(u32, @intCast(k)) * part.wide;
                    } else {
                        part.high /= 2;
                        part.j += @as(u32, @intCast(k)) * part.high;
                    }
                    half.* = .{ .cell = part, .err = self.cellError(part) };
                }
                const err = @max(halves[0].err, halves[1].err);
                if (err < worst) {
                    worst = err;
                    best = halves;
                }
            }
            try self.pending.appendSlice(self.allocator, &best);
            continue;
        }
        try self.cells.append(self.allocator, cell);
        for (corners(cell)) |corner| _ = try self.node(patch, corner[0], corner[1]);
    }
}

/// The largest difference between the field and the planes through the
/// corners of the cell's two triangles, at a 5 x 5 grid of samples
/// outside the free band. A sample outside both triangles, between a
/// chord and the curved side it cuts across, takes the plane continued
/// beyond them.
fn cellError(self: *const Builder, cell: Cell) f64 {
    const patch = &self.points[cell.patch];
    const field = &self.values[cell.patch];
    const scale = 1.0 / @as(f64, @floatFromInt(lattice));
    const s0 = @as(f64, @floatFromInt(cell.i)) * scale;
    const t0 = @as(f64, @floatFromInt(cell.j)) * scale;
    const width = @as(f64, @floatFromInt(cell.wide)) * scale;
    const height = @as(f64, @floatFromInt(cell.high)) * scale;
    const a = patches.evaluate(patch, field, s0, t0);
    const c = patches.evaluate(patch, field, s0 + width, t0 + height);
    const first = Plane.through(a, patches.evaluate(patch, field, s0 + width, t0), c);
    const second = Plane.through(a, c, patches.evaluate(patch, field, s0, t0 + height));
    if (first == null and second == null) return 0;
    var worst: f64 = 0;
    for (0..5) |m| for (0..5) |n| {
        if ((m == 0 or m == 4) and (n == 0 or n == 4)) continue;
        const sample = patches.evaluate(patch, field, s0 + width * @as(f64, @floatFromInt(m)) / 4, t0 + height * @as(f64, @floatFromInt(n)) / 4);
        if (self.options.free) |band| if (band.near(sample.point)) continue;
        // The triangle holding the sample in the plane, else the one
        // holding it in parameters.
        const plane = if (first != null and first.?.contains(sample.point))
            first.?
        else if (second != null and second.?.contains(sample.point))
            second.?
        else if (m >= n)
            first orelse second.?
        else
            second orelse first.?;
        worst = @max(worst, @abs(plane.at(sample.point) - sample.value));
    };
    return worst;
}

pub fn emit(self: *Builder, cell: Cell) !void {
    const ring = &self.ring;
    ring.clearRetainingCapacity();
    // Counterclockwise in parameters: each side from its first corner,
    // with the nodes smaller neighbours placed on it.
    const steps = [4][2]i32{ .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 } };
    const lengths = [4]u32{ cell.wide, cell.high, cell.wide, cell.high };
    for (corners(cell), steps, lengths) |corner, direction, length| {
        try ring.append(self.allocator, try self.node(cell.patch, corner[0], corner[1]));
        for (1..length) |k| {
            const i: u32 = @intCast(@as(i64, corner[0]) + direction[0] * @as(i64, @intCast(k)));
            const j: u32 = @intCast(@as(i64, corner[1]) + direction[1] * @as(i64, @intCast(k)));
            if (self.isMarked(cell.patch, i, j)) try ring.append(self.allocator, try self.node(cell.patch, i, j));
        }
    }
    const count = ring.items.len;
    if (self.triangles.items.len + count > self.options.max_triangles) return error.GeometryWorkLimit;
    if (count == 4) {
        try self.triangles.appendSlice(self.allocator, &.{ .{ ring.items[0], ring.items[1], ring.items[2] }, .{ ring.items[0], ring.items[2], ring.items[3] } });
        return;
    }
    const hub = try self.node(cell.patch, cell.i + cell.wide / 2, cell.j + cell.high / 2);
    for (0..count) |k| try self.triangles.append(self.allocator, .{ hub, ring.items[k], ring.items[(k + 1) % count] });
}

fn node(self: *Builder, patch: u32, i: u32, j: u32) !u32 {
    const scale = 1.0 / @as(f64, @floatFromInt(lattice));
    switch (self.place(patch, i, j)) {
        .corner => |key| {
            const result = try self.corner.getOrPut(self.allocator, key);
            if (result.found_existing) return result.value_ptr.*;
            const sample = patches.evaluate(&self.points[patch], &self.values[patch], @as(f64, @floatFromInt(i)) * scale, @as(f64, @floatFromInt(j)) * scale);
            const id: u32 = @intCast(self.nodes.items.len);
            result.value_ptr.* = id;
            errdefer _ = self.corner.remove(key);
            try self.nodes.append(self.allocator, sample.point);
            errdefer _ = self.nodes.pop();
            try self.fields.append(self.allocator, sample.value);
            return id;
        },
        .inside => |key| {
            const result = try self.inside.getOrPut(self.allocator, key);
            if (result.found_existing) return result.value_ptr.*;
            const sample = patches.evaluate(&self.points[patch], &self.values[patch], @as(f64, @floatFromInt(i)) * scale, @as(f64, @floatFromInt(j)) * scale);
            const id: u32 = @intCast(self.nodes.items.len);
            result.value_ptr.* = id;
            errdefer _ = self.inside.remove(key);
            try self.nodes.append(self.allocator, sample.point);
            errdefer _ = self.nodes.pop();
            try self.fields.append(self.allocator, sample.value);
            return id;
        },
        .along => |geo_key| {
            const sample = patches.evaluate(&self.points[patch], &self.values[patch], @as(f64, @floatFromInt(i)) * scale, @as(f64, @floatFromInt(j)) * scale);
            const ep = try self.edge_points.getOrPut(self.allocator, geo_key);
            const new_ep = !ep.found_existing;
            if (new_ep) ep.value_ptr.* = sample.point;
            const canonical_point = ep.value_ptr.*;
            errdefer if (new_ep) {
                _ = self.edge_points.remove(geo_key);
            };
            const full_key = [2]u64{ geo_key, @bitCast(sample.value) };
            const result = try self.along.getOrPut(self.allocator, full_key);
            if (result.found_existing) return result.value_ptr.*;
            const id: u32 = @intCast(self.nodes.items.len);
            result.value_ptr.* = id;
            errdefer _ = self.along.remove(full_key);
            try self.nodes.append(self.allocator, canonical_point);
            errdefer _ = self.nodes.pop();
            try self.fields.append(self.allocator, sample.value);
            return id;
        },
    }
}

fn isMarked(self: *const Builder, patch: u32, i: u32, j: u32) bool {
    return switch (self.place(patch, i, j)) {
        .corner => |key| self.corner.contains(key),
        .along => |geo_key| self.edge_points.contains(geo_key),
        .inside => |key| self.inside.contains(key),
    };
}

const Place = union(enum) { corner: [3]u64, along: u64, inside: u64 };

fn place(self: *const Builder, patch: u32, i: u32, j: u32) Place {
    const on_u = i == 0 or i == lattice;
    const on_v = j == 0 or j == lattice;
    if (on_u and on_v) {
        const index = @as(usize, if (i == 0) 0 else 12) + @as(usize, if (j == 0) 0 else 3);
        const point = self.points[patch][index];
        return .{ .corner = .{ @bitCast(point.x), @bitCast(point.y), @bitCast(self.values[patch][index]) } };
    }
    if (!on_u and !on_v) return .{ .inside = (@as(u64, patch) * (lattice + 1) + i) * (lattice + 1) + j };
    const side_index: usize = if (on_u) (if (i == 0) 0 else 1) else (if (j == 0) 2 else 3);
    const k = if (on_u) j else i;
    const side = self.sides.items[patch][side_index];
    return .{ .along = @as(u64, side.edge) << 32 | (if (side.reversed) lattice - k else k) };
}

/// Lattice steps per patch side. Cells keep at least two in each direction,
/// so that their centers are lattice points.
const lattice: u32 = 128;

/// Cells span powers of two of lattice steps in each direction.
const Cell = struct { patch: u32, i: u32, j: u32, wide: u32, high: u32 };

const Pending = struct { cell: Cell, err: f64 };

const Side = struct { edge: u32, reversed: bool };

/// Control indices along each side, in increasing parameter: u = 0, u = 1,
/// v = 0 and v = 1. Index i * 4 + j weighs B_i(u) B_j(v).
const side_controls = [4][4]u8{ .{ 0, 1, 2, 3 }, .{ 12, 13, 14, 15 }, .{ 0, 4, 8, 12 }, .{ 3, 7, 11, 15 } };

const EdgeKey = [4 * 16]u8;

fn corners(cell: Cell) [4][2]u32 {
    return .{ .{ cell.i, cell.j }, .{ cell.i + cell.wide, cell.j }, .{ cell.i + cell.wide, cell.j + cell.high }, .{ cell.i, cell.j + cell.high } };
}

fn edgeKey(patch: *const [16]g.Point, indices: [4]u8, reversed: bool) EdgeKey {
    var key: EdgeKey = undefined;
    for (0..4) |k| {
        const index = indices[if (reversed) 3 - k else k];
        const words = [2]u64{ @bitCast(patch[index].x), @bitCast(patch[index].y) };
        @memcpy(key[k * 16 ..][0..16], std.mem.asBytes(&words));
    }
    return key;
}

/// The affine function of the plane through three samples' values.
pub const Plane = struct {
    origin: g.Point,
    value: f64,
    gradient: g.Point,
    first: g.Point,
    second: g.Point,
    area: f64,

    /// Null for a triangle without area.
    pub fn through(a: patches.Sample, b: patches.Sample, c: patches.Sample) ?Plane {
        const first = b.point.sub(a.point);
        const second = c.point.sub(a.point);
        const area = first.cross(second);
        if (!(@abs(area) > 1e-12 * (first.dot(first) + second.dot(second)))) return null;
        const rise = [2]f64{ b.value - a.value, c.value - a.value };
        return .{
            .origin = a.point,
            .value = a.value,
            .gradient = .{ .x = (rise[0] * second.y - rise[1] * first.y) / area, .y = (rise[1] * first.x - rise[0] * second.x) / area },
            .first = first,
            .second = second,
            .area = area,
        };
    }

    pub fn at(self: Plane, point: g.Point) f64 {
        return self.value + self.gradient.dot(point.sub(self.origin));
    }

    pub fn contains(self: Plane, point: g.Point) bool {
        const offset = point.sub(self.origin);
        const b = offset.cross(self.second) / self.area;
        const c = self.first.cross(offset) / self.area;
        return b >= -1e-9 and c >= -1e-9 and b + c <= 1 + 1e-9;
    }
};
