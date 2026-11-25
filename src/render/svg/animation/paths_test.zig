//! Tests of instance-path edits: paint and d morphs, constant tracks, base transforms, constant colors, rejected glyph and parent paints, writer fragments and byte order.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const Path = @import("../../../drawing/path/Path.zig");
const t = std.testing;
const testing = @import("testing.zig");
const encodeSmil = testing.encodeSmil;
const fixture = testing.fixture;

test "paint and compatible d morph animate the instance path and establish static first-key values" {
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 10 } }, .close };
    const last = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 30, .y = 20 } }, .close };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .{ .r = 0, .g = 0, .b = 1, .a = 0.4 } }, .{ .time = 1, .value = .{ .r = 1, .g = 0, .b = 0 } } } }, .easing = .{ .spline = .{ .x1 = 0.3, .y1 = 0, .x2 = 0.7, .y2 = 1 } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1, .g = 1, .b = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 3 } } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } },
    };
    const result = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 3, .tracks = &tracks, .repeat = false });
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "fill='red'") == null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(0,0,255)\" fill-opacity=\"0.4\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "stroke-width=\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "d=\"M 0 0 L 10 10 Z \"><animate") != null);
    try t.expect(std.mem.indexOf(u8, result, "attributeName=\"d\" values=\"M 0 0 L 10 10 Z ;M 0 0 L 30 20 Z ") != null);
    try t.expect(std.mem.indexOf(u8, result, "keySplines=\"0.3 0 0.7 1\"") != null);
    // A single run is SMIL's default; holding its last value needs freeze.
    try t.expect(std.mem.indexOf(u8, result, "repeatCount") == null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"freeze\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "<defs><path id='glyph' d='M0 0L1 1'/></defs>") != null);
}

test "constant tracks write base attributes without interpolation elements" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .{ .x = 20, .y = 30 } }, .{ .time = 1, .value = .{ .x = 20, .y = 30 } } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } } } },
    };
    const result = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "transform=\"translate(20 30)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(0,0,0)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "<animate") == null);
}

test "path morph retains nonidentity base transforms and writes local d coordinates" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><g data-typst-label='libtypst-object-7' transform='matrix(2 0 0 3 11 13)'><path transform='translate(4 6)' d='M0 0L1 1'/></g></svg>";
    const first = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 4, .y = 5 } } };
    const last = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 6, .y = 7 } } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } }} };
    const result = try encodeSmil(t.allocator, input, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "transform='matrix(2 0 0 3 11 13)'") != null);
    try t.expect(std.mem.indexOf(u8, result, "transform='translate(4 6)'") != null);
    try t.expect(std.mem.indexOf(u8, result, "d=\"M 1 2 L 4 5 \"><animate attributeName=\"d\" values=\"M 1 2 L 4 5 ;M 1 2 L 6 7 \"") != null);
}

test "constant RGB and alpha components omit redundant animation while retaining first-key base paint" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .{ .r = 1, .g = 0, .b = 0 } }, .{ .time = 1, .value = .{ .r = 0, .g = 0, .b = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .{ .a = 0.25 } }, .{ .time = 1, .value = .{ .a = 0.75 } } } } },
    } };
    const result = try encodeSmil(t.allocator, fixture, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(255,0,0)\" fill-opacity=\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "stroke=\"rgb(0,0,0)\" stroke-opacity=\"0.25\"") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<animate attributeName=\"fill\""));
    try t.expectEqual(@as(usize, 0), std.mem.count(u8, result, "<animate attributeName=\"fill-opacity\""));
    try t.expectEqual(@as(usize, 0), std.mem.count(u8, result, "<animate attributeName=\"stroke\""));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<animate attributeName=\"stroke-opacity\""));
}

test "mixed glyph uses and one decoration path reject every paint and morph track" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><defs><path id='glyph' d='M0 0L1 1'/></defs><g data-typst-label='libtypst-object-7'><g><use href='#glyph' fill='black'/></g><use href='#glyph' fill='black'/><path fill='none' stroke='black' d='M0 0L10 0'/></g></svg>";
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    const last = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 20, .y = 0 } } };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 2 } } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } },
    };
    for (tracks) |track| {
        try t.expectError(error.AmbiguousPathTarget, encodeSmil(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{track} }));
    }
}

