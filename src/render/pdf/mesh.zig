//! Encodes one patch paint, with its exact curved clip, as a one-page PDF.
//! Typst has no patch paint, so the Typst adapter imports this page through
//! libtypst and places it over `bounds`; Typst's exporter still writes the
//! final document. The page is the unit square, and one Type 7
//! tensor-product patch mesh paints it.
//!
//! Colors at patch corners go into the mesh as RGB (`encodeColors`). A field
//! goes in as gray levels, and its stops apply through luminosity soft masks
//! of that mesh whose transfer functions are piecewise linear in the field
//! (see `Plan`). A shading /Function would say the same directly, but Quartz
//! (macOS Preview and Quick Look) draws no type 6 or 7 shading that has one.
//! Geometry and colors come from the caller, not from lighting.
const std = @import("std");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const style = @import("../../drawing/style.zig");
const Gradient = style.Gradient;
const Patches = Gradient.Patches;

const syntax = @import("syntax.zig");
const Segment = syntax.Segment;
const Objects = syntax.Objects;

pub const Workspace = syntax.Workspace;
const mesh_records = @import("mesh/records.zig");
const stop_plan = @import("mesh/stops.zig");
const fixtures = @import("mesh/fixtures.zig");
const color_record = mesh_records.color_record;
const Record = mesh_records.Record;
const quantize = mesh_records.quantize;
const compressRecords = mesh_records.compressRecords;
const Plan = stop_plan.Plan;
const valueRange = stop_plan.valueRange;
const patch_record = mesh_records.patch_record;
const writeCoverage = stop_plan.writeCoverage;
const writeOpacity = stop_plan.writeOpacity;
const writeContent = stop_plan.writeContent;
const compressPatches = mesh_records.compressPatches;
const writeTransfer = stop_plan.writeTransfer;
const fill = stop_plan.fill;
const writePaint = stop_plan.writePaint;
const square = fixtures.square;
const affinePatch = fixtures.affinePatch;
const streamOf = fixtures.streamOf;
const rainbow = fixtures.rainbow;

pub const Encoded = struct {
    /// The complete PDF, owned by the allocator passed to `encode`.
    pdf: []u8,
    /// Extent of the control points; the page's unit square maps onto it.
    bounds: g.BBox,
};

/// Patches with colors at their corners, and their exact curved clip, as a
/// one-page PDF: one type 7 mesh with RGB at every corner, which readers
/// interpolate bilinearly, and neither a function nor a soft mask, so the
/// page holds nothing translucent. Inputs are borrowed for the call.
pub fn encodeColors(allocator: std.mem.Allocator, workspace: *Workspace, patches: Gradient.ColorPatches, clip: []const Segment, evenodd: bool) !Encoded {
    patches.validate() catch return error.InvalidMesh;
    const bounds = try controlBounds(patches.points);
    if (clip.len == 0) return error.InvalidPath;
    const unit: Unit = .{ .origin = bounds.min, .size = bounds.max.sub(bounds.min) };
    var pdf = try std.Io.Writer.Allocating.initCapacity(allocator, 1024 +| clip.len *| 96 +| patches.points.len *| color_record / 2);
    errdefer pdf.deinit();
    writeColors(&pdf, workspace, patches, clip, unit, evenodd) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
    return .{ .pdf = try pdf.toOwnedSlice(), .bounds = bounds };
}

