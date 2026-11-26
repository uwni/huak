//! A model built by the projection backend, and views of it. Each query runs
//! one OCCT operation over a batch; this adapter only converts its inputs and
//! checks what comes back. A failed call leaves its message in `message`, also
//! when this adapter rejects the backend's answer.
const std = @import("std");
const c = @import("space_c");
const shading = @import("shading.zig");
const VTable = @import("Projection.zig").VTable;
const Model = @This();
pub const results = @import("model/results.zig");
const queries = @import("model/surface_queries.zig");
const Rows = results.Rows;
const items = results.items;
const Arcs = results.Arcs;
const Cells = results.Cells;
const Regions = results.Regions;
const surface_queries = queries.surface_queries;

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

pub fn rejected(self: *Model) error{ProjectionFailed} {
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
        .apex_v = native.apex_v,
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

    pub fn call(self: *const View) struct { *const VTable, *c.HuakView, [*c]u8, usize } {
        return .{ self.model.vtable, self.handle, self.model.message, self.model.message.len };
    }

    /// Where the lines of sight through screen points meet the root shapes.
    pub fn rays(self: *const View, points: []const c.HuakXY) Error!Rows(c.HuakShapeHit) {
        var found: c.HuakShapeHits = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.rays.?(h, points.ptr, points.len, &found, m, n));
        const result = try results.table(self, c.HuakShapeHit, points.len, found.offsets, found.items, found.count);
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
        return results.indices(self, list);
    }

    /// Each distinct edge of a root shape with the faces it bounds and its
    /// kind.
    pub fn edges(self: *const View, source: usize) Error![]const c.HuakEdge {
        var list: c.HuakEdges = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.edges.?(h, source, &list, m, n));
        if (list.count != 0 and list.items == null) return self.model.rejected();
        const result = items(c.HuakEdge, list.items, list.count);
        for (result) |edge| switch (edge.kind) {
            c.HUAK_EDGE, c.HUAK_SMOOTH, c.HUAK_SEAM => {},
            else => return self.model.rejected(),
        };
        return result;
    }

    /// The outlines of a root shape's faces as the camera sees them, as OCCT
    /// traces them face by face, with the face each lies on.
    pub fn rims(self: *const View, source: usize) Error![]const c.HuakRim {
        var list: c.HuakRims = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.rims.?(h, source, &list, m, n));
        if (list.count != 0 and list.items == null) return self.model.rejected();
        const result = items(c.HuakRim, list.items, list.count);
        for (result) |rim| if (rim.face >= self.model.shapes[source].faces) return self.model.rejected();
        return result;
    }

    /// The curves where two root shapes meet, with the face of each they lie
    /// on.
    pub fn sections(self: *const View, first: usize, second: usize) Error![]const c.HuakSection {
        var list: c.HuakSections = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.sections.?(h, first, second, &list, m, n));
        if (list.count != 0 and list.items == null) return self.model.rejected();
        return items(c.HuakSection, list.items, list.count);
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

    /// For each pair of a curve and a root shape, the spline parameters where
    /// the curve meets the shape's faces.
    pub fn pierce(self: *const View, pairs: []const c.HuakPair) Error!Rows(f64) {
        var rows: c.HuakRows = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.pierce.?(h, pairs.ptr, pairs.len, &rows, m, n));
        return results.table(self, f64, pairs.len, rows.offsets, rows.values, rows.count);
    }

    /// Path commands for pieces of images.
    pub fn approximate(self: *const View, pieces: []const c.HuakPiece, tolerance: f64) Error!Rows(c.HuakPathCommand) {
        var paths: c.HuakPaths = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.approximate.?(h, pieces.ptr, pieces.len, tolerance, &paths, m, n));
        return results.commands(self, pieces.len, paths);
    }

    /// The curves on a face where the normal makes `angle` with `direction`,
    /// as OCCT traces them, with their curves on the face.
    pub fn contours(self: *const View, source: usize, face_: usize, direction: [3]f64, angle: f64) Error![]const usize {
        var list: c.HuakIndices = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.contours.?(h, source, face_, &direction, angle, &list, m, n));
        return results.indices(self, list);
    }

    /// The images arranged into arcs, the pieces of them between the points
    /// where they cross, meet or end, each with the images that run along
    /// it. The view keeps the arrangement until the next one. An image is
    /// also cut at each of `cuts`.
    pub fn arrange(self: *const View, images: []const usize, cuts: []const c.HuakCut) Error!Arcs {
        var found: c.HuakArcs = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.arrange.?(h, images.ptr, images.len, cuts.ptr, cuts.len, &found, m, n));
        const arcs = items(c.HuakArc, found.items, found.count);
        var total: usize = 0;
        for (arcs) |arc| {
            if (arc.first_origin != total or arc.origin_count == 0) return self.model.rejected();
            total += arc.origin_count;
        }
        if (total != 0 and found.origins == null) return self.model.rejected();
        return .{ .arcs = arcs, .origins = items(c.HuakArcOrigin, found.origins, total) };
    }

    /// The cells of the latest arrangement, of `arcs` arcs, with the layers
    /// over each, front to back, and the cells on either side of each arc.
    pub fn cells(self: *const View, arcs: usize) Error!Cells {
        var found: c.HuakCells = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.cells.?(h, &found, m, n));
        if (found.arcs != arcs or (arcs != 0 and (found.left == null or found.right == null))) return self.model.rejected();
        const layers = try results.table(self, c.HuakLayer, found.count, found.offsets, found.layers, found.count);
        for (layers.values) |layer| {
            if (layer.source >= self.model.shapes.len or layer.face >= self.model.shapes[layer.source].faces) return self.model.rejected();
        }
        const left = items(usize, found.left, arcs);
        const right = items(usize, found.right, arcs);
        for (left, right) |here, there| if (here >= found.count or there >= found.count) return self.model.rejected();
        return .{ .layers = layers, .left = left, .right = right };
    }

    /// The closed paths of each set of arcs, arcs[offsets[k]..offsets[k +
    /// 1]], which bound a region lying to their left as they are turned.
    pub fn fill(self: *const View, offsets: []const usize, arcs: []const c.HuakTurnedArc, tolerance: f64) Error!Rows(c.HuakPathCommand) {
        std.debug.assert(offsets.len > 0 and offsets[offsets.len - 1] == arcs.len);
        var paths: c.HuakPaths = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.fill.?(h, offsets.ptr, arcs.ptr, offsets.len - 1, tolerance, &paths, m, n));
        return results.commands(self, offsets.len - 1, paths);
    }

    /// The connected regions of each set of arcs, arcs[offsets[k]..offsets[k +
    /// 1]], which bound a region lying to their left as they are turned.
    /// `moments` is populated only when `compute_moments` is true.
    pub fn regionsOf(self: *const View, offsets: []const usize, arcs: []const c.HuakTurnedArc, tolerance: f64, compute_moments: bool) Error!Regions {
        std.debug.assert(offsets.len > 0 and offsets[offsets.len - 1] == arcs.len);
        var found: c.HuakRegions = undefined;
        const t, const h, const m, const n = self.call();
        try status(t.regions.?(h, offsets.ptr, arcs.ptr, offsets.len - 1, tolerance, @intFromBool(compute_moments), &found, m, n));
        if (found.count != offsets.len - 1 or found.sets == null) return self.model.rejected();
        const sets = found.sets[0..offsets.len];
        if (sets[0] != 0) return self.model.rejected();
        for (sets[0 .. sets.len - 1], sets[1..]) |start, end| if (start > end) return self.model.rejected();
        const total = sets[sets.len - 1];
        if (total != 0 and (found.bounds == null or (compute_moments and found.moments == null))) return self.model.rejected();
        return .{
            .sets = sets,
            .outlines = try results.commands(self, total, .{ .offsets = found.offsets, .commands = found.commands, .count = total }),
            .bounds = items(c.HuakBox, found.bounds, total),
            .moments = if (compute_moments) items(c.HuakMoments, found.moments, total) else &.{},
        };
    }

    /// The faces' geometry as the camera sees it, for `shading`.
    pub fn surfaces(self: *View) shading.Surfaces {
        return .{ .ptr = self, .vtable = &surface_queries };
    }
};
