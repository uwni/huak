//! Continuous light for vector shading: the field d = n·l of a sheet and its
//! glint g = (n·h - c) / (1 - c), within an accuracy e at points farther than
//! the outline tolerance from a region's outline (the outline itself is only
//! that accurate).
//!
//! - A plane's light is constant. A cylinder seen across its axis shades along
//!   one direction in the plane: a profile of samples, linear between them,
//!   graded toward the contour where the projection folds (see `profile`).
//! - Other faces get tensor-product Bézier patches over a grid of their
//!   parameters. A patch interpolates the projected surface and the field at
//!   sixteen samples; PDF interpolates its corner values bilinearly in the
//!   parameters, and other outputs approximate its cubic field. The normal
//!   turns at most h across a cell, and bilinear interpolation of a function
//!   of that angle whose second derivative is at most 1 errs by at most
//!   h^2 / 4, so cells turn by h = sqrt(4 e). The glint turns 1 / (1 - c)
//!   times faster: where it can be positive, finer patches turning by
//!   sqrt(4 e (1 - c)) carry it. Interpolating in the parameters, patches
//!   need no refinement where the projection folds at the contour.
//! - A cell crossing the contour n·v = 0 splits along a diagonal, and each
//!   half keeps its front part, cut where n·v vanishes on its edges, as a
//!   patch with straight sides in the parameters. Patches sharing a side share
//!   its samples and so its control points; skirts carry the light of contour
//!   and face-boundary sides past the outline's tolerance and past the chords
//!   an output may draw for them.
//!
//! Normal rates per parameter are exact for cylinders, cones, spheres and
//! tori. Other surfaces use the largest derivative of the normal on a 33 x 33
//! grid, which estimates the rate but does not bound it.
//!
//! OCCT answers every geometric question through `Surfaces`, in batches: a
//! sheet requests the samples one step of its construction needs and has them
//! evaluated together before the next step reads them.
const std = @import("std");
const g = @import("../geometry.zig");

pub const Vec3 = [3]f64;

fn dot(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// A face of a projected model: its root shape and its index among that
/// shape's faces.
pub const Face = struct { source: usize, index: usize };

pub const Kind = enum { planar, cylindrical, conical, spherical, toroidal, freeform };

pub const Info = struct {
    kind: Kind,
    /// The face's parameter bounds.
    u: [2]f64,
    v: [2]f64,
    /// Zero unless the surface is periodic in the parameter.
    u_period: f64 = 0,
    v_period: f64 = 0,
    /// Cones.
    semi_angle: f64 = 0,
    /// Cylinders: u is the angle from axis_x toward axis_y.
    axis_x: Vec3 = .{ 0, 0, 0 },
    axis_y: Vec3 = .{ 0, 0, 0 },
};

/// A face's point as the camera sees it: its screen position and depth
/// toward the viewer, and the face's unit normal there as oriented in its
/// shape; null where the normal is undefined, as at a cone's apex.
pub const Look = struct { x: f64, y: f64, depth: f64, normal: ?Vec3 };

/// The derivatives along u and v of a face's unit normal.
pub const Turn = struct { du: Vec3, dv: Vec3 };

/// Where a line of sight meets a face: the depth and the face's parameters.
pub const Sighting = struct { depth: f64, uv: g.Point };

/// The geometry of a projected model's faces, from OCCT, in batches.
pub const Surfaces = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const QueryError = error{ SurfaceQueryFailed, OutOfMemory };
    pub const VTable = struct {
        info: *const fn (ptr: *anyopaque, face: Face) QueryError!Info,
        look: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, face: Face, uv: []const g.Point, out: []Look) QueryError!void,
        turns: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, face: Face, uv: []const g.Point, out: []?Turn) QueryError!void,
        roots: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, face: Face, segments: []const [2]g.Point, direction: Vec3, value: f64, tolerance: f64, out: []?f64) QueryError!void,
        sightings: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, face: Face, points: []const g.Point, offsets: []usize, out: *std.ArrayList(Sighting)) QueryError!void,
    };

    pub fn info(self: Surfaces, face: Face) QueryError!Info {
        return self.vtable.info(self.ptr, face);
    }
    /// The face at each parameter point as the camera sees it. `allocator`
    /// serves any scratch the query needs, here and below.
    pub fn look(self: Surfaces, allocator: std.mem.Allocator, face: Face, uv: []const g.Point, out: []Look) QueryError!void {
        std.debug.assert(uv.len == out.len);
        if (uv.len == 0) return;
        return self.vtable.look(self.ptr, allocator, face, uv, out);
    }
    /// The derivatives of the face's unit normal; null where the surface is
    /// singular.
    pub fn turns(self: Surfaces, allocator: std.mem.Allocator, face: Face, uv: []const g.Point, out: []?Turn) QueryError!void {
        std.debug.assert(uv.len == out.len);
        if (uv.len == 0) return;
        return self.vtable.turns(self.ptr, allocator, face, uv, out);
    }
    /// For each segment of the face's parameters, the fraction of the way
    /// along it where the face's normal n gives n·direction = value, to within
    /// `tolerance`; null where its ends give no change of sign or the normal
    /// is undefined on the way.
    pub fn roots(self: Surfaces, allocator: std.mem.Allocator, face: Face, segments: []const [2]g.Point, direction: Vec3, value: f64, tolerance: f64, out: []?f64) QueryError!void {
        std.debug.assert(segments.len == out.len);
        if (segments.len == 0) return;
        return self.vtable.roots(self.ptr, allocator, face, segments, direction, value, tolerance, out);
    }
    /// Appends where the lines of sight through screen points meet the face
    /// to `out`, which grows in `allocator`: those of point k at
    /// offsets[k]..offsets[k + 1], counted from the list's length at the
    /// call. `offsets` holds one more than `points`.
    pub fn sightings(self: Surfaces, allocator: std.mem.Allocator, face: Face, points: []const g.Point, offsets: []usize, out: *std.ArrayList(Sighting)) QueryError!void {
        std.debug.assert(offsets.len == points.len + 1);
        return self.vtable.sightings(self.ptr, allocator, face, points, offsets, out);
    }
};

