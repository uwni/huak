//! Watertight conforming Bézier patch tessellation onto a 2x2 SSAA strip buffer.
//!
//! Each boundary cubic curve computes its subdivision count symmetrically from
//! its own 4 control points and evaluates points in a canonical endpoint order,
//! so adjacent patches share bit-identical edge vertices with zero T-junctions.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");
const style = @import("../../../drawing/style.zig");
const patch_mesh = @import("../../../drawing/patches.zig");
const color_patches = @import("../../../drawing/color_patches.zig");
const scan = @import("scan.zig");
const Color = style.Color;
const Gradient = style.Gradient;

const max_subdiv: usize = 64;
/// Maximum geometric deviation from a cubic curve in subpixel units (= 1/16 output px).
const flatness_tol: f64 = 0.125;
/// Maximum bilinear color twist across one cell before subdividing.
const color_twist_tol: f64 = 0.25 / 255.0;

/// Rasterizes all `ColorPatches` overlapping `strip`.
pub fn rasterColorStrip(
    strip: *const scan.Strip,
    patches: Gradient.ColorPatches,
    patch_ids: []const u32,
    box: g.BBox,
    scale_x: f64,
    scale_y: f64,
    opaque_pad: bool,
) void {
    for (patch_ids) |id| {
        const corners = patches.colors[id];
        if (corners[0].a == 0 and corners[1].a == 0 and corners[2].a == 0 and corners[3].a == 0) continue;
        const net = toSubNet(&patches.points[id], box, scale_x, scale_y);
        tessellateColorPatch(strip, &net, corners, opaque_pad);
    }
}

/// Rasterizes all scalar-field `Patches` overlapping `strip`.
pub fn rasterFieldStrip(
    strip: *const scan.Strip,
    patches: Gradient.Patches,
    patch_ids: []const u32,
    box: g.BBox,
    scale_x: f64,
    scale_y: f64,
    opaque_pad: bool,
) void {
    const tol = @max(patches.tolerance, 1.0 / 512.0);
    for (patch_ids) |id| {
        const values = &patches.values[id];
        if (!patches.stops.paints(values)) continue;
        const net = toSubNet(&patches.points[id], box, scale_x, scale_y);
        tessellateFieldPatch(strip, &net, values, patches.stops, tol, opaque_pad);
    }
}

fn toSubNet(src: *const [16]g.Point, box: g.BBox, scale_x: f64, scale_y: f64) [16]g.Point {
    var out: [16]g.Point = undefined;
    for (src, &out) |p, *dst| {
        dst.* = .{
            .x = (p.x - box.min.x) * scale_x,
            .y = (box.max.y - p.y) * scale_y,
        };
    }
    return out;
}

/// Symmetric power-of-two Wang flatness subdivision count for a cubic curve.
/// Power-of-two counts align dyadic split points across quadtree neighbors,
/// and canonicalizing endpoint order guarantees identical counts on shared edges.
fn curveSteps(c_in: [4]g.Point) usize {
    const c = if (canonicalReverse(c_in)) [4]g.Point{ c_in[3], c_in[2], c_in[1], c_in[0] } else c_in;
    const d1 = g.Point{ .x = c[0].x - 2 * c[1].x + c[2].x, .y = c[0].y - 2 * c[1].y + c[2].y };
    const d2 = g.Point{ .x = c[1].x - 2 * c[2].x + c[3].x, .y = c[1].y - 2 * c[2].y + c[3].y };
    const m = @max(d1.norm(), d2.norm());
    if (!(m > 0)) return 1;
    const n_f = @ceil(@sqrt(0.75 * m / flatness_tol));
    if (!std.math.isFinite(n_f) or n_f <= 1) return 1;
    const raw: usize = @min(max_subdiv, @as(usize, @intFromFloat(n_f)));
    return std.math.ceilPowerOfTwoAssert(usize, raw);
}

