//! The line work of a projected model: its curves, split where the number of
//! sheets in front of them changes, and its visible faces, divided where the
//! sheets in front change, with band lighting and highlight ellipses. OCCT
//! answers every geometric question through `Model.View`; this module decides
//! what to ask and what to draw.
const std = @import("std");
const c = @import("space_c");
const g = @import("../geometry.zig");
const Model = @import("Model.zig");
const shading = @import("shading.zig");

/// OCCT's tolerances: points closer than `confusion` coincide, and curve
/// parameters closer than `parametric`; directions shorter than `angular`
/// have none.
const confusion = 1e-7;
const parametric = 1e-9;
const angular = 1e-12;

/// The order matches the C header's projected kinds.
pub const Kind = enum(c_int) { edge, outline, smooth, seam, curve, intersection };

/// Commands start..start + count of a curve or of a region's outline.
pub const Line = struct { source: usize, start: usize, count: usize, covering: usize, kind: Kind, other: isize };
/// A region of a face behind `covering` sheets, with its highlight, the
/// ellipses fitted to its face's highlights, and its bands of diffuse light.
pub const Face = struct {
    source: usize,
    face: usize,
    start: usize,
    count: usize,
    covering: usize,
    spot_start: usize,
    spot_count: usize,
    lobe_start: usize,
    lobe_count: usize,
    shade_start: usize,
    shade_count: usize,
};
pub const Spot = struct { center: g.Point, u: g.Point, v: g.Point };
pub const Shade = struct { start: usize, count: usize, diffuse: f64 };

pub const Linework = struct {
    commands: std.ArrayList(c.HuakPathCommand) = .empty,
    lines: std.ArrayList(Line) = .empty,
    faces: std.ArrayList(Face) = .empty,
    lobes: std.ArrayList(Spot) = .empty,
    shades: std.ArrayList(Shade) = .empty,
    /// The camera's frame as OCCT built it.
    frame: c.HuakFrame = undefined,
    /// The bounds of each face record's region, with its tolerance.
    bounds: std.ArrayList(?g.BBox) = .empty,

    pub fn deinit(self: *Linework, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.lines.deinit(allocator);
        self.faces.deinit(allocator);
        self.lobes.deinit(allocator);
        self.shades.deinit(allocator);
        self.bounds.deinit(allocator);
        self.* = undefined;
    }
};

pub const Camera = struct { azimuth: f64, elevation: f64, focus: f64 };

pub const Light = struct {
    /// Toward the light, of any length.
    direction: [3]f64,
    /// The highlight's angle around the half vector; zero for none.
    spot: f64,
    /// Increasing levels of n·l at which bands begin, the first zero.
    isophotes: []const f64,
    /// Regions for continuous light instead of bands.
    smooth: bool,
};

pub const Options = struct { faces: bool, light: ?Light, tolerance: f64 };

/// A view of the model for `camera`, which looks at the origin from
/// `azimuth` around z and `elevation` above the xy plane, with the screen's x
/// axis horizontal. `scratch` serves the view's conversions.
pub fn view(model: *Model, scratch: std.mem.Allocator, camera: Camera) Model.Error!Model.View {
    const eye: [3]f64 = .{ @cos(camera.elevation) * @cos(camera.azimuth), @cos(camera.elevation) * @sin(camera.azimuth), @sin(camera.elevation) };
    const x: [3]f64 = .{ -@sin(camera.azimuth), @cos(camera.azimuth), 0 };
    return model.view(scratch, eye, x, camera.focus);
}

/// The line work `view` shows of its model.
pub fn project(allocator: std.mem.Allocator, view_: *Model.View, options: Options) Model.Error!Linework {
    const model = view_.model;
    if (options.light != null and (view_.frame.focus != 0 or !options.faces)) return model.failWith("directional shading requires orthographic face projection");
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var result: Linework = .{ .frame = view_.frame };
    errdefer result.deinit(allocator);
    var work: Work = .{ .allocator = allocator, .scratch = arena.allocator(), .model = model, .view = view_, .out = &result, .tolerance = options.tolerance, .layered = options.faces };
    try work.collect();
    const boundaries = try work.drawLines();
    if (options.faces) try work.divideFaces(boundaries, options.light);
    return result;
}

/// A curve to draw: from hidden-line removal with its visibility in its own
/// shape, a free curve of a shape without faces, or where two shapes meet.
const Feature = struct {
    source: usize,
    kind: Kind,
    own: ?bool,
    curve: usize,
    other: isize = -1,
};

/// A hit along a line of sight; nearer hits have larger depths.
const Hit = struct { source: usize, face: usize, depth: f64, uv: c.HuakUV };

