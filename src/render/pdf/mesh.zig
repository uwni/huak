//! Encodes one mesh paint, with its exact curved clip, as a one-page PDF.
//! Typst has no mesh paint, so the Typst adapter imports this page through
//! libtypst and places it over `bounds`; Typst's exporter still writes the
//! final document. The page is the unit square holding a Type 4 free-form
//! Gouraud shading. Vertex alpha becomes a luminosity soft mask over the same
//! triangles. Geometry and colors come from the caller, not from lighting.
const std = @import("std");
const flate = std.compress.flate;
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const Mesh = @import("../../drawing/style.zig").Gradient.Mesh;

const Segment = typst.c.TypstPathSegment;

pub const Encoded = struct {
    /// The complete PDF, owned by the allocator passed to `encode`.
    pdf: []u8,
    /// Extent of the mesh vertices; the page's unit square maps onto it.
    bounds: g.BBox,
};

/// Inputs are borrowed for the call.
pub fn encode(allocator: std.mem.Allocator, mesh: Mesh, clip: []const Segment, evenodd: bool) !Encoded {
    const bounds = try vertexBounds(mesh);
    if (clip.len == 0) return error.InvalidPath;
    const unit: Unit = .{ .origin = bounds.min, .size = bounds.max.sub(bounds.min) };
    const transparent = for (mesh.vertices) |vertex| {
        if (vertex.a != 1) break true;
    } else false;
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    writeContent(&content.writer, clip, unit, evenodd, transparent) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
    const color = try shading(allocator, mesh, unit, .rgb);
    defer allocator.free(color);
    const alpha: ?[]u8 = if (transparent) try shading(allocator, mesh, unit, .alpha) else null;
    defer if (alpha) |bytes| allocator.free(bytes);
    return .{ .pdf = try document(allocator, content.written(), color, alpha), .bounds = bounds };
}

/// Storage validates stored paints the same way; `encode` is also usable alone.
fn vertexBounds(mesh: Mesh) !g.BBox {
    if (mesh.vertices.len < 3 or mesh.triangles.len == 0) return error.InvalidMesh;
    for (mesh.triangles) |triangle| for (triangle) |index| {
        if (index >= mesh.vertices.len) return error.InvalidMesh;
    };
    var bounds: g.BBox = .fromPoint(.{ .x = mesh.vertices[0].x, .y = mesh.vertices[0].y });
    for (mesh.vertices) |vertex| {
        const point: g.Point = .{ .x = vertex.x, .y = vertex.y };
        if (!point.isFinite() or !vertex.color().valid()) return error.InvalidMesh;
        bounds = bounds.include(point);
    }
    const size = bounds.max.sub(bounds.min);
    if (!size.isFinite() or size.x <= 0 or size.y <= 0) return error.InvalidMesh;
    return bounds;
}

/// Maps scene coordinates onto the page's unit square.
const Unit = struct {
    origin: g.Point,
    size: g.Point,

    fn x(self: Unit, value: f64) f64 {
        return (value - self.origin.x) / self.size.x;
    }
    fn y(self: Unit, value: f64) f64 {
        return (value - self.origin.y) / self.size.y;
    }
};

/// Clips to the exact path, then paints the shading through the alpha mask.
fn writeContent(w: *std.Io.Writer, clip: []const Segment, unit: Unit, evenodd: bool, transparent: bool) !void {
    const Operator = struct { name: []const u8, points: usize };
    for (clip, 0..) |segment, index| {
        const operator: Operator = switch (segment.kind) {
            typst.c.TYPST_SEGMENT_MOVE => .{ .name = "m", .points = 1 },
            typst.c.TYPST_SEGMENT_LINE => .{ .name = "l", .points = 1 },
            typst.c.TYPST_SEGMENT_CUBIC => .{ .name = "c", .points = 3 },
            typst.c.TYPST_SEGMENT_CLOSE => .{ .name = "h", .points = 0 },
            else => return error.InvalidPath,
        };
        if (index != 0) try w.writeByte('\n');
        const points = [3]typst.c.TypstPoint{ segment.p1, segment.p2, segment.p3 };
        for (points[0..operator.points]) |point| {
            try real(w, unit.x(point.x));
            try w.writeByte(' ');
            try real(w, unit.y(point.y));
            try w.writeByte(' ');
        }
        try w.writeAll(operator.name);
    }
    try w.writeAll(if (evenodd) "\nW*\nn" else "\nW\nn");
    if (transparent) try w.writeAll("\n/Alpha gs");
    try w.writeAll("\n/Color sh");
}

