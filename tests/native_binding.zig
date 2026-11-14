//! Real calls through the generated stable C ABI, independent of huak policy.
const std = @import("std");
const binding = @import("typst_binding");
const c = binding.c;
const options = @import("test_options");
const t = std.testing;

fn native() !binding.Functions {
    // Native worker and TLS destructors can reference this mapping. Individual
    // objects are released below; the DSO remains resident until process exit.
    var dynamic = try std.DynLib.open(options.library_path);
    return binding.load(&dynamic);
}

fn check(functions: *const binding.Functions, status: c.TypstStatus, diagnostics: *?*c.TypstDiagnostics) !void {
    defer {
        functions.diagnostics_release(diagnostics.*);
        diagnostics.* = null;
    }
    if (status != c.TYPST_OK) {
        if (functions.diagnostics_count(diagnostics.*) > 0) {
            var detail: c.TypstDiagnosticView = undefined;
            if (functions.diagnostics_get(diagnostics.*, 0, &detail) == c.TYPST_OK)
                std.debug.print("native status {d}: {s}\n", .{ status, binding.bytes(detail.message) });
        }
        return error.NativeCallFailed;
    }
}

test "generated native symbols load with the stable ABI and capabilities" {
    const functions = try native();
    try t.expectEqual(@as(u32, c.TYPST_ABI_VERSION), functions.abi_version());
    try t.expectEqual(binding.abi_version, functions.abi_version());
    try t.expect(@typeInfo(binding.Functions).@"struct".field_names.len > 0);
    var version: c.TypstVersionInfo = undefined;
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), functions.version_info(&version));
    try t.expectEqual(@as(u32, 1), version.abi_major);
    try t.expect(binding.bytes(version.library_version).len > 0);
    try t.expect(binding.bytes(version.typst_version).len > 0);
    const required: u64 = c.TYPST_CAP_PDF | c.TYPST_CAP_NATIVE_SCENE | c.TYPST_CAP_BATCH_LAYOUT | c.TYPST_CAP_TEXT_OUTLINE | c.TYPST_CAP_PDF_CREATOR;
    try t.expectEqual(required, version.capabilities & required);
}

test "native document and binary buffers remain owned after context destruction" {
    const functions = try native();
    var diagnostics: ?*c.TypstDiagnostics = null;
    var context: ?*c.TypstContext = null;
    defer functions.context_release(context);
    try check(&functions, functions.context_create(null, &context, &diagnostics), &diagnostics);
    functions.context_retain(context);
    functions.context_release(context);
    var document: ?*c.TypstDocument = null;
    defer functions.document_release(document);
    const source = "#set page(width:200pt,height:auto,margin:8pt)\ncafé Ω $sum_(i=1)^n i$\n#rect(width:40pt,height:12pt,fill:blue)";
    try check(&functions, functions.context_compile(context, binding.str(source), binding.str("native.typ"), &document, &diagnostics), &diagnostics);
    functions.document_retain(document);
    functions.document_release(document);
    functions.context_release(context);
    context = null;
    try t.expectEqual(@as(usize, 1), functions.document_page_count(document));
    var metrics: c.TypstMetrics = undefined;
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), functions.document_page_metrics(document, 0, &metrics));
    try t.expect(metrics.width_pt > 0 and metrics.height_pt > 0);
    var svg: ?*c.TypstBuffer = null;
    defer functions.buffer_release(svg);
    try check(&functions, functions.document_export_svg(document, 0, &svg, &diagnostics), &diagnostics);
    try t.expect(std.mem.indexOf(u8, binding.bytes(functions.buffer_data(svg)), "<path") != null);
    var pdf: ?*c.TypstBuffer = null;
    defer functions.buffer_release(pdf);
    try check(&functions, functions.document_export_pdf(document, null, &pdf, &diagnostics), &diagnostics);
    functions.buffer_retain(pdf);
    functions.buffer_release(pdf);
    functions.document_release(document);
    document = null;
    const output = binding.bytes(functions.buffer_data(pdf));
    try t.expect(std.mem.startsWith(u8, output, "%PDF-"));
    try t.expect(std.mem.indexOf(u8, output, "/FontFile") != null);
    try t.expect(std.mem.indexOf(u8, output, "/ToUnicode") != null);
}

