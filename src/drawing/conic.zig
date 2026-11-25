//! Lowers conic paints (see `style.Gradient.Conic`) to what outputs draw:
//! patches for a PDF patch mesh, and triangles for outputs that interpolate
//! only linearly on triangles. Both stay within the paint's tolerance of its
//! field.
//!
//! A wedge is cut along its chord into equal parts, and each part is drawn
//! out to a far chord, which joins points on the part's two rays at one
//! distance from the center: the same for the whole paint, and enough for
//! every far chord to lie past the area to cover. A ray that crosses the
//! wedge's chord at parameter s crosses the far chord at w, and with the
//! ends of the part at distances in the ratio q from the center,
//! s = w / (w + q (1 - w)). So |w - s| is at most the part's skew,
//! (sqrt q - 1) / (sqrt q + 1).
//!
//! - A patch has two corners at the center and two on the far chord, and is
//!   bilinear: constant along each ray, as the field is, and linear along
//!   the far chord. It differs from the field by at most the change across
//!   the part times the skew.
//! - A triangle's corner at the center takes the mean of its rays' values.
//!   From there to the far chord its difference from the field goes
//!   linearly from at most half the change across the part to the patch's,
//!   so with a skew of at most a half it is within half the change.
//!
//! Parts turn at most a quarter turn, which keeps the far points within
//! sqrt 2 of the distance they must cover.
const std = @import("std");
const g = @import("geometry.zig");
const Conic = @import("style.zig").Gradient.Conic;
const Triangulated = @import("patches.zig").Triangulated;

pub const Error = error{ InvalidStyle, InvalidColor, NonFinite, GeometryWorkLimit, OutOfMemory };

/// Far chords lie this much past the farthest corner to cover.
pub const margin = 1.0625;
const quarter_turn = std.math.pi / 2.0;

/// Bilinear patches with arrays owned by the allocator given to `patches`:
/// their points, and the field of each paint lowered on them in turn.
pub const Patched = struct {
    points: [][16]g.Point,
    values: [][16]f64,

    pub fn deinit(self: Patched, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.values);
    }

    /// The field of the paint at `index` among those lowered.
    pub fn field(self: Patched, index: usize) [][16]f64 {
        return self.values[index * self.points.len ..][0..self.points.len];
    }
};

/// Patches within the paint's tolerance of its field, wedge by wedge in
/// order; steps make none. Over (u, v) in the unit square a patch runs from
/// its earlier ray to its later one in u and from the center to the far
/// chord in v, and its field is linear in u. Neighbours share the edge along
/// their common ray. More than `max_patches` report GeometryWorkLimit.
pub fn patches(allocator: std.mem.Allocator, conic: Conic, cover: g.BBox, max_patches: usize) Error!Patched {
    return sharedPatches(allocator, &.{conic}, cover, max_patches);
}

