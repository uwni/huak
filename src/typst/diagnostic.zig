//! Present owned native diagnostics against the original caller source text.
const std = @import("std");
const api = @import("library.zig");
const binding = @import("typst_binding");
const c = binding.c;
const a = binding.allocator;

pub const Source = struct {
    name: []const u8,
    text: []const u8,
    /// Positions are reported in this file instead of `name`.
    origin: ?api.SourceOrigin = null,
};

pub fn format(library: *api.Library, report: ?*const c.TypstDiagnostics, sources: []const Source) api.Error![]u8 {
    return formatAlloc(library, report, sources) catch |err| return switch (err) {
        // An allocating memory writer fails writes only on allocation failure.
        error.WriteFailed => error.OutOfMemory,
        else => @as(api.Error, @errorCast(err)),
    };
}
fn formatAlloc(library: *api.Library, report: ?*const c.TypstDiagnostics, sources: []const Source) (api.Error || error{WriteFailed})![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    const count = library.functions.diagnostics_count(report);
    for (0..count) |index| {
        var entry: c.TypstDiagnosticView = undefined;
        try binding.status(library.functions.diagnostics_get(report, index, &entry));
        if (index != 0) try output.writer.writeByte('\n');
        try location(&output.writer, entry, sources);
        try output.writer.writeAll(binding.bytes(entry.message));
        for (0..entry.note_count) |note_index| {
            var note: c.TypstDiagnosticView = undefined;
            try binding.status(library.functions.diagnostics_get_note(report, index, note_index, &note));
            try output.writer.writeAll(if (note.flags & c.TYPST_DIAGNOSTIC_HINT != 0) "\nhint: " else "\nnote: ");
            try location(&output.writer, note, sources);
            try output.writer.writeAll(binding.bytes(note.message));
        }
    }
    return output.toOwnedSlice();
}
fn location(writer: *std.Io.Writer, entry: c.TypstDiagnosticView, sources: []const Source) !void {
    const name = std.mem.trimStart(u8, binding.bytes(entry.source_name), "/");
    if (name.len == 0) return;
    const source = for (sources) |source| {
        if (std.mem.eql(u8, name, std.mem.trimStart(u8, source.name, "/"))) break source;
    } else null;
    const origin = if (source) |known| known.origin else null;
    if (entry.flags & c.TYPST_DIAGNOSTIC_HAS_RANGE == 0) return writer.print("{s}: ", .{if (origin) |file| file.name else name});
    const known = source orelse return writer.print("{s}:{d}..{d}: ", .{ name, entry.byte_start, entry.byte_end });
    const position = std.zig.findLineColumn(known.text, @min(entry.byte_start, known.text.len));
    const file = origin orelse return writer.print("{s}:{d}:{d}: ", .{ name, position.line + 1, position.column + 1 });
    // The text begins mid-line in its file only on its first line.
    const column = if (position.line == 0) file.column + position.column else position.column;
    try writer.print("{s}:{d}:{d}: ", .{ file.name, file.line + position.line + 1, column + 1 });
}
