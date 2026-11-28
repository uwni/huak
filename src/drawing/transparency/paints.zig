//! Paints: what a leaf paints, composites of paints, the paints in a
//! composite that vary across the page, and a composite as one color or as
//! one gradient on the geometry its varying paints share.
const std = @import("std");
const style = @import("../style.zig");
const enclosure = @import("../enclosure.zig");
const color_patches = @import("../color_patches.zig");
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Enclosure = enclosure.Enclosure;
const Rgba = enclosure.Rgba;
const transparency = @import("../transparency.zig");
const meshes = @import("meshes.zig");
const visibility = @import("visibility.zig");
const Expr = transparency.Expr;
const Unit = transparency.Unit;
const Piece = transparency.Piece;
const max_varying = transparency.max_varying;
const Varying = transparency.Varying;
const Track = transparency.Track;
const premultipliedInto = transparency.premultipliedInto;
const overInto = transparency.overInto;
const scaledInto = transparency.scaledInto;
const opaqueColor = transparency.opaqueColor;
const rampOf = transparency.rampOf;
const netsOf = transparency.netsOf;
const sameBits = transparency.sameBits;
const Where = visibility.Where;

const Paint = style.Paint;

pub fn paintOf(self: anytype, id: u32) Paint {
    const leaf = self.leaves.items[id];
    const draw = leaf.draw();
    return switch (leaf.component) {
        .fill => draw.style.fill.?,
        .stroke => draw.style.pen.?.paint,
        .text => unreachable,
    };
}

pub fn isOpaque(self: anytype, id: u32) bool {
    if (self.leaves.items[id].component == .text) return true;
    const paint = paintOf(self, id);
    return paint.isOpaque();
}

pub fn expr(self: anytype, value: Expr) !*const Expr {
    const result = try self.arena.create(Expr);
    result.* = value;
    return result;
}

/// `context`, outermost first, over `bottom`.
pub fn fold(self: anytype, context: []const *const Expr, bottom: *const Expr) !*const Expr {
    var result = bottom;
    var index = context.len;
    while (index > 0) {
        index -= 1;
        result = try expr(self, .{ .over = .{ .top = context[index], .bottom = result } });
    }
    return result;
}

/// The paints in `value` that vary across the page, each once. They
/// must share their geometry (see `shares`).
pub fn varying(self: anytype, value: *const Expr) !Varying {
    var result: Varying = .{};
    try gather(self, value, &result);
    return result;
}

fn gather(self: anytype, value: *const Expr, result: *Varying) !void {
    switch (value.*) {
        .leaf => |id| {
            if (self.leaves.items[id].component == .text or paintOf(self, id) == .color) return;
            result.occurrences += 1;
            if (result.occurrences > max_varying) return error.OverlappingVaryingPaints;
            if (std.mem.findScalar(u32, result.slice(), id) != null) return;
            if (result.len != 0 and !shares(self, result.ids[0], id)) return error.OverlappingVaryingPaints;
            result.ids[result.len] = id;
            result.len += 1;
        },
        .over => |pair| {
            try gather(self, pair.top, result);
            try gather(self, pair.bottom, result);
        },
        .group => |group| try gather(self, group.inner, result),
        .empty, .paper => {},
    }
}

/// Whether two paints that vary across the page lie on one geometry,
/// where a composite of them is one paint: in the same place, ramps
/// of one kind between the same points, fields or colors on the same
/// patches, or fields on the same rays.
pub fn shares(self: anytype, a: u32, b: u32) bool {
    if (!std.meta.eql(self.leaves.items[a].transform, self.leaves.items[b].transform)) return false;
    const first = paintOf(self, a).gradient;
    const second = paintOf(self, b).gradient;
    return switch (first.*) {
        .linear, .radial => |ramp| std.meta.activeTag(first.*) == std.meta.activeTag(second.*) and
            ramp.start.eql(rampOf(second).?.start) and ramp.end.eql(rampOf(second).?.end),
        .patches, .color_patches => if (netsOf(second)) |nets| sameBits(netsOf(first).?, nets) else false,
        .fan => |conic| second.* == .fan and conic.center.eql(second.fan.center) and sameBits(conic.points, second.fan.points),
    };
}

