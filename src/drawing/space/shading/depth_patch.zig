//! 3D cubic Bézier patch geometry and Newell (1972) pairwise depth comparison:
//! Bernstein convex-hull 3D bounds, 2D separating-axis test, Newell 3D
//! supporting-plane slab test, exact 2D Newton inversion on overlap samples,
//! boundary segment crossings, and exact midpoint de Casteljau subdivision.
const std = @import("std");
const space_shading = @import("../shading.zig");
const patches_mod = @import("patches.zig");
const patch_math = @import("../../patches.zig");
const Patch = space_shading.Patch;
const DepthPatch = patches_mod.DepthPatch;
const g = @import("../../geometry.zig");
const side_controls = patches_mod.side_controls;

pub const max_subdiv_depth: u8 = 10;

pub const Relation = enum { disjoint, a_behind_b, b_behind_a, straddle };

pub const NodePatch = struct {
    px: [16]f64,
    py: [16]f64,
    pz: [16]f64,
    diffuse: [16]f64,
    glint: [16]f64,
    values: [16]f64,
    x_min: f64,
    x_max: f64,
    y_min: f64,
    y_max: f64,
    z_min: f64,
    z_max: f64,
    z_avg: f64,
    nx: f64,
    ny: f64,
    nz: f64,
    d_min: f64,
    d_max: f64,
    sheet: u8,
    subdiv_depth: u8,
    alive: bool = true,

    pub fn fromDepthInto(self: *NodePatch, dp: *const DepthPatch) void {
        for (dp.patch.points, &self.px, &self.py) |pt, *x, *y| {
            x.* = pt.x;
            y.* = pt.y;
        }
        self.pz = dp.pz;
        self.diffuse = dp.patch.diffuse;
        self.glint = dp.patch.glint;
        self.values = dp.patch.values;
        self.finalize(dp.sheet, 0);
    }

    pub fn finalize(self: *NodePatch, sheet: u8, subdiv_depth: u8) void {
        const px = &self.px;
        const py = &self.py;
        const pz = &self.pz;
        var x_min = px[0];
        var x_max = px[0];
        var y_min = py[0];
        var y_max = py[0];
        var z_min = pz[0];
        var z_max = pz[0];
        var z_sum: f64 = 0;
        for (0..16) |k| {
            x_min = @min(x_min, px[k]);
            x_max = @max(x_max, px[k]);
            y_min = @min(y_min, py[k]);
            y_max = @max(y_max, py[k]);
            z_min = @min(z_min, pz[k]);
            z_max = @max(z_max, pz[k]);
            z_sum += pz[k];
        }
        // Newell diagonal cross product (p15 - p0) x (p3 - p12): non-zero for
        // both quads and collapsed triangles (p3 == p15).
        const diag_u: space_shading.Vec3 = .{ px[15] - px[0], py[15] - py[0], pz[15] - pz[0] };
        const diag_v: space_shading.Vec3 = .{ px[3] - px[12], py[3] - py[12], pz[3] - pz[12] };
        var normal = space_shading.cross(diag_u, diag_v);
        const nlen = @sqrt(space_shading.dot(normal, normal));
        var d_min: f64 = 0;
        var d_max: f64 = 0;
        if (nlen > 0 and @abs(normal[2]) > 1e-12 * nlen) {
            const sign: f64 = if (normal[2] < 0) -1.0 / nlen else 1.0 / nlen;
            normal = .{ normal[0] * sign, normal[1] * sign, normal[2] * sign };
            d_min = space_shading.dot(normal, .{ px[0], py[0], pz[0] });
            d_max = d_min;
            for (1..16) |k| {
                const d = space_shading.dot(normal, .{ px[k], py[k], pz[k] });
                d_min = @min(d_min, d);
                d_max = @max(d_max, d);
            }
        } else {
            normal = .{ 0, 0, 0 };
        }
        self.x_min = x_min;
        self.x_max = x_max;
        self.y_min = y_min;
        self.y_max = y_max;
        self.z_min = z_min;
        self.z_max = z_max;
        self.z_avg = z_sum / 16.0;
        self.nx = normal[0];
        self.ny = normal[1];
        self.nz = normal[2];
        self.d_min = d_min;
        self.d_max = d_max;
        self.sheet = sheet;
        self.subdiv_depth = subdiv_depth;
        self.alive = true;
    }

    pub fn toPatchInto(self: *const NodePatch, out: *Patch) void {
        for (&out.points, self.px, self.py) |*pt, x, y| pt.* = .{ .x = x, .y = y };
        out.diffuse = self.diffuse;
        out.glint = self.glint;
        out.values = self.values;
    }

    pub fn screenSize(self: *const NodePatch) f64 {
        return std.math.hypot(self.x_max - self.x_min, self.y_max - self.y_min);
    }

    pub fn canSubdivide(self: *const NodePatch, min_size: f64) bool {
        return self.subdiv_depth < max_subdiv_depth and @max(self.x_max - self.x_min, self.y_max - self.y_min) > min_size;
    }

    pub fn subdivideInto(self: *const NodePatch, out: *[2]NodePatch) void {
        const span_s = @max(
            std.math.hypot(self.px[12] - self.px[0], self.py[12] - self.py[0]),
            std.math.hypot(self.px[15] - self.px[3], self.py[15] - self.py[3]),
        );
        const span_t = @max(
            std.math.hypot(self.px[3] - self.px[0], self.py[3] - self.py[0]),
            std.math.hypot(self.px[15] - self.px[12], self.py[15] - self.py[12]),
        );
        const along_s = span_s >= span_t;
        patch_math.splitArrayInto(&self.px, along_s, &out[0].px, &out[1].px);
        patch_math.splitArrayInto(&self.py, along_s, &out[0].py, &out[1].py);
        patch_math.splitArrayInto(&self.pz, along_s, &out[0].pz, &out[1].pz);
        patch_math.splitArrayInto(&self.diffuse, along_s, &out[0].diffuse, &out[1].diffuse);
        patch_math.splitArrayInto(&self.glint, along_s, &out[0].glint, &out[1].glint);
        patch_math.splitArrayInto(&self.values, along_s, &out[0].values, &out[1].values);
        const depth = self.subdiv_depth + 1;
        out[0].finalize(self.sheet, depth);
        out[1].finalize(self.sheet, depth);
    }
};

