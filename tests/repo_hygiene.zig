//! Repository hygiene contracts: source files stay within the 20,000-byte
//! token budget enforced by `.githooks/pre-commit`, and the 3D projection
//! README names the same C ABI entry point as `projection.h`.
const std = @import("std");
const t = std.testing;

const size_limit: u64 = 20_000;

const source_roots = [_][]const u8{
    "src",
    "cli",
    "apps",
    "build",
    "tests",
    "stdlib",
    "packages",
    "libtypst/src",
    "libtypst/tests",
    "bench",
};

fn skippedDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".git");
}

/// Matches `read_as_source` in `.githooks/pre-commit`.
fn readAsSource(path: []const u8) bool {
    const ignored_extensions = [_][]const u8{
        ".lock", ".svg", ".png", ".jpg", ".jpeg", ".otf", ".ttf", ".pdf", ".json", ".csv",
    };
    for (ignored_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return false;
    }
    if (std.mem.eql(u8, path, "libtypst/include/libtypst.h")) return false;
    if (std.mem.find(u8, path, "LICENSE") != null) return false;
    if (std.mem.find(u8, path, "/licenses/") != null) return false;
    return true;
}

fn checkDirectory(allocator: std.mem.Allocator, dir: std.Io.Dir, prefix: []const u8, failures: *usize) !void {
    var iterator = dir.iterate();
    while (try iterator.next(t.io)) |entry| {
        if (entry.kind == .directory) {
            if (skippedDirectory(entry.name)) continue;
            const child_path = try allocator.print("{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(child_path);
            var child = try dir.openDir(t.io, entry.name, .{ .iterate = true });
            defer child.close(t.io);
            try checkDirectory(allocator, child, child_path, failures);
        } else if (entry.kind == .file) {
            const full_path = try allocator.print("{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(full_path);
            if (!readAsSource(full_path)) continue;
            const stat = try dir.statFile(t.io, entry.name, .{});
            if (stat.size > size_limit) {
                std.debug.print("oversize source file: {s} ({d} bytes > {d})\n", .{ full_path, stat.size, size_limit });
                failures.* += 1;
            }
        }
    }
}

test "source files stay within the 20,000-byte limit" {
    var failures: usize = 0;
    for (source_roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(t.io, root, .{ .iterate = true });
        defer dir.close(t.io);
        try checkDirectory(t.allocator, dir, root, &failures);
    }
    try t.expectEqual(@as(usize, 0), failures);
}

test "space README matches HUAK_SPACE_ABI_VERSION in projection.h" {
    const header = @embedFile("space_projection_h");
    const readme = @embedFile("space_readme");
    const marker = "#define HUAK_SPACE_ABI_VERSION ";
    const start = (std.mem.find(u8, header, marker) orelse return error.AbiVersionNotFound) + marker.len;
    const end = std.mem.findScalarPos(u8, header, start, '\n') orelse header.len;
    const raw = std.mem.trimEnd(u8, std.mem.trim(u8, header[start..end], " \t\r"), "uU");
    const version = try std.fmt.parseInt(u32, raw, 0);
    const major = version >> 16;

    var expected_buf: [32]u8 = undefined;
    const expected = try std.mem.print(&expected_buf, "huak_space_api_v{d}", .{major});
    try t.expect(std.mem.find(u8, header, expected) != null);

    const prefix = "huak_space_api_v";
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.findPos(u8, readme, at, prefix)) |pos| {
        var tail = pos + prefix.len;
        while (tail < readme.len and std.ascii.isDigit(readme[tail])) : (tail += 1) {}
        const mentioned = readme[pos..tail];
        if (!std.mem.eql(u8, mentioned, expected)) {
            std.debug.print("src/drawing/space/README.md mentions '{s}', expected '{s}'\n", .{ mentioned, expected });
            return error.TestUnexpectedResult;
        }
        found += 1;
        at = tail;
    }
    try t.expect(found > 0);
}
