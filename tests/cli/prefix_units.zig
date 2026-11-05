const h = @import("harness.zig");
pub fn run(ctx: *h.Harness) !void {
    const basic = try ctx.fixture("prefix/basics");
    _ = try ctx.command("check", basic, &.{}, true);
    try h.output(try ctx.command("run", basic, &.{}, true), "106\n");
    try h.contains((try ctx.command("disassemble", basic, &.{}, true)).stdout, "call");
    const builtins = try ctx.fixture("prefix/builtins");
    _ = try ctx.command("run", builtins, &.{}, true);
    _ = try ctx.fixture("prefix/lib/common");
    _ = try ctx.fixture("prefix/lib/brushes");
    const drawing = try ctx.fixture("prefix/drawing");
    try h.output(try ctx.command("run", drawing, &.{ "--output", "prefix.svg", "--output", "first=prefix.pdf", "--output", "second=prefix-second.svg" }, true), "target\ncurve\n");
    try (try ctx.svg("prefix.svg")).viewBox("0 0 120 80");
    try (try ctx.svg("prefix-second.svg")).viewBox("0 0 90 60");
    try h.contains(try ctx.pdfText("prefix.pdf", false), "Prefix drawing Ω");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "missing_function", .source = "mixfix missing _ in unary\n" },
        .{ .name = "missing_group", .source = "fn f(x:int)->int;return x;end\nmixfix f _ in missing\n" },
        .{ .name = "duplicate", .source = "fn f(x:int)->int;return x;end\nmixfix f _ in unary\nmixfix f _ in unary\n" },
        .{ .name = "no_arguments", .source = "fn f();end\nmixfix f _ in unary\n" },
        .{ .name = "two_scalars", .source = "fn f(x:int,y:int)->int;return x+y;end\nmixfix f _ in unary\n" },
        .{ .name = "three_arguments", .source = "fn f(p:picture,x:path,c:color);end\nmixfix f _ in unary\n" },
        .{ .name = "escaped_declaration", .source = "fn f(x:int)->int;return x;end\nif false then\nmixfix f _ in unary\nend\nvalue:=f 1\n" },
        .{ .name = "wrong_type", .source = "fn f(x:int)->int;return x;end\nmixfix f _ in unary\nvalue:=f \"wrong\"\n" },
        .{ .name = "dead_wrong_type", .source = "fn f(x:int)->int;return x;end\nmixfix f _ in unary\nif false then\nvalue:=f \"wrong\"\nend\n" },
        .{ .name = "private_import", .source = "import drawing.drawing;import paint.{circle, picture};import \"lib/brushes.huak\" as brushes\np:=circle((5,5),2)\npic:=picture(640, 480)\ndrawing pic do;brushes.privatepaint p;end\n" },
        .{ .name = "normal_has_no_role", .source = "import paint.circle;import \"lib/brushes.huak\" as brushes\np:=circle((5,5),2)\nvalue:=brushes.normal p\n" },
        .{ .name = "static_target", .source = "import drawing.drawing;drawing 1 do\nend\n" },
        .{ .name = "drawing_export", .source = "import drawing.drawing;import paint.picture;pic:=picture(640, 480)\ndrawing pic do;export pic;end\n" },
        .{ .name = "escaped_drawing_import", .source = "import drawing.drawing;import paint.picture;pic:=picture(640, 480)\ndrawing pic do;import \"lib/brushes.huak\" as brushes;end\nbrushes.paint pic\n" },
        .{ .name = "reserved_mixfix", .source = "mixfix=1\n" },
        .{ .name = "undeclared_drawing", .source = "drawing=1\n" },
    }) |case| {
        const path = try ctx.script(try ctx.fmt("prefix/invalid_{s}", .{case.name}), case.source);
        const result = try ctx.command("check", path, &.{}, false);
        try h.output(result, "");
        try h.contains(result.stderr, path);
    }
    const independent = try ctx.script("prefix/independent_objects",
        \\import drawing.drawing
        \\import paint.{circle, draw, picture}; import assertions.assert
        \\import "lib/brushes.huak" as brushes
        \\p:=circle((5,5),2)
        \\plain:=draw p
        \\painted:=brushes.paint p
        \\assert(plain.parent==false and painted.parent==false)
        \\pic:=picture(640, 480)
        \\drawing pic do; +draw p; end
        \\draw p
        \\assert(len(pic.children)==1)
    );
    _ = try ctx.command("run", independent, &.{}, true);
    const dynamic = try ctx.fixture("prefix/dynamic_target");
    const dynamic_result = try ctx.command("run", dynamic, &.{}, false);
    try h.contains(dynamic_result.stderr, "picture");
    try h.contains(dynamic_result.stderr, try ctx.fmt("{s}:3:", .{dynamic}));
    const early = try ctx.fixture("prefix/early");
    const early_result = try ctx.command("run", early, &.{}, false);
    try h.either(early_result.stderr, "import", "initializ");
    const units = try ctx.fixture("units/drawing");
    _ = try ctx.command("check", units, &.{}, true);
    _ = try ctx.command("run", units, &.{ "--param", "radius=2 cm", "--param", "angle=2 pi rad", "--output", "units.pdf", "--output", "pic=units.svg" }, true);
    _ = try ctx.svg("units.svg");
    try h.contains(try ctx.pdfText("units.pdf", false), "Native units Ω");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "identifier_boundary", .source = "x:=2pirad" }, .{ .name = "sum_dimensions", .source = "x:=1cm+1deg" }, .{ .name = "mixed_scalar", .source = "x:=1cm+1" }, .{ .name = "compare_dimensions", .source = "x:=1cm==1deg" }, .{ .name = "coordinate_dimensions", .source = "x:=(1cm,1deg)" }, .{ .name = "dead_dimensions", .source = "if false then;x:=1cm+1deg;end" },
    }) |case| {
        const path = try ctx.script(try ctx.fmt("units/invalid_{s}", .{case.name}), case.source);
        try h.contains((try ctx.command("check", path, &.{}, false)).stderr, path);
    }
    const dynamic_units = try ctx.fixture("units/dynamic");
    const unit_failure = try ctx.command("run", dynamic_units, &.{}, false);
    try h.contains(unit_failure.stderr, "dimension");
    try h.contains(unit_failure.stderr, try ctx.fmt("{s}:2:", .{dynamic_units}));
    for ([_][]const u8{ "2pirad", "1cm+1mm", "1deg" }) |value| {
        const failed = try ctx.command("run", units, &.{ "--param", try ctx.fmt("radius={s}", .{value}) }, false);
        try h.either(failed.stderr, "parameter", "expected length");
    }
    const pens = try ctx.fixture("pens/drawing");
    _ = try ctx.command("check", pens, &.{}, true);
    _ = try ctx.command("run", pens, &.{ "--output", "pens.svg", "--output", "pic=pens.pdf" }, true);
    _ = try ctx.svg("pens.svg");
    try h.contains(try ctx.pdfText("pens.pdf", false), "Native pens Ω");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "dash_zero", .source = "import paint.{rgb, pen};p:=pen(rgb(0,0,0),1mm,\"round\",\"round\",4,[0mm,0mm])" },
        .{ .name = "dash_negative", .source = "import paint.{rgb, pen};p:=pen(rgb(0,0,0),1mm,\"round\",\"round\",4,[-1mm,2mm])" },
        .{ .name = "miter_limit", .source = "import paint.{rgb, pen};p:=pen(rgb(0,0,0),1mm,\"round\",\"miter\",0.5)" },
        .{ .name = "cap", .source = "import paint.{rgb, pen};p:=pen(rgb(0,0,0),1mm,\"unknown\")" },
        .{ .name = "open_nib", .source = "import paint.{makepen, path};p:=makepen(path((0,0),(1mm,1mm)))" },
        .{ .name = "negative_nib", .source = "import paint.pencircle;p:=pencircle(-1mm)" },
        .{ .name = "tolerance", .source = "import paint.{pensquare, stroke_outline, path};p:=stroke_outline(path((0,0),(1mm,1mm)),pensquare(),0mm)" },
    }) |case| {
        const path = try ctx.script(try ctx.fmt("pens/invalid_{s}", .{case.name}), case.source);
        try h.contains((try ctx.command("run", path, &.{}, false)).stderr, path);
    }
}