/// PDF reals have no exponent form, and readers keep single precision.
/// Integral values print as integers; others as the shortest decimal that
/// round-trips through binary32.
fn real(w: *std.Io.Writer, value: f64) !void {
    const single: f32 = @floatCast(value);
    if (!std.math.isFinite(single)) return error.InvalidPath;
    if (@trunc(single) == single and @abs(single) < 0x1p31) {
        try w.print("{d}", .{@as(i32, @intFromFloat(single))});
    } else try w.print("{d}", .{single});
}

const Channel = enum { rgb, alpha };

/// Every triangle corner is an independent record with flag 0; deflate
/// recovers the repetition of shared vertices. Records stream straight into
/// the compressor, so the uncompressed mesh is never held in memory.
fn shading(allocator: std.mem.Allocator, mesh: Mesh, unit: Unit, channel: Channel) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 1 << 16);
    errdefer output.deinit();
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    // The compressor's tables take about 224 KiB; keep them off the stack.
    const deflate = try allocator.create(flate.Compress);
    defer allocator.destroy(deflate);
    // Measured on the lighting replay mesh: level 4 is both faster and smaller
    // than levels 3 and 5 to 7 for these fixed 15- and 11-byte records.
    deflate.* = flate.Compress.init(&output.writer, window, .zlib, .level_4) catch return error.OutOfMemory;
    for (mesh.triangles) |triangle| for (triangle) |index| {
        const vertex = mesh.vertices[index];
        var record: [15]u8 = undefined;
        record[0] = 0;
        std.mem.writeInt(u32, record[1..5], quantize(u32, unit.x(vertex.x)), .big);
        std.mem.writeInt(u32, record[5..9], quantize(u32, unit.y(vertex.y)), .big);
        const length: usize = switch (channel) {
            .rgb => length: {
                for ([3]f64{ vertex.r, vertex.g, vertex.b }, 0..) |component, i| {
                    std.mem.writeInt(u16, record[9 + 2 * i ..][0..2], quantize(u16, component), .big);
                }
                break :length 15;
            },
            .alpha => length: {
                std.mem.writeInt(u16, record[9..11], quantize(u16, vertex.a), .big);
                break :length 11;
            },
        };
        deflate.writer.writeAll(record[0..length]) catch return error.OutOfMemory;
    };
    deflate.finish() catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

/// `value` lies in [0, 1].
fn quantize(comptime T: type, value: f64) T {
    return @intFromFloat(@round(value * std.math.maxInt(T)));
}

fn document(allocator: std.mem.Allocator, content: []const u8, color: []const u8, alpha: ?[]const u8) ![]u8 {
    const streams = content.len + color.len + if (alpha) |bytes| bytes.len else 0;
    var pdf = try std.Io.Writer.Allocating.initCapacity(allocator, streams + 2048);
    errdefer pdf.deinit();
    writeDocument(&pdf, content, color, alpha) catch return error.OutOfMemory;
    return pdf.toOwnedSlice();
}

const color_mesh = "/ShadingType 4/ColorSpace/DeviceRGB/BitsPerCoordinate 32/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1 0 1 0 1]/Filter/FlateDecode";
const alpha_mesh = "/ShadingType 4/ColorSpace/DeviceGray/BitsPerCoordinate 32/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1]/Filter/FlateDecode";
const page = "<</Type/Page/Parent 2 0 R/MediaBox[0 0 1 1]/Contents 4 0 R/Resources<</Shading<</Color 5 0 R>>";

