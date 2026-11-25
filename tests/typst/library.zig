//! The loaded library and its results: loading and ABI checks, shared entry points, batches, Unicode math, byte lengths, lifetimes and warnings.
const std = @import("std");
const testing = std.testing;
const options = @import("test_options");
const typst = @import("libtypst");
const sample = @import("typst_sample");

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
