//! Turning pieces into tensor-product patches with exact 3D camera depths,
//! skirts, and exact projection of on-contour thirds onto n·v = 0.
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
const on_contour = Node.on_contour;
const on_bounds = Node.on_bounds;

/// Control indices of each side in increasing parameter, and the piece
/// corners at its ends: v = 0 (corners 0 -> 1), u = 1 (1 -> 2), v = 1
/// (3 -> 2) and u = 0 (0 -> 3).
pub const side_controls = [4][4]usize{ .{ 0, 4, 8, 12 }, .{ 12, 13, 14, 15 }, .{ 3, 7, 11, 15 }, .{ 0, 1, 2, 3 } };

pub const side_ends = [4][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 2 }, .{ 0, 3 } };

/// A tensor-product patch together with its exact camera-space depth z
/// (increasing toward the viewer) at its 16 Bernstein control points.
pub const DepthPatch = struct {
    patch: Patch,
    pz: [16]f64,
    sheet: u8 = 0,
    facing_flipped: bool = false,
};

/// A skirt patch together with the mean depth along its contour/boundary edge.
pub const SkirtPatch = struct {
    patch: Patch,
    depth: f64,
};

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
pub fn coefficients(samples: [16]f64) [16]f64 {
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

/// A patch from side `side` of `dp` outward, away from the patch, carrying
/// the side's field unchanged across. It reaches past the outline's tolerance
/// and past the side's bulge from its chord, which an output may draw in its
/// place. Null for a side without length.
pub fn skirt(dp: DepthPatch, side: usize, tolerance: f64) ?SkirtPatch {
    const patch = dp.patch;
    var e: [4]g.Point = undefined;
    var depth_sum: f64 = 0;
    for (&e, side_controls[side]) |*point, index| {
        point.* = patch.points[index];
        depth_sum += dp.pz[index];
    }
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
    return .{ .patch = result, .depth = depth_sum * 0.25 };
}

pub fn bilinear(c: [4]g.Point, s: f64, t: f64) g.Point {
    return c[0].scale((1 - s) * (1 - t)).add(c[1].scale(s * (1 - t))).add(c[2].scale(s * t)).add(c[3].scale((1 - s) * t));
}

pub const ContourThird = struct {
    key: [2]u32,
    cell: usize,
    nodes: [2]u32,
};

/// The nodes a third and two thirds of the way from a to b. On-contour edges
/// (not lying on a parameter bound) are registered in `contour_list` so their
/// two interior thirds are projected onto n·v = 0 via OCCT `roots`.
pub fn thirdsOf(self: *Sheet, a: Corner, b: Corner, cell: usize, contour_list: *std.ArrayList(ContourThird)) ![2]u32 {
    if (a.lattice and b.lattice and @rem(b.i - a.i, 3) == 0 and @rem(b.j - a.j, 3) == 0) {
        const di = @divTrunc(b.i - a.i, 3);
        const dj = @divTrunc(b.j - a.j, 3);
        return .{ (try lattice_nodes.at(self, a.i + di, a.j + dj)).node, (try lattice_nodes.at(self, a.i + 2 * di, a.j + 2 * dj)).node };
    }
    const key = ordered(a.node, b.node);
    const entry = try self.thirds.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        const p0 = self.nodes.items[key[0]];
        const p1 = self.nodes.items[key[1]];
        const is_contour = (p0.place & p1.place & on_contour) != 0 and (p0.place & p1.place & on_bounds) == 0 and key[0] != key[1];
        const from = p0.uv;
        const length = lattice_nodes.near(self, from, p1.uv).sub(from);
        const place: u8 = if (is_contour) on_contour else 0;
        const first = try lattice_nodes.request(self, from.add(.{ .x = length.x / 3, .y = length.y / 3 }), place);
        const second = try lattice_nodes.request(self, from.add(length.scale(2.0 / 3.0)), place);
        entry.value_ptr.* = .{ first, second };
        if (is_contour) try contour_list.append(self.allocator, .{ .key = key, .cell = cell, .nodes = .{ first, second } });
    }
    const made = entry.value_ptr.*;
    return if (a.node == key[0]) made else .{ made[1], made[0] };
}

fn clampUv(self: *const Sheet, uv: g.Point) g.Point {
    return .{
        .x = if (self.period[0] == 0) std.math.clamp(uv.x, self.u[0], self.u[1]) else uv.x,
        .y = if (self.period[1] == 0) std.math.clamp(uv.y, self.v[0], self.v[1]) else uv.y,
    };
}

