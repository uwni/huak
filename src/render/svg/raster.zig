//! Pure-Zig 2x2 SSAA bitmap rasterizer exclusively for SVG mesh fills
//! (Gradient.ColorPatches, Gradient.Patches, Gradient.Conic).
//!
//! Rasterization runs in horizontal strips parallelized via `Workers`,
//! produces bit-identical output regardless of worker count, and applies
//! clip-aware gutter dilation so vector <clipPath> boundaries never suffer
//! bilinear dark/transparent fringes.
const std = @import("std");
const Workers = @import("workers");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const style = @import("../../drawing/style.zig");
const Gradient = style.Gradient;
const clip_mask = @import("raster/clip.zig");
const conic_raster = @import("raster/conic.zig");
const scan = @import("raster/scan.zig");
const patch_raster = @import("raster/patches.zig");
const strips = @import("raster/strips.zig");

pub const max_side: u32 = 1 << 14; // 16k
pub const max_pixels: usize = 1 << 26; // 64 MP
const points_per_inch: f64 = 72.0;
const max_chunks: usize = 32;
const target_strip_subpixels: usize = 1 << 20; // 1M subpixels (2x2 SSAA)

pub const Encoding = enum { rgb8, rgba8 };

pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    encoding: Encoding,
    /// Local-coordinate box covered by the image (top row = max.y, bottom = min.y).
    bounds: g.BBox,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Mesh = union(enum) {
    color_patches: Gradient.ColorPatches,
    patches: Gradient.Patches,
    conic: Gradient.Conic,
};

pub const Options = struct {
    dpi: f64 = 300,
    /// Net affine transform from mesh local coordinates to page points.
    placement: g.Transform = .{},
    evenodd: bool = false,
    workers: Workers = .serial,
};

pub const Error = error{
    InvalidStyle,
    InvalidPatches,
    GeometryWorkLimit,
    OutOfMemory,
    Canceled,
};

const flag_in_clip: u8 = 1;
const flag_painted: u8 = 2;

/// Computes pixel dimensions for `box` under `placement` at `dpi`.
/// Returns null if the box or transform is degenerate (zero area on page).
pub fn pixelDimensions(box: g.BBox, placement: g.Transform, dpi: f64) Error!?[2]u32 {
    if (!std.math.isFinite(dpi) or !(dpi > 0)) return error.InvalidStyle;
    const w = box.width();
    const h = box.height();
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or !(w > 0) or !(h > 0)) return null;
    const det = @abs(placement.a * placement.d - placement.b * placement.c);
    if (!std.math.isFinite(det) or det == 0) return null;
    const sx = std.math.hypot(placement.a, placement.b);
    const sy = std.math.hypot(placement.c, placement.d);
    if (!(sx > 0) or !(sy > 0)) return null;

    const px_per_pt = dpi / points_per_inch;
    const wf = @ceil(w * sx * px_per_pt);
    const hf = @ceil(h * sy * px_per_pt);
    if (!std.math.isFinite(wf) or !std.math.isFinite(hf)) return error.GeometryWorkLimit;
    if (wf > @as(f64, @floatFromInt(max_side)) or hf > @as(f64, @floatFromInt(max_side))) return error.GeometryWorkLimit;
    const width_px: u32 = @max(1, @as(u32, @intFromFloat(wf)));
    const height_px: u32 = @max(1, @as(u32, @intFromFloat(hf)));
    if (@as(usize, width_px) * @as(usize, height_px) > max_pixels) return error.GeometryWorkLimit;
    return .{ width_px, height_px };
}

