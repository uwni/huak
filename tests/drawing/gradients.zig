//! Gradient paints through the native scene: stop positions; patch and conic paints as type 7 PDF meshes and SVG triangles; and gradients on strokes, continuous with fills and drawn as footprints when they are meshes.
const std = @import("std");
const t = std.testing;
const typst = @import("libtypst");
const demo = @import("drawing_scene");
const huak = @import("huak");
const backend = huak.backend;
const render = huak.render;
const DisplayList = huak.core.DisplayList;
const Path = huak.core.Path;
const Point = huak.core.geometry.Point;
const options = @import("test_options");

/// `picture` on a page 60 points square, in `format`.
fn page(library: *typst.Library, picture: *const DisplayList, format: render.Format) !render.Output {
    return pageMesh(library, picture, format, .default);
}

fn pageMesh(library: *typst.Library, picture: *const DisplayList, format: render.Format, svg_mesh: render.SvgMesh) !render.Output {
    const scene: render.Scene = .{ .picture = picture, .size = .{ .x = 60, .y = 60 }, .svg_mesh = svg_mesh };
    var diagnostic: ?typst.Buffer = null;
    return scene.render(t.allocator, library, format, &diagnostic);
}

/// A page 60 points square as Poppler draws it in gray at 72 dpi: a pixel
/// a point, rows running down from the top.
const Gray = struct {
    image: []u8,

    const side = 60;
    const header = "P5\n60 60\n255\n";

    fn read(pdf: []const u8) !Gray {
        const image = try @import("../support/pdf.zig").raster(pdf, .{ .gray = true });
        errdefer t.allocator.free(image);
        try t.expect(std.mem.startsWith(u8, image, header));
        return .{ .image = image };
    }

    fn deinit(self: Gray) void {
        t.allocator.free(self.image);
    }

    fn at(self: Gray, column: usize, row: usize) f64 {
        return @floatFromInt(self.image[header.len + row * side + column]);
    }

    /// Whether a pixel's gray lies between `low` and `high`, the least and
    /// the greatest a paint takes over that pixel, give or take rounding:
    /// a reader may sample a shading anywhere in a pixel.
    fn within(self: Gray, column: usize, row: usize, low: f64, high: f64) bool {
        const value = self.at(column, row);
        return value >= low - 2 and value <= high + 2;
    }
};

/// Four flat patches tiling the page with the field x / 60. The field is
/// linear, so its coefficients are its values at the control points.
const Tiles = struct {
    points: [4][16]Point,
    values: [4][16]f64,

    fn init() Tiles {
        var result: Tiles = undefined;
        for (0..2) |row| for (0..2) |column| {
            const patch = row * 2 + column;
            for (0..4) |i| for (0..4) |j| {
                const x = 30 * (@as(f64, @floatFromInt(column)) + @as(f64, @floatFromInt(i)) / 3);
                const y = 30 * (@as(f64, @floatFromInt(row)) + @as(f64, @floatFromInt(j)) / 3);
                result.points[patch][i * 4 + j] = .{ .x = x, .y = y };
                result.values[patch][i * 4 + j] = x / 60;
            };
        };
        return result;
    }

    /// Black where the field is 0, white where it is 1.
    fn paint(self: *const Tiles) DisplayList.Gradient {
        return .{ .patches = .{
            .points = &self.points,
            .values = &self.values,
            .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .white } },
            .tolerance = 1.0 / 256.0,
        } };
    }
};

test "gradient color stops keep their positions through the native scene" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var bar = Path.init(t.allocator);
    defer bar.deinit();
    try bar.moveTo(.zero);
    try bar.lineTo(.{ .x = 40, .y = 0 });
    try bar.lineTo(.{ .x = 40, .y = 10 });
    try bar.lineTo(.{ .x = 0, .y = 10 });
    try bar.close();
    const colors = [_]DisplayList.Color{ .{ .r = 1 }, .{ .g = 1 }, .{ .b = 1 } };
    const ramp: DisplayList.Gradient.Ramp = .{ .start = .{ .x = 0, .y = 5 }, .end = .{ .x = 40, .y = 5 }, .colors = &colors, .offsets = &.{ 0, 0.25, 1 } };
    try picture.addPath(bar, .{ .fill = .{ .gradient = &.{ .linear = ramp } } }, .{});
    for ([_][]const f64{ &.{ 0, 1 }, &.{ 0.1, 0.5, 1 }, &.{ 0, 0.6, 0.4 }, &.{ 0, std.math.nan(f64), 1 } }) |offsets| {
        var invalid = ramp;
        invalid.offsets = offsets;
        try t.expectError(error.InvalidStyle, picture.addPath(bar, .{ .fill = .{ .gradient = &.{ .linear = invalid } } }, .{}));
    }
    var document = try backend.submit(t.allocator, &library, &picture, 40, 10, .{});
    defer document.deinit();
    var svg = try document.exportSvg(0);
    defer svg.deinit();
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "offset=\"25%\"") != null);
    try t.expect(std.mem.indexOf(u8, svg.bytes(), "offset=\"50%\"") == null);
}

