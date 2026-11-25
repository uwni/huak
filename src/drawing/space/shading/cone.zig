//! A cone: its rulings, highlight marks and rays, and its fan field.
//!
//! A cone's rulings meet at its apex and each carries constant light, so
//! around the apex's projection the light is a function of the ray: a fan
//! of rulings, linear between neighbours along the chord joining their far
//! ends. Rulings halve until a bound on the fan's error (see `Spokes`) is
//! within `fan_share` of e, which leaves the rest to the outputs that
//! draw the fan (see `fan`).
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const cone_rulings = @import("rulings.zig");
const Node = @import("Node.zig");
const Shading = space_shading.Shading;
const Output = space_shading.Output;
const Face = space_shading.Face;
const Info = space_shading.Info;
const Error = space_shading.Error;
const Field = space_shading.Field;
const rounding = cone_rulings.rounding;
const Wave = cone_rulings.Wave;
const Spokes = cone_rulings.Spokes;
const frontRulings = cone_rulings.frontRulings;
const angular_precision = space_shading.angular_precision;
const Ray = space_shading.Ray;

/// The share of the accuracy a fan's rulings may use; outputs get the rest.
/// Drawn as triangles a fan takes one for each change of the light by twice
/// that rest, while a ruling costs one patch, far less than a triangle, so
/// the rulings take little.
const fan_share = 1.0 / 8.0;

/// A ruling whose ray is shorter than this share of the fan's longest is
/// seen end on: its ray has no direction to trust.
const shortest_ray = 1e-9;