/// Images that bound regions of faces, and the visible outlines that separate
/// the sheets of their shape.
const Boundaries = struct { images: []const usize, contours: []const c.HuakTracked };

const Work = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    model: *Model,
    view: *Model.View,
    out: *Linework,
    tolerance: f64,
    layered: bool,
    features: std.ArrayList(Feature) = .empty,

    fn faces(self: *const Work, source: usize) usize {
        return self.model.shapes[source].faces;
    }

    /// Hidden-line removal of each shape with faces, the curves of each shape
    /// without, then where shapes with faces meet.
    fn collect(self: *Work) Model.Error!void {
        const s = self.scratch;
        var shaded: usize = 0;
        for (self.model.shapes, 0..) |shape, source| {
            if (shape.faces == 0) {
                for (try self.view.curves(source)) |curve| try self.features.append(s, .{ .source = source, .kind = .curve, .own = null, .curve = curve });
                continue;
            }
            shaded += 1;
            for (try self.view.silhouettes(source)) |found| try self.features.append(s, .{ .source = source, .kind = @fromBackingInt(@intCast(found.kind)), .own = found.visible != 0, .curve = found.curve });
        }
        if (shaded < 2) return;
        for (self.model.shapes, 0..) |second, j| {
            if (second.faces == 0) continue;
            for (self.model.shapes[0..j], 0..) |first, i| {
                if (first.faces == 0 or apart(first.box, second.box) or try self.model.same(i, j)) continue;
                for (try self.view.sections(i, j)) |curve| try self.features.append(s, .{ .source = i, .kind = .intersection, .own = null, .curve = curve, .other = @intCast(j) });
            }
        }
    }

    /// Draws each curve whole where its own shape decides how many sheets
    /// cover it, and otherwise split wherever it crosses another curve's
    /// image or pierces another shape, ranking each piece by the sheets in
    /// front of its middle.
    fn drawLines(self: *Work) Model.Error!Boundaries {
        const s = self.scratch;
        const features = self.features.items;
        // The images of the curves from hidden-line removal.
        const own_images = try s.alloc(?usize, features.len);
        @memset(own_images, null);
        {
            var curves: std.ArrayList(usize) = .empty;
            var owners: std.ArrayList(usize) = .empty;
            for (features, 0..) |f, k| if (f.own != null) {
                try curves.append(s, f.curve);
                try owners.append(s, k);
            };
            const images = try s.alloc(?usize, curves.items.len);
            try self.view.project(curves.items, false, self.tolerance, images);
            for (owners.items, images) |k, image| own_images[k] = image;
        }
        const Border = struct { feature: usize, image: usize };
        var borders: std.ArrayList(Border) = .empty;
        var boundaries: std.ArrayList(usize) = .empty;
        var contours: std.ArrayList(c.HuakTracked) = .empty;
        for (features, own_images, 0..) |f, found, k| {
            const own = f.own orelse continue;
            const image = found orelse continue;
            if (self.layered or own) try borders.append(s, .{ .feature = k, .image = image });
            if (self.layered and f.kind == .outline) try boundaries.append(s, image);
            if (self.layered and f.kind == .outline and own) try contours.append(s, .{ .image = image, .source = f.source });
        }
        var shaded: usize = 0;
        for (self.model.shapes) |shape| shaded += @intFromBool(shape.faces > 0);

        // Which curves are split, and the images of their splines.
        const Plan = union(enum) { skip, whole: usize, split };
        const plans = try s.alloc(Plan, features.len);
        var split: std.ArrayList(usize) = .empty;
        for (features, own_images, plans, 0..) |f, image, *plan, k| {
            plan.* = .split;
            if (f.own) |own| {
                if (image == null) {
                    plan.* = .skip;
                } else if ((!self.layered and !own) or (shaded == 1 and (own or !self.layered))) {
                    plan.* = .{ .whole = @intFromBool(!own) };
                }
            }
            if (plan.* == .split) try split.append(s, k);
        }
        const split_curves = try s.alloc(usize, split.items.len);
        for (split_curves, split.items) |*curve, k| curve.* = features[k].curve;
        const spline_images = try s.alloc(?usize, split.items.len);
        try self.view.project(split_curves, true, self.tolerance, spline_images);

        // The curves with an image: their spans, crossings and piercings.
        var traced: std.ArrayList(Traced) = .empty;
        var crossing_pairs: std.ArrayList(c.HuakPair) = .empty;
        var pierce_pairs: std.ArrayList(c.HuakPair) = .empty;
        for (split.items, spline_images) |k, found| {
            const image = found orelse continue;
            const f = features[k];
            if (self.layered and f.kind == .intersection) try boundaries.append(s, image);
            const crossings_start = crossing_pairs.items.len;
            for (borders.items) |border| {
                if (border.feature == k or (features[border.feature].source == f.source and f.own == true)) continue;
                try crossing_pairs.append(s, .{ .first = image, .second = border.image });
            }
            const pierce_start = pierce_pairs.items.len;
            for (self.model.shapes, 0..) |shape, owner| {
                if (shape.faces == 0 or owner == f.source or @as(isize, @intCast(owner)) == f.other) continue;
                try pierce_pairs.append(s, .{ .first = f.curve, .second = owner });
            }
            try traced.append(s, .{ .feature = k, .image = image, .crossings = .{ crossings_start, crossing_pairs.items.len }, .piercings = .{ pierce_start, pierce_pairs.items.len } });
        }
        const crossed = try self.view.crossings(crossing_pairs.items);
        const pierced = try self.view.pierce(pierce_pairs.items);
        {
            const images = try s.alloc(usize, traced.items.len);
            const curves = try s.alloc(usize, traced.items.len);
            for (traced.items, images, curves) |t, *image, *curve| {
                image.* = t.image;
                curve.* = features[t.feature].curve;
            }
            const spans = try s.alloc(c.HuakRange, traced.items.len);
            try self.view.ranges(images, spans);
            const info = try s.alloc(c.HuakCurveInfo, traced.items.len);
            try self.view.curveInfo(curves, info);
            for (traced.items, spans, info) |*t, span, facts| {
                t.span = span;
                t.line = facts.line != 0;
                t.tolerance = facts.tolerance;
            }
        }

        // Each curve's pieces between its sorted cuts, sampled at their middles.
        const Interval = struct { traced: usize, low: f64, high: f64 };
        var intervals: std.ArrayList(Interval) = .empty;
        var middles: std.ArrayList(c.HuakCurvePoint) = .empty;
        for (traced.items, 0..) |*t, index| {
            var cuts: std.ArrayList(f64) = .empty;
            try cuts.appendSlice(s, &.{ t.span.first, t.span.last });
            for (t.crossings[0]..t.crossings[1]) |pair| try cuts.appendSlice(s, crossed.row(pair));
            for (t.piercings[0]..t.piercings[1]) |pair| try cuts.appendSlice(s, pierced.row(pair));
            std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
            t.intervals[0] = intervals.items.len;
            for (cuts.items[0 .. cuts.items.len - 1], cuts.items[1..]) |a, b| {
                const low = @max(t.span.first, a);
                const high = @min(t.span.last, b);
                if (high - low <= parametric) continue;
                try intervals.append(s, .{ .traced = index, .low = low, .high = high });
                try middles.append(s, .{ .curve = features[t.feature].curve, .parameter = (low + high) * 0.5, .on_surface = @intFromBool(features[t.feature].kind == .curve) });
            }
            t.intervals[1] = intervals.items.len;
        }
        const points = try s.alloc(c.HuakXYZ, middles.items.len);
        try self.view.curvePoints(middles.items, points);
        const seen = try s.alloc(c.HuakLook, points.len);
        try self.view.look(points, seen);
        const screen = try s.alloc(c.HuakXY, seen.len);
        for (screen, seen) |*p, look| p.* = .{ .x = look.x, .y = look.y };
        const hits = try self.view.rays(screen);
        const covering = try s.alloc(usize, intervals.items.len);
        for (covering, intervals.items, seen, 0..) |*sheets, interval, look, k| {
            const t = traced.items[interval.traced];
            sheets.* = self.sheetsInFront(features[t.feature], t.tolerance, look.depth, try sortedHits(s, hits.row(k)));
        }

        // The pieces to write, in order: whole images, runs of one rank along
        // a curve, and straight runs written from their ends.
        const Write = struct { feature: usize, covering: usize, what: union(enum) { piece: usize, segment: usize } };
        var writes: std.ArrayList(Write) = .empty;
        var pieces: std.ArrayList(c.HuakPiece) = .empty;
        var segment_images: std.ArrayList(usize) = .empty;
        var segment_parameters: std.ArrayList(f64) = .empty;
        var next_traced: usize = 0;
        for (features, plans, own_images, 0..) |_, plan, own_image, k| switch (plan) {
            .skip => {},
            .whole => |rank| {
                try pieces.append(s, .{ .image = own_image.?, .whole = 1, .first = 0, .last = 0 });
                try writes.append(s, .{ .feature = k, .covering = rank, .what = .{ .piece = pieces.items.len - 1 } });
            },
            .split => {
                if (next_traced >= traced.items.len or traced.items[next_traced].feature != k) continue;
                const t = traced.items[next_traced];
                next_traced += 1;
                const runs = intervals.items[t.intervals[0]..t.intervals[1]];
                if (runs.len == 0) continue;
                var run = t.span.first;
                var previous = covering[t.intervals[0]];
                for (runs[1..], covering[t.intervals[0] + 1 .. t.intervals[1]]) |interval, rank| {
                    if (rank == previous) continue;
                    try self.planRun(&writes, &pieces, &segment_images, &segment_parameters, k, t, run, interval.low, previous);
                    run = interval.low;
                    previous = rank;
                }
                try self.planRun(&writes, &pieces, &segment_images, &segment_parameters, k, t, run, t.span.last, previous);
            },
        };
        const approximated = try self.view.approximate(pieces.items, self.tolerance);
        const ends = try s.alloc(c.HuakXY, segment_parameters.items.len);
        try self.view.imagePoints(segment_images.items, segment_parameters.items, ends);
        for (writes.items) |w| {
            const f = features[w.feature];
            const start = self.out.commands.items.len;
            switch (w.what) {
                .piece => |piece| try self.out.commands.appendSlice(self.allocator, approximated.row(piece)),
                .segment => |segment| {
                    const p = ends[2 * segment];
                    const q = ends[2 * segment + 1];
                    const dx = q.x - p.x;
                    const dy = q.y - p.y;
                    if (@sqrt(dx * dx + dy * dy) <= confusion) continue;
                    try self.out.commands.appendSlice(self.allocator, &.{ command(c.HUAK_MOVE, p), command(c.HUAK_LINE, q) });
                },
            }
            try self.out.lines.append(self.allocator, .{ .source = f.source, .start = start, .count = self.out.commands.items.len - start, .covering = w.covering, .kind = f.kind, .other = f.other });
        }
        return .{ .images = boundaries.items, .contours = contours.items };
    }

    const Traced = struct {
        feature: usize,
        image: usize,
        crossings: [2]usize,
        piercings: [2]usize,
        span: c.HuakRange = undefined,
        line: bool = false,
        tolerance: f64 = 0,
        intervals: [2]usize = undefined,
    };

    fn planRun(self: *Work, writes: anytype, pieces: *std.ArrayList(c.HuakPiece), images: *std.ArrayList(usize), parameters: *std.ArrayList(f64), feature: usize, t: Traced, from: f64, to: f64, sheets: usize) !void {
        const s = self.scratch;
        if (t.line) {
            try images.appendSlice(s, &.{ t.image, t.image });
            try parameters.appendSlice(s, &.{ from, to });
            try writes.append(s, .{ .feature = feature, .covering = sheets, .what = .{ .segment = images.items.len / 2 - 1 } });
        } else {
            try pieces.append(s, .{ .image = t.image, .whole = 0, .first = from, .last = to });
            try writes.append(s, .{ .feature = feature, .covering = sheets, .what = .{ .piece = pieces.items.len - 1 } });
        }
    }

    /// The sheets in front of a curve's point at `depth`. A curve drawn on a
    /// shape is not covered by its own sheets where hidden-line removal
    /// already ranked it, ties go to the earlier shape, and an intersection
    /// curve allows its own edge tolerance against the shapes it joins.
    fn sheetsInFront(self: *const Work, f: Feature, tolerance: f64, depth: f64, hits: []const Hit) usize {
        var count: usize = 0;
        for (hits) |hit| {
            if (f.own == true and hit.source == f.source) continue;
            const delta = hit.depth - depth;
            const tied = f.own != null and hit.source < f.source and @abs(delta) <= confusion;
            const joined = f.kind == .intersection and (hit.source == f.source or @as(isize, @intCast(hit.source)) == f.other);
            if (delta > (if (joined) tolerance else confusion) or tied) {
                count += 1;
                if (!self.layered) break;
            }
        }
        return count;
    }

    /// Divides the plane by the outlines, intersections and face boundaries,
    /// then groups the cells by the face each sheet in front shows. With band
    /// light, lighting contours divide the occupied cells further.
    fn divideFaces(self: *Work, boundaries: Boundaries, light: ?Light) Model.Error!void {
        const s = self.scratch;
        const smooth = if (light) |l| l.smooth else false;
        var tools: std.ArrayList(usize) = .empty;
        try tools.appendSlice(s, boundaries.images);
        // Face boundaries divide too, except seams where a face meets itself.
        {
            var curves: std.ArrayList(usize) = .empty;
            for (self.model.shapes, 0..) |shape, source| {
                if (shape.faces == 0) continue;
                for (try self.view.edges(source)) |edge| {
                    if (edge.faces == 0 or (edge.faces == 1 and edge.closed != 0)) continue;
                    try curves.append(s, edge.curve);
                }
            }
            const images = try s.alloc(?usize, curves.items.len);
            try self.view.project(curves.items, false, self.tolerance, images);
            for (images) |image| if (image) |i| try tools.append(s, i);
        }
        if (tools.items.len == 0) return;
        const box = try self.view.bounds(tools.items) orelse return;
        const margin = @max(box.max.x - box.min.x, box.max.y - box.min.y, 1.0);
        const rectangle: g.BBox = .{ .min = .{ .x = box.min.x - margin, .y = box.min.y - margin }, .max = .{ .x = box.max.x + margin, .y = box.max.y + margin } };
        var cells = try self.view.partition(rectangle, &.{}, tools.items, if (smooth) boundaries.contours else &.{});

        var lighting: ?Lighting = null;
        if (light) |l| if (!l.smooth) {
            lighting = try Lighting.init(self, l);
            const contours = try lighting.?.contours(self, l);
            if (contours.len > 0) {
                // Lighting contours divide only occupied cells: they are already
                // mutually split, and the empty background needs no light.
                const centers = try s.alloc(c.HuakXY, cells.len);
                try self.view.interiors(cells, centers);
                const found = try self.view.rays(centers);
                var occupied: std.ArrayList(usize) = .empty;
                for (cells, 0..) |cell, k| if (found.row(k).len > 0) try occupied.append(s, cell);
                if (occupied.items.len == 0) return;
                cells = try self.view.partition(null, occupied.items, contours, &.{});
            }
        };

        // Each cell joins a group for each sheet in front of it.
        const centers = try s.alloc(c.HuakXY, cells.len);
        try self.view.interiors(cells, centers);
        const found = try self.view.rays(centers);
        const sorted = try s.alloc([]const Hit, cells.len);
        for (sorted, 0..) |*list, k| list.* = try sortedHits(s, found.row(k));
        const normal_list = if (lighting != null) try self.normals(sorted) else &.{};
        var groups: std.AutoArrayHashMapUnmanaged(Key, Group) = .empty;
        var normal_index: usize = 0;
        for (cells, sorted) |cell, list| for (list, 0..) |hit, covering| {
            const entry = try groups.getOrPut(s, .{ .covering = covering, .source = hit.source, .face = hit.face });
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const group = entry.value_ptr;
            try group.body.append(s, cell);
            if (lighting) |*l| {
                const normal = normal_list[normal_index] orelse return self.model.failWith("undefined surface normal at lighting sample");
                normal_index += 1;
                const shade = try l.classify(s, normal, hit, cell);
                try group.shade(s, shade.diffuse, cell);
                if (shade.gleam) try group.spot.append(s, cell);
            }
        };
        if (lighting) |*l| try l.fitSpots(self);
        try self.write(&groups, if (lighting) |*l| l else null, smooth);
    }

    /// The face normal at every hit, in cell and hit order, one batch per face.
    fn normals(self: *Work, sorted: []const []const Hit) Model.Error![]?[3]f64 {
        const s = self.scratch;
        var total: usize = 0;
        for (sorted) |list| total += list.len;
        const result = try s.alloc(?[3]f64, total);
        var by_face: std.AutoArrayHashMapUnmanaged([2]usize, std.ArrayList(usize)) = .empty;
        var index: usize = 0;
        for (sorted) |list| for (list) |hit| {
            const entry = try by_face.getOrPut(s, .{ hit.source, hit.face });
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(s, index);
            index += 1;
        };
        const flat = try s.alloc(Hit, total);
        index = 0;
        for (sorted) |list| for (list) |hit| {
            flat[index] = hit;
            index += 1;
        };
        var surfaces = self.view.surfaces();
        for (by_face.keys(), by_face.values()) |key, owners| {
            const uv = try s.alloc(g.Point, owners.items.len);
            for (uv, owners.items) |*at, owner| at.* = .{ .x = flat[owner].uv.u, .y = flat[owner].uv.v };
            const seen = try s.alloc(shading.Look, uv.len);
            surfaces.look(s, .{ .source = key[0], .index = key[1] }, uv, seen) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.SurfaceQueryFailed => error.ProjectionFailed,
            };
            for (owners.items, seen) |owner, look| result[owner] = look.normal;
        }
        return result;
    }

    /// Writes each group's regions: in smooth light one record per region, so
    /// each can carry the field of its sheet; otherwise one record per group
    /// with its highlight and bands.
    fn write(self: *Work, groups: *std.AutoArrayHashMapUnmanaged(Key, Group), lighting: ?*Lighting, smooth: bool) Model.Error!void {
        const s = self.scratch;
        const keys = groups.keys();
        const order = try s.alloc(usize, keys.len);
        for (order, 0..) |*k, i| k.* = i;
        std.mem.sort(usize, order, keys, struct {
            fn less(all: []const Key, a: usize, b: usize) bool {
                const x = all[a];
                const y = all[b];
                if (x.covering != y.covering) return x.covering < y.covering;
                if (x.source != y.source) return x.source < y.source;
                return x.face < y.face;
            }
        }.less);
        // The sets of cells to merge, in the order they are written.
        var offsets: std.ArrayList(usize) = .empty;
        var cells: std.ArrayList(usize) = .empty;
        var keep: std.ArrayList(?usize) = .empty;
        try offsets.append(s, 0);
        const Sets = struct { body: usize, spot: ?usize = null, shades: [2]usize = .{ 0, 0 } };
        const sets = try s.alloc(Sets, keys.len);
        for (order, sets) |k, *set| {
            const key = keys[k];
            const group = &groups.values()[k];
            set.body = keep.items.len;
            try addSet(s, &offsets, &cells, &keep, group.body.items, if (smooth) key.source else null);
            if (smooth) continue;
            const paint = if (lighting) |l| l.faces[key.source][key.face] else FaceLight{};
            if (!(paint.planar and group.spot.items.len > 0) and group.spot.items.len > 0) {
                set.spot = keep.items.len;
                try addSet(s, &offsets, &cells, &keep, group.spot.items, null);
            }
            std.mem.sort(ShadeCells, group.shades.items, {}, struct {
                fn less(_: void, a: ShadeCells, b: ShadeCells) bool {
                    return a.diffuse < b.diffuse;
                }
            }.less);
            set.shades[0] = keep.items.len;
            if (group.shades.items.len > 1) for (group.shades.items) |shade| try addSet(s, &offsets, &cells, &keep, shade.cells.items, null);
            set.shades[1] = keep.items.len;
        }
        const merged = try self.view.merge(offsets.items, cells.items, keep.items);
        const outlines = try self.view.outlines(merged.values, self.tolerance);
        var region_bounds: []?g.BBox = &.{};
        if (smooth) {
            region_bounds = try s.alloc(?g.BBox, merged.values.len);
            try self.view.regionBounds(merged.values, region_bounds);
        }
        const a = self.allocator;
        const out = self.out;
        for (order, sets) |k, set| {
            const key = keys[k];
            const group = &groups.values()[k];
            if (smooth) {
                for (merged.offsets[set.body]..merged.offsets[set.body + 1]) |region| {
                    const start = out.commands.items.len;
                    try out.commands.appendSlice(a, outlines.row(region));
                    try out.faces.append(a, .{ .source = key.source, .face = key.face, .start = start, .count = out.commands.items.len - start, .covering = key.covering, .spot_start = start, .spot_count = 0, .lobe_start = 0, .lobe_count = 0, .shade_start = out.shades.items.len, .shade_count = 0 });
                    try out.bounds.append(a, region_bounds[region]);
                }
                continue;
            }
            const start = out.commands.items.len;
            try self.writeSet(merged, outlines, set.body);
            const end = out.commands.items.len;
            const paint = if (lighting) |l| l.faces[key.source][key.face] else FaceLight{};
            // A plane has one normal, so a gleam covers its entire visible region.
            const full_spot = paint.planar and group.spot.items.len > 0;
            if (set.spot) |spot| try self.writeSet(merged, outlines, spot);
            const spot_start = if (full_spot) start else end;
            const spot_count = out.commands.items.len - spot_start;
            const shade_start = out.shades.items.len;
            if (group.shades.items.len == 1) {
                try out.shades.append(a, .{ .start = start, .count = end - start, .diffuse = group.shades.items[0].diffuse });
            } else for (group.shades.items, set.shades[0]..set.shades[1]) |shade, index| {
                const first = out.commands.items.len;
                try self.writeSet(merged, outlines, index);
                try out.shades.append(a, .{ .start = first, .count = out.commands.items.len - first, .diffuse = shade.diffuse });
            }
            try out.faces.append(a, .{ .source = key.source, .face = key.face, .start = start, .count = end - start, .covering = key.covering, .spot_start = spot_start, .spot_count = spot_count, .lobe_start = paint.start, .lobe_count = paint.count, .shade_start = shade_start, .shade_count = out.shades.items.len - shade_start });
            try out.bounds.append(a, null);
        }
    }

    fn writeSet(self: *Work, merged: Model.Rows(usize), outlines: Model.Rows(c.HuakPathCommand), set: usize) !void {
        for (merged.offsets[set]..merged.offsets[set + 1]) |region| try self.out.commands.appendSlice(self.allocator, outlines.row(region));
    }
};