/// Rasterizes one SVG mesh fill clipped by `clip_segments` (with extent `clip_box`).
/// Returns null if nothing visible is painted.
pub fn rasterize(
    allocator: std.mem.Allocator,
    mesh: Mesh,
    clip_segments: []const Path.Segment,
    clip_box: g.BBox,
    options: Options,
) Error!?Image {
    const box = tightBounds(mesh, clip_box) orelse return null;
    const dims = try pixelDimensions(box, options.placement, options.dpi) orelse return null;
    const width_px = dims[0];
    const height_px = dims[1];
    const sub_w = width_px * 2;
    const sub_h = height_px * 2;

    const strip_rows: u32 = @intCast(@max(1, @min(64, @min(height_px, target_strip_subpixels / (@as(usize, width_px) * 4)))));
    const strip_sub_h = strip_rows * 2;
    const strip_count: usize = (height_px + strip_rows - 1) / strip_rows;

    const mask = try clip_mask.Mask.init(allocator, clip_segments, options.evenodd, box, sub_w, sub_h);
    defer mask.deinit(allocator);

    var strip_index: ?strips.StripIndex = null;
    defer if (strip_index) |idx| idx.deinit(allocator);
    var conic_wedges: ?[]conic_raster.Wedge = null;
    defer if (conic_wedges) |w| allocator.free(w);

    switch (mesh) {
        .color_patches => |cp| {
            if (cp.points.len == 0) return null;
            strip_index = try strips.StripIndex.build(allocator, cp.points, box, sub_w, sub_h, strip_sub_h, strip_count);
            if (strip_index.?.indices.len == 0) return null;
        },
        .patches => |p| {
            if (p.points.len == 0) return null;
            strip_index = try strips.StripIndex.build(allocator, p.points, box, sub_w, sub_h, strip_sub_h, strip_count);
            if (strip_index.?.indices.len == 0) return null;
        },
        .conic => |co| {
            if (co.points.len < 2) return null;
            conic_wedges = try conic_raster.prepare(allocator, co);
            if (conic_wedges.?.len == 0) return null;
        },
    }

    const opaque_mesh = isOpaqueMesh(mesh);
    const total_px = @as(usize, width_px) * @as(usize, height_px);
    const rgba = try allocator.alloc(u8, total_px * 4);
    errdefer allocator.free(rgba);
    const flags = try allocator.alloc(u8, total_px);
    defer allocator.free(flags);

    const ChunkResult = struct {
        any_painted: bool = false,
        any_in_clip: bool = false,
        in_clip_transparent: bool = false,
        painted_transparent: bool = false,
        err: ?Error = null,
    };

    const Shared = struct {
        mesh: Mesh,
        box: g.BBox,
        width_px: u32,
        height_px: u32,
        sub_w: u32,
        strip_rows: u32,
        strip_count: usize,
        mask: *const clip_mask.Mask,
        strip_index: ?*const strips.StripIndex,
        conic_wedges: []const conic_raster.Wedge,
        opaque_mesh: bool,
        rgba: []u8,
        flags: []u8,
        results: []ChunkResult,
        worker_allocator: std.mem.Allocator,

        fn runChunk(self: *@This(), chunk_idx: usize) bool {
            const res = &self.results[chunk_idx];
            const range = Workers.chunkRange(self.strip_count, self.results.len, chunk_idx);
            if (range.start >= range.end) return true;

            const alloc = self.worker_allocator;
            const max_sub_h = self.strip_rows * 2;
            const sub_pixels = alloc.alloc([4]f32, @as(usize, self.sub_w) * max_sub_h) catch |e| {
                res.err = e;
                return false;
            };
            defer alloc.free(sub_pixels);
            const clip_bits = alloc.alloc(u8, @as(usize, self.sub_w) * max_sub_h) catch |e| {
                res.err = e;
                return false;
            };
            defer alloc.free(clip_bits);
            var crossings: std.ArrayList(clip_mask.Crossing) = .empty;
            defer crossings.deinit(alloc);

            const scale_x = @as(f64, @floatFromInt(self.sub_w)) / self.box.width();
            const scale_y = @as(f64, @floatFromInt(self.height_px * 2)) / self.box.height();
            const inv_scale_x = 1.0 / scale_x;
            const inv_scale_y = 1.0 / scale_y;

            for (range.start..range.end) |s| {
                const y0: u32 = @intCast(s * self.strip_rows);
                const rows: u32 = @min(self.strip_rows, self.height_px - y0);
                const local_sub_h = rows * 2;
                const count = @as(usize, self.sub_w) * local_sub_h;
                @memset(sub_pixels[0..count], .{ 0, 0, 0, 0 });

                const strip: scan.Strip = .{
                    .pixels = sub_pixels[0..count],
                    .sub_w = self.sub_w,
                    .sy_start = y0 * 2,
                    .sub_h = local_sub_h,
                };
                switch (self.mesh) {
                    .color_patches => |cp| patch_raster.rasterColorStrip(&strip, cp, self.strip_index.?.slice(s), self.box, scale_x, scale_y, self.opaque_mesh),
                    .patches => |p| patch_raster.rasterFieldStrip(&strip, p, self.strip_index.?.slice(s), self.box, scale_x, scale_y, self.opaque_mesh),
                    .conic => |co| conic_raster.rasterStrip(&strip, co, self.conic_wedges, self.box, inv_scale_x, inv_scale_y, self.opaque_mesh),
                }

                self.mask.fillStrip(&crossings, alloc, y0 * 2, local_sub_h, self.sub_w, clip_bits[0..count]) catch |e| {
                    res.err = e;
                    return false;
                };

                downsampleStrip(
                    sub_pixels[0..count],
                    clip_bits[0..count],
                    self.width_px,
                    rows,
                    self.rgba[@as(usize, y0) * self.width_px * 4 ..][0 .. @as(usize, rows) * self.width_px * 4],
                    self.flags[@as(usize, y0) * self.width_px ..][0 .. @as(usize, rows) * self.width_px],
                    res,
                );
            }
            return true;
        }
    };

    const chunk_count = if (total_px >= 4096) options.workers.chunkCount(strip_count, 1, max_chunks) else 1;
    var results: [max_chunks]ChunkResult = @splat(.{});
    var shared: Shared = .{
        .mesh = mesh,
        .box = box,
        .width_px = width_px,
        .height_px = height_px,
        .sub_w = sub_w,
        .strip_rows = strip_rows,
        .strip_count = strip_count,
        .mask = &mask,
        .strip_index = if (strip_index) |*idx| idx else null,
        .conic_wedges = conic_wedges orelse &.{},
        .opaque_mesh = opaque_mesh,
        .rgba = rgba,
        .flags = flags,
        .results = results[0..chunk_count],
        .worker_allocator = if (chunk_count > 1) std.heap.page_allocator else allocator,
    };

    if (chunk_count > 1) {
        try options.workers.run(chunk_count, &shared, Shared.runChunk);
    } else {
        _ = shared.runChunk(0);
    }

    var any_painted = false;
    var any_in_clip = false;
    var in_clip_transparent = false;
    var painted_transparent = false;
    for (results[0..chunk_count]) |res| {
        if (res.err) |e| return e;
        any_painted = any_painted or res.any_painted;
        any_in_clip = any_in_clip or res.any_in_clip;
        in_clip_transparent = in_clip_transparent or res.in_clip_transparent;
        painted_transparent = painted_transparent or res.painted_transparent;
    }
    if (!any_painted) {
        allocator.free(rgba);
        return null;
    }

    try dilateGutter(allocator, rgba, flags, width_px, height_px);

    const has_transparency = if (any_in_clip) in_clip_transparent else painted_transparent;
    if (!has_transparency) {
        // Pack RGBA8 -> RGB8 in place, then shrink the buffer to 3 * total_px.
        for (0..total_px) |i| {
            rgba[i * 3] = rgba[i * 4];
            rgba[i * 3 + 1] = rgba[i * 4 + 1];
            rgba[i * 3 + 2] = rgba[i * 4 + 2];
        }
        const rgb = try allocator.realloc(rgba, total_px * 3);
        return .{ .pixels = rgb, .width = width_px, .height = height_px, .encoding = .rgb8, .bounds = box };
    }
    return .{ .pixels = rgba, .width = width_px, .height = height_px, .encoding = .rgba8, .bounds = box };
}