/// Patches for paints on the same rays, the same center and points, each
/// within its tolerance of its field as `patches` makes them: a wedge takes
/// as many parts as the paint that needs the most.
pub fn sharedPatches(allocator: std.mem.Allocator, conics: []const Conic, cover: g.BBox, max_patches: usize) Error!Patched {
    const first = conics[0];
    for (conics) |conic| {
        try conic.validate();
        if (!std.mem.eql(u8, std.mem.asBytes(&conic.center), std.mem.asBytes(&first.center)) or
            !std.mem.eql(u8, std.mem.sliceAsBytes(conic.points), std.mem.sliceAsBytes(first.points))) return error.InvalidStyle;
    }
    const distance = try reach(first, cover);
    var points: std.ArrayList([16]g.Point) = .empty;
    defer points.deinit(allocator);
    // Each paint's field, patch after patch.
    var values: std.ArrayList([16]f64) = .empty;
    defer values.deinit(allocator);
    for (0..first.points.len - 1) |k| {
        if (step(first, k)) continue;
        var parts: usize = 1;
        for (conics) |conic| parts = @max(parts, try partsOf(conic, k, .patches, max_patches - points.items.len));
        for (0..parts) |part| {
            const from = farPoint(first, spoke(first, k, part, parts), distance);
            const to = farPoint(first, spoke(first, k, part + 1, parts), distance);
            var patch: [16]g.Point = undefined;
            for (0..4) |i| for (0..4) |j| {
                const s = @as(f64, @floatFromInt(i)) / 3;
                const t = @as(f64, @floatFromInt(j)) / 3;
                patch[i * 4 + j] = first.center.add(from.lerp(to, s).sub(first.center).scale(t));
            };
            try points.append(allocator, patch);
            for (conics) |conic| {
                const low = valueAt(conic, k, part, parts);
                const high = valueAt(conic, k, part + 1, parts);
                var field: [16]f64 = undefined;
                // A ray's controls and values come out the same in both of
                // the patches beside it.
                for (0..4) |i| for (0..4) |j| {
                    field[i * 4 + j] = if (i == 3) high else low + (high - low) * @as(f64, @floatFromInt(i)) / 3;
                };
                try values.append(allocator, field);
            }
        }
    }
    // Patch by patch, each paint in turn, to each paint's field in turn.
    const count = points.items.len;
    const fields = try allocator.alloc([16]f64, values.items.len);
    errdefer allocator.free(fields);
    for (values.items, 0..) |field, index| fields[(index % conics.len) * count + index / conics.len] = field;
    return .{ .points = try points.toOwnedSlice(allocator), .values = fields };
}

/// Triangles from the center whose linear interpolation stays within the
/// paint's tolerance of its field, wedge by wedge in order. Points on the
/// far chords are shared by the triangles beside them; each triangle has
/// its own corner at the center. More than `max_triangles` report
/// GeometryWorkLimit.
pub fn triangulate(allocator: std.mem.Allocator, conic: Conic, cover: g.BBox, max_triangles: usize) Error!Triangulated {
    try conic.validate();
    const distance = try reach(conic, cover);
    var points: std.ArrayList(g.Point) = .empty;
    errdefer points.deinit(allocator);
    var values: std.ArrayList(f64) = .empty;
    errdefer values.deinit(allocator);
    var triangles: std.ArrayList([3]u32) = .empty;
    errdefer triangles.deinit(allocator);
    var previous = try vertex(allocator, &points, &values, farPoint(conic, spoke(conic, 0, 0, 1), distance), conic.values[0]);
    for (0..conic.points.len - 1) |k| {
        if (step(conic, k)) {
            previous = try vertex(allocator, &points, &values, points.items[previous], conic.values[k + 1]);
            continue;
        }
        const parts = try partsOf(conic, k, .triangles, max_triangles - triangles.items.len);
        for (1..parts + 1) |part| {
            const next = try vertex(allocator, &points, &values, farPoint(conic, spoke(conic, k, part, parts), distance), valueAt(conic, k, part, parts));
            const center = try vertex(allocator, &points, &values, conic.center, (values.items[previous] + values.items[next]) / 2);
            try triangles.append(allocator, .{ center, previous, next });
            previous = next;
        }
    }
    const owned_points = try points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_points);
    const owned_values = try values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_values);
    return .{ .points = owned_points, .values = owned_values, .triangles = try triangles.toOwnedSlice(allocator) };
}

/// The field at `p` from the last wedge holding it, or null outside every
/// wedge and at the center.
pub fn evaluate(conic: Conic, p: g.Point) ?f64 {
    const ray = p.sub(conic.center);
    var k = conic.points.len - 1;
    while (k > 0) {
        k -= 1;
        if (step(conic, k)) continue;
        const from = conic.points[k].sub(conic.center);
        const to = conic.points[k + 1].sub(conic.center);
        const turn = from.cross(to);
        const before = from.cross(ray) * std.math.sign(turn);
        const after = ray.cross(to) * std.math.sign(turn);
        if (before < 0 or after < 0 or before + after == 0) continue;
        const s = before / (before + after);
        return conic.values[k] + (conic.values[k + 1] - conic.values[k]) * s;
    }
    return null;
}

