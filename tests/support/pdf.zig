//! Shared native PDF verification with Poppler, its text and its pixels; no
//! dependency on a CLI test harness.
const std = @import("std");
const t = std.testing;

pub const RasterOptions = struct { gray: bool = false };

/// What Poppler draws of a one-page PDF at 72 dpi: a binary PPM, or a PGM
/// with `gray`, whose rows run down. The caller frees it with t.allocator.
pub fn raster(bytes: []const u8, options: RasterOptions) ![]u8 {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(t.io, .{ .sub_path = "document.pdf", .data = bytes });
    const result = try std.process.run(t.allocator, t.io, .{
        .argv = if (options.gray)
            &.{ "pdftoppm", "-r", "72", "-singlefile", "-gray", "document.pdf" }
        else
            &.{ "pdftoppm", "-r", "72", "-singlefile", "document.pdf" },
        .cwd = .{ .dir = temporary.dir },
    });
    defer t.allocator.free(result.stderr);
    errdefer t.allocator.free(result.stdout);
    try t.expect(result.term.success());
    return result.stdout;
}

pub const Options = struct { raw: bool = false };

/// Extract UTF-8 text with Poppler. The caller frees the result with t.allocator.
pub fn text(bytes: []const u8, options: Options) ![]u8 {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(t.io, .{ .sub_path = "document.pdf", .data = bytes });
    const result = try std.process.run(t.allocator, t.io, .{
        .argv = if (options.raw)
            &.{ "pdftotext", "-enc", "UTF-8", "-raw", "document.pdf", "-" }
        else
            &.{ "pdftotext", "-enc", "UTF-8", "document.pdf", "-" },
        .cwd = .{ .dir = temporary.dir },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer t.allocator.free(result.stderr);
    if (!result.term.success()) {
        defer t.allocator.free(result.stdout);
        std.debug.print("pdftotext: {s}\n", .{result.stderr});
        return error.PdfExtractionFailed;
    }
    return result.stdout;
}
