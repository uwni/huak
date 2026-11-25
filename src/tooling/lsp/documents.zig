//! Editor buffers: the documents the editor opens, changes and closes, which
//! overlay the files they are, and the documents of the standard library's
//! scheme.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const TextEdit = @import("../TextEdit.zig");
const standard = @import("huak_std");
const Json = std.json.Value;
const lsp = @import("../lsp.zig");
const publish = @import("publish.zig");
const Session = lsp.Session;
const field = lsp.field;
const string = lsp.string;
const integer = lsp.integer;
const byteOffset = lsp.byteOffset;
const pathFromUri = lsp.pathFromUri;
const writeMessage = lsp.writeMessage;

/// `huak/standardSource`: the source of a standard library module.
pub fn standardSource(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const uri = string(field(params, "uri")) orelse return error.InvalidParams;
    const path = try pathFromUri(self.frontend.io, allocator, uri);
    defer allocator.free(path);
    const content = standard.source(path) orelse return error.InvalidParams;
    return self.reply(writer, id, content);
}

/// `textDocument/didOpen`: keeps the editor's buffer, then checks every open
/// document.
pub fn didOpen(self: *Session, frontend: *const Frontend, params: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const item = field(params, "textDocument") orelse return error.InvalidParams;
    const uri = string(field(item, "uri")) orelse return error.InvalidParams;
    const text = string(field(item, "text")) orelse return error.InvalidParams;
    const version = integer(field(item, "version")) orelse return error.InvalidParams;
    {
        const path = try pathFromUri(self.frontend.io, allocator, uri);
        errdefer allocator.free(path);
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        const key = try allocator.dupe(u8, uri);
        errdefer allocator.free(key);
        const existing = try self.documents.getOrPut(allocator, key);
        if (existing.found_existing) {
            allocator.free(key);
            self.freeDocument(existing.value_ptr.*);
        }
        existing.value_ptr.* = .{ .text = owned_text, .path = path, .version = version };
    }
    return publish.diagnoseAll(self, frontend, writer);
}

/// `textDocument/didChange`: applies the edits of a newer version, then
/// checks every open document.
pub fn didChange(self: *Session, frontend: *const Frontend, params: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const item = field(params, "textDocument") orelse return error.InvalidParams;
    const uri = string(field(item, "uri")) orelse return error.InvalidParams;
    const version = integer(field(item, "version")) orelse return error.InvalidParams;
    const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
    if (version <= document.version) return;
    const changes = field(params, "contentChanges") orelse return error.InvalidParams;
    if (changes != .array) return error.InvalidParams;
    {
        var edit: TextEdit = .{ .source = document.text };
        defer edit.deinit(allocator);
        for (changes.array.items) |change| {
            const text = edit.bytes();
            const replacement = string(field(change, "text")) orelse return error.InvalidParams;
            var start: usize = 0;
            var end = text.len;
            if (field(change, "range")) |range| {
                start = try byteOffset(text, field(range, "start"));
                end = try byteOffset(text, field(range, "end"));
                if (start > end) return error.InvalidParams;
            }
            edit.replace(allocator, start, end, replacement) catch |err| switch (err) {
                error.InvalidRange => return error.InvalidParams,
                else => return err,
            };
        }
        if (try edit.take(allocator)) |text| {
            allocator.free(document.text);
            document.text = text;
        }
        document.version = version;
    }
    return publish.diagnoseAll(self, frontend, writer);
}

/// `textDocument/didClose`: drops the buffer and its diagnostics, then
/// checks the documents still open.
pub fn didClose(self: *Session, frontend: *const Frontend, params: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const item = field(params, "textDocument") orelse return error.InvalidParams;
    const uri = string(field(item, "uri")) orelse return error.InvalidParams;
    if (self.documents.fetchRemove(uri)) |removed| {
        allocator.free(removed.key);
        self.freeDocument(removed.value);
    }
    try writeMessage(allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .diagnostics = [_]bool{} } });
    return publish.diagnoseAll(self, frontend, writer);
}
