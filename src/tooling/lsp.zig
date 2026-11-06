//! Language Server Protocol 3.17 over stdio. JSON is handled by std.json;
//! document checking and formatting share the ordinary language frontend.
const std = @import("std");
const Frontend = @import("Frontend.zig");
const formatting = @import("format.zig");
const inlay = @import("inlay_hints.zig");
const locations = @import("position.zig");
const TextEdit = @import("TextEdit.zig");
const bundles = @import("diagnostics.zig");
const output_choices = @import("outputs.zig");
const definitions = @import("definition.zig");
const semantic_tokens = @import("semantic_tokens.zig");
const compiler = @import("../language/compiler.zig");
const builtins = @import("../language/builtin.zig");
const Lexer = @import("../language/Lexer.zig");
const standard = @import("huak_std");
const Json = std.json.Value;

pub const max_message_bytes = 8 * 1024 * 1024;

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
        const colon = std.mem.indexOfScalar(u8, content, ':') orelse return error.InvalidHeader;
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

const Document = struct { text: []u8, path: []const u8, version: i64 };
// Protocol payloads only; ErrorBundle remains the diagnostic owner.
const RelatedInformation = struct {
    const Location = struct { uri: []const u8, range: locations.Range };
    location: Location,
    message: []const u8,
};
const PublishedDiagnostic = struct {
    range: locations.Range,
    severity: u8 = 1,
    source: []const u8 = "huak",
    message: []const u8,
    relatedInformation: []const RelatedInformation,
};
pub const Session = struct {
    frontend: *Frontend,
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

    fn freeDocument(self: *Session, document: Document) void {
        self.frontend.allocator.free(document.text);
        self.frontend.allocator.free(document.path);
    }

    pub fn handle(self: *Session, bytes: []const u8, writer: *std.Io.Writer) !void {
        const parsed = std.json.parseFromSlice(Json, self.frontend.allocator, bytes, .{ .allocate = .alloc_always }) catch {
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
        const previous_overlay = self.frontend.overlay;
        self.frontend.overlay = .{ .ptr = self, .vtable = &.{ .resolve = overlay } };
        defer self.frontend.overlay = previous_overlay;
        self.dispatch(method, params, id, writer) catch |err| switch (err) {
            error.InvalidParams, error.InvalidUri, error.UnknownDocument => if (id) |request_id| try self.failure(writer, request_id, -32602, @errorName(err)),
            else => return err,
        };
    }

    fn dispatch(self: *Session, method: []const u8, params: Json, id: ?Json, writer: *std.Io.Writer) !void {
        const allocator = self.frontend.allocator;
        if (std.mem.eql(u8, method, "initialized") or std.mem.eql(u8, method, "$/cancelRequest")) return;
        if (std.mem.eql(u8, method, "huak/standardSource")) {
            if (id == null) return;
            const uri = string(field(params, "uri")) orelse return error.InvalidParams;
            const path = try pathFromUri(allocator, uri);
            defer allocator.free(path);
            const content = standard.source(path) orelse return error.InvalidParams;
            return self.reply(writer, id.?, content);
        }
        if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            const byte_offset = locations.offset(document.text, try position(field(params, "position") orelse return error.InvalidParams)) orelse return error.InvalidParams;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            return self.reply(writer, id.?, try definitions.find(self.frontend, arena.allocator(), document.text, document.path, byte_offset));
        }
        if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            return self.reply(writer, id.?, .{ .data = try semantic_tokens.collect(self.frontend, arena.allocator(), document.text, document.path) });
        }
        if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            const requested = field(params, "range") orelse return error.InvalidParams;
            const start = locations.offset(document.text, try position(field(requested, "start") orelse return error.InvalidParams)) orelse return error.InvalidParams;
            const end = locations.offset(document.text, try position(field(requested, "end") orelse return error.InvalidParams)) orelse return error.InvalidParams;
            if (start > end) return error.InvalidParams;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            var diagnostic: ?compiler.Diagnostic = null;
            const syntax = self.frontend.syntax(arena.allocator(), document.text, document.path, &diagnostic) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.reply(writer, id.?, [_]bool{});
            };
            const hints = try inlay.collect(arena.allocator(), syntax.source_text, syntax.script.statements, uri, .{ .start = start, .end = end });
            return self.reply(writer, id.?, hints);
        }
        if (std.mem.eql(u8, method, "huak/outputs")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            var diagnostic: ?compiler.Diagnostic = null;
            var program = self.frontend.compile(document.text, document.path, &diagnostic) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (diagnostic) |detail| return self.failure(writer, id.?, -32603, detail.text());
                return self.failure(writer, id.?, -32603, @errorName(err));
            };
            defer program.deinit();
            const outputs = try output_choices.collect(allocator, &program);
            defer allocator.free(outputs);
            return self.reply(writer, id.?, .{ .outputs = outputs });
        }
        if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            const byte_offset = locations.offset(document.text, try position(field(params, "position") orelse return error.InvalidParams)) orelse return error.InvalidParams;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            var items: std.ArrayList(definitions.Completion) = .empty;
            const contextual = try definitions.complete(self.frontend, arena.allocator(), document.text, document.path, byte_offset);
            try items.appendSlice(arena.allocator(), contextual);
            if (definitions.memberRequest(document.text, byte_offset))
                return self.reply(writer, id.?, .{ .isIncomplete = false, .items = items.items });
            for (builtins.signatures) |signature| if (signature.implicit) {
                const present = for (items.items) |candidate| {
                    if (std.mem.eql(u8, candidate.label, signature.name)) break true;
                } else false;
                if (!present) try items.append(arena.allocator(), .{ .label = signature.name, .kind = 3, .detail = try definitions.builtinText(arena.allocator(), signature) });
            };
            inline for (comptime std.meta.tags(Lexer.Kind)) |kind| {
                const name = comptime @tagName(kind);
                if (comptime std.mem.startsWith(u8, name, "kw_")) try items.append(arena.allocator(), .{ .label = name[3..], .kind = 14, .detail = "Huak keyword" });
            }
            return self.reply(writer, id.?, .{ .isIncomplete = false, .items = items.items });
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            const byte_offset = locations.offset(document.text, try position(field(params, "position") orelse return error.InvalidParams)) orelse return error.InvalidParams;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            if (try definitions.describe(self.frontend, arena.allocator(), document.text, document.path, byte_offset)) |detail|
                return self.reply(writer, id.?, .{ .contents = .{ .kind = "plaintext", .value = detail } });
            const name = try identifierAt(self.frontend, document.text, byte_offset);
            if (name) |identifier| if (builtins.implicit(identifier)) |signature| {
                const detail = try definitions.builtinText(allocator, signature);
                defer allocator.free(detail);
                return self.reply(writer, id.?, .{ .contents = .{ .kind = "plaintext", .value = detail } });
            };
            return self.reply(writer, id.?, @as(?bool, null));
        }
        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const text = string(field(item, "text")) orelse return error.InvalidParams;
            const version = integer(field(item, "version")) orelse return error.InvalidParams;
            {
                const path = try pathFromUri(allocator, uri);
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
            return self.diagnoseAll(writer);
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
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
                        start = locations.offset(text, try position(field(range, "start") orelse return error.InvalidParams)) orelse return error.InvalidParams;
                        end = locations.offset(text, try position(field(range, "end") orelse return error.InvalidParams)) orelse return error.InvalidParams;
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
            return self.diagnoseAll(writer);
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            if (self.documents.fetchRemove(uri)) |removed| {
                allocator.free(removed.key);
                self.freeDocument(removed.value);
            }
            try writeMessage(allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .diagnostics = [_]bool{} } });
            return self.diagnoseAll(writer);
        }
        if (std.mem.eql(u8, method, "textDocument/formatting")) {
            if (id == null) return;
            const item = field(params, "textDocument") orelse return error.InvalidParams;
            const uri = string(field(item, "uri")) orelse return error.InvalidParams;
            const document = self.documents.getPtr(uri) orelse return error.UnknownDocument;
            const options = field(params, "options") orelse return error.InvalidParams;
            const tab_size = integer(field(options, "tabSize")) orelse return error.InvalidParams;
            const spaces = field(options, "insertSpaces") orelse return error.InvalidParams;
            if (spaces != .bool or tab_size < 1 or tab_size > 16) return error.InvalidParams;
            var diagnostic: ?compiler.Diagnostic = null;
            const formatted = formatting.formatWithOptions(self.frontend, document.text, document.path, &diagnostic, .{ .tab_size = @intCast(tab_size), .insert_spaces = spaces.bool }) catch |err| {
                if (diagnostic) |*detail| {
                    var bundle = try bundles.fromDiagnostic(allocator, document.path, document.text, detail);
                    defer bundle.deinit(allocator);
                    return self.failure(writer, id.?, -32603, bundle.nullTerminatedString(bundle.getErrorMessage(bundle.getMessages()[0]).msg));
                }
                return self.failure(writer, id.?, -32603, @errorName(err));
            };
            defer allocator.free(formatted);
            if (std.mem.eql(u8, formatted, document.text)) return self.reply(writer, id.?, [_]bool{});
            return self.reply(writer, id.?, .{.{ .range = locations.Range{ .start = .{ .line = 0, .character = 0 }, .end = locations.at(document.text, document.text.len) }, .newText = formatted }});
        }
        if (id) |request_id| try self.failure(writer, request_id, -32601, "Method not found");
    }

    fn diagnoseAll(self: *Session, writer: *std.Io.Writer) !void {
        var entries = self.documents.iterator();
        while (entries.next()) |entry| try self.diagnostics(entry.key_ptr.*, entry.value_ptr, writer);
    }

    fn overlay(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !compiler.ResolvedSource {
        const self: *Session = @ptrCast(@alignCast(context));
        const wanted = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer) orelse ".", path });
        defer allocator.free(wanted);
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.frontend.io, wanted, allocator) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        defer if (canonical) |name| allocator.free(name);
        var entries = self.documents.valueIterator();
        while (entries.next()) |document| {
            if (std.mem.eql(u8, wanted, document.path) or (canonical != null and std.mem.eql(u8, canonical.?, document.path))) return .{ .name = document.path, .source = document.text };
        }
        return error.FileNotFound;
    }

    fn diagnostics(self: *Session, uri: []const u8, document: *const Document, writer: *std.Io.Writer) !void {
        var diagnostic: ?compiler.Diagnostic = null;
        self.frontend.check(document.text, document.path, &diagnostic) catch |err| {
            if (diagnostic) |*detail| {
                var bundle = try bundles.fromDiagnostic(self.frontend.allocator, document.path, document.text, detail);
                defer bundle.deinit(self.frontend.allocator);
                return self.publishBundle(uri, document, bundle, writer);
            }
            var wip = try std.zig.ErrorBundle.Wip.init(self.frontend.allocator);
            defer wip.deinit();
            try wip.addRootErrorMessage(.{ .msg = try wip.addString(@errorName(err)) });
            var bundle = try wip.toOwnedBundle("");
            defer bundle.deinit(self.frontend.allocator);
            return self.publishBundle(uri, document, bundle, writer);
        };
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = document.version, .diagnostics = [_]bool{} } });
    }

    fn publishBundle(self: *Session, uri: []const u8, document: *const Document, bundle: std.zig.ErrorBundle, writer: *std.Io.Writer) !void {
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
                    if (try self.relatedLocation(allocator, bundle, loc)) |location| try related.append(allocator, .{ .location = location, .message = bundle.nullTerminatedString(root.msg) });
                }
            }
            try body.writer.writeAll(bundle.nullTerminatedString(root.msg));
            for (bundle.getNotes(index)) |note_index| {
                const note = bundle.getErrorMessage(note_index);
                if (note.src_loc == .none) {
                    try body.writer.print("\n{s}", .{bundle.nullTerminatedString(note.msg)});
                } else if (try self.relatedLocation(allocator, bundle, bundle.getSourceLocation(note.src_loc))) |location| {
                    try related.append(allocator, .{ .location = location, .message = bundle.nullTerminatedString(note.msg) });
                }
            }
            try published.append(allocator, .{ .range = range, .message = try body.toOwnedSlice(), .relatedInformation = related.items });
        }
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .method = "textDocument/publishDiagnostics", .params = .{ .uri = uri, .version = document.version, .diagnostics = published.items } });
    }

    fn relatedLocation(self: *Session, allocator: std.mem.Allocator, bundle: std.zig.ErrorBundle, loc: std.zig.ErrorBundle.SourceLocation) !?RelatedInformation.Location {
        const path = bundle.nullTerminatedString(loc.src_path);
        if (!std.fs.path.isAbsolute(path)) return null;
        var content: ?[]const u8 = null;
        var documents = self.documents.valueIterator();
        while (documents.next()) |document| if (std.mem.eql(u8, document.path, path)) {
            content = document.text;
            break;
        };
        if (content == null and loc.source_line == 0) content = std.Io.Dir.cwd().readFileAlloc(self.frontend.io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
        const address: std.Uri = .{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } };
        return .{ .uri = try std.fmt.allocPrint(allocator, "{f}", .{address.fmt(.all)}), .range = locationRange(bundle, loc, content) };
    }

    fn reply(self: *Session, writer: *std.Io.Writer, id: Json, result: anytype) !void {
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }
    fn failure(self: *Session, writer: *std.Io.Writer, id: Json, code: i64, message: []const u8) !void {
        try writeMessage(self.frontend.allocator, writer, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }
};

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

