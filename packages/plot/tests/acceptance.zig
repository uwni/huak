//! Run from packages/plot: zig run -OReleaseSafe tests/acceptance.zig -- HUAK LIBTYPST
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedHuakAndLibrary;
    const check: Check = .{ .a = a, .io = init.io, .binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a), .library = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a) };
    try std.Io.Dir.cwd().createDirPath(init.io, "target/acceptance");
    for ([_][]const u8{ "core", "statistics", "layout" }) |name| {
        const output = try check.huak(&.{ "run", try check.fmt("tests/{s}.huak", .{name}) }, true);
        try contains(output, "checks passed");
    }
    const examples = [_][]const u8{ "basic", "axes", "statistical", "heatmap", "markers", "composition", "four_sides", "broken_axes" };
    for (examples) |name| {
        const source = try check.fmt("examples/{s}.huak", .{name});
        _ = try check.huak(&.{ "check", source }, true);
        for ([_][]const u8{ "1", "4" }) |jobs| {
            _ = try check.huak(&.{ "run", source, "--jobs", jobs, try check.fmt("--output=target/acceptance/{s}-{s}.svg", .{ name, jobs }), try check.fmt("--output=target/acceptance/{s}-{s}.pdf", .{ name, jobs }) }, true);
        }
        for ([_][]const u8{ "svg", "pdf" }) |format| {
            const first = try check.read(try check.fmt("target/acceptance/{s}-1.{s}", .{ name, format }));
            const second = try check.read(try check.fmt("target/acceptance/{s}-4.{s}", .{ name, format }));
            if (!std.mem.eql(u8, first, second)) return error.ParallelOutputChanged;
            try contains(first, if (std.mem.eql(u8, format, "svg")) "<svg" else "%PDF-");
        }
        _ = try check.process(&.{ "rsvg-convert", "-o", try check.fmt("target/acceptance/{s}.png", .{name}), try check.fmt("target/acceptance/{s}-1.svg", .{name}) }, true);
        const text = try check.process(&.{ "pdftotext", try check.fmt("target/acceptance/{s}-1.pdf", .{name}), "-" }, true);
        if (text.len < 10) return error.MissingPdfText;
        if (std.mem.eql(u8, name, "four_sides")) {
            for ([_][]const u8{ "Frequency band", "Frequency (Hz)", "Gain (dB)", "Phase (degrees)" }) |label| try contains(text, label);
        }
    }
    _ = try check.huak(&.{ "run", "tests/layout.huak", "--output=first=target/acceptance/first.svg", "--output=second=target/acceptance/second.svg" }, true);
    if (!std.mem.eql(u8, try check.read("target/acceptance/first.svg"), try check.read("target/acceptance/second.svg"))) return error.RepeatedRenderChanged;
    _ = try check.huak(&.{ "run", "tests/render_contracts.huak", "--output=linear=target/acceptance/probe-linear.pdf", "--output=logarithmic=target/acceptance/probe-logarithmic.pdf" }, true);
    for ([_][]const u8{ "linear", "logarithmic" }) |name| {
        _ = try check.process(&.{ "pdftoppm", "-r", "72", "-singlefile", try check.fmt("target/acceptance/probe-{s}.pdf", .{name}), try check.fmt("target/acceptance/probe-{s}", .{name}) }, true);
        try verifyPixels(try check.read(try check.fmt("target/acceptance/probe-{s}.ppm", .{name})));
    }
    try contains(try check.huak(&.{ "run", "tests/rulers.huak", "--output=target/acceptance/rulers.pdf" }, true), "ruler checks passed");
    _ = try check.process(&.{ "pdftoppm", "-r", "72", "-singlefile", "target/acceptance/rulers.pdf", "target/acceptance/rulers" }, true);
    try verifyRulers(try check.read("target/acceptance/rulers.ppm"));
    try contains(try check.huak(&.{ "run", "tests/breaks.huak", "--output=target/acceptance/breaks.pdf", "--output=segmented=target/acceptance/segmented.svg" }, true), "break checks passed");
    const segmented = try check.read("target/acceptance/segmented.svg");
    if (std.mem.indexOf(u8, segmented, "<clipPath") != null) return error.DecorationsUseClip;
    // Both shafts, both slashes and the single outer arrowhead use the native pen.
    for ([_][]const u8{ "stroke-dasharray=\"6 3\"", "stroke-dashoffset=\"1\"" }) |style| {
        if (std.mem.count(u8, segmented, style) != 5) return error.WrongBrokenSpinePen;
    }
    _ = try check.process(&.{ "pdftoppm", "-r", "72", "-singlefile", "target/acceptance/breaks.pdf", "target/acceptance/breaks" }, true);
    try verifyBreaks(try check.read("target/acceptance/breaks.ppm"));
    try contains(try check.huak(&.{ "run", "tests/options.huak", "--output=legend_sample=target/acceptance/legend-sample.svg", "--output=legend_bare=target/acceptance/legend-bare.svg" }, true), "plot option checks passed");
    // legend_line=false removes exactly the legend sample: one line for the
    // red series and the three errorbar strokes for the blue one.
    const legend_sample = try check.read("target/acceptance/legend-sample.svg");
    const legend_bare = try check.read("target/acceptance/legend-bare.svg");
    for ([_]struct { stroke: []const u8, sample: usize }{ .{ .stroke = "stroke=\"#ff0000\"", .sample = 1 }, .{ .stroke = "stroke=\"#0000ff\"", .sample = 3 } }) |series| {
        if (std.mem.count(u8, legend_sample, series.stroke) != std.mem.count(u8, legend_bare, series.stroke) + series.sample) return error.WrongLegendSample;
    }
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "a:=axis(f); plotting a do xlim [0,10]; breaks \"bottom\" over [[2,6],[5,8]] end; render(f)", .expected = "ordered, disjoint" },
        .{ .source = "a:=axis(f); plotting a do xlim [0,10]; breaks \"bottom\" over [[2,6]] gap 400pt end; render(f)", .expected = "fit inside" },
        .{ .source = "a:=axis(f); plotting a do +bar categories [\"A\"] values [1]; breaks \"bottom\" over [[0,1]] end; render(f)", .expected = "require a numeric scale" },
        .{ .source = "a:=axis(f); b:=axis(f,(1,0)); plotting a do xlim [0,10]; breaks \"bottom\" over [[2,6]] end; plotting b do breaks \"bottom\" over [[3,7]] end; link_x(f,[a,b]); render(f)", .expected = "conflicting breaks" },
        .{ .source = "a:=axis(f); plotting a do side \"north\" with {} end", .expected = "unknown axis side" },
        .{ .source = "a:=axis(f); plotting a do title typ[T]; settings {\"title_align\":\"top\"}; +lines x [0,1] y [0,1] end; render(f)", .expected = "title_align must be left, center or right" },
        .{ .source = "a:=axis(f); plotting a do +scatter x [0] y [0] on_axes x \"top\" y \"right\" end; render(f)", .expected = "undeclared axis side" },
        .{ .source = "a:=axis(f); plotting a do remap \"top\" ticks [1,10] to [typ[A]] end", .expected = "labels differ" },
        .{ .source = "a:=axis(f); plotting a do side \"bottom\" with {\"decades\":[1,2,5]} end; render(f)", .expected = "require a log10 scale" },
        .{ .source = "a:=axis(f); plotting a do side \"bottom\" with {\"scale\":\"log10\",\"decades\":[1,10]} end; render(f)", .expected = "decade multipliers" },
        .{ .source = "a:=axis(f); plotting a do side \"left\" with {\"arrow\":\"middle\"} end; render(f)", .expected = "unknown arrow ends" },
        .{ .source = "a:=axis(f); plotting a do +annotate(0.5,0.5,typ[note]) styled {\"align\":\"middle\"} end; render(f)", .expected = "unknown annotation align" },
        .{ .source = "a:=axis(f); plotting a do +annotate(0.5,0.5,typ[#box[n] <n>]) styled {\"part\":\"m\"} end; render(f)", .expected = "annotation has no part labeled m" },
        .{ .source = "lines([1],[1,2])", .expected = "lengths differ" },
        .{ .source = "marker(\"bogus\")", .expected = "unknown marker" },
        .{ .source = "marker(\"circle\") sized -1pt", .expected = "positive" },
        .{ .source = "a:=axis(f); plotting a do xscale \"log10\"; +lines x [0,1] y [1,2] end; render(f)", .expected = "positive data" },
        .{ .source = "a:=axis(f); plotting a do xlim [2,1] end; render(f)", .expected = "increasing" },
        .{ .source = "a:=axis(f); plotting a do +errorbars x [1] y [2] errors [-1] end; render(f)", .expected = "nonnegative" },
        .{ .source = "a:=axis(f); plotting a do +band x [1] lower [2] upper [1] end; render(f)", .expected = "lower bound" },
        .{ .source = "a:=axis(f); plotting a do +heatmap [[1,2],[3]] end; render(f)", .expected = "rectangular" },
        .{ .source = "a:=axis(f); plotting a do +scatter x [0,1] y [0,1] styled {\"sizes\":[2pt]} end; render(f)", .expected = "sizes length" },
        .{ .source = "a:=axis(f); plotting a do settings {\"xticks\":[0,1],\"xlabels\":[typ[one]]} end; render(f)", .expected = "labels differ" },
        .{ .source = "a:=axis(f); axis(f)", .expected = "already occupied" },
        .{ .source = "a:=axis(f); b:=axis(f,(1,0)); configure(b,{\"xscale\":\"log10\"}); link_x(f,[a,b]); render(f)", .expected = "same scale" },
        .{ .source = "a:=axis(f); b:=axis(f,(1,0)); configure(a,{\"xlim\":[0,1]}); configure(b,{\"xlim\":[0,2]}); link_x(f,[a,b]); render(f)", .expected = "conflicting limits" },
        .{ .source = "a:=axis(f); configure(a,{\"xlable\":typ[x]})", .expected = "unknown plot option" },
        .{ .source = "a:=axis(f); plotting a do +lines x [1] y [\"bad\"] end; render(f)", .expected = "expected number" },
        .{ .source = "a:=axis(f); plotting a do +hist([1,2],edges:[0,0,1]) end; render(f)", .expected = "edges must increase" },
        .{ .source = "a:=axis(f); plotting a do colorbar \"right\" end; render(f)", .expected = "requires a heatmap" },
        .{ .source = "a:=axis(f); b:=axis(f,(1,0)); c:=axis(f,(2,0)); configure(a,{\"xticks\":[0,1]}); configure(c,{\"xticks\":[0,2]}); link_x(f,[a,b]); link_x(f,[b,c]); render(f)", .expected = "conflicting ticks" },
    };
    for (cases, 0..) |case, i| {
        const path = try check.fmt("target/acceptance/invalid-{d}.huak", .{i});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = try check.fmt("import \"../../plot.huak\".*\nf:=figure(400pt,300pt)\n{s}\n", .{case.source}) });
        try contains(try check.huak(&.{ "run", path }, false), case.expected);
    }
    std.debug.print("Plot acceptance passed: 6 numerical/DSL suites, {d} galleries, {d} SVG/PDF gallery exports, repeated/parallel equality, native PDF text, clipping/marker/axis/arrow/break raster contracts, {d} negative cases.\n", .{ examples.len, examples.len * 4, cases.len });
}

