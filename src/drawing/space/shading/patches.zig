//! Turning pieces into tensor-product patches, with skirts.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const lattice_nodes = @import("nodes.zig");
const Sheet = @import("Sheet.zig");
const Node = @import("Node.zig");
const Patch = space_shading.Patch;
const Placed = Sheet.Placed;
const Error = space_shading.Error;
const Piece = Sheet.Piece;
const Corner = Sheet.Corner;
const ordered = lattice_nodes.ordered;
const Shine = space_shading.Shine;

/// Control indices of each side in increasing parameter, and the piece
/// corners at its ends: v = 0 (corners 0 -> 1), u = 1 (1 -> 2), v = 1
/// (3 -> 2) and u = 0 (0 -> 3).
const side_controls = [4][4]usize{ .{ 0, 4, 8, 12 }, .{ 12, 13, 14, 15 }, .{ 3, 7, 11, 15 }, .{ 0, 1, 2, 3 } };

pub const side_ends = [4][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 2 }, .{ 0, 3 } };

/// Bézier coefficients of the cubic through samples at 0, 1/3, 2/3 and 1.
/// The inner two use one expression in mirrored order, so a reversed side
/// gets exactly the reversed coefficients.
fn bezier(a: f64, b: f64, c: f64, d: f64) [4]f64 {
    return .{ a, inner(a, b, c, d), inner(d, c, b, a), d };
}

fn inner(p: f64, q: f64, r: f64, s: f64) f64 {
    return (-5 * p + 18 * q - 9 * r + 2 * s) / 6;
}

/// Tensor-product coefficients of samples at (i / 3, j / 3), index i * 4 + j.
/// Each side's coefficients depend on that side's samples alone.
fn coefficients(samples: [16]f64) [16]f64 {
    var rows: [16]f64 = undefined;
    for (0..4) |j| {
        const column = bezier(samples[j], samples[4 + j], samples[8 + j], samples[12 + j]);
        for (0..4) |i| rows[i * 4 + j] = column[i];
    }
    var result: [16]f64 = undefined;
    for (0..4) |i| {
        const row = bezier(rows[i * 4], rows[i * 4 + 1], rows[i * 4 + 2], rows[i * 4 + 3]);
        for (0..4) |j| result[i * 4 + j] = row[j];
    }
    return result;
}

/// A patch from side `side` of `patch` outward, away from the patch, carrying
/// the side's field unchanged across. It reaches past the outline's tolerance
/// and past the side's bulge from its chord, which an output may draw in its
/// place. Null for a side without length.
pub fn skirt(patch: Patch, side: usize, tolerance: f64) ?Patch {
    var e: [4]g.Point = undefined;
    for (&e, side_controls[side]) |*point, index| point.* = patch.points[index];
    const chord = e[3].sub(e[0]);
    const length = chord.norm();
    if (!(length > 0)) return null;
    const across: g.Point = .{ .x = -chord.y / length, .y = chord.x / length };
    var bulge: f64 = 0;
    for (e[1..3]) |point| bulge = @max(bulge, @abs(point.sub(e[0]).dot(across)));
    const width = 2 * tolerance + bulge;
    var center: g.Point = .zero;
    for ([_]usize{ 5, 6, 9, 10 }) |index| center = center.add(patch.points[index].scale(0.25));
    const outward: f64 = if (e[0].add(e[3]).scale(0.5).sub(center).dot(across) >= 0) 1 else -1;
    var result: Patch = undefined;
    for (0..4) |i| {
        var tangent = e[@min(i + 1, 3)].sub(e[i -| 1]);
        if (!(tangent.norm() > 1e-9 * length)) tangent = chord;
        const normal = (g.Point{ .x = -tangent.y, .y = tangent.x }).scale(outward / tangent.norm());
        // The first row is the side itself, bit for bit.
        result.points[i * 4] = patch.points[side_controls[side][i]];
        for (1..4) |j| result.points[i * 4 + j] = e[i].add(normal.scale(width * @as(f64, @floatFromInt(j)) / 3));
        for (0..4) |j| {
            result.diffuse[i * 4 + j] = patch.diffuse[side_controls[side][i]];
            result.glint[i * 4 + j] = patch.glint[side_controls[side][i]];
            result.values[i * 4 + j] = patch.values[side_controls[side][i]];
        }
    }
    return result;
}