/// Newell (1972) comparison cascade for two patches with overlapping 2D bboxes.
pub fn compare(a: *const NodePatch, b: *const NodePatch, scale: f64) Relation {
    if (a.z_max <= b.z_min) return .a_behind_b;
    if (b.z_max <= a.z_min) return .b_behind_a;
    if (separated2D(a, b)) return .disjoint;

    if (b.nz > 0) {
        const nb: space_shading.Vec3 = .{ b.nx, b.ny, b.nz };
        var amin = space_shading.dot(nb, .{ a.px[0], a.py[0], a.pz[0] });
        var amax = amin;
        for (1..16) |k| {
            const d = space_shading.dot(nb, .{ a.px[k], a.py[k], a.pz[k] });
            amin = @min(amin, d);
            amax = @max(amax, d);
        }
        if (amax <= b.d_min) return .a_behind_b;
        if (amin >= b.d_max) return .b_behind_a;
    }
    if (a.nz > 0) {
        const na: space_shading.Vec3 = .{ a.nx, a.ny, a.nz };
        var bmin = space_shading.dot(na, .{ b.px[0], b.py[0], b.pz[0] });
        var bmax = bmin;
        for (1..16) |k| {
            const d = space_shading.dot(na, .{ b.px[k], b.py[k], b.pz[k] });
            bmin = @min(bmin, d);
            bmax = @max(bmax, d);
        }
        if (bmax <= a.d_min) return .b_behind_a;
        if (bmin >= a.d_max) return .a_behind_b;
    }

    if (a.sheet == b.sheet and sharedSameSheetEdge(a, b, scale)) return .disjoint;
    return overlapDepth(a, b, scale);
}

