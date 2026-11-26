//! Where a piece can show: its box, and the region of the paint it is
//! drawn within, traced by lines.
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");

/// Where a piece can show: within `cover`, a box in its paint's own
/// coordinates, and, when it is drawn within another paint, within that
/// paint's region, traced by `lines` in world coordinates.
pub const Where = struct {
    cover: g.BBox,
    within: ?struct { lines: *const Path, transform: g.Transform } = null,

    /// Whether a patch, which lies within its control points, can show
    /// there; `slack` is how closely the lines trace their region.
    pub fn meets(self: Where, net: *const [16]g.Point, slack: f64) bool {
        if (!g.BBox.fromSlice(net).overlaps(self.cover, 0)) return false;
        const inside = self.within orelse return true;
        var world: g.BBox = .fromPoint(inside.transform.apply(net[0]));
        for (net[1..]) |point| world = world.include(inside.transform.apply(point));
        return regionMeets(inside.lines, world.expanded(slack));
    }
};

/// Whether a region traced by closed `lines`, filled by the nonzero rule,
/// meets `box`: a line crosses it, or its center lies inside.
fn regionMeets(lines: *const Path, box: g.BBox) bool {
    const center = box.min.add(box.max).scale(0.5);
    var winding: i32 = 0;
    var start: g.Point = .zero;
    var current: g.Point = .zero;
    for (lines.segments.items) |segment| {
        const end = switch (segment) {
            .move => |point| {
                start = point;
                current = point;
                continue;
            },
            .line => |point| point,
            .close => start,
            .cubic => unreachable,
        };
        if (crosses(current, end, box)) return true;
        const side = end.sub(current).cross(center.sub(current));
        if (current.y <= center.y) {
            if (end.y > center.y and side > 0) winding += 1;
        } else if (end.y <= center.y and side < 0) winding -= 1;
        current = end;
    }
    return winding != 0;
}

/// Whether the segment from `a` to `b` meets `box`, by Liang and Barsky's
/// clipping.
fn crosses(a: g.Point, b: g.Point, box: g.BBox) bool {
    const d = b.sub(a);
    var enter: f64 = 0;
    var leave: f64 = 1;
    for ([_][2]f64{ .{ -d.x, a.x - box.min.x }, .{ d.x, box.max.x - a.x }, .{ -d.y, a.y - box.min.y }, .{ d.y, box.max.y - a.y } }) |bound| {
        const p, const q = bound;
        if (p == 0) {
            if (q < 0) return false;
            continue;
        }
        const r = q / p;
        if (p < 0) {
            if (r > leave) return false;
            enter = @max(enter, r);
        } else {
            if (r < enter) return false;
            leave = @min(leave, r);
        }
    }
    return true;
}
