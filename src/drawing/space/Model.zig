//! A model built by the projection backend, and views of it. Each query runs
//! one OCCT operation over a batch; this adapter only converts its inputs and
//! checks what comes back. A failed call leaves its message in `message`, also
//! when this adapter rejects the backend's answer.
const std = @import("std");
const c = @import("space_c");
const g = @import("../geometry.zig");
const shading = @import("shading.zig");
const VTable = @import("Projection.zig").VTable;
const Model = @This();

pub const Message = [512]u8;
pub const Error = error{ ProjectionFailed, OutOfMemory };

/// A root shape: how many faces it has, and its bounding box with its
/// tolerance, or null when it has no geometry.
pub const Shape = struct { faces: usize, box: ?[2][3]f64 };

vtable: *const VTable,
handle: *c.HuakModel,
/// The root shapes, which queries name by index.
shapes: []const Shape,
message: *Message,

/// Builds `nodes`, whose operands precede their users, keeping `roots`.
/// `shapes` is allocated in `allocator`, which `deinit` takes again.
pub fn build(allocator: std.mem.Allocator, vtable: *const VTable, nodes: []const c.HuakModelShape, roots: []const usize, tolerance: f64, message: *Message) Error!Model {
    var handle: ?*c.HuakModel = null;
    try status(vtable.build.?(nodes.ptr, nodes.len, roots.ptr, roots.len, tolerance, &handle, message, message.len));
    const model = handle orelse return fail(message, "projection backend returned no model");
    errdefer vtable.release_model.?(model);
    const shapes = try allocator.alloc(Shape, roots.len);
    errdefer allocator.free(shapes);
    for (shapes, 0..) |*shape, source| {
        var native: c.HuakShape = undefined;
        try status(vtable.shape.?(model, source, &native, message, message.len));
        shape.* = .{ .faces = native.faces, .box = if (native.empty != 0) null else .{ native.box[0..3].*, native.box[3..6].* } };
    }
    return .{ .vtable = vtable, .handle = model, .shapes = shapes, .message = message };
}

pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
    self.vtable.release_model.?(self.handle);
    allocator.free(self.shapes);
    self.* = undefined;
}

/// The backend's message tells failures, argument errors and indices out of
/// range apart.
fn status(code: c_int) Error!void {
    return switch (code) {
        c.HUAK_SPACE_OK => {},
        c.HUAK_SPACE_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.ProjectionFailed,
    };
}

/// Fails with `text` as the message.
pub fn failWith(self: *Model, text: []const u8) error{ProjectionFailed} {
    return fail(self.message, text);
}

fn fail(message: *Message, text: []const u8) error{ProjectionFailed} {
    write(message, text);
    return error.ProjectionFailed;
}

fn write(message: *Message, text: []const u8) void {
    const length = @min(text.len, message.len - 1);
    @memcpy(message[0..length], text[0..length]);
    message[length] = 0;
}

fn rejected(self: *Model) error{ProjectionFailed} {
    return fail(self.message, "projection backend returned records outside its arrays");
}

/// Whether two root shapes are the same shape.
pub fn same(self: *Model, first: usize, second: usize) Error!bool {
    var result: c_int = 0;
    try status(self.vtable.same.?(self.handle, first, second, &result, self.message, self.message.len));
    return result != 0;
}

pub fn face(self: *Model, source: usize, index: usize) Error!shading.Info {
    var native: c.HuakFace = undefined;
    try status(self.vtable.face.?(self.handle, source, index, &native, self.message, self.message.len));
    return .{
        .kind = switch (native.kind) {
            c.HUAK_PLANAR => .planar,
            c.HUAK_CYLINDRICAL => .cylindrical,
            c.HUAK_CONICAL => .conical,
            c.HUAK_SPHERICAL => .spherical,
            c.HUAK_TOROIDAL => .toroidal,
            c.HUAK_FREEFORM => .freeform,
            else => return self.rejected(),
        },
        .u = .{ native.u0, native.u1 },
        .v = .{ native.v0, native.v1 },
        .u_period = native.u_period,
        .v_period = native.v_period,
        .semi_angle = native.semi_angle,
        .axis_x = native.axis_x,
        .axis_y = native.axis_y,
    };
}