fn isOpaqueMesh(mesh: Mesh) bool {
    return switch (mesh) {
        .color_patches => |cp| blk: {
            for (cp.colors) |quad| for (quad) |col| if (col.a != 1) break :blk false;
            break :blk true;
        },
        .patches => |p| p.stops.isOpaque(),
        .conic => |co| co.stops.isOpaque(),
    };
}

fn tightBounds(mesh: Mesh, clip_box: g.BBox) ?g.BBox {
    const nets: []const [16]g.Point = switch (mesh) {
        .color_patches => |cp| cp.points,
        .patches => |p| p.points,
        .conic => return clip_box,
    };
    if (nets.len == 0) return null;
    var mesh_box = g.BBox.fromPoint(nets[0][0]);
    for (nets) |*net| for (net) |pt| {
        mesh_box = mesh_box.include(pt);
    };
    const lo_x = @max(clip_box.min.x, mesh_box.min.x);
    const lo_y = @max(clip_box.min.y, mesh_box.min.y);
    const hi_x = @min(clip_box.max.x, mesh_box.max.x);
    const hi_y = @min(clip_box.max.y, mesh_box.max.y);
    if (!(hi_x > lo_x) or !(hi_y > lo_y)) return null;
    return .{ .min = .{ .x = lo_x, .y = lo_y }, .max = .{ .x = hi_x, .y = hi_y } };
}

inline fn quantize(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}

