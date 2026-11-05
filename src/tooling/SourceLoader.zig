//! Filesystem policy for Huak imports. The compiler itself only uses a resolver.
const std = @import("std");
const compiler = @import("../language/compiler.zig");

const SourceLoader = @This();

const CachedSource = struct { name: [:0]u8, source: []u8 };
/// Hosts can observe paths attempted by the resolver, including missing
/// imports. The callback borrows the path only for the duration of the call.
pub const Observer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub inline fn observe(self: Observer, path: []const u8) anyerror!void {
        return self.vtable.observe(self.ptr, path);
    }

    pub const VTable = struct {
        observe: *const fn (*anyopaque, []const u8) anyerror!void,
    };
};
io: std.Io,
allocator: std.mem.Allocator,
sources: std.StringHashMapUnmanaged(CachedSource) = .{},
overlay: ?compiler.ImportResolver = null,
observer: ?Observer = null,

pub fn deinit(self: *SourceLoader) void {
    var sources = self.sources.valueIterator();
    while (sources.next()) |cached| {
        self.allocator.free(cached.name);
        self.allocator.free(cached.source);
    }
    self.sources.deinit(self.allocator);
    self.* = undefined;
}

/// The compiler copies each source into its Program. Release these raw
/// filesystem buffers when compilation ends, rather than retaining copies
/// throughout layout and rendering.
pub fn resolve(context: *anyopaque, _: std.mem.Allocator, importer: []const u8, path: []const u8) !compiler.ResolvedSource {
    const self: *SourceLoader = @ptrCast(@alignCast(context));
    const memory = self.allocator;
    if (self.overlay) |overlay| {
        if (overlay.resolve(memory, importer, path)) |resolved| return resolved else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    const absolute = std.fs.path.isAbsolute(path);
    const joined = if (absolute) path else try std.fs.path.join(memory, &.{ std.fs.path.dirname(importer) orelse ".", path });
    defer if (!absolute) memory.free(joined);
    if (self.observer) |observer| try observer.observe(joined);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, memory);
    errdefer memory.free(canonical);
    if (self.observer) |observer| try observer.observe(canonical);
    if (self.sources.get(canonical)) |existing| {
        memory.free(canonical);
        return .{ .name = existing.name, .source = existing.source };
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, canonical, memory, .unlimited);
    errdefer memory.free(bytes);
    try self.sources.put(memory, canonical, .{ .name = canonical, .source = bytes });
    return .{ .name = canonical, .source = bytes };
}