/// Each front cell's center: the mean of its front corners in the
/// parameters. `placed` lists each cell's pieces together.
pub fn centers(self: *Sheet, placed: []const Placed) Error!void {
    const a = self.allocator;
    var uv: std.ArrayList(g.Point) = .empty;
    var owners: std.ArrayList(usize) = .empty;
    var k: usize = 0;
    while (k < placed.len) {
        const cell = placed[k].cell;
        const base = self.nodes.items[placed[k].piece[0].node].uv;
        var sum: g.Point = .zero;
        var count: f64 = 0;
        while (k < placed.len and placed[k].cell == cell) : (k += 1) for (placed[k].piece) |corner| {
            sum = sum.add(lattice_nodes.near(self, base, self.nodes.items[corner.node].uv));
            count += 1;
        };
        try uv.append(a, .{ .x = sum.x / count, .y = sum.y / count });
        try owners.append(a, cell);
    }
    const nodes = try a.alloc(Node, uv.items.len);
    try self.shading.evaluate(a, self.face, uv.items, nodes);
    for (owners.items, nodes) |cell, center| self.cells[cell].center = center;
}

/// A piece's corners in the parameters, the last three moved by whole
/// periods next to the first.
pub fn corners(self: *const Sheet, piece: Piece) [4]g.Point {
    const first = self.nodes.items[piece[0].node].uv;
    return .{ first, lattice_nodes.near(self, first, self.nodes.items[piece[1].node].uv), lattice_nodes.near(self, first, self.nodes.items[piece[2].node].uv), lattice_nodes.near(self, first, self.nodes.items[piece[3].node].uv) };
}

pub fn bilinear(c: [4]g.Point, s: f64, t: f64) g.Point {
    return c[0].scale((1 - s) * (1 - t)).add(c[1].scale(s * (1 - t))).add(c[2].scale(s * t)).add(c[3].scale((1 - s) * t));
}

/// The nodes a third and two thirds of the way from a to b: lattice points
/// on lattice sides, otherwise points on the straight side in the
/// parameters, made once per side from its lower node and shared by both
/// patches on it.
pub fn thirdsOf(self: *Sheet, a: Corner, b: Corner) ![2]u32 {
    if (a.lattice and b.lattice and @rem(b.i - a.i, 3) == 0 and @rem(b.j - a.j, 3) == 0) {
        const di = @divTrunc(b.i - a.i, 3);
        const dj = @divTrunc(b.j - a.j, 3);
        return .{ (try lattice_nodes.at(self, a.i + di, a.j + dj)).node, (try lattice_nodes.at(self, a.i + 2 * di, a.j + 2 * dj)).node };
    }
    const key = ordered(a.node, b.node);
    const entry = try self.thirds.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        const from = self.nodes.items[key[0]].uv;
        const length = lattice_nodes.near(self, from, self.nodes.items[key[1]].uv).sub(from);
        const first = try lattice_nodes.request(self, from.add(.{ .x = length.x / 3, .y = length.y / 3 }), 0);
        entry.value_ptr.* = .{ first, try lattice_nodes.request(self, from.add(length.scale(2.0 / 3.0)), 0) };
    }
    const made = entry.value_ptr.*;
    return if (a.node == key[0]) made else .{ made[1], made[0] };
}

