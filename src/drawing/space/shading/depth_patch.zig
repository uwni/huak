//! 3D cubic Bézier patch geometry and Newell (1972) pairwise depth comparison:
//! Bernstein convex-hull 3D bounds, 2D separating-axis test, Newell 3D
//! supporting-plane slab test, exact 2D Newton inversion on overlap samples,
//! boundary segment crossings, and exact midpoint de Casteljau subdivision.
const std = @import("std");
const space_shading = @import("../shading.zig");
const patches_mod = @import("patches.zig");
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

    pub fn fromDepth(dp: DepthPatch) NodePatch {
        var px: [16]f64 = undefined;
        var py: [16]f64 = undefined;
        for (dp.patch.points, &px, &py) |pt, *x, *y| {
            x.* = pt.x;
            y.* = pt.y;
        }
        return init(px, py, dp.pz, dp.patch.diffuse, dp.patch.glint, dp.patch.values, dp.sheet, 0);
    }

    pub fn init(px: [16]f64, py: [16]f64, pz: [16]f64, diffuse: [16]f64, glint: [16]f64, values: [16]f64, sheet: u8, subdiv_depth: u8) NodePatch {
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
        const ux = px[15] - px[0];
        const uy = py[15] - py[0];
        const uz = pz[15] - pz[0];
        const vx = px[3] - px[12];
        const vy = py[3] - py[12];
        const vz = pz[3] - pz[12];
        var nx = uy * vz - uz * vy;
        var ny = uz * vx - ux * vz;
        var nz = ux * vy - uy * vx;
        const nlen = @sqrt(nx * nx + ny * ny + nz * nz);
        var d_min: f64 = 0;
        var d_max: f64 = 0;
        if (nlen > 0 and @abs(nz) > 1e-12 * nlen) {
            const sign: f64 = if (nz < 0) -1.0 / nlen else 1.0 / nlen;
            nx *= sign;
            ny *= sign;
            nz *= sign;
            d_min = nx * px[0] + ny * py[0] + nz * pz[0];
            d_max = d_min;
            for (1..16) |k| {
                const d = nx * px[k] + ny * py[k] + nz * pz[k];
                d_min = @min(d_min, d);
                d_max = @max(d_max, d);
            }
        } else {
            nx = 0;
            ny = 0;
            nz = 0;
        }
        return .{
            .px = px,
            .py = py,
            .pz = pz,
            .diffuse = diffuse,
            .glint = glint,
            .values = values,
            .x_min = x_min,
            .x_max = x_max,
            .y_min = y_min,
            .y_max = y_max,
            .z_min = z_min,
            .z_max = z_max,
            .z_avg = z_sum / 16.0,
            .nx = nx,
            .ny = ny,
            .nz = nz,
            .d_min = d_min,
            .d_max = d_max,
            .sheet = sheet,
            .subdiv_depth = subdiv_depth,
        };
    }

    pub fn toPatch(self: *const NodePatch) Patch {
        var pts: [16]g.Point = undefined;
        for (&pts, self.px, self.py) |*pt, x, y| pt.* = .{ .x = x, .y = y };
        return .{ .points = pts, .diffuse = self.diffuse, .glint = self.glint, .values = self.values };
    }

    pub fn screenSize(self: *const NodePatch) f64 {
        return std.math.hypot(self.x_max - self.x_min, self.y_max - self.y_min);
    }

    pub fn canSubdivide(self: *const NodePatch, min_size: f64) bool {
        return self.subdiv_depth < max_subdiv_depth and @max(self.x_max - self.x_min, self.y_max - self.y_min) > min_size;
    }

    pub fn subdivide(self: *const NodePatch) [2]NodePatch {
        const span_s = @max(
            std.math.hypot(self.px[12] - self.px[0], self.py[12] - self.py[0]),
            std.math.hypot(self.px[15] - self.px[3], self.py[15] - self.py[3]),
        );
        const span_t = @max(
            std.math.hypot(self.px[3] - self.px[0], self.py[3] - self.py[0]),
            std.math.hypot(self.px[15] - self.px[12], self.py[15] - self.py[12]),
        );
        const along_s = span_s >= span_t;
        const px = splitArray(self.px, along_s);
        const py = splitArray(self.py, along_s);
        const pz = splitArray(self.pz, along_s);
        const diffuse = splitArray(self.diffuse, along_s);
        const glint = splitArray(self.glint, along_s);
        const values = splitArray(self.values, along_s);
        const depth = self.subdiv_depth + 1;
        return .{
            init(px[0], py[0], pz[0], diffuse[0], glint[0], values[0], self.sheet, depth),
            init(px[1], py[1], pz[1], diffuse[1], glint[1], values[1], self.sheet, depth),
        };
    }
};

