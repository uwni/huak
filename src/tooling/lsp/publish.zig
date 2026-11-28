//! textDocument/publishDiagnostics from an ErrorBundle: UTF-16 ranges and related information.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const bundles = @import("../diagnostics.zig");
const definitions = @import("../definition.zig");
const compiler = @import("../../language/compiler.zig");
const Json = std.json.Value;
const lsp = @import("../lsp.zig");
const Session = lsp.Session;
const Document = lsp.Document;
const writeMessage = lsp.writeMessage;
const readMessage = lsp.readMessage;

// Protocol payloads only; ErrorBundle remains the diagnostic owner.
pub const RelatedInformation = struct {
    location: locations.Location,
    message: []const u8,
};

const PublishedDiagnostic = struct {
    range: locations.Range,
    severity: u8 = 1,
    source: []const u8 = "huak",
    message: []const u8,
    // zlinter-disable-next-line field_naming - LSP JSON field name
    relatedInformation: []const RelatedInformation,
};

pub fn diagnoseAll(self: *Session, frontend: *const Frontend, writer: *std.Io.Writer) !void {
    var entries = self.documents.iterator();
    while (entries.next()) |entry| try diagnostics(self, frontend, entry.key_ptr.*, entry.value_ptr, writer);
}

pub fn diagnostics(self: *Session, frontend: *const Frontend, uri: []const u8, document: *const Document, writer: *std.Io.Writer) !void {
    var diagnostic: ?compiler.Diagnostic = null;
    frontend.check(document.text, document.path, &diagnostic) catch |err| {
        if (err != error.OutOfMemory and diagnostic != null) {
            var bundle = try bundles.fromDiagnostic(frontend.allocator, document.path, document.text, &diagnostic.?);
            defer bundle.deinit(self.frontend.allocator);
            return publishBundle(self, uri, document, bundle, writer);
        }
        var wip = try std.zig.ErrorBundle.Wip.init(self.frontend.allocator);
        defer wip.deinit();
        try wip.addRootErrorMessage(.{ .msg = try wip.addString(@errorName(err)) });
        var bundle = try wip.toOwnedBundle("");
        defer bundle.deinit(self.frontend.allocator);
        return publishBundle(self, uri, document, bundle, writer);
    };
    try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = document.version, .diagnostics = [_]bool{} } });
}

pub fn publishBundle(self: *Session, uri: []const u8, document: *const Document, bundle: std.zig.ErrorBundle, writer: *std.Io.Writer) !void {
    var temporary: std.heap.ArenaAllocator = .init(self.frontend.allocator);
    defer temporary.deinit();
    const allocator = temporary.allocator();
    var published: std.ArrayList(PublishedDiagnostic) = .empty;
    for (bundle.getMessages()) |index| {
        const root = bundle.getErrorMessage(index);
        var related: std.ArrayList(RelatedInformation) = .empty;
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        var range: locations.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
        if (root.src_loc != .none) {
            const loc = bundle.getSourceLocation(root.src_loc);
            const path = bundle.nullTerminatedString(loc.src_path);
            if (std.mem.eql(u8, path, document.path)) {
                range = locationRange(bundle, loc, document.text);
            } else {
                // An imported module's error belongs in relatedInformation,
                // while retaining the existing root-document summary.
                try body.writer.print("{s}:{d}:{d}: ", .{ path, loc.line + 1, loc.column + 1 });
                if (try relatedLocation(self, allocator, bundle, loc)) |location| try related.append(allocator, .{ .location = location, .message = bundle.nullTerminatedString(root.msg) });
            }
        }
        try body.writer.writeAll(bundle.nullTerminatedString(root.msg));
        for (bundle.getNotes(index)) |note_index| {
            const note = bundle.getErrorMessage(note_index);
            if (note.src_loc == .none) {
                try body.writer.print("\n{s}", .{bundle.nullTerminatedString(note.msg)});
            } else if (try relatedLocation(self, allocator, bundle, bundle.getSourceLocation(note.src_loc))) |location| {
                try related.append(allocator, .{ .location = location, .message = bundle.nullTerminatedString(note.msg) });
            }
        }
        try published.append(allocator, .{ .range = range, .message = try body.toOwnedSlice(), .relatedInformation = related.items });
    }
    try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = document.version, .diagnostics = published.items } });
}

