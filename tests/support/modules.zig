//! In-memory module sources and the import resolver that language tests compile against.
const std = @import("std");
const huak = @import("huak");
const l = huak.language;

pub const ModuleSource = struct { name: []const u8, source: []const u8 };

pub const ModuleResolver = struct {
    sources: []const ModuleSource,

    pub fn resolve(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !l.compiler.ResolvedSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        const name = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer).?, path });
        for (self.sources) |source| if (std.mem.eql(u8, source.name, name)) return .{ .name = name, .source = try allocator.dupe(u8, source.source) };
        return error.ModuleNotFound;
    }
};