const Check = struct {
    a: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    library: []const u8,
    fn fmt(self: Check, comptime pattern: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.a, pattern, args);
    }
    fn read(self: Check, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(64 * 1024 * 1024));
    }
    fn process(self: Check, argv: []const []const u8, success: bool) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{any}\n{s}\n{s}\n", .{ argv, result.stdout, result.stderr });
            return error.UnexpectedProcessResult;
        }
        return if (success) result.stdout else result.stderr;
    }
    fn huak(self: Check, args: []const []const u8, success: bool) ![]const u8 {
        const argv = try self.a.alloc([]const u8, args.len + 3);
        argv[0] = self.binary;
        @memcpy(argv[1 .. args.len + 1], args);
        argv[args.len + 1] = "--libtypst";
        argv[args.len + 2] = self.library;
        return self.process(argv, success);
    }
};
fn contains(bytes: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, bytes, expected) == null) {
        std.debug.print("Expected {s}:\n{s}\n", .{ expected, bytes });
        return error.MissingExpectedText;
    }
}

// Poppler at 72 dpi gives one pixel per physical point. These expectations
// are independent of SVG markup: no data may escape x = 13..190, and the
// 12 pt blue square must retain the same physical footprint on both scales.
fn verifyPixels(ppm: []const u8) !void {
    const pixels = try probePixels(ppm);
    var blue: usize = 0;
    var red: usize = 0;
    for (0..200) |y| for (0..200) |x| {
        const p = pixels[(y * 200 + x) * 3 ..][0..3];
        if (x < 12 or x > 190) {
            if (!std.mem.eql(u8, p, &.{ 255, 255, 255 })) return error.DataEscapedClip;
        }
        if (p[2] > 240 and p[0] < 20 and p[1] < 20) {
            if (x < 95 or x > 108 or y < 47 or y > 61) return error.MarkerMovedOrStretched;
            blue += 1;
        }
        if (p[0] > 240 and p[1] < 20 and p[2] < 20) red += 1;
    };
    if (blue < 110 or blue > 169 or red < 175) return error.MissingOrMisSizedGeometry;
}

