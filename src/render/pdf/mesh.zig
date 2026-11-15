//! Encodes one patch paint, with its exact curved clip, as a one-page PDF.
//! Typst has no patch paint, so the Typst adapter imports this page through
//! libtypst and places it over `bounds`; Typst's exporter still writes the
//! final document. The page is the unit square. One Type 7 tensor-product
//! patch mesh carries the field itself as gray levels, and the stops apply
//! through luminosity soft masks of that mesh whose transfer functions are
//! piecewise linear in the field (see `Plan`). A shading /Function would say
//! the same directly, but Quartz (macOS Preview and Quick Look) draws no
//! type 6 or 7 shading that has one. Geometry and colors come from the
//! caller, not from lighting.
const std = @import("std");
const flate = std.compress.flate;
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const style = @import("../../drawing/style.zig");
const Gradient = style.Gradient;
const Color = style.Color;
const Patches = Gradient.Patches;

const Segment = typst.c.TypstPathSegment;

/// Deflate state for every stream one caller encodes, about 288 KiB. Allocate
/// it once per document and use it from one thread at a time.
pub const Workspace = struct {
    deflate: flate.Compress,
    window: [flate.max_window_len]u8,
};

pub const Encoded = struct {
    /// The complete PDF, owned by the allocator passed to `encode`.
    pdf: []u8,
    /// Extent of the control points; the page's unit square maps onto it.
    bounds: g.BBox,
};

/// Inputs are borrowed for the call. Objects and compressed streams go
/// straight into the returned buffer, which is the only allocation.
pub fn encode(allocator: std.mem.Allocator, workspace: *Workspace, patches: Patches, clip: []const Segment, evenodd: bool) !Encoded {
    const bounds = try controlBounds(patches);
    if (clip.len == 0) return error.InvalidPath;
    const plan: Plan = .of(patches.stops, valueRange(patches));
    var pdf = try std.Io.Writer.Allocating.initCapacity(allocator, capacityHint(patches, clip.len));
    errdefer pdf.deinit();
    const unit: Unit = .{ .origin = bounds.min, .size = bounds.max.sub(bounds.min) };
    writeDocument(&pdf, workspace, patches, clip, unit, evenodd, plan) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
    return .{ .pdf = try pdf.toOwnedSlice(), .bounds = bounds };
}

/// How the page paints the stops over the field's range. The colors build
/// up in layers: a fill with the base stop's color, then for each ramp of
/// `Ramps`, a fill with the color of its upper stop whose weight rises from
/// 0 at its lower stop's level to 1 at its own. Laid in order, these are
/// exactly the stops' linear interpolation. Stops at or below the low end
/// fold into the base.
///
/// Outside the patches every mask reads gray 0, the low end of the range.
/// Unless the opacity there is zero, a coverage mask, the alpha of the mesh
/// itself, keeps the paint to the patches.
const Plan = struct {
    stops: Gradient.Stops,
    /// The field's range: gray 0 to 1 on the mesh.
    range: [2]f64,
    /// The stop whose color the base fill has.
    base: usize,
    /// How many ramps lay a fill over the base.
    layers: usize,
    opacity: union(enum) { constant: f64, varying },
    coverage: bool,

    fn of(stops: Gradient.Stops, range: [2]f64) Plan {
        var plan: Plan = .{ .stops = stops, .range = range, .base = 0, .layers = 0, .opacity = .varying, .coverage = false };
        for (stops.levels, 0..) |level, index| {
            if (level <= range[0]) plan.base = index;
        }
        var each = plan.ramps();
        while (each.next()) |_| plan.layers += 1;
        const low = stops.at(range[0]).a;
        var constant = stops.at(range[1]).a == low;
        for (stops.levels, stops.colors) |level, color| {
            if (level > range[0] and level < range[1] and color.a != low) constant = false;
        }
        if (constant) plan.opacity = .{ .constant = low };
        plan.coverage = low > 0;
        return plan;
    }

    fn ramps(self: *const Plan) Ramps {
        return .{ .stops = self.stops, .high = self.range[1], .from = self.base };
    }
};

/// The color layers, as pairs of stops: each ramp runs from one stop to a
/// later one, and the next ramp starts where it ends. A ramp passes over the
/// stops whose colors lie on its straight line, up to rounding, since they
/// change nothing; it adds no layer when its ends have the same color, and
/// ramps starting at or above the field's high end add nothing.
const Ramps = struct {
    stops: Gradient.Stops,
    high: f64,
    from: usize,

    fn next(self: *Ramps) ?[2]usize {
        const levels = self.stops.levels;
        const colors = self.stops.colors;
        while (self.from + 1 < levels.len and levels[self.from] < self.high) {
            const from = self.from;
            var to = from + 1;
            while (to + 1 < levels.len and onLine(self.stops, from, to + 1)) to += 1;
            self.from = to;
            const a = colors[from];
            const b = colors[to];
            if (a.r != b.r or a.g != b.g or a.b != b.b) return .{ from, to };
        }
        return null;
    }
};

