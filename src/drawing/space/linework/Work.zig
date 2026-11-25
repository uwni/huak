const std = @import("std");
const c = @import("space_c");
const Model = @import("../Model.zig");
const linework = @import("../linework.zig");
const lines = @import("lines.zig");
const regions = @import("regions.zig");
const Work = @This();
const Kind = linework.Kind;
const Linework = linework.Linework;

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
model: *Model,
view: *Model.View,
out: *Linework,
tolerance: f64,
layered: bool,
features: std.ArrayList(Feature) = .empty,

/// The edges and outlines of each shape with faces, the curves of each
/// shape without, then where shapes with faces meet.
pub fn collect(self: *Work) Model.Error!void {
    const s = self.scratch;
    var shaded: usize = 0;
    for (self.model.shapes, 0..) |shape, source| {
        if (shape.faces == 0) {
            for (try self.view.curves(source)) |curve| try self.features.append(s, .{ .source = source, .kind = .curve, .curve = curve, .on_face = false });
            continue;
        }
        shaded += 1;
        for (try self.view.edges(source)) |edge| {
            const kind: Kind = switch (edge.kind) {
                c.HUAK_SMOOTH => .smooth,
                c.HUAK_SEAM => .seam,
                else => .edge,
            };
            if (edge.faces == 0) {
                try self.features.append(s, .{ .source = source, .kind = kind, .curve = edge.curve, .on_face = false });
                continue;
            }
            const divides = !(edge.faces == 1 and edge.closed != 0);
            try self.features.append(s, .{ .source = source, .kind = kind, .curve = edge.curve, .faces = .{ known(edge.face[0]), known(edge.face[1]) }, .divides = divides });
        }
        // An outline along an edge of its face is that edge's curve: a
        // seam there is an outline and divides the plane; an edge already
        // divides it.
        const first = self.features.items.len;
        rims: for (try self.view.rims(source)) |rim| {
            for (self.features.items[0..first]) |*f| if (f.source == source and f.curve == rim.curve) {
                if (!f.divides) f.* = .{ .source = source, .kind = .outline, .curve = rim.curve, .faces = .{ rim.face, null } };
                continue :rims;
            };
            try self.features.append(s, .{ .source = source, .kind = .outline, .curve = rim.curve, .faces = .{ rim.face, null } });
        }
    }
    if (shaded < 2) return;
    for (self.model.shapes, 0..) |second, j| {
        if (second.faces == 0) continue;
        for (self.model.shapes[0..j], 0..) |first, i| {
            if (first.faces == 0 or apart(first.box, second.box) or try self.model.same(i, j)) continue;
            for (try self.view.sections(i, j)) |found| try self.features.append(s, .{ .source = i, .kind = .intersection, .curve = found.curve, .other = @intCast(j), .faces = .{ known(found.face[0]), known(found.face[1]) } });
        }
    }
}

/// Arranges the plane by the images of all the features and draws those
/// that are lines, arc by arc: each arc of a curve behind the layers in
/// front of the curve over the arc's middle that run on across the arc;
/// consecutive arcs of one image behind as many make one line. A curve
/// on no face is also cut where it passes through a face of another
/// shape. Returns the arrangement with its cells, if any.
pub fn drawLines(self: *Work) Model.Error!?Drawn {
    const s = self.scratch;
    const features = self.features.items;
    var tools: std.ArrayList(Tool) = .empty;
    var cut_pairs: std.ArrayList(c.HuakPair) = .empty;
    var cut_tools: std.ArrayList(usize) = .empty;
    for ([_]bool{ true, false }) |dividing| {
        var curves: std.ArrayList(usize) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        for (features, 0..) |f, k| if ((f.on_face and f.divides) == dividing) {
            try curves.append(s, f.curve);
            try owners.append(s, k);
        };
        // The image of a curve that bounds no region keeps the curve's
        // parameter.
        const images = try s.alloc(?usize, curves.items.len);
        try self.view.project(curves.items, !dividing, self.tolerance, images);
        for (owners.items, images) |k, found| if (found) |image| {
            const f = features[k];
            if (!f.on_face) for (self.model.shapes, 0..) |shape, owner| {
                if (shape.faces == 0 or owner == f.source) continue;
                try cut_pairs.append(s, .{ .first = f.curve, .second = owner });
                try cut_tools.append(s, tools.items.len);
            };
            try tools.append(s, .{ .image = image, .curve = f.curve, .source = f.source, .kind = f.kind, .other = f.other });
        };
    }
    if (tools.items.len == 0) return null;
    var cuts: std.ArrayList(c.HuakCut) = .empty;
    if (cut_pairs.items.len > 0) {
        const pierced = try self.view.pierce(cut_pairs.items);
        for (cut_tools.items, 0..) |t, pair| for (pierced.row(pair)) |at| try cuts.append(s, .{ .image = tools.items[t].image, .parameter = at });
    }
    const images = try s.alloc(usize, tools.items.len);
    for (images, tools.items) |*image, tool| image.* = tool.image;
    const arcs = try self.view.arrange(images, cuts.items);
    const middles = try s.alloc(c.HuakXY, arcs.arcs.len);
    for (middles, arcs.arcs) |*at, arc| at.* = .{ .x = arc.x, .y = arc.y };
    const drawn: Drawn = .{ .tools = tools.items, .arcs = arcs, .cells = try self.view.cells(arcs.arcs.len), .middles = try self.view.rays(middles) };
    try lines.drawArcs(self, drawn);
    return drawn;
}

