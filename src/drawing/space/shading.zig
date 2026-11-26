//! Continuous light for vector shading: the field d = n·l of a sheet and its
//! glint g = (n·h - c) / (1 - c), within an accuracy e at points farther than
//! the outline tolerance from a region's outline (the outline itself is only
//! that accurate).
//!
//! A plane's light is constant. A cylinder seen across its axis gets a
//! profile (`shading/cylinder.zig`), a cone a fan (`shading/cone.zig`), and
//! other faces tensor-product Bézier patches over a grid of their parameters
//! (`shading/Sheet.zig`).
//!
//! OCCT answers every geometric question through `Surfaces`, in batches: a
//! sheet requests the samples one step of its construction needs and has them
//! evaluated together before the next step reads them.
const std = @import("std");
const g = @import("../geometry.zig");
const cylinder = @import("shading/cylinder.zig");
const cone = @import("shading/cone.zig");
const Node = @import("shading/Node.zig");
const Sheet = @import("shading/Sheet.zig");
const regionFields = Sheet.regionFields;

pub const Vec3 = [3]f64;

pub fn dot(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// `v` scaled to length 1.
pub fn unit(v: Vec3) Vec3 {
    const length = @sqrt(dot(v, v));
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

/// The direction halfway between the sun and the eye, where the highlight is
/// brightest: none without a spot, or when the two are opposite.
pub fn halfway(sun: Vec3, eye: Vec3, spot: f64) ?Vec3 {
    const bisector: Vec3 = .{ sun[0] + eye[0], sun[1] + eye[1], sun[2] + eye[2] };
    const length = @sqrt(dot(bisector, bisector));
    return if (spot > 0 and length > angular_precision) .{ bisector[0] / length, bisector[1] / length, bisector[2] / length } else null;
}

/// A face of a projected model: its root shape and its index among that
/// shape's faces; `back` for the side its normal points away from, which
/// an open sheet may show. That side is shaded as a face of its own, with
/// the normal reversed in every answer about it.
pub const Face = struct { source: usize, index: usize, back: bool = false };

pub const Kind = enum { planar, cylindrical, conical, spherical, toroidal, freeform };

pub const Info = struct {
    kind: Kind,
    /// The face's parameter bounds.
    u: [2]f64,
    v: [2]f64,
    /// Zero unless the surface is periodic in the parameter.
    u_period: f64 = 0,
    v_period: f64 = 0,
    /// Cones: the semi-angle, and the v of the apex, where the rulings meet.
    semi_angle: f64 = 0,
    apex_v: f64 = 0,
    /// Cylinders: u is the angle from axis_x toward axis_y.
    axis_x: Vec3 = .{ 0, 0, 0 },
    axis_y: Vec3 = .{ 0, 0, 0 },
};

/// A face's point as the camera sees it: its screen position and depth
/// toward the viewer, and the face's unit normal there as oriented in its
/// shape, reversed on its back (see `Face`); null where the normal is
/// undefined, as at a cone's apex.
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
    /// Unit vector toward the light; zero for none, which leaves n·l at 0
    /// everywhere, with no highlight.
    sun: Vec3,
    /// The highlight's angle around the half vector; zero for none.
    spot: f64 = 0,
    /// The largest error interpolated light may have.
    accuracy: f64,
};

/// Light at one point: n·l, unclamped, and the glint (n·h - cos spot) /
/// (1 - cos spot), 1 at the center of the highlight and positive inside it.
/// Where the point is unlit the glint is capped at 0, so the field stays
/// continuous across the terminator wherever the highlight does not reach
/// it; with no highlight it is -1.
pub const Shine = struct { diffuse: f64, glint: f64 };
pub const Sample = struct {
    /// The fraction of the way from start to end.
    position: f64,
    shine: Shine,
};
/// A tensor-product Bézier patch carrying the light and the script's field:
/// over (u, v) in the unit square, the sums of points[i * 4 + j],
/// diffuse[i * 4 + j], glint[i * 4 + j] and values[i * 4 + j] times
/// B_i(u) B_j(v), with B the cubic Bernstein polynomials.
pub const Patch = struct { points: [16]g.Point, diffuse: [16]f64, glint: [16]f64, values: [16]f64 };
/// A point on a ray from a fan's center and the light along that ray.
pub const Ray = struct { point: g.Point, shine: Shine };
pub const Range = struct { start: usize, count: usize };

/// A constant field; a profile varying only along start -> end, linear
/// between samples in increasing position; a fan; or patches. Both lights of
/// a fan or of patches lie on the same rays or patches, so an output can
/// combine them ray by ray or patch by patch.
///
/// A fan is constant along each ray from its center, and between two
/// consecutive rays it is linear along the chord joining their points; two
/// rays at one point make a step. It carries n·l all around the center, and
/// the glint where the highlight shows, 0 elsewhere. A fan stays within the
/// accuracy less `tolerance` of the light, and an output that draws it may
/// add `tolerance`.
///
/// A patch's corner values, interpolated bilinearly, stay within the
/// accuracy of the light; its cubic field interpolates samples of the light
/// and is closer still. Later patches paint over earlier ones; together they
/// extend past the region they shade. Patches are finer where the highlight
/// can reach and carry the glint there; elsewhere the glint is 0. With the
/// script's field every face has patches, finer where the field strays from
/// them, and they carry the field too (see `Scalar`). Ranges index the
/// `Output`.
pub const Field = union(enum) {
    none,
    constant: Shine,
    profile: struct { start: g.Point, end: g.Point, samples: Range },
    fan: struct { center: g.Point, rays: Range, tolerance: f64 },
    patches: Range,
};

pub const Output = struct {
    samples: std.ArrayList(Sample) = .empty,
    rays: std.ArrayList(Ray) = .empty,
    patches: std.ArrayList(Patch) = .empty,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.rays.deinit(allocator);
        self.patches.deinit(allocator);
        self.* = undefined;
    }
};