/// Whether every stop strictly between `from` and `to` has the color that
/// linear interpolation between them gives, to well below the precision the
/// page writes.
fn onLine(stops: Gradient.Stops, from: usize, to: usize) bool {
    const levels = stops.levels;
    const a = stops.colors[from];
    const b = stops.colors[to];
    for (from + 1..to) |index| {
        const s = (levels[index] - levels[from]) / (levels[to] - levels[from]);
        const c = stops.colors[index];
        const off = @max(@abs(c.r - (a.r + s * (b.r - a.r))), @abs(c.g - (a.g + s * (b.g - a.g))), @abs(c.b - (a.b + s * (b.b - a.b))));
        if (!(off <= 1e-12)) return false;
    }
    return true;
}

/// A sizing hint, not a bound: patch records deflate to roughly half their
/// size, and each stop adds at most a few hundred bytes of transfer
/// functions. A short hint grows the buffer; the excess is trimmed.
fn capacityHint(patches: Patches, segments: usize) usize {
    return 2048 +| segments *| 96 +| patches.points.len *| patch_record / 2 +| patches.stops.levels.len *| 400;
}

/// Storage validates stored paints the same way; `encode` is also usable
/// alone. A patch lies within the hull of its control points.
fn controlBounds(patches: Patches) !g.BBox {
    patches.validate() catch return error.InvalidMesh;
    var bounds: g.BBox = .fromPoint(patches.points[0][0]);
    for (patches.points) |patch| for (patch) |point| {
        bounds = bounds.include(point);
    };
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

/// Objects in writing order: catalog, pages, page, content, then the mesh
/// (5) and the mask group that paints it (6), which every soft mask reads.
/// The form of the color layers and the form that nests the opacity mask
/// under the coverage mask follow where the plan has them.
fn writeDocument(pdf: *std.Io.Writer.Allocating, workspace: *Workspace, patches: Patches, clip: []const Segment, unit: Unit, evenodd: bool, plan: Plan) !void {
    const w = &pdf.writer;
    var objects: Objects = .{ .pdf = pdf };
    var next: usize = 7;
    const color_id = if (plan.layers != 0) take(&next) else 0;
    const nested_id = if (plan.coverage and plan.opacity == .varying) take(&next) else 0;
    // Type 7 shadings need PDF 1.3; soft masks need PDF 1.4.
    try w.writeAll("%PDF-1.4\n%\x80\x80\x80\x80\n\n");
    try objects.dictionary("<</Type/Catalog/Pages 2 0 R>>");
    try objects.dictionary("<</Type/Pages/Kids[3 0 R]/Count 1>>");
    try objects.begin();
    try w.writeAll("<</Type/Page/Parent 2 0 R/MediaBox[0 0 1 1]/Contents 4 0 R/Resources<</ExtGState<<");
    try if (plan.coverage) writeCoverage(w, plan) else writeOpacity(w, plan);
    try w.writeAll(">>");
    if (nested_id != 0) {
        try w.print("/XObject<</Masked {d} 0 R>>", .{nested_id});
    } else if (color_id != 0) try w.print("/XObject<</Color {d} 0 R>>", .{color_id});
    try objects.end(">>>>");
    var content = try objects.beginStream("");
    try writeContent(w, clip, unit, evenodd, plan);
    try objects.endStream(&content);
    var mesh = try objects.beginStream("/ShadingType 7/ColorSpace/DeviceGray/BitsPerCoordinate 24/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1]/Filter/FlateDecode");
    try compressPatches(workspace, w, patches, unit, plan.range);
    try objects.endStream(&mesh);
    var group = try objects.beginStream("/Type/XObject/Subtype/Form/BBox[0 0 1 1]/Group<</Type/Group/S/Transparency/CS/DeviceGray>>/Resources<</Shading<</Field 5 0 R>>>>");
    try w.writeAll("/Field sh");
    try objects.endStream(&group);
    if (color_id != 0) {
        try objects.open();
        try w.writeAll("/Type/XObject/Subtype/Form/BBox[0 0 1 1]/Group<</Type/Group/S/Transparency/CS/DeviceRGB>>/Resources<</ExtGState<<");
        const levels = plan.stops.levels;
        var ramps = plan.ramps();
        while (ramps.next()) |ramp| {
            try w.print("/Ramp{d}<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR", .{ramp[1]});
            try writeTransfer(w, .{ .ramp = .{ levels[ramp[0]], levels[ramp[1]] } }, plan.range);
            try w.writeAll(">>>>");
        }
        try w.writeAll(">>>>");
        var layers = try objects.data();
        try fill(w, plan.stops.colors[plan.base]);
        ramps = plan.ramps();
        while (ramps.next()) |ramp| {
            try w.print("\nq\n/Ramp{d} gs\n", .{ramp[1]});
            try fill(w, plan.stops.colors[ramp[1]]);
            try w.writeAll("\nQ");
        }
        try objects.endStream(&layers);
    }
    if (nested_id != 0) {
        try objects.open();
        try w.writeAll("/Type/XObject/Subtype/Form/BBox[0 0 1 1]/Group<</Type/Group/S/Transparency>>/Resources<</ExtGState<<");
        try writeOpacity(w, plan);
        try w.writeAll(">>");
        if (color_id != 0) try w.print("/XObject<</Color {d} 0 R>>", .{color_id});
        try w.writeAll(">>");
        var masked = try objects.data();
        try w.writeAll("/Opacity gs");
        try writePaint(w, plan);
        try objects.endStream(&masked);
    }
    const xref = pdf.written().len;
    try w.print("xref\n0 {d}\n0000000000 65535 f\r\n", .{objects.count + 1});
    for (objects.offsets[0..objects.count]) |offset| try w.print("{d:0>10} 00000 n\r\n", .{offset});
    try w.print("trailer\n<</Size {d}/Root 1 0 R>>\nstartxref\n{d}\n%%EOF", .{ objects.count + 1, xref });
}

fn take(next: *usize) usize {
    next.* += 1;
    return next.* - 1;
}

/// Numbers objects consecutively from 1 and records each offset for the
/// cross-reference table.
const Objects = struct {
    pdf: *std.Io.Writer.Allocating,
    offsets: [8]usize = undefined,
    count: usize = 0,

    /// Wide enough for any usize; unused digits remain spaces.
    const length_width = 20;
    const Stream = struct { length_at: usize, data_at: usize, length: usize = 0 };

    fn begin(self: *Objects) std.Io.Writer.Error!void {
        self.offsets[self.count] = self.pdf.written().len;
        self.count += 1;
        try self.pdf.writer.print("{d} 0 obj\n", .{self.count});
    }

    fn dictionary(self: *Objects, text: []const u8) std.Io.Writer.Error!void {
        try self.begin();
        try self.end(text);
    }

    /// Finishes an object begun with `begin` with its remaining text.
    fn end(self: *Objects, text: []const u8) std.Io.Writer.Error!void {
        try self.pdf.writer.writeAll(text);
        try self.pdf.writer.writeAll("\nendobj\n\n");
    }

    /// Opens a stream object's dictionary: write its keys other than /Length,
    /// then call `data`.
    fn open(self: *Objects) std.Io.Writer.Error!void {
        try self.begin();
        try self.pdf.writer.writeAll("<<");
    }

    /// Closes the dictionary. `endStream` fills in /Length once the data
    /// written in between is complete.
    fn data(self: *Objects) std.Io.Writer.Error!Stream {
        try self.pdf.writer.writeAll("/Length ");
        const length_at = self.pdf.written().len;
        try self.pdf.writer.splatByteAll(' ', length_width);
        try self.pdf.writer.writeAll(">>\nstream\n");
        return .{ .length_at = length_at, .data_at = self.pdf.written().len };
    }

    fn beginStream(self: *Objects, entries: []const u8) std.Io.Writer.Error!Stream {
        try self.open();
        try self.pdf.writer.writeAll(entries);
        return self.data();
    }

    fn endStream(self: *Objects, stream: *Stream) std.Io.Writer.Error!void {
        const written = self.pdf.written();
        stream.length = written.len - stream.data_at;
        _ = std.fmt.bufPrint(written[stream.length_at..][0..length_width], "{d}", .{stream.length}) catch unreachable;
        try self.pdf.writer.writeAll("\nendstream\nendobj\n\n");
    }
};

/// Clips to the exact path, then paints the plan through its masks.
fn writeContent(w: *std.Io.Writer, clip: []const Segment, unit: Unit, evenodd: bool, plan: Plan) !void {
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
    if (plan.coverage) {
        try w.writeAll("\n/Coverage gs");
        // A soft mask applies to a group as a whole; inside it, the
        // opacity mask can take over the state.
        if (plan.opacity == .varying) return w.writeAll("\n/Masked Do");
    } else try w.writeAll("\n/Opacity gs");
    try writePaint(w, plan);
}

/// The colors: the form of the layers, or the base fill alone.
fn writePaint(w: *std.Io.Writer, plan: Plan) !void {
    if (plan.layers != 0) return w.writeAll("\n/Color Do");
    try w.writeByte('\n');
    try fill(w, plan.stops.colors[plan.base]);
}

/// Fills the page square with one color.
fn fill(w: *std.Io.Writer, color: Color) !void {
    for ([3]f64{ color.r, color.g, color.b }) |component| {
        try real(w, component);
        try w.writeByte(' ');
    }
    try w.writeAll("rg\n0 0 1 1 re\nf");
}

/// The alpha of the mesh's own group, 1 on the patches and 0 elsewhere,
/// with a constant opacity.
fn writeCoverage(w: *std.Io.Writer, plan: Plan) !void {
    try w.writeAll("/Coverage<</SMask<</Type/Mask/S/Alpha/G 6 0 R>>");
    switch (plan.opacity) {
        .constant => |opacity| if (opacity != 1) {
            try w.writeAll("/ca ");
            try real(w, opacity);
        },
        .varying => {},
    }
    try w.writeAll(">>");
}

/// The stops' opacity: a luminosity mask of the mesh when it varies.
fn writeOpacity(w: *std.Io.Writer, plan: Plan) !void {
    try w.writeAll("/Opacity<<");
    switch (plan.opacity) {
        .constant => |opacity| {
            try w.writeAll("/ca ");
            try real(w, opacity);
        },
        .varying => {
            try w.writeAll("/SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR");
            try writeTransfer(w, .{ .opacity = plan.stops }, plan.range);
            try w.writeAll(">>");
        },
    }
    try w.writeAll(">>");
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

/// The field's range over the corners, which bound the bilinear field the
/// mesh interpolates; never empty.
fn valueRange(patches: Patches) [2]f64 {
    var low: f64 = std.math.inf(f64);
    var high: f64 = -std.math.inf(f64);
    for (patches.values) |field| for (corner_order) |index| {
        low = @min(low, field[index]);
        high = @max(high, field[index]);
    };
    if (!(high > low)) high = low + 1;
    return .{ low, high };
}

/// A function of the field through values at levels, linear between them
/// and flat beyond: the stops' opacity, or a layer's weight, which rises
/// from 0 at the first level to 1 at the second.
const Profile = union(enum) {
    opacity: Gradient.Stops,
    ramp: [2]f64,

    fn len(self: Profile) usize {
        return switch (self) {
            .opacity => |stops| stops.levels.len,
            .ramp => 2,
        };
    }

    fn level(self: Profile, index: usize) f64 {
        return switch (self) {
            .opacity => |stops| stops.levels[index],
            .ramp => |levels| levels[index],
        };
    }

    fn value(self: Profile, index: usize) f64 {
        return switch (self) {
            .opacity => |stops| stops.colors[index].a,
            .ramp => @floatFromInt(index),
        };
    }

    fn at(self: Profile, field: f64) f64 {
        return switch (self) {
            .opacity => |stops| stops.at(field).a,
            .ramp => |levels| std.math.clamp((field - levels[0]) / (levels[1] - levels[0]), 0, 1),
        };
    }
};

/// A knot of a transfer function: gray level `x`, as written, and value.
const Knot = struct { x: f32, y: f64 };

/// The pieces of a profile on the mask's gray scale, from the field's range
/// onto [0, 1], between knots at both ends and at every level strictly
/// inside. Knots that coincide in single precision bound no piece; the value
/// jumps there.
const Pieces = struct {
    profile: Profile,
    range: [2]f64,
    /// The next knot: 0 is the low end, 1 + i level i, 1 + len the high end.
    index: usize = 0,
    last: ?Knot = null,

    fn knot(self: *Pieces) ?Knot {
        const count = self.profile.len();
        while (self.index <= count + 1) {
            const index = self.index;
            self.index += 1;
            if (index == 0) return .{ .x = 0, .y = self.profile.at(self.range[0]) };
            if (index == count + 1) return .{ .x = 1, .y = self.profile.at(self.range[1]) };
            const level = self.profile.level(index - 1);
            if (!(level > self.range[0] and level < self.range[1])) continue;
            return .{ .x = @floatCast((level - self.range[0]) / (self.range[1] - self.range[0])), .y = self.profile.value(index - 1) };
        }
        return null;
    }

    fn next(self: *Pieces) ?[2]Knot {
        while (self.knot()) |current| {
            const previous = self.last;
            self.last = current;
            if (previous) |start| if (start.x < current.x) return .{ start, current };
        }
        return null;
    }
};

/// The profile as a soft mask's transfer function: a stitching (type 3)
/// function of linear (type 2) pieces over the gray levels.
fn writeTransfer(w: *std.Io.Writer, profile: Profile, range: [2]f64) !void {
    try w.writeAll("<</FunctionType 3/Domain[0 1]/Functions[");
    var pieces: Pieces = .{ .profile = profile, .range = range };
    var count: usize = 0;
    while (pieces.next()) |piece| : (count += 1) {
        try w.writeAll("<</FunctionType 2/Domain[0 1]/C0[");
        try real(w, piece[0].y);
        try w.writeAll("]/C1[");
        try real(w, piece[1].y);
        try w.writeAll("]/N 1>>");
    }
    // Every piece after the first starts at a bound.
    try w.writeAll("]/Bounds[");
    pieces = .{ .profile = profile, .range = range };
    var index: usize = 0;
    while (pieces.next()) |piece| : (index += 1) {
        if (index == 0) continue;
        if (index != 1) try w.writeByte(' ');
        try real(w, piece[0].x);
    }
    try w.writeAll("]/Encode[");
    for (0..count) |k| try w.writeAll(if (k == 0) "0 1" else " 0 1");
    try w.writeAll("]>>");
}

/// Bytes of a patch record: a flag, sixteen 24-bit coordinate pairs and four
/// 16-bit corner values. A record that shares an edge with the previous one
/// leaves out that edge's four points and two values.
const patch_record = 1 + 16 * 6 + 4 * 2;
/// Control points in the order a type 7 record lists them: p00 p01 p02 p03
/// p13 p23 p33 p32 p31 p30 p20 p10 p11 p12 p22 p21, where pij is index
/// i * 4 + j. The first twelve run around the boundary.
const stream_order = [16]u8{ 0, 1, 2, 3, 7, 11, 15, 14, 13, 12, 8, 4, 5, 6, 10, 9 };
/// Corner values in record order: p00, p03, p33, p30.
const corner_order = [4]u8{ 0, 3, 15, 12 };

/// A patch as its record encodes it: control points by index i * 4 + j, and
/// corner values in record order.
const Quantized = struct {
    points: [16][2]u24,
    corners: [4]u16,
};

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

fn quantized(patch: [16]g.Point, field: [16]f64, unit: Unit, range: [2]f64) Quantized {
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
fn join(last: Quantized, next: Quantized) ?struct { flag: u8, patch: Quantized } {
    for (orientations) |map| for (shared_edges, 1..) |edge, flag| {
        const same = for (0..4) |k| {
            if (!std.mem.eql(u24, &next.points[map[k]], &last.points[edge.points[k]])) break false;
        } else next.corners[slot(map[0])] == last.corners[edge.corners[0]] and next.corners[slot(map[3])] == last.corners[edge.corners[1]];
        if (!same) continue;
        var patch: Quantized = undefined;
        for (&patch.points, map) |*point, index| point.* = next.points[index];
        for (&patch.corners, corner_order) |*value, index| value.* = next.corners[slot(map[index])];
        return .{ .flag = @intCast(flag), .patch = patch };
    };
    return null;
}

/// Patches stream straight into the PDF. A patch sharing an edge with the
/// one before it, as neighbours in a grid usually do, names that edge with
/// a flag instead of repeating it.
fn compressPatches(workspace: *Workspace, out: *std.Io.Writer, patches: Patches, unit: Unit, range: [2]f64) std.Io.Writer.Error!void {
    workspace.deflate = try flate.Compress.init(out, &workspace.window, .zlib, .level_4);
    const deflate = &workspace.deflate;
    var previous: ?Quantized = null;
    for (patches.points, patches.values) |patch, field| {
        const native = quantized(patch, field, unit, range);
        const joined = if (previous) |last| join(last, native) else null;
        const written = if (joined) |shared| shared.patch else native;
        // A flag leaves out the first edge: four points and two values.
        const skip: usize = if (joined != null) 4 else 0;
        var record: [patch_record]u8 = undefined;
        record[0] = if (joined) |shared| shared.flag else 0;
        var at: usize = 1;
        for (stream_order[skip..]) |index| for (written.points[index]) |coordinate| {
            std.mem.writeInt(u24, record[at..][0..3], coordinate, .big);
            at += 3;
        };
        for (written.corners[skip / 2 ..]) |value| {
            std.mem.writeInt(u16, record[at..][0..2], value, .big);
            at += 2;
        }
        try deflate.writer.writeAll(record[0..at]);
        previous = written;
    }
    try deflate.finish();
}

/// `value` lies in [0, 1] up to rounding.
fn quantize(comptime T: type, value: f64) T {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * std.math.maxInt(T)));
}

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

/// The object's stream data, found by its /Length.
fn streamOf(pdf: []const u8, id: u8) ![]const u8 {
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

fn inflate(compressed: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(compressed);
    var decompress: flate.Decompress = .init(&input, .zlib, &.{});
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer output.deinit();
    _ = try decompress.reader.streamRemaining(&output.writer);
    return output.toOwnedSlice();
}

test "opaque patches paint through their coverage inside an exact curved clip" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    var clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    clip[2] = .{ .kind = typst.c.TYPST_SEGMENT_CUBIC, .reserved = 0, .p1 = .{ .x = 40, .y = 30 }, .p2 = .{ .x = 10 + 20.0 / 3.0, .y = 70 }, .p3 = .{ .x = 30, .y = 60 } };
    const patch = affinePatch();
    const patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1 }, .{ .b = 1 } } }, .tolerance = 0.01 };
    const encoded = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(encoded.pdf);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1.5 0.25 0.33333334 1.25 1 1 c\n0 1 l\nh\nW\nn\n/Coverage gs\n/Color Do", try streamOf(encoded.pdf, 4));
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "/Resources<</ExtGState<</Coverage<</SMask<</Type/Mask/S/Alpha/G 6 0 R>>>>>>/XObject<</Color 7 0 R>>>>") != null);
    try testing.expectEqualStrings("1 0 0 rg\n0 0 1 1 re\nf\nq\n/Ramp1 gs\n0 0 1 rg\n0 0 1 1 re\nf\nQ", try streamOf(encoded.pdf, 7));
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "/Opacity") == null);
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "xref\n0 8\n") != null);
}

