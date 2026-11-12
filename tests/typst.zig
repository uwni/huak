const std = @import("std");
const testing = std.testing;
const options = @import("test_options");
const typst = @import("libtypst");
const sample = @import("typst_sample");
const font_fixture = @embedFile("fixtures/fonts/LibertinusSerif-Regular.otf");

test "loader rejects missing libraries, NUL paths, incompatible ABI and missing symbols" {
    try testing.expectError(error.LibraryNotFound, typst.Library.open("/no-such-libtypst-0e76d328.so"));
    try testing.expectError(error.InvalidLibraryPath, typst.Library.open("invalid\x00library"));
    try testing.expectError(error.IncompatibleAbi, typst.Library.open(options.incompatible_path));
    try testing.expectError(error.MissingSymbol, typst.Library.open(options.incomplete_path));
}

test "layout references accept shared native entry points and reject a different implementation" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var other = try typst.Library.open(options.library_path);
    defer other.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const source = "Shared instance";
    const requests = [_]typst.LayoutRequest{.{
        .source = source,
        .syntax = .markup,
        .region = null,
    }};
    var measured: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &measured, null);
    defer layout.deinit();
    const frame = try layout.frame(0);
    const raw = try frame.nativeLayout(&other);
    try testing.expectEqual(try frame.nativeLayout(&library), raw);

    // Only the table is under test: this value owns no dynamic mapping or
    // resource. Use an actual foreign symbol without calling through it.
    var fixture = try std.DynLib.open(options.incomplete_path);
    defer fixture.close();
    var foreign = other;
    foreign.functions.layout_release = fixture.lookup(@TypeOf(foreign.functions.layout_release), "typst_layout_release") orelse return error.MissingSymbol;
    try testing.expectError(error.InvalidArgument, frame.nativeLayout(&foreign));
}

test "layout batches retain independent results after temporary descriptors expire" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    for ([_]usize{ 0, 1, 8, 9, 32 }) |count| {
        var requests: [32]typst.LayoutRequest = undefined;
        for (&requests) |*request| request.* = .{ .source = "Retained batch Ω" };
        var measured: [32]typst.Metrics = undefined;
        var layout = retained: {
            var engine = try library.createEngine();
            defer engine.deinit();
            break :retained try engine.layoutContent(requests[0..count], measured[0..count], null);
        };
        defer layout.deinit();
        try testing.expectEqual(count, layout.frameCount());
        for (0..count) |index| {
            try testing.expect(measured[index].width > 0);
            try testing.expectEqualDeep(measured[0], measured[index]);
            try testing.expectEqualDeep(measured[index], try layout.metrics(index));
            _ = try (try layout.frame(index)).nativeLayout(&library);
        }
    }
}

test "real Unicode math and graphics render repeatedly through one native engine" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    for (0..32) |_| {
        var document = try engine.compile(sample.source);
        defer document.deinit();
        try testing.expectEqual(@as(u32, 1), try document.pageCount());
        var warnings = try document.warnings();
        defer warnings.deinit();
        try testing.expectEqual(@as(usize, 0), warnings.bytes().len);
        var svg = try document.exportSvg(0);
        defer svg.deinit();
        try testing.expect(std.mem.startsWith(u8, svg.bytes(), "<svg"));
        try testing.expect(std.mem.endsWith(u8, svg.bytes(), "</svg>"));
        try testing.expect(std.mem.indexOf(u8, svg.bytes(), "<symbol ") != null);
        try testing.expect(std.mem.indexOf(u8, svg.bytes(), "<use ") != null);
        try testing.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#68a8d8\"") != null);
        try testing.expect(std.mem.indexOf(u8, svg.bytes(), "fill=\"#d8a868\"") != null);
        try testing.expectError(error.InvalidPage, document.exportSvg(1));
    }
}

test "UTF-8 and embedded NUL use explicit byte lengths and preserve diagnostics" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    try testing.expectError(error.InvalidUtf8, engine.compile("\xff\x00"));
    var utf8_error = try library.lastError();
    defer utf8_error.deinit();
    try testing.expect(utf8_error.bytes().len > 0);
    // If this input were accidentally truncated as a C string, it would compile.
    try testing.expectError(error.CompileFailed, engine.compile("Valid prefix\x00#let invalid ="));
    var compile_error = try library.lastError();
    defer compile_error.deinit();
    try testing.expect(compile_error.bytes().len > 0);
    var recovered = try engine.compile(sample.source);
    defer recovered.deinit();
    var no_error = try library.lastError();
    defer no_error.deinit();
    try testing.expectEqual(@as(usize, 0), no_error.bytes().len);
}

