//! What the PDF encoders of this directory share: number syntax, the object
//! table, path construction and the deflate state for streams.
const std = @import("std");
const flate = std.compress.flate;
const typst = @import("libtypst");

pub const Segment = typst.c.TypstPathSegment;

/// Deflate state for every stream one caller encodes, about 288 KiB. Allocate
/// it once per document and use it from one thread at a time.
pub const Workspace = struct {
    deflate: flate.Compress,
    window: [flate.max_window_len]u8,
};

/// PDF reals have no exponent form, and readers keep single precision.
/// Integral values print as integers; others as the shortest decimal that
/// round-trips through binary32.
pub fn real(w: *std.Io.Writer, value: f64) !void {
    const single: f32 = @floatCast(value);
    if (!std.math.isFinite(single)) return error.InvalidPath;
    if (@trunc(single) == single and @abs(single) < 0x1p31) {
        try w.print("{d}", .{@as(i32, @intFromFloat(single))});
    } else try w.print("{d}", .{single});
}

/// Path construction operators for `segments`, one a line. `map` gives the
/// coordinates to write: it has `x(f64) f64` and `y(f64) f64`.
pub fn path(w: *std.Io.Writer, segments: []const Segment, map: anytype) !void {
    const Operator = struct { name: []const u8, points: usize };
    for (segments, 0..) |segment, index| {
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
            try real(w, map.x(point.x));
            try w.writeByte(' ');
            try real(w, map.y(point.y));
            try w.writeByte(' ');
        }
        try w.writeAll(operator.name);
    }
}

/// Numbers objects consecutively from 1 and records each offset for the
/// cross-reference table. The caller supplies room for one offset an object.
pub const Objects = struct {
    pdf: *std.Io.Writer.Allocating,
    offsets: []usize,
    count: usize = 0,

    /// Wide enough for any usize; unused digits remain spaces.
    const length_width = 20;
    pub const Stream = struct { length_at: usize, data_at: usize, length: usize = 0 };

    pub fn begin(self: *Objects) std.Io.Writer.Error!void {
        self.offsets[self.count] = self.pdf.written().len;
        self.count += 1;
        try self.pdf.writer.print("{d} 0 obj\n", .{self.count});
    }

    pub fn dictionary(self: *Objects, text: []const u8) std.Io.Writer.Error!void {
        try self.begin();
        try self.end(text);
    }

    /// Finishes an object begun with `begin` with its remaining text.
    pub fn end(self: *Objects, text: []const u8) std.Io.Writer.Error!void {
        try self.pdf.writer.writeAll(text);
        try self.pdf.writer.writeAll("\nendobj\n\n");
    }

    /// Opens a stream object's dictionary: write its keys other than /Length,
    /// then call `data`.
    pub fn open(self: *Objects) std.Io.Writer.Error!void {
        try self.begin();
        try self.pdf.writer.writeAll("<<");
    }

    /// Closes the dictionary. `endStream` fills in /Length once the data
    /// written in between is complete.
    pub fn data(self: *Objects) std.Io.Writer.Error!Stream {
        try self.pdf.writer.writeAll("/Length ");
        const length_at = self.pdf.written().len;
        try self.pdf.writer.splatByteAll(' ', length_width);
        try self.pdf.writer.writeAll(">>\nstream\n");
        return .{ .length_at = length_at, .data_at = self.pdf.written().len };
    }

    pub fn beginStream(self: *Objects, entries: []const u8) std.Io.Writer.Error!Stream {
        try self.open();
        try self.pdf.writer.writeAll(entries);
        return self.data();
    }

    pub fn endStream(self: *Objects, stream: *Stream) std.Io.Writer.Error!void {
        const written = self.pdf.written();
        stream.length = written.len - stream.data_at;
        _ = std.fmt.bufPrint(written[stream.length_at..][0..length_width], "{d}", .{stream.length}) catch unreachable;
        try self.pdf.writer.writeAll("\nendstream\nendobj\n\n");
    }

    /// The cross-reference table and trailer, after the last object.
    pub fn finish(self: *Objects) std.Io.Writer.Error!void {
        const w = &self.pdf.writer;
        const xref = self.pdf.written().len;
        try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{self.count + 1});
        for (self.offsets[0..self.count]) |offset| try w.print("{d:0>10} 00000 n\r\n", .{offset});
        try w.print("trailer\n<</Size {d}/Root 1 0 R>>\nstartxref\n{d}\n%%EOF", .{ self.count + 1, xref });
    }
};
