//! Explicit ordinary-library collection, signed passages and native export.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const prefix =
    "import paint.*\nimport weave.weave\na:=path((10pt,50pt),(90pt,50pt))\nb:=path((50pt,10pt),(50pt,90pt))\nink:=pen(rgb(0,0,0),6pt)\n";
const invalid = [_]struct { name: []const u8, body: []const u8, message: []const u8 }{
    .{ .name = "count", .body = "+draw a with ink crossings [1,2];+draw b with ink crossings [-1]", .message = "one signed ID" },
    .{ .name = "zero", .body = "+draw a with ink crossings [0];+draw b with ink crossings [1]", .message = "expected crossing 1" },
    .{ .name = "id", .body = "+draw a with ink crossings [2];+draw b with ink crossings [1]", .message = "expected crossing 1" },
    .{ .name = "both-over", .body = "+draw a with ink crossings [1];+draw b with ink crossings [1]", .message = "one over passage and one under passage" },
    .{ .name = "both-under", .body = "+draw a with ink crossings [-1];+draw b with ink crossings [-1]", .message = "one over passage and one under passage" },
    .{ .name = "float-id", .body = "+draw a with ink crossings [1.0];+draw b with ink crossings [-1]", .message = "int" },
    .{ .name = "string-id", .body = "+draw a with ink crossings [\"1\"];+draw b with ink crossings [-1]", .message = "int" },
    .{ .name = "extra-id", .body = "+draw a with ink crossings [1]", .message = "one signed ID" },
    .{ .name = "self-conflict", .body = "+draw (10pt,10pt)--(90pt,90pt)--(10pt,90pt)--(90pt,10pt) with ink crossings [1,1]", .message = "one over passage and one under passage" },
};
pub const process_count = 9 + invalid.len;