test "documents and buffers survive engine destruction and release slots safely" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var document = try engine.compile(sample.source);
    defer document.deinit();
    engine.deinit();
    engine.deinit();
    try testing.expectError(error.InvalidState, engine.compile("inactive"));
    var svg = try document.exportSvg(0);
    try testing.expect(svg.bytes().len > 100);
    svg.deinit();
    try testing.expectEqual(@as(usize, 0), svg.bytes().len);
    svg.deinit();
    document.deinit();
    try testing.expectError(error.InvalidState, document.pageCount());
}

test "repeated opens share the process-lifetime library mapping" {
    for (0..3) |_| {
        var library = try typst.Library.open(options.library_path);
        defer library.deinit();
        var engine = try library.createEngine();
        defer engine.deinit();
        var document = try engine.compile(sample.source);
        defer document.deinit();
        var svg = try document.exportSvg(0);
        defer svg.deinit();
        try testing.expect(svg.bytes().len > 100);
    }
}

test "host preambles preserve independently parsed markup math code and trailing comments" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const cases = [_]struct { source: []const u8, syntax: typst.Syntax }{
        .{ .source = "[", .syntax = .markup },
        .{ .source = "\\[", .syntax = .markup },
        .{ .source = "$x // trailing comment\n$", .syntax = .markup },
        .{ .source = "#{ 1 // trailing comment\n}", .syntax = .markup },
        .{ .source = "```typ\n[] // raw content\n```", .syntax = .markup },
        .{ .source = "x // trailing comment", .syntax = .math },
        .{ .source = "[local] // trailing comment", .syntax = .code },
    };
    for (cases) |case| {
        const requests = [_]typst.LayoutRequest{
            .{ .source = case.source, .syntax = case.syntax },
            .{ .source = case.source, .syntax = case.syntax, .preamble = "let unused = 7 // trailing setup comment" },
        };
        var metrics: [2]typst.Metrics = undefined;
        var detail: typst.Diagnostic = .{};
        defer detail.deinit();
        var layout = engine.layoutContent(&requests, &metrics, &detail) catch |err| {
            std.debug.print("source {s}: {s}\n", .{ case.source, detail.text() });
            return err;
        };
        defer layout.deinit();
        try testing.expectApproxEqAbs(metrics[0].width, metrics[1].width, 1e-8);
        try testing.expectApproxEqAbs(metrics[0].height, metrics[1].height, 1e-8);
        try testing.expectApproxEqAbs(metrics[0].baseline, metrics[1].baseline, 1e-8);
        try testing.expectEqual(@as(usize, 2), layout.frameCount());
    }
}

test "host layout accepts native typography styles region and independent content scopes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        .{ .source = "#styled[A paragraph long enough to wrap onto several lines.]", .preamble = "set text(size:16pt, weight:700, fill:rgb(20,80,160)); let styled(body)=body", .region = .{ .width = 100, .height = 1000 } },
        .{ .source = "strong[Title]", .syntax = .code, .preamble = "set text(size:18pt)" },
        .{ .source = "sum_(i=1)^n i", .syntax = .math, .preamble = "set text(size:18pt)" },
        .{ .source = "sum_(i=1)^n i", .syntax = .math },
    };
    var metrics: [4]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width <= 100.000001);
    try testing.expect(metrics[0].height > 32);
    try testing.expect(metrics[1].width > 20);
    try testing.expect(metrics[2].height > 1.6 * metrics[3].height);
    const isolated = [_]typst.LayoutRequest{
        .{ .source = "#let private_name=7; Local", .preamble = "let shared_name=1" },
        .{ .source = "#private_name", .preamble = "let shared_name=1" },
    };
    var isolated_metrics: [2]typst.Metrics = undefined;
    var detail: typst.Diagnostic = .{};
    defer detail.deinit();
    try testing.expectError(error.CompileFailed, engine.layoutContent(&isolated, &isolated_metrics, &detail));
    try testing.expectEqual(@as(?usize, 1), detail.request_index);
    try testing.expect(std.mem.indexOf(u8, detail.text(), "private_name") != null);
    try testing.expect(library.functions.diagnostics_count(detail.native) != 0);
}

