//! Build the static example catalog from the repository tree.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer dir.close(init.io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(init.io)) |item| {
        if (item.kind != .file) continue;
        const path = try arena.dupe(u8, item.path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        try paths.append(arena, path);
    }
    std.mem.sort([]const u8, paths.items, {}, byPath);
    var files: std.json.ArrayHashMap([]const u8) = .{};
    var entries: std.ArrayList([]const u8) = .empty;
    for (paths.items) |path| {
        try files.map.put(arena, path, try dir.readFileAlloc(init.io, path, arena, .unlimited));
        if (!std.mem.endsWith(u8, path, ".huak")) continue;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "lib")) break;
        } else try entries.append(arena, path);
    }
    const json = try std.json.Stringify.valueAlloc(arena, .{ .entries = entries.items, .files = files }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = json });
}

fn byPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
