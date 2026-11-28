//! Flattens transparency, as Illustrator's Object > Flatten Transparency
//! does: the result paints only opaque colors and, drawn on the paper,
//! looks the same as the source.
//!
//! The result keeps the source's paint order and its curves. Opaque paints
//! outside layers are copied. A translucent paint becomes a group clipped to
//! what it covers, holding the paint itself over the paper and then, in
//! their own order, the paints under it, each in the color the translucent
//! paint gives it. A layer (a group with an opacity) is flattened first,
//! against nothing; its pieces then take the layer's opacity and become
//! translucent paints over what lies under the layer, later pieces covering
//! earlier ones as they do inside the layer. Every piece is drawn with the
//! source's own curves and later pieces cover earlier ones, so edges
//! anti-alias as in the source and no seam opens between pieces.
//!
//! Only what shows under a translucent paint is repeated. A translucent
//! paint that later translucent paints cover entirely is skipped, so nested
//! translucency does not repeat what lies under it once per level; the
//! paint-order planar map of Adobe's flattener (US 6,720,977) makes the same
//! decision region by region. Here it is made with region operations on the
//! curves. Patches and conic paints paint only their patches and wedges,
//! which need not fill their paths, so they cover nothing for this decision.
//! Opaque paints under a translucent one are culled by bounds, or by their
//! coverage where their paint varies, since paints that vary composite only
//! where they truly overlap. One on the same curves that paints all the
//! translucent one does hides what lies under it. A piece leaves out the
//! patches that cannot show: outside the region it is drawn within, or where
//! a translucent field is transparent.
//!
//! Colors are closed form. Paints that vary across the page keep their
//! geometry and get new colors: one ramp or field new stops, ramps between
//! the same points one ramp, and fields or colors on the same patches, or
//! fields on the same rays, colors at the corners of their patches. Between
//! stops and across patches the composite is a polynomial of the paints'
//! colors; stops are inserted and patches split until it is within half an
//! 8-bit step (see `enclosure.zig`). Paints that vary on different geometry
//! have no single gradient and are refused.
const std = @import("std");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");
const DisplayList = @import("DisplayList.zig");
const style = @import("style.zig");
const enclosure = @import("enclosure.zig");
const color_patches = @import("color_patches.zig");
const Workers = @import("workers");
const reading = @import("transparency/reading.zig");
const levels = @import("transparency/levels.zig");
const writing = @import("transparency/writing.zig");
const Allocator = std.mem.Allocator;
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Rgba = enclosure.Rgba;

pub const Options = struct {
    /// What the result is drawn on.
    paper: Color = .white,
    /// Curve tolerance of the regions that decide what shows under a
    /// translucent paint, and of stroke outlines used as clips.
    tolerance: f64 = g.curve_tolerance,
    /// The result shares patch arrays with pictures attached to this store.
    meshes: ?*DisplayList.MeshStore = null,
    /// Bounded worker budget for data-parallel color-patch composition.
    workers: Workers = .serial,
};

/// `source` is borrowed for the call. `labels` resolves a text into its
/// glyphs, `resolveOutline(allocator, reference) !DisplayList`, for text
/// that lies under a translucent paint; null refuses such text.
pub fn flatten(allocator: Allocator, source: *const DisplayList, options: Options, labels: anytype) !DisplayList {
    if (!options.paper.valid() or options.paper.a != 1) return error.InvalidColor;
    if (!std.math.isFinite(options.tolerance) or !(options.tolerance > 0)) return error.InvalidTolerance;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var self: Flattener(@TypeOf(labels)) = .{ .gpa = allocator, .arena = arena.allocator(), .options = options, .labels = if (@TypeOf(labels) == @TypeOf(null)) {} else labels };
    defer self.deinit();
    const items = try reading.parse(&self, source, .{}, null);
    var units: std.ArrayList(Unit) = .empty;
    var nodes: std.ArrayList(Node) = .empty;
    try levels.level(&self, items, &units, &nodes, .paper);
    var result = DisplayList.initWithMeshes(allocator, options.meshes);
    errdefer result.deinit();
    // One group holds it all, so the result is a picture.
    try result.beginScope(.{}, null);
    try writing.write(&self, &result, nodes.items, null);
    try result.endScope();
    return result;
}

