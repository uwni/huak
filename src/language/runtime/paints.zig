//! Builtins for colors and gradients, the paints of fills and strokes.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const numeric = conversions.numeric;
const point = conversions.point;
const lengthPoints = conversions.lengthPoints;

/// Colors and gradients.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    // A gradient's arrays are read into scratch memory; the stored gradient
    // keeps its own copy.
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    switch (id) {
        .rgb => {
            const value = DisplayList.Color{ .r = try numeric(arg.red), .g = try numeric(arg.green), .b = try numeric(arg.blue), .a = if (arg.alpha) |alpha| try numeric(alpha) else 1 };
            if (!value.valid()) return error.InvalidColor;
            return conversions.store(self, DisplayList.Color, &self.colors, value, .color);
        },
        .gradient_linear => return stored(self, .{ .linear = try ramp(self, scratch, try point(arg.start), try point(arg.end), arg.colors, arg.offsets) }),
        .gradient_radial => {
            const center = try point(arg.center);
            const radius = try lengthPoints(arg.radius);
            if (!(radius > 0)) return error.InvalidRadius;
            return stored(self, .{ .radial = try ramp(self, scratch, center, .{ .x = center.x + radius, .y = center.y }, arg.colors, arg.offsets) });
        },
        .gradient_patches => {
            const point_values = types.sequence(arg.points) orelse return error.TypeMismatch;
            const field_values = types.sequence(arg.values) orelse return error.TypeMismatch;
            const color_values = types.sequence(arg.colors) orelse return error.TypeMismatch;
            const level_values = types.sequence(arg.levels) orelse return error.TypeMismatch;
            // Sixteen control points and field coefficients per patch.
            if (point_values.len == 0 or point_values.len % 16 != 0 or field_values.len != point_values.len) return error.InvalidStyle;
            if (color_values.len == 0 or color_values.len != level_values.len) return error.InvalidStyle;
            const tolerance = try numeric(arg.tolerance);
            const margin = if (arg.margin) |given| try lengthPoints(given) else 0;
            if (!std.math.isFinite(tolerance) or !(tolerance > 0)) return error.InvalidStyle;
            if (!std.math.isFinite(margin) or !(margin >= 0)) return error.InvalidStyle;
            const target = if (self.backends.meshes) |store| store.lockedAllocator() else self.gpa;
            const points = try target.alloc([16]g.Point, point_values.len / 16);
            errdefer target.free(points);
            for (points, 0..) |*patch, index| for (patch, point_values[index * 16 ..][0..16]) |*dest, value| {
                const p = try point(value);
                if (!p.isFinite()) return error.NonFinite;
                dest.* = p;
            };
            const values = try target.alloc([16]f64, field_values.len / 16);
            errdefer target.free(values);
            for (values, 0..) |*patch, index| for (patch, field_values[index * 16 ..][0..16]) |*dest, value| {
                const v = try numeric(value);
                if (!std.math.isFinite(v)) return error.NonFinite;
                dest.* = v;
            };
            const colors = try target.alloc(DisplayList.Color, color_values.len);
            errdefer target.free(colors);
            for (color_values, colors) |value, *dest| dest.* = try conversions.color(self, value);
            const levels = try target.alloc(f64, level_values.len);
            errdefer target.free(levels);
            for (level_values, levels) |value, *dest| dest.* = try numeric(value);
            const raw: DisplayList.Gradient.Patches = .{
                .points = points,
                .values = values,
                .stops = .{ .levels = levels, .colors = colors },
                .tolerance = tolerance,
                .margin = margin,
            };
            try raw.stops.validate();
            const adopted = try raw.adopt(self.gpa, self.backends.meshes);
            errdefer adopted.shared.?.release();
            return conversions.adoptGradient(self, .{ .patches = adopted });
        },
        .gradient_fan => {
            const point_values = types.sequence(arg.points) orelse return error.TypeMismatch;
            const field_values = types.sequence(arg.values) orelse return error.TypeMismatch;
            // One field value per point, on its ray from the center.
            if (field_values.len != point_values.len) return error.InvalidStyle;
            const points = try scratch.alloc(g.Point, point_values.len);
            for (point_values, points) |value, *dest| dest.* = try point(value);
            const values = try scratch.alloc(f64, field_values.len);
            for (field_values, values) |value, *dest| dest.* = try numeric(value);
            return stored(self, .{ .fan = .{ .center = try point(arg.center), .points = points, .values = values, .stops = try stops(self, scratch, arg.colors, arg.levels), .tolerance = try numeric(arg.tolerance) } });
        },
        else => comptime unreachable,
    }
}

/// Stores a gradient that paints as a style may: its arrays checked by the
/// rules a style's paint obeys.
fn stored(self: *Runtime, gradient: DisplayList.Gradient) !Value {
    try DisplayList.validateStyle(&.{ .fill = .{ .gradient = &gradient } });
    return conversions.storeGradient(self, gradient);
}

/// Colors along the line from `start` to `end`, at `offsets` or evenly.
fn ramp(self: *Runtime, scratch: std.mem.Allocator, start: g.Point, end: g.Point, color_list: Value, offset_list: ?Value) !DisplayList.Gradient.Ramp {
    const values = types.sequence(color_list) orelse return error.TypeMismatch;
    const colors = try scratch.alloc(DisplayList.Color, values.len);
    for (values, colors) |value, *dest| dest.* = try conversions.color(self, value);
    const positions = if (offset_list) |given| types.sequence(given) orelse return error.TypeMismatch else &[_]Value{};
    const offsets = try scratch.alloc(f64, positions.len);
    for (positions, offsets) |value, *dest| dest.* = try numeric(value);
    return .{ .start = start, .end = end, .colors = colors, .offsets = offsets };
}

/// Colors at levels of a scalar field.
fn stops(self: *Runtime, scratch: std.mem.Allocator, color_list: Value, level_list: Value) !DisplayList.Gradient.Stops {
    const color_values = types.sequence(color_list) orelse return error.TypeMismatch;
    const level_values = types.sequence(level_list) orelse return error.TypeMismatch;
    if (color_values.len != level_values.len) return error.InvalidStyle;
    const colors = try scratch.alloc(DisplayList.Color, color_values.len);
    for (color_values, colors) |value, *dest| dest.* = try conversions.color(self, value);
    const levels = try scratch.alloc(f64, level_values.len);
    for (level_values, levels) |value, *dest| dest.* = try numeric(value);
    return .{ .levels = levels, .colors = colors };
}