fn writeDocument(pdf: *std.Io.Writer.Allocating, content: []const u8, color: []const u8, alpha: ?[]const u8) std.Io.Writer.Error!void {
    var objects: Objects = .{ .pdf = pdf };
    // Type 4 shading needs PDF 1.3; luminosity soft masks need PDF 1.4.
    try pdf.writer.writeAll("%PDF-1.4\n%\x80\x80\x80\x80\n\n");
    try objects.dictionary("<</Type/Catalog/Pages 2 0 R>>");
    try objects.dictionary("<</Type/Pages/Kids[3 0 R]/Count 1>>");
    try objects.dictionary(if (alpha != null) page ++ "/ExtGState<</Alpha 8 0 R>>>>>>" else page ++ ">>>>");
    try objects.stream("", content);
    try objects.stream(color_mesh, color);
    if (alpha) |bytes| {
        try objects.stream(alpha_mesh, bytes);
        try objects.stream("/Type/XObject/Subtype/Form/BBox[0 0 1 1]/Resources<</Shading<</Alpha 6 0 R>>>>/Group<</Type/Group/S/Transparency/CS/DeviceGray>>", "/Alpha sh");
        try objects.dictionary("<</Type/ExtGState/SMask<</Type/Mask/S/Luminosity/G 7 0 R>>>>");
    }
    const xref = pdf.written().len;
    try pdf.writer.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{objects.count + 1});
    for (objects.offsets[0..objects.count]) |offset| try pdf.writer.print("{d:0>10} 00000 n\r\n", .{offset});
    try pdf.writer.print("trailer\n<</Size {d}/Root 1 0 R>>\nstartxref\n{d}\n%%EOF", .{ objects.count + 1, xref });
}

/// Numbers objects consecutively from 1 and records each offset for the
/// cross-reference table.
const Objects = struct {
    pdf: *std.Io.Writer.Allocating,
    offsets: [8]usize = undefined,
    count: usize = 0,

    fn begin(self: *Objects) std.Io.Writer.Error!void {
        self.offsets[self.count] = self.pdf.written().len;
        self.count += 1;
        try self.pdf.writer.print("{d} 0 obj\n", .{self.count});
    }

    fn dictionary(self: *Objects, text: []const u8) std.Io.Writer.Error!void {
        try self.begin();
        try self.pdf.writer.writeAll(text);
        try self.pdf.writer.writeAll("\nendobj\n\n");
    }

    /// `entries` are the dictionary's keys other than /Length.
    fn stream(self: *Objects, entries: []const u8, data: []const u8) std.Io.Writer.Error!void {
        try self.begin();
        try self.pdf.writer.print("<<{s}/Length {d}>>\nstream\n", .{ entries, data.len });
        try self.pdf.writer.writeAll(data);
        try self.pdf.writer.writeAll("\nendstream\nendobj\n\n");
    }
};

const testing = std.testing;

fn square(points: [4][2]f64) [5]Segment {
    var segments: [5]Segment = @splat(std.mem.zeroes(Segment));
    for (points, segments[0..4], 0..) |p, *segment, i| {
        segment.kind = if (i == 0) typst.c.TYPST_SEGMENT_MOVE else typst.c.TYPST_SEGMENT_LINE;
        segment.p1 = .{ .x = p[0], .y = p[1] };
    }
    segments[4].kind = typst.c.TYPST_SEGMENT_CLOSE;
    return segments;
}

const corners = [_]Mesh.Vertex{
    .{ .x = 10, .y = 20, .r = 1, .g = 0, .b = 0 },
    .{ .x = 30, .y = 20, .r = 0, .g = 1, .b = 0, .a = 0.5 },
    .{ .x = 10, .y = 60, .r = 0, .g = 0, .b = 1, .a = 0 },
};
const one_triangle = [_][3]u32{.{ 0, 1, 2 }};

/// The object's stream data, found by its /Length.
fn streamOf(pdf: []const u8, id: u8) ![]const u8 {
    var header: [16]u8 = undefined;
    const start = std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&header, "\n{d} 0 obj\n", .{id})) orelse return error.MissingObject;
    const object = pdf[start..];
    const length_at = (std.mem.indexOf(u8, object, "/Length ") orelse return error.MissingLength) + "/Length ".len;
    const length_end = std.mem.indexOfScalarPos(u8, object, length_at, '>') orelse return error.MissingLength;
    const length = try std.fmt.parseInt(usize, object[length_at..length_end], 10);
    const data = (std.mem.indexOf(u8, object, ">>\nstream\n") orelse return error.MissingStream) + ">>\nstream\n".len;
    try testing.expectEqualStrings("\nendstream", object[data + length ..][0.."\nendstream".len]);
    return object[data..][0..length];
}