test "patch paints become a type 7 PDF mesh and SVG triangles of the same field" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var boundary = try demo.rectangle(t.allocator, .zero, 60, 60);
    defer boundary.deinit();
    const tiles = Tiles.init();
    try picture.addPath(boundary, .{ .fill = .{ .gradient = &tiles.paint() } }, .{});
    {
        // Default SVG rasterizes the mesh fill into a PNG image clipped by the
        // exact vector boundary, without triangle crispEdges rules.
        var output = try page(&library, &picture, .svg);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "<image"));
        try t.expect(std.mem.indexOf(u8, svg, "data:image/png;base64,") != null);
        try t.expect(std.mem.indexOf(u8, svg, "clip-path=") != null);
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, svg, " data-typst-label=\"huak-mesh\""));
        try t.expect(std.mem.indexOf(u8, svg, "shape-rendering:crispEdges") == null);
    }
    {
        // Explicit vector triangle mode: a linear field over flat patches needs
        // two triangles each, drawn in one clipped group under crispEdges.
        var output = try pageMesh(&library, &picture, .svg, .triangles);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 8), std.mem.count(u8, svg, "<path fill=\"url(#"));
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, " data-typst-label=\"huak-mesh\""));
        try t.expect(std.mem.indexOf(u8, svg, "clip-path=") != null);
        try t.expect(std.mem.indexOf(u8, svg, "</style></svg>") != null);
        try t.expect(std.mem.indexOf(u8, svg, "<image") == null);
    }
    var output = try page(&library, &picture, .pdf);
    defer output.deinit();
    try t.expect(std.mem.indexOf(u8, output.bytes(), "/ShadingType 7") != null);
    const gray = try Gray.read(output.bytes());
    defer gray.deinit();
    // The gray follows x across every patch.
    for ([_][2]usize{ .{ 5, 10 }, .{ 20, 40 }, .{ 31, 29 }, .{ 45, 50 }, .{ 55, 5 } }) |sample| {
        const expected = 255 * (@as(f64, @floatFromInt(sample[0])) + 0.5) / 60;
        try t.expect(@abs(gray.at(sample[0], sample[1]) - expected) <= 3);
    }
}

test "conic paints become a type 7 PDF mesh and SVG triangles of the same field" {
    const core = huak.core;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var boundary = try demo.rectangle(t.allocator, .zero, 60, 60);
    defer boundary.deinit();
    // Four wedges go once around the middle of the square.
    const conic: DisplayList.Gradient.Conic = .{
        .center = .{ .x = 30, .y = 30 },
        .points = &.{ .{ .x = 50, .y = 30 }, .{ .x = 30, .y = 50 }, .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 10 }, .{ .x = 50, .y = 30 } },
        .values = &.{ 0, 0.25, 1, 0.5, 0 },
        .stops = .{ .levels = &.{ 0, 1 }, .colors = &.{ .black, .white } },
        .tolerance = 1.0 / 64.0,
    };
    try picture.addPath(boundary, .{ .fill = .{ .gradient = &.{ .fan = conic } } }, .{});
    {
        // Default SVG analytically rasterizes the conic fan into one clipped PNG image.
        var output = try page(&library, &picture, .svg);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "<image"));
        try t.expect(std.mem.indexOf(u8, svg, "data:image/png;base64,") != null);
        try t.expect(std.mem.indexOf(u8, svg, "clip-path=") != null);
        try t.expectEqual(@as(usize, 0), std.mem.count(u8, svg, " data-typst-label=\"huak-mesh\""));
    }
    {
        // Explicit vector triangle mode: a wedge becomes one triangle for every
        // two tolerances its field changes by: 8, 24, 16 and 16.
        var output = try pageMesh(&library, &picture, .svg, .triangles);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 64), std.mem.count(u8, svg, "<path fill=\"url(#"));
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, " data-typst-label=\"huak-mesh\""));
        try t.expect(std.mem.indexOf(u8, svg, "clip-path=") != null);
        try t.expect(std.mem.indexOf(u8, svg, "</style></svg>") != null);
        try t.expect(std.mem.indexOf(u8, svg, "<image") == null);
    }
    var output = try page(&library, &picture, .pdf);
    defer output.deinit();
    try t.expect(std.mem.indexOf(u8, output.bytes(), "/ShadingType 7") != null);
    const gray = try Gray.read(output.bytes());
    defer gray.deinit();
    // The gray is the field on the ray through each pixel; rows run down.
    // The samples keep off the center, where a pixel spans many rays.
    for ([_][2]usize{ .{ 55, 30 }, .{ 30, 5 }, .{ 5, 30 }, .{ 30, 55 }, .{ 45, 12 }, .{ 12, 20 }, .{ 20, 50 }, .{ 50, 44 }, .{ 38, 22 } }) |sample| {
        const expected = 255 * core.conic.evaluate(conic, .{ .x = @as(f64, @floatFromInt(sample[0])) + 0.5, .y = 59.5 - @as(f64, @floatFromInt(sample[1])) }).?;
        try t.expect(@abs(gray.at(sample[0], sample[1]) - expected) <= 4);
    }
}

