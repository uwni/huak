//! Whole-document requests: semantic colors, hints at the ends of blocks,
//! the formatting edit, and the pictures a script exports.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const formatter = @import("../format.zig");
const inlay = @import("../inlay_hints.zig");
const locations = @import("../position.zig");
const bundles = @import("../diagnostics.zig");
const output_choices = @import("../outputs.zig");
const semantic_tokens = @import("../semantic_tokens.zig");
const compiler = @import("../../language/compiler.zig");
const Json = std.json.Value;
const lsp = @import("../lsp.zig");
const Session = lsp.Session;
const field = lsp.field;
const integer = lsp.integer;
const byteOffset = lsp.byteOffset;

/// `textDocument/semanticTokens/full`: the document's tokens with their kinds.
pub fn semanticTokens(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    _, const document = try self.requestedDocument(params);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    return self.reply(writer, id, .{ .data = try semantic_tokens.collect(frontend, arena.allocator(), document.text, document.path) });
}

/// `textDocument/inlayHint`: the hints within a range; none where the
/// document does not parse.
pub fn inlayHint(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const uri, const document = try self.requestedDocument(params);
    const requested = field(params, "range") orelse return error.InvalidParams;
    const start = try byteOffset(document.text, field(requested, "start"));
    const end = try byteOffset(document.text, field(requested, "end"));
    if (start > end) return error.InvalidParams;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    const syntax = frontend.syntax(arena.allocator(), document.text, document.path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        return self.reply(writer, id, [_]bool{});
    };
    const hints = try inlay.collect(arena.allocator(), syntax.source_text, syntax.script.statements, uri, .{ .start = start, .end = end });
    return self.reply(writer, id, hints);
}

/// `textDocument/formatting`: one edit replacing the document with its
/// formatted text, or none where it is formatted already.
pub fn formatting(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    _, const document = try self.requestedDocument(params);
    const options = field(params, "options") orelse return error.InvalidParams;
    const tab_size = integer(field(options, "tabSize")) orelse return error.InvalidParams;
    const spaces = field(options, "insertSpaces") orelse return error.InvalidParams;
    if (spaces != .bool or tab_size < 1 or tab_size > 16) return error.InvalidParams;
    var diagnostic: ?compiler.Diagnostic = null;
    const formatted = formatter.formatWithOptions(frontend, document.text, document.path, &diagnostic, .{ .tab_size = @intCast(tab_size), .insert_spaces = spaces.bool }) catch |err| {
        if (err != error.OutOfMemory and diagnostic != null) {
            var bundle = try bundles.fromDiagnostic(allocator, document.path, document.text, &diagnostic.?);
            defer bundle.deinit(allocator);
            return self.failure(writer, id, -32603, bundle.nullTerminatedString(bundle.getErrorMessage(bundle.getMessages()[0]).msg));
        }
        return self.failure(writer, id, -32603, @errorName(err));
    };
    defer allocator.free(formatted);
    if (std.mem.eql(u8, formatted, document.text)) return self.reply(writer, id, [_]bool{});
    return self.reply(writer, id, .{.{ .range = locations.Range{ .start = .{ .line = 0, .character = 0 }, .end = locations.at(document.text, document.text.len) }, .newText = formatted }});
}

/// `huak/outputs`: the pictures the script exports.
pub fn outputs(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    _, const document = try self.requestedDocument(params);
    var diagnostic: ?compiler.Diagnostic = null;
    var program = frontend.compile(document.text, document.path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diagnostic) |detail| return self.failure(writer, id, -32603, detail.text());
        return self.failure(writer, id, -32603, @errorName(err));
    };
    defer program.deinit();
    const choices = try output_choices.collect(allocator, &program);
    defer allocator.free(choices);
    return self.reply(writer, id, .{ .outputs = choices });
}