test "native batch preserves successes errors diagnostic indices and independent ownership" {
    const functions = try native();
    var diagnostics: ?*c.TypstDiagnostics = null;
    var context: ?*c.TypstContext = null;
    defer functions.context_release(context);
    try check(&functions, functions.context_create(null, &context, &diagnostics), &diagnostics);
    const requests = [_]c.TypstLayoutRequest{
        .{ .source = binding.str("First café Ω"), .source_name = binding.str("first.typ"), .options = null },
        .{ .source = binding.str("#let broken = ("), .source_name = binding.str("broken.typ"), .options = null },
        .{ .source = binding.str("$x^2$"), .source_name = binding.str("last.typ"), .options = null },
    };
    var results: [requests.len]c.TypstLayoutResult = @splat(std.mem.zeroes(c.TypstLayoutResult));
    defer for (results) |result| {
        functions.layout_release(result.layout);
        functions.diagnostics_release(result.diagnostics);
    };
    try check(&functions, functions.context_layout_many(context, &requests, requests.len, &results, &diagnostics), &diagnostics);
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), results[0].status);
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_COMPILE_FAILED), results[1].status);
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), results[2].status);
    try t.expect(results[1].layout == null);
    try t.expect(functions.diagnostics_count(results[1].diagnostics) > 0);
    var detail: c.TypstDiagnosticView = undefined;
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), functions.diagnostics_get(results[1].diagnostics, 0, &detail));
    try t.expectEqual(@as(usize, 1), detail.request_index);
    try t.expectEqualStrings("/broken.typ", binding.bytes(detail.source_name));
    try t.expect(binding.bytes(detail.message).len > 0);
    functions.diagnostics_retain(results[1].diagnostics);
    functions.diagnostics_release(results[1].diagnostics);
    functions.context_release(context);
    context = null;
    for ([_]usize{ 0, 2 }) |index| {
        var metrics: c.TypstMetrics = undefined;
        try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), functions.layout_metrics(results[index].layout, &metrics));
        try t.expect(metrics.width_pt > 0 and metrics.height_pt > 0);
    }
    var outline: ?*c.TypstOutline = null;
    defer functions.outline_release(outline);
    try check(&functions, functions.layout_outline(results[0].layout, &outline, &diagnostics), &diagnostics);
    var view: c.TypstOutlineView = undefined;
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_OK), functions.outline_view(outline, &view));
    try t.expect(view.path_count > 0 and view.segment_count > 0);
    functions.outline_retain(outline);
    functions.outline_release(outline);
}

test "invalid native requests return per-call diagnostics and allow recovery" {
    const functions = try native();
    var diagnostics: ?*c.TypstDiagnostics = null;
    defer functions.diagnostics_release(diagnostics);
    var context: ?*c.TypstContext = null;
    defer functions.context_release(context);
    const invalid = c.TypstContextOptions{ .struct_size = 1, .flags = 0, .fonts = null, .font_count = 0, .files = null, .file_count = 0, .inputs_json = binding.str(""), .font_dirs = null, .font_dir_count = 0 };
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_INVALID_ARGUMENT), functions.context_create(&invalid, &context, &diagnostics));
    try t.expect(context == null);
    try t.expect(functions.diagnostics_count(diagnostics) > 0);
    functions.diagnostics_release(diagnostics);
    diagnostics = null;
    // An ABI 1.3 host's record ends before font_dirs. The library must not
    // read past struct_size, so this invalid UTF-8 directory is never seen.
    const malformed = [_]c.TypstStr{.{ .data = "\xff", .len = 1 }};
    var older = std.mem.zeroes(c.TypstContextOptions);
    older.struct_size = @offsetOf(c.TypstContextOptions, "font_dirs");
    older.font_dirs = &malformed;
    older.font_dir_count = malformed.len;
    var compatible: ?*c.TypstContext = null;
    defer functions.context_release(compatible);
    try check(&functions, functions.context_create(&older, &compatible, &diagnostics), &diagnostics);
    older.struct_size = @sizeOf(c.TypstContextOptions);
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_INVALID_UTF8), functions.context_create(&older, &context, &diagnostics));
    try t.expect(context == null);
    functions.diagnostics_release(diagnostics);
    diagnostics = null;
    try check(&functions, functions.context_create(null, &context, &diagnostics), &diagnostics);
    var document: ?*c.TypstDocument = null;
    defer functions.document_release(document);
    try t.expectEqual(@as(c.TypstStatus, c.TYPST_INVALID_UTF8), functions.context_compile(context, binding.str("\xff\x00"), binding.str("bad.typ"), &document, &diagnostics));
    try t.expect(document == null);
    try t.expect(functions.diagnostics_count(diagnostics) > 0);
    functions.diagnostics_release(diagnostics);
    diagnostics = null;
    try check(&functions, functions.context_compile(context, binding.str("Recovered"), binding.str("good.typ"), &document, &diagnostics), &diagnostics);
    try t.expectEqual(@as(usize, 1), functions.document_page_count(document));
}

test "borrowed UTF-8 and binary views preserve explicit lengths" {
    const data = [_]u8{ 0, 255, 128, 65 };
    try t.expectEqualSlices(u8, &data, binding.bytes(binding.str(&data)));
    const empty: c.TypstBytes = .{ .data = null, .len = 0 };
    try t.expectEqualSlices(u8, &.{}, binding.bytes(empty));
}
