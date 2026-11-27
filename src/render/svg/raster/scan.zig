//! Watertight fixed-point triangle scan-conversion with top-left fill convention
//! onto a 2x2 SSAA premultiplied RGBA strip buffer.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");
const style = @import("../../../drawing/style.zig");
const Color = style.Color;
const Stops = style.Gradient.Stops;

/// Sub-subpixel fixed-point precision: 1/16 of a subpixel (= 1/32 of an output pixel).
const fixed_scale: f64 = 16.0;
const fixed_step: i64 = 16;
const fixed_half: i64 = 8;
/// Coordinate limit where i64 edge products cannot overflow (|delta| <= 2^28 -> product <= 2^56).
const safe_coord: f64 = 1.0e8;

pub const Strip = struct {
    /// Premultiplied linear-channel RGBA in [0, 1], row-major (sub_w * sub_h).
    pixels: [][4]f32,
    sub_w: u32,
    sy_start: u32,
    sub_h: u32,
};

pub const ColorVertex = struct {
    p: g.Point,
    c: Color,
};

pub const FieldVertex = struct {
    p: g.Point,
    v: f64,
};

/// Composites straight-alpha `src` over premultiplied `dst` in channel space.
pub inline fn blendOver(dst: *[4]f32, src: Color) void {
    const a: f32 = @floatCast(src.a);
    if (a <= 0) return;
    if (a >= 1) {
        dst.* = .{ @floatCast(src.r), @floatCast(src.g), @floatCast(src.b), 1 };
        return;
    }
    const inv = 1.0 - a;
    dst[0] = @as(f32, @floatCast(src.r)) * a + dst[0] * inv;
    dst[1] = @as(f32, @floatCast(src.g)) * a + dst[1] * inv;
    dst[2] = @as(f32, @floatCast(src.b)) * a + dst[2] * inv;
    dst[3] = a + dst[3] * inv;
}

inline fn blendRgba(dst: *[4]f32, r: f32, g_: f32, b: f32, a: f32) void {
    if (a <= 0) return;
    if (a >= 1) {
        dst.* = .{ r, g_, b, 1 };
        return;
    }
    const inv = 1.0 - a;
    dst[0] = r * a + dst[0] * inv;
    dst[1] = g_ * a + dst[1] * inv;
    dst[2] = b * a + dst[2] * inv;
    dst[3] = a + dst[3] * inv;
}

const FixedPoint = struct { x: i64, y: i64 };

fn toFixed(p: g.Point) FixedPoint {
    return .{
        .x = @intFromFloat(@round(p.x * fixed_scale)),
        .y = @intFromFloat(@round(p.y * fixed_scale)),
    };
}

inline fn isTopLeft(dx: i64, dy: i64) bool {
    return dy < 0 or (dy == 0 and dx > 0);
}

inline fn edgeEval128(a: FixedPoint, b: FixedPoint, px: i64, py: i64) i128 {
    const dx: i128 = @as(i128, b.x) - @as(i128, a.x);
    const dy: i128 = @as(i128, b.y) - @as(i128, a.y);
    return dx * (@as(i128, py) - @as(i128, a.y)) - dy * (@as(i128, px) - @as(i128, a.x));
}

inline fn edgePad(dx: i64, dy: i64) i128 {
    // 0.25 subpixels (= 4 fixed units) perpendicular padding seals quadtree
    // T-junction slivers between adaptive Bézier patches on opaque meshes.
    const ax: u64 = @abs(dx);
    const ay: u64 = @abs(dy);
    const len_approx: u64 = @max(ax, ay) + (@min(ax, ay) >> 1);
    return @as(i128, len_approx) * 4;
}

