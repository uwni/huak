//! Host layout requests: preambles, native styles and regions, templates as show rules, bindings and evaluated modules.
const std = @import("std");
const testing = std.testing;
const options = @import("test_options");
const typst = @import("libtypst");

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

test "host templates apply as show rules and report positions in their originating file" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    // A template keeps its own setup definitions; its setup styles nothing.
    const large: typst.Template = .{
        .code = "body => { set text(size: 30pt); emphasis(body) }",
        .name = "large",
        .setup = "let emphasis(body) = strong(body)\nset text(red)",
        .setup_name = "large-setup",
    };
    const plain: typst.LayoutRequest = .{ .source = "Hello" };
    var shown = plain;
    shown.templates = &.{large};
    shown.shows = &.{0};
    var registered = plain;
    registered.templates = &.{large};
    var metrics: [3]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{ plain, shown, registered }, &metrics, null);
    defer layout.deinit();
    try testing.expect(metrics[1].width > 2 * metrics[0].width);
    try testing.expectEqual(metrics[0].width, metrics[2].width);

    // Errors inside a template are placed in the file the code came from.
    const failing: typst.Template = .{
        .code = "body => {\n  set text(size: missing)\n  body\n}",
        .name = "failing",
        .origin = .{ .name = "styles.huak", .line = 6, .column = 20 },
    };
    var broken = plain;
    broken.templates = &.{failing};
    broken.shows = &.{0};
    var single: [1]typst.Metrics = undefined;
    var detail: typst.Diagnostic = .{};
    defer detail.deinit();
    try testing.expectError(error.CompileFailed, engine.layoutContent(&.{broken}, &single, &detail));
    try testing.expect(std.mem.indexOf(u8, detail.text(), "styles.huak:8:18: unknown variable: missing") != null);
}

test "binding inputs are validated by the library, which reads only the fields their kind selects" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const c = typst.c;
    var metrics: [1]typst.Metrics = undefined;
    // A scalar's collection fields are outside its contract: counts without
    // storage behind them are not read.
    var count = std.mem.zeroes(c.TypstValueInput);
    count.kind = c.TYPST_VALUE_INT;
    count.integer = 7;
    count.item_count = 3;
    count.binding_count = 5;
    const scalar = [_]c.TypstBinding{.{ .name = .{ .data = "count", .len = 5 }, .value = &count }};
    var layout = try engine.layoutContent(&.{.{ .source = "#assert(count == 7) ok", .bindings = &scalar }}, &metrics, null);
    layout.deinit();
    // A missing value and a tree beyond the depth limit are the library's errors.
    const missing = [_]c.TypstBinding{.{ .name = .{ .data = "count", .len = 5 }, .value = null }};
    try testing.expectError(error.InvalidArgument, engine.layoutContent(&.{.{ .source = "x", .bindings = &missing }}, &metrics, null));
    var levels: [70]c.TypstValueInput = undefined;
    for (&levels, 0..) |*level, index| {
        level.* = std.mem.zeroes(c.TypstValueInput);
        level.kind = c.TYPST_VALUE_ARRAY;
        if (index + 1 < levels.len) {
            level.items = &levels[index + 1];
            level.item_count = 1;
        }
    }
    const deep = [_]c.TypstBinding{.{ .name = .{ .data = "deep", .len = 4 }, .value = &levels[0] }};
    try testing.expectError(error.InvalidArgument, engine.layoutContent(&.{.{ .source = "x", .bindings = &deep }}, &metrics, null));
}

test "evaluated modules bind into requests, apply as show rules and place errors in their own file" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    const c = typst.c;
    var size = std.mem.zeroes(c.TypstValueInput);
    size.kind = c.TYPST_VALUE_LENGTH;
    size.number = 30;
    const own = [_]c.TypstBinding{.{ .name = .{ .data = "size", .len = 4 }, .value = &size }};
    var base = try engine.evalModule(.{
        .code = "#let scale = size\n#let style(body) = { set text(size: scale); body }\n#let fail() = panic(\"inside base\")",
        .name = "base.typ",
        .bindings = &own,
        .origin = .{ .name = "styles.huak", .line = 4, .column = 10 },
    });
    defer base.deinit();
    // The first handle of whichever options a value belongs to.
    var first = std.mem.zeroes(c.TypstValueInput);
    first.kind = c.TYPST_VALUE_MODULE_HANDLE;
    const uses_base = [_]c.TypstBinding{.{ .name = .{ .data = "base", .len = 4 }, .value = &first }};
    var theme = try engine.evalModule(.{
        .code = "#import calc as calc\n#let style = base.style\n#let fail = base.fail",
        .name = "theme.typ",
        .bindings = &uses_base,
        .modules = &.{&base},
    });
    defer theme.deinit();
    var warnings = try theme.warnings();
    defer warnings.deinit();
    try testing.expect(std.mem.indexOf(u8, warnings.bytes(), "theme.typ:1:") != null);
    var quiet = try base.warnings();
    defer quiet.deinit();
    try testing.expectEqual(@as(usize, 0), quiet.bytes().len);

    const root = [_]c.TypstBinding{.{ .name = .{ .data = "lib", .len = 3 }, .value = &first }};
    const style_path = [_]c.TypstStr{.{ .data = "style", .len = 5 }};
    const show = [_]c.TypstShowValue{.{ .value = &first, .path = &style_path, .path_count = 1 }};
    const plain: typst.LayoutRequest = .{ .source = "#assert(repr(lib) == \"<module theme>\")Hello", .bindings = &root, .modules = &.{&theme} };
    var shown = plain;
    shown.show_values = &show;
    var metrics: [2]typst.Metrics = undefined;
    var layout = try engine.layoutContent(&.{ plain, shown }, &metrics, null);
    layout.deinit();
    try testing.expect(metrics[1].width > 2 * metrics[0].width);

    // An error raised inside the module that `theme` was evaluated with is
    // placed in that module's file; the request lists only `theme`.
    var failing = plain;
    failing.source = "#lib.fail()";
    var single: [1]typst.Metrics = undefined;
    var detail: typst.Diagnostic = .{};
    defer detail.deinit();
    try testing.expectError(error.CompileFailed, engine.layoutContent(&.{failing}, &single, &detail));
    try testing.expect(std.mem.indexOf(u8, detail.text(), "styles.huak:7:") != null);
    // An evaluation error is the library's last error, in the module's file.
    try testing.expectError(error.CompileFailed, engine.evalModule(.{
        .code = "#let broken = missing",
        .name = "broken.typ",
        .origin = .{ .name = "styles.huak", .line = 9, .column = 3 },
    }));
    var message = try library.lastError();
    defer message.deinit();
    try testing.expect(std.mem.indexOf(u8, message.bytes(), "styles.huak:10:18: unknown variable: missing") != null);
    // A module belongs to the library that evaluated it.
    var other = try typst.Library.open(options.library_path);
    defer other.deinit();
    var fixture = try std.DynLib.open(options.incomplete_path);
    defer fixture.close();
    var foreign = other;
    foreign.functions.layout_release = fixture.lookup(@TypeOf(foreign.functions.layout_release), "typst_layout_release") orelse return error.MissingSymbol;
    try testing.expectError(error.InvalidArgument, theme.native(&foreign));
    _ = try theme.native(&other);
}
