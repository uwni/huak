//! Label anchors of native layouts in the bundled example, serial and in workers.
const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

pub const process_count = 4;

pub fn run(ctx: *h.Harness) !void {
    const example = try std.Io.Dir.cwd().readFileAlloc(t.io, "examples/language/anchors.huak", ctx.allocator(), .unlimited);
    const source = try ctx.script("anchors/example", example);
    try h.output(try ctx.command("check", source, &.{}, true), "");
    for ([_][]const u8{ "1", "4" }) |jobs| {
        _ = try ctx.command("run", source, &.{
            try ctx.fmt("--jobs={s}", .{jobs}),
            try ctx.fmt("--output=anchors-{s}.svg", .{jobs}),
            try ctx.fmt("--output=anchors-{s}.pdf", .{jobs}),
        }, true);
        const svg = try ctx.svg(try ctx.fmt("anchors-{s}.svg", .{jobs}));
        // Each arrow is a stroked shaft and a filled head in its own color.
        for ([_][]const u8{ "#1a59bf", "#cc3326" }) |ink| {
            try t.expect(svg.hasAttribute("stroke", ink));
            try t.expect(svg.hasAttribute("fill", ink));
        }
        // The matrix stays native text, entries included.
        const text = try ctx.pdfText(try ctx.fmt("anchors-{s}.pdf", .{jobs}), false);
        for ([_][]const u8{ "𝑀", "𝑎", "𝑏", "𝑐", "𝑑" }) |glyph| try h.contains(text, glyph);
    }
    try t.expectEqualStrings(try ctx.read("anchors-1.svg"), try ctx.read("anchors-4.svg"));
    try t.expectEqualStrings(try ctx.read("anchors-1.pdf"), try ctx.read("anchors-4.pdf"));
    const repeated = try ctx.script("anchors/repeated", "x:=typ[#box[A] <same> and #box[B] <same>].anchors");
    const failure = try ctx.command("run", repeated, &.{}, false);
    try h.contains(failure.stderr, "label <same> occurs more than once in the typeset content");
}
