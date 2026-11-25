//! Transforms: the registry entry, the transform builtins, mapping and bending objects.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const transform_geometry = @import("../../drawing/transform/root.zig");
const mapping = transform_geometry.mapping;
const DisplayList = @import("../../drawing/DisplayList.zig");
const geometry_outline = @import("../../drawing/outline.zig");
const Machine = @import("../Machine.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Affine3 = @import("../../drawing/transform/Affine3.zig");
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const object_handles = @import("object_handles.zig");
const pen = @import("pen.zig");
const lengthPoints = conversions.lengthPoints;
const numeric = conversions.numeric;
const point = conversions.point;
const angular = conversions.angular;
const vector = conversions.vector;

pub const Transform = union(enum) {
    plane: struct { xy: g.Transform, z_scale: f64 },
    spatial: *const Affine3,

    pub fn matrix3(t: Transform) Affine3 {
        return switch (t) {
            .plane => |p| blk: {
                var matrix = Affine3.fromPlane(p.xy);
                matrix.rows[2][2] = p.z_scale;
                break :blk matrix;
            },
            .spatial => |p| p.*,
        };
    }
};

pub fn transformResult(self: *Runtime, value: g.Transform, z_scale: f64) !Value {
    if (!value.isFinite() or !std.math.isFinite(z_scale)) return error.NonFinite;
    return conversions.store(self, Transform, &self.transforms, .{ .plane = .{ .xy = value, .z_scale = z_scale } }, .transform);
}

fn spatialTransform(self: *Runtime, value: Affine3) !Value {
    for (value.rows) |row| for (row) |v| {
        if (!std.math.isFinite(v)) return error.NonFinite;
    };
    const matrix = try self.gpa.create(Affine3);
    errdefer self.gpa.destroy(matrix);
    matrix.* = value;
    return conversions.store(self, Transform, &self.transforms, .{ .spatial = matrix }, .transform);
}

pub fn mapObject(self: *Runtime, machine: *Machine, args: []const Value) !Value {
    // No operand slices or mutable picture commands may be borrowed across
    // script callbacks: they can grow the VM stack and runtime registries.
    const arg = builtin.arguments(.mapped, args);
    const object = arg.object;
    const function = arg.mapping;
    const context = arg.context;
    var options: mapping.Options = .{};
    if (arg.tolerance) |value| options.tolerance = try lengthPoints(value);
    try options.validate();
    const affine = if (function.valueType() == .transform) try conversions.transformValue(self, function) else null;
    if (affine == null and function != .function) return error.TypeMismatch;
    const operator: @import("Mapping.zig") = .{ .machine = machine, .function = function, .context = context };
    if (object.valueType() == .path) {
        const source = try self.path(object);
        return self.pathResult(if (affine) |t| try source.transformed(self.gpa, t) else try mapping.mapped(self.gpa, source, operator, options));
    }
    if (affine) |t| return transformedObject(self, object, t);
    var selected = try object_handles.objectSnapshot(self, object, true);
    defer selected.deinit();
    var snapshot = try geometry_outline.extract(self.gpa, .{ .picture = &selected.picture }, null);
    defer snapshot.deinit();
    return object_handles.objectResult(self, try mapping.picture(self.scene_allocator, &snapshot, operator, options));
}

pub fn transformedObject(self: *Runtime, object: Value, transform: g.Transform) !Value {
    var selected = try object_handles.objectSnapshot(self, object, true);
    defer selected.deinit();
    const copied = copy: {
        var result = DisplayList.initWithMeshes(self.scene_allocator, self.backends.meshes);
        errdefer result.deinit();
        try result.append(&selected.picture, transform);
        break :copy result;
    };
    return object_handles.objectResult(self, copied);
}

/// Transforms: construction, composition, application, mapping and bending.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .matrix => return transformResult(self, .{ .a = try numeric(arg.a), .b = try numeric(arg.b), .c = try numeric(arg.c), .d = try numeric(arg.d), .e = try lengthPoints(arg.e), .f = try lengthPoints(arg.f) }, 1),
        .translate => {
            if (arg.offset == .vec3) {
                const p = try arg.offset.vec3.points();
                var t: Affine3 = .{};
                for (&t.rows, p) |*row, v| row[3] = v;
                return spatialTransform(self, t);
            }
            const p = try point(arg.offset);
            return transformResult(self, .translation(p.x, p.y), 1);
        },
        .scale => {
            const x = try numeric(arg.x);
            const t = g.Transform.scaling(x, if (arg.y) |y| try numeric(y) else x);
            const z = arg.z orelse return transformResult(self, t, if (arg.y != null) 1 else x);
            var spatial = Affine3.fromPlane(t);
            spatial.rows[2][2] = try numeric(z);
            return spatialTransform(self, spatial);
        },
        .rotate => {
            const angle = try angular(arg.angle);
            const axis = arg.axis orelse return transformResult(self, .rotation(angle), 1);
            if (axis != .vec3 or !axis.vec3.dimension.eql(.scalar)) return error.InvalidAxis;
            return spatialTransform(self, try Affine3.rotation(angle, try axis.vec3.points()));
        },
        .compose => {
            const first = try self.affineValue(arg.first);
            const second = try self.affineValue(arg.second);
            if (first == .plane and second == .plane)
                return transformResult(self, first.plane.xy.then(second.plane.xy), first.plane.z_scale * second.plane.z_scale);
            return spatialTransform(self, first.matrix3().then(second.matrix3()));
        },
        .apply => {
            if (arg.point == .vec3) {
                const p = arg.point.vec3;
                const v = (try self.affineValue(arg.transform)).matrix3().apply(try p.points());
                return .{ .vec3 = try types.Vec3.fromPoints(v, p.dimension) };
            }
            const result = (try conversions.transformValue(self, arg.transform)).apply(try point(arg.point));
            const original = try vector(arg.point);
            return .{ .vec2 = if (original.dimension.eql(.scalar)) .{ .x = result.x, .y = result.y } else types.Vec2.fromPoint(result) };
        },
        .mapped => return error.CallbackUnavailable,
        .bent => {
            const offset = if (arg.offset) |given| try lengthPoints(given) else 0;
            const tolerance = if (arg.tolerance) |given| try lengthPoints(given) else g.curve_tolerance;
            var bend = try transform_geometry.Bend.init(self.gpa, try self.path(arg.guide), offset, tolerance);
            defer bend.deinit();
            if (arg.object.valueType() == .path) return self.pathResult(try bend.path(self.gpa, try self.path(arg.object)));
            var source = try object_handles.objectSnapshot(self, arg.object, true);
            defer source.deinit();
            return object_handles.objectResult(self, try bend.picture(self.scene_allocator, &source.picture));
        },
        .transformed => {
            if (arg.object.valueType() == .shape or (arg.object.valueType() == .path and (try self.affineValue(arg.transform)) == .spatial))
                return conversions.modelResult(self, .transformed, &.{ arg.object, arg.transform });
            const transform = try conversions.transformValue(self, arg.transform);
            if (arg.object.valueType() == .pen) {
                var value = try conversions.penValue(self, arg.object);
                var retained = try (try value.fixedNib()).transformed(self.gpa, transform);
                defer retained.deinit();
                value.nib = retained.nib;
                return pen.storePen(self, value);
            }
            if (arg.object == .object) return transformedObject(self, arg.object, transform);
            return self.pathResult(try (try self.path(arg.object)).transformed(self.gpa, transform));
        },
        else => comptime unreachable,
    }
}
