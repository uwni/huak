//! Answering the shading engine's batches of surface questions from the view and the model: the shading.Surfaces table of this backend.
const std = @import("std");
const c = @import("space_c");
const g = @import("../../geometry.zig");
const shading = @import("../shading.zig");
const Model = @import("../Model.zig");
const results = @import("results.zig");
const View = Model.View;
const QueryError = shading.Surfaces.QueryError;

pub const surface_queries: shading.Surfaces.VTable = .{ .info = info, .look = lookAt, .turns = turns, .roots = roots, .sightings = sightings };

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
    for (found, out) |sample, *result| result.* = .{ .x = sample.look.x, .y = sample.look.y, .depth = sample.look.depth, .normal = if (sample.defined != 0) side(f, sample.normal) else null };
}

/// A normal of `f`'s face as the side `f` names sees it.
fn side(f: shading.Face, v: shading.Vec3) shading.Vec3 {
    return if (f.back) .{ -v[0], -v[1], -v[2] } else v;
}

fn turns(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, uv: []const g.Point, out: []?shading.Turn) QueryError!void {
    const self = of(ptr);
    const parameters = try uvs(allocator, uv);
    defer allocator.free(parameters);
    const found = try allocator.alloc(c.HuakNormalTurn, uv.len);
    defer allocator.free(found);
    const model = self.model;
    try query(model.vtable.normal_turns.?(model.handle, f.source, f.index, parameters.ptr, parameters.len, found.ptr, model.message, model.message.len));
    for (found, out) |turn, *result| result.* = if (turn.defined != 0) .{ .du = side(f, turn.du), .dv = side(f, turn.dv) } else null;
}

fn roots(ptr: *anyopaque, allocator: std.mem.Allocator, f: shading.Face, segments: []const [2]g.Point, direction: shading.Vec3, value: f64, tolerance: f64, out: []?f64) QueryError!void {
    const self = of(ptr);
    const native = try allocator.alloc(c.HuakSegment, segments.len);
    defer allocator.free(native);
    for (native, segments) |*to, segment| to.* = .{ .from = .{ .u = segment[0].x, .v = segment[0].y }, .to = .{ .u = segment[1].x, .v = segment[1].y } };
    const found = try allocator.alloc(f64, segments.len);
    defer allocator.free(found);
    const model = self.model;
    // On the back, n·direction = value where the face's own normal gives -value.
    const level = if (f.back) -value else value;
    try query(model.vtable.roots.?(model.handle, f.source, f.index, native.ptr, native.len, &direction, level, tolerance, found.ptr, model.message, model.message.len));
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
    const result = results.table(self, c.HuakSighting, points.len, found.offsets, found.items, found.count) catch return error.SurfaceQueryFailed;
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
