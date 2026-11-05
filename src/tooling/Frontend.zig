//! Host-side compilation shared by the command line and editor applications.
const std = @import("std");
const compiler = @import("../language/compiler.zig");
const bytecode = @import("../language/bytecode.zig");
const ast = @import("../language/ast.zig");
const ModuleGraph = @import("../language/ModuleGraph.zig");
const typst = @import("libtypst");
const SourceLoader = @import("SourceLoader.zig");

const Frontend = @This();

/// Parsed source and AST borrow the caller's arena. Imported syntax is
/// resolved through the same loader and native Typst parser as compilation.
pub const Syntax = struct { source_text: []const u8, script: ast.Script };
allocator: std.mem.Allocator,
io: std.Io,
library_path: []const u8,
native: ?typst.Library = null,
native_error: ?anyerror = null,
/// Borrowed during source requests, for example unsaved editor documents.
overlay: ?compiler.ImportResolver = null,
dependency_observer: ?SourceLoader.Observer = null,

pub fn deinit(self: *Frontend) void {
    if (self.native) |*library| library.deinit();
    self.* = undefined;
}

pub fn getLibrary(self: *Frontend) !*typst.Library {
    if (self.native == null) self.native = typst.Library.open(self.library_path) catch |err| {
        self.native_error = err;
        return err;
    };
    return &self.native.?;
}

pub fn sourceBlock(self: *Frontend, source: []const u8) !usize {
    return (try self.getLibrary()).sourceBlock(source);
}

pub fn compile(self: *Frontend, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !bytecode.Program {
    return (try self.request(source, path, diagnostic, .compile)).?;
}

pub fn check(self: *Frontend, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !void {
    _ = try self.request(source, path, diagnostic, .check);
}

fn request(self: *Frontend, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic, comptime purpose: enum { compile, check }) !?bytecode.Program {
    self.native_error = null;
    var loader: SourceLoader = .{ .io = self.io, .allocator = self.allocator, .overlay = self.overlay, .observer = self.dependency_observer };
    defer loader.deinit();
    const options: compiler.CompileOptions = .{
        .source_parser = .{ .ptr = self, .vtable = &.{ .block = block } },
        .import_resolver = .{ .ptr = &loader, .vtable = &.{ .resolve = SourceLoader.resolve } },
    };
    if (purpose == .check) {
        try compiler.check(self.allocator, source, path, options, diagnostic);
        return null;
    }
    return try compiler.compile(self.allocator, source, path, options, diagnostic);
}

pub fn syntax(self: *Frontend, arena: std.mem.Allocator, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !Syntax {
    const parsed = try self.graph(arena, source, path, diagnostic);
    const root = parsed.units.items[0];
    return .{ .source_text = root.source_text, .script = root.script };
}

/// The ordinary module graph retains lexical scopes and original exported
/// identities for navigation. All graph storage belongs to the request arena.
pub fn graph(self: *Frontend, arena: std.mem.Allocator, source: []const u8, path: []const u8, diagnostic: *?compiler.Diagnostic) !ModuleGraph {
    self.native_error = null;
    diagnostic.* = null;
    var loader: SourceLoader = .{ .io = self.io, .allocator = self.allocator, .overlay = self.overlay, .observer = self.dependency_observer };
    defer loader.deinit();
    var parsed_graph = ModuleGraph.init(arena, arena, .{ .source_parser = .{ .ptr = self, .vtable = &.{ .block = block } } }, .{ .ptr = &loader, .vtable = &.{ .resolve = SourceLoader.resolve } }, diagnostic);
    try parsed_graph.root(path, source);
    // This is a loaded syntax snapshot. The loader is request-local and
    // cannot remain available through a borrowed resolver callback.
    parsed_graph.resolver = null;
    return parsed_graph;
}

fn block(context: *anyopaque, source: []const u8) !usize {
    const self: *Frontend = @ptrCast(@alignCast(context));
    return self.sourceBlock(source);
}