fn addSet(s: std.mem.Allocator, offsets: *std.ArrayList(usize), cells: *std.ArrayList(usize), keep: *std.ArrayList(?usize), members: []const usize, source: ?usize) !void {
    try cells.appendSlice(s, members);
    try offsets.append(s, cells.items.len);
    try keep.append(s, source);
}

fn command(op: c_int, p: c.HuakXY) c.HuakPathCommand {
    var result = std.mem.zeroes(c.HuakPathCommand);
    result.op = op;
    result.p[0] = p;
    return result;
}

/// Whether two boxes with their tolerances are apart; a shape without
/// geometry meets nothing.
fn apart(a: ?[2][3]f64, b: ?[2][3]f64) bool {
    const x = a orelse return true;
    const y = b orelse return true;
    for (0..3) |k| if (x[0][k] > y[1][k] or y[0][k] > x[1][k]) return true;
    return false;
}

/// The hits along a line of sight from the front. A line on the common edge
/// of two faces of one shape meets both: within OCCT's confusion only the
/// first face of each shape counts, and separate shapes at the same depth
/// stay distinct sheets, in input order.
fn sortedHits(s: std.mem.Allocator, found: []const c.HuakShapeHit) ![]const Hit {
    const hits = try s.alloc(Hit, found.len);
    for (hits, found) |*hit, f| hit.* = .{ .source = f.source, .face = f.face, .depth = f.depth, .uv = .{ .u = f.u, .v = f.v } };
    std.mem.sort(Hit, hits, {}, struct {
        fn nearer(_: void, a: Hit, b: Hit) bool {
            return a.depth > b.depth;
        }
    }.nearer);
    var kept: usize = 0;
    var first: usize = 0;
    while (first < hits.len) {
        var end = first + 1;
        while (end < hits.len and hits[first].depth - hits[end].depth <= confusion) end += 1;
        std.mem.sort(Hit, hits[first..end], {}, struct {
            fn earlier(_: void, a: Hit, b: Hit) bool {
                return if (a.source != b.source) a.source < b.source else a.face < b.face;
            }
        }.earlier);
        for (first..end) |k| if (k == first or hits[k].source != hits[kept - 1].source) {
            hits[kept] = hits[k];
            kept += 1;
        };
        first = end;
    }
    return hits[0..kept];
}