pub fn relatedLocation(self: *Session, allocator: std.mem.Allocator, bundle: std.zig.ErrorBundle, loc: std.zig.ErrorBundle.SourceLocation) !?locations.Location {
    const path = bundle.nullTerminatedString(loc.src_path);
    if (!std.Io.Dir.path.isAbsolute(path)) return null;
    var content: ?[]const u8 = null;
    if (self.openDocument(path)) |entry| return .{ .uri = entry.key_ptr.*, .range = locationRange(bundle, loc, entry.value_ptr.text) };
    if (loc.source_line == 0) content = std.Io.Dir.cwd().readFileAlloc(self.frontend.io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
    return .{ .uri = try definitions.uriForPath(allocator, path), .range = locationRange(bundle, loc, content) };
}

fn locationRange(bundle: std.zig.ErrorBundle, loc: std.zig.ErrorBundle.SourceLocation, text: ?[]const u8) locations.Range {
    if (text) |content| return .{ .start = locations.at(content, loc.span_main), .end = locations.at(content, loc.span_end) };
    // A source-line snapshot is sufficient to convert byte columns to UTF-16
    // even after a module or a runtime's full source storage has been released.
    const line = if (loc.source_line != 0) bundle.nullTerminatedString(loc.source_line) else "";
    const column: usize = loc.column;
    const width: usize = loc.span_end -| loc.span_main;
    const start = if (line.len != 0) locations.at(line, column).character else column;
    const end = if (line.len != 0) locations.at(line, column + width).character else column + width;
    return .{ .start = .{ .line = loc.line, .character = start }, .end = .{ .line = loc.line, .character = end } };
}

test "ErrorBundle locations produce UTF-16 ranges and structured related information" {
    const allocator = std.testing.allocator;
    const text = "emoji:=\"🙂\"; missing\n";
    const start = std.mem.find(u8, text, "missing").?;
    var detail: @import("../../language/Machine.zig").RuntimeDiagnostic = .{
        .diagnostic = @import("../../language/source.zig").Diagnostic.init(.{ .start = start, .end = start + 7 }, "unknown identifier", .{}),
        .native_message = "native detail",
        .trace = &.{.{ .function = "caller", .module = 0, .span = .{ .start = start, .end = start + 7 } }},
    };
    detail.diagnostic.setSource("/unavailable/figure file.huak", text);
    var bundle = try bundles.fromRuntime(allocator, "/unavailable/figure file.huak", text, &detail, &.{.{ .name = "/unavailable/figure file.huak", .source_text = text, .entry = 0, .exports = &.{} }});
    defer bundle.deinit(allocator);
    var frontend: Frontend = .{ .allocator = allocator, .io = std.testing.io };
    var session: Session = .{ .frontend = &frontend };
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const document: Document = .{ .text = @constCast(text), .path = "/unavailable/figure file.huak", .version = 3 };
    try publishBundle(&session, "file:///unavailable/figure%20file.huak", &document, bundle, &output.writer);
    var reader = std.Io.Reader.fixed(output.written());
    const body = (try readMessage(allocator, &reader)).?;
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(Json, allocator, body, .{});
    defer parsed.deinit();
    const errors = parsed.value.object.get("params").?.object.get("diagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    const diagnostic = errors[0].object;
    const primary = diagnostic.get("range").?.object.get("start").?.object;
    try std.testing.expectEqual(@as(i64, @intCast(locations.at(text, start).character)), primary.get("character").?.integer);
    try std.testing.expect(std.mem.find(u8, diagnostic.get("message").?.string, "native detail") != null);
    const related = diagnostic.get("relatedInformation").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("at caller", related[0].object.get("message").?.string);
    const place = related[0].object.get("location").?.object;
    try std.testing.expectEqualStrings("file:///unavailable/figure%20file.huak", place.get("uri").?.string);
    try std.testing.expectEqual(primary.get("character").?.integer, place.get("range").?.object.get("start").?.object.get("character").?.integer);
}