/// Newell (1972) comparison cascade for two patches with overlapping 2D bboxes.
pub fn compare(a: *const NodePatch, b: *const NodePatch, scale: f64) Relation {
    if (a.z_max <= b.z_min) return .a_behind_b;
    if (b.z_max <= a.z_min) return .b_behind_a;
    if (separated2D(a, b)) return .disjoint;

    if (b.nz > 0) {
        var amin = b.nx * a.px[0] + b.ny * a.py[0] + b.nz * a.pz[0];
        var amax = amin;
        for (1..16) |k| {
            const d = b.nx * a.px[k] + b.ny * a.py[k] + b.nz * a.pz[k];
            amin = @min(amin, d);
            amax = @max(amax, d);
        }
        if (amax <= b.d_min) return .a_behind_b;
        if (amin >= b.d_max) return .b_behind_a;
    }
    if (a.nz > 0) {
        var bmin = a.nx * b.px[0] + a.ny * b.py[0] + a.nz * b.pz[0];
        var bmax = bmin;
        for (1..16) |k| {
            const d = a.nx * b.px[k] + a.ny * b.py[k] + a.nz * b.pz[k];
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

fn bernstein(u: f64) [4]f64 {
    const r = 1 - u;
    return .{ r * r * r, 3 * u * r * r, 3 * u * u * r, u * u * u };
}

fn dBernstein(u: f64) [4]f64 {
    const r = 1 - u;
    return .{ -3 * r * r, 3 * r * (1 - 3 * u), 3 * u * (2 - 3 * u), 3 * u * u };
}

fn evalPoint(p: *const NodePatch, s: f64, t: f64) [3]f64 {
    const bs = bernstein(s);
    const bt = bernstein(t);
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

fn evalScalar(c: *const [16]f64, s: f64, t: f64) f64 {
    const bs = bernstein(s);
    const bt = bernstein(t);
    var v: f64 = 0;
    for (0..4) |i| for (0..4) |j| {
        v += c[i * 4 + j] * bs[i] * bt[j];
    };
    return v;
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
            const bs = bernstein(s);
            const bt = bernstein(t);
            const dbs = dBernstein(s);
            const dbt = dBernstein(t);
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
                    return evalScalar(&p.pz, std.math.clamp(s, 0, 1), std.math.clamp(t, 0, 1));
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

fn splitCubic(c: [4]f64) [2][4]f64 {
    const q0 = 0.5 * (c[0] + c[1]);
    const q1 = 0.5 * (c[1] + c[2]);
    const q2 = 0.5 * (c[2] + c[3]);
    const r0 = 0.5 * (q0 + q1);
    const r1 = 0.5 * (q1 + q2);
    const mid = 0.5 * (r0 + r1);
    return .{ .{ c[0], q0, r0, mid }, .{ mid, r1, q2, c[3] } };
}

fn splitArray(src: [16]f64, along_s: bool) [2][16]f64 {
    var out: [2][16]f64 = undefined;
    if (along_s) {
        for (0..4) |j| {
            const parts = splitCubic(.{ src[j], src[4 + j], src[8 + j], src[12 + j] });
            for (0..4) |i| {
                out[0][i * 4 + j] = parts[0][i];
                out[1][i * 4 + j] = parts[1][i];
            }
        }
    } else {
        for (0..4) |i| {
            const parts = splitCubic(.{ src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3] });
            for (0..4) |j| {
                out[0][i * 4 + j] = parts[0][j];
                out[1][i * 4 + j] = parts[1][j];
            }
        }
    }
    return out;
}