const Key = struct { covering: usize, source: usize, face: usize };
const ShadeCells = struct { diffuse: f64, cells: std.ArrayList(usize) = .empty };
const Group = struct {
    body: std.ArrayList(usize) = .empty,
    spot: std.ArrayList(usize) = .empty,
    shades: std.ArrayList(ShadeCells) = .empty,

    fn shade(self: *Group, s: std.mem.Allocator, diffuse: f64, cell: usize) !void {
        for (self.shades.items) |*existing| if (existing.diffuse == diffuse) return existing.cells.append(s, cell);
        try self.shades.append(s, .{ .diffuse = diffuse });
        try self.shades.items[self.shades.items.len - 1].cells.append(s, cell);
    }
};

/// A face's band lighting: whether it is planar, its lit cells, and the
/// ellipses fitted to them.
const FaceLight = struct {
    planar: bool = false,
    lit: std.ArrayList(usize) = .empty,
    start: usize = 0,
    count: usize = 0,
};

const Lighting = struct {
    sun: [3]f64,
    eye: [3]f64,
    half: ?[3]f64,
    /// The sum of the unit vectors toward the light and the viewer, which OCCT
    /// normalizes for the highlight's contour.
    bisector: [3]f64,
    cutoff: f64,
    isophotes: []const f64,
    faces: [][]FaceLight,

    fn init(work: *Work, light: Light) Model.Error!Lighting {
        const s = work.scratch;
        const d = light.direction;
        const length = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        const sun: [3]f64 = .{ d[0] / length, d[1] / length, d[2] / length };
        const eye = work.view.frame.eye;
        const bisector: [3]f64 = .{ sun[0] + eye[0], sun[1] + eye[1], sun[2] + eye[2] };
        const magnitude = @sqrt(bisector[0] * bisector[0] + bisector[1] * bisector[1] + bisector[2] * bisector[2]);
        const faces = try s.alloc([]FaceLight, work.model.shapes.len);
        for (faces, work.model.shapes, 0..) |*list, shape, source| {
            list.* = try s.alloc(FaceLight, shape.faces);
            for (list.*, 0..) |*paint, index| paint.* = .{ .planar = (try work.model.face(source, index)).kind == .planar };
        }
        return .{
            .sun = sun,
            .eye = eye,
            .half = if (light.spot > 0 and magnitude > angular) .{ bisector[0] / magnitude, bisector[1] / magnitude, bisector[2] / magnitude } else null,
            .bisector = bisector,
            .cutoff = @cos(light.spot),
            .isophotes = light.isophotes,
            .faces = faces,
        };
    }

    /// The images of the isophotes and of the highlight's boundary on every
    /// curved face.
    fn contours(self: *const Lighting, work: *Work, light: Light) Model.Error![]const usize {
        var images: std.ArrayList(usize) = .empty;
        for (self.faces, 0..) |list, source| for (list, 0..) |paint, face| {
            if (paint.planar) continue;
            for (self.isophotes) |level| try images.appendSlice(work.scratch, try work.view.contours(source, face, light.direction, std.math.acos(level), work.tolerance));
            if (self.half != null) try images.appendSlice(work.scratch, try work.view.contours(source, face, self.bisector, light.spot, work.tolerance));
        };
        return images.items;
    }

    const Sample = struct { diffuse: f64, gleam: bool };

    /// The band of n·l at a hit, and whether it lies in the highlight; a
    /// plane keeps its exact light.
    fn classify(self: *Lighting, s: std.mem.Allocator, normal: [3]f64, hit: Hit, cell: usize) !Sample {
        const paint = &self.faces[hit.source][hit.face];
        const facing = dot(normal, self.sun);
        const gleam = if (self.half) |half| facing > 0 and dot(normal, self.eye) > 0 and dot(normal, half) >= self.cutoff else false;
        if (gleam and !paint.planar and std.mem.indexOfScalar(usize, paint.lit.items, cell) == null) try paint.lit.append(s, cell);
        if (paint.planar or facing <= 0) return .{ .diffuse = if (0 < facing) facing else 0, .gleam = gleam };
        var next: usize = 0;
        while (next < self.isophotes.len and !(facing < self.isophotes[next])) next += 1;
        const low = self.isophotes[next - 1];
        const high = if (next == self.isophotes.len) 1 else self.isophotes[next];
        return .{ .diffuse = (low + high) / 2, .gleam = gleam };
    }

    /// One elliptical falloff for each connected highlight before occlusion:
    /// an ellipse's second moments give its semiaxes and direction.
    fn fitSpots(self: *Lighting, work: *Work) Model.Error!void {
        const s = work.scratch;
        var offsets: std.ArrayList(usize) = .empty;
        var cells: std.ArrayList(usize) = .empty;
        var keep: std.ArrayList(?usize) = .empty;
        var owners: std.ArrayList(*FaceLight) = .empty;
        try offsets.append(s, 0);
        for (self.faces) |list| for (list) |*paint| {
            if (paint.lit.items.len == 0) continue;
            try addSet(s, &offsets, &cells, &keep, paint.lit.items, null);
            try owners.append(s, paint);
        };
        if (owners.items.len == 0) return;
        const merged = try work.view.merge(offsets.items, cells.items, keep.items);
        const found = try s.alloc(c.HuakMoments, merged.values.len);
        try work.view.moments(merged.values, found);
        for (owners.items, 0..) |paint, set| {
            paint.start = work.out.lobes.items.len;
            for (found[merged.offsets[set]..merged.offsets[set + 1]]) |m| {
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
};

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// The smooth light field of each front region, from the consecutive records
/// of one face's regions at a time; other records get none.
pub fn smoothFields(work: *const Linework, lighting: *shading.Shading, out: *shading.Output, fields: []shading.Field) shading.Error!void {
    std.debug.assert(fields.len == work.faces.items.len);
    @memset(fields, .none);
    const records = work.faces.items;
    const inf = std.math.inf(f64);
    var start: usize = 0;
    while (start < records.len) {
        const first = records[start];
        var end = start + 1;
        while (end < records.len and records[end].covering == first.covering and records[end].source == first.source and records[end].face == first.face) end += 1;
        if (first.covering == 0) {
            // A region without geometry bounds nothing.
            const bounds = try lighting.allocator.alloc(g.BBox, end - start);
            defer lighting.allocator.free(bounds);
            for (work.bounds.items[start..end], bounds) |found, *box| box.* = found orelse .{ .min = .{ .x = inf, .y = inf }, .max = .{ .x = -inf, .y = -inf } };
            try lighting.fields(out, .{ .source = first.source, .index = first.face }, bounds, fields[start..end]);
        }
        start = end;
    }
}
