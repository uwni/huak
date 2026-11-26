//! One elliptical falloff per connected highlight, from OCCT's region moments.
const std = @import("std");
const g = @import("../../geometry.zig");
const Model = @import("../Model.zig");
const Bands = @import("Bands.zig");
const Work = @import("Work.zig");
const regions = @import("regions.zig");
const Bounding = regions.Bounding;
const Sets = regions.Sets;
const FaceLight = Bands.FaceLight;

/// One elliptical falloff for each connected highlight of a curved face
/// before occlusion: an ellipse's second moments give its semiaxes and
/// direction.
pub fn fitSpots(self: *Bands, work: *Work, lit: *const Bounding([2]usize)) Model.Error!void {
    const s = work.scratch;
    var sets: Sets = .{};
    var owners: std.ArrayList(*FaceLight) = .empty;
    for (self.faces, 0..) |list, source| for (list, 0..) |*paint, face| {
        _ = try sets.add(s, lit.of(.{ source, face }) orelse continue);
        try owners.append(s, paint);
    };
    if (owners.items.len == 0) return;
    const found = try work.view.regionsOf(sets.offsets.items, sets.arcs.items, work.tolerance, true);
    for (owners.items, 0..) |paint, set| {
        paint.start = work.out.lobes.items.len;
        for (found.moments[found.sets[set]..found.sets[set + 1]]) |m| {
            if (!(m.area > 0)) return work.model.failWith("invalid highlight area");
            // About an axis in the plane, a region's moment is its area
            // times its variance across the axis; about the normal it is
            // the sum of both. A uniform ellipse's variance along a
            // semiaxis r is r^2 / 4.
            var major: usize = 3;
            var minor: usize = 3;
            for (0..3) |k| {
                if (@abs(m.axes[k][2]) > 0.5) continue;
                if (major == 3) {
                    major = k;
                } else minor = k;
            }
            if (minor == 3) return work.model.failWith("invalid highlight area");
            if (m.moments[minor] < m.moments[major]) std.mem.swap(usize, &major, &minor);
            // The major semiaxis lies along the axis of the smaller moment.
            const a = @sqrt(4 * m.moments[minor] / m.area);
            const b = @sqrt(4 * @max(0, m.moments[major]) / m.area);
            if (b == 0) continue;
            // Either way along an axis: the one toward +x, or +y across.
            const axis: g.Point = .{ .x = m.axes[major][0], .y = m.axes[major][1] };
            const along = if (axis.x < 0 or (axis.x == 0 and axis.y < 0)) axis.scale(-1) else axis;
            try work.out.lobes.append(work.allocator, .{
                .center = .{ .x = m.center[0], .y = m.center[1] },
                .u = along.scale(a),
                .v = (g.Point{ .x = -along.y, .y = along.x }).scale(b),
            });
        }
        paint.count = work.out.lobes.items.len - paint.start;
    }
}