/// Rasterizes one triangle with linearly interpolated RGBA vertex colors.
/// When `opaque_pad` is true (opaque meshes), edges receive 0.25-subpixel
/// conservative padding to seal quadtree T-junctions without visible shift.
pub fn colorTriangle(strip: *const Strip, v0_in: ColorVertex, v1_in: ColorVertex, v2_in: ColorVertex, opaque_pad: bool) void {
    rasterTriangle(strip, v0_in, v1_in, v2_in, opaque_pad, struct {
        inline fn shade(dst: *[4]f32, a: ColorVertex, b: ColorVertex, c: ColorVertex, w0: f64, w1: f64, w2: f64) void {
            const r: f32 = @floatCast(a.c.r * w0 + b.c.r * w1 + c.c.r * w2);
            const gv: f32 = @floatCast(a.c.g * w0 + b.c.g * w1 + c.c.g * w2);
            const bv: f32 = @floatCast(a.c.b * w0 + b.c.b * w1 + c.c.b * w2);
            const av: f32 = @floatCast(a.c.a * w0 + b.c.a * w1 + c.c.a * w2);
            blendRgba(dst, r, gv, bv, av);
        }
    });
}

/// Rasterizes one triangle with a linearly interpolated scalar field evaluated
/// through `stops` at every covered subpixel.
pub fn fieldTriangle(strip: *const Strip, v0_in: FieldVertex, v1_in: FieldVertex, v2_in: FieldVertex, stops: Stops, opaque_pad: bool) void {
    const Shade = struct {
        stops: Stops,
        inline fn shade(self: @This(), dst: *[4]f32, a: FieldVertex, b: FieldVertex, c: FieldVertex, w0: f64, w1: f64, w2: f64) void {
            const value = a.v * w0 + b.v * w1 + c.v * w2;
            blendOver(dst, self.stops.at(value));
        }
    };
    rasterTriangleCtx(strip, v0_in, v1_in, v2_in, opaque_pad, Shade{ .stops = stops });
}

fn rasterTriangle(strip: *const Strip, v0_in: anytype, v1_in: @TypeOf(v0_in), v2_in: @TypeOf(v0_in), opaque_pad: bool, comptime Shader: type) void {
    const Wrap = struct {
        inline fn shade(_: @This(), dst: *[4]f32, a: @TypeOf(v0_in), b: @TypeOf(v0_in), c: @TypeOf(v0_in), w0: f64, w1: f64, w2: f64) void {
            Shader.shade(dst, a, b, c, w0, w1, w2);
        }
    };
    rasterTriangleCtx(strip, v0_in, v1_in, v2_in, opaque_pad, Wrap{});
}