pub const Component = enum { fill, stroke, text };

/// One paint of the source: a fill, a stroke or a text, in world
/// coordinates under the clips of the groups around it.
pub const Leaf = struct {
    picture: *const DisplayList,
    /// A path or a label command of `picture`.
    command: DisplayList.Command,
    component: Component,
    transform: g.Transform,
    /// The innermost clip around it.
    clip: ?u32,
    bounds: g.BBox,

    pub fn draw(self: Leaf) DisplayList.PathCommand {
        return self.command.path;
    }
};

/// A group's clip in world coordinates, under the clip around that group.
const Clip = struct { path: Path, parent: ?u32, bounds: g.BBox };

/// The source as paints and layers, in paint order. Groups without an
/// opacity dissolve into the transforms and clips of their paints.
pub const Item = union(enum) {
    leaf: u32,
    layer: struct { opacity: f64, items: []const Item },
};

/// What a piece paints, over the source's paints and their colors. A group
/// applies a layer's opacity to what its content paints over nothing.
pub const Expr = union(enum) {
    leaf: u32,
    over: struct { top: *const Expr, bottom: *const Expr },
    group: struct { opacity: f64, inner: *const Expr },
    empty,
    paper,
};

/// A paint at one level of the paint order: a source paint, or a piece of a
/// flattened layer. It paints with `geometry`'s curves within the coverage
/// of each of `clips`.
pub const Unit = struct {
    serial: u32,
    geometry: u32,
    clips: []const u32,
    expr: *const Expr,
    opaque_: bool,
    /// The units under it are those before this index at its level.
    under: usize,
    bounds: g.BBox,
};

/// The result before it becomes a picture: groups clipped to a paint's
/// coverage, and pieces painted with a paint's curves.
pub const Node = union(enum) {
    clip: struct { leaf: u32, children: []const Node },
    piece: Piece,
};
pub const Piece = struct {
    geometry: u32,
    expr: *const Expr,
    /// The paint whose coverage clips the piece, when the piece paints with
    /// the curves of another paint: the one whose gradient it carries.
    within: ?u32 = null,
    /// Inside a group clipped to `geometry`'s own coverage, the piece
    /// fills the group instead of repeating the curves the clip has.
    fills_clip: bool = false,
};

/// What lies at the bottom of a level: the paper, or nothing in a layer.
pub const Backdrop = enum { paper, empty };

/// At most this many times paints that vary across the page enter one
/// composite: each raises its degree by one.
pub const max_varying = color_patches.max_colorings;

/// The paints of a composite that vary across the page.
pub const Varying = struct {
    ids: [max_varying]u32 = undefined,
    len: usize = 0,
    /// How often they enter it, a paint each time it does.
    occurrences: usize = 0,

    pub fn slice(self: *const Varying) []const u32 {
        return self.ids[0..self.len];
    }
};

/// Colors along a parameter, linear between positions `at`, which do not
/// decrease; where two are equal the color steps.
pub const Track = struct {
    at: []const f64,
    colors: []const Color,

    /// The colors just before and just after `position`; before the first
    /// position and past the last, the colors there.
    pub fn sides(self: Track, position: f64) [2]Color {
        const Order = struct {
            fn below(target: f64, at: f64) bool {
                return at < target;
            }
            fn notAbove(target: f64, at: f64) bool {
                return at <= target;
            }
        };
        const first = std.sort.partitionPoint(f64, self.at, position, Order.below);
        const past = std.sort.partitionPoint(f64, self.at, position, Order.notAbove);
        if (first < past) return .{ self.colors[first], self.colors[past - 1] };
        if (first == 0) return .{ self.colors[0], self.colors[0] };
        if (first == self.at.len) return .{ self.colors[first - 1], self.colors[first - 1] };
        const color = self.colors[first - 1].lerp(self.colors[first], (position - self.at[first - 1]) / (self.at[first] - self.at[first - 1]));
        return .{ color, color };
    }
};