/// Patches over pieces carrying n·l, the script's field, and the glint on
/// the `fine` pieces of cells the highlight can reach; the glint of other
/// patches is 0, since they are too coarse for it. The light and field at a
/// node without a normal come from a point a little way toward the patch's
/// center. `strays` gets how far each patch strays from the field.
pub fn patches(self: *Sheet, placed: []const Placed, fine: bool, out: []Patch, strays: []f64) Error!void {
    const a = self.allocator;
    const ids = try a.alloc([16]u32, placed.len);
    for (placed, ids) |p, *id| id.* = try self.samples(p.piece);
    try lattice_nodes.flush(self);
    const lights = try a.alloc([16]Shine, placed.len);
    const fields = try a.alloc([16]f64, placed.len);
    var probes: std.ArrayList(g.Point) = .empty;
    var owners: std.ArrayList(usize) = .empty;
    for (placed, ids, lights, fields, 0..) |p, id, *light, *field, index| {
        const center = bilinear(corners(self, p.piece), 0.5, 0.5);
        for (id, light, field, 0..) |node_id, *shine, *value, k| {
            const n = self.nodes.items[node_id];
            if (!n.singular) {
                shine.* = n.shine;
                value.* = n.value;
                continue;
            }
            const from = lattice_nodes.near(self, center, n.uv);
            try probes.append(a, from.add(center.sub(from).scale(1e-3)));
            try owners.append(a, index * 16 + k);
        }
    }
    const nearby = try a.alloc(Node, probes.items.len);
    try self.shading.evaluate(a, self.face, probes.items, nearby);
    for (nearby) |n| if (n.singular) return error.UndefinedNormal;
    try self.shading.sample(a, nearby);
    for (nearby, owners.items) |n, owner| {
        lights[owner / 16][owner % 16] = n.shine;
        fields[owner / 16][owner % 16] = n.value;
    }
    for (placed, ids, lights, fields, out, strays) |p, id, light, field, *patch, *stray| {
        const highlight = fine and self.cells[p.cell].gleams;
        var xs: [16]f64 = undefined;
        var ys: [16]f64 = undefined;
        var diffuse: [16]f64 = undefined;
        var glint: [16]f64 = @splat(0);
        for (id, light, &xs, &ys, &diffuse, &glint) |node_id, shine, *x, *y, *d, *h| {
            x.* = self.nodes.items[node_id].x;
            y.* = self.nodes.items[node_id].y;
            d.* = shine.diffuse;
            if (highlight) h.* = shine.glint;
        }
        const px = coefficients(xs);
        const py = coefficients(ys);
        for (&patch.points, px, py) |*point, x, y| point.* = .{ .x = x, .y = y };
        patch.diffuse = coefficients(diffuse);
        patch.glint = coefficients(glint);
        patch.values = coefficients(field);
        stray.* = straying(field);
    }
}

/// How far a patch's corner values, interpolated bilinearly in its
/// parameters as a PDF patch mesh paints them, stray from its samples at
/// (i / 3, j / 3), index i * 4 + j.
pub fn straying(samples: [16]f64) f64 {
    var most: f64 = 0;
    for (0..4) |i| for (0..4) |j| {
        const s = @as(f64, @floatFromInt(i)) / 3;
        const t = @as(f64, @floatFromInt(j)) / 3;
        const corners_ = (1 - s) * (1 - t) * samples[0] + s * (1 - t) * samples[12] + s * t * samples[15] + (1 - s) * t * samples[3];
        most = @max(most, @abs(samples[i * 4 + j] - corners_));
    };
    return most;
}

test "a reversed cubic side gets exactly the reversed coefficients" {
    var random: std.Random.DefaultPrng = .init(5);
    for (0..200) |_| {
        var samples: [4]f64 = undefined;
        for (&samples) |*s| s.* = random.random().float(f64) * 200 - 100;
        const forward = bezier(samples[0], samples[1], samples[2], samples[3]);
        const backward = bezier(samples[3], samples[2], samples[1], samples[0]);
        for (0..4) |k| try std.testing.expectEqual(forward[k], backward[3 - k]);
    }
    // The cubic interpolates its samples.
    const c = bezier(1, 4, -2, 3);
    for ([_]f64{ 0, 1.0 / 3.0, 2.0 / 3.0, 1 }, [_]f64{ 1, 4, -2, 3 }) |s, expected| {
        const r = 1 - s;
        const b = [4]f64{ r * r * r, 3 * s * r * r, 3 * s * s * r, s * s * s };
        try std.testing.expectApproxEqAbs(expected, b[0] * c[0] + b[1] * c[1] + b[2] * c[2] + b[3] * c[3], 1e-12);
    }
}
