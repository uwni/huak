//! Triangulates scalar fields on tensor-product Bézier patches (see
//! `style.Gradient.Patches`) for outputs that interpolate only linearly on
//! triangles in the plane. Each patch splits in its own parameters until
//! linear interpolation in the plane over each cell's two triangles stays
//! within the tolerance of the field at 21 samples across the cell; the
//! samples estimate the error, they do not bound it. A cell halves in one
//! direction at a time, the one whose halves follow the field better, down
//! to 1/64 of its patch: where the projection folds at a contour the field
//! changes like the square root of the distance across it, and the cells
//! there become strips along the contour.
//!
//! Patches with a common edge (the same control points and field
//! coefficients along it, in either direction) share every node on it, and a
//! cell with smaller neighbours is fanned from its center through the nodes
//! on its sides, so the triangles meet without gaps.
const std = @import("std");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");

pub const Error = error{ InvalidPatches, GeometryWorkLimit, OutOfMemory };

/// Lattice steps per patch side. Cells keep at least two in each direction,
/// so that their centers are lattice points.
const lattice: u32 = 128;
/// Pieces an outline's index may hold; more report GeometryWorkLimit.
const max_pieces: usize = 1 << 20;

/// Arrays owned by the allocator given to `triangulate`.
pub const Triangulated = struct {
    points: []g.Point,
    values: []f64,
    triangles: [][3]u32,

    pub fn deinit(self: Triangulated, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.values);
        allocator.free(self.triangles);
    }
};

pub const Options = struct {
    /// The largest error the triangles may add to the field.
    tolerance: f64,
    /// Where the error does not count.
    free: ?*const Outline = null,
    /// More report GeometryWorkLimit.
    max_triangles: usize,
};

/// Triangles keep the order of their patches, so later patches still paint
/// over earlier ones.
pub fn triangulate(allocator: std.mem.Allocator, points: []const [16]g.Point, values: []const [16]f64, options: Options) Error!Triangulated {
    if (points.len != values.len or points.len >= std.math.maxInt(u32) or !std.math.isFinite(options.tolerance) or !(options.tolerance > 0)) return error.InvalidPatches;
    for (points, values) |patch, field| {
        for (patch) |point| if (!point.isFinite()) return error.InvalidPatches;
        for (field) |value| if (!std.math.isFinite(value)) return error.InvalidPatches;
    }
    var builder: Builder = .{ .allocator = allocator, .points = points, .values = values, .options = options };
    defer builder.deinit();
    try builder.identifyEdges();
    // Every patch places its cells' corners before any triangle is made, so
    // each cell sees the nodes its neighbours put on its sides.
    for (0..points.len) |patch| try builder.split(@intCast(patch));
    for (builder.cells.items) |cell| try builder.emit(cell);
    return builder.finish();
}