// Compositing, on premultiplied colors with channels in `enclosure.Real` or
// `enclosure.Enclosure`.

pub fn premultiplied(comptime T: type, color: Rgba(T)) Rgba(T) {
    var result: Rgba(T) = undefined;
    premultipliedInto(T, &color, &result);
    return result;
}

pub fn premultipliedInto(comptime T: type, color: *const Rgba(T), out: *Rgba(T)) void {
    std.debug.assert(out != color);
    color.r.mulInto(&color.a, &out.r);
    color.g.mulInto(&color.a, &out.g);
    color.b.mulInto(&color.a, &out.b);
    out.a = color.a;
}

/// Porter and Duff's source over.
pub fn over(comptime T: type, top: Rgba(T), bottom: Rgba(T)) Rgba(T) {
    var result: Rgba(T) = undefined;
    overInto(T, &top, &bottom, &result);
    return result;
}

pub fn overInto(comptime T: type, top: *const Rgba(T), bottom: *const Rgba(T), out: *Rgba(T)) void {
    std.debug.assert(out != top and out != bottom);
    var one: T = undefined;
    one.setConstant(1);
    var rest: T = undefined;
    one.subInto(&top.a, &rest);
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        var under: T = undefined;
        rest.mulInto(&@field(bottom.*, channel), &under);
        @field(top.*, channel).addInto(&under, &@field(out.*, channel));
    }
}

pub fn scaled(comptime T: type, color: Rgba(T), factor: f64) Rgba(T) {
    var result: Rgba(T) = undefined;
    scaledInto(T, &color, factor, &result);
    return result;
}

pub fn scaledInto(comptime T: type, color: *const Rgba(T), factor: f64, out: *Rgba(T)) void {
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        @field(color.*, channel).scaleInto(factor, &@field(out.*, channel));
    }
}

/// A composite over the paper is opaque, so its channels are its color.
pub fn opaqueColor(color: Rgba(Real)) Color {
    return .{ .r = std.math.clamp(color.r.value, 0, 1), .g = std.math.clamp(color.g.value, 0, 1), .b = std.math.clamp(color.b.value, 0, 1) };
}

/// The ramp of a gradient along a line or a radius.
pub fn rampOf(gradient: *const Gradient) ?Gradient.Ramp {
    return switch (gradient.*) {
        .linear, .radial => |ramp| ramp,
        .patches, .fan, .color_patches => null,
    };
}

/// The patches a gradient colors.
pub fn netsOf(gradient: *const Gradient) ?[]const [16]g.Point {
    return switch (gradient.*) {
        .patches => |patches| patches.points,
        .color_patches => |patches| patches.points,
        .linear, .radial, .fan => null,
    };
}

pub fn sameBits(a: anytype, b: @TypeOf(a)) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

/// `box` narrowed to `other`, or `other` without a box.
pub fn narrowed(box: ?g.BBox, other: g.BBox) ?g.BBox {
    return if (box) |outer| intersectBoxes(outer, other) else other;
}

pub fn intersectBoxes(a: g.BBox, b: g.BBox) ?g.BBox {
    const box: g.BBox = .{ .min = .{ .x = @max(a.min.x, b.min.x), .y = @max(a.min.y, b.min.y) }, .max = .{ .x = @min(a.max.x, b.max.x), .y = @min(a.max.y, b.max.y) } };
    return if (box.min.x > box.max.x or box.min.y > box.max.y) null else box;
}

