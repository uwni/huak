//! Type 7 mesh records: their layout, shared-edge flags, quantization and deflate streaming.
const std = @import("std");
const flate = std.compress.flate;
const g = @import("../../../drawing/geometry.zig");
const style = @import("../../../drawing/style.zig");
const Gradient = style.Gradient;
const Color = style.Color;
const Patches = Gradient.Patches;
const color_patches = @import("../../../drawing/color_patches.zig");
const syntax = @import("../syntax.zig");
const Workspace = syntax.Workspace;
/// Corners in record order, p00, p03, p33, p30: the order in which color
/// patches give their colors.
const corner_order = color_patches.corner_index;
const testing = std.testing;
const mesh = @import("../mesh.zig");
const fixtures = @import("fixtures.zig");
const Unit = mesh.Unit;
const square = fixtures.square;
const affinePatch = fixtures.affinePatch;
const encodeColors = mesh.encodeColors;
const streamOf = fixtures.streamOf;
const inflate = fixtures.inflate;
const encode = mesh.encode;

/// Bytes of a record: a flag, sixteen 24-bit coordinate pairs and four
/// corners of 16-bit components, one for a gray value and three for a
/// color. A record that shares an edge with the previous one leaves out that
/// edge's four points and two corners.
fn recordSize(comptime Corner: type) usize {
    return 1 + 16 * 6 + 4 * @sizeOf(Corner);
}

pub const patch_record = recordSize(u16);

pub const color_record = recordSize([3]u16);

/// Control points in the order a type 7 record lists them: p00 p01 p02 p03
/// p13 p23 p33 p32 p31 p30 p20 p10 p11 p12 p22 p21, where pij is index
/// i * 4 + j. The first twelve run around the boundary.
const stream_order = [16]u8{ 0, 1, 2, 3, 7, 11, 15, 14, 13, 12, 8, 4, 5, 6, 10, 9 };

/// A patch as its record encodes it: control points by index i * 4 + j, and
/// corner values or colors in record order.
pub fn Record(comptime Corner: type) type {
    return struct {
        points: [16][2]u24,
        corners: [4]Corner,
    };
}

const Quantized = Record(u16);

/// The edges of the previous patch that flags 1 and 2 name, as point indices
/// from its p00 p01 p02 p03 boundary order and corner slots: the boundary
/// from its fourth and seventh point on. A record with that flag starts with
/// the edge, so its p00 to p03 and first two corner values are those. Flag 3,
/// the edge from p30 back to p00, is valid PDF too, but Quartz (macOS Preview
/// and Quick Look) draws such records with holes, so it is never written.
const shared_edges = [2]struct { points: [4]u8, corners: [2]u8 }{
    .{ .points = .{ 3, 7, 11, 15 }, .corners = .{ 1, 2 } },
    .{ .points = .{ 15, 14, 13, 12 }, .corners = .{ 2, 3 } },
};

/// The eight ways to lay a patch's control net over its parameter square;
/// each describes the same surface and field. Entry k is the index in the
/// original net of the point at index k.
const orientations: [8][16]u8 = table: {
    var result: [8][16]u8 = undefined;
    for (&result, 0..) |*map, o| for (0..4) |i| for (0..4) |j| {
        var row = if (o >= 4) j else i;
        var column = if (o >= 4) i else j;
        if (o & 1 != 0) row = 3 - row;
        if (o & 2 != 0) column = 3 - column;
        map[i * 4 + j] = row * 4 + column;
    };
    break :table result;
};

fn quantized(patch: *const [16]g.Point, field: *const [16]f64, unit: Unit, range: [2]f64) Quantized {
    var result: Quantized = undefined;
    for (patch, &result.points) |point, *out| out.* = .{ quantize(u24, unit.x(point.x)), quantize(u24, unit.y(point.y)) };
    for (corner_order, &result.corners) |index, *out| out.* = quantize(u16, (field[index] - range[0]) / (range[1] - range[0]));
    return result;
}

/// The corner slot of a corner's point index.
fn slot(index: u8) usize {
    return std.mem.indexOfScalar(u8, &corner_order, index).?;
}

