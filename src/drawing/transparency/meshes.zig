//! Visibility culling and color-patch composition for mesh gradients shared
//! across translucent layers.
const std = @import("std");
const g = @import("../geometry.zig");
const style = @import("../style.zig");
const outline = @import("../outline.zig");
const enclosure = @import("../enclosure.zig");
const color_patches = @import("../color_patches.zig");
const conic_mesh = @import("../conic.zig");
const transparency = @import("../transparency.zig");
const paints = @import("paints.zig");
const visibility = @import("visibility.zig");
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Rgba = enclosure.Rgba;
const Expr = transparency.Expr;
const max_varying = transparency.max_varying;
const opaqueColor = transparency.opaqueColor;
const netsOf = transparency.netsOf;
const Where = visibility.Where;
const paintOf = paints.paintOf;
const isOpaque = paints.isOpaque;
const composedInto = paints.composedInto;

/// Of patches `nets` with `colorings`, which are narrowed to match,
/// those that can show, or null when none can: those that can meet
/// `where`, and with `painting` only those where no field is
/// transparent across the patch. A field paint claims nothing (see
/// `paints.claims`), so where it paints nothing other pieces paint what
/// shows, as long as every piece of its group leaves the same patches
/// out: pieces on a paint's own patches do, but conic paints are
/// lowered to different patches for different pieces.
pub fn showingPatches(self: anytype, nets: []const [16]g.Point, colorings: []color_patches.Coloring, where: Where, painting: bool) !?[]const [16]g.Point {
    var kept: std.ArrayList(usize) = .empty;
    for (nets, 0..) |*net, k| {
        if (!where.meets(net, self.options.tolerance)) continue;
        const shows = !painting or for (colorings) |coloring| {
            if (coloring == .field and !coloring.field.stops.paints(&coloring.field.values[k])) break false;
        } else true;
        if (shows) try kept.append(self.arena, k);
    }
    if (kept.items.len == 0) return null;
    if (kept.items.len == nets.len) return nets;
    for (colorings) |*coloring| switch (coloring.*) {
        .field => |*field| field.values = try select(self, [16]f64, field.values, kept.items),
        .corners => |*corners| corners.* = try select(self, [4]Color, corners.*, kept.items),
    };
    return try select(self, [16]g.Point, nets, kept.items);
}

fn select(self: anytype, comptime T: type, items: []const T, kept: []const usize) ![]const T {
    const result = try self.arena.alloc(T, kept.len);
    for (kept, result) |k, *item| item.* = items[k];
    return result;
}

/// Colors at patch corners for a composite of paints on the same
/// patches, or of conic paints on the same rays, lowered to the
/// same patches; null where none of them can show `where`.
pub fn compositeMesh(self: anytype, value: *const Expr, ids: []const u32, where: Where) !?Gradient {
    var colorings: [max_varying]color_patches.Coloring = undefined;
    var nets: []const [16]g.Point = undefined;
    const lowered = paintOf(self, ids[0]).gradient.* == .fan;
    if (lowered) {
        var conics: [max_varying]Gradient.Conic = undefined;
        for (ids, conics[0..ids.len]) |id, *conic| conic.* = paintOf(self, id).gradient.fan;
        const shared = try conic_mesh.sharedPatches(self.arena, conics[0..ids.len], where.cover, outline.max_items);
        nets = shared.points;
        for (conics[0..ids.len], colorings[0..ids.len], 0..) |conic, *coloring, index| {
            coloring.* = .{ .field = .{ .values = shared.field(index), .stops = conic.stops } };
        }
    } else {
        nets = netsOf(paintOf(self, ids[0]).gradient).?;
        for (ids, colorings[0..ids.len]) |id, *coloring| coloring.* = switch (paintOf(self, id).gradient.*) {
            .patches => |patches| .{ .field = .{ .values = patches.values, .stops = patches.stops } },
            .color_patches => |patches| .{ .corners = patches.colors },
            else => unreachable,
        };
    }
    var has_opaque = false;
    var margin: f64 = 0;
    for (ids) |id| {
        if (isOpaque(self, id)) has_opaque = true;
        switch (paintOf(self, id).gradient.*) {
            .patches => |patches| margin = @max(margin, patches.margin),
            .color_patches => |patches| margin = @max(margin, patches.margin),
            else => {},
        }
    }
    const shown = try showingPatches(self, nets, colorings[0..ids.len], where, !lowered and !has_opaque) orelse return null;
    // One opaque color_patches paint composited with constants and constant
    // group opacities is an exact affine map of its four corner colors: zero
    // interpolation error, no enclosure algebra or subdivision needed.
    if (!lowered and ids.len == 1 and colorings[0] == .corners) {
        if (shown.len > outline.max_items) return error.GeometryWorkLimit;
        const source_colors = colorings[0].corners;
        if (self.options.meshes) |store| {
            const target = store.lockedAllocator();
            const points = try target.dupe([16]g.Point, shown);
            errdefer target.free(points);
            const colors = try target.alloc([4]Color, shown.len);
            errdefer target.free(colors);
            mapCorners(self, value, ids, source_colors, colors);
            return .{ .color_patches = try adoptColorPatches(self, store, .{ .points = points, .colors = colors, .margin = margin }) };
        }
        const colors = try self.arena.alloc([4]Color, shown.len);
        mapCorners(self, value, ids, source_colors, colors);
        return .{ .color_patches = .{ .points = shown, .colors = colors, .margin = margin } };
    }
    const Flattening = @TypeOf(self);
    const Combine = struct {
        flattener: Flattening,
        value: *const Expr,
        ids: []const u32,

        pub fn colorInto(context: @This(), comptime T: type, colors: []const Rgba(T), out: *Rgba(T)) void {
            composedInto(context.flattener, T, context.value, context.ids, colors, out);
        }
    };
    const opts: color_patches.ComposeOptions = .{ .tolerance = Color.tolerance, .max_patches = outline.max_items, .workers = self.options.workers };
    const combiner: Combine = .{ .flattener = self, .value = value, .ids = ids };
    if (self.options.meshes) |store| {
        const target = store.lockedAllocator();
        const owned = try color_patches.compose(target, shown, colorings[0..ids.len], combiner, opts);
        errdefer owned.deinit(target);
        var view = owned.view();
        view.margin = margin;
        return .{ .color_patches = try adoptColorPatches(self, store, view) };
    }
    var composed = try color_patches.composeArena(self.arena, shown, colorings[0..ids.len], combiner, opts);
    composed.margin = margin;
    return .{ .color_patches = composed };
}

fn mapCorners(self: anytype, value: *const Expr, ids: []const u32, source: []const [4]Color, dest: [][4]Color) void {
    for (source, dest) |corners, *out| {
        for (corners, out) |color, *mapped| {
            var leaf: [1]Rgba(Real) = undefined;
            enclosure.constantsInto(Real, color, &leaf[0]);
            var result: Rgba(Real) = undefined;
            composedInto(self, Real, value, ids, &leaf, &result);
            mapped.* = opaqueColor(result);
        }
    }
}

fn adoptColorPatches(self: anytype, store: *Gradient.Store, patches: Gradient.ColorPatches) !Gradient.ColorPatches {
    const shared = try Gradient.ColorPatches.Shared.adopt(self.gpa, store, patches);
    errdefer shared.release();
    try self.adopted_colors.append(self.arena, shared);
    return shared.view();
}