/// Whether a translucent unit paints all it covers, so that what is
/// under it shows there only through it. A unit painted with
/// patches or a conic paint paints only those, and claims nothing.
pub fn claims(self: anytype, unit: Unit) !bool {
    if (unit.opaque_) return false;
    for ((try varying(self, unit.expr)).slice()) |id| {
        if (paintOf(self, id).gradient.isMesh()) return false;
    }
    return true;
}

/// The composite `value`, premultiplied, computed in T: `colors[i]`
/// is the color of the varying paint `ids[i]`.
pub fn composedInto(self: anytype, comptime T: type, value: *const Expr, ids: []const u32, colors: []const Rgba(T), out: *Rgba(T)) void {
    switch (value.*) {
        .leaf => |id| {
            if (std.mem.findScalar(u32, ids, id)) |index| {
                premultipliedInto(T, &colors[index], out);
            } else {
                const c = paintOf(self, id).color;
                enclosure.constantsInto(T, Color{ .r = c.r * c.a, .g = c.g * c.a, .b = c.b * c.a, .a = c.a }, out);
            }
        },
        .over => |pair| {
            var top: Rgba(T) = undefined;
            var bottom: Rgba(T) = undefined;
            composedInto(self, T, pair.top, ids, colors, &top);
            composedInto(self, T, pair.bottom, ids, colors, &bottom);
            overInto(T, &top, &bottom, out);
        },
        .group => |group| {
            var inner: Rgba(T) = undefined;
            composedInto(self, T, group.inner, ids, colors, &inner);
            scaledInto(T, &inner, group.opacity, out);
        },
        .empty => enclosure.constantsInto(T, Color{ .a = 0 }, out),
        .paper => {
            const p = self.options.paper;
            enclosure.constantsInto(T, Color{ .r = p.r * p.a, .g = p.g * p.a, .b = p.b * p.a, .a = p.a }, out);
        },
    }
}

/// The color of a composite of solid paints over the paper.
pub fn solidColor(self: anytype, value: *const Expr) Color {
    var result: Rgba(Real) = undefined;
    composedInto(self, Real, value, &.{}, &.{}, &result);
    return opaqueColor(result);
}

/// The composite `value` as one gradient on the geometry its
/// varying paints share; null where it paints nothing that can show
/// `where`.
pub fn composite(self: anytype, value: *const Expr, paints: Varying, where: Where) !?*const Gradient {
    const ids = paints.slice();
    const first = paintOf(self, ids[0]).gradient;
    const result = try self.arena.create(Gradient);
    result.* = switch (first.*) {
        inline .linear, .radial => |ramp, tag| ramp: {
            var tracks: [max_varying]Track = undefined;
            for (ids, tracks[0..ids.len]) |id, *track| track.* = try rampTrack(self, rampOf(paintOf(self, id).gradient).?);
            const along = try compositeTrack(self, value, ids, tracks[0..ids.len]);
            break :ramp @unionInit(Gradient, @tagName(tag), .{ .start = ramp.start, .end = ramp.end, .colors = along.colors, .offsets = along.at });
        },
        // One field keeps its own, with stops recolored.
        .patches => |patches| if (ids.len == 1) one: {
            var colorings = [_]color_patches.Coloring{.{ .field = .{ .values = patches.values, .stops = patches.stops } }};
            const nets = try meshes.showingPatches(self, patches.points, &colorings, where, !isOpaque(self, ids[0])) orelse return null;
            break :one .{ .patches = .{
                .points = nets,
                .values = colorings[0].field.values,
                .stops = try compositeStops(self, value, ids, patches.stops),
                .tolerance = patches.tolerance,
                .margin = patches.margin,
            } };
        } else try meshes.compositeMesh(self, value, ids, where) orelse return null,
        .fan => |conic| if (ids.len == 1) .{ .fan = .{
            .center = conic.center,
            .points = conic.points,
            .values = conic.values,
            .stops = try compositeStops(self, value, ids, conic.stops),
            .tolerance = conic.tolerance,
        } } else try meshes.compositeMesh(self, value, ids, where) orelse return null,
        .color_patches => try meshes.compositeMesh(self, value, ids, where) orelse return null,
    };
    return result;
}

fn compositeStops(self: anytype, value: *const Expr, ids: []const u32, stops: Gradient.Stops) !Gradient.Stops {
    const along = try compositeTrack(self, value, ids, &.{.{ .at = stops.levels, .colors = stops.colors }});
    return .{ .levels = along.at, .colors = along.colors };
}

