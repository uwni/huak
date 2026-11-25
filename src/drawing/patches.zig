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
const Builder = @import("patches/Builder.zig");

pub const Error = error{ InvalidPatches, GeometryWorkLimit, OutOfMemory };

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

test {
    _ = @import("patches/triangulate_test.zig");
}