test "one workspace serves consecutive encodings identically" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    const patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = rainbow, .tolerance = 0.01 };
    const first = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(first.pdf);
    const second = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(second.pdf);
    try testing.expectEqualSlices(u8, first.pdf, second.pdf);
}

fn encodeAndRelease(allocator: std.mem.Allocator, workspace: *Workspace, clip: []const Segment) !void {
    const patch = affinePatch();
    const encoded = try encode(allocator, workspace, .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = rainbow, .tolerance = 0.01 }, clip, true);
    allocator.free(encoded.pdf);
}

test "every failed allocation releases the partial encoding" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    try testing.checkAllAllocationFailures(testing.allocator, encodeAndRelease, .{ workspace, @as([]const Segment, &clip) });
}

/// Red, half-transparent green and blue along the field.
const rainbow: Gradient.Stops = .{ .levels = &.{ 0, 0.5, 1 }, .colors = &.{ .{ .r = 1 }, .{ .g = 1, .a = 0.5 }, .{ .b = 1 } } };

/// One patch mapping the unit square onto [10, 30] x [20, 60], with the
/// field u from 0 to 1.
fn affinePatch() struct { points: [16]g.Point, values: [16]f64 } {
    var points: [16]g.Point = undefined;
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3;
        points[i * 4 + j] = .{ .x = 10 + 20 * u, .y = 20 + 40 * @as(f64, @floatFromInt(j)) / 3 };
        values[i * 4 + j] = u;
    };
    return .{ .points = points, .values = values };
}