/// `next` laid out to begin with an edge it shares with `last`, and the
/// flag naming that edge; null when they share none. The comparison is of
/// the encoded values, so a shared edge decodes exactly as written in full.
fn join(comptime Corner: type, last: *const Record(Corner), next: *const Record(Corner)) ?struct { flag: u8, patch: Record(Corner) } {
    for (orientations) |map| for (shared_edges, 1..) |edge, flag| {
        const same = for (0..4) |k| {
            if (!std.mem.eql(u24, &next.points[map[k]], &last.points[edge.points[k]])) break false;
        } else std.meta.eql(next.corners[slot(map[0])], last.corners[edge.corners[0]]) and std.meta.eql(next.corners[slot(map[3])], last.corners[edge.corners[1]]);
        if (!same) continue;
        var patch: Record(Corner) = undefined;
        for (&patch.points, map) |*point, index| point.* = next.points[index];
        for (&patch.corners, corner_order) |*value, index| value.* = next.corners[slot(map[index])];
        return .{ .flag = @intCast(flag), .patch = patch };
    };
    return null;
}

/// Field patches stream straight into the PDF as gray records.
pub fn compressPatches(workspace: *Workspace, out: *std.Io.Writer, patches: Patches, unit: Unit, range: [2]f64) std.Io.Writer.Error!void {
    const Fields = struct {
        patches: Patches,
        unit: Unit,
        range: [2]f64,
        pub fn record(self: @This(), index: usize) Quantized {
            return quantized(&self.patches.points[index], &self.patches.values[index], self.unit, self.range);
        }
    };
    try compressRecords(u16, workspace, out, patches.points.len, Fields{ .patches = patches, .unit = unit, .range = range });
}

/// Records stream straight into the PDF, `source.record(index)` for each
/// index below `count`. A patch sharing an edge with the one before it, as
/// neighbours in a grid usually do, names that edge with a flag instead of
/// repeating it.
pub fn compressRecords(comptime Corner: type, workspace: *Workspace, out: *std.Io.Writer, count: usize, source: anytype) std.Io.Writer.Error!void {
    workspace.deflate = try flate.Compress.init(out, &workspace.window, .zlib, .level_4);
    const deflate = &workspace.deflate;
    const components = @sizeOf(Corner) / 2;
    var previous: ?Record(Corner) = null;
    for (0..count) |index| {
        const native = source.record(index);
        const joined = if (previous) |*last| join(Corner, last, &native) else null;
        const written = if (joined) |shared| shared.patch else native;
        // A flag leaves out the first edge: four points and two corners.
        const skip: usize = if (joined != null) 4 else 0;
        var record: [recordSize(Corner)]u8 = undefined;
        record[0] = if (joined) |shared| shared.flag else 0;
        var at: usize = 1;
        for (stream_order[skip..]) |point| for (written.points[point]) |coordinate| {
            std.mem.writeInt(u24, record[at..][0..3], coordinate, .big);
            at += 3;
        };
        for (written.corners[skip / 2 ..]) |corner| {
            const values: [components]u16 = @bitCast(corner);
            for (values) |value| {
                std.mem.writeInt(u16, record[at..][0..2], value, .big);
                at += 2;
            }
        }
        try deflate.writer.writeAll(record[0..at]);
        previous = written;
    }
    try deflate.finish();
}

/// `value` lies in [0, 1] up to rounding.
pub fn quantize(comptime T: type, value: f64) T {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * std.math.maxInt(T)));
}

test "colors at patch corners make one RGB mesh without a function or a soft mask" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    const corners = [4]Color{ .{ .r = 1 }, .{ .g = 1 }, .{ .b = 1 }, .{ .r = 1, .g = 1, .b = 1 } };
    const encoded = try encodeColors(testing.allocator, workspace, .{ .points = &.{patch.points}, .colors = &.{corners} }, &clip, true);
    defer testing.allocator.free(encoded.pdf);
    const pdf = encoded.pdf;
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.3\n"));
    try testing.expectEqualDeep(g.BBox{ .min = .{ .x = 10, .y = 20 }, .max = .{ .x = 30, .y = 60 } }, encoded.bounds);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW*\nn\n/Mesh sh", try streamOf(pdf, 4));
    try testing.expect(std.mem.indexOf(u8, pdf, "5 0 obj\n<</ShadingType 7/ColorSpace/DeviceRGB/BitsPerCoordinate 24/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1 0 1 0 1]/Filter/FlateDecode/Length ") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/SMask") == null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Function") == null);
    try testing.expect(std.mem.indexOf(u8, pdf, "xref\n0 6\n") != null);
    const records = try inflate(try streamOf(pdf, 5));
    defer testing.allocator.free(records);
    try testing.expectEqual(color_record, records.len);
    // After the flag and sixteen points, the corners p00, p03, p33, p30.
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, records[97..]);
    try testing.expectError(error.InvalidMesh, encodeColors(testing.allocator, workspace, .{ .points = &.{patch.points}, .colors = &.{.{ .{ .a = 0.5 }, .{}, .{}, .{} }} }, &clip, true));
}