/// A scalar field from outside the engine, a script's: its value at points
/// of the faces in world coordinates, given the unit normal of the side
/// shaded there. A failure is the sampler's to report: it answers only
/// FieldFailed.
pub const Sampler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const SampleError = error{ FieldFailed, OutOfMemory };
    pub const VTable = struct {
        values: *const fn (ptr: *anyopaque, points: []const Vec3, normals: []const Vec3, out: []f64) SampleError!void,
    };

    pub fn values(self: Sampler, points: []const Vec3, normals: []const Vec3, out: []f64) SampleError!void {
        std.debug.assert(points.len == normals.len and points.len == out.len);
        if (points.len == 0) return;
        return self.vtable.values(self.ptr, points, normals, out);
    }
};

/// The script's field; how far a patch's corner values, interpolated
/// bilinearly as a PDF patch mesh paints them, may stray from it at the
/// patch's samples, an estimate rather than a bound; and how far apart its
/// samples may lie on the page, so that the estimate sees what changes
/// over that distance.
pub const Scalar = struct { sampler: Sampler, tolerance: f64, step: f64 };

/// How often the script's field may halve a cell's side.
pub const field_levels = 8;

pub const Error = Surfaces.QueryError || Sampler.SampleError || error{ ShadingLimit, UndefinedNormal, FieldLimit };

/// Patches per projection; more report ShadingLimit instead of exhausting
/// memory.
pub const max_patches: usize = 250_000;
/// OCCT's angular precision, below which the half vector is undefined.
pub const angular_precision = 1e-12;
/// The most steps one division of a profile or cell may take.
pub const max_steps: f64 = std.math.maxInt(i32);

/// An orthographic camera's axes in world coordinates, as OCCT builds them
/// through the origin: the screen's x and y, and toward the viewer. A point
/// at screen (x, y) and depth d is x X + y Y + d E.
pub const Axes = struct { x: Vec3, y: Vec3, eye: Vec3 };

