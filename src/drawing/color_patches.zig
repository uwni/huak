//! Patches with a color at each corner (see `style.Gradient.ColorPatches`):
//! made from colorings of tensor-product Bézier patches, for outputs that
//! draw colors at patch corners but no color function, and lowered to fields
//! along lines in color space for outputs that draw only scalar fields.
//!
//! A coloring is a field colored by stops, or colors at the corners. A field
//! on a patch is taken as a PDF patch mesh draws it: its corner values
//! interpolated bilinearly in the patch's parameters. Colors at the corners,
//! interpolated the same way, follow a composite of colorings within the
//! tolerance where an enclosure of the composite says so (see
//! `enclosure.zig`). There a field's color is the chord of its stops across
//! the field's range on the piece, plus the stops' distance from that chord;
//! where a stop level falls inside the range, the distance shrinks with the
//! range.
//!
//! Splitting is in a patch's own parameters, in halves along each parameter
//! that something varies in, and exact: each piece is the restriction of the
//! patch's net, found by de Casteljau's algorithm. A piece never splits more
//! than `max_depth` times.
const std = @import("std");
const g = @import("geometry.zig");
const style = @import("style.zig");
const enclosure = @import("enclosure.zig");
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Enclosure = enclosure.Enclosure;
const Rgba = enclosure.Rgba;

/// Color patches lowered to pieces whose colors lie along lines.
pub const scalar = @import("color_patches/scalar.zig");

pub const Error = error{ InvalidPatches, GeometryWorkLimit, OutOfMemory };

/// How often a piece may split.
pub const max_depth = 12;

/// Corner order of `ColorPatches.colors`: (u, v) = (0, 0), (0, 1), (1, 1),
/// (1, 0), and the indices of those corners in a net.
pub const corner_uv = [4][2]f64{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
pub const corner_index = [4]u8{ 0, 3, 15, 12 };

/// The net of a patch's restriction to [u0, u1] x [v0, v1]. Point i * 4 + j
/// weighs B_i(u) B_j(v).
pub fn subnet(net: [16]g.Point, u: [2]f64, v: [2]f64) [16]g.Point {
    var across: [16]g.Point = undefined;
    for (0..4) |j| {
        const curve: g.Cubic = .{ .p0 = net[j], .p1 = net[4 + j], .p2 = net[8 + j], .p3 = net[12 + j] };
        const part = curve.trimmed(u[0], u[1]) catch unreachable;
        across[j] = part.p0;
        across[4 + j] = part.p1;
        across[8 + j] = part.p2;
        across[12 + j] = part.p3;
    }
    var result: [16]g.Point = undefined;
    for (0..4) |i| {
        const curve: g.Cubic = .{ .p0 = across[i * 4], .p1 = across[i * 4 + 1], .p2 = across[i * 4 + 2], .p3 = across[i * 4 + 3] };
        const part = curve.trimmed(v[0], v[1]) catch unreachable;
        result[i * 4] = part.p0;
        result[i * 4 + 1] = part.p1;
        result[i * 4 + 2] = part.p2;
        result[i * 4 + 3] = part.p3;
    }
    return result;
}

/// Bilinear interpolation of values at the corners, in `corner_uv` order.
pub fn bilinear(corners: [4]f64, u: f64, v: f64) f64 {
    return (1 - u) * (1 - v) * corners[0] + (1 - u) * v * corners[1] + u * v * corners[2] + u * (1 - v) * corners[3];
}

pub fn bilinearColor(corners: [4]Color, u: f64, v: f64) Color {
    var result: Color = .{};
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        @field(result, channel) = bilinear(.{ @field(corners[0], channel), @field(corners[1], channel), @field(corners[2], channel), @field(corners[3], channel) }, u, v);
    }
    return result;
}

/// The corner values of a field's coefficients.
pub fn cornerValues(values: [16]f64) [4]f64 {
    var result: [4]f64 = undefined;
    for (corner_index, &result) |index, *out| out.* = values[index];
    return result;
}

/// Owned arrays of color patches.
pub const Owned = struct {
    points: [][16]g.Point,
    colors: [][4]Color,

    pub fn deinit(self: Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.colors);
    }

    pub fn view(self: Owned) Gradient.ColorPatches {
        return .{ .points = self.points, .colors = self.colors };
    }
};

/// Collects pieces in order, within a budget.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayList([16]g.Point) = .empty,
    colors: std.ArrayList([4]Color) = .empty,
    max_patches: usize,

    pub fn deinit(self: *Builder) void {
        self.points.deinit(self.allocator);
        self.colors.deinit(self.allocator);
    }

    pub fn add(self: *Builder, net: [16]g.Point, colors: [4]Color) Error!void {
        if (self.points.items.len >= self.max_patches) return error.GeometryWorkLimit;
        try self.points.append(self.allocator, net);
        try self.colors.append(self.allocator, colors);
    }

    pub fn finish(self: *Builder) Error!Owned {
        const points = try self.points.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(points);
        return .{ .points = points, .colors = try self.colors.toOwnedSlice(self.allocator) };
    }
};