fn rasterTriangleCtx(strip: *const Strip, v0_in: anytype, v1_in: @TypeOf(v0_in), v2_in: @TypeOf(v0_in), opaque_pad: bool, shader: anytype) void {
    const strip_top: f64 = @floatFromInt(strip.sy_start);
    const strip_bot: f64 = @floatFromInt(strip.sy_start + strip.sub_h);
    const strip_right: f64 = @floatFromInt(strip.sub_w);
    const pad_f: f64 = if (opaque_pad) 0.5 else 0.0;

    const min_y_f = @min(@min(v0_in.p.y, v1_in.p.y), v2_in.p.y) - pad_f;
    const max_y_f = @max(@max(v0_in.p.y, v1_in.p.y), v2_in.p.y) + pad_f;
    if (max_y_f < strip_top or min_y_f >= strip_bot) return;

    const min_x_f = @min(@min(v0_in.p.x, v1_in.p.x), v2_in.p.x) - pad_f;
    const max_x_f = @max(@max(v0_in.p.x, v1_in.p.x), v2_in.p.x) + pad_f;
    if (max_x_f < 0 or min_x_f >= strip_right) return;

    const max_abs = @max(
        @max(@abs(v0_in.p.x), @abs(v0_in.p.y)),
        @max(@max(@abs(v1_in.p.x), @abs(v1_in.p.y)), @max(@abs(v2_in.p.x), @abs(v2_in.p.y))),
    );
    if (!std.math.isFinite(max_abs)) return;

    const sx0: u32 = if (min_x_f <= 0) 0 else @min(strip.sub_w, @as(u32, @intFromFloat(@floor(min_x_f))));
    const sx1: u32 = if (max_x_f >= strip_right) strip.sub_w else @min(strip.sub_w, @as(u32, @intFromFloat(@ceil(max_x_f))));
    const sy0: u32 = if (min_y_f <= strip_top) strip.sy_start else @min(strip.sy_start + strip.sub_h, @as(u32, @intFromFloat(@floor(min_y_f))));
    const sy1: u32 = if (max_y_f >= strip_bot) strip.sy_start + strip.sub_h else @min(strip.sy_start + strip.sub_h, @as(u32, @intFromFloat(@ceil(max_y_f))));
    if (sx0 >= sx1 or sy0 >= sy1) return;

    if (max_abs > safe_coord) {
        rasterLargeFloat(strip, v0_in, v1_in, v2_in, sx0, sx1, sy0, sy1, shader);
        return;
    }

    const v0 = v0_in;
    var v1 = v1_in;
    var v2 = v2_in;
    const f0 = toFixed(v0.p);
    var f1 = toFixed(v1.p);
    var f2 = toFixed(v2.p);

    var area128: i128 = edgeEval128(f0, f1, f2.x, f2.y);
    if (area128 == 0) return;
    if (area128 < 0) {
        std.mem.swap(@TypeOf(v1), &v1, &v2);
        std.mem.swap(FixedPoint, &f1, &f2);
        area128 = -area128;
    }

    const inv_area: f64 = 1.0 / @as(f64, @floatFromInt(area128));

    // Edge vectors for f1->f2 (w0), f2->f0 (w1), f0->f1 (w2).
    const dx0 = f2.x - f1.x;
    const dy0 = f2.y - f1.y;
    const dx1 = f0.x - f2.x;
    const dy1 = f0.y - f2.y;
    const dx2 = f1.x - f0.x;
    const dy2 = f1.y - f0.y;

    const bias0: i128 = if (opaque_pad) edgePad(dx0, dy0) else if (isTopLeft(dx0, dy0)) 0 else -1;
    const bias1: i128 = if (opaque_pad) edgePad(dx1, dy1) else if (isTopLeft(dx1, dy1)) 0 else -1;
    const bias2: i128 = if (opaque_pad) edgePad(dx2, dy2) else if (isTopLeft(dx2, dy2)) 0 else -1;

    const step_x0: i128 = -@as(i128, dy0) * fixed_step;
    const step_x1: i128 = -@as(i128, dy1) * fixed_step;
    const step_x2: i128 = -@as(i128, dy2) * fixed_step;

    const step_y0: i128 = @as(i128, dx0) * fixed_step;
    const step_y1: i128 = @as(i128, dx1) * fixed_step;
    const step_y2: i128 = @as(i128, dx2) * fixed_step;

    const px0: i64 = @as(i64, sx0) * fixed_step + fixed_half;
    const py0: i64 = @as(i64, sy0) * fixed_step + fixed_half;

    var row0 = edgeEval128(f1, f2, px0, py0);
    var row1 = edgeEval128(f2, f0, px0, py0);
    var row2 = edgeEval128(f0, f1, px0, py0);

    // Fast i64 stepping when values fit safely inside i64.
    const fits_i64 = max_abs <= 1.0e7;
    if (fits_i64) {
        var r0: i64 = @intCast(row0);
        var r1: i64 = @intCast(row1);
        var r2: i64 = @intCast(row2);
        const sx_0: i64 = @intCast(step_x0);
        const sx_1: i64 = @intCast(step_x1);
        const sx_2: i64 = @intCast(step_x2);
        const sy_0: i64 = @intCast(step_y0);
        const sy_1: i64 = @intCast(step_y1);
        const sy_2: i64 = @intCast(step_y2);
        const b0: i64 = @intCast(bias0);
        const b1: i64 = @intCast(bias1);
        const b2: i64 = @intCast(bias2);

        var sy = sy0;
        while (sy < sy1) : (sy += 1) {
            var e0 = r0;
            var e1 = r1;
            var e2 = r2;
            const row_base = @as(usize, sy - strip.sy_start) * strip.sub_w;
            var sx = sx0;
            while (sx < sx1) : (sx += 1) {
                if (((e0 + b0) | (e1 + b1) | (e2 + b2)) >= 0) {
                    if ((e0 | e1 | e2) >= 0) {
                        const w0 = @as(f64, @floatFromInt(e0)) * inv_area;
                        const w1 = @as(f64, @floatFromInt(e1)) * inv_area;
                        shader.shade(&strip.pixels[row_base + sx], v0, v1, v2, w0, w1, 1.0 - w0 - w1);
                    } else {
                        const c0 = @max(@as(i64, 0), e0);
                        const c1 = @max(@as(i64, 0), e1);
                        const c2 = @max(@as(i64, 0), e2);
                        const inv_w = 1.0 / @as(f64, @floatFromInt(c0 + c1 + c2));
                        shader.shade(&strip.pixels[row_base + sx], v0, v1, v2, @as(f64, @floatFromInt(c0)) * inv_w, @as(f64, @floatFromInt(c1)) * inv_w, @as(f64, @floatFromInt(c2)) * inv_w);
                    }
                }
                e0 += sx_0;
                e1 += sx_1;
                e2 += sx_2;
            }
            r0 += sy_0;
            r1 += sy_1;
            r2 += sy_2;
        }
        return;
    }

    var sy = sy0;
    while (sy < sy1) : (sy += 1) {
        var e0 = row0;
        var e1 = row1;
        var e2 = row2;
        const row_base = @as(usize, sy - strip.sy_start) * strip.sub_w;
        var sx = sx0;
        while (sx < sx1) : (sx += 1) {
            if (e0 + bias0 >= 0 and e1 + bias1 >= 0 and e2 + bias2 >= 0) {
                if (e0 >= 0 and e1 >= 0 and e2 >= 0) {
                    const w0 = @as(f64, @floatFromInt(e0)) * inv_area;
                    const w1 = @as(f64, @floatFromInt(e1)) * inv_area;
                    shader.shade(&strip.pixels[row_base + sx], v0, v1, v2, w0, w1, 1.0 - w0 - w1);
                } else {
                    const c0 = @max(@as(i128, 0), e0);
                    const c1 = @max(@as(i128, 0), e1);
                    const c2 = @max(@as(i128, 0), e2);
                    const inv_w = 1.0 / @as(f64, @floatFromInt(c0 + c1 + c2));
                    shader.shade(&strip.pixels[row_base + sx], v0, v1, v2, @as(f64, @floatFromInt(c0)) * inv_w, @as(f64, @floatFromInt(c1)) * inv_w, @as(f64, @floatFromInt(c2)) * inv_w);
                }
            }
            e0 += step_x0;
            e1 += step_x1;
            e2 += step_x2;
        }
        row0 += step_y0;
        row1 += step_y1;
        row2 += step_y2;
    }
}

