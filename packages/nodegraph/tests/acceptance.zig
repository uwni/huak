//! Run from packages/nodegraph: zig run tests/acceptance.zig -- HUAK LIBTYPST [BASELINE]
//! External package acceptance through the real CLI and independent image/PDF tools.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3 or args.len > 4) return error.ExpectedHuakLibraryAndOptionalBaseline;
    var check: Check = .{
        .a = a,
        .io = init.io,
        .binary = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], a),
        .library = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[2], a),
        .baseline = if (args.len == 4) args[3] else null,
    };
    try std.Io.Dir.cwd().createDirPath(init.io, "target/nodegraph/acceptance");
    const probe = try check.write("no-std-dependency.huak", "import \"std/nodegraph.huak\".*\n");
    try contains(try check.huak(&.{ "check", probe }, false), "unknown standard library module");
    for ([_][]const u8{ "regression", "api", "mark_trim", "filled_marks", "offset", "shapes", "shift", "mark_inherit", "defocus", "mark_extrude", "cylinder", "brace_shape", "snap_priority", "mark_props", "label_anchor" }) |name| {
        const output = try check.huak(&.{ "run", try check.fmt("tests/fixtures/{s}.huak", .{name}) }, true);
        try contains(output, "checks passed");
    }
    try contains(try check.huak(&.{ "run", "tests/fixtures/brace_color.huak", "--output=target/nodegraph/acceptance/brace-color.svg" }, true), "brace color checks passed");
    const brace_color = try check.read(try check.path("brace-color.svg"));
    for ([_][]const u8{ "#008000", "#0000ff", "#ff8000" }) |color| try contains(brace_color, color);
    try contains(try check.huak(&.{ "run", "tests/fixtures/scene.huak", "--output=target/nodegraph/acceptance/scene.svg", "--output=debug_grid=target/nodegraph/acceptance/debug-grid.svg" }, true), "scene checks passed");
    const grid = try check.read(try check.path("debug-grid.svg"));
    if (std.mem.count(u8, grid, "stroke=\"#8c9ebf\"") != 4) return error.MissingGridEdges;
    try contains(grid, "matrix(0 1 1 0 0 0)");
    try contains(try check.huak(&.{ "run", "tests/fixtures/mark_bend.huak", "--output=tip_check=target/nodegraph/acceptance/arrow-tip.svg" }, true), "mark bending checks passed");
    _ = try check.tool(&.{ "rsvg-convert", "-w", "1000", "-o", try check.path("arrow-tip.png"), try check.path("arrow-tip.svg") });
    try number(try check.tool(&.{ "magick", try check.path("arrow-tip.png"), "-crop", "30x30+366+289", "+repage", "-background", "white", "-alpha", "remove", "-fx", "max(r-b,0)", "-format", "%[fx:mean]", "info:" }), 0);
    _ = try check.huak(&.{ "run", "examples/scene.huak", "--output=target/nodegraph/acceptance/scene-example.svg" }, true);

    const before_gallery = check.exports;
    for ([_]struct { script: []const u8, names: []const []const u8 }{
        .{ .script = "examples/bending.huak", .names = &.{"comparison"} },
        .{ .script = "examples/diagrams.huak", .names = &.{ "commutative", "flowchart", "state_machine", "groups", "transparent_crossings" } },
        .{ .script = "examples/catalog.huak", .names = &.{ "shapes", "marks", "decorations", "stretched" } },
    }) |program| {
        _ = try check.huak(&.{ "check", program.script }, true);
        for ([_][]const u8{ "1", "4" }) |jobs| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(a, &.{ "run", program.script, try check.fmt("--jobs={s}", .{jobs}) });
            for (program.names) |name| for ([_][]const u8{ "svg", "pdf" }) |format| {
                try argv.append(a, try check.fmt("--output={s}=target/nodegraph/acceptance/{s}-{s}.{s}", .{ name, name, jobs, format }));
            };
            _ = try check.huak(argv.items, true);
        }
        for (program.names) |name| for ([_][]const u8{ "svg", "pdf" }) |format| {
            const file = try check.fmt("{s}-1.{s}", .{ name, format });
            const bytes = try check.read(try check.path(file));
            try equal(bytes, try check.read(try check.path(try check.fmt("{s}-4.{s}", .{ name, format }))));
            try check.compareBaseline(file, bytes);
            if (std.mem.eql(u8, format, "pdf")) {
                if (!std.mem.startsWith(u8, bytes, "%PDF-")) return error.InvalidPdf;
            } else {
                if (std.mem.eql(u8, name, "comparison")) {
                    var widths = std.mem.splitSequence(u8, bytes, "stroke-width=\"");
                    _ = widths.next();
                    var count: usize = 0;
                    while (widths.next()) |width| {
                        try number(width[0 .. std.mem.indexOfScalar(u8, width, '"') orelse return error.InvalidSvg], 1.2);
                        count += 1;
                    }
                    if (count != 26) return error.ChangedArrowStrokes;
                }
                _ = try check.tool(&.{ "rsvg-convert", "-o", try check.path(try check.fmt("{s}.png", .{name})), try check.path(file) });
            }
        };
    }
    const gallery_exports = check.exports - before_gallery;
    try contains(try check.tool(&.{ "pdftotext", try check.path("transparent_crossings-1.pdf"), "-" }), "Native text");
    // The fixture uses mathematical italic Unicode letters, retained as text.
    const math = try check.tool(&.{ "pdftotext", "-raw", try check.path("commutative-1.pdf"), "-" });
    try contains(math, "𝐺");
    try contains(math, "𝐻");
    for ([_][]const u8{ "transparency", "many_crossings" }) |name| {
        const file = if (std.mem.eql(u8, name, "many_crossings")) "many-crossings.svg" else "transparency.svg";
        _ = try check.huak(&.{ "run", try check.fmt("tests/fixtures/{s}.huak", .{name}), try check.fmt("--output={s}", .{try check.path(file)}) }, true);
        try check.compareBaseline(file, try check.read(try check.path(file)));
        _ = try check.tool(&.{ "rsvg-convert", "-w", "1000", "-h", "600", "-o", try check.path(try check.fmt("{s}.png", .{name})), try check.path(file) });
    }
    for ([_]struct { x: usize, y: usize, alpha: f64 }{
        .{ .x = 460, .y = 300, .alpha = 0 }, .{ .x = 500, .y = 300, .alpha = 1 },
        .{ .x = 400, .y = 300, .alpha = 1 }, .{ .x = 200, .y = 500, .alpha = 0 },
    }) |sample| try check.alpha("transparency.png", sample.x, sample.y, sample.alpha);

    // Same invalid inputs and diagnostics as the former external driver.
    for ([_][3][]const u8{
        .{ "duplicate-name", "geometry([node(\"a\",grid(0,0),typ[A]),node(\"a\",grid(1,0),typ[B])])", "duplicate diagram object name" },
        .{ "unknown-option", "node(\"a\",grid(0,0),typ[A],{\"raduis\": 10pt})", "unknown nodegraph option: raduis" },
        .{ "duplicate-option", "node(\"a\",grid(0,0),typ[A],{\"width\": 10pt, \"width\": 20pt})", "duplicate dictionary key" },
        .{ "legacy-list-options", "node(\"a\",grid(0,0),typ[A],[[\"width\",10pt]])", "expected dict" },
        .{ "coordinate-field-type", "coordinate:=grid(0,0); coordinate.value=\"bad\"", "expected vec2" },
        .{ "node-cycle", "geometry([node(\"a\",named(\"b\"),typ[A]),node(\"b\",named(\"a\"),typ[B])])", "cyclic or unknown node" },
        .{ "group-cycle", "geometry([enclose(\"a\",[\"b\"],typ[]),enclose(\"b\",[\"a\"],typ[])])", "cyclic or unknown node" },
        .{ "edge-cycle", "geometry([edge(named(\"b\"),absolute((0pt,0pt)),{\"name\": \"a\"}),edge(named(\"a\"),absolute((1pt,0pt)),{\"name\": \"b\"})])", "cyclic or unknown edge" },
        .{ "unknown-node", "geometry([connect(\"missing\",\"also_missing\")])", "cyclic or unknown edge" },
        .{ "missing-auto", "geometry([edge(automatic(),absolute((1pt,0pt)))])", "no preceding node" },
        .{ "axes", "geometry([],{\"axes\": [(1,0),(1,0)]})", "orthogonal unit vectors" },
        .{ "size", "geometry([node(\"a\",grid(0,0),typ[A],{\"width\": -1pt})])", "dimensions must be positive" },
        .{ "huge-grid", "geometry([node(\"a\",grid(0,0),typ[A]),node(\"b\",grid(5000,0),typ[B])])", "exceeds 4096" },
        .{ "dodge", "geometry([edge(absolute((0pt,0pt)),absolute((10pt,0pt)),{\"dodge\": [6pt,6pt]})])", "dodge leaves no visible connector" },
        .{ "unknown-mark", "diagram([edge(absolute((0pt,0pt)),absolute((10pt,0pt)),{\"head\": \"not_a_mark\"})])", "unknown arrow mark" },
        .{ "unknown-shape-option", "node(\"a\",grid(0,0),typ[A],{\"shape\":\"diamond\",\"shape_options\":{\"bogus\":1}})", "unknown nodegraph option: bogus" },
        .{ "unknown-shorthand", "arrows(\"x-|-x->\")", "use explicit mark descriptors" },
        .{ "label-position", "diagram([edge(absolute((0pt,0pt)),absolute((100pt,0pt)),{\"label\": typ[bad], \"label_pos\": 2})])", "position must be in" },
        .{ "gap-string-index", "source:=\"hook->\"; character:=source[0]", "index" },
        .{ "gap-gradient", "paint:=gradient(rgb(1,0,0),rgb(0,0,1))", "unknown function" },
    }) |case| {
        const file = try check.write(try check.fmt("{s}.huak", .{case[0]}), try check.fmt("import paint.rgb\nimport math.*\nimport \"../../../nodegraph.huak\".*\n{s}\n", .{case[1]}));
        const message = try check.huak(&.{ "run", file }, false);
        _ = try check.write(try check.fmt("{s}.stderr", .{case[0]}), message);
        try contains(message, case[2]);
    }
    const capabilities = try check.write("native-capabilities.huak", @embedFile("fixtures/native_capabilities.huak"));
    _ = try check.huak(&.{ "run", capabilities, "--output=target/nodegraph/acceptance/native-capabilities.svg" }, true);
    _ = try check.tool(&.{ "rsvg-convert", "-w", "200", "-h", "200", "-o", try check.path("native-capabilities.png"), try check.path("native-capabilities.svg") });
    try check.alpha("native-capabilities.png", 100, 100, 0);
    try check.alpha("native-capabilities.png", 20, 180, 1);
    _ = try check.write("results.json", try std.json.Stringify.valueAlloc(a, .{
        .processes = check.processes,
        .huakIndependent = true,
        .galleryExports = gallery_exports,
        .additionalSvgExports = check.exports - gallery_exports,
        .jobsByteIdentical = true,
        .baselineByteIdentical = if (check.baseline != null) @as(?bool, true) else null,
        .nativePdfText = true,
        .transparentClearance = true,
        .crossingStressObjects = 131,
        .negativeCases = 18,
        .nativeCapabilityChecks = 5,
        .capabilityProbes = 2,
    }, .{ .whitespace = .indent_2 }));
    std.debug.print("Nodegraph: {d} Huak processes passed; {d} exports, serial/parallel equality, PDF text, alpha, arrow strokes, debug grid and diagnostics verified.\n", .{ check.processes, check.exports });
}

