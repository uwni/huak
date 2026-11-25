//! Builtins of the math namespace and vectors.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const types = @import("../types.zig");
const units = types.units;
const numeric_ops = @import("../numeric.zig");
const special = @import("special.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const conversions = @import("conversions.zig");
const angular = conversions.angular;
const number = conversions.number;
const numeric = conversions.numeric;

/// The math namespace and vectors.
pub fn invoke(comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .sin, .cos, .tan => {
            const x = try angular(arg.angle);
            return number(switch (id) {
                .sin => @sin(x),
                .cos => @cos(x),
                .tan => @tan(x),
                else => unreachable,
            });
        },
        .gamma, .lgamma => {
            const x = try numeric(arg.value);
            if (x <= 0 and x == @trunc(x)) return error.DomainError;
            return number(if (id == .gamma) std.math.gamma(f64, x) else std.math.lgamma(f64, x));
        },
        .beta => return number(try special.beta(try numeric(arg.a), try numeric(arg.b))),
        .erf => return number(special.erf(try numeric(arg.value))),
        .erfc => return number(special.erfc(try numeric(arg.value))),
        .sqrt, .abs => {
            var quantity = try types.asQuantity(arg.value);
            if (id == .sqrt) quantity = try units.squareRoot(quantity) else quantity.value = @abs(quantity.value);
            return types.fromQuantity(try quantity.checked());
        },
        .log, .log10 => {
            const x = try numeric(arg.value);
            if (x <= 0) return error.DomainError;
            return number(if (id == .log) @log(x) else @log10(x));
        },
        .floor, .ceil, .round => {
            const x = try numeric(arg.value);
            // Halves round away from zero, as Typst's calc.round does.
            return number(switch (id) {
                .floor => @floor(x),
                .ceil => @ceil(x),
                else => @round(x),
            });
        },
        .min, .max, .pow, .atan2 => {
            const first, const second = switch (id) {
                .pow => .{ arg.base, arg.exponent },
                .atan2 => .{ arg.y, arg.x },
                else => .{ arg.a, arg.b },
            };
            const x = try types.asQuantity(first);
            const y = try types.asQuantity(second);
            if (id == .pow) return types.fromQuantity(try units.arithmetic(.power, x, y));
            const order = try units.compare(x, y);
            if (id == .atan2) return .{ .quantity = .{ .value = std.math.atan2(x.value, y.value), .dimension = .rotation } };
            return if ((id == .min and order != .gt) or (id == .max and order != .lt)) first else second;
        },
        .vec2 => return numeric_ops.makeVec2(arg.x, arg.y),
        .vec3 => return numeric_ops.makeVector(3, .{ arg.x, arg.y, arg.z }),
        .dot, .norm, .unit => switch (if (id == .dot) arg.a else arg.value) {
            inline .vec2, .vec3 => |v, tag| {
                if (!v.isFinite()) return error.NonFinite;
                if (id == .dot) {
                    if (arg.b != tag) return error.TypeMismatch;
                    const w = @field(arg.b, @tagName(tag));
                    const dot = v.x * w.x + v.y * w.y + (if (tag == .vec3) v.z * w.z else 0);
                    return types.fromQuantity(try (units.Quantity{ .value = dot, .dimension = try v.dimension.combine(w.dimension, false) }).checked());
                }
                if (id == .norm) {
                    const xy = std.math.hypot(v.x, v.y);
                    return types.fromQuantity(try (units.Quantity{ .value = if (tag == .vec3) std.math.hypot(xy, v.z) else xy, .dimension = v.dimension }).checked());
                }
                if (tag == .vec2) {
                    const n = try (g.Point{ .x = v.x, .y = v.y }).normalized();
                    return .{ .vec2 = .{ .x = n.x, .y = n.y } };
                } else {
                    const max = @max(@abs(v.x), @abs(v.y), @abs(v.z));
                    if (max == 0) return error.ZeroVector;
                    const n: types.Vec3 = .{ .x = v.x / max, .y = v.y / max, .z = v.z / max };
                    return .{ .vec3 = n.scale(1 / std.math.hypot(std.math.hypot(n.x, n.y), n.z)) };
                }
            },
            else => return error.TypeMismatch,
        },
        .lerp => {
            const difference = try numeric_ops.valueArithmetic(.subtract, arg.b, arg.a);
            return numeric_ops.valueArithmetic(.add, arg.a, try numeric_ops.valueArithmetic(.multiply, difference, arg.t));
        },
        else => comptime unreachable,
    }
}