/// One projection's light and view. Fields of its faces draw from one patch
/// budget.
pub const Shading = struct {
    allocator: std.mem.Allocator,
    surfaces: Surfaces,
    /// Toward the viewer, as OCCT's camera has it.
    eye: Vec3,
    /// The screen's x and y axes in world coordinates.
    across: [2]Vec3,
    /// The script's field, if any.
    scalar: ?Scalar,
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
    pub fn init(allocator: std.mem.Allocator, surfaces: Surfaces, light: Light, axes: Axes, tolerance: f64, scalar: ?Scalar) error{OutOfMemory}!Shading {
        const eye = axes.eye;
        const half = halfway(light.sun, eye, light.spot);
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
            .across = .{ axes.x, axes.y },
            .scalar = scalar,
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

    pub fn glint(self: *const Shading, normal: Vec3) f64 {
        const half = self.half orelse return -1;
        return (dot(normal, half) - self.cutoff) / (1 - self.cutoff);
    }

    pub fn shine(self: *const Shading, normal: Vec3) Shine {
        const diffuse = dot(normal, self.sun);
        const gleam = self.glint(normal);
        return .{ .diffuse = diffuse, .glint = if (diffuse > 0) gleam else @min(gleam, 0) };
    }

    /// The node at `uv`: its projection, depth, normal and light. A singular
    /// node keeps its projection and depth only.
    pub fn node(self: *const Shading, uv: g.Point, seen: Look, place: u8) Node {
        var result: Node = .{ .uv = uv, .x = seen.x, .y = seen.y, .depth = seen.depth, .place = place };
        const normal = seen.normal orelse {
            result.singular = true;
            return result;
        };
        result.normal = normal;
        result.facing = dot(normal, self.eye);
        result.shine = self.shine(normal);
        result.raw = self.glint(normal);
        return result;
    }

    pub fn evaluate(self: *const Shading, scratch: std.mem.Allocator, face: Face, uv: []const g.Point, out: []Node) Error!void {
        const seen = try scratch.alloc(Look, uv.len);
        try self.surfaces.look(scratch, face, uv, seen);
        for (uv, seen, out) |at, point, *result| result.* = self.node(at, point, 0);
    }

    /// Where a node lies in world coordinates.
    pub fn world(self: *const Shading, n: Node) Vec3 {
        var result: Vec3 = undefined;
        for (&result, self.across[0], self.across[1], self.eye) |*v, x, y, e| v.* = n.x * x + n.y * y + n.depth * e;
        return result;
    }

    /// The script's field at the nodes, in one batch. A singular node has
    /// no normal to give it, and takes its value later, as its light, from a
    /// point nearby.
    pub fn sample(self: *const Shading, scratch: std.mem.Allocator, nodes: []Node) Error!void {
        const scalar = self.scalar orelse return;
        var points: std.ArrayList(Vec3) = .empty;
        defer points.deinit(scratch);
        var normals: std.ArrayList(Vec3) = .empty;
        defer normals.deinit(scratch);
        var owners: std.ArrayList(usize) = .empty;
        defer owners.deinit(scratch);
        try points.ensureTotalCapacity(scratch, nodes.len);
        try normals.ensureTotalCapacity(scratch, nodes.len);
        try owners.ensureTotalCapacity(scratch, nodes.len);
        for (nodes, 0..) |n, index| if (!n.singular) {
            points.appendAssumeCapacity(self.world(n));
            normals.appendAssumeCapacity(n.normal);
            owners.appendAssumeCapacity(index);
        };
        const found = try scratch.alloc(f64, owners.items.len);
        defer scratch.free(found);
        try scalar.sampler.values(points.items, normals.items, found);
        for (owners.items, found) |owner, value| nodes[owner].value = value;
    }

    /// One field per region. `regions` bound the planar regions where `face`
    /// is the front surface, and `sides` are the sides of it they show;
    /// profile samples and patches go to `out`. A plane's light is
    /// constant, a cylinder's a profile and a cone's a fan, but the script's
    /// field can vary every way: with it every face gets patches.
    ///
    /// A face that shows one side is shaded from that side. A face that
    /// shows both, as an open sheet may, gets a sheet for each side, and
    /// each region the cells of both that nothing of the face lies in front
    /// of: where a sheet folds away at its outline, the side beyond is
    /// behind the side before.
    pub fn fields(self: *Shading, out: *Output, whole: Face, sides: Sides, regions: []const g.BBox, single_layer: bool, result: []Field) Error!void {
        std.debug.assert(regions.len == result.len);
        @memset(result, .none);
        if (regions.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const info = try self.surfaces.info(whole);
        const both = sides.front and sides.back;
        const face: Face = .{ .source = whole.source, .index = whole.index, .back = sides.back and !sides.front };
        if (self.scalar == null and !both) switch (info.kind) {
            .planar => {
                var center: [1]Node = undefined;
                try self.evaluate(scratch, face, &.{.{ .x = (info.u[0] + info.u[1]) / 2, .y = (info.v[0] + info.v[1]) / 2 }}, &center);
                if (center[0].singular) return error.UndefinedNormal;
                @memset(result, .{ .constant = center[0].shine });
                return;
            },
            .cylindrical => if (try cylinder.profile(self, scratch, out, face, info)) |field| {
                @memset(result, field);
                return;
            },
            .conical => if (try cone.fan(self, scratch, out, face, info)) |field| {
                @memset(result, field);
                return;
            },
            else => {},
        };
        var sheets: [2]Sheet = undefined;
        const count: usize = if (both) 2 else 1;
        for (sheets[0..count], 0..) |*sheet, k| {
            sheet.* = try .init(self, scratch, if (both) .{ .source = face.source, .index = face.index, .back = k == 1 } else face, info);
            try sheet.build();
        }
        try regionFields(self, sheets[0..count], scratch, out, regions, result, single_layer and !both);
    }
};

/// The sides of a face that show: the front, where its normal points at
/// the viewer, and the back.
pub const Sides = struct { front: bool = false, back: bool = false };

test {
    _ = @import("shading/patches.zig");
    _ = @import("shading/grid.zig");
    _ = @import("shading/depth_order.zig");
}