/// Catalog, pages, page, its content, then the mesh.
fn writeColors(pdf: *std.Io.Writer.Allocating, workspace: *Workspace, patches: Gradient.ColorPatches, clip: []const Segment, unit: Unit, evenodd: bool) !void {
    const w = &pdf.writer;
    var offsets: [5]usize = undefined;
    var objects: Objects = .{ .pdf = pdf, .offsets = &offsets };
    // Type 7 shadings need PDF 1.3.
    try w.writeAll("%PDF-1.3\n%\x80\x80\x80\x80\n\n");
    try objects.dictionary("<</Type/Catalog/Pages 2 0 R>>");
    try objects.dictionary("<</Type/Pages/Kids[3 0 R]/Count 1>>");
    try objects.dictionary("<</Type/Page/Parent 2 0 R/MediaBox[0 0 1 1]/Contents 4 0 R/Resources<</Shading<</Mesh 5 0 R>>>>>>");
    var content = try objects.beginStream("");
    try syntax.path(w, clip, unit);
    try w.writeAll(if (evenodd) "\nW*\nn\n/Mesh sh" else "\nW\nn\n/Mesh sh");
    try objects.endStream(&content);
    var mesh = try objects.beginStream("/ShadingType 7/ColorSpace/DeviceRGB/BitsPerCoordinate 24/BitsPerComponent 16/BitsPerFlag 8/Decode[0 1 0 1 0 1 0 1 0 1]/Filter/FlateDecode");
    const Colors = struct {
        patches: Gradient.ColorPatches,
        unit: Unit,
        pub fn record(self: @This(), index: usize) Record([3]u16) {
            var result: Record([3]u16) = undefined;
            for (self.patches.points[index], &result.points) |point, *out| out.* = .{ quantize(u24, self.unit.x(point.x)), quantize(u24, self.unit.y(point.y)) };
            for (self.patches.colors[index], &result.corners) |color, *out| out.* = .{ quantize(u16, color.r), quantize(u16, color.g), quantize(u16, color.b) };
            return result;
        }
    };
    try compressRecords([3]u16, workspace, w, patches.points.len, Colors{ .patches = patches, .unit = unit });
    try objects.endStream(&mesh);
    try objects.finish();
}

/// Inputs are borrowed for the call. Objects and compressed streams go
/// straight into the returned buffer, which is the only allocation.
pub fn encode(allocator: std.mem.Allocator, workspace: *Workspace, patches: Patches, clip: []const Segment, evenodd: bool) !Encoded {
    patches.validate() catch return error.InvalidMesh;
    const bounds = try controlBounds(patches.points);
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

/// A sizing hint, not a bound: patch records deflate to roughly half their
/// size, and each stop adds at most a few hundred bytes of transfer
/// functions. A short hint grows the buffer; the excess is trimmed.
fn capacityHint(patches: Patches, segments: usize) usize {
    return 2048 +| segments *| 96 +| patches.points.len *| patch_record / 2 +| patches.stops.levels.len *| 400;
}

/// A patch lies within the hull of its control points.
fn controlBounds(points: []const [16]g.Point) !g.BBox {
    var bounds = g.BBox.fromSlice(&points[0]);
    for (points[1..]) |*patch| bounds = bounds.unite(g.BBox.fromSlice(patch));
    const size = bounds.max.sub(bounds.min);
    if (!size.isFinite() or size.x <= 0 or size.y <= 0) return error.InvalidMesh;
    return bounds;
}

/// Maps scene coordinates onto the page's unit square.
pub const Unit = struct {
    origin: g.Point,
    size: g.Point,

    pub fn x(self: Unit, value: f64) f64 {
        return (value - self.origin.x) / self.size.x;
    }
    pub fn y(self: Unit, value: f64) f64 {
        return (value - self.origin.y) / self.size.y;
    }
};

/// Objects in writing order: catalog, pages, page, content, then the mesh
/// (5) and the mask group that paints it (6), which every soft mask reads.
/// The form of the color layers and the form that nests the opacity mask
/// under the coverage mask follow where the plan has them.
fn writeDocument(pdf: *std.Io.Writer.Allocating, workspace: *Workspace, patches: Patches, clip: []const Segment, unit: Unit, evenodd: bool, plan: Plan) !void {
    const w = &pdf.writer;
    var offsets: [8]usize = undefined;
    var objects: Objects = .{ .pdf = pdf, .offsets = &offsets };
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
    try objects.finish();
}

fn take(next: *usize) usize {
    next.* += 1;
    return next.* - 1;
}

const testing = std.testing;

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

test {
    _ = @import("mesh/records.zig");
    _ = @import("mesh/stops_test.zig");
}