test "host preamble errors preserve separate source positions hints and traces" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const cases = [_]struct { request: typst.LayoutRequest, position: []const u8 }{
        .{ .request = .{ .source = "first\n#missing_body", .preamble = "let good=1" }, .position = "source:2:2:" },
        .{ .request = .{ .source = "ok", .preamble = "let good=1\nlet x=missing_preamble" }, .position = "preamble:2:7:" },
        .{ .request = .{ .source = "#bad()", .preamble = "let bad() = missing_nested" }, .position = "preamble:1:13:" },
    };
    for (cases) |case| {
        var metrics: [1]typst.Metrics = undefined;
        var detail: typst.Diagnostic = .{};
        defer detail.deinit();
        try testing.expectError(error.CompileFailed, engine.layoutContent(&.{case.request}, &metrics, &detail));
        try testing.expect(std.mem.indexOf(u8, detail.text(), case.position) != null);
        if (std.mem.indexOf(u8, case.request.source, "bad()") != null) {
            var view: typst.c.TypstDiagnosticView = undefined;
            try library.check(library.functions.diagnostics_get(detail.native, 0, &view), null);
            try testing.expect(view.note_count != 0);
            try testing.expect(std.mem.indexOf(u8, detail.text(), "note: source:") != null);
        }
    }
    var metrics: [1]typst.Metrics = undefined;
    var detail: typst.Diagnostic = .{};
    defer detail.deinit();
    try testing.expectError(error.CompileFailed, engine.layoutContent(&.{.{ .source = "#let body =", .preamble = "let prefix =" }}, &metrics, &detail));
    try testing.expect(std.mem.indexOf(u8, detail.text(), "source:") != null);
    try testing.expect(std.mem.indexOf(u8, detail.text(), "preamble:") != null);
    try testing.expectError(error.CompileFailed, engine.layoutContent(&.{.{ .source = "]", .preamble = "let prefix=1" }}, &metrics, &detail));
    var view: typst.c.TypstDiagnosticView = undefined;
    try library.check(library.functions.diagnostics_get(detail.native, 0, &view), null);
    try testing.expect(view.note_count != 0);
    try testing.expect(std.mem.indexOf(u8, detail.text(), "hint:") != null);
    try testing.expect(std.mem.indexOf(u8, detail.text(), "\\]") != null);
}

test "engine inputs are immutable strings copied before the caller releases storage" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const key = try testing.allocator.dupe(u8, "caption");
    const value = try testing.allocator.dupe(u8, "Fixed Ω input");
    var engine = try library.createEngineWithOptions(&.{ .inputs = &.{.{ .key = key, .value = value }} });
    defer engine.deinit();
    testing.allocator.free(key);
    testing.allocator.free(value);
    var document = try engine.compile("#assert(sys.inputs.caption == \"Fixed Ω input\")\n#sys.inputs.caption");
    defer document.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{ .source = "sys.inputs.caption", .syntax = .code }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 20);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .inputs = &.{ .{ .key = "duplicate", .value = "1" }, .{ .key = "duplicate", .value = "2" } } }));
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .inputs = &.{.{ .key = "", .value = "empty" }} }));
}

test "custom font bytes are copied and retained by independent text frames" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const copy = try testing.allocator.dupe(u8, font_fixture);
    var engine = try library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = copy }}, .use_bundled_fonts = false });
    defer engine.deinit();
    testing.allocator.free(copy);
    var metrics: [1]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{.{ .source = "Retained custom font" }}, &metrics, null);
    defer layout.deinit();
    engine.deinit();
    const native = try (try layout.frame(0)).nativeLayout(&library);
    var actual: typst.c.TypstMetrics = undefined;
    try library.check(library.functions.layout_metrics(native, &actual), null);
    try testing.expectEqual(metrics[0].width, actual.width_pt);
    try testing.expect(actual.width_pt > 0);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = "invalid font bytes" }} }));
}

test "font directories and system fonts are discovered by libtypst" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(testing.io, "fonts/nested");
    try temporary.dir.writeFile(testing.io, .{ .sub_path = "fonts/nested/serif.otf", .data = font_fixture });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    const directory = try std.fs.path.join(testing.allocator, &.{ buffer[0..length], "fonts" });
    defer testing.allocator.free(directory);
    // Without bundled fonts the scanned directory supplies the only face.
    var scanned = try library.createEngineWithOptions(&.{ .font_dirs = &.{directory}, .use_bundled_fonts = false });
    defer scanned.deinit();
    var metrics: [1]typst.Metrics = undefined;
    var layout = try scanned.layoutContent(&.{.{ .source = "Discovered font" }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 0);
    // Another configuration gets its own context; repeating one, as watch
    // rebuilds do, reuses it instead of scanning the system again.
    var default = try library.createEngine();
    defer default.deinit();
    var system = try library.createEngineWithOptions(&.{ .system_fonts = true });
    defer system.deinit();
    try testing.expect(system.handle != default.handle);
    var again = try library.createEngineWithOptions(&.{ .system_fonts = true });
    defer again.deinit();
    try testing.expect(again.handle == system.handle);
}