/// Projects the 1/3 and 2/3 nodes of on-contour edges onto n·v = 0 via OCCT
/// `roots` along cell-scaled perpendicular brackets in (u, v).
fn projectContourThirds(self: *Sheet, list: []const ContourThird) Error!void {
    if (list.len == 0) return;
    const a = self.allocator;
    const Pending = struct { node: u32, mid: g.Point, perp: g.Point, nlen: f64 };
    var work: std.ArrayList(Pending) = .empty;
    for (list) |item| {
        const ci = item.cell % self.cu;
        const cj = item.cell / self.cu;
        const hu = @max(self.edges[0][ci + 1] - self.edges[0][ci], 1e-12);
        const hv = @max(self.edges[1][cj + 1] - self.edges[1][cj], 1e-12);
        const p0 = self.nodes.items[item.key[0]].uv;
        const p1 = lattice_nodes.near(self, p0, self.nodes.items[item.key[1]].uv);
        const d = p1.sub(p0);
        const nd: g.Point = .{ .x = d.x / hu, .y = d.y / hv };
        const nlen = nd.norm();
        if (!(nlen > 1e-12)) continue;
        const perp: g.Point = .{ .x = (-nd.y / nlen) * hu, .y = (nd.x / nlen) * hv };
        for ([2]f64{ 1.0 / 3.0, 2.0 / 3.0 }, item.nodes) |frac, node_id| {
            try work.append(a, .{ .node = node_id, .mid = p0.add(d.scale(frac)), .perp = perp, .nlen = nlen });
        }
    }
    if (work.items.len == 0) return;
    var active = work.items;
    for ([2]f64{ 0.25, 0.55 }) |scale| {
        if (active.len == 0) break;
        const segs = try a.alloc([2]g.Point, active.len);
        for (active, segs) |w, *seg| {
            const delta = w.perp.scale(scale * w.nlen);
            seg.* = .{ clampUv(self, w.mid.sub(delta)), clampUv(self, w.mid.add(delta)) };
        }
        const found = try a.alloc(?f64, active.len);
        try self.shading.surfaces.roots(a, self.face, segs, self.shading.eye, 0, 1e-12, found);
        var missed: std.ArrayList(Pending) = .empty;
        for (active, segs, found) |w, seg, root| {
            if (root) |s| {
                self.nodes.items[w.node].uv = seg[0].add(seg[1].sub(seg[0]).scale(s));
            } else try missed.append(a, w);
        }
        active = missed.items;
    }
}

/// Fills the 4 interior sample nodes of every non-aligned piece using discrete
/// Coons interpolation of its 4 boundary edges in (u, v), so interior samples
/// conform smoothly to projected curved contour edges.
fn fillInteriorSamples(self: *Sheet, placed: []const Placed, ids: [][16]u32) !void {
    for (placed, ids) |p, *id| {
        const a, const b, const c, const d = p.piece;
        const aligned = a.lattice and b.lattice and c.lattice and d.lattice and
            b.i - a.i == d.j - a.j and b.j == a.j and d.i == a.i and c.i == b.i and c.j == d.j;
        if (aligned) continue;
        const base = self.nodes.items[id[0]].uv;
        var bnd: [16]g.Point = undefined;
        for ([_]usize{ 0, 1, 2, 3, 4, 8, 12, 13, 14, 15, 7, 11 }) |k| {
            bnd[k] = lattice_nodes.near(self, base, self.nodes.items[id[k]].uv);
        }
        const uv_corners = [4]g.Point{ bnd[0], bnd[12], bnd[15], bnd[3] };
        for (1..3) |i| for (1..3) |j| {
            const s = @as(f64, @floatFromInt(i)) / 3.0;
            const t = @as(f64, @floatFromInt(j)) / 3.0;
            const coons = bnd[j].scale(1 - s)
                .add(bnd[12 + j].scale(s))
                .add(bnd[i * 4].scale(1 - t))
                .add(bnd[i * 4 + 3].scale(t))
                .sub(bilinear(uv_corners, s, t));
            id[i * 4 + j] = try lattice_nodes.request(self, clampUv(self, coons), 0);
        };
    }
}

/// Builds `DepthPatch`es over `placed` carrying n·l, the script's field,
/// glint on `fine` gleaming cells, and exact 3D camera depth coefficients.
pub fn depthPatches(self: *Sheet, placed: []const Placed, fine: bool, out: []DepthPatch, strays: []f64) Error!void {
    const a = self.allocator;
    const ids = try a.alloc([16]u32, placed.len);
    var contour_list: std.ArrayList(ContourThird) = .empty;
    for (placed, ids) |p, *id| id.* = try self.samples(p.piece, p.cell, &contour_list);
    try projectContourThirds(self, contour_list.items);
    try fillInteriorSamples(self, placed, ids);
    try lattice_nodes.flush(self);
    const sheet_id: u8 = if (self.face.back) 1 else 0;
    for (placed, ids, out, strays) |p, id, *dp, *stray| {
        const highlight = fine and self.cells[p.cell].gleams;
        var xs: [16]f64 = undefined;
        var ys: [16]f64 = undefined;
        var zs: [16]f64 = undefined;
        var diffuse: [16]f64 = undefined;
        var glint: [16]f64 = @splat(0);
        var field: [16]f64 = undefined;
        var flipped = false;
        for (id, &xs, &ys, &zs, &diffuse, &glint, &field) |node_id, *x, *y, *z, *d, *h, *v| {
            const n = self.nodes.items[node_id];
            x.* = n.x;
            y.* = n.y;
            z.* = n.depth;
            d.* = n.shine.diffuse;
            if (highlight) h.* = n.shine.glint;
            v.* = n.value;
            if ((n.place & on_contour) == 0 and n.facing < -1e-6) flipped = true;
        }
        const px = coefficients(xs);
        const py = coefficients(ys);
        var patch: Patch = undefined;
        for (&patch.points, px, py) |*point, x, y| point.* = .{ .x = x, .y = y };
        patch.diffuse = coefficients(diffuse);
        patch.glint = coefficients(glint);
        patch.values = coefficients(field);
        dp.* = .{
            .patch = patch,
            .pz = coefficients(zs),
            .sheet = sheet_id,
            .facing_flipped = flipped,
        };
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
    const c = bezier(1, 4, -2, 3);
    for ([_]f64{ 0, 1.0 / 3.0, 2.0 / 3.0, 1 }, [_]f64{ 1, 4, -2, 3 }) |s, expected| {
        const r = 1 - s;
        const b = [4]f64{ r * r * r, 3 * s * r * r, 3 * s * s * r, s * s * s };
        try std.testing.expectApproxEqAbs(expected, b[0] * c[0] + b[1] * c[1] + b[2] * c[2] + b[3] * c[3], 1e-12);
    }
}