/// Canonical direction predicate so reversed edges execute identical float ops.
fn canonicalReverse(c: [4]g.Point) bool {
    if (c[0].x != c[3].x) return c[3].x < c[0].x;
    if (c[0].y != c[3].y) return c[3].y < c[0].y;
    if (c[1].x != c[2].x) return c[2].x < c[1].x;
    return c[2].y < c[1].y;
}

fn evalCubic(c: [4]g.Point, t: f64) g.Point {
    const b = patch_mesh.bernstein(t);
    return .{
        .x = c[0].x * b[0] + c[1].x * b[1] + c[2].x * b[2] + c[3].x * b[3],
        .y = c[0].y * b[0] + c[1].y * b[1] + c[2].y * b[2] + c[3].y * b[3],
    };
}

/// Evaluates `k / n` along cubic `c` using canonical endpoint order.
fn evalCanonicalEdge(c: [4]g.Point, k: usize, n: usize) g.Point {
    if (k == 0) return c[0];
    if (k == n) return c[3];
    if (canonicalReverse(c)) {
        const rev = [4]g.Point{ c[3], c[2], c[1], c[0] };
        const t = @as(f64, @floatFromInt(n - k)) / @as(f64, @floatFromInt(n));
        return evalCubic(rev, t);
    }
    const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
    return evalCubic(c, t);
}

fn evalPatchPoint(net: *const [16]g.Point, u: f64, v: f64) g.Point {
    const bu = patch_mesh.bernstein(u);
    const bv = patch_mesh.bernstein(v);
    var x: f64 = 0;
    var y: f64 = 0;
    for (0..4) |i| for (0..4) |j| {
        const w = bu[i] * bv[j];
        const p = net[i * 4 + j];
        x += p.x * w;
        y += p.y * w;
    };
    return .{ .x = x, .y = y };
}

fn netExtentSubpx(net: *const [16]g.Point) [2]f64 {
    var u_span: f64 = 0;
    var v_span: f64 = 0;
    for (0..4) |j| {
        var len: f64 = 0;
        for (0..3) |i| len += net[i * 4 + j].distance(net[(i + 1) * 4 + j]);
        u_span = @max(u_span, len);
    }
    for (0..4) |i| {
        var len: f64 = 0;
        for (0..3) |j| len += net[i * 4 + j].distance(net[i * 4 + j + 1]);
        v_span = @max(v_span, len);
    }
    return .{ u_span, v_span };
}

fn patchBoundaryCurves(net: *const [16]g.Point) struct {
    bottom: [4]g.Point,
    top: [4]g.Point,
    left: [4]g.Point,
    right: [4]g.Point,
} {
    return .{
        .bottom = .{ net[0], net[4], net[8], net[12] },
        .top = .{ net[3], net[7], net[11], net[15] },
        .left = .{ net[0], net[1], net[2], net[3] },
        .right = .{ net[12], net[13], net[14], net[15] },
    };
}

fn interiorCurveSteps(net: *const [16]g.Point) [2]usize {
    var nu: usize = 1;
    var nv: usize = 1;
    for ([_]usize{ 1, 2 }) |j| {
        nu = @max(nu, curveSteps(.{ net[j], net[4 + j], net[8 + j], net[12 + j] }));
    }
    for ([_]usize{ 1, 2 }) |i| {
        nv = @max(nv, curveSteps(.{ net[i * 4], net[i * 4 + 1], net[i * 4 + 2], net[i * 4 + 3] }));
    }
    return .{ nu, nv };
}

