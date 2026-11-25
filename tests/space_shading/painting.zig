//! What a field paints at a point, the way a PDF patch mesh and the other outputs draw it.
const std = @import("std");
const huak = @import("huak");
const shading = huak.core.shading;
const g = huak.core.geometry;
const patch_mesh = huak.core.patches;
const fan_mesh = huak.core.conic;
const Conic = huak.core.DisplayList.Gradient.Conic;

/// A fan as outputs draw it, each light within its tolerance: the patches of
/// a PDF patch mesh, and the triangles of other outputs.
pub const Fan = struct {
    rays: usize,
    /// For n·l, then the glint, each in its own field of the patches.
    patches: [2][]shading.Patch,
    triangles: [2]patch_mesh.Triangulated,
    /// The highest glint where the highlight stops on a terminator: on one
    /// of two rays at one point.
    cut: f64,

    pub fn init(a: std.mem.Allocator, out: *const shading.Output, fan: @FieldType(shading.Field, "fan"), cover: g.BBox) !Fan {
        const rays = out.rays.items[fan.rays.start..][0..fan.rays.count];
        var result: Fan = .{ .rays = rays.len, .patches = undefined, .triangles = undefined, .cut = 0 };
        const points = try a.alloc(g.Point, rays.len);
        for (rays, points) |ray, *point| point.* = ray.point;
        for (rays[0 .. rays.len - 1], rays[1..]) |ray, next| {
            if (ray.point.eql(next.point)) result.cut = @max(result.cut, ray.shine.glint, next.shine.glint);
        }
        for (0..2) |light| {
            const values = try a.alloc(f64, rays.len);
            for (rays, values) |ray, *value| value.* = if (light == 0) ray.shine.diffuse else ray.shine.glint;
            // The field needs no colors; the paint does.
            const conic: Conic = .{ .center = fan.center, .points = points, .values = values, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .black } }, .tolerance = fan.tolerance };
            const lowered = try fan_mesh.patches(a, conic, cover, 1 << 20);
            const patches = try a.alloc(shading.Patch, lowered.points.len);
            for (patches, lowered.points, lowered.values) |*patch, controls, field| {
                patch.* = .{ .points = controls, .diffuse = field, .glint = field, .values = @splat(0) };
            }
            result.patches[light] = patches;
            result.triangles[light] = try fan_mesh.triangulate(a, conic, cover, 1 << 20);
        }
        return result;
    }
};

/// Linear interpolation on the last triangle holding `p`.
fn onTriangles(mesh: patch_mesh.Triangulated, p: g.Point) ?f64 {
    var k = mesh.triangles.len;
    while (k > 0) {
        k -= 1;
        const corners = mesh.triangles[k];
        const a = mesh.points[corners[0]];
        const b = mesh.points[corners[1]];
        const d = mesh.points[corners[2]];
        const area = b.sub(a).cross(d.sub(a));
        if (area == 0) continue;
        const wa = b.sub(p).cross(d.sub(p)) / area;
        const wb = d.sub(p).cross(a.sub(p)) / area;
        const wd = 1 - wa - wb;
        if (wa < -1e-12 or wb < -1e-12 or wd < -1e-12) continue;
        return wa * mesh.values[corners[0]] + wb * mesh.values[corners[1]] + wd * mesh.values[corners[2]];
    }
    return null;
}

