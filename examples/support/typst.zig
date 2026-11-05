//! Shared in-memory typesetting for the Typst example and benchmark.
const std = @import("std");
const typst = @import("libtypst");

pub fn render(engine: *typst.Engine, source: []const u8) !typst.Buffer {
    var document = engine.compile(source) catch |err| {
        if (engine.library.lastError()) |result| {
            var diagnostic = result;
            defer diagnostic.deinit();
            std.debug.print("Typst: {s}\n", .{diagnostic.bytes()});
        } else |_| {}
        return err;
    };
    defer document.deinit();
    if (try document.pageCount() != 1) return error.UnexpectedPageCount;
    var warnings = try document.warnings();
    defer warnings.deinit();
    if (warnings.bytes().len != 0) {
        std.debug.print("Typst warnings: {s}\n", .{warnings.bytes()});
        return error.UnexpectedWarning;
    }
    return document.exportSvg(0);
}
