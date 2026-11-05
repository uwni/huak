//! Typst itself determines the boundaries of embedded [] and {} blocks.
const api = @import("library.zig");
const binding = @import("typst_binding");
const c = binding.c;

pub fn sourceBlock(library: *api.Library, source: []const u8) api.Error!usize {
    var length: usize = 0;
    var report: ?*c.TypstDiagnostics = null;
    defer library.functions.diagnostics_release(report);
    const result = library.functions.source_block(binding.str(source), &length, &report);
    try library.checkDiagnosed(result, report, &.{.{ .name = "source", .text = source }});
    if (length > source.len) return error.InvalidResult;
    return length;
}