/// Whether points k and k + 1 lie on one ray.
fn step(conic: Conic, k: usize) bool {
    return conic.points[k].sub(conic.center).cross(conic.points[k + 1].sub(conic.center)) == 0;
}

/// From the center to the point `part` of `parts` along wedge k's chord.
fn spoke(conic: Conic, k: usize, part: usize, parts: usize) g.Point {
    const from = conic.points[k].sub(conic.center);
    if (part == 0) return from;
    const to = conic.points[k + 1].sub(conic.center);
    if (part == parts) return to;
    return from.lerp(to, @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(parts)));
}

/// The field on the ray through that point.
fn valueAt(conic: Conic, k: usize, part: usize, parts: usize) f64 {
    if (part == 0) return conic.values[k];
    if (part == parts) return conic.values[k + 1];
    return conic.values[k] + (conic.values[k + 1] - conic.values[k]) * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(parts));
}

const Shape = enum { patches, triangles };

/// How many equal parts wedge k's chord takes for each part to turn at most
/// a quarter turn and to stay, drawn as `shape`, within the tolerance of the
/// field. More than `limit` report GeometryWorkLimit.
fn partsOf(conic: Conic, k: usize, shape: Shape, limit: usize) Error!usize {
    const change = @abs(conic.values[k + 1] - conic.values[k]);
    const least: f64 = switch (shape) {
        .patches => 1,
        .triangles => @max(1, @ceil(change / (2 * conic.tolerance))),
    };
    if (!(least <= @as(f64, @floatFromInt(limit)))) return error.GeometryWorkLimit;
    var parts: usize = @intFromFloat(least);
    while (parts <= limit) : (parts *= 2) {
        var turn: f64 = 0;
        var skew: f64 = 0;
        var from = spoke(conic, k, 0, parts);
        for (1..parts + 1) |part| {
            const to = spoke(conic, k, part, parts);
            turn = @max(turn, @abs(std.math.atan2(from.cross(to), from.dot(to))));
            const root = @sqrt(@max(from.norm(), to.norm()) / @min(from.norm(), to.norm()));
            skew = @max(skew, (root - 1) / (root + 1));
            from = to;
        }
        const within = switch (shape) {
            .patches => change / @as(f64, @floatFromInt(parts)) * skew <= conic.tolerance,
            .triangles => skew <= 0.5,
        };
        if (within and turn <= quarter_turn) return parts;
    }
    return error.GeometryWorkLimit;
}

/// The distance from the center of every far point. Far chords of parts
/// that turn at most a quarter turn then lie past `cover`.
fn reach(conic: Conic, cover: g.BBox) Error!f64 {
    var far: f64 = 0;
    for ([_]g.Point{ cover.min, cover.max, .{ .x = cover.min.x, .y = cover.max.y }, .{ .x = cover.max.x, .y = cover.min.y } }) |corner| {
        far = @max(far, corner.sub(conic.center).norm());
    }
    // With nothing to cover any distance does.
    if (far == 0) far = conic.points[0].sub(conic.center).norm();
    const distance = margin * std.math.sqrt2 * far;
    if (!std.math.isFinite(distance)) return error.NonFinite;
    return distance;
}

/// The point `distance` from the center along `ray`.
fn farPoint(conic: Conic, ray: g.Point, distance: f64) g.Point {
    return conic.center.add(ray.scale(distance / ray.norm()));
}

fn vertex(allocator: std.mem.Allocator, points: *std.ArrayList(g.Point), values: *std.ArrayList(f64), point: g.Point, value: f64) !u32 {
    if (points.items.len == std.math.maxInt(u32)) return error.GeometryWorkLimit;
    try points.append(allocator, point);
    try values.append(allocator, value);
    return @intCast(points.items.len - 1);
}

test {
    _ = @import("conic/lowering_test.zig");
}