fn separated2D(a: *const NodePatch, b: *const NodePatch) bool {
    const qa = [4][2]f64{ .{ a.px[0], a.py[0] }, .{ a.px[12], a.py[12] }, .{ a.px[15], a.py[15] }, .{ a.px[3], a.py[3] } };
    const qb = [4][2]f64{ .{ b.px[0], b.py[0] }, .{ b.px[12], b.py[12] }, .{ b.px[15], b.py[15] }, .{ b.px[3], b.py[3] } };
    for ([2][4][2]f64{ qa, qb }) |quad| {
        for (0..4) |k| {
            const p0 = quad[k];
            const p1 = quad[(k + 1) % 4];
            const ax = -(p1[1] - p0[1]);
            const ay = p1[0] - p0[0];
            if (ax * ax + ay * ay <= 1e-24) continue;
            var amin = ax * a.px[0] + ay * a.py[0];
            var amax = amin;
            var bmin = ax * b.px[0] + ay * b.py[0];
            var bmax = bmin;
            for (1..16) |i| {
                const pa = ax * a.px[i] + ay * a.py[i];
                const pb = ax * b.px[i] + ay * b.py[i];
                amin = @min(amin, pa);
                amax = @max(amax, pa);
                bmin = @min(bmin, pb);
                bmax = @max(bmax, pb);
            }
            const eps = 1e-11 * @max(1.0, @abs(amin), @abs(amax), @abs(bmin), @abs(bmax));
            if (amax <= bmin + eps or bmax <= amin + eps) return true;
        }
    }
    return false;
}

fn sharedSameSheetEdge(a: *const NodePatch, b: *const NodePatch, scale: f64) bool {
    const tol = 1e-9 * scale;
    for (side_controls) |sa| {
        for (side_controls) |sb| {
            const forward = sameCtrl3(a, sa[0], b, sb[0], tol) and sameCtrl3(a, sa[3], b, sb[3], tol) and
                sameCtrl3(a, sa[1], b, sb[1], tol) and sameCtrl3(a, sa[2], b, sb[2], tol);
            const backward = !forward and sameCtrl3(a, sa[0], b, sb[3], tol) and sameCtrl3(a, sa[3], b, sb[0], tol) and
                sameCtrl3(a, sa[1], b, sb[2], tol) and sameCtrl3(a, sa[2], b, sb[1], tol);
            if (!forward and !backward) continue;
            const ex = a.px[sa[3]] - a.px[sa[0]];
            const ey = a.py[sa[3]] - a.py[sa[0]];
            if (ex * ex + ey * ey <= 1e-24) continue;
            const ca = evalPoint(a, 0.5, 0.5);
            const cb = evalPoint(b, 0.5, 0.5);
            const sa_side = (ca[0] - a.px[sa[0]]) * (-ey) + (ca[1] - a.py[sa[0]]) * ex;
            const sb_side = (cb[0] - a.px[sa[0]]) * (-ey) + (cb[1] - a.py[sa[0]]) * ex;
            if (sa_side * sb_side < 0) return true;
        }
    }
    return false;
}

fn sameCtrl3(a: *const NodePatch, ia: usize, b: *const NodePatch, ib: usize, tol: f64) bool {
    return @abs(a.px[ia] - b.px[ib]) <= tol and @abs(a.py[ia] - b.py[ib]) <= tol and @abs(a.pz[ia] - b.pz[ib]) <= tol;
}

