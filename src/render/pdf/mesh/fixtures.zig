//! Patches, streams and colors shared by the mesh tests.
const std = @import("std");
const flate = std.compress.flate;
const typst = @import("libtypst");
const g = @import("../../../drawing/geometry.zig");
const style = @import("../../../drawing/style.zig");
const Gradient = style.Gradient;
const syntax = @import("../syntax.zig");
const Segment = syntax.Segment;
const testing = std.testing;

pub fn square(points: [4][2]f64) [5]Segment {
    var segments: [5]Segment = @splat(std.mem.zeroes(Segment));
    for (points, segments[0..4], 0..) |p, *segment, i| {
        segment.kind = if (i == 0) typst.c.TYPST_SEGMENT_MOVE else typst.c.TYPST_SEGMENT_LINE;
        segment.p1 = .{ .x = p[0], .y = p[1] };
    }
    segments[4].kind = typst.c.TYPST_SEGMENT_CLOSE;
    return segments;
}

/// The object's stream data, found by its /Length.
pub fn streamOf(pdf: []const u8, id: u8) ![]const u8 {
    var header: [16]u8 = undefined;
    const start = std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&header, "\n{d} 0 obj\n", .{id})) orelse return error.MissingObject;
    const object = pdf[start..];
    const length_at = (std.mem.indexOf(u8, object, "/Length ") orelse return error.MissingLength) + "/Length ".len;
    const length_end = std.mem.indexOfScalarPos(u8, object, length_at, '>') orelse return error.MissingLength;
    const length = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, object[length_at..length_end], " "), 10);
    const data = (std.mem.indexOf(u8, object, ">>\nstream\n") orelse return error.MissingStream) + ">>\nstream\n".len;
    try testing.expectEqualStrings("\nendstream", object[data + length ..][0.."\nendstream".len]);
    return object[data..][0..length];
}

pub fn inflate(compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress: flate.Decompress = .init(&input, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    _ = try decompress.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

/// Red, half-transparent green and blue along the field.
pub const rainbow: Gradient.Stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1 }, .{ .g = 1, .a = 0.5 }, .{ .b = 1 } } };

/// One patch mapping the unit square onto [10, 30] x [20, 60], with the
/// field u from 0 to 1.
pub fn affinePatch() struct { points: [16]g.Point, values: [16]f64 } {
    var points: [16]g.Point = undefined;
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        points[i * 4 + j] = .{ .x = 10 + 20 * u, .y = 20 + 40 * @as(f64, @floatFromInt(j)) / 3 };
        values[i * 4 + j] = u;
    };
    return .{ .points = points, .values = values };
}
