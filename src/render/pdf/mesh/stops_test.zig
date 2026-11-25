//! Tests of the stop plan: control-point order and soft masks, single colors and opacities, folded stops, merged ramps and transfer functions.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");
const style = @import("../../../drawing/style.zig");
const Gradient = style.Gradient;
const Color = style.Color;
const Patches = Gradient.Patches;
const syntax = @import("../syntax.zig");
const Workspace = syntax.Workspace;
const testing = std.testing;
const mesh = @import("../mesh.zig");
const fixtures = @import("fixtures.zig");
const mesh_records = @import("records.zig");
const square = fixtures.square;
const affinePatch = fixtures.affinePatch;
const rainbow = fixtures.rainbow;
const encode = mesh.encode;
const streamOf = fixtures.streamOf;
const inflate = fixtures.inflate;
const patch_record = mesh_records.patch_record;

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