/// The band within `margin` of an outline traced only that accurately, where
/// the field's error does not count. Curves are flattened within a quarter of
/// the margin, and the pieces of the outline are kept in square cells at
/// least four margins wide, each holding the pieces that come within a
/// margin of it, so a query reads one cell.
pub const Outline = struct {
    margin: f64,
    cell: f64,
    /// The outline's extent grown by the margin; cells count from its corner.
    bounds: g.BBox,
    pieces: []const [2]g.Point,
    /// Per cell, the range of `members` that lists its pieces.
    cells: std.AutoHashMapUnmanaged([2]i64, [2]u32),
    members: []const u32,

    pub fn init(allocator: std.mem.Allocator, segments: []const Path.Segment, margin: f64) Error!Outline {
        if (!std.math.isFinite(margin) or !(margin > 0)) return error.InvalidPatches;
        var chords: std.ArrayList([2]g.Point) = .empty;
        defer chords.deinit(allocator);
        var current = g.Point.zero;
        var start = g.Point.zero;
        var bounds: ?g.BBox = null;
        for (segments) |segment| switch (segment) {
            .move => |point| {
                current = point;
                start = point;
            },
            .line => |point| {
                try chords.append(allocator, .{ current, point });
                current = point;
            },
            .cubic => |curve| {
                const cubic: g.Cubic = .{ .p0 = current, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end };
                // Chords of n equal parameter spans stray from the curve by
                // about the control points' distance from the chord over n^2.
                const across = @max(distanceToSegment(curve.c1, current, curve.end), distanceToSegment(curve.c2, current, curve.end));
                const count: usize = @intFromFloat(@min(4096, @max(1, @ceil(@sqrt(4 * across / margin)))));
                var previous = current;
                for (1..count + 1) |k| {
                    const next = cubic.at(@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count)));
                    try chords.append(allocator, .{ previous, next });
                    previous = next;
                }
                current = curve.end;
            },
            .close => {
                try chords.append(allocator, .{ current, start });
                current = start;
            },
        };
        for (chords.items) |chord| for (chord) |point| {
            if (!point.isFinite()) return error.InvalidPatches;
            bounds = if (bounds) |box| box.include(point) else .fromPoint(point);
        };
        const box = (bounds orelse return .{ .margin = margin, .cell = 4 * margin, .bounds = .fromPoint(.zero), .pieces = &.{}, .cells = .empty, .members = &.{} }).expanded(margin);
        // At most 2048 cells across the outline's extent.
        const cell = @max(4 * margin, @max(box.width(), box.height()) / 2048);
        if (!std.math.isFinite(cell)) return error.InvalidPatches;
        var pieces: std.ArrayList([2]g.Point) = .empty;
        defer pieces.deinit(allocator);
        for (chords.items) |chord| {
            const count: usize = @intFromFloat(@max(1, @ceil(chord[0].distance(chord[1]) / cell)));
            if (pieces.items.len + count > max_pieces) return error.GeometryWorkLimit;
            for (0..count) |k| {
                const from = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
                const to = @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(count));
                try pieces.append(allocator, .{ chord[0].lerp(chord[1], from), chord[0].lerp(chord[1], to) });
            }
        }
        var result: Outline = .{ .margin = margin, .cell = cell, .bounds = box, .pieces = &.{}, .cells = .empty, .members = &.{} };
        errdefer result.deinit(allocator);
        // Count each cell's pieces, then place them.
        for (pieces.items) |piece| {
            var covered = result.span(piece);
            while (covered.next()) |key| {
                const entry = try result.cells.getOrPut(allocator, key);
                if (!entry.found_existing) entry.value_ptr.* = .{ 0, 0 };
                entry.value_ptr[1] += 1;
            }
        }
        var total: u32 = 0;
        var ranges = result.cells.valueIterator();
        while (ranges.next()) |range| {
            range[0] = total;
            total += range[1];
            range[1] = 0;
        }
        const members = try allocator.alloc(u32, total);
        result.members = members;
        for (pieces.items, 0..) |piece, index| {
            var covered = result.span(piece);
            while (covered.next()) |key| {
                const range = result.cells.getPtr(key).?;
                members[range[0] + range[1]] = @intCast(index);
                range[1] += 1;
            }
        }
        result.pieces = try pieces.toOwnedSlice(allocator);
        return result;
    }

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        allocator.free(self.pieces);
        allocator.free(self.members);
        self.cells.deinit(allocator);
        self.* = undefined;
    }

    pub fn near(self: *const Outline, point: g.Point) bool {
        if (!self.bounds.contains(point)) return false;
        const range = self.cells.get(self.cellOf(point)) orelse return false;
        for (self.members[range[0]..][0..range[1]]) |index| {
            const piece = self.pieces[index];
            if (distanceToSegment(point, piece[0], piece[1]) < self.margin) return true;
        }
        return false;
    }

    /// Within the bounds, at most a few thousand cells from their corner.
    fn cellOf(self: *const Outline, point: g.Point) [2]i64 {
        const offset = point.sub(self.bounds.min);
        return .{ @intFromFloat(@floor(offset.x / self.cell)), @intFromFloat(@floor(offset.y / self.cell)) };
    }

    /// The cells a piece comes within a margin of.
    fn span(self: *const Outline, piece: [2]g.Point) Span {
        const low = self.cellOf(.{ .x = @min(piece[0].x, piece[1].x) - self.margin, .y = @min(piece[0].y, piece[1].y) - self.margin });
        const high = self.cellOf(.{ .x = @max(piece[0].x, piece[1].x) + self.margin, .y = @max(piece[0].y, piece[1].y) + self.margin });
        return .{ .low = low, .high = high, .at = low };
    }

    const Span = struct {
        low: [2]i64,
        high: [2]i64,
        at: [2]i64,

        fn next(self: *Span) ?[2]i64 {
            if (self.at[1] > self.high[1]) return null;
            const result = self.at;
            self.at[0] += 1;
            if (self.at[0] > self.high[0]) {
                self.at[0] = self.low[0];
                self.at[1] += 1;
            }
            return result;
        }
    };
};