pub const Light = struct {
    /// Unit vector toward the light.
    sun: Vec3,
    /// The highlight's angle around the half vector; zero for none.
    spot: f64 = 0,
    /// The largest error interpolated light may have.
    accuracy: f64,
};

/// Light at one point: n·l, unclamped, and the glint (n·h - cos spot) /
/// (1 - cos spot), 1 at the center of the highlight and positive inside it,
/// or -1 where the point is unlit or there is no highlight.
pub const Shine = struct { diffuse: f64, glint: f64 };
pub const Sample = struct {
    /// The fraction of the way from start to end.
    position: f64,
    shine: Shine,
};
/// A tensor-product Bézier patch carrying a field: over (u, v) in the unit
/// square, the sums of points[i * 4 + j] and values[i * 4 + j] times
/// B_i(u) B_j(v), with B the cubic Bernstein polynomials.
pub const Patch = struct { points: [16]g.Point, values: [16]f64 };
pub const Range = struct { start: usize, count: usize };

/// A constant field; a profile varying only along start -> end, linear
/// between samples in increasing position; or patches of n·l, and finer
/// patches of the glint where the highlight can reach. A patch's corner
/// values, interpolated bilinearly, stay within the accuracy of the light;
/// its cubic field interpolates samples of the light and is closer still.
/// Later patches paint over earlier ones; together they extend past the
/// region they shade. Ranges index the `Output`.
pub const Field = union(enum) {
    none,
    constant: Shine,
    profile: struct { start: g.Point, end: g.Point, samples: Range },
    patches: struct { diffuse: Range, glint: Range },
};

pub const Output = struct {
    samples: std.ArrayList(Sample) = .empty,
    patches: std.ArrayList(Patch) = .empty,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.patches.deinit(allocator);
        self.* = undefined;
    }
};

pub const Error = Surfaces.QueryError || error{ ShadingLimit, UndefinedNormal };

/// Patches per projection; more report ShadingLimit instead of exhausting
/// memory.
pub const max_patches: usize = 250_000;
/// OCCT's angular precision, below which the half vector is undefined.
const angular_precision = 1e-12;
/// The most steps one division of a profile or cell may take.
const max_steps: f64 = std.math.maxInt(i32);
/// How closely a contour cut is placed, as a fraction of its side.
const root_tolerance = 1e-12;

