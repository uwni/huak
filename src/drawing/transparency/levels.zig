//! Levels: the source and each layer flattened into units, where each
//! translucent unit shows, and the pieces that repeat what shows under it.
const std = @import("std");
const Path = @import("../path/Path.zig");
const transparency = @import("../transparency.zig");
const compositing = @import("paints.zig");
const coverage = @import("coverage.zig");
const Item = transparency.Item;
const Expr = transparency.Expr;
const Unit = transparency.Unit;
const Node = transparency.Node;
const Backdrop = transparency.Backdrop;
const intersectBoxes = transparency.intersectBoxes;

fn newUnit(self: anytype, unit: Unit) Unit {
    var result = unit;
    result.serial = self.serials;
    self.serials += 1;
    return result;
}

/// Flattens the items of the source or of a layer, appending its
/// units to `units` and what it paints to `nodes`.
pub fn level(self: anytype, items: []const Item, units: *std.ArrayList(Unit), nodes: *std.ArrayList(Node), backdrop: Backdrop) anyerror!void {
    const first = units.items.len;
    for (items) |item| switch (item) {
        .leaf => |id| {
            const leaf = self.leaves.items[id];
            if (leaf.component == .text and backdrop == .empty) return error.TranslucentText;
            try units.append(self.arena, newUnit(self, .{ .serial = 0, .geometry = id, .clips = &.{}, .expr = try compositing.expr(self, .{ .leaf = id }), .opaque_ = compositing.isOpaque(self, id), .under = units.items.len, .bounds = leaf.bounds }));
        },
        .layer => |layer| {
            var inner_units: std.ArrayList(Unit) = .empty;
            var inner_nodes: std.ArrayList(Node) = .empty;
            try level(self, layer.items, &inner_units, &inner_nodes, .empty);
            try collect(self, inner_nodes.items, &.{}, layer.opacity, units.items.len, units);
        },
    };
    try showing(self, units.items[first..]);
    for (units.items[first..]) |unit| {
        if (unit.opaque_) {
            try nodes.append(self.arena, .{ .piece = try compositing.piece(self, unit.geometry, unit.expr) });
            continue;
        }
        // Later translucent units at this level repeat it where they
        // cover it; where none does, it shows itself.
        const region = self.visible.get(unit.serial) orelse continue;
        try translucent(self, unit, &.{}, units.items[0..unit.under], backdrop, region, nodes, true);
    }
}

/// The pieces of a flattened layer as units of the level around it.
fn collect(self: anytype, nodes: []const Node, clips: []const u32, opacity: f64, under: usize, units: *std.ArrayList(Unit)) !void {
    for (nodes) |node| switch (node) {
        .clip => |group| {
            const inner = try std.mem.concat(self.arena, u32, &.{ clips, &.{group.leaf} });
            try collect(self, group.children, inner, opacity, under, units);
        },
        .piece => |part| {
            const own = if (part.within) |within| try std.mem.concat(self.arena, u32, &.{ clips, &.{within} }) else clips;
            var box = self.leaves.items[part.geometry].bounds;
            var empty = false;
            for (own) |clip| box = intersectBoxes(box, self.leaves.items[clip].bounds) orelse {
                empty = true;
                break;
            };
            if (empty) continue;
            try units.append(self.arena, newUnit(self, .{
                .serial = 0,
                .geometry = part.geometry,
                .clips = own,
                .expr = try compositing.expr(self, .{ .group = .{ .opacity = opacity, .inner = part.expr } }),
                .opaque_ = false,
                .under = under,
                .bounds = box,
            }));
        },
    };
}