test "patch records list control points in type 7 order and stops become soft masks" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    const patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = rainbow, .tolerance = 0.01 };
    const encoded = try encode(testing.allocator, workspace, patches, &clip, true);
    defer testing.allocator.free(encoded.pdf);
    const pdf = encoded.pdf;
    try testing.expectEqualDeep(g.BBox{ .min = .{ .x = 10, .y = 20 }, .max = .{ .x = 30, .y = 60 } }, encoded.bounds);
    try testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));
    // Every cross-reference entry addresses its object.
    const xref = std.mem.lastIndexOf(u8, pdf, "xref\n0 9\n") orelse return error.MissingXref;
    var trailer: [40]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&trailer, "startxref\n{d}\n%%EOF", .{xref}), pdf[std.mem.lastIndexOf(u8, pdf, "startxref").?..]);
    var entries_ = std.mem.splitSequence(u8, pdf[xref + "xref\n0 9\n".len ..], "\r\n");
    try testing.expectEqualStrings("0000000000 65535 f", entries_.next().?);
    for (1..9) |id| {
        const entry = entries_.next().?;
        const offset = try std.fmt.parseInt(usize, entry[0..10], 10);
        var header: [16]u8 = undefined;
        try testing.expect(std.mem.startsWith(u8, pdf[offset..], try std.fmt.bufPrint(&header, "{d} 0 obj\n", .{id})));
    }
    // The mesh holds the field as gray levels, without a function, which
    // Quartz would not draw.
    try testing.expect(std.mem.indexOf(u8, pdf, "5 0 obj\n<</ShadingType 7/ColorSpace/DeviceGray/BitsPerCoordinate 24/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1]/Filter/FlateDecode/Length ") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "/Function<<") == null);
    try testing.expectEqualStrings("/Field sh", try streamOf(pdf, 6));
    // Opacity rises from the half at u = 1/2 to full at both ends, so the
    // page paints through the coverage, and inside it through the opacity.
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW*\nn\n/Coverage gs\n/Masked Do", try streamOf(pdf, 4));
    try testing.expectEqualStrings("/Opacity gs\n/Color Do", try streamOf(pdf, 8));
    const piece = "<</FunctionType 2/Domain[0 1]/C0[{s}]/C1[{s}]/N 1>>";
    const transfer = "/TR<</FunctionType 3/Domain[0 1]/Functions[" ++ piece ++ piece ++ "]/Bounds[0.5]/Encode[0 1 0 1]>>";
    var expected: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&expected, "/Opacity<</SMask<</Type/Mask/S/Luminosity/G 6 0 R" ++ transfer ++ ">>>>", .{ "1", "0.5", "0.5", "1" })) != null);
    // Red, then green weighted in over the first half, blue over the second.
    try testing.expectEqualStrings("1 0 0 rg\n0 0 1 1 re\nf\nq\n/Ramp1 gs\n0 1 0 rg\n0 0 1 1 re\nf\nQ\nq\n/Ramp2 gs\n0 0 1 rg\n0 0 1 1 re\nf\nQ", try streamOf(pdf, 7));
    try testing.expect(std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&expected, "/Ramp1<</SMask<</Type/Mask/S/Luminosity/G 6 0 R" ++ transfer ++ ">>>>", .{ "0", "1", "1", "1" })) != null);
    try testing.expect(std.mem.indexOf(u8, pdf, try std.fmt.bufPrint(&expected, "/Ramp2<</SMask<</Type/Mask/S/Luminosity/G 6 0 R" ++ transfer ++ ">>>>", .{ "0", "0", "0", "1" })) != null);

    const records = try inflate(try streamOf(pdf, 5));
    defer testing.allocator.free(records);
    try testing.expectEqual(patch_record, records.len);
    try testing.expectEqual(@as(u8, 0), records[0]);
    // p01 = (0, 1/3) on the page, then p13 = (1/3, 1) fifth.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x55, 0x55, 0x55 }, records[7..13]);
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x55, 0x55, 0xff, 0xff, 0xff }, records[25..31]);
    // Corner values p00, p03, p33, p30: the field is u.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff }, records[97..105]);
}

