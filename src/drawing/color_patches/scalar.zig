//! An output that draws scalar fields only takes each patch's colors as a
//! field along one line in color space. Where the corner colors lie farther
//! than the tolerance from every line through two of them, the patch splits
//! until they do not; bilinear colors keep to the line their corners are on.
const std = @import("std");
const g = @import("../geometry.zig");
const style = @import("../style.zig");
const Color = style.Color;
const Gradient = style.Gradient;
const color_patches = @import("../color_patches.zig");
const Error = color_patches.Error;
const corner_uv = color_patches.corner_uv;
const bilinearColor = color_patches.bilinearColor;
const bilinear = color_patches.bilinear;
const subnet = color_patches.subnet;
const subdivide = color_patches.subdivide;
const variation = color_patches.variation;

/// A piece of a color patch whose colors lie along `line`: the field `values`
/// goes from 0 at the line's first color to 1 at its second.
pub const Lined = struct {
    net: [16]g.Point,
    values: [16]f64,
    line: [2]Color,
};

fn distance(a: Color, b: Color) f64 {
    return @max(@max(@abs(a.r - b.r), @abs(a.g - b.g)), @max(@abs(a.b - b.b), @abs(a.a - b.a)));
}

/// The line through the two corner colors farthest apart, where along it
/// each corner lies, and how far the farthest corner lies off it.
fn fit(colors: [4]Color) struct { line: [2]Color, at: [4]f64, off: f64 } {
    var best: [2]usize = .{ 0, 0 };
    var spread: f64 = -1;
    for (0..4) |i| for (i + 1..4) |j| {
        const d = distance(colors[i], colors[j]);
        if (d > spread) {
            spread = d;
            best = .{ i, j };
        }
    };
    const a = colors[best[0]];
    const b = colors[best[1]];
    const axis: [4]f64 = .{ b.r - a.r, b.g - a.g, b.b - a.b, b.a - a.a };
    const squared = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2] + axis[3] * axis[3];
    var at: [4]f64 = @splat(0);
    var off: f64 = 0;
    for (colors, &at) |color, *s| {
        const offset: [4]f64 = .{ color.r - a.r, color.g - a.g, color.b - a.b, color.a - a.a };
        s.* = if (squared > 0) (offset[0] * axis[0] + offset[1] * axis[1] + offset[2] * axis[2] + offset[3] * axis[3]) / squared else 0;
        for (offset, axis) |o, x| off = @max(off, @abs(o - s.* * x));
    }
    return .{ .line = .{ a, b }, .at = at, .off = off };
}

/// Color patches as pieces whose colors lie along lines, within `tolerance`.
/// Pieces keep the order of their patches.
pub fn lines(allocator: std.mem.Allocator, patches: Gradient.ColorPatches, tolerance: f64, max_pieces: usize) Error![]Lined {
    if (!(tolerance > 0)) return error.InvalidPatches;
    var result: std.ArrayList(Lined) = .empty;
    errdefer result.deinit(allocator);
    for (patches.points, patches.colors) |net, colors| {
        const Piece = struct {
            allocator: std.mem.Allocator,
            result: *std.ArrayList(Lined),
            net: [16]g.Point,
            colors: [4]Color,
            tolerance: f64,
            max_pieces: usize,

            fn at(self: @This(), u: [2]f64, v: [2]f64) [4]Color {
                var result_: [4]Color = undefined;
                for (corner_uv, &result_) |uv, *out| out.* = bilinearColor(self.colors, u[@intFromFloat(uv[0])], v[@intFromFloat(uv[1])]);
                return result_;
            }
            pub fn accept(self: @This(), u: [2]f64, v: [2]f64) Error!bool {
                return fit(self.at(u, v)).off <= self.tolerance;
            }
            pub fn emit(self: @This(), u: [2]f64, v: [2]f64) Error!void {
                if (self.result.items.len >= self.max_pieces) return error.GeometryWorkLimit;
                const fitted = fit(self.at(u, v));
                // The field is bilinear: its coefficients are its values at
                // (i / 3, j / 3).
                var values: [16]f64 = undefined;
                for (0..4) |i| for (0..4) |j| {
                    values[i * 4 + j] = bilinear(fitted.at, @as(f64, @floatFromInt(i)) / 3, @as(f64, @floatFromInt(j)) / 3);
                };
                try self.result.append(self.allocator, .{ .net = subnet(self.net, u, v), .values = values, .line = fitted.line });
            }
        };
        try subdivide(Piece{ .allocator = allocator, .result = &result, .net = net, .colors = colors, .tolerance = tolerance, .max_pieces = max_pieces }, variation(Color, colors), .{ 0, 1 }, .{ 0, 1 }, 0);
    }
    return result.toOwnedSlice(allocator);
}