fn Flattener(comptime Labels: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// Everything here lives until the result is written.
        arena: Allocator,
        options: Options,
        labels: if (Labels == @TypeOf(null)) void else Labels,
        leaves: std.ArrayList(Leaf) = .empty,
        clips: std.ArrayList(Clip) = .empty,
        /// World regions, computed when first needed and owned by `gpa`: a
        /// paint's own shape, the region of a clip with the clips around it,
        /// and a unit's coverage when it has clips of its own.
        shapes: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        clip_regions: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        coverages: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        leaf_coverages: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        /// Where a layer's piece shows: not under later pieces of its layer.
        visible: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        /// What a group clips to where a paint paints, traced by lines.
        tracings: std.AutoHashMapUnmanaged(u32, *Path) = .empty,
        /// Closed world-space fill curves, cached on `arena`.
        closed_paths: std.AutoHashMapUnmanaged(u32, Path) = .empty,
        /// Color-patch arrays adopted into `options.meshes`, released once
        /// the output picture has taken its own references.
        adopted_colors: std.ArrayList(*Gradient.ColorPatches.Shared) = .empty,
        /// The glyphs a text resolves into, and the pictures they view.
        glyphs: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
        resolved: std.ArrayList(*DisplayList) = .empty,
        serials: u32 = 0,

        fn deinit(self: *Self) void {
            for (self.adopted_colors.items) |shared| shared.release();
            inline for (.{ &self.shapes, &self.clip_regions, &self.coverages, &self.leaf_coverages, &self.visible, &self.tracings }) |table| {
                var values = table.valueIterator();
                while (values.next()) |path| {
                    path.*.deinit();
                    self.gpa.destroy(path.*);
                }
                table.deinit(self.gpa);
            }
            self.glyphs.deinit(self.gpa);
            for (self.resolved.items) |picture| {
                picture.deinit();
                self.gpa.destroy(picture);
            }
        }

        pub fn boundsOf(self: *Self, unit: Unit) !g.BBox {
            const leaf = self.leaves.items[unit.geometry];
            if (leaf.component != .text) return unit.bounds;
            if (comptime Labels == @TypeOf(null)) {
                return unit.bounds;
            } else {
                // Glyphs may reach past the text's measured box.
                var box: ?g.BBox = null;
                for (try self.glyphsOf(unit.geometry)) |glyph| {
                    const extent = self.leaves.items[glyph].bounds;
                    box = if (box) |known| known.unite(extent) else extent;
                }
                return box orelse unit.bounds;
            }
        }

        /// The glyphs of a text as paints of their own.
        pub fn glyphsOf(self: *Self, id: u32) ![]const u32 {
            if (self.glyphs.get(id)) |known| return known;
            if (comptime Labels == @TypeOf(null)) {
                return error.LabelResolverRequired;
            } else return self.resolveGlyphs(id);
        }

        fn resolveGlyphs(self: *Self, id: u32) ![]const u32 {
            const leaf = self.leaves.items[id];
            const picture = try self.gpa.create(DisplayList);
            picture.* = self.labels.resolveOutline(self.gpa, leaf.command.label.reference) catch |err| {
                self.gpa.destroy(picture);
                return err;
            };
            self.resolved.append(self.arena, picture) catch |err| {
                picture.deinit();
                self.gpa.destroy(picture);
                return err;
            };
            const items = try reading.parse(self, picture, leaf.transform, leaf.clip);
            var ids: std.ArrayList(u32) = .empty;
            for (items) |item| switch (item) {
                .leaf => |glyph| {
                    if (self.leaves.items[glyph].component == .text) return error.TranslucentText;
                    try ids.append(self.arena, glyph);
                },
                .layer => return error.TranslucentText,
            };
            try self.glyphs.put(self.gpa, id, ids.items);
            return ids.items;
        }
    };
}

// Tests

test {
    _ = @import("transparency/translucency_test.zig");
    _ = @import("transparency/gradients_test.zig");
    _ = @import("transparency/text_test.zig");
}