test "one color needs no layers and one opacity no opacity mask" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    var patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = .{ .levels = &.{0.25}, .colors = &.{.{ .g = 1 }} }, .tolerance = 0.01 };
    // One opaque color: a plain fill, kept to the patches by their coverage.
    const flat = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(flat.pdf);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW\nn\n/Coverage gs\n0 1 0 rg\n0 0 1 1 re\nf", try streamOf(flat.pdf, 4));
    try testing.expect(std.mem.indexOf(u8, flat.pdf, "/Resources<</ExtGState<</Coverage<</SMask<</Type/Mask/S/Alpha/G 6 0 R>>>>>>>>") != null);
    try testing.expect(std.mem.indexOf(u8, flat.pdf, "/Luminosity") == null);
    try testing.expect(std.mem.indexOf(u8, flat.pdf, "xref\n0 7\n") != null);
    // A glow: one color fading in from nothing, through the opacity mask
    // alone, which is zero off the patches too.
    patches.stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1, .g = 1, .b = 1, .a = 0 }, .{ .r = 1, .g = 1, .b = 1 } } };
    const glow = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(glow.pdf);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW\nn\n/Opacity gs\n1 1 1 rg\n0 0 1 1 re\nf", try streamOf(glow.pdf, 4));
    try testing.expect(std.mem.indexOf(u8, glow.pdf, "/Resources<</ExtGState<</Opacity<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0]/C1[1]/N 1>>]/Bounds[]/Encode[0 1]>>>>>>>>>>") != null);
    try testing.expect(std.mem.indexOf(u8, glow.pdf, "/Coverage") == null);
    try testing.expect(std.mem.indexOf(u8, glow.pdf, "xref\n0 7\n") != null);
    // Half opacity throughout: the layers at a constant alpha.
    patches.stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .{ .r = 1, .a = 0.5 }, .{ .b = 1, .a = 0.5 } } };
    const faint = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(faint.pdf);
    try testing.expectEqualStrings("0 0 m\n1 0 l\n1 1 l\n0 1 l\nh\nW\nn\n/Coverage gs\n/Color Do", try streamOf(faint.pdf, 4));
    try testing.expect(std.mem.indexOf(u8, faint.pdf, "/Coverage<</SMask<</Type/Mask/S/Alpha/G 6 0 R>>/ca 0.5>>") != null);
    try testing.expect(std.mem.indexOf(u8, faint.pdf, "/Opacity") == null);
    try testing.expect(std.mem.indexOf(u8, faint.pdf, "xref\n0 8\n") != null);
}