test "parent paints reject nested object content while child paths and group transforms remain independent" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><g data-typst-label='libtypst-object-8'><path d='M0 0L1 1'/><g data-typst-label='libtypst-object-7'><path d='M0 0L2 2'/></g></g></svg>";
    var fill: a.Track = .{ .target = 8, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } };
    try t.expectError(error.AmbiguousPathTarget, encodeSmil(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{fill} }));
    fill.target = 7;
    const translate: a.Track = .{ .target = 8, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 5, .y = 6 } } } } };
    const output = try encodeSmil(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{ translate, fill } });
    defer t.allocator.free(output);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, output, "attributeName=\"fill\""));
    try t.expect(std.mem.indexOf(u8, output, "<path d='M0 0L1 1'/>") != null);
}

test "writer fragments preserve nonempty path content and untouched attributes" {
    const source = "<svg><g data-typst-label='libtypst-object-7'><path data-note='A&amp;B' d='M0 0L1 1' fill='red'><!--keep--><![CDATA[<>&]]></path></g></svg>";
    const tracks = [_]a.Track{.{ .target = 7, .property = .{ .fill = &.{
        .{ .time = 0, .value = .black },
        .{ .time = 1, .value = .black },
    } } }};
    const output = try encodeSmil(t.allocator, source, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer t.allocator.free(output);
    try t.expect(std.mem.indexOf(u8, output, "data-note='A&amp;B' d='M0 0L1 1'") != null);
    try t.expect(std.mem.indexOf(u8, output, "fill-opacity=\"1\"><!--keep--><![CDATA[<>&]]></path>") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, output, "</path>"));
    var source_reader: @import("xml_parser").Reader.Static = .init(t.allocator, output, .{});
    defer source_reader.deinit();
    while (try source_reader.interface.read() != .eof) {}
}

test "interleaved target tracks preserve the original SVG byte order" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 2, .y = 3 } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 9, .property = .{ .scale = &.{ .{ .time = 0, .value = .{ .x = 1, .y = 1 } }, .{ .time = 1, .value = .{ .x = 2, .y = 2 } } } } },
        .{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .b = 1 } } } } },
    };
    const expected =
        "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100' viewBox='0 0 100 100'>" ++
        "<defs>" ++
        "<path id='glyph' d='M0 0L1 1'/>" ++
        "</defs>" ++
        "<g transform=\"translate(0 0)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"translate\" values=\"0 0;2 3\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g transform=\"rotate(0 0 0)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"rotate\" values=\"0 0 0;180 0 0\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g data-typst-label='libtypst-object-7' transform='translate(5 6)'>" ++
        "<path  d='M0 0L10 0Z' fill=\"rgb(0,0,0)\" fill-opacity=\"1\" stroke=\"rgb(0,0,0)\" stroke-opacity=\"1\">" ++
        "<animate attributeName=\"fill\" values=\"rgb(0,0,0);rgb(255,0,0)\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<animate attributeName=\"stroke\" values=\"rgb(0,0,0);rgb(0,0,255)\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "</path>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "<g opacity=\"0\">" ++
        "<animate attributeName=\"opacity\" values=\"0;1\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g transform=\"scale(1 1)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"scale\" values=\"1 1;2 2\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g data-typst-label='libtypst-object-9'>" ++
        "<use href='#glyph'/>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "</svg>";
    const output = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 2, .tracks = &tracks });
    defer t.allocator.free(output);
    try t.expectEqualStrings(expected, output);
}

test "color constancy completion preserves every key and late validation" {
    var keys = [_]a.ColorKey{
        .{ .time = 0, .value = .{ .a = 0 } },
        .{ .time = 0.25, .value = .{ .r = 1, .a = 1 } },
        .{ .time = 0.75, .value = .{ .g = 1, .a = 0.4 } },
        .{ .time = 1, .value = .{ .b = 1, .a = 0.8 } },
    };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .fill = &keys } }} };
    const result = try encodeSmil(t.allocator, fixture, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "values=\"rgb(0,0,0);rgb(255,0,0);rgb(0,255,0);rgb(0,0,255)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "values=\"0;1;0.4;0.8\"") != null);
    keys[3].value.r = std.math.nan(f64);
    try t.expectError(error.InvalidColor, encodeSmil(t.allocator, fixture, &animation));
}
