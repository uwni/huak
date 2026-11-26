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
        .constant => |shine| return ownedList(output, try output.dupe(Value, &.{ .{ .string = "constant" }, .{ .number = shine.diffuse }, .{ .number = shine.glint } })),
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
            return ownedList(output, try output.dupe(Value, &.{
                .{ .string = "profile" },
                .{ .vec2 = types.Vec2.fromPoint(graded.start) },
                .{ .vec2 = types.Vec2.fromPoint(graded.end) },
                try ownedList(output, positions),
                try ownedList(output, diffuse),
                try ownedList(output, glint),
            }));
        },
        .fan => |fan| {
            const rays = shaded.rays.items[fan.rays.start..][0..fan.rays.count];
            var shows = false;
            for (rays) |ray| if (ray.shine.glint > 0) {
                shows = true;
                break;
            };
            const points = try output.alloc(Value, rays.len);
            const diffuse = try output.alloc(Value, rays.len);
            const glint: ?[]Value = if (shows) try output.alloc(Value, rays.len) else null;
            for (rays, points, diffuse, 0..) |ray, *at, *d, index| {
                at.* = .{ .vec2 = types.Vec2.fromPoint(ray.point) };
                d.* = .{ .number = ray.shine.diffuse };
                if (glint) |table| table[index] = .{ .number = ray.shine.glint };
            }
            return ownedList(output, try output.dupe(Value, &.{
                .{ .string = "fan" },
                .{ .vec2 = types.Vec2.fromPoint(fan.center) },
                try ownedList(output, points),
                try ownedList(output, diffuse),
                try ownedList(output, glint),
                .{ .number = fan.tolerance },
            }));
        },
        .patches => |range| {
            const patches = shaded.patches.items[range.start..][0..range.count];
            const count = patches.len * 16;
            var shows = false;
            // A patch's field stays within its coefficients.
            if (lit) {
                outer: for (patches) |*patch| for (patch.glint) |gl| if (gl > 0) {
                    shows = true;
                    break :outer;
                };
            }
            const points = try output.alloc(Value, count);
            const diffuse: ?[]Value = if (lit) try output.alloc(Value, count) else null;
            const glint: ?[]Value = if (shows) try output.alloc(Value, count) else null;
            const values: ?[]Value = if (scalar != null) try output.alloc(Value, count) else null;
            for (patches, 0..) |*patch, index| {
                const base = index * 16;
                for (patch.points, 0..) |control, k| points[base + k] = .{ .vec2 = types.Vec2.fromPoint(control) };
                if (diffuse) |table| for (patch.diffuse, 0..) |d, k| {
                    table[base + k] = .{ .number = d };
                };
                if (glint) |table| for (patch.glint, 0..) |gl, k| {
                    table[base + k] = .{ .number = gl };
                };
                if (values) |table| for (patch.values, 0..) |v, k| {
                    table[base + k] = .{ .number = v };
                };
            }
            return ownedList(output, try output.dupe(Value, &.{
                .{ .string = "patches" },
                try ownedList(output, points),
                try ownedList(output, diffuse),
                try ownedList(output, glint),
                .{ .number = shading_accuracy },
                .{ .quantity = units.fromPoints(margin) },
                try ownedList(output, values),
                .{ .number = scalar orelse 0 },
            }));
        },
    }
}

/// Wraps a freshly allocated `output` slice in an ownerless `List.Owned` so
/// the VM claims it in place on materialization without copying its buffer.
fn ownedList(output: std.mem.Allocator, items: ?[]Value) !Value {
    const list = try output.create(types.List.Owned);
    list.* = .{};
    if (items) |slice| list.values = .fromOwnedSlice(slice);
    return .{ .list = .{ .owned = list } };
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