test "one gradient paints a stroke and the fill it meets with the same colors" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    // A shaft and its head, as an arrow draws them: the stroke ends where
    // the head begins, and both take the ramp along the arrow.
    const ramp: DisplayList.Gradient = .{ .linear = .{ .start = .{ .x = 5, .y = 30 }, .end = .{ .x = 55, .y = 30 }, .colors = &.{ .black, .white } } };
    var shaft = Path.init(t.allocator);
    defer shaft.deinit();
    try shaft.moveTo(.{ .x = 5, .y = 30 });
    try shaft.lineTo(.{ .x = 45, .y = 30 });
    try picture.draw(shaft, .{ .paint = .{ .gradient = &ramp }, .width = 6, .cap = .butt }, .{});
    var head = Path.init(t.allocator);
    defer head.deinit();
    try head.moveTo(.{ .x = 45, .y = 22 });
    try head.lineTo(.{ .x = 55, .y = 30 });
    try head.lineTo(.{ .x = 45, .y = 38 });
    try head.close();
    try picture.fill(head, .{ .gradient = &ramp }, .{});
    var output = try page(&library, &picture, .pdf);
    defer output.deinit();
    const gray = try Gray.read(output.bytes());
    defer gray.deinit();
    // Row 29 runs along the arrow; its gray follows x through the joint at
    // x = 45, from the shaft into the head.
    for ([_]usize{ 10, 25, 40, 43, 44, 45, 46, 50, 53 }) |column| {
        const left = @as(f64, @floatFromInt(column));
        try t.expect(gray.within(column, 29, 255 * (left - 5) / 50, 255 * (left + 1 - 5) / 50));
    }
    // The step across the joint is the step within either part.
    const within_shaft = gray.at(44, 29) - gray.at(43, 29);
    try t.expect(@abs(gray.at(45, 29) - gray.at(44, 29) - within_shaft) <= 2);
    try t.expect(@abs(gray.at(46, 29) - gray.at(45, 29) - within_shaft) <= 2);
}

test "a radial gradient paints a stroke in the coordinates of its path" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var ring = try Path.circle(t.allocator, .{ .x = 30, .y = 30 }, 20);
    defer ring.deinit();
    const glow: DisplayList.Gradient = .{ .radial = .{ .start = .{ .x = 30, .y = 30 }, .end = .{ .x = 60, .y = 30 }, .colors = &.{ .black, .white } } };
    try picture.draw(ring, .{ .paint = .{ .gradient = &glow }, .width = 8 }, .{});
    {
        var output = try page(&library, &picture, .svg);
        defer output.deinit();
        try t.expect(std.mem.indexOf(u8, output.bytes(), "<radialGradient") != null);
        try t.expect(std.mem.indexOf(u8, output.bytes(), "<image") == null);
    }
    var output = try page(&library, &picture, .pdf);
    defer output.deinit();
    const gray = try Gray.read(output.bytes());
    defer gray.deinit();
    // The ring runs from 16 to 24 points out; its gray is the distance from
    // the center over the radius, 30, which over a pixel runs from its
    // nearest point to its farthest corner.
    for ([_][2]usize{ .{ 12, 29 }, .{ 47, 29 }, .{ 29, 10 }, .{ 30, 50 }, .{ 44, 15 } }) |sample| {
        // The pixel's square, from the center, in the picture's coordinates.
        const x = @as(f64, @floatFromInt(sample[0])) - 30;
        const y = 59 - @as(f64, @floatFromInt(sample[1])) - 30;
        const near: Point = .{ .x = std.math.clamp(0, x, x + 1), .y = std.math.clamp(0, y, y + 1) };
        const far: Point = .{ .x = @max(@abs(x), @abs(x + 1)), .y = @max(@abs(y), @abs(y + 1)) };
        try t.expect(gray.within(sample[0], sample[1], 255 * near.norm() / 30, 255 * far.norm() / 30));
    }
    // Inside the ring is the paper.
    try t.expectEqual(@as(f64, 255), gray.at(30, 29));
}