pub fn run(ctx: *h.Harness) !void {
    const script = try ctx.fixture("weave/basic");
    _ = try ctx.command("check", script, &.{}, true);
    try h.contains((try ctx.command("disassemble", script, &.{}, true)).stdout, "call");
    for ([_][]const u8{ "1", "4" }) |jobs| {
        try h.output(try ctx.command("run", script, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=weave-{s}.svg", .{jobs}),
            try ctx.fmt("--output=explicit=weave-explicit-{s}.svg", .{jobs}),
            try ctx.fmt("--output=reversed=weave-reversed-{s}.svg", .{jobs}),
            try ctx.fmt("--output=self_crossing=weave-self-{s}.svg", .{jobs}),
            try ctx.fmt("--output=hopf=weave-hopf-{s}.svg", .{jobs}),
            try ctx.fmt("--output=partial_hopf=weave-partial-hopf-{s}.svg", .{jobs}),
            try ctx.fmt("--output=partial_second_hopf=weave-partial-second-hopf-{s}.svg", .{jobs}),
            try ctx.fmt("--output=trefoil=weave-trefoil-{s}.svg", .{jobs}),
            try ctx.fmt("--output=trefoil=weave-trefoil-{s}.pdf", .{jobs}),
            try ctx.fmt("--output=hopf=weave-hopf-{s}.pdf", .{jobs}),
        }, true), "weave checks passed\n");
        const automatic = try ctx.read(try ctx.fmt("weave-{s}.svg", .{jobs}));
        try t.expectEqualStrings(automatic, try ctx.read(try ctx.fmt("weave-explicit-{s}.svg", .{jobs})));
        try t.expect(!std.mem.eql(u8, automatic, try ctx.read(try ctx.fmt("weave-reversed-{s}.svg", .{jobs}))));
        try t.expectEqualStrings(try ctx.read(try ctx.fmt("weave-hopf-{s}.svg", .{jobs})), try ctx.read(try ctx.fmt("weave-partial-hopf-{s}.svg", .{jobs})));
        try t.expectEqualStrings(try ctx.read(try ctx.fmt("weave-hopf-{s}.svg", .{jobs})), try ctx.read(try ctx.fmt("weave-partial-second-hopf-{s}.svg", .{jobs})));
        for ([_][]const u8{ "weave", "weave-self", "weave-hopf", "weave-trefoil" }) |name| {
            const svg = try ctx.svg(try ctx.fmt("{s}-{s}.svg", .{ name, jobs }));
            try svg.viewBox("0 0 100 100");
            try t.expect(svg.count("path") > 0);
            try t.expect(svg.count("clipPath") > 0);
        }
        try h.contains(try ctx.read(try ctx.fmt("weave-hopf-{s}.pdf", .{jobs})), "%PDF-");
        try h.contains(try ctx.read(try ctx.fmt("weave-trefoil-{s}.pdf", .{jobs})), "%PDF-");
        const knot = try ctx.svg(try ctx.fmt("weave-trefoil-{s}.svg", .{jobs}));
        // One native stroke paints the translucent self crossing once. Typst
        // may encode alpha in its color rather than a stroke-opacity attribute.
        var strokes: usize = 0;
        for (knot.elements) |element| {
            if (std.mem.eql(u8, element.name, "path") and element.attr("stroke") != null) strokes += 1;
        }
        try t.expectEqual(@as(usize, 1), strokes);
    }
    try t.expectEqualStrings(try ctx.read("weave-1.svg"), try ctx.read("weave-4.svg"));
    try t.expectEqualStrings(try ctx.read("weave-hopf-1.svg"), try ctx.read("weave-hopf-4.svg"));
    try t.expectEqualStrings(try ctx.read("weave-trefoil-1.svg"), try ctx.read("weave-trefoil-4.svg"));
    const diagonal = try ctx.fixture("weave/diagonal");
    _ = try ctx.command("run", diagonal, &.{ "--output=diagonal.svg", "--output=diagonal.pdf" }, true);
    try t.expect((try ctx.svg("diagonal.svg")).count("clipPath") >= 2);
    try h.contains(try ctx.read("diagonal.pdf"), "%PDF-");
    const blocks = try ctx.script("weave/blocks",
        \\import paint.*
        \\import weave.weave
        \\import assertions.assert
        \\a := path((0pt,0pt),(10pt,0pt))
        \\b := path((0pt,20pt),(10pt,20pt))
        \\plate := picture(100pt,100pt)
        \\ink := pen(rgb(0,0,0), 2pt)
        \\ordinary := picture()
        \\outer := weave do
        \\    item := draw b with ink
        \\    assert(item.kind == "path")
        \\    drawing ordinary do
        \\        +item
        \\        +draw b with ink
        \\    end
        \\    draw b
        \\    +draw a
        \\    inner := weave(tolerance:0.002pt, gap:2pt) do +draw b end
        \\    assert(len(inner.children)==1)
        \\    assert(bounds(inner)[0].y > 10pt)
        \\    +draw path((0pt,4pt),(10pt,4pt))
        \\end
        \\assert(len(outer.children)==2)
        \\assert(bounds(outer)[1].y < 10pt)
        \\assert(len(ordinary.children)==2)
        \\assert(bounds(ordinary)[0] == bounds(draw(b, ink))[0])
        \\assert(len(plate.children)==0)
        \\drawing plate do
        \\    +outer
        \\    +weave do +draw b end
        \\    +draw a
        \\end
        \\assert(len(plate.children)==3)
        \\early := weave do
        \\    +draw a
        \\    return picture()
        \\end
        \\assert(len(early.children)==0)
    );
    _ = try ctx.command("run", blocks, &.{}, true);
    for (invalid) |case| {
        const source = try ctx.fmt("{s}default weave do;{s};end\n", .{ prefix, case.body });
        const file = try ctx.script(try ctx.fmt("weave/invalid-{s}", .{case.name}), source);
        const failure = try ctx.command("run", file, &.{"--output=weave-invalid.svg"}, false);
        try h.contains(failure.stderr, case.message);
        try ctx.absent("weave-invalid.svg");
    }
    for ([_]struct { name: []const u8, option: []const u8, message: []const u8 }{
        .{ .name = "gap", .option = "gap:-1pt", .message = "gap must be nonnegative" },
        .{ .name = "tolerance", .option = "tolerance:0pt", .message = "tolerance must be positive" },
    }) |case| {
        const file = try ctx.script(try ctx.fmt("weave/invalid-{s}", .{case.name}), try ctx.fmt("{s}weave({s}) do end\n", .{ prefix, case.option }));
        try h.contains((try ctx.command("run", file, &.{}, false)).stderr, case.message);
    }
    const standalone = try ctx.script("weave/standalone",
        \\import weave.weave
        \\import assertions.assert
        \\import color.rgb
        \\empty:picture := weave do end
        \\assert(len(empty.children) == 0)
        \\unused := weave do
        \\    item := draw ((0pt,0pt) -- (10pt,0pt)) with pen(rgb(0,0,0), 2pt)
        \\    assert(item.kind == "path")
        \\end
        \\assert(len(unused.children) == 0)
    );
    _ = try ctx.command("run", standalone, &.{}, true);
}
