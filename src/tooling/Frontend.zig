//! Host-side compilation shared by the command line and editor applications.
const std = @import("std");
const compiler = @import("../language/compiler.zig");
const bytecode = @import("../language/bytecode.zig");
const ast = @import("../language/ast.zig");
const ModuleGraph = @import("../language/ModuleGraph.zig");
const SourceLoader = @import("SourceLoader.zig");

const Frontend = @This();

/// Parsed source and AST borrow the caller's arena. Imported syntax is
/// resolved through the same loader and native Typst parser as compilation.
pub const Syntax = struct { source_text: []const u8, script: ast.Script };
pub const Observer = SourceLoader.Observer;
allocator: std.mem.Allocator,
io: std.Io,
/// Embedded syntax is a borrowed host service.
source_parser: anyerror!?compiler.SourceParser = null,
/// Borrowed during source requests, for example unsaved editor documents.
overlay: ?compiler.ImportResolver = null,
dependency_observer: ?Observer = null,

pub fn sourceBlock(self: *const Frontend, source: []const u8) !usize {
    const parser = (try self.source_parser) orelse return error.MissingSourceParser;
    return parser.block(source);
}

pub fn compile(self: *const Frontend, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !bytecode.Program {
    var files = self.sourceLoader();
    defer files.deinit();
    return compiler.compile(self.allocator, source, path, self.compileOptions(&files), diagnostic);
}

pub fn check(self: *const Frontend, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !void {
    var files = self.sourceLoader();
    defer files.deinit();
    return compiler.check(self.allocator, source, path, self.compileOptions(&files), diagnostic);
}

pub fn syntax(self: *const Frontend, arena: std.mem.Allocator, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !Syntax {
    const parsed = try self.graph(arena, source, path, diagnostic);
    const root = parsed.units.items[0];
    return .{ .source_text = root.source_text, .script = root.script };
}

/// The ordinary module graph retains lexical scopes and original exported
/// identities for navigation. All graph storage belongs to the request arena.
pub fn graph(self: *const Frontend, arena: std.mem.Allocator, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !ModuleGraph {
    var files = self.sourceLoader();
    defer files.deinit();
    return compiler.parseModules(arena, arena, source, path, self.compileOptions(&files), diagnostic);
}

fn sourceLoader(self: *const Frontend) SourceLoader {
    return .{ .io = self.io, .allocator = self.allocator, .overlay = self.overlay, .observer = self.dependency_observer };
}

fn compileOptions(self: *const Frontend, files: *SourceLoader) compiler.CompileOptions {
    return .{ .source_parser = self.source_parser, .import_resolver = .{ .ptr = files, .vtable = &.{ .resolve = SourceLoader.resolve } } };
}