test "a stroke painted with patches is drawn as its footprint" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    var line = Path.init(t.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = 5, .y = 30 });
    try line.lineTo(.{ .x = 55, .y = 30 });
    const tiles = Tiles.init();
    try picture.draw(line, .{ .paint = .{ .gradient = &tiles.paint() }, .width = 10, .cap = .butt }, .{});
    {
        var output = try page(&library, &picture, .svg);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), "<image"));
        try t.expect(std.mem.indexOf(u8, output.bytes(), "clip-path=") != null);
    }
    {
        var output = try pageMesh(&library, &picture, .svg, .triangles);
        defer output.deinit();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes(), " data-typst-label=\"huak-mesh\""));
    }
    var output = try page(&library, &picture, .pdf);
    defer output.deinit();
    try t.expect(std.mem.indexOf(u8, output.bytes(), "/ShadingType 7") != null);
    const gray = try Gray.read(output.bytes());
    defer gray.deinit();
    // Within the stroke the gray follows the field; the patches cover the
    // whole page, but only the stroke is painted.
    for ([_]usize{ 10, 30, 50 }) |column| {
        const expected = 255 * (@as(f64, @floatFromInt(column)) + 0.5) / 60;
        try t.expect(@abs(gray.at(column, 29) - expected) <= 3);
    }
    for ([_][2]usize{ .{ 30, 10 }, .{ 30, 50 }, .{ 2, 29 }, .{ 57, 29 } }) |outside| {
        try t.expectEqual(@as(f64, 255), gray.at(outside[0], outside[1]));
    }
}

test "a fitted page measures each stroke the way it is drawn" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    // Both strokes are resolved before submission, the first because a mesh
    // paints it and the second because a nib shapes it. Fitting the page
    // measures them in the order they are drawn.
    var meshed = Path.init(t.allocator);
    defer meshed.deinit();
    try meshed.moveTo(.{ .x = 10, .y = 30 });
    try meshed.lineTo(.{ .x = 50, .y = 30 });
    const tiles = Tiles.init();
    try picture.draw(meshed, .{ .paint = .{ .gradient = &tiles.paint() }, .width = 10, .cap = .butt }, .{});
    var nibbed = Path.init(t.allocator);
    defer nibbed.deinit();
    try nibbed.moveTo(.{ .x = 10, .y = 50 });
    try nibbed.lineTo(.{ .x = 50, .y = 50 });
    try picture.draw(nibbed, .{ .nib = .{ .ellipse = .{ .a = 4, .d = 2 } }, .cap = .round }, .{});
    const fitted: render.Scene = .{ .picture = &picture };
    var diagnostic: ?typst.Buffer = null;
    {
        var output = try fitted.render(t.allocator, &library, .svg, &diagnostic);
        defer output.deinit();
        const svg = output.bytes();
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "<image"));
        // Non-mesh elements, including the nib's stroke, stay pure vector paths.
        try t.expect(std.mem.indexOf(u8, svg, "stroke-width=\"1\"") != null);
    }
    const fitted_tri: render.Scene = .{ .picture = &picture, .svg_mesh = .triangles };
    var output = try fitted_tri.render(t.allocator, &library, .svg, &diagnostic);
    defer output.deinit();
    const svg = output.bytes();
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, svg, " data-typst-label=\"huak-mesh\""));
    // The nib's stroke stays a native stroke of the normalized ellipse.
    try t.expect(std.mem.indexOf(u8, svg, "stroke-width=\"1\"") != null);
}