test "stops beyond the field's range fold into the base or add nothing" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    // The field runs from 0 to 1: the stops at -1 and -0.5 are passed by
    // then, the one at 0.25 repeats its predecessor's color, and the one at
    // 3 only starts rising after 2.
    const patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = .{
        .levels = &.{ -1, -0.5, 0.25, 0.75, 2, 3 },
        .colors = &.{ .{ .r = 1 }, .{ .g = 1 }, .{ .g = 1 }, .{ .b = 1 }, .{ .r = 1, .g = 1, .b = 1 }, .black },
    }, .tolerance = 0.01 };
    const encoded = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(encoded.pdf);
    try testing.expectEqualStrings("0 1 0 rg\n0 0 1 1 re\nf\nq\n/Ramp3 gs\n0 0 1 rg\n0 0 1 1 re\nf\nQ\nq\n/Ramp4 gs\n1 1 1 rg\n0 0 1 1 re\nf\nQ", try streamOf(encoded.pdf, 7));
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "/Ramp3<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0]/C1[0]/N 1>><</FunctionType 2/Domain[0 1]/C0[0]/C1[1]/N 1>><</FunctionType 2/Domain[0 1]/C0[1]/C1[1]/N 1>>]/Bounds[0.25 0.75]/Encode[0 1 0 1 0 1]>>>>>>") != null);
    try testing.expect(std.mem.indexOf(u8, encoded.pdf, "/Ramp4<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0]/C1[0]/N 1>><</FunctionType 2/Domain[0 1]/C0[0]/C1[0.2]/N 1>>]/Bounds[0.75]/Encode[0 1 0 1]>>>>>>") != null);
}