/// A cone shades as a fan around its apex's projection: each ruling
/// projects to a ray from it with constant light. Null where the face
/// spans its apex or holds several arcs of rulings facing the viewer,
/// where none faces the viewer, where the view runs along a ruling, or
/// where a sample has no normal.
pub fn fan(self: *Shading, scratch: std.mem.Allocator, out: *Output, face: Face, info: Info) Error!?Field {
    // The apex of a pointed cone bounds its face only up to rounding.
    const slack = rounding * (info.v[1] - info.v[0]);
    if (info.apex_v > info.v[0] + slack and info.apex_v < info.v[1] - slack) return null;
    const far = if (@abs(info.v[0] - info.apex_v) > @abs(info.v[1] - info.apex_v)) info.v[0] else info.v[1];
    if (!(@abs(far - info.apex_v) > slack)) return null;
    // The apex, and the far ends of three rulings: along the rulings u
    // each coordinate and each light is a cos u + b sin u + c.
    const quarter = std.math.pi / 2.0;
    var probes: [4]Node = undefined;
    try self.evaluate(scratch, face, &.{ .{ .x = 0, .y = info.apex_v }, .{ .x = 0, .y = far }, .{ .x = quarter, .y = far }, .{ .x = 2 * quarter, .y = far } }, &probes);
    const ends = probes[1..];
    for (ends) |end| if (end.singular) return null;
    const apex: g.Point = .{ .x = probes[0].x, .y = probes[0].y };
    const x: Wave = .through(ends[0].x, ends[1].x, ends[2].x);
    const y: Wave = .through(ends[0].y, ends[1].y, ends[2].y);
    const spokes: Spokes = .init(.{ .x = x.a, .y = y.a }, .{ .x = x.b, .y = y.b }, .{ .x = x.c - apex.x, .y = y.c - apex.y });
    const light: Wave = .through(ends[0].shine.diffuse, ends[1].shine.diffuse, ends[2].shine.diffuse);
    const range = frontRulings(.through(ends[0].facing, ends[1].facing, ends[2].facing), info) orelse return null;
    const target = self.accuracy * fan_share;

    var rulings: std.ArrayList(f64) = .empty;
    try rulings.append(scratch, range[0]);
    if (!try spokes.divide(scratch, &rulings, light, range, target, self.budget)) return null;

    // The highlight shows on lit rulings whose glint is positive. Its
    // fan spans them: it fades to zero where the glint does, and stops at
    // the glint it has on a terminator.
    const Mark = struct { u: f64, shown: bool };
    var marks: std.ArrayList(Mark) = .empty;
    if (self.half != null) {
        const glint_: Wave = .through(ends[0].raw, ends[1].raw, ends[2].raw);
        if (glint_.positive()) |bright| if (bright.hull(range)) |reach| {
            // Arcs between the rulings where either light changes sign.
            const Cut = struct { u: f64, fades: bool };
            var cuts: std.ArrayList(Cut) = .empty;
            try cuts.append(scratch, .{ .u = reach[0], .fades = reach[0] > range[0] });
            for ([_]Wave{ light, glint_ }, [_]bool{ false, true }) |wave, fades| {
                const arc = wave.positive() orelse continue;
                if (arc.half >= std.math.pi) continue;
                var turn: f64 = -2;
                while (turn <= 2) : (turn += 1) for ([_]f64{ -arc.half, arc.half }) |side| {
                    const u = arc.middle + side + 2 * std.math.pi * turn;
                    if (u > reach[0] and u < reach[1]) try cuts.append(scratch, .{ .u = u, .fades = fades });
                };
            }
            try cuts.append(scratch, .{ .u = reach[1], .fades = reach[1] < range[1] });
            std.mem.sort(Cut, cuts.items, {}, struct {
                fn less(_: void, a: Cut, b: Cut) bool {
                    return a.u < b.u;
                }
            }.less);
            var between: std.ArrayList(f64) = .empty;
            var inside: std.ArrayList(f64) = .empty;
            for (cuts.items[0 .. cuts.items.len - 1], cuts.items[1..]) |from, to| {
                if (!(to.u - from.u > angular_precision)) continue;
                const middle = (from.u + to.u) / 2;
                const shows = light.at(middle) > 0 and glint_.at(middle) > 0;
                // The glint is zero where it fades out, and not shown
                // on the far side of a terminator.
                try marks.append(scratch, .{ .u = from.u, .shown = shows and !from.fades });
                between.clearRetainingCapacity();
                if (shows) {
                    if (!try spokes.divide(scratch, &between, glint_, .{ from.u, to.u }, target, self.budget)) return null;
                    between.items.len -= 1;
                }
                // n·l's rulings within the arc join the glint's, so that
                // across the highlight both fans have the same rays and an
                // output can combine them wedge by wedge.
                inside.clearRetainingCapacity();
                for (rulings.items) |u| if (u > from.u and u < to.u) try inside.append(scratch, u);
                var k: usize = 0;
                var r: usize = 0;
                while (k < between.items.len or r < inside.items.len) {
                    const take_glint = r == inside.items.len or (k < between.items.len and between.items[k] <= inside.items[r]);
                    const u = if (take_glint) between.items[k] else inside.items[r];
                    if (take_glint) k += 1 else r += 1;
                    if (marks.items[marks.items.len - 1].u == u) continue;
                    try marks.append(scratch, .{ .u = u, .shown = shows });
                }
                try marks.append(scratch, .{ .u = to.u, .shown = shows and !to.fades });
            }
        };
    }
    // A ruling where neighbouring arcs agree is one ray. Past the
    // highlight a ruling carries no glint without a mark, so of the marks
    // without one only those beside the highlight stay: there the glint
    // falls to zero, or steps to it on a terminator.
    var kept: usize = 0;
    for (marks.items) |mark| {
        if (kept != 0 and marks.items[kept - 1].u == mark.u and marks.items[kept - 1].shown == mark.shown) continue;
        marks.items[kept] = mark;
        kept += 1;
    }
    var shown: []const Mark = marks.items[0..kept];
    while (shown.len >= 2 and !shown[0].shown and !shown[1].shown) shown = shown[1..];
    while (shown.len >= 2 and !shown[shown.len - 1].shown and !shown[shown.len - 2].shown) shown = shown[0 .. shown.len - 1];
    for (shown) |mark| {
        if (mark.shown) break;
    } else shown = shown[0..0];
    // Every ray of the glint is a ray of n·l too.
    if (shown.len != 0) {
        var merged: std.ArrayList(f64) = .empty;
        var r: usize = 0;
        for (shown) |mark| {
            while (r < rulings.items.len and rulings.items[r] < mark.u) : (r += 1) try merged.append(scratch, rulings.items[r]);
            if (merged.items.len == 0 or merged.items[merged.items.len - 1] != mark.u) try merged.append(scratch, mark.u);
            if (r < rulings.items.len and rulings.items[r] == mark.u) r += 1;
        }
        try merged.appendSlice(scratch, rulings.items[r..]);
        rulings = merged;
    }

    const count = rulings.items.len;
    if (count > self.budget) return error.ShadingLimit;
    const uv = try scratch.alloc(g.Point, count);
    for (uv, rulings.items) |*at, u| at.* = .{ .x = u, .y = far };
    const nodes = try scratch.alloc(Node, count);
    try self.evaluate(scratch, face, uv, nodes);
    // A ruling seen end on has no ray.
    var longest: f64 = 0;
    for (nodes) |n| longest = @max(longest, std.math.hypot(n.x - apex.x, n.y - apex.y));
    for (nodes) |n| {
        if (n.singular or !(std.math.hypot(n.x - apex.x, n.y - apex.y) > shortest_ray * longest)) return null;
    }
    self.budget -= count;

    // A ray on each ruling, with the glint where the highlight shows. Where
    // it starts or stops on a terminator, its ruling holds two rays, a
    // step to the glint and from it.
    var rays: std.ArrayList(Ray) = .empty;
    var m: usize = 0;
    for (rulings.items, nodes) |u, n| {
        const point: g.Point = .{ .x = n.x, .y = n.y };
        const first = m;
        while (m < shown.len and shown[m].u == u) : (m += 1) {
            try rays.append(scratch, .{ .point = point, .shine = .{ .diffuse = n.shine.diffuse, .glint = if (shown[m].shown) n.raw else 0 } });
        }
        if (m == first) try rays.append(scratch, .{ .point = point, .shine = .{ .diffuse = n.shine.diffuse, .glint = 0 } });
    }
    std.debug.assert(m == shown.len);
    // Within the outline's tolerance of the apex a region reaches every
    // way, so past its end rulings the fan keeps their light, half the
    // rest of the turn each.
    var sweep: f64 = 0;
    for (rays.items[0 .. rays.items.len - 1], rays.items[1..]) |from, to| {
        const a = from.point.sub(apex);
        const b = to.point.sub(apex);
        sweep += std.math.atan2(a.cross(b), a.dot(b));
    }
    const rest = std.math.copysign(std.math.pi - @abs(sweep) / 2, sweep);
    const start = out.rays.items.len;
    try spread(self.allocator, &out.rays, apex, rays.items, rest);
    return .{ .fan = .{
        .center = apex,
        .rays = .{ .start = start, .count = out.rays.items.len - start },
        .tolerance = self.accuracy - target,
    } };
}

