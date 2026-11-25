//! Writes the patterns that the language defines into the editor grammars:
//! `editor-grammar GRAMMAR CONFIGURATION`, the VS Code TextMate grammar and
//! language configuration. Each file keeps the rest of its text.
const std = @import("std");
const tooling = @import("huak_tooling");
const grammar = tooling.editor_grammar;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) {
        std.debug.print("usage: editor-grammar GRAMMAR CONFIGURATION\n", .{});
        std.process.exit(2);
    }
    try rewrite(init.io, a, args[1], &try grammar.grammarEntries(a));
    try rewrite(init.io, a, args[2], &try grammar.configurationEntries(a));
}

fn rewrite(io: std.Io, a: std.mem.Allocator, path: []const u8, entries: []const grammar.Entry) !void {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    const written = try grammar.apply(a, json, entries);
    if (std.mem.eql(u8, json, written)) return;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = stat.permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, written);
    try atomic.replace(io);
}