test "stops on the straight line between their neighbours merge into one ramp" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    // The shade palette of a mid gray ink: dark, the ink and light lie on one
    // line in color over their levels, up to rounding.
    const ink = 0.5;
    const tones = [3]f64{ ink * (1 - 0.58), ink, ink + (1 - ink) * 0.33 };
    var colors: [3]Color = undefined;
    for (&colors, tones) |*color, tone| color.* = .{ .r = tone, .g = tone, .b = tone };
    var patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = .{ .levels = &.{ 0, 0.58 / 0.91, 1 }, .colors = &colors }, .tolerance = 0.01 };
    const merged = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(merged.pdf);
    try testing.expectEqualStrings("0.21 0.21 0.21 rg\n0 0 1 1 re\nf\nq\n/Ramp2 gs\n0.665 0.665 0.665 rg\n0 0 1 1 re\nf\nQ", try streamOf(merged.pdf, 7));
    try testing.expect(std.mem.indexOf(u8, merged.pdf, "/Ramp2<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0]/C1[1]/N 1>>]/Bounds[]/Encode[0 1]>>>>>>") != null);
    // A brighter middle stop bends the line: two ramps.
    colors[1] = .{ .r = 0.6, .g = 0.6, .b = 0.6 };
    patches.stops.colors = &colors;
    const bent = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(bent.pdf);
    try testing.expectEqualStrings("0.21 0.21 0.21 rg\n0 0 1 1 re\nf\nq\n/Ramp1 gs\n0.6 0.6 0.6 rg\n0 0 1 1 re\nf\nQ\nq\n/Ramp2 gs\n0.665 0.665 0.665 rg\n0 0 1 1 re\nf\nQ", try streamOf(bent.pdf, 7));
}