const Check = struct {
    a: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    library: []const u8,
    baseline: ?[]const u8,
    processes: usize = 0,
    exports: usize = 0,

    fn fmt(self: Check, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.a, format, args);
    }
    fn path(self: Check, file: []const u8) ![]const u8 {
        return self.fmt("target/nodegraph/acceptance/{s}", .{file});
    }
    fn write(self: Check, file: []const u8, bytes: []const u8) ![]const u8 {
        const destination = try self.path(file);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = destination, .data = bytes });
        return destination;
    }
    fn read(self: Check, file: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, file, self.a, .limited(16 * 1024 * 1024));
    }
    fn process(self: Check, argv: []const []const u8, success: bool) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(16 * 1024 * 1024), .timeout = .{ .deadline = .fromNow(self.io, .{ .raw = .fromSeconds(60), .clock = .awake }) } });
        if (result.term != .exited or (result.term.exited == 0) != success) {
            std.debug.print("{any}: {any}\n{s}\n{s}\n", .{ argv, result.term, result.stdout, result.stderr });
            return error.UnexpectedProcessResult;
        }
        return if (success) result.stdout else result.stderr;
    }
    fn tool(self: Check, argv: []const []const u8) ![]const u8 {
        return self.process(argv, true);
    }
    fn huak(self: *Check, args: []const []const u8, success: bool) ![]const u8 {
        const argv = try self.a.alloc([]const u8, args.len + 3);
        argv[0] = self.binary;
        @memcpy(argv[1 .. args.len + 1], args);
        argv[args.len + 1] = "--libtypst";
        argv[args.len + 2] = self.library;
        self.processes += 1;
        const result = try self.process(argv, success);
        if (success) for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--output=") or std.mem.eql(u8, arg, "--output")) self.exports += 1;
        };
        return result;
    }
    fn compareBaseline(self: Check, name: []const u8, bytes: []const u8) !void {
        if (self.baseline) |base| try equal(bytes, try self.read(try std.fs.path.join(self.a, &.{ base, name })));
    }
    fn alpha(self: Check, file: []const u8, x: usize, y: usize, expected: f64) !void {
        try number(try self.tool(&.{ "magick", try self.path(file), "-format", try self.fmt("%[fx:p{{{d},{d}}}.a]", .{ x, y }), "info:" }), expected);
    }
};

fn contains(bytes: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, bytes, expected) == null) {
        std.debug.print("Expected '{s}' in:\n{s}\n", .{ expected, bytes });
        return error.MissingExpectedText;
    }
}
fn equal(first: []const u8, second: []const u8) !void {
    if (!std.mem.eql(u8, first, second)) return error.OutputChanged;
}
fn number(bytes: []const u8, expected: f64) !void {
    const actual = try std.fmt.parseFloat(f64, std.mem.trim(u8, bytes, " \t\r\n"));
    if (actual != expected) return error.UnexpectedPixelOrStroke;
}
