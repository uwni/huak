//! Band light: each face in bands of n·l between the isophotes, with a
//! highlight around the half vector.
//!
//! The bands of a curved face end at its isophotes and its highlight at the
//! contour around the half vector, the terminator and the face's outline.
//! These contours divide the plane with the curves drawn, so the light of
//! every layer is one over each cell of the arcs: that of its face where
//! the line of sight that found the cell's layers meets it.
const std = @import("std");
const c = @import("space_c");
const Model = @import("../Model.zig");
const shading = @import("../shading.zig");
const dot = shading.dot;
const linework = @import("../linework.zig");
const layer_light = @import("light.zig");
const highlight_spots = @import("spots.zig");
const regions = @import("regions.zig");
const Work = @import("Work.zig");
const Bands = @This();
const Key = regions.Key;
const Light = linework.Light;
const Drawn = Work.Drawn;
const Bounding = regions.Bounding;
const keyOf = regions.keyOf;
const gleams = layer_light.gleams;
const sortedOrder = regions.sortedOrder;
const Sets = regions.Sets;

sun: [3]f64,
half: ?[3]f64,
cutoff: f64,
isophotes: []const f64,
faces: [][]FaceLight,

/// The band of n·l a layer lies in, and whether it lies in the highlight.
pub const Sample = struct { diffuse: f64, gleam: bool };
/// A band of a face behind as many layers; `diffuse` is the band's light
/// as bits.
const Shaded = struct { key: Key, diffuse: u64 };

pub fn init(work: *Work, light: Light) Model.Error!Bands {
    const s = work.scratch;
    const sun = shading.unit(light.direction);
    const faces = try s.alloc([]FaceLight, work.model.shapes.len);
    for (faces, work.model.shapes, 0..) |*list, shape, source| {
        list.* = try s.alloc(FaceLight, shape.faces);
        for (list.*, 0..) |*paint, index| paint.* = .{ .planar = (try work.model.face(source, index)).kind == .planar };
    }
    return .{
        .sun = sun,
        .half = shading.halfway(sun, work.view.frame.eye, light.spot),
        .cutoff = @cos(light.spot),
        .isophotes = light.isophotes,
        .faces = faces,
    };
}

/// Where the normal makes a given cosine with a unit direction: the
/// same curves as for the opposite direction and the opposite cosine.
const Level = struct {
    direction: [3]f64,
    cosine: f64,

    /// Whether two levels are one: their directions agree, or are
    /// opposite, within OCCT's angular precision, and so do their
    /// cosines, which are given numbers.
    fn same(a: Level, b: Level) bool {
        const turn = cross(a.direction, b.direction);
        if (@sqrt(dot(turn, turn)) > shading.angular_precision) return false;
        return if (dot(a.direction, b.direction) > 0) a.cosine == b.cosine else a.cosine == -b.cosine;
    }
};

/// Adds every curved face's isophotes and the boundary of its highlight
/// to the curves that divide the plane, each curve once: a level that is
/// the face's outline, where the normal is square to the line of sight,
/// or a level already traced, adds none. A plane has one light.
pub fn trace(self: *const Bands, work: *Work) Model.Error!void {
    const s = work.scratch;
    var levels: std.ArrayList(Level) = .empty;
    try levels.append(s, .{ .direction = work.view.frame.eye, .cosine = 0 });
    for (self.isophotes) |level| try levels.append(s, .{ .direction = self.sun, .cosine = level });
    if (self.half) |half| try levels.append(s, .{ .direction = half, .cosine = self.cutoff });
    for (self.faces, 0..) |list, source| for (list, 0..) |paint, face| {
        if (paint.planar) continue;
        for (levels.items[1..], 1..) |level, k| {
            const traced = for (levels.items[0..k]) |earlier| {
                if (Level.same(earlier, level)) break true;
            } else false;
            if (traced) continue;
            for (try work.view.contours(source, face, level.direction, std.math.acos(level.cosine))) |curve| try work.features.append(s, .{ .source = source, .kind = null, .curve = curve, .faces = .{ face, null } });
        }
    };
}

