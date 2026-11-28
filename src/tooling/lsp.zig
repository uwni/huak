//! Language Server Protocol 3.17 over stdio. JSON is handled by std.json;
//! document checking and formatting share the ordinary language frontend.
const std = @import("std");
const Frontend = @import("Frontend.zig");
const SourceLoader = @import("SourceLoader.zig");
const locations = @import("position.zig");
const definitions = @import("definition.zig");
const semantic_tokens = @import("semantic_tokens.zig");
const compiler = @import("../language/compiler.zig");
const standard = @import("huak_std");
const Json = std.json.Value;
const documents = @import("lsp/documents.zig");
const navigation = @import("lsp/navigation.zig");
const presentation = @import("lsp/presentation.zig");

pub const max_message_bytes = 8 * 1024 * 1024;

/// The requests this server answers beyond the protocol's own: a standard
/// library module's source, and the pictures a script exports.
pub const requests = struct {
    pub const standard_source = "huak/standardSource";
    pub const outputs = "huak/outputs";
};
/// The URI scheme of the standard library's modules.
pub const standard_scheme = definitions.standard_scheme;

/// The requests the server answers by method, and the notifications it
/// takes, each with its handler.
const request_handlers = .{
    .{ requests.standard_source, documents.standardSource },
    .{ "textDocument/definition", navigation.definition },
    .{ "textDocument/semanticTokens/full", presentation.semanticTokens },
    .{ "textDocument/inlayHint", presentation.inlayHint },
    .{ requests.outputs, presentation.outputs },
    .{ "textDocument/completion", navigation.completion },
    .{ "textDocument/hover", navigation.hover },
    .{ "textDocument/formatting", presentation.formatting },
};
const notification_handlers = .{
    .{ "textDocument/didOpen", documents.didOpen },
    .{ "textDocument/didChange", documents.didChange },
    .{ "textDocument/didClose", documents.didClose },
};

pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var length: ?usize = null;
    var header_bytes: usize = 0;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse {
            if (header_bytes == 0) return null;
            return error.IncompleteHeader;
        };
        header_bytes += line.len + 1;
        if (header_bytes > 8192 or line.len == 0 or line[line.len - 1] != '\r') return error.InvalidHeader;
        const content = line[0 .. line.len - 1];
        if (content.len == 0) break;
        const colon = std.mem.findScalar(u8, content, ':') orelse return error.InvalidHeader;
        if (std.ascii.eqlIgnoreCase(content[0..colon], "Content-Length")) {
            if (length != null) return error.InvalidHeader;
            length = std.fmt.parseInt(usize, std.mem.trim(u8, content[colon + 1 ..], " \t"), 10) catch return error.InvalidHeader;
        }
    }
    const count = length orelse return error.InvalidHeader;
    if (count > max_message_bytes) return error.MessageTooLarge;
    const body = try allocator.alloc(u8, count);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