/// Where each translucent unit of a level shows: not under a later
/// one that claims what it covers (see `claims`) and repeats it
/// there. Units shown nowhere get no region.
fn showing(self: anytype, units: []const Unit) !void {
    var claimed: std.ArrayList(Unit) = .empty;
    var index = units.len;
    while (index > 0) {
        index -= 1;
        const unit = units[index];
        if (unit.opaque_) continue;
        const shown = region: {
            var rest = try (try coverage.coverage(self, unit)).clone(self.gpa);
            errdefer rest.deinit();
            for (claimed.items) |later| {
                const box = rest.bounds() orelse break;
                if (!later.bounds.overlaps(box, 0)) continue;
                const next = try coverage.combine(self, rest, (try coverage.coverage(self, later)).*, .difference);
                rest.deinit();
                rest = next;
            }
            if (try compositing.claims(self, unit)) try claimed.append(self.arena, unit);
            break :region rest;
        };
        if (shown.segments.items.len == 0) {
            var nothing = shown;
            nothing.deinit();
            continue;
        }
        _ = try coverage.store(self, &self.visible, unit.serial, shown);
    }
}

/// A translucent unit, where it shows within `region`: its paint over
/// the backdrop, then what shows under it in the colors it gives
/// them. Grouped, all of it is clipped to the unit's coverage; a unit
/// that covers everything still unclaimed where it is repeated needs
/// no group, since later paints cover whatever spills past it.
fn translucent(self: anytype, unit: Unit, context: []const *const Expr, under: []const Unit, backdrop: Backdrop, region: *const Path, out: *std.ArrayList(Node), grouped: bool) anyerror!void {
    const inner = try std.mem.concat(self.arena, *const Expr, &.{ context, &.{unit.expr} });
    var children: std.ArrayList(Node) = .empty;
    const target = if (grouped) &children else out;
    var shown = try below(self, unit, under, region);
    defer {
        for (shown.entries.items) |entry| if (entry.visible) |path| {
            path.deinit();
            self.gpa.destroy(path);
        };
        shown.entries.deinit(self.gpa);
    }
    // Over a unit that covers all of it, the paint over the backdrop
    // never shows.
    if (!shown.covered) {
        const bottom = try compositing.expr(self, if (backdrop == .paper) .paper else .empty);
        try target.append(self.arena, .{ .piece = try compositing.piece(self, unit.geometry, try compositing.fold(self, inner, bottom)) });
    }
    for (shown.entries.items) |entry| {
        const beneath = under[entry.index];
        if (!beneath.opaque_) {
            try translucent(self, beneath, inner, under[0..beneath.under], backdrop, entry.visible.?, target, !entry.covers);
        } else if (self.leaves.items[beneath.geometry].component == .text) {
            // A text changes color under a translucent paint: its
            // glyphs take its place there.
            for (try self.glyphsOf(beneath.geometry)) |glyph| {
                if (!compositing.isOpaque(self, glyph)) return error.TranslucentText;
                try target.append(self.arena, .{ .piece = try compositing.piece(self, glyph, try compositing.fold(self, inner, try compositing.expr(self, .{ .leaf = glyph }))) });
            }
        } else try target.append(self.arena, .{ .piece = try compositing.piece(self, beneath.geometry, try compositing.fold(self, inner, beneath.expr)) });
    }
    if (!grouped) return;
    var node: Node = node: {
        const items = children.items;
        const base = if (items.len != 0 and items[0] == .piece and items[0].piece.geometry == unit.geometry and items[0].piece.within == null) &items[0].piece else null;
        // A paint with nothing under it is its own curves.
        if (items.len == 1 and base != null) break :node items[0];
        if (base) |piece_| piece_.fills_clip = true;
        break :node .{ .clip = .{ .leaf = unit.geometry, .children = items } };
    };
    var index = unit.clips.len;
    while (index > 0) {
        index -= 1;
        const wrapped = try self.arena.alloc(Node, 1);
        wrapped[0] = node;
        node = .{ .clip = .{ .leaf = unit.clips[index], .children = wrapped } };
    }
    try out.append(self.arena, node);
}

const Shown = struct {
    index: usize,
    /// Where a translucent unit shows.
    visible: ?*Path,
    /// Whether that is everything the unit was looked under.
    covers: bool = false,
};
const Below = struct { entries: std.ArrayList(Shown), covered: bool };