/// A ramp's colors along it, evenly spaced without offsets.
fn rampTrack(self: anytype, ramp: Gradient.Ramp) !Track {
    if (ramp.offsets.len != 0) return .{ .at = ramp.offsets, .colors = ramp.colors };
    const spaced = try self.arena.alloc(f64, ramp.colors.len);
    for (spaced, 0..) |*position, index| position.* = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(spaced.len - 1));
    return .{ .at = spaced, .colors = ramp.colors };
}

/// The composite `value` along one parameter, where varying paint
/// `ids[i]` has the colors `tracks[i]`: at every position of every
/// track, and between two often enough that interpolating linearly
/// strays at most `Color.tolerance`. Between two positions every
/// track is linear, and linear interpolation of n equal steps strays
/// from the composite by at most its curvature / (8 n^2).
fn compositeTrack(self: anytype, value: *const Expr, ids: []const u32, tracks: []const Track) !Track {
    var positions: std.ArrayList(f64) = .empty;
    for (tracks) |track| try positions.appendSlice(self.arena, track.at);
    std.mem.sort(f64, positions.items, {}, std.sort.asc(f64));
    var at: std.ArrayList(f64) = .empty;
    var out: std.ArrayList(Color) = .empty;
    var previous: [max_varying]Color = undefined;
    var last: ?f64 = null;
    for (positions.items) |position| {
        if (last == position) continue;
        var before: [max_varying]Color = undefined;
        var after: [max_varying]Color = undefined;
        var jumps = false;
        for (tracks, before[0..tracks.len], after[0..tracks.len]) |track, *left, *right| {
            left.*, right.* = track.sides(position);
            jumps = jumps or !std.meta.eql(left.*, right.*);
        }
        if (last) |from| {
            var leaves: [max_varying]Rgba(Enclosure) = undefined;
            for (leaves[0..tracks.len], previous[0..tracks.len], before[0..tracks.len]) |*leaf, start, end| {
                inline for (.{ "r", "g", "b", "a" }) |channel| @field(leaf.*, channel).setLinear(@field(start, channel), @field(end, channel));
            }
            var bound: Rgba(Enclosure) = undefined;
            composedInto(self, Enclosure, value, ids, leaves[0..tracks.len], &bound);
            const curvature = @max(bound.r.curvature(), bound.g.curvature(), bound.b.curvature());
            const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(curvature / (8 * Color.tolerance))))));
            for (1..steps) |step| {
                const fraction = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
                var inside: [max_varying]Rgba(Real) = undefined;
                for (inside[0..tracks.len], previous[0..tracks.len], before[0..tracks.len]) |*color, start, end| enclosure.constantsInto(Real, start.lerp(end, fraction), color);
                try at.append(self.arena, from + (position - from) * fraction);
                var step_color: Rgba(Real) = undefined;
                composedInto(self, Real, value, ids, inside[0..tracks.len], &step_color);
                try out.append(self.arena, opaqueColor(step_color));
            }
            try at.append(self.arena, position);
            try out.append(self.arena, colorAt(self, value, ids, before[0..tracks.len]));
        }
        if (last == null or jumps) {
            try at.append(self.arena, position);
            try out.append(self.arena, colorAt(self, value, ids, after[0..tracks.len]));
        }
        @memcpy(previous[0..tracks.len], after[0..tracks.len]);
        last = position;
    }
    return .{ .at = at.items, .colors = out.items };
}

fn colorAt(self: anytype, value: *const Expr, ids: []const u32, colors: []const Color) Color {
    var reals: [max_varying]Rgba(Real) = undefined;
    for (colors, reals[0..colors.len]) |color, *out| enclosure.constantsInto(Real, color, out);
    var result: Rgba(Real) = undefined;
    composedInto(self, Real, value, ids, reals[0..colors.len], &result);
    return opaqueColor(result);
}

/// A piece painting `value` where `natural` paints: with the curves of
/// a varying paint when there is one, within `natural`'s coverage.
pub fn piece(self: anytype, natural: u32, value: *const Expr) !Piece {
    const paints = try varying(self, value);
    if (paints.len == 0 or std.mem.findScalar(u32, paints.slice(), natural) != null) return .{ .geometry = natural, .expr = value };
    return .{ .geometry = paints.ids[0], .expr = value, .within = natural };
}
