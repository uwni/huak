//! The light of each layer, from one batch of normals per face.
const std = @import("std");
const c = @import("space_c");
const g = @import("../../geometry.zig");
const Model = @import("../Model.zig");
const shading = @import("../shading.zig");
const dot = shading.dot;
const Bands = @import("Bands.zig");
const Work = @import("Work.zig");
const angular = shading.angular_precision;

/// Whether one of the layers is of `layer`'s face and gleams.
pub fn gleams(layers: []const c.HuakLayer, light: []const Bands.Sample, layer: c.HuakLayer) bool {
    for (layers, light) |other, sample| if (sample.gleam and other.source == layer.source and other.face == layer.face) return true;
    return false;
}

/// The light of each layer: that of its face's normal where the line of
/// sight over its cell meets it, one batch of normals per face.
pub fn lightsOf(self: *const Bands, work: *Work, layers: []const c.HuakLayer) Model.Error![]const Bands.Sample {
    const s = work.scratch;
    const result = try s.alloc(Bands.Sample, layers.len);
    var by_face: std.array_hash_map.Auto([2]usize, std.ArrayList(usize)) = .empty;
    for (layers, 0..) |layer, index| {
        const entry = try by_face.getOrPut(s, .{ layer.source, layer.face });
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(s, index);
    }
    var surfaces = work.view.surfaces();
    for (by_face.keys(), by_face.values()) |face, owners| {
        const uv = try s.alloc(g.Point, owners.items.len);
        for (uv, owners.items) |*at, owner| at.* = .{ .x = layers[owner].u, .y = layers[owner].v };
        const seen = try s.alloc(shading.Look, uv.len);
        surfaces.look(s, .{ .source = face[0], .index = face[1] }, uv, seen) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SurfaceQueryFailed => error.ProjectionFailed,
        };
        for (owners.items, seen) |owner, look| result[owner] = classify(self, look.normal orelse return work.model.failWith("undefined surface normal inside a region of a face"), layers[owner]);
    }
    return result;
}

/// The light of a layer where its face's normal is `normal`. A plane
/// keeps its exact light. On a curved face, light within OCCT's angular
/// precision of a level lies below it: so does the whole of a face
/// whose light stays at a level, as a cone's does lit along its axis.
pub fn classify(self: *const Bands, normal: [3]f64, layer: c.HuakLayer) Bands.Sample {
    const facing = dot(normal, self.sun);
    const toward = if (self.half) |half| dot(normal, half) else 0;
    if (self.faces[layer.source][layer.face].planar) return .{
        .diffuse = if (0 < facing) facing else 0,
        .gleam = self.half != null and facing > 0 and layer.facing > 0 and toward >= self.cutoff,
    };
    var next: usize = 0;
    while (next < self.isophotes.len and facing > self.isophotes[next] + angular) next += 1;
    const gleam = self.half != null and next > 0 and layer.facing > 0 and toward > self.cutoff + angular;
    if (next == 0) return .{ .diffuse = 0, .gleam = gleam };
    const low = self.isophotes[next - 1];
    const high = if (next == self.isophotes.len) 1 else self.isophotes[next];
    return .{ .diffuse = (low + high) / 2, .gleam = gleam };
}
