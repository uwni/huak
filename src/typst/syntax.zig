//! Typst itself determines the boundaries of embedded [] and {} blocks.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const c = binding.c;

pub fn sourceBlock(library: *api.Library, source: []const u8) api.Error!usize {
    // A block must end at an ASCII delimiter. Limit the native parser's
    // input to a growing prefix; only Typst decides whether it is closed.
    // Each new window is scanned once, including for a single long block.
    var start: usize = 0;
    var limit: usize = @min(128, source.len);
    while (true) {
        const end: ?usize = if (limit == source.len) limit else if (std.mem.lastIndexOfAny(u8, source[start..limit], "]}")) |index| start + index + 1 else null;
        if (end) |count| {
            var length: usize = 0;
            var report: ?*c.TypstDiagnostics = null;
            defer library.functions.diagnostics_release(report);
            const input = source[0..count];
            const result = library.functions.source_block(binding.str(input), &length, &report);
            if (result != c.TYPST_COMPILE_FAILED or limit == source.len) {
                try library.checkDiagnosed(result, report, &.{.{ .name = "source", .text = input }});
                if (length > count) return error.InvalidResult;
                return length;
            }
        }
        start = limit;
        limit = @min(source.len, limit *| 2);
    }
}