fn distanceToSegment(point: g.Point, a: g.Point, b: g.Point) f64 {
    const along = b.sub(a);
    const squared = along.dot(along);
    const fraction = if (squared > 0) std.math.clamp(point.sub(a).dot(along) / squared, 0, 1) else 0;
    return point.distance(a.add(along.scale(fraction)));
}

/// Cells span powers of two of lattice steps in each direction.
const Cell = struct { patch: u32, i: u32, j: u32, wide: u32, high: u32 };
const Pending = struct { cell: Cell, err: f64 };
const Side = struct { edge: u32, reversed: bool };

/// Control indices along each side, in increasing parameter: u = 0, u = 1,
/// v = 0 and v = 1. Index i * 4 + j weighs B_i(u) B_j(v).
const sides = [4][4]u8{ .{ 0, 1, 2, 3 }, .{ 12, 13, 14, 15 }, .{ 0, 4, 8, 12 }, .{ 3, 7, 11, 15 } };
const EdgeKey = [4 * 24]u8;

const Builder = struct {
    allocator: std.mem.Allocator,
    points: []const [16]g.Point,
    values: []const [16]f64,
    options: Options,
    sides: std.ArrayList([4]Side) = .empty,
    edges: std.AutoHashMapUnmanaged(EdgeKey, u32) = .empty,
    /// Nodes by place: patch corners by position and value, points on a
    /// side by edge and canonical lattice position, others by patch and
    /// lattice point.
    corner: std.AutoHashMapUnmanaged([3]u64, u32) = .empty,
    along: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    inside: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    ring: std.ArrayList(u32) = .empty,
    nodes: std.ArrayList(g.Point) = .empty,
    fields: std.ArrayList(f64) = .empty,
    triangles: std.ArrayList([3]u32) = .empty,

    fn deinit(self: *Builder) void {
        self.sides.deinit(self.allocator);
        self.edges.deinit(self.allocator);
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

    fn finish(self: *Builder) Error!Triangulated {
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(nodes);
        const fields = try self.fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(fields);
        return .{ .points = nodes, .values = fields, .triangles = try self.triangles.toOwnedSlice(self.allocator) };
    }

    fn identifyEdges(self: *Builder) !void {
        try self.sides.ensureTotalCapacity(self.allocator, self.points.len);
        for (self.points, self.values) |*patch, *field| {
            var result: [4]Side = undefined;
            for (sides, &result) |indices, *side| {
                const forward = edgeKey(patch, field, indices, false);
                const backward = edgeKey(patch, field, indices, true);
                const reversed = std.mem.order(u8, &backward, &forward) == .lt;
                const entry = try self.edges.getOrPut(self.allocator, if (reversed) backward else forward);
                if (!entry.found_existing) entry.value_ptr.* = self.edges.count() - 1;
                side.* = .{ .edge = entry.value_ptr.*, .reversed = reversed };
            }
            self.sides.appendAssumeCapacity(result);
        }
    }

    fn split(self: *Builder, patch: u32) !void {
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
        const a = evaluate(patch, field, s0, t0);
        const c = evaluate(patch, field, s0 + width, t0 + height);
        const first = Plane.through(a, evaluate(patch, field, s0 + width, t0), c);
        const second = Plane.through(a, c, evaluate(patch, field, s0, t0 + height));
        if (first == null and second == null) return 0;
        var worst: f64 = 0;
        for (0..5) |m| for (0..5) |n| {
            if ((m == 0 or m == 4) and (n == 0 or n == 4)) continue;
            const sample = evaluate(patch, field, s0 + width * @as(f64, @floatFromInt(m)) / 4, t0 + height * @as(f64, @floatFromInt(n)) / 4);
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

    fn emit(self: *Builder, cell: Cell) !void {
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
                if (self.existing(cell.patch, i, j)) |found| try ring.append(self.allocator, found);
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
        const slot = switch (self.place(patch, i, j)) {
            inline else => |key, kind| entry: {
                const result = try @field(self, @tagName(kind)).getOrPut(self.allocator, key);
                if (result.found_existing) return result.value_ptr.*;
                break :entry result.value_ptr;
            },
        };
        const scale = 1.0 / @as(f64, @floatFromInt(lattice));
        const sample = evaluate(&self.points[patch], &self.values[patch], @as(f64, @floatFromInt(i)) * scale, @as(f64, @floatFromInt(j)) * scale);
        const id: u32 = @intCast(self.nodes.items.len);
        // The slot stays valid until the map changes; fill it first.
        slot.* = id;
        errdefer self.forget(patch, i, j);
        try self.nodes.append(self.allocator, sample.point);
        errdefer _ = self.nodes.pop();
        try self.fields.append(self.allocator, sample.value);
        return id;
    }

    fn forget(self: *Builder, patch: u32, i: u32, j: u32) void {
        switch (self.place(patch, i, j)) {
            inline else => |key, kind| _ = @field(self, @tagName(kind)).remove(key),
        }
    }

    fn existing(self: *const Builder, patch: u32, i: u32, j: u32) ?u32 {
        return switch (self.place(patch, i, j)) {
            inline else => |key, kind| @field(self, @tagName(kind)).get(key),
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
};

fn corners(cell: Cell) [4][2]u32 {
    return .{ .{ cell.i, cell.j }, .{ cell.i + cell.wide, cell.j }, .{ cell.i + cell.wide, cell.j + cell.high }, .{ cell.i, cell.j + cell.high } };
}

fn edgeKey(patch: *const [16]g.Point, field: *const [16]f64, indices: [4]u8, reversed: bool) EdgeKey {
    var key: EdgeKey = undefined;
    for (0..4) |k| {
        const index = indices[if (reversed) 3 - k else k];
        const words = [3]u64{ @bitCast(patch[index].x), @bitCast(patch[index].y), @bitCast(field[index]) };
        @memcpy(key[k * 24 ..][0..24], std.mem.asBytes(&words));
    }
    return key;
}

pub const Sample = struct { point: g.Point, value: f64 };

/// The patch point and field value at (u, v).
pub fn evaluate(patch: *const [16]g.Point, field: *const [16]f64, u: f64, v: f64) Sample {
    const bu = bernstein(u);
    const bv = bernstein(v);
    var point = g.Point.zero;
    var value: f64 = 0;
    for (0..4) |i| for (0..4) |j| {
        const weight = bu[i] * bv[j];
        point = point.add(patch[i * 4 + j].scale(weight));
        value += field[i * 4 + j] * weight;
    };
    return .{ .point = point, .value = value };
}

fn bernstein(s: f64) [4]f64 {
    const r = 1 - s;
    return .{ r * r * r, 3 * s * r * r, 3 * s * s * r, s * s * s };
}

/// The affine function of the plane through three samples' values.
const Plane = struct {
    origin: g.Point,
    value: f64,
    gradient: g.Point,
    first: g.Point,
    second: g.Point,
    area: f64,

    /// Null for a triangle without area.
    fn through(a: Sample, b: Sample, c: Sample) ?Plane {
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

    fn at(self: Plane, point: g.Point) f64 {
        return self.value + self.gradient.dot(point.sub(self.origin));
    }

    fn contains(self: Plane, point: g.Point) bool {
        const offset = point.sub(self.origin);
        const b = offset.cross(self.second) / self.area;
        const c = self.first.cross(offset) / self.area;
        return b >= -1e-9 and c >= -1e-9 and b + c <= 1 + 1e-9;
    }
};

const t = std.testing;

/// Bézier coefficients of the bicubic through `samples` at u, v in
/// {0, 1/3, 2/3, 1}, row-major like the coefficients.
fn interpolate(comptime T: type, samples: [16]T) [16]T {
    // Inverse of the cubic Bernstein basis at 0, 1/3, 2/3 and 1.
    const inverse = [4][4]f64{ .{ 1, 0, 0, 0 }, .{ -5.0 / 6.0, 3, -1.5, 1.0 / 3.0 }, .{ 1.0 / 3.0, -1.5, 3, -5.0 / 6.0 }, .{ 0, 0, 0, 1 } };
    var rows: [16]T = undefined;
    for (0..4) |i| for (0..4) |j| {
        var sum = std.mem.zeroes(T);
        for (0..4) |k| sum = add(T, sum, samples[k * 4 + j], inverse[i][k]);
        rows[i * 4 + j] = sum;
    };
    var result: [16]T = undefined;
    for (0..4) |i| for (0..4) |j| {
        var sum = std.mem.zeroes(T);
        for (0..4) |k| sum = add(T, sum, rows[i * 4 + k], inverse[j][k]);
        result[i * 4 + j] = sum;
    };
    return result;
}

fn add(comptime T: type, sum: T, value: T, weight: f64) T {
    return if (T == f64) sum + value * weight else sum.add(value.scale(weight));
}

/// A patch of the front of a sphere of radius 20 seen along z, lit from
/// above: polar angle a in [a0, a1] from the view axis, azimuth b in
/// [b0, b1]. The field is n·l with l = (0, 0.6, 0.8).
fn spherePatch(a0: f64, a1: f64, b0: f64, b1: f64) struct { points: [16]g.Point, values: [16]f64 } {
    var points: [16]g.Point = undefined;
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        const a = a0 + (a1 - a0) * @as(f64, @floatFromInt(i)) / 3;
        const b = b0 + (b1 - b0) * @as(f64, @floatFromInt(j)) / 3;
        const normal = [3]f64{ @sin(a) * @cos(b), @sin(a) * @sin(b), @cos(a) };
        points[i * 4 + j] = .{ .x = 20 * normal[0], .y = 20 * normal[1] };
        values[i * 4 + j] = 0.6 * normal[1] + 0.8 * normal[2];
    };
    return .{ .points = interpolate(g.Point, points), .values = interpolate(f64, values) };
}

/// Linear interpolation of the triangulation at `point`, or null outside it.
fn shade(result: Triangulated, point: g.Point) ?f64 {
    for (result.triangles) |triangle| {
        const plane = Plane.through(
            .{ .point = result.points[triangle[0]], .value = result.values[triangle[0]] },
            .{ .point = result.points[triangle[1]], .value = result.values[triangle[1]] },
            .{ .point = result.points[triangle[2]], .value = result.values[triangle[2]] },
        ) orelse continue;
        if (plane.contains(point)) return plane.at(point);
    }
    return null;
}

test "triangles of a sphere's patches follow the field near its contour" {
    // Two rings of patches running into the contour at a = pi / 2.
    var points: [8][16]g.Point = undefined;
    var values: [8][16]f64 = undefined;
    for (0..2) |ring| for (0..4) |k| {
        const a0 = std.math.pi / 2.0 - 0.25 * @as(f64, @floatFromInt(2 - ring));
        const b0 = 0.2 + 0.125 * @as(f64, @floatFromInt(k));
        const patch = spherePatch(a0, a0 + 0.25, b0, b0 + 0.125);
        points[ring * 4 + k] = patch.points;
        values[ring * 4 + k] = patch.values;
    };
    // The contour's outline, a circle of radius 20, traced within 0.01.
    const margin = 0.01;
    var outline_segments: [201]Path.Segment = undefined;
    for (&outline_segments, 0..) |*segment, k| {
        const angle = 0.1 + 0.8 * @as(f64, @floatFromInt(k)) / 200;
        const point: g.Point = .{ .x = 20 * @cos(angle), .y = 20 * @sin(angle) };
        segment.* = if (k == 0) .{ .move = point } else .{ .line = point };
    }
    var outline = try Outline.init(t.allocator, &outline_segments, margin);
    defer outline.deinit(t.allocator);
    try t.expect(outline.near(.{ .x = 20 * @cos(0.5) + 0.009, .y = 20 * @sin(0.5) }));
    try t.expect(!outline.near(.{ .x = 20 * @cos(0.5) - 0.02, .y = 20 * @sin(0.5) }));
    const tolerance = 1.0 / 256.0;
    const strict = try triangulate(t.allocator, &points, &values, .{ .tolerance = tolerance, .max_triangles = 100_000 });
    defer strict.deinit(t.allocator);
    const banded = try triangulate(t.allocator, &points, &values, .{ .tolerance = tolerance, .free = &outline, .max_triangles = 100_000 });
    defer banded.deinit(t.allocator);
    // Contour cells split; the band near the outline needs fewer.
    try t.expect(banded.triangles.len > 16 and banded.triangles.len < strict.triangles.len);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for ([_]Triangulated{ strict, banded }, [_]f64{ 0, 2 * margin }) |result, clear| {
        var worst: f64 = 0;
        for (0..2000) |_| {
            const patch = random.uintLessThan(usize, 8);
            const sample = evaluate(&points[patch], &values[patch], random.float(f64), random.float(f64));
            if (20 - @sqrt(sample.point.dot(sample.point)) < clear) continue;
            const value = shade(result, sample.point) orelse continue;
            worst = @max(worst, @abs(value - sample.value));
        }
        try t.expect(worst <= 1.5 * tolerance);
    }
}

test "a coarse patch takes the nodes its finer neighbour puts on their edge" {
    // Two unit squares sharing the edge x = 1. Both fields are 0.02 y^2 there,
    // within the tolerance of linear; the left one adds 4 x (1 - x) y^2, which
    // splits the left square along y.
    var left: [16]g.Point = undefined;
    var right: [16]g.Point = undefined;
    var left_field: [16]f64 = undefined;
    var right_field: [16]f64 = undefined;
    // Bézier coefficients of 4 u (1 - u) and of v^2.
    const across = [4]f64{ 0, 4.0 / 3.0, 4.0 / 3.0, 0 };
    const along = [4]f64{ 0, 0, 1.0 / 3.0, 1 };
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        const v = @as(f64, @floatFromInt(j)) / 3;
        left[i * 4 + j] = .{ .x = u, .y = v };
        right[i * 4 + j] = .{ .x = 1 + u, .y = v };
        left_field[i * 4 + j] = across[i] * along[j] + 0.02 * along[j];
        right_field[i * 4 + j] = 0.02 * along[j];
    };
    const result = try triangulate(t.allocator, &.{ left, right }, &.{ left_field, right_field }, .{ .tolerance = 0.01, .max_triangles = 100_000 });
    defer result.deinit(t.allocator);
    // Edges used once lie on the outline of the union, never along x = 1.
    var uses: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    defer uses.deinit(t.allocator);
    for (result.triangles) |triangle| for (0..3) |k| {
        const a = triangle[k];
        const b = triangle[(k + 1) % 3];
        const entry = try uses.getOrPut(t.allocator, .{ @min(a, b), @max(a, b) });
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    };
    var shared: usize = 0;
    var iterator = uses.iterator();
    while (iterator.next()) |entry| {
        const a = result.points[entry.key_ptr[0]];
        const b = result.points[entry.key_ptr[1]];
        const on_edge = a.x == 1 and b.x == 1;
        if (on_edge) shared += 1;
        if (on_edge and ((a.y > 0 and a.y < 1) or (b.y > 0 and b.y < 1))) try t.expectEqual(@as(u32, 2), entry.value_ptr.*);
    }
    // The left patch split, so the shared edge holds more than one segment.
    try t.expect(shared > 1);
}

test "flat patches with linear fields need two triangles, and limits hold" {
    var patch: [16]g.Point = undefined;
    var field: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        patch[i * 4 + j] = .{ .x = 3 * @as(f64, @floatFromInt(i)), .y = 2 * @as(f64, @floatFromInt(j)) + @as(f64, @floatFromInt(i)) };
        field[i * 4 + j] = @as(f64, @floatFromInt(i)) - 0.5 * @as(f64, @floatFromInt(j));
    };
    const result = try triangulate(t.allocator, &.{patch}, &.{field}, .{ .tolerance = 1e-9, .max_triangles = 100 });
    defer result.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), result.triangles.len);
    try t.expectEqual(@as(usize, 4), result.points.len);
    const curved = spherePatch(std.math.pi / 2.0 - 0.25, std.math.pi / 2.0, 0, 0.5);
    try t.expectError(error.GeometryWorkLimit, triangulate(t.allocator, &.{curved.points}, &.{curved.values}, .{ .tolerance = 1e-6, .max_triangles = 20 }));
    try t.expectError(error.InvalidPatches, triangulate(t.allocator, &.{patch}, &.{field}, .{ .tolerance = 0, .max_triangles = 100 }));
    var far = patch;
    far[5].x = std.math.inf(f64);
    try t.expectError(error.InvalidPatches, triangulate(t.allocator, &.{far}, &.{field}, .{ .tolerance = 0.1, .max_triangles = 100 }));
}

test "triangulation releases everything on allocation failure" {
    const curved = spherePatch(std.math.pi / 2.0 - 0.25, std.math.pi / 2.0, 0, 0.25);
    try t.checkAllAllocationFailures(t.allocator, struct {
        fn run(allocator: std.mem.Allocator, points: [16]g.Point, values: [16]f64) !void {
            const result = try triangulate(allocator, &.{points}, &.{values}, .{ .tolerance = 1.0 / 64.0, .max_triangles = 10_000 });
            result.deinit(allocator);
        }
    }.run, .{ curved.points, curved.values });
}