/// Fallback for huge off-canvas vertices (> 1e8 subpixels) where fixed-point would overflow.
fn rasterLargeFloat(strip: *const Strip, v0_in: anytype, v1_in: @TypeOf(v0_in), v2_in: @TypeOf(v0_in), sx0: u32, sx1: u32, sy0: u32, sy1: u32, shader: anytype) void {
    const v0 = v0_in;
    var v1 = v1_in;
    var v2 = v2_in;
    var area = (v1.p.x - v0.p.x) * (v2.p.y - v0.p.y) - (v1.p.y - v0.p.y) * (v2.p.x - v0.p.x);
    if (area == 0 or !std.math.isFinite(area)) return;
    if (area < 0) {
        std.mem.swap(@TypeOf(v1), &v1, &v2);
        area = -area;
    }
    const inv_area = 1.0 / area;
    var sy = sy0;
    while (sy < sy1) : (sy += 1) {
        const py = @as(f64, @floatFromInt(sy)) + 0.5;
        const row_base = @as(usize, sy - strip.sy_start) * strip.sub_w;
        var sx = sx0;
        while (sx < sx1) : (sx += 1) {
            const px = @as(f64, @floatFromInt(sx)) + 0.5;
            const e0 = (v2.p.x - v1.p.x) * (py - v1.p.y) - (v2.p.y - v1.p.y) * (px - v1.p.x);
            const e1 = (v0.p.x - v2.p.x) * (py - v2.p.y) - (v0.p.y - v2.p.y) * (px - v2.p.x);
            const e2 = (v1.p.x - v0.p.x) * (py - v0.p.y) - (v1.p.y - v0.p.y) * (px - v0.p.x);
            if (e0 >= 0 and e1 >= 0 and e2 >= 0) {
                const w0 = e0 * inv_area;
                const w1 = e1 * inv_area;
                const w2 = 1.0 - w0 - w1;
                shader.shade(&strip.pixels[row_base + sx], v0, v1, v2, w0, w1, w2);
            }
        }
    }
}
