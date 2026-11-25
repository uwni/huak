//! A cylinder seen across its axis: sample angles, the terminator, strips near the contour, and its profile field.
//!
//! A plane's light is constant. A cylinder seen across its axis shades along
//! one direction in the plane: a profile of samples, linear between them,
//! graded toward the contour where the projection folds (see `profile`).
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Node = @import("Node.zig");
const Shading = space_shading.Shading;
const Output = space_shading.Output;
const Face = space_shading.Face;
const Info = space_shading.Info;
const Error = space_shading.Error;
const Field = space_shading.Field;
const dot = space_shading.dot;
const max_steps = space_shading.max_steps;
const angular_precision = space_shading.angular_precision;
const Shine = space_shading.Shine;

/// A cylinder seen across its axis shades along one direction in the
/// plane: each ruling projects to a line with constant light. Null where
/// the axis points at the viewer or a sample has no normal.
pub fn profile(self: *Shading, scratch: std.mem.Allocator, out: *Output, face: Face, info: Info) Error!?Field {
    const e1 = info.axis_x;
    const e2 = info.axis_y;
    if (std.math.hypot(dot(self.eye, e1), dot(self.eye, e2)) < 1e-6) return null;
    const v = (info.v[0] + info.v[1]) / 2;
    // The parameter u is the angle around the axis from e1.
    const toward = std.math.atan2(dot(self.eye, e2), dot(self.eye, e1));
    var ends: [2]Node = undefined;
    try self.evaluate(scratch, face, &.{ .{ .x = toward, .y = v }, .{ .x = toward, .y = v + 1 } }, &ends);
    const probe = ends[0];
    const above = ends[1];
    if (probe.singular or above.singular) return null;
    const center = if (probe.facing > 0) toward else toward + std.math.pi;
    const ax = above.x - probe.x;
    const ay = above.y - probe.y;
    const along = std.math.hypot(ax, ay);
    if (along < 1e-9) return null;
    const wx = -ay / along;
    const wy = ax / along;

    var angles: std.ArrayList(f64) = .empty;
    const first = center - std.math.pi / 2.0;
    const last = center + std.math.pi / 2.0;
    for (self.facing) |level| try angles.appendSlice(scratch, &.{ first + std.math.asin(level), last - std.math.asin(level) });
    const fine = if (self.half != null) @min(self.step, @sqrt(8 * self.accuracy * (1 - self.cutoff))) else self.step;
    const deepest = std.math.asin(self.facing[self.facing.len - 1]);
    const from = first + deepest;
    const to = last - deepest;
    const count = @max(1, @ceil((to - from) / fine));
    if (!(count <= max_steps)) return error.ShadingLimit;
    const steps: usize = @intFromFloat(count);
    for (0..steps + 1) |k| try angles.append(scratch, from + (to - from) * @as(f64, @floatFromInt(k)) / count);
    // The terminator, where n·l = 0, is a sample so the dark side stays flat.
    const sx = dot(self.sun, e1);
    const sy = dot(self.sun, e2);
    if (std.math.hypot(sx, sy) > angular_precision) for ([2]f64{ std.math.pi / 2.0, -std.math.pi / 2.0 }) |turn| {
        var terminator = std.math.atan2(sy, sx) + turn;
        terminator += 2 * std.math.pi * @round((center - terminator) / (2 * std.math.pi));
        if (terminator > first and terminator < last) try angles.append(scratch, terminator);
    };
    std.mem.sort(f64, angles.items, {}, std.sort.asc(f64));

    const uv = try scratch.alloc(g.Point, angles.items.len);
    for (uv, angles.items) |*at, a| at.* = .{ .x = a, .y = v };
    const nodes = try scratch.alloc(Node, uv.len);
    try self.evaluate(scratch, face, uv, nodes);
    const Ruling = struct { t: f64, shine: Shine };
    const rulings = try scratch.alloc(Ruling, nodes.len);
    for (nodes, rulings) |n, *ruling| {
        if (n.singular) return null;
        ruling.* = .{ .t = wx * n.x + wy * n.y, .shine = n.shine };
    }
    std.mem.sort(Ruling, rulings, {}, struct {
        fn less(_: void, a: Ruling, b: Ruling) bool {
            return a.t < b.t;
        }
    }.less);
    const low = rulings[0].t;
    const high = rulings[rulings.len - 1].t;
    if (!(high - low > 1e-9)) return null;
    const origin = wx * probe.x + wy * probe.y;
    const start = out.samples.items.len;
    for (rulings, 0..) |ruling, k| {
        const position = if (k + 1 == rulings.len) 1.0 else (ruling.t - low) / (high - low);
        if (k != 0) {
            const previous = out.samples.items[out.samples.items.len - 1];
            if (position == previous.position and ruling.shine.diffuse == previous.shine.diffuse) continue;
        }
        try out.samples.append(self.allocator, .{ .position = position, .shine = ruling.shine });
    }
    return .{ .profile = .{
        .start = .{ .x = probe.x + wx * (low - origin), .y = probe.y + wy * (low - origin) },
        .end = .{ .x = probe.x + wx * (high - origin), .y = probe.y + wy * (high - origin) },
        .samples = .{ .start = start, .count = out.samples.items.len - start },
    } };
}