test "a patch sharing an edge with the previous one names it with a flag" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    // Two patches stacked in y over [10, 30] x [20, 40] and [10, 30] x
    // [40, 60], meeting along y = 40; a third, apart from them, last. The
    // field is u, that is x, throughout.
    var points: [3][16]g.Point = undefined;
    var values: [3][16]f64 = undefined;
    for (&points, &values, [3]f64{ 20, 40, 20 }, [3]f64{ 10, 10, 100 }) |*patch, *field, y, x| for (0..4) |i| for (0..4) |j| {
        patch[i * 4 + j] = .{ .x = x + 20 * @as(f64, @floatFromInt(i)) / 3, .y = y + 20 * @as(f64, @floatFromInt(j)) / 3 };
        field[i * 4 + j] = @as(f64, @floatFromInt(i)) / 3;
    };
    const patches: Patches = .{ .points = &points, .values = &values, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .b = 1 } } }, .tolerance = 0.01 };
    const encoded = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(encoded.pdf);
    const records = try inflate(try streamOf(encoded.pdf, 5));
    defer testing.allocator.free(records);
    const shared = 1 + 12 * 6 + 2 * 2;
    try testing.expectEqual(patch_record + shared + patch_record, records.len);
    try testing.expectEqual(@as(u8, 0), records[0]);
    try testing.expectEqual(@as(u8, 0), records[patch_record + shared]);
    // The first patch's top edge, p03 p13 p23 p33, is flag 1's edge; the
    // second patch starts with it, its net transposed, so its p0j is the
    // original pj0 and its p33 and p30 values the original's at p33 and p03.
    const second = records[patch_record..][0..shared];
    try testing.expectEqual(@as(u8, 1), second[0]);
    const unit: Unit = .{ .origin = encoded.bounds.min, .size = encoded.bounds.max.sub(encoded.bounds.min) };
    for (stream_order[4..], 0..) |index, k| {
        const original = points[1][(index % 4) * 4 + index / 4];
        try testing.expectEqual(quantize(u24, unit.x(original.x)), std.mem.readInt(u24, second[1 + 6 * k ..][0..3], .big));
        try testing.expectEqual(quantize(u24, unit.y(original.y)), std.mem.readInt(u24, second[4 + 6 * k ..][0..3], .big));
    }
    try testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, second[73..75], .big));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, second[75..77], .big));
}

test "a patch meeting the previous one only on the edge flag 3 names is written in full" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 0 }, .{ 30, 0 }, .{ 30, 40 }, .{ 10, 40 } });
    // The first patch over [10, 30] x [20, 40], the second below it over
    // [10, 30] x [0, 20]: they meet along the first one's p00 p10 p20 p30,
    // the edge only flag 3 could name. The field is u, that is x.
    var points: [2][16]g.Point = undefined;
    var values: [2][16]f64 = undefined;
    for (&points, &values, [2]f64{ 20, 0 }) |*patch, *field, y| for (0..4) |i| for (0..4) |j| {
        patch[i * 4 + j] = .{ .x = 10 + 20 * @as(f64, @floatFromInt(i)) / 3, .y = y + 20 * @as(f64, @floatFromInt(j)) / 3 };
        field[i * 4 + j] = @as(f64, @floatFromInt(i)) / 3;
    };
    const patches: Patches = .{ .points = &points, .values = &values, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .b = 1 } } }, .tolerance = 0.01 };
    const encoded = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(encoded.pdf);
    const records = try inflate(try streamOf(encoded.pdf, 5));
    defer testing.allocator.free(records);
    try testing.expectEqual(2 * patch_record, records.len);
    try testing.expectEqual(@as(u8, 0), records[0]);
    try testing.expectEqual(@as(u8, 0), records[patch_record]);
}
