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
const Workers = @import("workers");
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Enclosure = enclosure.Enclosure;
const Rgba = enclosure.Rgba;

/// Color patches lowered to pieces whose colors lie along lines.
pub const scalar = @import("color_patches/scalar.zig");

pub const Error = error{ InvalidPatches, GeometryWorkLimit, OutOfMemory };
pub const ComposeError = Error || std.Io.Cancelable;

pub const ComposeOptions = struct {
    tolerance: f64,
    max_patches: usize,
    workers: Workers = .serial,
};

/// How often a piece may split.
pub const max_depth = 12;

/// Corner order of `ColorPatches.colors`: (u, v) = (0, 0), (0, 1), (1, 1),
/// (1, 0), and the indices of those corners in a net.
pub const corner_uv = [4][2]f64{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
pub const corner_index = [4]u8{ 0, 3, 15, 12 };

/// The net of a patch's restriction to [u0, u1] x [v0, v1]. Point i * 4 + j
/// weighs B_i(u) B_j(v).
pub fn subnet(net: *const [16]g.Point, u: [2]f64, v: [2]f64) [16]g.Point {
    if (u[0] == 0 and u[1] == 1 and v[0] == 0 and v[1] == 1) return net.*;
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

/// Colors at the corners of `nets`, within `options.tolerance` of a composite of
/// colorings of them: `combine.colorInto(comptime T, colors: []const Rgba(T),
/// out: *Rgba(T))` (or `combine.color(comptime T, colors: []const Rgba(T))
/// Rgba(T)`) gives the opaque color where the colorings have `colors`,
/// computed with T either `enclosure.Real` or `enclosure.Enclosure`, of
/// degree at most `enclosure.max_degree` in each parameter. Arrays are owned
/// by `allocator`.
pub fn compose(allocator: std.mem.Allocator, nets: []const [16]g.Point, colorings: []const Coloring, combine: anytype, options: ComposeOptions) ComposeError!Owned {
    var builder: Builder = .{ .allocator = allocator, .max_patches = options.max_patches };
    defer builder.deinit();
    try composeInto(&builder, nets, colorings, combine, options);
    return builder.finish();
}

/// Like `compose`, returning slices directly backed by `arena` without a
/// shrinking `toOwnedSlice` copy.
pub fn composeArena(arena: std.mem.Allocator, nets: []const [16]g.Point, colorings: []const Coloring, combine: anytype, options: ComposeOptions) ComposeError!Gradient.ColorPatches {
    var builder: Builder = .{ .allocator = arena, .max_patches = options.max_patches };
    try composeInto(&builder, nets, colorings, combine, options);
    return .{ .points = builder.points.items, .colors = builder.colors.items };
}

const min_parallel_chunk = 256;
const max_chunks = 32;

fn composeInto(builder: *Builder, nets: []const [16]g.Point, colorings: []const Coloring, combine: anytype, options: ComposeOptions) ComposeError!void {
    if (!(options.tolerance > 0) or colorings.len == 0 or colorings.len > max_colorings) return error.InvalidPatches;
    for (colorings) |coloring| switch (coloring) {
        .field => |field| if (field.values.len != nets.len) return error.InvalidPatches,
        .corners => |corners| if (corners.len != nets.len) return error.InvalidPatches,
    };
    if (nets.len > builder.max_patches) return error.GeometryWorkLimit;
    const chunk_count = options.workers.chunkCount(nets.len, min_parallel_chunk, max_chunks);
    if (chunk_count > 1) return composeParallel(builder, nets, colorings, combine, options, chunk_count);
    try builder.points.ensureUnusedCapacity(builder.allocator, nets.len);
    try builder.colors.ensureUnusedCapacity(builder.allocator, nets.len);
    try composeRange(builder, nets, 0, nets.len, colorings, combine, options.tolerance);
}

fn composeParallel(builder: *Builder, nets: []const [16]g.Point, colorings: []const Coloring, combine: anytype, options: ComposeOptions, chunk_count: usize) ComposeError!void {
    const Combine = @TypeOf(combine);
    const Chunk = struct {
        builder: Builder,
        err: ?Error = null,
    };
    const Shared = struct {
        chunks: []Chunk,
        nets: []const [16]g.Point,
        colorings: []const Coloring,
        combine: Combine,
        tolerance: f64,

        fn one(self: *@This(), index: usize) bool {
            const chunk = &self.chunks[index];
            const range = Workers.chunkRange(self.nets.len, self.chunks.len, index);
            chunk.builder.points.ensureUnusedCapacity(chunk.builder.allocator, range.end - range.start) catch |e| {
                chunk.err = e;
                return false;
            };
            chunk.builder.colors.ensureUnusedCapacity(chunk.builder.allocator, range.end - range.start) catch |e| {
                chunk.err = e;
                return false;
            };
            composeRange(&chunk.builder, self.nets, range.start, range.end, self.colorings, self.combine, self.tolerance) catch |e| {
                chunk.err = e;
                return false;
            };
            return true;
        }
    };
    var chunks: [max_chunks]Chunk = undefined;
    for (chunks[0..chunk_count]) |*chunk| {
        chunk.* = .{ .builder = .{ .allocator = std.heap.page_allocator, .max_patches = builder.max_patches } };
    }
    defer for (chunks[0..chunk_count]) |*chunk| chunk.builder.deinit();
    var shared: Shared = .{
        .chunks = chunks[0..chunk_count],
        .nets = nets,
        .colorings = colorings,
        .combine = combine,
        .tolerance = options.tolerance,
    };
    try options.workers.run(chunk_count, &shared, Shared.one);
    var total: usize = 0;
    for (chunks[0..chunk_count]) |*chunk| {
        if (chunk.err) |e| return e;
        total += chunk.builder.points.items.len;
        if (builder.points.items.len + total > builder.max_patches) return error.GeometryWorkLimit;
    }
    try builder.points.ensureUnusedCapacity(builder.allocator, total);
    try builder.colors.ensureUnusedCapacity(builder.allocator, total);
    for (chunks[0..chunk_count]) |*chunk| {
        builder.points.appendSliceAssumeCapacity(chunk.builder.points.items);
        builder.colors.appendSliceAssumeCapacity(chunk.builder.colors.items);
    }
}

fn composeRange(builder: *Builder, nets: []const [16]g.Point, start: usize, end: usize, colorings: []const Coloring, combine: anytype, tolerance: f64) Error!void {
    const Combine = @TypeOf(combine);
    const has_into = @hasDecl(Combine, "colorInto");
    const Piece = struct {
        builder: *Builder,
        net: *const [16]g.Point,
        colorings: []const Coloring,
        patch: usize,
        combine: Combine,
        tolerance: f64,

        fn values(self: *const @This(), field: []const [16]f64, u: [2]f64, v: [2]f64) [4]f64 {
            const whole = cornerValues(field[self.patch]);
            var result: [4]f64 = undefined;
            for (corner_uv, &result) |uv, *out| out.* = bilinear(whole, u[@intFromFloat(uv[0])], v[@intFromFloat(uv[1])]);
            return result;
        }
        fn colors(self: *const @This(), corners: []const [4]Color, u: [2]f64, v: [2]f64) [4]Color {
            var result: [4]Color = undefined;
            for (corner_uv, &result) |uv, *out| out.* = bilinearColor(corners[self.patch], u[@intFromFloat(uv[0])], v[@intFromFloat(uv[1])]);
            return result;
        }
        pub fn accept(self: *const @This(), u: [2]f64, v: [2]f64) Error!bool {
            var leaves: [max_colorings]Rgba(Enclosure) = undefined;
            for (self.colorings, leaves[0..self.colorings.len], 0..) |coloring, *leaf, index| switch (coloring) {
                .field => |field| encloseInto(field.stops, self.values(field.values, u, v), index, leaf),
                .corners => |corners| bilinearEnclosureInto(self.colors(corners, u, v), leaf),
            };
            var composite: Rgba(Enclosure) = undefined;
            if (has_into) {
                self.combine.colorInto(Enclosure, leaves[0..self.colorings.len], &composite);
            } else {
                composite = self.combine.color(Enclosure, leaves[0..self.colorings.len]);
            }
            return @max(composite.r.interpolationError(), composite.g.interpolationError(), composite.b.interpolationError()) <= self.tolerance;
        }
        pub fn emit(self: *const @This(), u: [2]f64, v: [2]f64) Error!void {
            var corners: [4][max_colorings]Rgba(Real) = undefined;
            for (self.colorings, 0..) |coloring, i| switch (coloring) {
                .field => |field| for (self.values(field.values, u, v), &corners) |value, *corner| {
                    enclosure.constantsInto(Real, field.stops.at(value), &corner[i]);
                },
                .corners => |given| for (self.colors(given, u, v), &corners) |color, *corner| {
                    enclosure.constantsInto(Real, color, &corner[i]);
                },
            };
            var result: [4]Color = undefined;
            for (&corners, &result) |*corner, *color| {
                var composite: Rgba(Real) = undefined;
                if (has_into) {
                    self.combine.colorInto(Real, corner[0..self.colorings.len], &composite);
                } else {
                    composite = self.combine.color(Real, corner[0..self.colorings.len]);
                }
                color.* = .{ .r = std.math.clamp(composite.r.value, 0, 1), .g = std.math.clamp(composite.g.value, 0, 1), .b = std.math.clamp(composite.b.value, 0, 1) };
            }
            try self.builder.add(subnet(self.net, u, v), result);
        }
    };
    for (nets[start..end], start..) |*net, k| {
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
        const piece: Piece = .{ .builder = builder, .net = net, .colorings = colorings, .patch = k, .combine = combine, .tolerance = tolerance };
        try subdivide(&piece, split, .{ 0, 1 }, .{ 0, 1 }, 0);
    }
}

fn setBilinearChannel(corners: [4]f64, out: *Enclosure) void {
    if (corners[0] == corners[1] and corners[0] == corners[2] and corners[0] == corners[3]) {
        out.setConstant(corners[0]);
    } else {
        out.setBilinear(corners);
    }
}

fn bilinearEnclosureInto(corners: [4]Color, out: *Rgba(Enclosure)) void {
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        setBilinearChannel(.{ @field(corners[0], channel), @field(corners[1], channel), @field(corners[2], channel), @field(corners[3], channel) }, &@field(out.*, channel));
    }
}

/// The color of a field with `values` at the corners of a piece: the chord
/// of `stops` across the values' range, which the values interpolated
/// bilinearly keep to, and in each channel the stops' distance from that
/// chord, which ranges between its least and greatest at the levels inside
/// the range. That distance is unknown 4 `index` + the channel's.
fn encloseInto(stops: Gradient.Stops, values: [4]f64, index: usize, out: *Rgba(Enclosure)) void {
    comptime std.debug.assert(4 * max_colorings <= enclosure.max_unknowns);
    const range: [2]f64 = .{ std.mem.min(f64, &values), std.mem.max(f64, &values) };
    const ends: [2]Color = .{ stops.at(range[0]), stops.at(range[1]) };
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
        const target = &@field(out.*, channel);
        setBilinearChannel(corners, target);
        if (below != 0 or above != 0) target.addUncertainty(4 * index + offset, below, above);
    }
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
    return compose(allocator, patches.points, &.{.{ .field = .{ .values = patches.values, .stops = patches.stops } }}, Itself{}, .{ .tolerance = tolerance, .max_patches = max_patches }) catch |err| switch (err) {
        error.Canceled => unreachable,
        else => |e| e,
    };
}

test {
    _ = @import("color_patches/compose_test.zig");
    _ = @import("color_patches/scalar_test.zig");
}
