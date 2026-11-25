//! Symbol requests: where a name is defined, what it is, and what may be
//! written at a point, answered through `definition.zig`.
const std = @import("std");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const definitions = @import("../definition.zig");
const builtins = @import("../../language/builtin.zig");
const Lexer = @import("../../language/Lexer.zig");
const Json = std.json.Value;
const lsp = @import("../lsp.zig");
const Session = lsp.Session;
const field = lsp.field;
const byteOffset = lsp.byteOffset;

/// `textDocument/definition`: where the name at a position is defined, in
/// the open document of its file when there is one.
pub fn definition(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    const uri, const document = try self.requestedDocument(params);
    const byte_offset = try byteOffset(document.text, field(params, "position"));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const target = try definitions.find(frontend, arena.allocator(), document.text, document.path, byte_offset) orelse
        return self.reply(writer, id, @as(?locations.Location, null));
    const address = if (std.mem.eql(u8, document.path, target.path)) uri else if (self.openDocument(target.path)) |entry| entry.key_ptr.* else try definitions.uriForPath(arena.allocator(), target.path);
    return self.reply(writer, id, locations.Location{ .uri = address, .range = target.range });
}

/// `textDocument/completion`: what the context at a position offers; after a
/// member access only that, else also the implicit builtins and the keywords.
pub fn completion(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    _, const document = try self.requestedDocument(params);
    const byte_offset = try byteOffset(document.text, field(params, "position"));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var items: std.ArrayList(definitions.completion.Completion) = .empty;
    const contextual = try definitions.completion.complete(frontend, arena.allocator(), document.text, document.path, byte_offset);
    try items.appendSlice(arena.allocator(), contextual);
    if (definitions.completion.memberRequest(document.text, byte_offset))
        return self.reply(writer, id, .{ .isIncomplete = false, .items = items.items });
    for (builtins.signatures) |signature| if (signature.implicit) {
        const present = for (items.items) |candidate| {
            if (std.mem.eql(u8, candidate.label, signature.name)) break true;
        } else false;
        if (!present) try items.append(arena.allocator(), .{ .label = signature.name, .kind = 3, .detail = try definitions.hover.builtinText(arena.allocator(), signature) });
    };
    inline for (comptime std.meta.tags(Lexer.Kind)) |kind| {
        const name = comptime @tagName(kind);
        if (comptime std.mem.startsWith(u8, name, "kw_")) try items.append(arena.allocator(), .{ .label = name[3..], .kind = 14, .detail = "Huak keyword" });
    }
    // Members of the `typ` keyword form keywords of their own.
    for ([_][]const u8{ "typ.module", "typ.show" }) |form| try items.append(arena.allocator(), .{ .label = form, .kind = 14, .detail = "Huak keyword" });
    return self.reply(writer, id, .{ .isIncomplete = false, .items = items.items });
}

/// `textDocument/hover`: what the name at a position is, or nothing.
pub fn hover(self: *Session, frontend: *const Frontend, params: Json, id: Json, writer: *std.Io.Writer) !void {
    const allocator = frontend.allocator;
    _, const document = try self.requestedDocument(params);
    const byte_offset = try byteOffset(document.text, field(params, "position"));
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    if (try definitions.hover.describe(frontend, arena.allocator(), document.text, document.path, byte_offset)) |detail|
        return self.reply(writer, id, .{ .contents = .{ .kind = "plaintext", .value = detail } });
    return self.reply(writer, id, @as(?bool, null));
}