/// The parameters a piece varies in.
pub const Split = struct { u: bool, v: bool };

/// Whether values at the corners, in `corner_uv` order, vary in u and in v.
pub fn variation(comptime T: type, corners: [4]T) Split {
    const eql = std.meta.eql;
    return .{ .u = !eql(corners[0], corners[3]) or !eql(corners[1], corners[2]), .v = !eql(corners[0], corners[1]) or !eql(corners[3], corners[2]) };
}

/// Splits [u0, u1] x [v0, v1] of a patch until `context.accept(u, v)` holds,
/// in halves along each parameter in `split`, the ones the patch varies in,
/// and hands each accepted piece to `context.emit(u, v)`: in increasing v
/// and then u, the order in which a PDF patch mesh paints a patch.
pub fn subdivide(context: anytype, split: Split, u: [2]f64, v: [2]f64, depth: usize) Error!void {
    if (depth == max_depth or (!split.u and !split.v) or try context.accept(u, v)) return context.emit(u, v);
    const um = (u[0] + u[1]) / 2;
    const vm = (v[0] + v[1]) / 2;
    const us: []const [2]f64 = if (split.u) &.{ .{ u[0], um }, .{ um, u[1] } } else &.{u};
    const vs: []const [2]f64 = if (split.v) &.{ .{ v[0], vm }, .{ vm, v[1] } } else &.{v};
    for (vs) |part_v| for (us) |part_u| try subdivide(context, split, part_u, part_v, depth + 1);
}

/// What colors patches: a field colored by stops, with sixteen coefficients
/// for each patch, or colors at the corners of each, in `corner_uv` order.
pub const Coloring = union(enum) {
    field: struct { values: []const [16]f64, stops: Gradient.Stops },
    corners: []const [4]Color,
};

/// How many colorings `compose` combines.
pub const max_colorings = 4;

/// Colors at the corners of `nets`, within `tolerance` of a composite of
/// colorings of them: `combine.color(comptime T, colors: []const Rgba(T))
/// Rgba(T)` is the opaque color where the colorings have `colors`, computed
/// with T either `enclosure.Real` or `enclosure.Enclosure`, of degree at
/// most `enclosure.max_degree` in each parameter. Arrays are owned by
/// `allocator`.
pub fn compose(allocator: std.mem.Allocator, nets: []const [16]g.Point, colorings: []const Coloring, combine: anytype, tolerance: f64, max_patches: usize) Error!Owned {
    if (!(tolerance > 0) or colorings.len == 0 or colorings.len > max_colorings) return error.InvalidPatches;
    for (colorings) |coloring| switch (coloring) {
        .field => |field| if (field.values.len != nets.len) return error.InvalidPatches,
        .corners => |corners| if (corners.len != nets.len) return error.InvalidPatches,
    };
    var builder: Builder = .{ .allocator = allocator, .max_patches = max_patches };
    defer builder.deinit();
    for (nets, 0..) |net, k| {
        const Piece = struct {
            builder: *Builder,
            net: [16]g.Point,
            colorings: []const Coloring,
            patch: usize,
            combine: @TypeOf(combine),
            tolerance: f64,

            fn values(self: @This(), field: []const [16]f64, u: [2]f64, v: [2]f64) [4]f64 {
                const whole = cornerValues(field[self.patch]);
                var result: [4]f64 = undefined;
                for (corner_uv, &result) |uv, *out| out.* = bilinear(whole, u[@intFromFloat(uv[0])], v[@intFromFloat(uv[1])]);
                return result;
            }
            fn colors(self: @This(), corners: []const [4]Color, u: [2]f64, v: [2]f64) [4]Color {
                var result: [4]Color = undefined;
                for (corner_uv, &result) |uv, *out| out.* = bilinearColor(corners[self.patch], u[@intFromFloat(uv[0])], v[@intFromFloat(uv[1])]);
                return result;
            }
            pub fn accept(self: @This(), u: [2]f64, v: [2]f64) Error!bool {
                var leaves: [max_colorings]Rgba(Enclosure) = undefined;
                for (self.colorings, leaves[0..self.colorings.len], 0..) |coloring, *leaf, index| leaf.* = switch (coloring) {
                    .field => |field| enclose(field.stops, self.values(field.values, u, v), index),
                    .corners => |corners| bilinearEnclosure(self.colors(corners, u, v)),
                };
                const composite = self.combine.color(Enclosure, leaves[0..self.colorings.len]);
                return @max(composite.r.interpolationError(), composite.g.interpolationError(), composite.b.interpolationError()) <= self.tolerance;
            }
            pub fn emit(self: @This(), u: [2]f64, v: [2]f64) Error!void {
                var corners: [4][max_colorings]Rgba(Real) = undefined;
                for (self.colorings, 0..) |coloring, i| switch (coloring) {
                    .field => |field| for (self.values(field.values, u, v), &corners) |value, *corner| {
                        corner[i] = enclosure.constants(Real, field.stops.at(value));
                    },
                    .corners => |given| for (self.colors(given, u, v), &corners) |color, *corner| {
                        corner[i] = enclosure.constants(Real, color);
                    },
                };
                var result: [4]Color = undefined;
                for (&corners, &result) |*corner, *color| {
                    const composite = self.combine.color(Real, corner[0..self.colorings.len]);
                    color.* = .{ .r = std.math.clamp(composite.r.value, 0, 1), .g = std.math.clamp(composite.g.value, 0, 1), .b = std.math.clamp(composite.b.value, 0, 1) };
                }
                try self.builder.add(subnet(self.net, u, v), result);
            }
        };
        // Fields and colors are bilinear: a piece varies in a parameter only
        // where its patch does.
        var split: Split = .{ .u = false, .v = false };
        for (colorings) |coloring| {
            const varies = switch (coloring) {
                .field => |field| variation(f64, cornerValues(field.values[k])),
                .corners => |corners| variation(Color, corners[k]),
            };
            split = .{ .u = split.u or varies.u, .v = split.v or varies.v };
        }
        try subdivide(Piece{ .builder = &builder, .net = net, .colorings = colorings, .patch = k, .combine = combine, .tolerance = tolerance }, split, .{ 0, 1 }, .{ 0, 1 }, 0);
    }
    return builder.finish();
}