/// One projection's light and view. Fields of its faces draw from one patch
/// budget.
pub const Shading = struct {
    allocator: std.mem.Allocator,
    surfaces: Surfaces,
    /// Toward the viewer, as OCCT's camera has it.
    eye: Vec3,
    sun: Vec3,
    half: ?Vec3,
    cutoff: f64,
    accuracy: f64,
    tolerance: f64,
    /// Largest normal turn between neighbouring profile samples away from the
    /// contour, and the facing levels n·v where profile strips near it end.
    step: f64,
    facing: []f64,
    /// Patches the projection may still produce.
    budget: usize = max_patches,

    /// `tolerance` is the outline's: skirts reach past it.
    pub fn init(allocator: std.mem.Allocator, surfaces: Surfaces, light: Light, eye: Vec3, tolerance: f64) error{OutOfMemory}!Shading {
        const bisector: Vec3 = .{ light.sun[0] + eye[0], light.sun[1] + eye[1], light.sun[2] + eye[2] };
        const length = @sqrt(dot(bisector, bisector));
        const half: ?Vec3 = if (light.spot > 0 and length > angular_precision) .{ bisector[0] / length, bisector[1] / length, bisector[2] / length } else null;
        const step = @sqrt(8 * light.accuracy);
        var facing: std.ArrayList(f64) = .empty;
        errdefer facing.deinit(allocator);
        try facing.append(allocator, 0);
        var turn = 4 * light.accuracy;
        while (turn < step) : (turn += @sqrt(8 * light.accuracy * turn)) try facing.append(allocator, @sin(turn));
        return .{
            .allocator = allocator,
            .surfaces = surfaces,
            .eye = eye,
            .sun = light.sun,
            .half = half,
            .cutoff = @cos(light.spot),
            .accuracy = light.accuracy,
            .tolerance = tolerance,
            .step = step,
            .facing = try facing.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Shading) void {
        self.allocator.free(self.facing);
        self.* = undefined;
    }

    fn glint(self: *const Shading, normal: Vec3) f64 {
        const half = self.half orelse return -1;
        return (dot(normal, half) - self.cutoff) / (1 - self.cutoff);
    }

    fn shine(self: *const Shading, normal: Vec3) Shine {
        const diffuse = dot(normal, self.sun);
        return .{ .diffuse = diffuse, .glint = if (diffuse > 0) self.glint(normal) else -1 };
    }

    /// The node at `uv`: its projection, depth and light. A singular node
    /// keeps its projection and depth only.
    fn node(self: *const Shading, uv: g.Point, seen: Look, place: u8) Node {
        var result: Node = .{ .uv = uv, .x = seen.x, .y = seen.y, .depth = seen.depth, .place = place };
        const normal = seen.normal orelse {
            result.singular = true;
            return result;
        };
        result.facing = dot(normal, self.eye);
        result.shine = self.shine(normal);
        result.raw = self.glint(normal);
        return result;
    }

    fn evaluate(self: *const Shading, scratch: std.mem.Allocator, face: Face, uv: []const g.Point, out: []Node) Error!void {
        const seen = try scratch.alloc(Look, uv.len);
        try self.surfaces.look(scratch, face, uv, seen);
        for (uv, seen, out) |at, point, *result| result.* = self.node(at, point, 0);
    }

    /// One field per region. `regions` bound the planar regions where `face`
    /// is the front surface; profile samples and patches go to `out`.
    pub fn fields(self: *Shading, out: *Output, face: Face, regions: []const g.BBox, result: []Field) Error!void {
        std.debug.assert(regions.len == result.len);
        @memset(result, .none);
        if (regions.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const info = try self.surfaces.info(face);
        switch (info.kind) {
            .planar => {
                var center: [1]Node = undefined;
                try self.evaluate(scratch, face, &.{.{ .x = (info.u[0] + info.u[1]) / 2, .y = (info.v[0] + info.v[1]) / 2 }}, &center);
                if (center[0].singular) return error.UndefinedNormal;
                @memset(result, .{ .constant = center[0].shine });
                return;
            },
            .cylindrical => if (try self.profile(scratch, out, face, info)) |field| {
                @memset(result, field);
                return;
            },
            else => {},
        }
        var sheet: Sheet = try .init(self, scratch, face, info);
        try sheet.build();
        // A face that can cover itself keeps the cells on its front sheet where
        // they are, judged at their centers.
        const covers = switch (info.kind) {
            .cylindrical, .conical, .spherical => false,
            else => true,
        };
        if (covers) try sheet.cull();
        // A region shows the front sheet, and a visible cell lies where its
        // sheet is in front, so the visible cells over a region's bounds cover
        // it. Their neighbours fill edges that are only partly covered. Skirts
        // go under all patches; a face that can cover itself paints far cells
        // first.
        const cells = sheet.cells;
        const member = try scratch.alloc(bool, cells.len);
        var primary: std.ArrayList(usize) = .empty;
        var members: std.ArrayList(usize) = .empty;
        for (regions, result) |box, *field| {
            @memset(member, false);
            primary.clearRetainingCapacity();
            for (cells, 0..) |cell, index| {
                const bounds = cell.bounds orelse continue;
                if (!cell.front or !cell.visible or !box.overlaps(bounds, 0)) continue;
                member[index] = true;
                try primary.append(scratch, index);
            }
            members.clearRetainingCapacity();
            try members.appendSlice(scratch, primary.items);
            for (primary.items) |index| {
                const i: i64 = @intCast(index % sheet.cu);
                const j: i64 = @intCast(index / sheet.cu);
                for ([3]i64{ -1, 0, 1 }) |dj| for ([3]i64{ -1, 0, 1 }) |di| {
                    const neighbour = sheet.cellAt(i + di, j + dj) orelse continue;
                    if (member[neighbour] or !cells[neighbour].front) continue;
                    member[neighbour] = true;
                    try members.append(scratch, neighbour);
                };
            }
            if (members.items.len == 0) continue;
            if (covers) {
                std.mem.sort(usize, members.items, cells, struct {
                    fn farther(all: []const Cell, a: usize, b: usize) bool {
                        return all[a].center.depth < all[b].center.depth;
                    }
                }.farther);
            } else std.mem.sort(usize, members.items, {}, std.sort.asc(usize));
            const diffuse = out.patches.items.len;
            for (primary.items) |index| try out.patches.appendSlice(self.allocator, cells[index].skirts.items);
            for (members.items) |index| try out.patches.appendSlice(self.allocator, cells[index].diffuse.items);
            const glints = out.patches.items.len;
            for (members.items) |index| try out.patches.appendSlice(self.allocator, cells[index].glint.items);
            const used = out.patches.items.len - diffuse;
            if (used > self.budget) return error.ShadingLimit;
            self.budget -= used;
            field.* = .{ .patches = .{
                .diffuse = .{ .start = diffuse, .count = glints - diffuse },
                .glint = .{ .start = glints, .count = out.patches.items.len - glints },
            } };
        }
    }

    /// A cylinder seen across its axis shades along one direction in the
    /// plane: each ruling projects to a line with constant light. Null where
    /// the axis points at the viewer or a sample has no normal.
    fn profile(self: *Shading, scratch: std.mem.Allocator, out: *Output, face: Face, info: Info) Error!?Field {
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
        if (std.math.hypot(sx, sy) > 1e-12) for ([2]f64{ std.math.pi / 2.0, -std.math.pi / 2.0 }) |turn| {
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

    /// The largest derivative of the unit normal along each parameter on a
    /// 33 x 33 grid: an estimate, not a bound.
    fn rates(self: *const Shading, scratch: std.mem.Allocator, face: Face, info: Info) Error![2]f64 {
        const probes = 32;
        const side = probes + 1;
        const uv = try scratch.alloc(g.Point, side * side);
        for (0..side) |j| for (0..side) |i| {
            uv[j * side + i] = .{
                .x = info.u[0] + (info.u[1] - info.u[0]) * @as(f64, @floatFromInt(i)) / probes,
                .y = info.v[0] + (info.v[1] - info.v[0]) * @as(f64, @floatFromInt(j)) / probes,
            };
        };
        const found = try scratch.alloc(?Turn, uv.len);
        try self.surfaces.turns(scratch, face, uv, found);
        var rate: [2]f64 = .{ 0, 0 };
        for (found) |turn| if (turn) |t| {
            rate[0] = @max(rate[0], @sqrt(dot(t.du, t.du)));
            rate[1] = @max(rate[1], @sqrt(dot(t.dv, t.dv)));
        };
        return rate;
    }
};

/// A sample of a face: its parameters, projection, depth and light.
const Node = struct {
    uv: g.Point,
    x: f64 = 0,
    y: f64 = 0,
    depth: f64 = 0,
    /// n·v, positive on the front sheet.
    facing: f64 = 0,
    shine: Shine = .{ .diffuse = 0, .glint = 0 },
    /// The glint before lighting gates it.
    raw: f64 = -1,
    /// On the contour or on a parameter bound of the face.
    place: u8 = 0,
    /// Without a normal: the facing comes from points nearby, and the light
    /// of a patch from a point toward its center.
    singular: bool = false,
};

/// Node places: the contour, and the four parameter bounds of a face that is
/// not periodic in that direction. Patch sides along one place get a skirt.
const on_contour: u8 = 1;
const on_bounds: u8 = 2 | 4 | 8 | 16;

/// Control indices of each side in increasing parameter, and the piece
/// corners at its ends: v = 0 (corners 0 -> 1), u = 1 (1 -> 2), v = 1
/// (3 -> 2) and u = 0 (0 -> 3).
const side_controls = [4][4]usize{ .{ 0, 4, 8, 12 }, .{ 12, 13, 14, 15 }, .{ 3, 7, 11, 15 }, .{ 0, 1, 2, 3 } };
const side_ends = [4][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 2 }, .{ 0, 3 } };

/// Bézier coefficients of the cubic through samples at 0, 1/3, 2/3 and 1.
/// The inner two use one expression in mirrored order, so a reversed side
/// gets exactly the reversed coefficients.
fn bezier(a: f64, b: f64, c: f64, d: f64) [4]f64 {
    return .{ a, inner(a, b, c, d), inner(d, c, b, a), d };
}

fn inner(p: f64, q: f64, r: f64, s: f64) f64 {
    return (-5 * p + 18 * q - 9 * r + 2 * s) / 6;
}

/// Tensor-product coefficients of samples at (i / 3, j / 3), index i * 4 + j.
/// Each side's coefficients depend on that side's samples alone.
fn coefficients(samples: [16]f64) [16]f64 {
    var rows: [16]f64 = undefined;
    for (0..4) |j| {
        const column = bezier(samples[j], samples[4 + j], samples[8 + j], samples[12 + j]);
        for (0..4) |i| rows[i * 4 + j] = column[i];
    }
    var result: [16]f64 = undefined;
    for (0..4) |i| {
        const row = bezier(rows[i * 4], rows[i * 4 + 1], rows[i * 4 + 2], rows[i * 4 + 3]);
        for (0..4) |j| result[i * 4 + j] = row[j];
    }
    return result;
}

/// A patch from side `side` of `patch` outward, away from the patch, carrying
/// the side's field unchanged across. It reaches past the outline's tolerance
/// and past the side's bulge from its chord, which an output may draw in its
/// place. Null for a side without length.
fn skirt(patch: Patch, side: usize, tolerance: f64) ?Patch {
    var e: [4]g.Point = undefined;
    for (&e, side_controls[side]) |*point, index| point.* = patch.points[index];
    const chord = e[3].sub(e[0]);
    const length = chord.norm();
    if (!(length > 0)) return null;
    const across: g.Point = .{ .x = -chord.y / length, .y = chord.x / length };
    var bulge: f64 = 0;
    for (e[1..3]) |point| bulge = @max(bulge, @abs(point.sub(e[0]).dot(across)));
    const width = 2 * tolerance + bulge;
    var center: g.Point = .zero;
    for ([_]usize{ 5, 6, 9, 10 }) |index| center = center.add(patch.points[index].scale(0.25));
    const outward: f64 = if (e[0].add(e[3]).scale(0.5).sub(center).dot(across) >= 0) 1 else -1;
    var result: Patch = undefined;
    for (0..4) |i| {
        var tangent = e[@min(i + 1, 3)].sub(e[i -| 1]);
        if (!(tangent.norm() > 1e-9 * length)) tangent = chord;
        const normal = (g.Point{ .x = -tangent.y, .y = tangent.x }).scale(outward / tangent.norm());
        // The first row is the side itself, bit for bit.
        result.points[i * 4] = patch.points[side_controls[side][i]];
        for (1..4) |j| result.points[i * 4 + j] = e[i].add(normal.scale(width * @as(f64, @floatFromInt(j)) / 3));
        for (0..4) |j| result.values[i * 4 + j] = patch.values[side_controls[side][i]];
    }
    return result;
}

/// A corner of a piece: a node, with its lattice point if it has one.
const Corner = struct {
    node: u32,
    i: i64 = 0,
    j: i64 = 0,
    lattice: bool = false,
};
/// A patch's corners at (0, 0), (1, 0), (1, 1) and (0, 1) in its own
/// parameters, joined by straight lines in the face's parameters. A triangle
/// repeats its last corner.
const Piece = [4]Corner;
/// A piece and the cell it belongs to.
const Placed = struct { cell: usize, piece: Piece };

const Cell = struct {
    diffuse: std.ArrayList(Patch) = .empty,
    glint: std.ArrayList(Patch) = .empty,
    skirts: std.ArrayList(Patch) = .empty,
    /// Of all the cell's patches.
    bounds: ?g.BBox = null,
    center: Node = .{ .uv = .zero },
    front: bool = false,
    visible: bool = true,

    fn add(cell: *Cell, allocator: std.mem.Allocator, list: *std.ArrayList(Patch), patch: Patch) !void {
        try list.append(allocator, patch);
        for (patch.points) |point| cell.bounds = if (cell.bounds) |bounds| bounds.include(point) else .fromPoint(point);
    }
};

/// The halves of a quad on either side of its diagonal from corner 0.
fn halves(quad: Piece) [2][3]Corner {
    return .{ .{ quad[0], quad[1], quad[2] }, .{ quad[0], quad[2], quad[3] } };
}

fn ordered(a: u32, b: u32) [2]u32 {
    return .{ @min(a, b), @max(a, b) };
}

/// The patches of one face over a grid of its parameters. Lattice points
/// subdivide each cell into n = 3 m steps per side: cells sample their
/// patches every m steps, and glint patches, m per cell side, every step.
/// Nodes are requested where a step of the construction needs them and
/// evaluated together before the next step reads them.
const Sheet = struct {
    shading: *const Shading,
    /// An arena that holds everything the sheet makes.
    allocator: std.mem.Allocator,
    face: Face,
    u: [2]f64,
    v: [2]f64,
    /// The period of a parameter around which the face closes, or zero.
    period: [2]f64,
    cu: usize,
    cv: usize,
    /// Normal turn across a cell, and lattice steps per cell side.
    turn: f64,
    m: i64,
    n: i64,
    nu: i64,
    nv: i64,
    nodes: std.ArrayList(Node) = .empty,
    /// Nodes from this index on await evaluation.
    pending: usize = 0,
    lattice: std.AutoHashMapUnmanaged([2]i64, u32) = .empty,
    /// The node where n·v vanishes on a side, and the nodes a third and two
    /// thirds of the way along a side, keyed by the side's ordered nodes.
    cuts: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
    thirds: std.AutoHashMapUnmanaged([2]u32, [2]u32) = .empty,
    /// Index j * cu + i.
    cells: []Cell,

    fn init(shading: *const Shading, allocator: std.mem.Allocator, face: Face, info: Info) Error!Sheet {
        const span: [2]f64 = .{ info.u[1] - info.u[0], info.v[1] - info.v[0] };
        // Normal turn per unit of each parameter.
        const rate: [2]f64 = switch (info.kind) {
            .cylindrical => .{ 1, 0 },
            .conical => .{ @cos(info.semi_angle), 0 },
            .spherical, .toroidal => .{ 1, 1 },
            .planar, .freeform => try shading.rates(allocator, face, info),
        };
        var period: [2]f64 = .{ 0, 0 };
        for (&period, [2]f64{ info.u_period, info.v_period }, span) |*wrap, length, extent| {
            if (length > 0 and @abs(extent - length) <= 1e-9 * length) wrap.* = length;
        }
        const size = @sqrt(4 * shading.accuracy);
        var count: [2]usize = undefined;
        for (&count, span, rate, period) |*divisions, extent, turn, wrap| {
            const cells = @ceil(extent * turn / size);
            if (!(cells < 1e6)) return error.ShadingLimit;
            divisions.* = @intCast(@max(@as(i64, if (wrap > 0) 3 else 1), @as(i64, @intFromFloat(cells))));
        }
        const cu = count[0];
        const cv = count[1];
        if (@as(f64, @floatFromInt(cu)) * @as(f64, @floatFromInt(cv)) > @as(f64, @floatFromInt(shading.budget))) return error.ShadingLimit;
        const turn = @max(span[0] / @as(f64, @floatFromInt(cu)) * rate[0], span[1] / @as(f64, @floatFromInt(cv)) * rate[1]);
        var m: i64 = 1;
        if (shading.half != null) {
            const steps = @ceil(turn / @sqrt(4 * shading.accuracy * (1 - shading.cutoff)));
            if (!(steps <= max_steps)) return error.ShadingLimit;
            m = @max(1, @as(i64, @intFromFloat(steps)));
        }
        const n = 3 * m;
        const cells = try allocator.alloc(Cell, cu * cv);
        @memset(cells, .{});
        return .{
            .shading = shading,
            .allocator = allocator,
            .face = face,
            .u = info.u,
            .v = info.v,
            .period = period,
            .cu = cu,
            .cv = cv,
            .turn = turn,
            .m = m,
            .n = n,
            .nu = @as(i64, @intCast(cu)) * n,
            .nv = @as(i64, @intCast(cv)) * n,
            .cells = cells,
        };
    }

    /// The cell at (i, j), wrapping around periodic parameters; null outside.
    fn cellAt(self: *const Sheet, i: i64, j: i64) ?usize {
        const cu: i64 = @intCast(self.cu);
        const cv: i64 = @intCast(self.cv);
        const ci = if (self.period[0] > 0) @mod(i, cu) else i;
        const cj = if (self.period[1] > 0) @mod(j, cv) else j;
        if (ci < 0 or ci >= cu or cj < 0 or cj >= cv) return null;
        return @intCast(cj * cu + ci);
    }

    fn build(self: *Sheet) Error!void {
        const a = self.allocator;
        const quads = try a.alloc(Placed, self.cells.len);
        for (quads, 0..) |*quad, index| {
            const i: i64 = @intCast(index % self.cu);
            const j: i64 = @intCast(index / self.cu);
            quad.* = .{ .cell = index, .piece = try self.square(i * self.n, j * self.n, self.n) };
        }
        try self.flush();
        var front: std.ArrayList(Placed) = .empty;
        try self.frontPieces(quads, &front);
        for (front.items) |placed| self.cells[placed.cell].front = true;
        try self.centers(front.items);
        const diffuse = try a.alloc(Patch, front.items.len);
        try self.patches(front.items, false, diffuse);
        for (front.items, diffuse) |placed, patch| {
            const cell = &self.cells[placed.cell];
            try cell.add(a, &cell.diffuse, patch);
            for (side_ends, 0..) |ends, side| {
                const p = self.nodes.items[placed.piece[ends[0]].node];
                const q = self.nodes.items[placed.piece[ends[1]].node];
                if (p.place & q.place & (on_contour | on_bounds) == 0) continue;
                if (skirt(patch, side, self.shading.tolerance)) |made| try cell.add(a, &cell.skirts, made);
            }
        }
        // Glint patches where the highlight can reach: the glint changes by at
        // most turn / (1 - c) across the cell.
        if (self.shading.half == null) return;
        var fine: std.ArrayList(Placed) = .empty;
        for (quads) |quad| {
            if (!self.cells[quad.cell].front) continue;
            var glint = -std.math.inf(f64);
            for (quad.piece) |corner| glint = @max(glint, self.nodes.items[corner.node].raw);
            if (!(glint > -self.turn / (1 - self.shading.cutoff))) continue;
            const origin = quad.piece[0];
            var fj: i64 = 0;
            while (fj < self.m) : (fj += 1) {
                var fi: i64 = 0;
                while (fi < self.m) : (fi += 1) {
                    try fine.append(a, .{ .cell = quad.cell, .piece = try self.square(origin.i + 3 * fi, origin.j + 3 * fj, 3) });
                }
            }
        }
        try self.flush();
        var lit: std.ArrayList(Placed) = .empty;
        try self.frontPieces(fine.items, &lit);
        const glints = try a.alloc(Patch, lit.items.len);
        try self.patches(lit.items, true, glints);
        for (lit.items, glints) |placed, patch| {
            // The field stays within its coefficients, and the highlight shows
            // only where it is positive.
            if (!(std.mem.max(f64, &patch.values) > 0)) continue;
            const cell = &self.cells[placed.cell];
            try cell.add(a, &cell.glint, patch);
        }
    }

    /// Hides the cells whose centers another sheet of the face covers.
    fn cull(self: *Sheet) Error!void {
        const a = self.allocator;
        var points: std.ArrayList(g.Point) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        for (self.cells, 0..) |cell, index| {
            if (!cell.front or cell.center.singular) continue;
            try points.append(a, .{ .x = cell.center.x, .y = cell.center.y });
            try owners.append(a, index);
        }
        if (points.items.len == 0) return;
        const offsets = try a.alloc(usize, points.items.len + 1);
        var found: std.ArrayList(Sighting) = .empty;
        try self.shading.surfaces.sightings(a, self.face, points.items, offsets, &found);
        for (owners.items, offsets[0..owners.items.len], offsets[1..]) |index, start, end| {
            const cell = &self.cells[index];
            for (found.items[start..end]) |sighting| {
                if (sighting.depth > cell.center.depth + self.shading.tolerance) {
                    cell.visible = false;
                    break;
                }
            }
        }
    }

    /// Requests a node at `uv`, evaluated by the next `flush`.
    fn request(self: *Sheet, uv: g.Point, place: u8) !u32 {
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .uv = uv, .place = place });
        return id;
    }

    /// Evaluates the requested nodes. Where the normal is undefined, such as
    /// at a cone's apex, the facing that decides which side of the contour a
    /// node lies on is the mean over points a little way into the face in each
    /// parameter direction.
    fn flush(self: *Sheet) Error!void {
        const a = self.allocator;
        const fresh = self.nodes.items[self.pending..];
        if (fresh.len == 0) return;
        self.pending = self.nodes.items.len;
        const uv = try a.alloc(g.Point, fresh.len);
        for (uv, fresh) |*position, n| position.* = n.uv;
        const points = try a.alloc(Look, fresh.len);
        try self.shading.surfaces.look(a, self.face, uv, points);
        var probes: std.ArrayList(g.Point) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        const du = (self.u[1] - self.u[0]) / @as(f64, @floatFromInt(self.nu)) * 1e-3;
        const dv = (self.v[1] - self.v[0]) / @as(f64, @floatFromInt(self.nv)) * 1e-3;
        for (fresh, points, 0..) |*n, point, index| {
            n.* = self.shading.node(n.uv, point, n.place);
            if (!n.singular) continue;
            const before = probes.items.len;
            for ([_]g.Point{ .{ .x = du, .y = 0 }, .{ .x = -du, .y = 0 }, .{ .x = 0, .y = dv }, .{ .x = 0, .y = -dv } }) |step| {
                const probe = n.uv.add(step);
                if ((self.period[0] == 0 and (probe.x < self.u[0] or probe.x > self.u[1])) or
                    (self.period[1] == 0 and (probe.y < self.v[0] or probe.y > self.v[1]))) continue;
                try probes.append(a, probe);
                try owners.append(a, index);
            }
            if (probes.items.len == before) return error.UndefinedNormal;
        }
        const nearby = try a.alloc(Look, probes.items.len);
        try self.shading.surfaces.look(a, self.face, probes.items, nearby);
        var k: usize = 0;
        while (k < owners.items.len) {
            const owner = owners.items[k];
            var facing: f64 = 0;
            var count: f64 = 0;
            while (k < owners.items.len and owners.items[k] == owner) : (k += 1) {
                const normal = nearby[k].normal orelse continue;
                facing += dot(normal, self.shading.eye);
                count += 1;
            }
            if (count == 0) return error.UndefinedNormal;
            fresh[owner].facing = facing / count;
        }
    }

    fn inFront(self: *const Sheet, corner: Corner) bool {
        return self.nodes.items[corner.node].facing > 0;
    }

    /// `to` moved by whole periods to lie nearest `from`.
    fn near(self: *const Sheet, from: g.Point, to: g.Point) g.Point {
        var result = to;
        if (self.period[0] > 0) result.x = to.x - self.period[0] * @round((to.x - from.x) / self.period[0]);
        if (self.period[1] > 0) result.y = to.y - self.period[1] * @round((to.y - from.y) / self.period[1]);
        return result;
    }

    /// The lattice corner (i, j).
    fn at(self: *Sheet, i: i64, j: i64) !Corner {
        const wi = if (self.period[0] > 0) @mod(i, self.nu) else i;
        const wj = if (self.period[1] > 0) @mod(j, self.nv) else j;
        const entry = try self.lattice.getOrPut(self.allocator, .{ wi, wj });
        if (!entry.found_existing) {
            var place: u8 = 0;
            if (self.period[0] == 0) place |= @as(u8, if (wi == 0) 2 else 0) | @as(u8, if (wi == self.nu) 4 else 0);
            if (self.period[1] == 0) place |= @as(u8, if (wj == 0) 8 else 0) | @as(u8, if (wj == self.nv) 16 else 0);
            entry.value_ptr.* = try self.request(.{
                .x = self.u[0] + (self.u[1] - self.u[0]) * @as(f64, @floatFromInt(wi)) / @as(f64, @floatFromInt(self.nu)),
                .y = self.v[0] + (self.v[1] - self.v[0]) * @as(f64, @floatFromInt(wj)) / @as(f64, @floatFromInt(self.nv)),
            }, place);
        }
        return .{ .node = entry.value_ptr.*, .i = i, .j = j, .lattice = true };
    }

    /// The lattice quad with corner (i, j) and sides of `size` steps.
    fn square(self: *Sheet, i: i64, j: i64, size: i64) !Piece {
        return .{ try self.at(i, j), try self.at(i + size, j), try self.at(i + size, j + size), try self.at(i, j + size) };
    }

    /// The front parts of quads, in order, after cutting the sides that cross
    /// the contour.
    fn frontPieces(self: *Sheet, quads: []const Placed, out: *std.ArrayList(Placed)) Error!void {
        var sides: std.ArrayList([2]u32) = .empty;
        for (quads) |quad| {
            const count = self.frontCount(quad.piece);
            if (count == 0 or count == 4) continue;
            for (halves(quad.piece)) |half| for (0..3) |k| {
                const p = half[k];
                const q = half[(k + 1) % 3];
                if (self.inFront(p) == self.inFront(q)) continue;
                const key = ordered(p.node, q.node);
                const entry = try self.cuts.getOrPut(self.allocator, key);
                if (entry.found_existing) continue;
                entry.value_ptr.* = undefined;
                try sides.append(self.allocator, key);
            };
        }
        try self.cut(sides.items);
        for (quads) |quad| try self.pieces(quad, out);
    }

    fn frontCount(self: *const Sheet, quad: Piece) usize {
        var count: usize = 0;
        for (quad) |corner| count += @intFromBool(self.inFront(corner));
        return count;
    }

    /// The point on each side where n·v vanishes, which OCCT finds along the
    /// straight side in the parameters from its lower node, all sides in one
    /// batch. A side is cut once and shared by both cells on it.
    fn cut(self: *Sheet, sides: []const [2]u32) Error!void {
        if (sides.len == 0) return;
        const a = self.allocator;
        const segments = try a.alloc([2]g.Point, sides.len);
        for (sides, segments) |key, *segment| {
            const from = self.nodes.items[key[0]].uv;
            segment.* = .{ from, self.near(from, self.nodes.items[key[1]].uv) };
        }
        const found = try a.alloc(?f64, sides.len);
        try self.shading.surfaces.roots(a, self.face, segments, self.shading.eye, 0, root_tolerance, found);
        for (sides, segments, found) |key, segment, root| {
            const p = self.nodes.items[key[0]];
            const q = self.nodes.items[key[1]];
            // Without a root, as where the normal is undefined on the way,
            // interpolate the facing at the ends.
            const s = root orelse p.facing / (p.facing - q.facing);
            const place = (p.place & q.place & on_bounds) | on_contour;
            self.cuts.getPtr(key).?.* = try self.request(segment[0].add(segment[1].sub(segment[0]).scale(s)), place);
        }
        try self.flush();
    }

    /// The front parts of a quad: the whole quad, or, where it crosses the
    /// contour, the front parts of the two halves on either side of a
    /// diagonal.
    fn pieces(self: *Sheet, quad: Placed, out: *std.ArrayList(Placed)) !void {
        switch (self.frontCount(quad.piece)) {
            0 => return,
            4 => return out.append(self.allocator, quad),
            else => {},
        }
        for (halves(quad.piece)) |half| {
            var ring: [4]Corner = undefined;
            var size: usize = 0;
            for (0..3) |k| {
                const p = half[k];
                const q = half[(k + 1) % 3];
                const inside = self.inFront(p);
                if (inside) {
                    ring[size] = p;
                    size += 1;
                }
                if (inside != self.inFront(q)) {
                    ring[size] = .{ .node = self.cuts.get(ordered(p.node, q.node)).? };
                    size += 1;
                }
            }
            switch (size) {
                3 => try out.append(self.allocator, .{ .cell = quad.cell, .piece = .{ ring[0], ring[1], ring[2], ring[2] } }),
                4 => try out.append(self.allocator, .{ .cell = quad.cell, .piece = ring }),
                else => {},
            }
        }
    }

    /// Each front cell's center: the mean of its front corners in the
    /// parameters. `placed` lists each cell's pieces together.
    fn centers(self: *Sheet, placed: []const Placed) Error!void {
        const a = self.allocator;
        var uv: std.ArrayList(g.Point) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        var k: usize = 0;
        while (k < placed.len) {
            const cell = placed[k].cell;
            const base = self.nodes.items[placed[k].piece[0].node].uv;
            var sum: g.Point = .zero;
            var count: f64 = 0;
            while (k < placed.len and placed[k].cell == cell) : (k += 1) for (placed[k].piece) |corner| {
                sum = sum.add(self.near(base, self.nodes.items[corner.node].uv));
                count += 1;
            };
            try uv.append(a, .{ .x = sum.x / count, .y = sum.y / count });
            try owners.append(a, cell);
        }
        const nodes = try a.alloc(Node, uv.items.len);
        try self.shading.evaluate(a, self.face, uv.items, nodes);
        for (owners.items, nodes) |cell, center| self.cells[cell].center = center;
    }

    /// A piece's corners in the parameters, the last three moved by whole
    /// periods next to the first.
    fn corners(self: *const Sheet, piece: Piece) [4]g.Point {
        const first = self.nodes.items[piece[0].node].uv;
        return .{ first, self.near(first, self.nodes.items[piece[1].node].uv), self.near(first, self.nodes.items[piece[2].node].uv), self.near(first, self.nodes.items[piece[3].node].uv) };
    }

    fn bilinear(c: [4]g.Point, s: f64, t: f64) g.Point {
        return c[0].scale((1 - s) * (1 - t)).add(c[1].scale(s * (1 - t))).add(c[2].scale(s * t)).add(c[3].scale((1 - s) * t));
    }

    /// The nodes a third and two thirds of the way from a to b: lattice points
    /// on lattice sides, otherwise points on the straight side in the
    /// parameters, made once per side from its lower node and shared by both
    /// patches on it.
    fn thirdsOf(self: *Sheet, a: Corner, b: Corner) ![2]u32 {
        if (a.lattice and b.lattice and @rem(b.i - a.i, 3) == 0 and @rem(b.j - a.j, 3) == 0) {
            const di = @divTrunc(b.i - a.i, 3);
            const dj = @divTrunc(b.j - a.j, 3);
            return .{ (try self.at(a.i + di, a.j + dj)).node, (try self.at(a.i + 2 * di, a.j + 2 * dj)).node };
        }
        const key = ordered(a.node, b.node);
        const entry = try self.thirds.getOrPut(self.allocator, key);
        if (!entry.found_existing) {
            const from = self.nodes.items[key[0]].uv;
            const length = self.near(from, self.nodes.items[key[1]].uv).sub(from);
            const first = try self.request(from.add(.{ .x = length.x / 3, .y = length.y / 3 }), 0);
            entry.value_ptr.* = .{ first, try self.request(from.add(length.scale(2.0 / 3.0)), 0) };
        }
        const made = entry.value_ptr.*;
        return if (a.node == key[0]) made else .{ made[1], made[0] };
    }

    /// The nodes a patch over `piece` samples at (i / 3, j / 3), index
    /// i * 4 + j.
    fn samples(self: *Sheet, piece: Piece) ![16]u32 {
        var id: [16]u32 = undefined;
        id[0] = piece[0].node;
        id[12] = piece[1].node;
        id[15] = piece[2].node;
        id[3] = piece[3].node;
        for ([_][4]usize{ .{ 0, 1, 4, 8 }, .{ 1, 2, 13, 14 }, .{ 3, 2, 7, 11 }, .{ 0, 3, 1, 2 } }) |side| {
            const made = try self.thirdsOf(piece[side[0]], piece[side[1]]);
            id[side[2]] = made[0];
            id[side[3]] = made[1];
        }
        const a, const b, const c, const d = piece;
        const aligned = a.lattice and b.lattice and c.lattice and d.lattice and
            b.i - a.i == d.j - a.j and b.j == a.j and d.i == a.i and c.i == b.i and c.j == d.j;
        const uv = self.corners(piece);
        for (1..3) |i| for (1..3) |j| {
            id[i * 4 + j] = if (aligned)
                (try self.at(a.i + @divTrunc((b.i - a.i) * @as(i64, @intCast(i)), 3), a.j + @divTrunc((d.j - a.j) * @as(i64, @intCast(j)), 3))).node
            else
                try self.request(bilinear(uv, @as(f64, @floatFromInt(i)) / 3.0, @as(f64, @floatFromInt(j)) / 3.0), 0);
        };
        return id;
    }

    /// Patches over pieces carrying n·l, or the glint. The light at a node
    /// without a normal comes from a point a little way toward the patch's
    /// center.
    fn patches(self: *Sheet, placed: []const Placed, glint: bool, out: []Patch) Error!void {
        const a = self.allocator;
        const ids = try a.alloc([16]u32, placed.len);
        for (placed, ids) |p, *id| id.* = try self.samples(p.piece);
        try self.flush();
        const values = try a.alloc([16]f64, placed.len);
        var probes: std.ArrayList(g.Point) = .empty;
        var owners: std.ArrayList(usize) = .empty;
        for (placed, ids, values, 0..) |p, id, *value, index| {
            const center = bilinear(self.corners(p.piece), 0.5, 0.5);
            for (id, value, 0..) |node_id, *v, k| {
                const n = self.nodes.items[node_id];
                if (!n.singular) {
                    v.* = if (glint) n.shine.glint else n.shine.diffuse;
                    continue;
                }
                const from = self.near(center, n.uv);
                try probes.append(a, from.add(center.sub(from).scale(1e-3)));
                try owners.append(a, index * 16 + k);
            }
        }
        const nearby = try a.alloc(Node, probes.items.len);
        try self.shading.evaluate(a, self.face, probes.items, nearby);
        for (nearby, owners.items) |n, owner| {
            if (n.singular) return error.UndefinedNormal;
            values[owner / 16][owner % 16] = if (glint) n.shine.glint else n.shine.diffuse;
        }
        for (ids, values, out) |id, value, *patch| {
            var xs: [16]f64 = undefined;
            var ys: [16]f64 = undefined;
            for (id, &xs, &ys) |node_id, *x, *y| {
                x.* = self.nodes.items[node_id].x;
                y.* = self.nodes.items[node_id].y;
            }
            const px = coefficients(xs);
            const py = coefficients(ys);
            for (&patch.points, px, py) |*point, x, y| point.* = .{ .x = x, .y = y };
            patch.values = coefficients(value);
        }
    }
};

test "a reversed cubic side gets exactly the reversed coefficients" {
    var random: std.Random.DefaultPrng = .init(5);
    for (0..200) |_| {
        var samples: [4]f64 = undefined;
        for (&samples) |*s| s.* = random.random().float(f64) * 200 - 100;
        const forward = bezier(samples[0], samples[1], samples[2], samples[3]);
        const backward = bezier(samples[3], samples[2], samples[1], samples[0]);
        for (0..4) |k| try std.testing.expectEqual(forward[k], backward[3 - k]);
    }
    // The cubic interpolates its samples.
    const c = bezier(1, 4, -2, 3);
    for ([_]f64{ 0, 1.0 / 3.0, 2.0 / 3.0, 1 }, [_]f64{ 1, 4, -2, 3 }) |s, expected| {
        const r = 1 - s;
        const b = [4]f64{ r * r * r, 3 * s * r * r, 3 * s * s * r, s * s * s };
        try std.testing.expectApproxEqAbs(expected, b[0] * c[0] + b[1] * c[1] + b[2] * c[2] + b[3] * c[3], 1e-12);
    }
}