fn verifyRulers(ppm: []const u8) !void {
    const pixels = try probePixels(ppm);
    var marker: usize = 0;
    var data_head: usize = 0;
    var reversed_head: usize = 0;
    var line_heads = [2]usize{ 0, 0 };
    for (0..200) |y| for (0..200) |x| {
        const p = pixels[(y * 200 + x) * 3 ..][0..3];
        if (p[0] > 240 and p[1] < 30 and p[2] < 30) {
            // log10(10) is halfway across. Reversed 50/200 is 3/4 up.
            if (x < 95 or x > 104 or y < 51 or y > 61) return error.LayerUsesWrongRuler;
            marker += 1;
        }
        if (p[1] > 100 and p[0] < 100 and p[2] < 100 and (y < 98 or y > 101)) {
            if (x < 147 or x > 159) return error.DataArrowPointsBackward;
            data_head += 1;
        }
        if (p[2] > 200 and p[0] < 100 and p[1] < 100 and (x < 185 or x > 188)) {
            if (y < 173 or y > 185) return error.AxisArrowPointsBackward;
            reversed_head += 1;
        }
        if (p[0] > 200 and p[2] > 200 and p[1] < 100) {
            if (x > 58 and x < 115) return error.LineCrossesMissingSample;
            if (y < 142 or y > 145) {
                if (x > 44 and x < 56) line_heads[0] += 1 else if (x > 140 and x < 152) line_heads[1] += 1 else return error.MisplacedLineArrow;
            }
        }
    };
    if (marker < 45 or data_head < 6 or reversed_head < 6 or line_heads[0] < 4 or line_heads[1] < 4) return error.MissingRulerGeometry;
}