fn overlapDepth(a: *const NodePatch, b: *const NodePatch, scale: f64) Relation {
    const probes = [4]f64{ 0.05, 0.35, 0.65, 0.95 };
    const eps_z = 1e-9 * scale;
    var min_dz = std.math.inf(f64);
    var max_dz = -std.math.inf(f64);
    var hits: usize = 0;

    for (probes) |s| for (probes) |t| {
        const p = evalPoint(a, s, t);
        if (p[0] < b.x_min - 1e-9 or p[0] > b.x_max + 1e-9 or p[1] < b.y_min - 1e-9 or p[1] > b.y_max + 1e-9) continue;
        if (invertPatch(b, p[0], p[1], scale)) |zb| {
            const dz = p[2] - zb;
            hits += 1;
            min_dz = @min(min_dz, dz);
            max_dz = @max(max_dz, dz);
            if (min_dz < -eps_z and max_dz > eps_z) return .straddle;
        }
    };

    for (probes) |s| for (probes) |t| {
        const p = evalPoint(b, s, t);
        if (p[0] < a.x_min - 1e-9 or p[0] > a.x_max + 1e-9 or p[1] < a.y_min - 1e-9 or p[1] > a.y_max + 1e-9) continue;
        if (invertPatch(a, p[0], p[1], scale)) |za| {
            const dz = za - p[2];
            hits += 1;
            min_dz = @min(min_dz, dz);
            max_dz = @max(max_dz, dz);
            if (min_dz < -eps_z and max_dz > eps_z) return .straddle;
        }
    };

    if (hits == 0) {
        const ox = 0.5 * (@max(a.x_min, b.x_min) + @min(a.x_max, b.x_max));
        const oy = 0.5 * (@max(a.y_min, b.y_min) + @min(a.y_max, b.y_max));
        if (invertPatch(a, ox, oy, scale)) |za| if (invertPatch(b, ox, oy, scale)) |zb| {
            const dz = za - zb;
            hits += 1;
            min_dz = @min(min_dz, dz);
            max_dz = @max(max_dz, dz);
        };
        checkBoundaryCrossings(a, b, scale, &hits, &min_dz, &max_dz);
    }

    if (hits == 0) return .disjoint;
    if (min_dz < -eps_z and max_dz > eps_z) return .straddle;
    if (max_dz <= eps_z and min_dz < -eps_z) return .a_behind_b;
    if (min_dz >= -eps_z and max_dz > eps_z) return .b_behind_a;
    return .disjoint;
}

fn checkBoundaryCrossings(a: *const NodePatch, b: *const NodePatch, scale: f64, hits: *usize, min_dz: *f64, max_dz: *f64) void {
    const Seg = struct { x0: f64, y0: f64, x1: f64, y1: f64, z0: f64, z1: f64 };
    var segs_a: [12]Seg = undefined;
    var segs_b: [12]Seg = undefined;
    const fillSegs = struct {
        fn run(p: *const NodePatch, out: *[12]Seg) void {
            const frac = [4]f64{ 0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0 };
            var idx: usize = 0;
            for (0..4) |side| {
                var pts: [4][3]f64 = undefined;
                for (0..4) |k| {
                    const s = switch (side) {
                        0, 2 => frac[k],
                        1 => 1.0,
                        else => 0.0,
                    };
                    const t = switch (side) {
                        0 => 0.0,
                        2 => 1.0,
                        else => frac[k],
                    };
                    pts[k] = evalPoint(p, s, t);
                }
                for (0..3) |k| {
                    out[idx] = .{ .x0 = pts[k][0], .y0 = pts[k][1], .x1 = pts[k + 1][0], .y1 = pts[k + 1][1], .z0 = pts[k][2], .z1 = pts[k + 1][2] };
                    idx += 1;
                }
            }
        }
    }.run;
    fillSegs(a, &segs_a);
    fillSegs(b, &segs_b);
    for (segs_a) |sa| {
        const dax = sa.x1 - sa.x0;
        const day = sa.y1 - sa.y0;
        for (segs_b) |sb| {
            if (@max(sa.x0, sa.x1) < @min(sb.x0, sb.x1) or @max(sb.x0, sb.x1) < @min(sa.x0, sa.x1)) continue;
            if (@max(sa.y0, sa.y1) < @min(sb.y0, sb.y1) or @max(sb.y0, sb.y1) < @min(sa.y0, sa.y1)) continue;
            const dbx = sb.x1 - sb.x0;
            const dby = sb.y1 - sb.y0;
            const den = dax * dby - day * dbx;
            if (@abs(den) <= 1e-18 * scale * scale) continue;
            const rx = sb.x0 - sa.x0;
            const ry = sb.y0 - sa.y0;
            const ta = (rx * dby - ry * dbx) / den;
            const tb = (rx * day - ry * dax) / den;
            if (ta <= 1e-5 or ta >= 1 - 1e-5 or tb <= 1e-5 or tb >= 1 - 1e-5) continue;
            const px = sa.x0 + ta * dax;
            const py = sa.y0 + ta * day;
            const za = invertPatch(a, px, py, scale) orelse (sa.z0 + ta * (sa.z1 - sa.z0));
            const zb = invertPatch(b, px, py, scale) orelse (sb.z0 + tb * (sb.z1 - sb.z0));
            const dz = za - zb;
            hits.* += 1;
            min_dz.* = @min(min_dz.*, dz);
            max_dz.* = @max(max_dz.*, dz);
        }
    }
}

