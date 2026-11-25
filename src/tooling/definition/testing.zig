//! A test resolver over in-memory files, with definition expectations.
const std = @import("std");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Lexer = @import("../../language/Lexer.zig");
const Frontend = @import("../Frontend.zig");
const locations = @import("../position.zig");
const definition = @import("../definition.zig");
const Location = definition.Location;
const find = definition.find;
const uriForPath = definition.uriForPath;

pub const Fixture = struct {
    name: []const u8 = "/tmp/definition.huak",
    source: []const u8,
    files: []const struct { name: []const u8, source: []const u8 } = &.{},

    pub fn resolve(context: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.eql(u8, path, file.name)) return .{ .name = file.name, .source = file.source };
        return error.FileNotFound;
    }

    pub fn lookup(self: *const Fixture, allocator: std.mem.Allocator, query: []const u8) !?Location {
        const frontend: Frontend = .{ .allocator = allocator, .io = std.testing.io, .source_parser = @import("../../language/Parser.zig").TestSourceParser.parser, .overlay = .{ .ptr = @constCast(self), .vtable = &.{ .resolve = resolve } } };
        const offset = std.mem.lastIndexOf(u8, self.source, query) orelse return error.MissingTestQuery;
        return find(&frontend, allocator, self.source, self.name, offset);
    }

    pub fn expect(self: *const Fixture, query: []const u8, uri: []const u8, target_source: []const u8, target_name: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const result = (try self.lookup(arena.allocator(), query)) orelse return error.MissingDefinition;
        const start = std.mem.indexOf(u8, target_source, target_name) orelse return error.MissingTestTarget;
        var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
        var scanner: Lexer = .{ .source = target_source, .pos = start, .diagnostic = &diagnostic };
        const token = try scanner.next();
        try std.testing.expectEqualStrings(uri, try uriForPath(arena.allocator(), result.path));
        try std.testing.expectEqualDeep(locations.Range{ .start = locations.at(target_source, start), .end = locations.at(target_source, token.span.end) }, result.range);
    }

    pub fn expectNone(self: *const Fixture, query: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expect(try self.lookup(arena.allocator(), query) == null);
    }
};
