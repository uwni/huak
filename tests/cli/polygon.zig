const h = @import("harness.zig");

pub fn run(ctx: *h.Harness) !void {
    _ = try ctx.fixture("polygon/lib/regions");
    const drawing = try ctx.fixture("polygon/drawing");
    _ = try ctx.command("check", drawing, &.{}, true);
    const code = try ctx.command("disassemble", drawing, &.{}, true);
    try h.contains(code.stdout, "call_builtin");
    try h.contains(code.stdout, "regions.huak");
    _ = try ctx.command("run", drawing, &.{ "--output", "polygon.svg", "--output", "pic=polygon.pdf" }, true);
    _ = try ctx.svg("polygon.svg");
    try h.contains(try ctx.pdfText("polygon.pdf", false), "Native polygon regions Ω");
    for ([_]struct { name: []const u8, mode: []const u8 = "run", expression: []const u8 }{
        .{ .name = "open_boolean", .expression = "region_union(path((0,0),(1mm,0)),a)" },
        .{ .name = "open_offset", .expression = "offset(path((0,0),(1mm,0)),1mm)" },
        .{ .name = "open_region", .expression = "clip_region(path((0,0),(1mm,0)),(0,0),(2mm,2mm))" },
        .{ .name = "zero_tolerance", .expression = "region_union(a,b,0mm)" },
        .{ .name = "negative_tolerance", .expression = "clip_lines(path((0,0),(1mm,0)),(0,0),(2mm,2mm),-1mm)" },
        .{ .name = "fill_rule", .expression = "region_xor(a,b,0.001mm,\"unknown\")" },
        .{ .name = "offset_fill_rule", .expression = "offset(a,1mm,\"round\",4,0.001mm,\"unknown\")" },
        .{ .name = "clip_fill_rule", .expression = "clip_region(a,(0,0),(10mm,10mm),0.001mm,\"unknown\")" },
        .{ .name = "offset_join", .expression = "offset(a,1mm,\"unknown\")" },
        .{ .name = "stroke_cap", .expression = "stroke_path(a,1mm,\"unknown\")" },
        .{ .name = "stroke_join", .expression = "stroke_path(a,1mm,\"butt\",\"unknown\")" },
        .{ .name = "miter_limit", .expression = "offset(a,1mm,\"miter\",0.5)" },
        .{ .name = "negative_width", .expression = "stroke_path(a,-1mm)" },
        .{ .name = "region_rectangle", .expression = "clip_region(a,(5mm,5mm),(1mm,1mm))" },
        .{ .name = "line_rectangle", .expression = "clip_lines(a,(5mm,5mm),(1mm,1mm))" },
        .{ .name = "delta_dimension", .mode = "check", .expression = "offset(a,1deg)" },
        .{ .name = "width_dimension", .mode = "check", .expression = "stroke_path(a,1deg)" },
        .{ .name = "tolerance_dimension", .mode = "check", .expression = "region_union(a,b,1deg)" },
        .{ .name = "rectangle_dimension", .expression = "clip_region(a,(1deg,1deg),(2deg,2deg))" },
    }) |case| {
        const source = try ctx.fmt("import paint.{{rectangle, path}};import geometry.{{region_union, region_xor, offset, clip_region, clip_lines}};import pen.stroke_path;a:=rectangle((0,0),10mm,10mm); b:=rectangle((5mm,0),10mm,10mm)\nresult:={s}\n", .{case.expression});
        const file = try ctx.script(try ctx.fmt("polygon/invalid_{s}", .{case.name}), source);
        const failure = try ctx.command(case.mode, file, &.{}, false);
        try h.contains(failure.stderr, try ctx.fmt("{s}:2:", .{file}));
        try h.output(failure, "");
    }
}