/// A camera looking along -eye at the origin with `x` horizontal on the
/// screen; a focus of zero for orthographic projection. `scratch` serves the
/// conversions the view's queries need.
pub fn view(self: *Model, scratch: std.mem.Allocator, eye: [3]f64, x: [3]f64, focus: f64) Error!View {
    var handle: ?*c.HuakView = null;
    var frame: c.HuakFrame = undefined;
    try status(self.vtable.view.?(self.handle, &eye, &x, focus, &handle, &frame, self.message, self.message.len));
    return .{ .model = self, .handle = handle orelse return fail(self.message, "projection backend returned no view"), .frame = frame, .scratch = scratch };
}

/// A camera on the model, with OCCT's frame for it, and the space curves,
/// planar images and planar regions its queries make, named by index.
/// Results borrow the view's memory until `deinit`.
pub const View = struct {
    model: *Model,
    handle: *c.HuakView,
    frame: c.HuakFrame,
    scratch: std.mem.Allocator,

    pub fn deinit(self: *View) void {
        self.model.vtable.release_view.?(self.handle);
        self.* = undefined;
    }

    fn call(self: *const View) struct { *const VTable, *c.HuakView, [*c]u8, usize } {
        return .{ self.model.vtable, self.handle, self.model.message, self.model.message.len };
    }

    fn indices(self: *const View, list: c.HuakIndices) Error![]const usize {
        if (list.count != 0 and list.items == null) return self.model.rejected();
        return items(usize, list.items, list.count);
    }

    /// Where the camera puts points.
    pub fn look(self: *const View, points: []const c.HuakXYZ, out: []c.HuakLook) Error!void {
        std.debug.assert(points.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.look.?(h, points.ptr, points.len, out.ptr, m, n));
    }

    /// Where the lines of sight through screen points meet the root shapes.
    pub fn rays(self: *const View, points: []const c.HuakXY) Error!Rows(c.HuakShapeHit) {
        var found: c.HuakShapeHits = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.rays.?(h, points.ptr, points.len, &found, m, n));
        const result = try self.table(c.HuakShapeHit, points.len, found.offsets, found.items, found.count);
        for (result.values) |hit| {
            if (hit.source >= self.model.shapes.len or hit.face >= self.model.shapes[hit.source].faces) return self.model.rejected();
        }
        return result;
    }

    /// The edges of a root shape, as space curves, in exploration order.
    pub fn curves(self: *const View, source: usize) Error![]const usize {
        var list: c.HuakIndices = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.curves.?(h, source, &list, m, n));
        return self.indices(list);
    }

    /// Each distinct edge of a root shape with the faces it bounds.
    pub fn edges(self: *const View, source: usize) Error![]const c.HuakEdge {
        var list: c.HuakEdges = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.edges.?(h, source, &list, m, n));
        if (list.count != 0 and list.items == null) return self.model.rejected();
        return items(c.HuakEdge, list.items, list.count);
    }

    /// Hidden-line removal of a root shape alone: for each kind, edge,
    /// outline, smooth and seam, its visible curves and then its hidden ones.
    pub fn silhouettes(self: *const View, source: usize) Error![]const c.HuakSilhouette {
        var list: c.HuakSilhouettes = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.silhouettes.?(h, source, &list, m, n));
        if (list.count != 0 and list.items == null) return self.model.rejected();
        const result = items(c.HuakSilhouette, list.items, list.count);
        for (result) |s| if (s.kind < c.HUAK_EDGE or s.kind > c.HUAK_SEAM) return self.model.rejected();
        return result;
    }

    /// The curves where two root shapes meet.
    pub fn sections(self: *const View, first: usize, second: usize) Error![]const usize {
        var list: c.HuakIndices = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.sections.?(h, first, second, &list, m, n));
        return self.indices(list);
    }

    /// The image of each curve, or of its spline, or null where it is a point.
    pub fn project(self: *const View, curves_: []const usize, spline: bool, tolerance: f64, images: []?usize) Error!void {
        std.debug.assert(curves_.len == images.len);
        const native = try self.scratch.alloc(isize, curves_.len);
        defer self.scratch.free(native);
        const t, const h, const m, const n = self.call();
        try status(t.project.?(h, curves_.ptr, curves_.len, @intFromBool(spline), tolerance, native.ptr, m, n));
        for (native, images) |index, *image| image.* = if (index < 0) null else @intCast(index);
    }

    pub fn curveInfo(self: *const View, curves_: []const usize, out: []c.HuakCurveInfo) Error!void {
        std.debug.assert(curves_.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.curve_info.?(h, curves_.ptr, curves_.len, out.ptr, m, n));
    }

    /// The parameter range of each image's planar curve.
    pub fn ranges(self: *const View, images: []const usize, out: []c.HuakRange) Error!void {
        std.debug.assert(images.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.ranges.?(h, images.ptr, images.len, out.ptr, m, n));
    }

    /// The bounds of images together, with their tolerances; null when empty.
    pub fn bounds(self: *const View, images: []const usize) Error!?g.BBox {
        var box: c.HuakBox = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.bounds.?(h, images.ptr, images.len, &box, m, n));
        return boxOf(box);
    }

    /// The bounds of each region with its tolerance; null for an empty one.
    pub fn regionBounds(self: *const View, regions: []const usize, out: []?g.BBox) Error!void {
        std.debug.assert(regions.len == out.len);
        const native = try self.scratch.alloc(c.HuakBox, regions.len);
        defer self.scratch.free(native);
        const t, const h, const m, const n = self.call();
        try status(t.region_bounds.?(h, regions.ptr, regions.len, native.ptr, m, n));
        for (native, out) |box, *result| result.* = boxOf(box);
    }

    /// For each pair of images, the parameters on the first where they meet.
    pub fn crossings(self: *const View, pairs: []const c.HuakPair) Error!Rows(f64) {
        var rows: c.HuakRows = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.crossings.?(h, pairs.ptr, pairs.len, &rows, m, n));
        return self.table(f64, pairs.len, rows.offsets, rows.values, rows.count);
    }

    /// For each pair of a curve and a root shape, the spline parameters where
    /// the curve meets the shape's faces.
    pub fn pierce(self: *const View, pairs: []const c.HuakPair) Error!Rows(f64) {
        var rows: c.HuakRows = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.pierce.?(h, pairs.ptr, pairs.len, &rows, m, n));
        return self.table(f64, pairs.len, rows.offsets, rows.values, rows.count);
    }

    pub fn curvePoints(self: *const View, points: []const c.HuakCurvePoint, out: []c.HuakXYZ) Error!void {
        std.debug.assert(points.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.curve_points.?(h, points.ptr, points.len, out.ptr, m, n));
    }

    pub fn imagePoints(self: *const View, images: []const usize, parameters: []const f64, out: []c.HuakXY) Error!void {
        std.debug.assert(images.len == parameters.len and images.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.image_points.?(h, images.ptr, parameters.ptr, images.len, out.ptr, m, n));
    }

    /// Path commands for pieces of images.
    pub fn approximate(self: *const View, pieces: []const c.HuakPiece, tolerance: f64) Error!Rows(c.HuakPathCommand) {
        var paths: c.HuakPaths = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.approximate.?(h, pieces.ptr, pieces.len, tolerance, &paths, m, n));
        return self.commands(pieces.len, paths);
    }

    /// The images of the curves on a face where the normal makes `angle`
    /// with `direction`.
    pub fn contours(self: *const View, source: usize, face_: usize, direction: [3]f64, angle: f64, tolerance: f64) Error![]const usize {
        var list: c.HuakIndices = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.contours.?(h, source, face_, &direction, angle, tolerance, &list, m, n));
        return self.indices(list);
    }

    /// The regions into which images divide `rectangle`, or `domain` without
    /// one. Pieces of tracked images join their shape's borders.
    pub fn partition(self: *const View, rectangle: ?g.BBox, domain: []const usize, tools: []const usize, tracked: []const c.HuakTracked) Error![]const usize {
        var box: c.HuakBox = undefined;
        if (rectangle) |r| box = .{ .x0 = r.min.x, .y0 = r.min.y, .x1 = r.max.x, .y1 = r.max.y, .empty = 0 };
        var list: c.HuakIndices = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.partition.?(h, if (rectangle != null) &box else null, domain.ptr, domain.len, tools.ptr, tools.len, tracked.ptr, tracked.len, &list, m, n));
        return self.indices(list);
    }

    /// A point inside each region.
    pub fn interiors(self: *const View, regions: []const usize, out: []c.HuakXY) Error!void {
        std.debug.assert(regions.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.interiors.?(h, regions.ptr, regions.len, out.ptr, m, n));
    }

    /// Each list of regions, regions[offsets[k]..offsets[k + 1]], merged where
    /// they share a boundary, except along the borders of shape keep[k]; none
    /// where keep[k] is null.
    pub fn merge(self: *const View, offsets: []const usize, regions: []const usize, keep: []const ?usize) Error!Rows(usize) {
        std.debug.assert(offsets.len == keep.len + 1);
        const native = try self.scratch.alloc(isize, keep.len);
        defer self.scratch.free(native);
        for (native, keep) |*to, source| to.* = if (source) |s| @intCast(s) else -1;
        const sets: c.HuakGroups = .{ .offsets = offsets.ptr, .items = regions.ptr, .count = keep.len };
        var merged: c.HuakGroups = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.merge.?(h, &sets, native.ptr, &merged, m, n));
        return self.table(usize, keep.len, merged.offsets, merged.items, merged.count);
    }

    /// Each region's wires as closed paths.
    pub fn outlines(self: *const View, regions: []const usize, tolerance: f64) Error!Rows(c.HuakPathCommand) {
        var paths: c.HuakPaths = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.outlines.?(h, regions.ptr, regions.len, tolerance, &paths, m, n));
        return self.commands(regions.len, paths);
    }

    /// Each region's area, centroid, principal moments and their axes.
    pub fn moments(self: *const View, regions: []const usize, out: []c.HuakMoments) Error!void {
        std.debug.assert(regions.len == out.len);
        const t, const h, const m, const n = self.call();
        try status(t.moments.?(h, regions.ptr, regions.len, out.ptr, m, n));
    }

    fn table(self: *const View, comptime T: type, expected: usize, offsets: [*c]const usize, values: [*c]const T, count: usize) Error!Rows(T) {
        if (count != expected or offsets == null) return self.model.rejected();
        const limits = offsets[0 .. count + 1];
        if (limits[0] != 0) return self.model.rejected();
        for (limits[0..count], limits[1..]) |start, end| if (start > end) return self.model.rejected();
        if (limits[count] != 0 and values == null) return self.model.rejected();
        return .{ .offsets = limits, .values = items(T, values, limits[count]) };
    }

    fn commands(self: *const View, expected: usize, paths: c.HuakPaths) Error!Rows(c.HuakPathCommand) {
        const result = try self.table(c.HuakPathCommand, expected, paths.offsets, paths.commands, paths.count);
        for (result.values) |command| switch (command.op) {
            c.HUAK_MOVE, c.HUAK_LINE, c.HUAK_BEZIER, c.HUAK_CLOSE => {},
            else => return self.model.rejected(),
        };
        return result;
    }

    /// The faces' geometry as the camera sees it, for `shading`.
    pub fn surfaces(self: *View) shading.Surfaces {
        return .{ .ptr = self, .vtable = &surface_queries };
    }

    const surface_queries: shading.Surfaces.VTable = .{ .info = info, .look = lookAt, .turns = turns, .roots = roots, .sightings = sightings };
    const QueryError = shading.Surfaces.QueryError;

    fn query(code: c_int) QueryError!void {
        return switch (code) {
            c.HUAK_SPACE_OK => {},
            c.HUAK_SPACE_OUT_OF_MEMORY => error.OutOfMemory,
            else => error.SurfaceQueryFailed,
        };
    }

    fn of(ptr: *anyopaque) *View {
        return @ptrCast(@alignCast(ptr));
    }

    fn info(ptr: *anyopaque, f: shading.Face) QueryError!shading.Info {
        return of(ptr).model.face(f.source, f.index) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ProjectionFailed => error.SurfaceQueryFailed,
        };
    }

    fn lookAt(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, uv: []const g.Point, out: []shading.Look) QueryError!void {
        const self = of(ptr);
        const parameters = try uvs(allocator, uv);
        defer allocator.free(parameters);
        const found = try allocator.alloc(c.HuakSample, uv.len);
        defer allocator.free(found);
        const t, const h, const m, const n = self.call();
        try query(t.samples.?(h, f.source, f.index, parameters.ptr, parameters.len, found.ptr, m, n));
        for (found, out) |sample, *result| result.* = .{ .x = sample.look.x, .y = sample.look.y, .depth = sample.look.depth, .normal = if (sample.defined != 0) sample.normal else null };
    }

    fn turns(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, uv: []const g.Point, out: []?shading.Turn) QueryError!void {
        const self = of(ptr);
        const parameters = try uvs(allocator, uv);
        defer allocator.free(parameters);
        const found = try allocator.alloc(c.HuakNormalTurn, uv.len);
        defer allocator.free(found);
        const model = self.model;
        try query(model.vtable.normal_turns.?(model.handle, f.source, f.index, parameters.ptr, parameters.len, found.ptr, model.message, model.message.len));
        for (found, out) |turn, *result| result.* = if (turn.defined != 0) .{ .du = turn.du, .dv = turn.dv } else null;
    }

    fn roots(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, segments: []const [2]g.Point, direction: shading.Vec3, value: f64, tolerance: f64, out: []?f64) QueryError!void {
        const self = of(ptr);
        const native = try allocator.alloc(c.HuakSegment, segments.len);
        defer allocator.free(native);
        for (native, segments) |*to, segment| to.* = .{ .from = .{ .u = segment[0].x, .v = segment[0].y }, .to = .{ .u = segment[1].x, .v = segment[1].y } };
        const found = try allocator.alloc(f64, segments.len);
        defer allocator.free(found);
        const model = self.model;
        try query(model.vtable.roots.?(model.handle, f.source, f.index, native.ptr, native.len, &direction, value, tolerance, found.ptr, model.message, model.message.len));
        for (found, out) |s, *result| result.* = if (std.math.isNan(s)) null else s;
    }

    fn sightings(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, points: []const g.Point, offsets: []usize, out: *std.ArrayList(shading.Sighting)) QueryError!void {
        const self = of(ptr);
        const native = try allocator.alloc(c.HuakXY, points.len);
        defer allocator.free(native);
        for (native, points) |*to, point| to.* = .{ .x = point.x, .y = point.y };
        var found: c.HuakSightings = undefined;
        const t, const h, const m, const n = self.call();
        try query(t.sightings.?(h, f.source, f.index, native.ptr, native.len, &found, m, n));
        const result = self.table(c.HuakSighting, points.len, found.offsets, found.items, found.count) catch return error.SurfaceQueryFailed;
        const base = out.items.len;
        try out.ensureUnusedCapacity(allocator, result.values.len);
        for (result.values) |s| out.appendAssumeCapacity(.{ .depth = s.depth, .uv = .{ .x = s.u, .y = s.v } });
        for (offsets, result.offsets) |*offset, limit| offset.* = base + limit;
    }

    fn uvs(allocator: std.mem.Allocator, uv: []const g.Point) error{OutOfMemory}![]c.HuakUV {
        const result = try allocator.alloc(c.HuakUV, uv.len);
        for (result, uv) |*to, at| to.* = .{ .u = at.x, .v = at.y };
        return result;
    }
};

fn boxOf(box: c.HuakBox) ?g.BBox {
    if (box.empty != 0) return null;
    return .{ .min = .{ .x = box.x0, .y = box.y0 }, .max = .{ .x = box.x1, .y = box.y1 } };
}

/// Lists laid out one after another: list k is values[offsets[k]..offsets[k + 1]].
pub fn Rows(comptime T: type) type {
    return struct {
        offsets: []const usize,
        values: []const T,

        pub fn row(self: @This(), k: usize) []const T {
            return self.values[self.offsets[k]..self.offsets[k + 1]];
        }
    };
}

fn items(comptime T: type, pointer: [*c]const T, count: usize) []const T {
    return if (count == 0) &.{} else pointer[0..count];
}