fn scalarSteps(values: *const [16]f64, tol: f64) [2]usize {
    var max_du: f64 = 0;
    var max_dv: f64 = 0;
    for (0..4) |j| {
        const d1 = @abs(values[j] - 2 * values[4 + j] + values[8 + j]);
        const d2 = @abs(values[4 + j] - 2 * values[8 + j] + values[12 + j]);
        max_du = @max(max_du, @max(d1, d2));
    }
    for (0..4) |i| {
        const d1 = @abs(values[i * 4] - 2 * values[i * 4 + 1] + values[i * 4 + 2]);
        const d2 = @abs(values[i * 4 + 1] - 2 * values[i * 4 + 2] + values[i * 4 + 3]);
        max_dv = @max(max_dv, @max(d1, d2));
    }
    // Cross-derivative / bilinear twist across the patch.
    var max_twist: f64 = 0;
    for (0..3) |i| for (0..3) |j| {
        const tw = @abs(values[i * 4 + j] - values[i * 4 + j + 1] - values[(i + 1) * 4 + j] + values[(i + 1) * 4 + j + 1]);
        max_twist = @max(max_twist, tw);
    };
    const twist_n = @sqrt(@max(0.0, 2.25 * max_twist / tol));
    const nu_f = @ceil(@max(@sqrt(@max(0.0, 0.75 * max_du / tol)), twist_n));
    const nv_f = @ceil(@max(@sqrt(@max(0.0, 0.75 * max_dv / tol)), twist_n));
    return .{
        if (!std.math.isFinite(nu_f) or nu_f <= 1) 1 else @min(max_subdiv, @as(usize, @intFromFloat(nu_f))),
        if (!std.math.isFinite(nv_f) or nv_f <= 1) 1 else @min(max_subdiv, @as(usize, @intFromFloat(nv_f))),
    };
}

fn tessellateColorPatch(strip: *const scan.Strip, net: *const [16]g.Point, corners: [4]Color, opaque_pad: bool) void {
    const edges = patchBoundaryCurves(net);
    const n_bot = curveSteps(edges.bottom);
    const n_top = curveSteps(edges.top);
    const n_left = curveSteps(edges.left);
    const n_right = curveSteps(edges.right);
    const inner = interiorCurveSteps(net);

    var nu = @max(@max(n_bot, n_top), inner[0]);
    var nv = @max(@max(n_left, n_right), inner[1]);

    // Check bilinear color twist across the patch so diagonal triangulation stays exact.
    const twist = @max(
        @max(@abs(corners[0].r - corners[1].r + corners[2].r - corners[3].r), @abs(corners[0].g - corners[1].g + corners[2].g - corners[3].g)),
        @max(@abs(corners[0].b - corners[1].b + corners[2].b - corners[3].b), @abs(corners[0].a - corners[1].a + corners[2].a - corners[3].a)),
    );
    if (twist > 4.0 * color_twist_tol) {
        const span = netExtentSubpx(net);
        const cap_u: usize = @min(max_subdiv, @max(1, @as(usize, @intFromFloat(@ceil(span[0] * 2.0)))));
        const cap_v: usize = @min(max_subdiv, @max(1, @as(usize, @intFromFloat(@ceil(span[1] * 2.0)))));
        const need: usize = @min(max_subdiv, @as(usize, @intFromFloat(@ceil(@sqrt(twist / (4.0 * color_twist_tol))))));
        nu = @max(nu, @min(need, cap_u));
        nv = @max(nv, @min(need, cap_v));
    }

    const Eval = struct {
        corners: [4]Color,
        opaque_pad: bool,
        inline fn vertex(self: @This(), p: g.Point, u: f64, v: f64) scan.ColorVertex {
            return .{ .p = p, .c = color_patches.bilinearColor(self.corners, u, v) };
        }
        inline fn emit(self: @This(), s: *const scan.Strip, a: scan.ColorVertex, b: scan.ColorVertex, c: scan.ColorVertex) void {
            scan.colorTriangle(s, a, b, c, self.opaque_pad);
        }
    };
    emitConforming(strip, net, edges, n_bot, n_top, n_left, n_right, nu, nv, Eval{ .corners = corners, .opaque_pad = opaque_pad });
}