/// Writes the region of each face behind as many layers.
pub fn fillFaces(self: *Work, drawn: Drawn) Model.Error!void {
    const found = try regions.bodies(self, drawn);
    if (found.keys.len == 0) return;
    const paths = try self.view.fill(found.sets.offsets.items, found.sets.arcs.items, self.tolerance);
    const out = self.out;
    for (found.keys, 0..) |key, set| {
        const start = out.commands.items.len;
        try out.commands.appendSlice(self.allocator, paths.row(set));
        const end = out.commands.items.len;
        try out.faces.append(self.allocator, .{ .source = key.source, .face = key.face, .sides = found.shown.of(key), .start = start, .count = end - start, .covering = key.covering, .spot_start = end, .spot_count = 0, .lobe_start = 0, .lobe_count = 0, .shade_start = out.shades.items.len, .shade_count = 0 });
        try out.bounds.append(self.allocator, null);
    }
}

/// Writes the regions of the faces for smooth light: one record for
/// each connected part of the region of a face behind as many layers,
/// with its bounds, so that each can carry its own light. The records
/// of one face behind as many layers follow each other.
pub fn fillParts(self: *Work, drawn: Drawn) Model.Error!void {
    const found = try regions.bodies(self, drawn);
    if (found.keys.len == 0) return;
    const parts = try self.view.regionsOf(found.sets.offsets.items, found.sets.arcs.items, self.tolerance);
    const out = self.out;
    for (found.keys, 0..) |key, set| {
        for (parts.sets[set]..parts.sets[set + 1]) |region| {
            const start = out.commands.items.len;
            try out.commands.appendSlice(self.allocator, parts.outlines.row(region));
            try out.faces.append(self.allocator, .{ .source = key.source, .face = key.face, .sides = found.shown.of(key), .start = start, .count = out.commands.items.len - start, .covering = key.covering, .spot_start = start, .spot_count = 0, .lobe_start = 0, .lobe_count = 0, .shade_start = out.shades.items.len, .shade_count = 0 });
            try out.bounds.append(self.allocator, parts.bound(region));
        }
    }
}

/// A curve whose image divides the plane: an edge of a shape, a face's
/// outline, where two shapes meet, a curve of a shape without faces, or a
/// contour of a face's light; the faces it lies on, of `source` and then of
/// `other`, where known.
const Feature = struct {
    source: usize,
    /// The kind of line to draw; none for a contour of light, which only
    /// divides.
    kind: ?Kind,
    curve: usize,
    other: isize = -1,
    faces: [2]?usize = .{ null, null },
    /// Whether the curve lies on a face, so that the layers in front may
    /// change across its image.
    on_face: bool = true,
    /// Whether the curve bounds regions of faces: a seam, where a face meets
    /// itself, lies inside one.
    divides: bool = true,
};

/// A feature's image, with the space curve and shape it shows.
const Tool = struct {
    image: usize,
    curve: usize,
    source: usize,
    kind: ?Kind,
    other: isize = -1,
};

fn known(face: usize) ?usize {
    return if (face == c.HUAK_NO_FACE) null else face;
}

/// A line written from pieces of an image.
pub const Run = struct { source: usize, kind: Kind, other: isize, covering: usize };

/// The curves' images arranged into arcs; the cells between the arcs, with
/// the layers over each, front to back; and where the line of sight through
/// each arc's middle meets the shapes.
pub const Drawn = struct {
    tools: []const Tool,
    arcs: Model.results.Arcs,
    cells: Model.results.Cells,
    middles: Model.results.Rows(c.HuakShapeHit),

    /// The layers on the left of an arc, the left of the way it runs.
    pub fn left(self: Drawn, arc: usize) []const c.HuakLayer {
        return self.cells.layers.row(self.cells.left[arc]);
    }

    pub fn right(self: Drawn, arc: usize) []const c.HuakLayer {
        return self.cells.layers.row(self.cells.right[arc]);
    }
};

/// Whether two boxes with their tolerances are apart; a shape without
/// geometry meets nothing.
fn apart(a: ?[2][3]f64, b: ?[2][3]f64) bool {
    const x = a orelse return true;
    const y = b orelse return true;
    for (0..3) |k| if (x[0][k] > y[1][k] or y[0][k] > x[1][k]) return true;
    return false;
}