fn downsampleStrip(
    sub_pixels: []const [4]f32,
    clip_bits: []const u8,
    width_px: u32,
    rows: u32,
    out_rgba: []u8,
    out_flags: []u8,
    res: anytype,
) void {
    const sub_w = width_px * 2;
    for (0..rows) |row| {
        const r0 = (row * 2) * sub_w;
        const r1 = (row * 2 + 1) * sub_w;
        const out_row = row * width_px;
        for (0..width_px) |col| {
            const c0 = col * 2;
            const idxs = [4]usize{ r0 + c0, r0 + c0 + 1, r1 + c0, r1 + c0 + 1 };
            var clip_count: u32 = 0;
            for (idxs) |k| clip_count += clip_bits[k];

            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            const denom: f32 = if (clip_count > 0) blk: {
                for (idxs) |k| if (clip_bits[k] != 0) {
                    sum[0] += sub_pixels[k][0];
                    sum[1] += sub_pixels[k][1];
                    sum[2] += sub_pixels[k][2];
                    sum[3] += sub_pixels[k][3];
                };
                break :blk @floatFromInt(clip_count);
            } else blk: {
                for (idxs) |k| {
                    sum[0] += sub_pixels[k][0];
                    sum[1] += sub_pixels[k][1];
                    sum[2] += sub_pixels[k][2];
                    sum[3] += sub_pixels[k][3];
                }
                break :blk 4.0;
            };

            const dst = out_rgba[(out_row + col) * 4 ..][0..4];
            var f: u8 = if (clip_count > 0) flag_in_clip else 0;
            if (clip_count > 0) res.any_in_clip = true;

            if (sum[3] > 0) {
                const a_byte = quantize(sum[3] / denom);
                if (a_byte > 0) {
                    const inv_a = 1.0 / sum[3];
                    dst.* = .{ quantize(sum[0] * inv_a), quantize(sum[1] * inv_a), quantize(sum[2] * inv_a), a_byte };
                    f |= flag_painted;
                    res.any_painted = true;
                    if (a_byte < 255) {
                        res.painted_transparent = true;
                        if (clip_count > 0) res.in_clip_transparent = true;
                    }
                } else {
                    dst.* = .{ 0, 0, 0, 0 };
                    if (clip_count > 0) res.in_clip_transparent = true;
                }
            } else {
                dst.* = .{ 0, 0, 0, 0 };
                if (clip_count > 0) res.in_clip_transparent = true;
            }
            out_flags[out_row + col] = f;
        }
    }
}

/// Bleeds color up to 2 pixels into unpainted pixels outside the clip path
/// (both RGB and alpha, eliminating bilinear zoom halos along <clipPath>) and
/// 1 pixel of RGB-only into unpainted pixels inside the clip path (eliminating
/// dark fringes around internal transparent mesh edges while keeping alpha = 0).
fn dilateGutter(allocator: std.mem.Allocator, rgba: []u8, flags: []u8, width_px: u32, height_px: u32) !void {
    const Update = struct { idx: usize, px: [4]u8, mark_painted: bool };
    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(allocator);

    const w: isize = @intCast(width_px);
    const h: isize = @intCast(height_px);
    const offsets = [8][2]isize{
        .{ -1, 0 },  .{ 1, 0 },  .{ 0, -1 }, .{ 0, 1 },
        .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 },
    };

    for (0..2) |pass| {
        updates.clearRetainingCapacity();
        for (0..height_px) |yu| {
            const y: isize = @intCast(yu);
            const row_base = yu * width_px;
            for (0..width_px) |xu| {
                const idx = row_base + xu;
                const f = flags[idx];
                if (f & flag_painted != 0) continue;
                const in_clip = (f & flag_in_clip) != 0;
                // Only bleed 1 px RGB-only into transparent interior pixels.
                if (in_clip and pass > 0) continue;

                const x: isize = @intCast(xu);
                var sr: u32 = 0;
                var sg: u32 = 0;
                var sb: u32 = 0;
                var sa: u32 = 0;
                var count: u32 = 0;
                for (offsets) |off| {
                    const nx = x + off[0];
                    const ny = y + off[1];
                    if (nx < 0 or nx >= w or ny < 0 or ny >= h) continue;
                    const nidx = @as(usize, @intCast(ny)) * width_px + @as(usize, @intCast(nx));
                    if (flags[nidx] & flag_painted == 0) continue;
                    const np = rgba[nidx * 4 ..][0..4];
                    sr += np[0];
                    sg += np[1];
                    sb += np[2];
                    sa += np[3];
                    count += 1;
                }
                if (count == 0) continue;
                const half = count / 2;
                const px = [4]u8{
                    @intCast((sr + half) / count),
                    @intCast((sg + half) / count),
                    @intCast((sb + half) / count),
                    if (in_clip) 0 else @intCast((sa + half) / count),
                };
                try updates.append(allocator, .{ .idx = idx, .px = px, .mark_painted = !in_clip });
            }
        }
        for (updates.items) |u| {
            rgba[u.idx * 4 ..][0..4].* = u.px;
            if (u.mark_painted) flags[u.idx] |= flag_painted;
        }
        if (updates.items.len == 0) break;
    }
}

test {
    _ = @import("raster/raster_test.zig");
}