fn inflate(compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress: flate.Decompress = .init(&input, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    _ = try decompress.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

test "mesh records, clip and soft mask form a self-consistent PDF" {
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const encoded = try encode(testing.allocator, .{ .vertices = &corners, .triangles = &one_triangle }, &clip, true);
    defer testing.allocator.free(encoded.pdf);
    const pdf = encoded.pdf;
    try testing.expectEqualDeep(g.BBox{ .min = .{ .x = 10, .y = 20 }, .max = .{ .x = 30, .y = 60 } }, encoded.bounds);
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW*\nn\n/Alpha gs\n/Color sh", try streamOf(pdf, 4));

    const color = try inflate(try streamOf(pdf, 5));
    defer testing.allocator.free(color);
    try testing.expectEqual(3 * 15, color.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 }, color[0..15]);
    try testing.expectEqualSlices(u8, &.{ 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0 }, color[15..30]);
    const alpha = try inflate(try streamOf(pdf, 6));
    defer testing.allocator.free(alpha);
    try testing.expectEqual(3 * 11, alpha.len);
    // Alpha records reuse the flag and coordinates of the color records.
    for (0..3) |i| try testing.expectEqualSlices(u8, color[i * 15 ..][0..9], alpha[i * 11 ..][0..9]);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x80, 0x00, 0, 0 }, &.{ alpha[9], alpha[10], alpha[20], alpha[21], alpha[31], alpha[32] });

    // Every cross-reference entry addresses its object.
    const xref = std.mem.lastIndexOf(u8, pdf, "xref\n0 9\n") orelse return error.MissingXref;
    var trailer: [40]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&trailer, "startxref\n{d}\n%%EOF", .{xref}), pdf[std.mem.lastIndexOf(u8, pdf, "startxref").?..]);
    var entries = std.mem.splitSequence(u8, pdf[xref + "xref\n0 9\n".len ..], "\r\n");
    try testing.expectEqualStrings("0000000000 65535 f", entries.next().?);
    for (1..9) |id| {
        const entry = entries.next().?;
        const offset = try std.fmt.parseInt(usize, entry[0..10], 10);
        var header: [16]u8 = undefined;
        try testing.expect(std.mem.startsWith(u8, pdf[offset..], try std.fmt.bufPrint(&header, "{d} 0 obj\n", .{id})));
    }
}

test "opaque meshes and curved nonzero clips need no soft mask" {
    var opaque_corners = corners;
    for (&opaque_corners) |*vertex| vertex.a = 1;
    var clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    clip[2] = .{ .kind = typst.c.TYPST_SEGMENT_CUBIC, .reserved = 0, .p1 = .{ .x = 40, .y = 30 }, .p2 = .{ .x = 10 + 20.0 / 3.0, .y = 70 }, .p3 = .{ .x = 30, .y = 60 } };
    const encoded = try encode(testing.allocator, .{ .vertices = &opaque_corners, .triangles = &one_triangle }, &clip, false);
    defer testing.allocator.free(encoded.pdf);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1.5 0.25 0.33333334 1.25 1 1 c\n0 1 l\nh\nW\nn\n/Color sh", try streamOf(encoded.pdf, 4));
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "/SMask") == null);
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "xref\n0 6\n") != null);
}

test "invalid meshes and clips are rejected before any output" {
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const mesh: Mesh = .{ .vertices = &corners, .triangles = &one_triangle };
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, .{ .vertices = corners[0..2], .triangles = &one_triangle }, &clip, false));
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, .{ .vertices = &corners, .triangles = &.{.{ 0, 1, 3 }} }, &clip, false));
    var flat = corners;
    flat[2].y = 20;
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, .{ .vertices = &flat, .triangles = &one_triangle }, &clip, false));
    var dim = corners;
    dim[1].g = 1.5;
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, .{ .vertices = &dim, .triangles = &one_triangle }, &clip, false));
    try testing.expectError(error.InvalidPath, encode(testing.allocator, mesh, &.{}, false));
    var far = clip;
    far[1].p1.x = 1e300;
    try testing.expectError(error.InvalidPath, encode(testing.allocator, mesh, &far, false));
    var unknown = clip;
    unknown[3].kind = 99;
    try testing.expectError(error.InvalidPath, encode(testing.allocator, mesh, &unknown, false));
}

fn encodeAndRelease(allocator: std.mem.Allocator, clip: []const Segment) !void {
    const encoded = try encode(allocator, .{ .vertices = &corners, .triangles = &one_triangle }, clip, false);
    allocator.free(encoded.pdf);
}

test "every failed allocation releases the partial encoding" {
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    try testing.checkAllAllocationFailures(testing.allocator, encodeAndRelease, .{@as([]const Segment, &clip)});
}