fn tessellateFieldPatch(strip: *const scan.Strip, net: *const [16]g.Point, values: *const [16]f64, stops: Gradient.Stops, tol: f64, opaque_pad: bool) void {
    const edges = patchBoundaryCurves(net);
    const n_bot = curveSteps(edges.bottom);
    const n_top = curveSteps(edges.top);
    const n_left = curveSteps(edges.left);
    const n_right = curveSteps(edges.right);
    const inner = interiorCurveSteps(net);
    const field_n = scalarSteps(values, tol);
    const span = netExtentSubpx(net);
    const cap_u: usize = @min(max_subdiv, @max(1, @as(usize, @intFromFloat(@ceil(span[0] * 2.0)))));
    const cap_v: usize = @min(max_subdiv, @max(1, @as(usize, @intFromFloat(@ceil(span[1] * 2.0)))));

    const nu = @max(@max(n_bot, n_top), @max(inner[0], @min(field_n[0], cap_u)));
    const nv = @max(@max(n_left, n_right), @max(inner[1], @min(field_n[1], cap_v)));

    const Eval = struct {
        values: *const [16]f64,
        stops: Gradient.Stops,
        opaque_pad: bool,
        inline fn vertex(self: @This(), p: g.Point, u: f64, v: f64) scan.FieldVertex {
            return .{ .p = p, .v = patch_mesh.evalScalar(self.values, u, v) };
        }
        inline fn emit(self: @This(), s: *const scan.Strip, a: scan.FieldVertex, b: scan.FieldVertex, c: scan.FieldVertex) void {
            scan.fieldTriangle(s, a, b, c, self.stops, self.opaque_pad);
        }
    };
    emitConforming(strip, net, edges, n_bot, n_top, n_left, n_right, nu, nv, Eval{ .values = values, .stops = stops, .opaque_pad = opaque_pad });
}