fn bilinearChannel(corners: [4]f64) Enclosure {
    if (corners[0] == corners[1] and corners[0] == corners[2] and corners[0] == corners[3]) return Enclosure.constant(corners[0]);
    return Enclosure.bilinear(corners);
}

fn bilinearEnclosure(corners: [4]Color) Rgba(Enclosure) {
    var result: Rgba(Enclosure) = undefined;
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        @field(result, channel) = bilinearChannel(.{ @field(corners[0], channel), @field(corners[1], channel), @field(corners[2], channel), @field(corners[3], channel) });
    }
    return result;
}

/// The color of a field with `values` at the corners of a piece: the chord
/// of `stops` across the values' range, which the values interpolated
/// bilinearly keep to, and in each channel the stops' distance from that
/// chord, which ranges between its least and greatest at the levels inside
/// the range. That distance is unknown 4 `index` + the channel's.
fn enclose(stops: Gradient.Stops, values: [4]f64, index: usize) Rgba(Enclosure) {
    comptime std.debug.assert(4 * max_colorings <= enclosure.max_unknowns);
    const range: [2]f64 = .{ std.mem.min(f64, &values), std.mem.max(f64, &values) };
    const ends: [2]Color = .{ stops.at(range[0]), stops.at(range[1]) };
    var result: Rgba(Enclosure) = undefined;
    inline for (.{ "r", "g", "b", "a" }, 0..) |channel, offset| {
        const chord: [2]f64 = .{ @field(ends[0], channel), @field(ends[1], channel) };
        var corners: [4]f64 = undefined;
        for (values, &corners) |value, *corner| corner.* = onChord(chord, range, value);
        var below: f64 = 0;
        var above: f64 = 0;
        for (stops.levels, stops.colors) |level, color| {
            if (!(level > range[0] and level < range[1])) continue;
            const off = @field(color, channel) - onChord(chord, range, level);
            below = @min(below, off);
            above = @max(above, off);
        }
        const base = bilinearChannel(corners);
        @field(result, channel) = if (below != 0 or above != 0) base.uncertain(4 * index + offset, below, above) else base;
    }
    return result;
}

/// Linear from chord[0] at range[0] to chord[1] at range[1].
fn onChord(chord: [2]f64, range: [2]f64, value: f64) f64 {
    if (!(range[1] > range[0])) return chord[0];
    return chord[0] + (chord[1] - chord[0]) * (value - range[0]) / (range[1] - range[0]);
}

/// An opaque field as colors at patch corners, within `tolerance` of its
/// stops. Arrays are owned by `allocator`.
pub fn fromField(allocator: std.mem.Allocator, patches: Gradient.Patches, tolerance: f64, max_patches: usize) Error!Owned {
    if (!patches.stops.isOpaque()) return error.InvalidPatches;
    const Itself = struct {
        pub fn color(_: @This(), comptime T: type, colors: []const Rgba(T)) Rgba(T) {
            return colors[0];
        }
    };
    return compose(allocator, patches.points, &.{.{ .field = .{ .values = patches.values, .stops = patches.stops } }}, Itself{}, tolerance, max_patches);
}

test {
    _ = @import("color_patches/compose_test.zig");
    _ = @import("color_patches/scalar_test.zig");
}