fn field(value: Json, key: []const u8) ?Json {
    return if (value == .object) value.object.get(key) else null;
}
fn string(value: ?Json) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}
fn integer(value: ?Json) ?i64 {
    const v = value orelse return null;
    return if (v == .integer) v.integer else null;
}
fn position(value: Json) !locations.Position {
    const line = integer(field(value, "line")) orelse return error.InvalidParams;
    const character = integer(field(value, "character")) orelse return error.InvalidParams;
    if (line < 0 or character < 0) return error.InvalidParams;
    return .{ .line = @intCast(line), .character = @intCast(character) };
}
fn pathFromUri(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const uri = std.Uri.parse(text) catch return error.InvalidUri;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "huak-stdlib")) {
        if (uri.host != null or uri.query != null or uri.fragment != null) return error.InvalidUri;
        const raw = try uri.path.toRawMaybeAlloc(allocator);
        defer if (uri.path == .percent_encoded and std.mem.indexOfScalar(u8, uri.path.percent_encoded, '%') != null) allocator.free(raw);
        if (raw.len == 0 or raw[0] != '/' or standard.source(raw[1..]) == null) return error.InvalidUri;
        return allocator.dupe(u8, raw[1..]);
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or uri.query != null or uri.fragment != null) return error.InvalidUri;
    if (uri.host) |host| {
        const raw = try host.toRawMaybeAlloc(allocator);
        defer if (host == .percent_encoded and std.mem.indexOfScalar(u8, host.percent_encoded, '%') != null) allocator.free(raw);
        if (raw.len != 0 and !std.ascii.eqlIgnoreCase(raw, "localhost")) return error.InvalidUri;
    }
    const raw = try uri.path.toRawMaybeAlloc(allocator);
    defer if (uri.path == .percent_encoded and std.mem.indexOfScalar(u8, uri.path.percent_encoded, '%') != null) allocator.free(raw);
    if (!std.fs.path.isAbsolute(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidUri;
    return std.fs.path.resolve(allocator, &.{raw});
}

fn identifierAt(frontend: *Frontend, input: []const u8, byte_offset: usize) !?[]const u8 {
    const token = try definitions.tokenAt(frontend, input, byte_offset) orelse return null;
    return if (token.kind == .identifier) input[token.span.start..token.span.end] else null;
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

test "ErrorBundle locations produce UTF-16 ranges and structured related information" {
    const allocator = std.testing.allocator;
    const text = "emoji:=\"🙂\"; missing\n";
    const start = std.mem.indexOf(u8, text, "missing").?;
    var detail: @import("../language/Machine.zig").RuntimeDiagnostic = .{
        .diagnostic = @import("../language/source.zig").Diagnostic.init(.{ .start = start, .end = start + 7 }, "unknown identifier", .{}),
        .native_message = "native detail",
        .trace = &.{.{ .function = "caller", .module = 0, .span = .{ .start = start, .end = start + 7 } }},
    };
    detail.diagnostic.setSource("/unavailable/figure file.huak", text);
    var bundle = try bundles.fromRuntime(allocator, "/unavailable/figure file.huak", text, &detail, &.{.{ .name = "/unavailable/figure file.huak", .source_text = text, .entry = 0, .exports = &.{} }});
    defer bundle.deinit(allocator);
    var frontend: Frontend = .{ .allocator = allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var session: Session = .{ .frontend = &frontend };
    defer session.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const document: Document = .{ .text = @constCast(text), .path = "/unavailable/figure file.huak", .version = 3 };
    try session.publishBundle("file:///unavailable/figure%20file.huak", &document, bundle, &output.writer);
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
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.get("message").?.string, "native detail") != null);
    const related = diagnostic.get("relatedInformation").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), related.len);
    try std.testing.expectEqualStrings("at caller", related[0].object.get("message").?.string);
    const place = related[0].object.get("location").?.object;
    try std.testing.expectEqualStrings("file:///unavailable/figure%20file.huak", place.get("uri").?.string);
    try std.testing.expectEqual(primary.get("character").?.integer, place.get("range").?.object.get("start").?.object.get("character").?.integer);
}
