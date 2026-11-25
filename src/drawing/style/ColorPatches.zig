//! Tensor-product Bézier patches with a color at each corner. Patch k maps
//! (u, v) in the unit square to the sum of `points[k][i * 4 + j]`
//! B_i(u) B_j(v), and its color there interpolates `colors[k]`, given at
//! (u, v) = (0, 0), (0, 1), (1, 1) and (1, 0), bilinearly in u and v: what
//! a PDF patch mesh with colors at its corners draws. Only the patches
//! paint, later ones over earlier ones. Every color is opaque: flattening
//! transparency makes these where two fields on the same patches combine.
const std = @import("std");
const g = @import("../geometry.zig");
const drawing_style = @import("../style.zig");
const bits = drawing_style.bits;
const Color = drawing_style.Color;
const ColorPatches = @This();

points: []const [16]g.Point,
colors: []const [4]Color,

pub fn validate(self: ColorPatches) error{ InvalidStyle, InvalidColor, NonFinite }!void {
    if (self.points.len == 0 or self.points.len != self.colors.len) return error.InvalidStyle;
    for (self.points) |patch| for (patch) |point| if (!point.isFinite()) return error.NonFinite;
    for (self.colors) |corners| for (corners) |color| if (!color.valid() or color.a != 1) return error.InvalidColor;
}

pub fn hash(self: ColorPatches, seed: u64) u64 {
    const hashBytes = std.hash.Wyhash.hash;
    return hashBytes(hashBytes(seed, bits(self.points)), bits(self.colors));
}

pub fn eql(a: ColorPatches, b: ColorPatches) bool {
    return std.mem.eql(u8, bits(a.points), bits(b.points)) and std.mem.eql(u8, bits(a.colors), bits(b.colors));
}

pub fn dupe(self: ColorPatches, allocator: std.mem.Allocator) !ColorPatches {
    const points = try allocator.dupe([16]g.Point, self.points);
    errdefer allocator.free(points);
    return .{ .points = points, .colors = try allocator.dupe([4]Color, self.colors) };
}

pub fn free(self: ColorPatches, allocator: std.mem.Allocator) void {
    allocator.free(self.points);
    allocator.free(self.colors);
}