fn evalPoint(p: *const NodePatch, s: f64, t: f64) [3]f64 {
    const bs = patch_math.bernstein(s);
    const bt = patch_math.bernstein(t);
    var x: f64 = 0;
    var y: f64 = 0;
    var z: f64 = 0;
    for (0..4) |i| for (0..4) |j| {
        const w = bs[i] * bt[j];
        const k = i * 4 + j;
        x += p.px[k] * w;
        y += p.py[k] * w;
        z += p.pz[k] * w;
    };
    return .{ x, y, z };
}

fn invertPatch(p: *const NodePatch, x: f64, y: f64, scale: f64) ?f64 {
    var best_i: usize = 1;
    var best_j: usize = 1;
    var best_d2 = std.math.inf(f64);
    for (0..4) |i| for (0..4) |j| {
        const k = i * 4 + j;
        const dx = p.px[k] - x;
        const dy = p.py[k] - y;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best_i = i;
            best_j = j;
        }
    };
    const starts = [2][2]f64{
        .{ std.math.clamp(@as(f64, @floatFromInt(best_i)) / 3.0, 0.05, 0.95), std.math.clamp(@as(f64, @floatFromInt(best_j)) / 3.0, 0.05, 0.95) },
        .{ 0.5, 0.5 },
    };
    const tol = 1e-9 * scale;
    for (starts) |start| {
        var s = start[0];
        var t = start[1];
        for (0..12) |_| {
            const bs = patch_math.bernstein(s);
            const bt = patch_math.bernstein(t);
            const dbs = patch_math.dBernstein(s);
            const dbt = patch_math.dBernstein(t);
            var ex: f64 = -x;
            var ey: f64 = -y;
            var x_s: f64 = 0;
            var x_t: f64 = 0;
            var y_s: f64 = 0;
            var y_t: f64 = 0;
            for (0..4) |i| for (0..4) |j| {
                const k = i * 4 + j;
                const w = bs[i] * bt[j];
                const ws = dbs[i] * bt[j];
                const wt = bs[i] * dbt[j];
                ex += p.px[k] * w;
                ey += p.py[k] * w;
                x_s += p.px[k] * ws;
                x_t += p.px[k] * wt;
                y_s += p.py[k] * ws;
                y_t += p.py[k] * wt;
            };
            if (@abs(ex) + @abs(ey) <= tol) {
                if (s >= -1e-6 and s <= 1 + 1e-6 and t >= -1e-6 and t <= 1 + 1e-6) {
                    return patch_math.evalScalar(&p.pz, std.math.clamp(s, 0, 1), std.math.clamp(t, 0, 1));
                }
                break;
            }
            const det = x_s * y_t - x_t * y_s;
            if (!(@abs(det) > 1e-24 * scale * scale)) break;
            s = std.math.clamp(s - (ex * y_t - ey * x_t) / det, -0.25, 1.25);
            t = std.math.clamp(t - (x_s * ey - y_s * ex) / det, -0.25, 1.25);
        }
    }
    return null;
}
