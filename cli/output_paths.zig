//! Reject output aliases before the script or any output file is started.
const std = @import("std");
const builtin = @import("builtin");
const Output = @import("options.zig").Output;
const Report = @import("Report.zig");
const Identity = struct { device: u64, inode: u64 };
const Missing = struct { parent: Identity, basename: []const u8 };
pub const Existing = std.AutoHashMapUnmanaged(Identity, []const u8);

pub fn validate(io: std.Io, allocator: std.mem.Allocator, outputs: []const Output, report: *Report) !Existing {
    var files: Existing = .empty;
    errdefer files.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var paths: std.StringHashMapUnmanaged(void) = .{};
    var missing: std.ArrayList(Missing) = .empty;
    for (outputs) |output| {
        const path = try std.posix.toPosixPath(output.path);
        if (try identity(io, std.mem.sliceTo(&path, 0))) |file| {
            const entry = try files.getOrPut(allocator, file);
            if (entry.found_existing) return duplicate(output.path, report);
            entry.value_ptr.* = output.path;
            continue;
        }
        // An absent destination needs alias checks only when another output
        // could create it. Its parent is otherwise checked by the writer.
        if (outputs.len < 2) continue;
        const canonical = try destination(io, memory, output.path, 0);
        if ((try paths.getOrPut(memory, canonical)).found_existing) return duplicate(output.path, report);
        const parent = try memory.dupeSentinel(u8, std.fs.path.dirname(canonical).?, 0);
        const directory = (try identity(io, parent)) orelse return error.FileNotFound;
        const basename = std.fs.path.basename(canonical);
        for (missing.items) |previous| {
            if (!std.meta.eql(directory, previous.parent)) continue;
            if (std.mem.eql(u8, basename, previous.basename)) return duplicate(output.path, report);
            if (!asciiOnly(basename) or !asciiOnly(previous.basename) or std.ascii.eqlIgnoreCase(basename, previous.basename)) {
                if (try filesystemAliases(io, parent, basename, previous.basename)) return duplicate(output.path, report);
            }
        }
        try missing.append(memory, .{ .parent = directory, .basename = basename });
    }
    return files;
}

pub fn checkInput(io: std.Io, existing: *const Existing, input: []const u8, report: *Report) !void {
    if (existing.count() == 0) return;
    const path = try std.posix.toPosixPath(input);
    const file = try identity(io, std.mem.sliceTo(&path, 0)) orelse return;
    if (existing.get(file)) |output| return report.fail("huak: output '{s}' would overwrite input '{s}'", .{ output, input });
}

fn asciiOnly(name: []const u8) bool {
    for (name) |byte| if (!std.ascii.isAscii(byte)) return false;
    return true;
}

// The filesystem defines Unicode normalization and case equivalence. Probe in
// a private sibling directory, without creating or opening either output name.
fn filesystemAliases(io: std.Io, parent: []const u8, first: []const u8, second: []const u8) !bool {
    const directory = try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer directory.close(io);
    var name_buffer: [48]u8 = undefined;
    const name = created: {
        for (0..8) |_| {
            var random: [12]u8 = undefined;
            io.random(&random);
            var encoded: [16]u8 = undefined;
            _ = std.base64.url_safe.Encoder.encode(&encoded, &random);
            const name = try std.fmt.bufPrint(&name_buffer, ".huak-output-check-{s}", .{encoded});
            directory.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break :created name;
        }
        return error.PathAlreadyExists;
    };
    const result = probeNames(io, directory, name, first, second);
    // Cancellation must not strand the private probe directory. Cleanup errors
    // are reported as failures, including when the probe itself failed.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    try directory.deleteTree(io, name);
    return result;
}

fn probeNames(io: std.Io, parent: std.Io.Dir, directory_name: []const u8, first: []const u8, second: []const u8) !bool {
    const directory = try parent.openDir(io, directory_name, .{});
    defer directory.close(io);
    const a = try directory.createFile(io, first, .{ .exclusive = true });
    a.close(io);
    const b = directory.createFile(io, second, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return true,
        else => return err,
    };
    b.close(io);
    return false;
}

fn duplicate(path: []const u8, report: *Report) error{Reported} {
    return report.fail("huak: duplicate output path '{s}'", .{path});
}

fn destination(io: std.Io, allocator: std.mem.Allocator, path: []const u8, links: usize) ![:0]const u8 {
    if (links == 40) return error.SymLinkLoop;
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = std.Io.Dir.cwd().readLink(io, path, &buffer) catch |link_err| switch (link_err) {
                error.NotLink, error.FileNotFound => {
                    const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(path) orelse ".", allocator);
                    return std.fs.path.joinZ(allocator, &.{ parent, std.fs.path.basename(path) });
                },
                else => return link_err,
            };
            const target = buffer[0..length];
            const joined = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse ".", target });
            return destination(io, allocator, joined, links + 1);
        },
        else => return err,
    };
}

// std.Io.File.Stat currently exposes the inode without its device. Both are
// required: inode numbers are only unique within one filesystem.
fn identity(io: std.Io, path: [:0]const u8) !?Identity {
    while (true) {
        const result: struct { code: std.posix.E, file: Identity } = switch (builtin.os.tag) {
            .macos => value: {
                var stat: std.c.Stat = undefined;
                const code = std.c.errno(std.c.fstatat(std.c.AT.FDCWD, path.ptr, &stat, 0));
                break :value .{ .code = code, .file = if (code == .SUCCESS) .{ .device = @bitCast(@as(i64, stat.dev)), .inode = stat.ino } else undefined };
            },
            .linux => value: {
                const linux = std.os.linux;
                var stat: linux.Statx = undefined;
                const code = linux.errno(linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .INO = true }, &stat));
                if (code == .SUCCESS and !stat.mask.INO) return error.FileSystem;
                break :value .{ .code = code, .file = if (code == .SUCCESS) .{ .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor, .inode = stat.ino } else undefined };
            },
            else => @compileError("huak currently supports macOS and Linux"),
        };
        switch (result.code) {
            .SUCCESS => return result.file,
            .NOENT => return null,
            .INTR => try io.checkCancel(),
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NOTDIR => return error.NotDir,
            else => return std.posix.unexpectedErrno(result.code),
        }
    }
}