test "coinciding levels and a constant field still give valid transfer functions" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    var patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = .{ .levels = &.{ 0.5, 0.5 + 1e-12, 1 }, .colors = &.{ .black, .{ .r = 1 }, .{ .b = 1 } } }, .tolerance = 0.01 };
    // In single precision the first ramp is a step at gray 0.5.
    const jump = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(jump.pdf);
    try testing.expect(std.mem.indexOf(u8, jump.pdf, "/Ramp1<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0]/C1[0]/N 1>><</FunctionType 2/Domain[0 1]/C0[1]/C1[1]/N 1>>]/Bounds[0.5]/Encode[0 1 0 1]>>>>>>") != null);
    // A constant field of 0.5 widens to [0.5, 1.5]: every corner is gray 0,
    // which the ramp maps to the mid level of a black to white gradient.
    const constant: [16]f64 = @splat(0.5);
    patches.values = &.{constant};
    patches.stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .{ .r = 1, .g = 1, .b = 1 } } };
    const flat = try encode(testing.allocator, workspace, patches, &clip, false);
    defer testing.allocator.free(flat.pdf);
    try testing.expect(std.mem.indexOf(u8, flat.pdf, "/Ramp1<</SMask<</Type/Mask/S/Luminosity/G 6 0 R/TR<</FunctionType 3/Domain[0 1]/Functions[<</FunctionType 2/Domain[0 1]/C0[0.5]/C1[1]/N 1>><</FunctionType 2/Domain[0 1]/C0[1]/C1[1]/N 1>>]/Bounds[0.5]/Encode[0 1 0 1]>>>>>>") != null);
    const records = try inflate(try streamOf(flat.pdf, 5));
    defer testing.allocator.free(records);
    try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), records[97..105]);
}

test "invalid patches are rejected before any output" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    const stops: Gradient.Stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .{ .r = 1 } } };
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, workspace, .{ .points = &.{}, .values = &.{}, .stops = stops, .tolerance = 0.01 }, &clip, false));
    var far = patch.points;
    far[6].y = std.math.nan(f64);
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, workspace, .{ .points = &.{far}, .values = &.{patch.values}, .stops = stops, .tolerance = 0.01 }, &clip, false));
    var flat = patch.points;
    for (&flat) |*point| point.y = 20;
    try testing.expectError(error.InvalidMesh, encode(testing.allocator, workspace, .{ .points = &.{flat}, .values = &.{patch.values}, .stops = stops, .tolerance = 0.01 }, &clip, false));
}

test "invalid clips are rejected before any output" {
    const workspace = try testing.allocator.create(Workspace);
    defer testing.allocator.destroy(workspace);
    const clip = square(.{ .{ 10, 20 }, .{ 30, 20 }, .{ 30, 60 }, .{ 10, 60 } });
    const patch = affinePatch();
    const patches: Patches = .{ .points = &.{patch.points}, .values = &.{patch.values}, .stops = rainbow, .tolerance = 0.01 };
    try testing.expectError(error.InvalidPath, encode(testing.allocator, workspace, patches, &.{}, false));
    var far = clip;
    far[1].p1.x = 1e300;
    try testing.expectError(error.InvalidPath, encode(testing.allocator, workspace, patches, &far, false));
    var unknown = clip;
    unknown[3].kind = 99;
    try testing.expectError(error.InvalidPath, encode(testing.allocator, workspace, patches, &unknown, false));
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