/// The light a field paints at `p`: [0] as a PDF patch mesh paints it,
/// bilinear in the corner values of a fan's patches or the field's own, or
/// as given; [1] as other outputs draw it, a fan's triangles and a patch's
/// cubic field. Null where the field does not cover `p`.
pub fn paint(field: shading.Field, out: *const shading.Output, fan: ?Fan, p: g.Point) ?[2]shading.Shine {
    switch (field) {
        .none => return null,
        .constant => |shine| return .{ shine, shine },
        .fan => {
            const drawn = fan.?;
            const diffuse = topmost(drawn.patches[0], .diffuse, p) orelse return null;
            const glint = topmost(drawn.patches[1], .glint, p) orelse return null;
            return .{
                .{ .diffuse = diffuse[0], .glint = glint[0] },
                .{ .diffuse = onTriangles(drawn.triangles[0], p) orelse return null, .glint = onTriangles(drawn.triangles[1], p) orelse return null },
            };
        },
        .profile => |profile| {
            const axis = profile.end.sub(profile.start);
            const t = std.math.clamp(p.sub(profile.start).dot(axis) / axis.dot(axis), 0, 1);
            const list = out.samples.items[profile.samples.start..][0..profile.samples.count];
            for (list[1..], list[0 .. list.len - 1]) |next, previous| {
                if (t > next.position) continue;
                const w = if (next.position > previous.position) (t - previous.position) / (next.position - previous.position) else 1;
                const shine: shading.Shine = .{ .diffuse = previous.shine.diffuse + (next.shine.diffuse - previous.shine.diffuse) * w, .glint = previous.shine.glint + (next.shine.glint - previous.shine.glint) * w };
                return .{ shine, shine };
            }
            return null;
        },
        .patches => |range| {
            const patches = out.patches.items[range.start..][0..range.count];
            const d = topmost(patches, .diffuse, p) orelse return null;
            const h = topmost(patches, .glint, p).?;
            return .{ .{ .diffuse = d[0], .glint = h[0] }, .{ .diffuse = d[1], .glint = h[1] } };
        },
    }
}

/// A light of the last patch drawn over `p`: bilinear between its corner
/// values, as a PDF patch mesh paints it, and its cubic field.
fn topmost(patches: []const shading.Patch, comptime light: enum { diffuse, glint }, p: g.Point) ?[2]f64 {
    var k = patches.len;
    while (k > 0) {
        k -= 1;
        const patch = &patches[k];
        const s, const t = locate(&patch.points, p) orelse continue;
        const v = &@field(patch, @tagName(light));
        const cubic = patch_mesh.evaluate(&patch.points, v, s, t).value;
        return .{ v[0] * (1 - s) * (1 - t) + v[12] * s * (1 - t) + v[15] * s * t + v[3] * (1 - s) * t, cubic };
    }
    return null;
}

/// Where in a patch's own parameters `p` lies, by Newton's method on the
/// patch's points from a few starting points; null when no solution lies in
/// the unit square. The patch is Huak's output, not an OCCT surface.
fn locate(points: *const [16]g.Point, p: g.Point) ?[2]f64 {
    var box_: g.BBox = .fromPoint(points[0]);
    for (points) |q| box_ = box_.include(q);
    if (!box_.expanded(1e-9).contains(p)) return null;
    const step = 1e-6;
    const flat: [16]f64 = @splat(0);
    for ([_][2]f64{ .{ 0.5, 0.5 }, .{ 0.15, 0.15 }, .{ 0.85, 0.15 }, .{ 0.15, 0.85 }, .{ 0.85, 0.85 } }) |start| {
        var s, var t = start;
        for (0..40) |_| {
            const at = patch_mesh.evaluate(points, &flat, s, t).point;
            const r = at.sub(p);
            if (r.norm() < 1e-10) return if (s > -1e-7 and s < 1 + 1e-7 and t > -1e-7 and t < 1 + 1e-7) .{ s, t } else null;
            const du = patch_mesh.evaluate(points, &flat, s + step, t).point.sub(patch_mesh.evaluate(points, &flat, s - step, t).point).scale(0.5 / step);
            const dv = patch_mesh.evaluate(points, &flat, s, t + step).point.sub(patch_mesh.evaluate(points, &flat, s, t - step).point).scale(0.5 / step);
            const det = du.cross(dv);
            if (!(@abs(det) > 1e-300)) break;
            s = std.math.clamp(s - r.cross(dv) / det, -0.5, 1.5);
            t = std.math.clamp(t - du.cross(r) / det, -0.5, 1.5);
        }
    }
    return null;
}