/// The units of `under` that show within `region`, where `owner`
/// shows, in paint order, with where each translucent one shows. A
/// translucent unit that claims what it covers (see `claims`) hides
/// it from the units under it. Opaque units are culled by bounds, or
/// by their coverage where their paint varies: a composite with
/// another varying paint exists only where the two truly overlap.
/// They hide nothing, unless they cover all the owner paints (see
/// `covers`). `covered` is set when one unit covers or claims all
/// that is left, so nothing under it shows and neither does anything
/// before it.
fn below(self: anytype, owner: Unit, under: []const Unit, region: *const Path) !Below {
    var result: Below = .{ .entries = .empty, .covered = false };
    errdefer {
        for (result.entries.items) |entry| if (entry.visible) |path| {
            path.deinit();
            self.gpa.destroy(path);
        };
        result.entries.deinit(self.gpa);
    }
    if (under.len == 0) return result;
    var unclaimed = try region.clone(self.gpa);
    defer unclaimed.deinit();
    var box = unclaimed.bounds() orelse return result;
    var index = under.len;
    while (index > 0) {
        index -= 1;
        const beneath = under[index];
        if (!(try self.boundsOf(beneath)).overlaps(box, 0)) continue;
        if (beneath.opaque_) {
            if ((try compositing.varying(self, beneath.expr)).len != 0 and !try meets(self, beneath, &unclaimed)) continue;
            try result.entries.append(self.gpa, .{ .index = index, .visible = null });
            if (try covers(self, beneath, owner)) {
                result.covered = true;
                break;
            }
            continue;
        }
        const covered = try coverage.coverage(self, beneath);
        var visible = try coverage.combine(self, unclaimed, covered.*, .intersect);
        if (visible.segments.items.len == 0) {
            visible.deinit();
            continue;
        }
        const owned = self.gpa.create(Path) catch |err| {
            visible.deinit();
            return err;
        };
        owned.* = visible;
        result.entries.append(self.gpa, .{ .index = index, .visible = owned }) catch |err| {
            owned.deinit();
            self.gpa.destroy(owned);
            return err;
        };
        if (!try compositing.claims(self, beneath)) continue;
        const rest = try coverage.combine(self, unclaimed, covered.*, .difference);
        unclaimed.deinit();
        unclaimed = rest;
        if (rest.segments.items.len == 0) {
            result.entries.items[result.entries.items.len - 1].covers = true;
            result.covered = true;
            break;
        }
        box = unclaimed.bounds() orelse break;
    }
    std.mem.reverse(Shown, result.entries.items);
    return result;
}

/// Whether an opaque unit paints all that a translucent one can: a
/// fill on the same curves in the same place, with a paint that
/// fills them, or on the same patches or rays as each paint of the
/// translucent one that varies.
fn covers(self: anytype, opaque_unit: Unit, unit: Unit) !bool {
    if (opaque_unit.clips.len != 0 or unit.clips.len != 0) return false;
    const a = self.leaves.items[opaque_unit.geometry];
    const b = self.leaves.items[unit.geometry];
    if (a.component != .fill or b.component != .fill or a.clip != b.clip or !std.meta.eql(a.transform, b.transform)) return false;
    if (a.draw().style.fill_rule != b.draw().style.fill_rule) return false;
    const curves = try a.picture.range(a.draw().path);
    const others = try b.picture.range(b.draw().path);
    if (curves.len != others.len) return false;
    for (curves, others) |x, y| if (!std.meta.eql(x, y)) return false;
    switch (compositing.paintOf(self, opaque_unit.geometry)) {
        .color => return true,
        .gradient => |gradient| if (!gradient.isMesh()) return true,
    }
    const paints = try compositing.varying(self, unit.expr);
    for (paints.slice()) |id| if (!compositing.shares(self, opaque_unit.geometry, id)) return false;
    return paints.len != 0;
}

/// Whether a unit covers any of `region`.
fn meets(self: anytype, unit: Unit, region: *const Path) !bool {
    var common = try coverage.combine(self, region.*, (try coverage.coverage(self, unit)).*, .intersect);
    defer common.deinit();
    return common.segments.items.len != 0;
}