pub fn writeMessage(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(body);
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

pub const Document = struct { text: []u8, path: [:0]const u8, version: i64 };
pub const Session = struct {
    frontend: *const Frontend,
    documents: std.StringHashMapUnmanaged(Document) = .{},
    initialized: bool = false,
    shutdown: bool = false,
    exited: bool = false,

    pub fn deinit(self: *Session) void {
        var entries = self.documents.iterator();
        while (entries.next()) |entry| {
            self.frontend.allocator.free(entry.key_ptr.*);
            self.freeDocument(entry.value_ptr.*);
        }
        self.documents.deinit(self.frontend.allocator);
        self.* = undefined;
    }

    pub fn freeDocument(self: *Session, document: Document) void {
        self.frontend.allocator.free(document.text);
        self.frontend.allocator.free(document.path);
    }

    pub fn handle(self: *Session, bytes: []const u8, writer: *std.Io.Writer) !void {
        const parsed = std.json.parseFromSlice(Json, self.frontend.allocator, bytes, .{ .allocate = .alloc_always }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.failure(writer, .null, -32700, "Parse error");
        };
        defer parsed.deinit();
        const message = parsed.value;
        const id = field(message, "id");
        const method = string(field(message, "method")) orelse return self.failure(writer, id orelse .null, -32600, "Invalid request");
        if (!std.mem.eql(u8, string(field(message, "jsonrpc")) orelse "", "2.0")) return self.failure(writer, id orelse .null, -32600, "Invalid request");
        if (id) |request_id| switch (request_id) {
            .integer, .string, .null => {},
            else => return self.failure(writer, .null, -32600, "Invalid request id"),
        };
        if (std.mem.eql(u8, method, "exit")) {
            self.exited = true;
            return;
        }
        if (self.shutdown) {
            if (id) |request_id| try self.failure(writer, request_id, -32600, "Server has shut down");
            return;
        }
        if (std.mem.eql(u8, method, "initialize")) {
            if (id == null) return;
            if (self.initialized) return self.failure(writer, id.?, -32600, "Already initialized");
            self.initialized = true;
            return self.reply(writer, id.?, .{
                .capabilities = .{
                    .positionEncoding = "utf-16",
                    .textDocumentSync = .{ .openClose = true, .change = @as(u8, 2) },
                    .documentFormattingProvider = true,
                    .completionProvider = .{ .triggerCharacters = [_][]const u8{"."} },
                    .hoverProvider = true,
                    .definitionProvider = true,
                    .inlayHintProvider = true,
                    .semanticTokensProvider = .{ .legend = semantic_tokens.legend, .full = true },
                },
                .serverInfo = .{ .name = "huak-lsp", .version = "0.1.0" },
            });
        }
        if (!self.initialized) {
            if (id) |request_id| try self.failure(writer, request_id, -32002, "Server not initialized");
            return;
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            if (id) |request_id| {
                self.shutdown = true;
                try self.reply(writer, request_id, @as(?bool, null));
            }
            return;
        }
        const params = field(message, "params") orelse .null;
        self.dispatch(method, params, id, writer) catch |err| switch (err) {
            error.InvalidParams, error.InvalidUri, error.UnknownDocument => if (id) |request_id| try self.failure(writer, request_id, -32602, @errorName(err)),
            else => return err,
        };
    }

    /// Answers a request, or takes a notification, by its method, with the
    /// session's open documents overlaying the files they are.
    fn dispatch(self: *Session, method: []const u8, params: Json, id: ?Json, writer: *std.Io.Writer) !void {
        var frontend = self.frontend.*;
        frontend.overlay = .{ .ptr = self, .vtable = &.{ .resolve = Session.overlay } };
        if (std.mem.eql(u8, method, "initialized") or std.mem.eql(u8, method, "$/cancelRequest")) return;
        inline for (request_handlers) |entry| if (std.mem.eql(u8, method, entry[0])) {
            const request_id = id orelse return;
            return entry[1](self, &frontend, params, request_id, writer);
        };
        inline for (notification_handlers) |entry| if (std.mem.eql(u8, method, entry[0])) return entry[1](self, &frontend, params, writer);
        if (id) |request_id| try self.failure(writer, request_id, -32601, "Method not found");
    }

    pub fn overlay(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !compiler.ResolvedSource {
        const self: *Session = @ptrCast(@alignCast(context));
        const joined = if (std.Io.Dir.path.isAbsolute(path)) path else try std.Io.Dir.path.join(allocator, &.{ std.Io.Dir.path.dirname(importer) orelse ".", path });
        defer if (!std.Io.Dir.path.isAbsolute(path)) allocator.free(joined);
        const key = try SourceLoader.canonicalPath(self.frontend.io, allocator, joined);
        defer allocator.free(key);
        if (self.openDocument(key)) |entry| return .{ .name = entry.value_ptr.path, .source = entry.value_ptr.text };
        const fallback = self.frontend.overlay orelse return error.FileNotFound;
        return fallback.resolve(allocator, importer, path);
    }

    pub fn openDocument(self: *Session, path: []const u8) ?std.StringHashMapUnmanaged(Document).Entry {
        var found: ?std.StringHashMapUnmanaged(Document).Entry = null;
        var entries = self.documents.iterator();
        while (entries.next()) |entry| {
            if (std.mem.eql(u8, path, entry.value_ptr.path) and
                (found == null or std.mem.order(u8, entry.key_ptr.*, found.?.key_ptr.*) == .lt)) found = entry;
        }
        return found;
    }

    /// The URI a request names in `params.textDocument.uri`, and the open
    /// document there.
    pub fn requestedDocument(self: *Session, params: Json) !struct { []const u8, *Document } {
        const item = field(params, "textDocument") orelse return error.InvalidParams;
        const uri = string(field(item, "uri")) orelse return error.InvalidParams;
        const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
        return .{ uri, document };
    }

    pub fn reply(self: *Session, writer: *std.Io.Writer, id: Json, result: anytype) !void {
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }
    pub fn failure(self: *Session, writer: *std.Io.Writer, id: Json, code: i64, message: []const u8) !void {
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }
};

pub fn field(value: Json, key: []const u8) ?Json {
    return if (value == .object) value.object.get(key) else null;
}
pub fn string(value: ?Json) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}
pub fn integer(value: ?Json) ?i64 {
    const v = value orelse return null;
    return if (v == .integer) v.integer else null;
}
pub fn position(value: Json) !locations.Position {
    const line = integer(field(value, "line")) orelse return error.InvalidParams;
    const character = integer(field(value, "character")) orelse return error.InvalidParams;
    if (line < 0 or character < 0) return error.InvalidParams;
    return .{ .line = @intCast(line), .character = @intCast(character) };
}
/// The byte offset in `text` of the position `value`.
pub fn byteOffset(text: []const u8, value: ?Json) !usize {
    return locations.offset(text, try position(value orelse return error.InvalidParams)) orelse return error.InvalidParams;
}
pub fn pathFromUri(io: std.Io, allocator: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    const uri = std.Uri.parse(text) catch return error.InvalidUri;
    if (std.ascii.eqlIgnoreCase(uri.scheme, definitions.standard_scheme)) {
        if (uri.host != null or uri.query != null or uri.fragment != null) return error.InvalidUri;
        const raw = try uri.path.toRawMaybeAlloc(allocator);
        defer if (uri.path == .percent_encoded and std.mem.findScalar(u8, uri.path.percent_encoded, '%') != null) allocator.free(raw);
        if (raw.len == 0 or raw[0] != '/' or standard.source(raw[1..]) == null) return error.InvalidUri;
        return allocator.dupeSentinel(u8, raw[1..], 0);
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or uri.query != null or uri.fragment != null) return error.InvalidUri;
    if (uri.host) |host| {
        const raw = try host.toRawMaybeAlloc(allocator);
        defer if (host == .percent_encoded and std.mem.findScalar(u8, host.percent_encoded, '%') != null) allocator.free(raw);
        if (raw.len != 0 and !std.ascii.eqlIgnoreCase(raw, "localhost")) return error.InvalidUri;
    }
    const raw = try uri.path.toRawMaybeAlloc(allocator);
    defer if (uri.path == .percent_encoded and std.mem.findScalar(u8, uri.path.percent_encoded, '%') != null) allocator.free(raw);
    if (!std.Io.Dir.path.isAbsolute(raw) or std.mem.findScalar(u8, raw, 0) != null) return error.InvalidUri;
    return SourceLoader.canonicalPath(io, allocator, raw);
}

test "JSON-RPC framing handles multiple messages and rejects conflicting lengths" {
    const a = std.testing.allocator;
    var input = std.Io.Reader.fixed("Content-Length: 2\r\n\r\n{}Content-Length: 2\r\n\r\n[]");
    const first = (try readMessage(a, &input)).?;
    defer a.free(first);
    const second = (try readMessage(a, &input)).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("{}", first);
    try std.testing.expectEqualStrings("[]", second);
    try std.testing.expect(try readMessage(a, &input) == null);
    input = .fixed("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}");
    try std.testing.expectError(error.InvalidHeader, readMessage(a, &input));
}

test {
    _ = @import("lsp/publish.zig");
}
