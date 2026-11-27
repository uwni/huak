//! Analytical conic gradient wedge preparation and strip evaluation onto a
//! 2x2 SSAA premultiplied RGBA strip buffer.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");
const Gradient = @import("../../../drawing/style.zig").Gradient;
const scan = @import("scan.zig");

/// Precomputed non-step wedge of a conic gradient for analytical evaluation.
pub const Wedge = struct {
    from: g.Point,
    to: g.Point,
    sign: f64,
    v0: f64,
    dv: f64,
    /// True when the next wedge does not immediately continue from `to`,
    /// so rays landing exactly on `to` belong to this wedge.
    include_end: bool,
};

pub fn prepare(allocator: std.mem.Allocator, conic: Gradient.Conic) ![]Wedge {
    var list: std.ArrayList(Wedge) = .empty;
    errdefer list.deinit(allocator);
    for (0..conic.points.len - 1) |k| {
        const from = conic.points[k].sub(conic.center);
        const to = conic.points[k + 1].sub(conic.center);
        const turn = from.cross(to);
        if (turn == 0) continue;
        try list.append(allocator, .{
            .from = from,
            .to = to,
            .sign = std.math.sign(turn),
            .v0 = conic.values[k],
            .dv = conic.values[k + 1] - conic.values[k],
            .include_end = true,
        });
    }
    // Avoid double-compositing translucent rays landing on a shared spoke.
    if (list.items.len > 1) {
        for (0..list.items.len - 1) |i| {
            const cur = &list.items[i];
            const next = list.items[i + 1];
            if (cur.to.cross(next.from) == 0 and cur.to.dot(next.from) > 0) {
                cur.include_end = false;
            }
        }
        const last = &list.items[list.items.len - 1];
        const first = list.items[0];
        if (last.to.cross(first.from) == 0 and last.to.dot(first.from) > 0) {
            last.include_end = false;
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Analytically evaluates `conic` at every subpixel of `strip`.
pub fn rasterStrip(
    strip: *const scan.Strip,
    conic: Gradient.Conic,
    wedges: []const Wedge,
    box: g.BBox,
    inv_scale_x: f64,
    inv_scale_y: f64,
    opaque_stops: bool,
) void {
    if (wedges.len == 0) return;
    for (0..strip.sub_h) |r| {
        const py = box.max.y - (@as(f64, @floatFromInt(strip.sy_start + @as(u32, @intCast(r)))) + 0.5) * inv_scale_y;
        const dy = py - conic.center.y;
        const row = strip.pixels[r * strip.sub_w ..][0..strip.sub_w];
        for (0..strip.sub_w) |sx| {
            const px = box.min.x + (@as(f64, @floatFromInt(sx)) + 0.5) * inv_scale_x;
            const ray: g.Point = .{ .x = px - conic.center.x, .y = dy };
            if (opaque_stops) {
                var idx = wedges.len;
                while (idx > 0) {
                    idx -= 1;
                    const w = wedges[idx];
                    const before = w.from.cross(ray) * w.sign;
                    const after = ray.cross(w.to) * w.sign;
                    if (before < 0 or after < 0 or before + after == 0) continue;
                    const s = before / (before + after);
                    scan.blendOver(&row[sx], conic.stops.at(w.v0 + w.dv * s));
                    break;
                }
            } else {
                for (wedges) |w| {
                    const before = w.from.cross(ray) * w.sign;
                    const after = ray.cross(w.to) * w.sign;
                    if (before < 0 or after < 0 or before + after == 0) continue;
                    if (after == 0 and !w.include_end) continue;
                    const s = before / (before + after);
                    scan.blendOver(&row[sx], conic.stops.at(w.v0 + w.dv * s));
                }
            }
        }
    }
}
