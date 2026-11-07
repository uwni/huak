//! Directional envelope through real import, worker, render and error paths.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
pub const process_count = 11;

pub fn run(ctx: *h.Harness) !void {
    const script = try ctx.script("envelopes/main",
        \\import paint.*;import pen.pensquare
        \\caption:=typ[Directional envelope Ω]
        \\nib:=pensquare(4pt)
        \\curve:=rectangle((20,20),60,40)
        \\fn figure(inward:bool)->picture
        \\    p:=picture with width 160 height 100
        \\    source:=curve
        \\    if inward then source=reverse(source) end
        \\    boundary:=envelope of source with nib
        \\    drawing p do
        \\        +boundary filled rgb(0.1,0.4,0.8)
        \\        +caption at (4,85)
        \\    end
        \\    return p
        \\end
        \\export outside :=figure(false)
        \\default outside
        \\export inside:=figure(true)
    );
    _ = try ctx.command("check", script, &.{}, true);
    try h.contains((try ctx.command("disassemble", script, &.{}, true)).stdout, "call_builtin");
    for ([_][]const u8{ "1", "4" }) |jobs| {
        try h.output(try ctx.command("run", script, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=directional-{s}.svg", .{jobs}),
            try ctx.fmt("--output=inside=directional-inner-{s}.svg", .{jobs}),
            try ctx.fmt("--output=directional-{s}.pdf", .{jobs}),
        }, true), "");
        _ = try ctx.svg(try ctx.fmt("directional-{s}.svg", .{jobs}));
        _ = try ctx.svg(try ctx.fmt("directional-inner-{s}.svg", .{jobs}));
        try h.contains(try ctx.pdfText(try ctx.fmt("directional-{s}.pdf", .{jobs}), false), "Directional envelope Ω");
    }
    try t.expectEqualStrings(try ctx.read("directional-1.svg"), try ctx.read("directional-4.svg"));
    try t.expectEqualStrings(try ctx.read("directional-inner-1.svg"), try ctx.read("directional-inner-4.svg"));
    try t.expectEqualStrings(try ctx.read("directional-1.pdf"), try ctx.read("directional-4.pdf"));
    const broken = try ctx.script("envelopes/ellipse",
        \\import paint.{envelope, fill, picture};import pen.pencircle;fn broken()->picture
        \\    p:=picture(640, 480)
        \\    edge:=envelope((0,0)--(30,0),pencircle(4pt))
        \\    object.append(p, object.fill(edge))
        \\    return p
        \\end
        \\export first:=broken()
        \\export second:=broken()
    );
    const serial = try ctx.command("run", broken, &.{ "--jobs=1", "--output=first=ellipse-1.svg" }, false);
    const parallel = try ctx.command("run", broken, &.{ "--jobs=4", "--output=first=ellipse-4.svg" }, false);
    try h.contains(parallel.stderr, "EllipticalPen");
    try h.contains(parallel.stderr, "polygonal pen");
    try t.expectEqualStrings(serial.stderr, parallel.stderr);
    try ctx.absent("ellipse-1.svg");
    try ctx.absent("ellipse-4.svg");
    const angle = try ctx.script("envelopes/angle", "import paint.envelope;import pen.pensquare;curve:=(0,0)--(20,0)\nedge:=envelope(curve,pensquare(4pt),1deg)\n");
    try h.contains((try ctx.command("check", angle, &.{}, false)).stderr, "length");
    const tolerance = try ctx.script("envelopes/tolerance", "import paint.envelope;import pen.pensquare;curve:=(0,0)--(20,0)\nedge:=envelope(curve,pensquare(4pt),0pt)\n");
    try h.contains((try ctx.command("run", tolerance, &.{}, false)).stderr, "InvalidTolerance");
    const gradient = try ctx.script("envelopes/gradient",
        \\import paint.*; import pen.pensquare; import std.pen_motion.*; import assertions.assert
        \\param tolerance:length = 0.01pt
        \\motion := moving() do return scaling x (1 + t) y (1 + t) end
        \\stops := [rgb(0,0,0),rgb(1,0,0)]
        \\brush := pen(stops[0],nib:pensquare(1pt),motion:motion,tolerance:tolerance)
        \\curve := (100pt,6pt)--(110pt,6pt)
        \\item := object.linear_stroke(curve,(100pt,6pt),(110pt,6pt),stops,brush)
        \\assert(bounds(item) == bounds(object.draw(curve,brush)))
        \\default drawing picture(120pt,12pt) do +copy(item) end
        \\export fitted := drawing picture() do +item end
        \\assert(fitted.width == 11.5pt)
        \\assert(fitted.height == 2pt)
    );
    const fine = "--param=tolerance=0.0000001pt";
    _ = try ctx.command("run", gradient, &.{fine}, true);
    try h.contains((try ctx.command("run", gradient, &.{ fine, "--output=fine.svg" }, false)).stderr, "OutputPrecisionRange");
    try ctx.absent("fine.svg");
    _ = try ctx.command("run", gradient, &.{ "--output=gradient.svg", "--output=gradient.pdf", "--output=fitted=fitted.svg" }, true);
    try h.contains(try ctx.read("gradient.svg"), "<linearGradient");
    try h.contains(try ctx.read("gradient.pdf"), "/ShadingType");
    try (try ctx.svg("fitted.svg")).viewBox("0 0 11.5 2");
}