test "Huak context disables plugins and has no implicit filesystem or clock" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const cases = [_]struct { source: []const u8, marker: []const u8 }{
        .{ .source = "#plugin(\"missing.wasm\")", .marker = "plugin" },
        .{ .source = "#std.plugin(\"missing.wasm\")", .marker = "plugin" },
        .{ .source = "#eval(\"plugin\")", .marker = "plugin" },
        .{ .source = "#read(\"blocked.txt\")", .marker = "blocked.txt" },
        .{ .source = "#datetime.today()", .marker = "date" },
    };
    for (cases) |case| {
        try testing.expectError(error.CompileFailed, engine.compile(case.source));
        var message = try library.lastError();
        defer message.deinit();
        try testing.expect(std.mem.indexOf(u8, message.bytes(), case.marker) != null);
    }
}

test "batch warnings retain request indices and source order" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const requests = [_]typst.LayoutRequest{
        .{ .source = "#set text(font:\"huak-missing-font-first\"); First", .preamble = "let shared=1" },
        .{ .source = "#set text(font:\"huak-missing-font-second\"); Second", .preamble = "let shared=1" },
    };
    var metrics: [2]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&requests, &metrics, null);
    defer layout.deinit();
    var warnings = try layout.warnings();
    defer warnings.deinit();
    const first = std.mem.indexOf(u8, warnings.bytes(), "request 0:") orelse return error.MissingFirstWarning;
    const second = std.mem.indexOf(u8, warnings.bytes(), "request 1:") orelse return error.MissingSecondWarning;
    try testing.expect(first < second);
    try testing.expect(std.mem.indexOf(u8, warnings.bytes()[first..second], "huak-missing-font-first") != null);
    try testing.expect(std.mem.indexOf(u8, warnings.bytes()[second..], "huak-missing-font-second") != null);
}

test "custom TTC sources reject a malformed face after an otherwise valid face" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const valid = try collectionFixture(testing.allocator, font_fixture, false);
    defer testing.allocator.free(valid);
    var accepted = try library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = valid }}, .use_bundled_fonts = false });
    defer accepted.deinit();
    try testing.expect(accepted.handle != null);
    var metrics: [1]typst.Metrics = undefined;
    var layout = try accepted.layoutContent(&.{.{ .source = "Valid TTC face" }}, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[0].width > 0);
    const invalid = try collectionFixture(testing.allocator, font_fixture, true);
    defer testing.allocator.free(invalid);
    try testing.expectError(error.InvalidArgument, library.createEngineWithOptions(&.{ .font_sources = &.{.{ .data = invalid }}, .use_bundled_fonts = false }));
    var detail = try library.lastError();
    defer detail.deinit();
    try testing.expect(std.mem.indexOf(u8, detail.bytes(), "face 1") != null);
}

/// Test data only: relocate one bundled SFNT into a two-face TTC container.
/// The production loader delegates all font parsing to the upstream C API.
fn collectionFixture(allocator: std.mem.Allocator, source: []const u8, bad_second: bool) ![]u8 {
    const prefix = 20;
    const data = try allocator.alloc(u8, prefix + source.len);
    errdefer allocator.free(data);
    @memset(data[0..prefix], 0);
    @memcpy(data[0..4], "ttcf");
    std.mem.writeInt(u32, data[4..8], 0x0001_0000, .big);
    std.mem.writeInt(u32, data[8..12], 2, .big);
    std.mem.writeInt(u32, data[12..16], prefix, .big);
    std.mem.writeInt(u32, data[16..20], if (bad_second) @intCast(data.len + 64) else prefix, .big);
    @memcpy(data[prefix..], source);
    const tables = std.mem.readInt(u16, source[4..6], .big);
    for (0..tables) |index| {
        const offset = prefix + 12 + index * 16 + 8;
        const field: *[4]u8 = @ptrCast(data[offset..][0..4]);
        std.mem.writeInt(u32, field, std.mem.readInt(u32, field, .big) + prefix, .big);
    }
    return data;
}