fn emitConforming(
    strip: *const scan.Strip,
    net: *const [16]g.Point,
    edges: anytype,
    n_bot: usize,
    n_top: usize,
    n_left: usize,
    n_right: usize,
    nu_in: usize,
    nv_in: usize,
    eval: anytype,
) void {
    const V = @TypeOf(eval.vertex(g.Point.zero, 0, 0));

    // Fast path: uniform grid when all four edges match (includes 1x1 quads).
    if (n_bot == nu_in and n_top == nu_in and n_left == nv_in and n_right == nv_in) {
        const nu = nu_in;
        const nv = nv_in;
        var prev_row: [max_subdiv + 1]V = undefined;
        var curr_row: [max_subdiv + 1]V = undefined;
        for (0..nu + 1) |i| {
            const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nu));
            prev_row[i] = eval.vertex(evalCanonicalEdge(edges.bottom, i, nu), u, 0);
        }
        for (1..nv + 1) |j| {
            const v = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(nv));
            curr_row[0] = eval.vertex(evalCanonicalEdge(edges.left, j, nv), 0, v);
            curr_row[nu] = eval.vertex(evalCanonicalEdge(edges.right, j, nv), 1, v);
            if (j == nv) {
                for (1..nu) |i| {
                    const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nu));
                    curr_row[i] = eval.vertex(evalCanonicalEdge(edges.top, i, nu), u, 1);
                }
            } else {
                for (1..nu) |i| {
                    const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nu));
                    curr_row[i] = eval.vertex(evalPatchPoint(net, u, v), u, v);
                }
            }
            for (0..nu) |i| {
                eval.emit(strip, prev_row[i], prev_row[i + 1], curr_row[i + 1]);
                eval.emit(strip, prev_row[i], curr_row[i + 1], curr_row[i]);
            }
            @memcpy(prev_row[0 .. nu + 1], curr_row[0 .. nu + 1]);
        }
        return;
    }

    // General conforming tessellation: strictly interior grid [1..nu-1] x [1..nv-1]
    // stitched to the four canonical outer edges via a zero-T-junction zipper.
    const nu = @max(nu_in, 2);
    const nv = @max(nv_in, 2);
    const in_w = nu - 1;
    const in_h = nv - 1;

    var inner_bot: [max_subdiv]V = undefined;
    var inner_top: [max_subdiv]V = undefined;
    var inner_left: [max_subdiv]V = undefined;
    var inner_right: [max_subdiv]V = undefined;

    var prev_row: [max_subdiv]V = undefined;
    var curr_row: [max_subdiv]V = undefined;

    for (0..in_h) |jj| {
        const v = @as(f64, @floatFromInt(jj + 1)) / @as(f64, @floatFromInt(nv));
        for (0..in_w) |ii| {
            const u = @as(f64, @floatFromInt(ii + 1)) / @as(f64, @floatFromInt(nu));
            curr_row[ii] = eval.vertex(evalPatchPoint(net, u, v), u, v);
        }
        if (jj == 0) @memcpy(inner_bot[0..in_w], curr_row[0..in_w]);
        if (jj + 1 == in_h) @memcpy(inner_top[0..in_w], curr_row[0..in_w]);
        inner_left[jj] = curr_row[0];
        inner_right[jj] = curr_row[in_w - 1];
        if (jj > 0) {
            for (0..in_w - 1) |ii| {
                eval.emit(strip, prev_row[ii], prev_row[ii + 1], curr_row[ii + 1]);
                eval.emit(strip, prev_row[ii], curr_row[ii + 1], curr_row[ii]);
            }
        }
        @memcpy(prev_row[0..in_w], curr_row[0..in_w]);
    }

    var outer: [max_subdiv + 1]V = undefined;
    // Bottom edge: u = 0 -> 1, v = 0.
    for (0..n_bot + 1) |k| {
        const u = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_bot));
        outer[k] = eval.vertex(evalCanonicalEdge(edges.bottom, k, n_bot), u, 0);
    }
    zipEdge(strip, outer[0 .. n_bot + 1], inner_bot[0..in_w], nu, eval);

    // Right edge: v = 0 -> 1, u = 1.
    for (0..n_right + 1) |k| {
        const v = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_right));
        outer[k] = eval.vertex(evalCanonicalEdge(edges.right, k, n_right), 1, v);
    }
    zipEdge(strip, outer[0 .. n_right + 1], inner_right[0..in_h], nv, eval);

    // Top edge: u = 1 -> 0, v = 1 (reversed inner_top to match CCW perimeter).
    for (0..n_top + 1) |k| {
        const idx = n_top - k;
        const u = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_top));
        outer[k] = eval.vertex(evalCanonicalEdge(edges.top, idx, n_top), u, 1);
    }
    var rev_top: [max_subdiv]V = undefined;
    for (0..in_w) |ii| rev_top[ii] = inner_top[in_w - 1 - ii];
    zipEdge(strip, outer[0 .. n_top + 1], rev_top[0..in_w], nu, eval);

    // Left edge: v = 1 -> 0, u = 0 (reversed inner_left to match CCW perimeter).
    for (0..n_left + 1) |k| {
        const idx = n_left - k;
        const v = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_left));
        outer[k] = eval.vertex(evalCanonicalEdge(edges.left, idx, n_left), 0, v);
    }
    var rev_left: [max_subdiv]V = undefined;
    for (0..in_h) |jj| rev_left[jj] = inner_left[in_h - 1 - jj];
    zipEdge(strip, outer[0 .. n_left + 1], rev_left[0..in_h], nv, eval);
}

fn zipEdge(strip: *const scan.Strip, outer: anytype, inner: @TypeOf(outer), grid_n: usize, eval: anytype) void {
    const m = outer.len - 1;
    const k = inner.len;
    var o: usize = 0;
    var ii: usize = 0;
    while (o < m or ii + 1 < k) {
        const advance_outer = if (o == m) false else if (ii + 1 == k) true else (o + 1) * grid_n <= (ii + 2) * m;
        if (advance_outer) {
            eval.emit(strip, outer[o], outer[o + 1], inner[ii]);
            o += 1;
        } else {
            eval.emit(strip, outer[o], inner[ii + 1], inner[ii]);
            ii += 1;
        }
    }
}