/// Writes the regions of the faces with their light. Behind each number
/// of layers a face's region is where the next layer is of that face;
/// its bands and its highlight are where that layer has their light; the
/// arcs across which each changes bound it. A face's highlights before
/// occlusion are where any of its layers gleams.
pub fn fill(self: *Bands, work: *Work, drawn: Drawn) Model.Error!void {
    const s = work.scratch;
    const lights = try layer_light.lightsOf(self, work, drawn.cells.layers.values);
    const cells = drawn.cells;
    var bodies: Bounding(Key) = .{};
    var shades: Bounding(Shaded) = .{};
    var spots: Bounding(Key) = .{};
    var lit: Bounding([2]usize) = .{};
    var shown: regions.Shown = .{};
    for (0..drawn.arcs.arcs.len) |k| {
        const layers: [2][]const c.HuakLayer = .{ drawn.left(k), drawn.right(k) };
        const light: [2][]const Sample = .{
            lights[cells.layers.offsets[cells.left[k]]..][0..layers[0].len],
            lights[cells.layers.offsets[cells.right[k]]..][0..layers[1].len],
        };
        for (0..@max(layers[0].len, layers[1].len)) |covering| {
            var body: [2]?Key = .{ null, null };
            var shade: [2]?Shaded = .{ null, null };
            var spot: [2]?Key = .{ null, null };
            for (0..2) |side| if (covering < layers[side].len) {
                const key = keyOf(covering, layers[side][covering]);
                try shown.add(s, covering, layers[side][covering]);
                const sample = light[side][covering];
                body[side] = key;
                shade[side] = .{ .key = key, .diffuse = @bitCast(sample.diffuse) };
                if (sample.gleam) spot[side] = key;
            };
            try bodies.between(s, k, body[0], body[1]);
            try shades.between(s, k, shade[0], shade[1]);
            try spots.between(s, k, spot[0], spot[1]);
        }
        for (0..2) |side| for (layers[side], light[side], 0..) |layer, sample, index| {
            if (!sample.gleam or self.faces[layer.source][layer.face].planar) continue;
            if (gleams(layers[side][0..index], light[side][0..index], layer) or gleams(layers[1 - side], light[1 - side], layer)) continue;
            try lit.add(s, .{ layer.source, layer.face }, .{ .arc = k, .reversed = @intCast(side) });
        };
    }
    try highlight_spots.fitSpots(self, work, &lit);
    const keys = bodies.arcs.keys();
    if (keys.len == 0) return;
    const order = try sortedOrder(s, keys);
    // Each face's bands behind as many layers, the darkest first.
    const bands = try s.alloc(std.ArrayList(Shaded), keys.len);
    @memset(bands, .empty);
    for (shades.arcs.keys()) |shaded| try bands[bodies.arcs.getIndex(shaded.key) orelse return work.model.failWith("a band of light lies on no region of its face")].append(s, shaded);
    for (bands) |*list| std.mem.sort(Shaded, list.items, {}, struct {
        fn less(_: void, x: Shaded, y: Shaded) bool {
            return @as(f64, @bitCast(x.diffuse)) < @as(f64, @bitCast(y.diffuse));
        }
    }.less);
    // The sets of arcs to fill, in the order they are written: each
    // face's region, its highlight where that is not the whole region,
    // and its bands where it has more than one.
    var sets: Sets = .{};
    for (order) |k| {
        const key = keys[k];
        _ = try sets.add(s, bodies.arcs.values()[k].items);
        if (!self.faces[key.source][key.face].planar) if (spots.of(key)) |arcs| {
            _ = try sets.add(s, arcs);
        };
        if (bands[k].items.len > 1) for (bands[k].items) |shaded| {
            _ = try sets.add(s, shades.of(shaded).?);
        };
    }
    const paths = try work.view.fill(sets.offsets.items, sets.arcs.items, work.tolerance);
    const a = work.allocator;
    const out = work.out;
    var set: usize = 0;
    for (order) |k| {
        const key = keys[k];
        const paint = self.faces[key.source][key.face];
        const start = out.commands.items.len;
        try out.commands.appendSlice(a, paths.row(set));
        set += 1;
        const end = out.commands.items.len;
        // A plane has one normal, so its gleam covers its entire region.
        var spot_start = end;
        if (spots.of(key) != null) {
            if (paint.planar) {
                spot_start = start;
            } else {
                try out.commands.appendSlice(a, paths.row(set));
                set += 1;
            }
        }
        const spot_count = out.commands.items.len - spot_start;
        const shade_start = out.shades.items.len;
        if (bands[k].items.len == 1) {
            try out.shades.append(a, .{ .start = start, .count = end - start, .diffuse = @bitCast(bands[k].items[0].diffuse) });
        } else for (bands[k].items) |shaded| {
            const first = out.commands.items.len;
            try out.commands.appendSlice(a, paths.row(set));
            set += 1;
            try out.shades.append(a, .{ .start = first, .count = out.commands.items.len - first, .diffuse = @bitCast(shaded.diffuse) });
        }
        try out.faces.append(a, .{ .source = key.source, .face = key.face, .sides = shown.of(key), .start = start, .count = end - start, .covering = key.covering, .spot_start = spot_start, .spot_count = spot_count, .lobe_start = paint.start, .lobe_count = paint.count, .shade_start = shade_start, .shade_count = out.shades.items.len - shade_start });
        try out.bounds.append(a, null);
    }
}

/// A face in band light: whether it is planar, and the ellipses fitted to
/// its highlights.
pub const FaceLight = struct {
    planar: bool,
    start: usize = 0,
    count: usize = 0,
};

fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
