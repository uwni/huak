//! Native integration fixtures are intentionally independent of executables.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const options = @import("test_options");
const a = huak.animation;
const native_svg = huak.svg.animation;
const backend = huak.backend;
const DisplayList = huak.core.DisplayList;
const Path = huak.core.Path;

const Fixture = struct {
    const text = "#text(size: 12pt)[Fixed Unicode label · 数学]";
    const formula = "#text(size: 16pt)[$frac(1, 2)$]";
    const requests = [_]typst.LayoutRequest{
        .{
            .source = text,
            .syntax = .markup,
            .region = null,
        },
        .{
            .source = formula,
            .syntax = .markup,
            .region = null,
        },
    };
    const curve_id = 1;
    const label_id = 2;
    const formula_id = 3;
    const width = 180;
    const height = 100;
    const start = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 10 } }, .{ .cubic = .{ .c1 = .{ .x = 30, .y = 50 }, .c2 = .{ .x = 70, .y = 50 }, .end = .{ .x = 90, .y = 10 } } } };
    const end = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 10 } }, .{ .cubic = .{ .c1 = .{ .x = 30, .y = 70 }, .c2 = .{ .x = 70, .y = 70 }, .end = .{ .x = 90, .y = 10 } } } };
    const path_keys = [_]a.PathKey{ .{ .time = 0, .value = &start }, .{ .time = 1, .value = &end } };
    const tracks = [_]a.Track{
        .{ .target = curve_id, .property = .{ .path = &path_keys } },
        .{ .target = curve_id, .property = .{ .motion = .{ .path = &start } } },
    };

    picture: DisplayList,
    ids: [3]u64,
    fn init(allocator: std.mem.Allocator, measured: []const typst.Metrics) !Fixture {
        var picture = DisplayList.init(allocator);
        errdefer picture.deinit();
        var curve = Path.init(allocator);
        defer curve.deinit();
        try curve.moveTo(start[0].move);
        try curve.cubicTo(start[1].cubic.c1, start[1].cubic.c2, start[1].cubic.end);
        var ids: [3]u64 = @splat(0);
        ids[picture.commands.items.len] = curve_id;
        try picture.draw(curve, .{ .width = 2 }, .{});
        for (measured, 0..) |metrics, index| {
            ids[picture.commands.items.len] = if (index == 0) label_id else formula_id;
            try picture.labelAtBaseline(@intCast(index), .{ .width = metrics.width, .height = metrics.height, .baseline = metrics.baseline }, .{ .x = 12, .y = 70 + @as(f64, @floatFromInt(index)) * 20 }, .{});
        }
        return .{ .picture = picture, .ids = ids };
    }
    fn deinit(self: *Fixture) void {
        self.picture.deinit();
    }
};

test "one typeset scene yields continuous tracks with shared glyph resources and no new layout" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [Fixture.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&Fixture.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var fixture = try Fixture.init(std.testing.allocator, &measured);
    defer fixture.deinit();
    var document = try backend.submit(std.testing.allocator, &library, &fixture.picture, Fixture.width, Fixture.height, .{ .frames = &frames, .object_ids = &fixture.ids });
    defer document.deinit();
    // Encoding only consumes the exported SVG; an engine or retained labels
    // cannot participate in another layout after their owners are released.
    labels.deinit();
    engine.deinit();
    var static = try document.exportSvg(0);
    defer static.deinit();
    const output = try native_svg.encodeAnimatedSvg(std.testing.allocator, static.bytes(), &.{ .duration_seconds = 2, .tracks = &Fixture.tracks });
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(std.mem.count(u8, static.bytes(), "<symbol "), std.mem.count(u8, output, "<symbol "));
    try std.testing.expect(std.mem.count(u8, output, "<symbol ") > 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "<svg "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "<animateMotion "));
    try std.testing.expect(std.mem.indexOf(u8, output, "attributeName=\"d\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "libtypst-object-18446744073709551615"));
}

test "animation bytes outlive native owners and unknown objects fail explicitly" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [Fixture.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&Fixture.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var fixture = try Fixture.init(std.testing.allocator, &measured);
    defer fixture.deinit();
    var document = try backend.submit(std.testing.allocator, &library, &fixture.picture, Fixture.width, Fixture.height, .{ .frames = &frames, .object_ids = &fixture.ids });
    defer document.deinit();
    labels.deinit();
    engine.deinit();
    var static = try document.exportSvg(0);
    defer static.deinit();
    document.deinit();
    const opacity = [_]a.ScalarKey{ .{ .time = 0, .value = 0.25 }, .{ .time = 1, .value = 1 } };
    const tracks = [_]a.Track{.{ .target = Fixture.label_id, .property = .{ .opacity = &opacity } }};
    const output = try native_svg.encodeAnimatedSvg(std.testing.allocator, static.bytes(), &.{ .duration_seconds = 1, .repeat = false, .tracks = &tracks });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "attributeName=\"opacity\"") != null);
    const invalid = [_]a.Track{.{ .target = 999, .property = .{ .opacity = &opacity } }};
    try std.testing.expectError(error.MissingTarget, native_svg.encodeAnimatedSvg(std.testing.allocator, static.bytes(), &.{ .duration_seconds = 1, .tracks = &invalid }));
}

test "real formula combining glyph instances and a fraction bar rejects partial path animation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [Fixture.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&Fixture.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var fixture = try Fixture.init(std.testing.allocator, &measured);
    defer fixture.deinit();
    var document = try backend.submit(std.testing.allocator, &library, &fixture.picture, Fixture.width, Fixture.height, .{ .frames = &frames, .object_ids = &fixture.ids });
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    const colors = [_]a.ColorKey{ .{ .time = 0, .value = .{ .r = 1 } }, .{ .time = 1, .value = .{ .b = 1 } } };
    const widths = [_]a.ScalarKey{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 2 } };
    for ([_]a.Property{ .{ .fill = &colors }, .{ .stroke = &colors }, .{ .stroke_width = &widths }, .{ .path = &Fixture.path_keys } }) |property| {
        const tracks = [_]a.Track{.{ .target = Fixture.formula_id, .property = property }};
        try std.testing.expectError(error.AmbiguousPathTarget, native_svg.encodeAnimatedSvg(std.testing.allocator, svg.bytes(), &.{ .duration_seconds = 1, .tracks = &tracks }));
    }
}
