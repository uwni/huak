//! Smooth light and script-defined scalar fields for projected front regions.
const std = @import("std");
const Machine = @import("../../Machine.zig");
const convert = @import("../conversions.zig");
const types = @import("../../types.zig");
const units = @import("../../../drawing/units.zig");
const g = @import("../../../drawing/geometry.zig");
const shading = @import("../../../drawing/space/shading.zig");
const Model = @import("../../../drawing/space/Model.zig");
const linework = @import("../../../drawing/space/linework.zig");
const Value = types.Value;

/// Smooth light stays within one 256th of n·l and of the glint wherever an
/// output interpolates it; the palette's slope keeps the color error below
/// one 8-bit step.
pub const shading_accuracy = 1.0 / 256.0;

/// false, or [kind, ...]: ["constant", diffuse, glint], ["profile", start,
/// end, positions, diffuse, glint], ["fan", center, points, diffuse, glint,
/// accuracy], with the light on the ray through each point and the error
/// outputs may add as the accuracy, or ["patches", points, diffuse, glint,
/// accuracy, margin, values, tolerance], with sixteen control points and
/// coefficients of each light and of the script's field per patch; the
/// margin is the outline tolerance and the tolerance the field's. A fan's or
/// patches' glint is empty where the highlight shows nowhere, their n·l
/// without a light, and the values without a field.
pub fn fieldValue(output: std.mem.Allocator, shaded: *const shading.Output, field: shading.Field, margin: f64, lit: bool, scalar: ?f64) !Value {
    switch (field) {
        .none => return .{ .boolean = false },
        .constant => |shine| return types.listView(try output.dupe(Value, &.{ .{ .string = "constant" }, .{ .number = shine.diffuse }, .{ .number = shine.glint } })),
        .profile => |graded| {
            const samples = shaded.samples.items[graded.samples.start..][0..graded.samples.count];
            const positions = try output.alloc(Value, samples.len);
            const diffuse = try output.alloc(Value, samples.len);
            const glint = try output.alloc(Value, samples.len);
            for (samples, positions, diffuse, glint) |sample, *position, *d, *gl| {
                position.* = .{ .number = sample.position };
                d.* = .{ .number = sample.shine.diffuse };
                gl.* = .{ .number = sample.shine.glint };
            }
            return types.listView(try output.dupe(Value, &.{ .{ .string = "profile" }, .{ .vec2 = types.Vec2.fromPoint(graded.start) }, .{ .vec2 = types.Vec2.fromPoint(graded.end) }, types.listView(positions), types.listView(diffuse), types.listView(glint) }));
        },
        .fan => |fan| {
            const rays = shaded.rays.items[fan.rays.start..][0..fan.rays.count];
            const points = try output.alloc(Value, rays.len);
            const lights = try lightLists(output, rays.len);
            var shows = false;
            for (rays, points, lights[0], lights[1]) |ray, *at, *d, *gl| {
                at.* = .{ .vec2 = types.Vec2.fromPoint(ray.point) };
                d.* = .{ .number = ray.shine.diffuse };
                gl.* = .{ .number = ray.shine.glint };
                shows = shows or ray.shine.glint > 0;
            }
            return types.listView(try output.dupe(Value, &.{ .{ .string = "fan" }, .{ .vec2 = types.Vec2.fromPoint(fan.center) }, types.listView(points), types.listView(lights[0]), glintList(lights[1], shows), .{ .number = fan.tolerance } }));
        },
        .patches => |range| {
            const patches = shaded.patches.items[range.start..][0..range.count];
            const points = try output.alloc(Value, patches.len * 16);
            const lights = try lightLists(output, patches.len * 16);
            const values = try output.alloc(Value, patches.len * 16);
            var shows = false;
            for (patches, 0..) |patch, index| for (patch.points, patch.diffuse, patch.glint, patch.values, 0..) |control, d, gl, v, k| {
                points[index * 16 + k] = .{ .vec2 = types.Vec2.fromPoint(control) };
                lights[0][index * 16 + k] = .{ .number = d };
                lights[1][index * 16 + k] = .{ .number = gl };
                values[index * 16 + k] = .{ .number = v };
                // A patch's field stays within its coefficients.
                shows = shows or gl > 0;
            };
            return types.listView(try output.dupe(Value, &.{
                .{ .string = "patches" },
                types.listView(points),
                types.listView(if (lit) lights[0] else lights[0][0..0]),
                glintList(lights[1], shows),
                .{ .number = shading_accuracy },
                .{ .quantity = units.fromPoints(margin) },
                types.listView(if (scalar != null) values else values[0..0]),
                .{ .number = scalar orelse 0 },
            }));
        },
    }
}

/// Lists for n·l and the glint.
fn lightLists(output: std.mem.Allocator, count: usize) ![2][]Value {
    const diffuse = try output.alloc(Value, count);
    return .{ diffuse, try output.alloc(Value, count) };
}

fn glintList(values: []Value, shows: bool) Value {
    return types.listView(if (shows) values else values[0..0]);
}

/// The script's field: its function called through the VM with a point of
/// a face in world coordinates, as lengths, and the unit normal of the side
/// shaded there. A callback's failure waits until the projection unwinds
/// to be reported.
pub const ScriptField = struct {
    machine: *Machine,
    function: Value,
    failure: ?anyerror = null,

    const vtable: shading.Sampler.VTable = .{ .values = values };

    pub fn sampler(self: *ScriptField) shading.Sampler {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn values(ptr: *anyopaque, points: []const shading.Vec3, normals: []const shading.Vec3, out: []f64) shading.Sampler.SampleError!void {
        const self: *ScriptField = @ptrCast(@alignCast(ptr));
        for (points, normals, out) |p, n, *value| value.* = self.at(p, n) catch |err| {
            self.failure = err;
            return error.FieldFailed;
        };
    }

    fn at(self: *ScriptField, p: shading.Vec3, n: shading.Vec3) !f64 {
        const args = [_]Value{ .{ .vec3 = try types.Vec3.fromPoints(p, units.Dimension.distance) }, .{ .vec3 = .{ .x = n[0], .y = n[1], .z = n[2] } } };
        const result = try self.machine.invokeFunction(self.function, &args);
        const number = convert.numeric(result) catch return error.FieldMustReturnNumber;
        if (!std.math.isFinite(number)) return error.NonFinite;
        return number;
    }
};

/// The larger side of the box the face records cover on the page.
pub fn pageExtent(work: *const linework.Linework) f64 {
    var whole: ?g.BBox = null;
    for (work.bounds.items) |found| if (found) |box| {
        whole = if (whole) |sum| sum.include(box.min).include(box.max) else box;
    };
    const box = whole orelse return 0;
    return @max(box.max.x - box.min.x, box.max.y - box.min.y);
}

/// The smooth fields of each front region: its light, without bands, and
/// the script's field.
pub fn shade(scratch: std.mem.Allocator, view: *Model.View, work: *const linework.Linework, light: ?linework.Light, tolerance: f64, scalar: ?shading.Scalar, out_fields: []shading.Field, shaded: *shading.Output) shading.Error!void {
    const sun: shading.Vec3 = if (light) |l| shading.unit(l.direction) else .{ 0, 0, 0 };
    const spot = if (light) |l| l.spot else 0;
    const frame = work.frame;
    var lighting: shading.Shading = try .init(scratch, view.surfaces(), .{ .sun = sun, .spot = spot, .accuracy = shading_accuracy }, .{ .x = frame.x, .y = frame.y, .eye = frame.eye }, tolerance, scalar);
    defer lighting.deinit();
    try linework.smoothFields(work, &lighting, shaded, out_fields);
}