/// Appends `rays`, and past both ends rays that carry each end's value on
/// around `center` by `angle`, away from the other rays, in steps of at
/// most a quarter turn.
fn spread(allocator: std.mem.Allocator, out: *std.ArrayList(Ray), center: g.Point, rays: []const Ray, angle: f64) error{OutOfMemory}!void {
    const steps: usize = if (@abs(angle) > angular_precision) @intFromFloat(@ceil(@abs(angle) / (std.math.pi / 2.0))) else 0;
    const step = if (steps != 0) angle / @as(f64, @floatFromInt(steps)) else 0;
    var k = steps;
    while (k > 0) : (k -= 1) try out.append(allocator, .{ .point = turned(center, rays[0].point, -step * @as(f64, @floatFromInt(k))), .shine = rays[0].shine });
    try out.appendSlice(allocator, rays);
    const last = rays[rays.len - 1];
    for (1..steps + 1) |j| {
        try out.append(allocator, .{ .point = turned(center, last.point, step * @as(f64, @floatFromInt(j))), .shine = last.shine });
    }
}

fn turned(center: g.Point, point: g.Point, angle: f64) g.Point {
    const ray = point.sub(center);
    return center.add(.{ .x = ray.x * @cos(angle) - ray.y * @sin(angle), .y = ray.x * @sin(angle) + ray.y * @cos(angle) });
}