fn probePixels(ppm: []const u8) ![]const u8 {
    const header = "P6\n200 200\n255\n";
    if (!std.mem.startsWith(u8, ppm, header) or ppm.len != header.len + 200 * 200 * 3) return error.UnexpectedRaster;
    return ppm[header.len..];
}

fn verifyBreaks(ppm: []const u8) !void {
    const pixels = try probePixels(ppm);
    var red: usize = 0;
    var green = [2]usize{ 0, 0 };
    for (0..200) |y| for (0..200) |x| {
        const p = pixels[(y * 200 + x) * 3 ..][0..3];
        // The data and grid leave the break transparent. Within 5 pt of a
        // spine the slashes themselves can cross into the gap.
        if ((x >= 94 and x <= 108 and (y < 182 or y > 192)) or
            (y >= 91 and y <= 105 and (x < 8 or x > 18)))
        {
            if (p[0] != 255 or p[1] != 204 or p[2] != 0) return error.BreakIsNotTransparent;
        }
        // Follow the black shafts along their full retained lengths, right
        // up to each slash. The middle of each break shows the orange page.
        if ((y == 187 and ((x >= 13 and x < 93) or (x >= 110 and x < 190))) or
            (x == 12 and ((y >= 10 and y < 90) or (y >= 107 and y < 187))))
        {
            if (!std.mem.eql(u8, p, &.{ 0, 0, 0 })) return error.SpineStopsBeforeBreakMark;
        }
        if ((y == 187 and x >= 95 and x <= 106) or (x == 12 and y >= 93 and y <= 103)) {
            if (!std.mem.eql(u8, p, &.{ 255, 204, 0 })) return error.SpineCrossesBreak;
        }
        if (p[0] > 220 and p[2] > 220 and p[1] < 40) return error.OmittedMarkerVisible;
        if (p[0] > 220 and p[1] < 40 and p[2] < 40) {
            if (x < 146 or x > 154 or y < 143 or y > 151) return error.WrongBrokenCoordinate;
            red += 1;
        }
        if (x >= 52 and x <= 54 and p[1] > 140 and p[0] < 50 and p[2] < 50) {
            if (y > 107) green[0] += 1 else if (y < 90) green[1] += 1;
        }
    };
    if (red < 25 or green[0] < 28 or green[1] < 28) return error.BrokenLayerMissing;
    // Crossings on each side follow the original slope, even though the two
    // data endpoints fall into different x and y intervals.
    for ([_][2]usize{ .{ 33, 131 }, .{ 170, 66 } }) |xy| {
        const p = pixels[(xy[1] * 200 + xy[0]) * 3 ..][0..3];
        if (p[0] < 160 or p[1] < 160 or p[2] < 160) return error.WrongBreakIntersection;
    }
}
