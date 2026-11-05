//! Watch the source graph used by a build. Standard file metadata and a short
//! quiet interval handle in-place edits, atomic saves and missing-file recovery.
const std = @import("std");
const Session = @import("Session.zig");
const Report = @import("Report.zig");
const Output = @import("options.zig").Output;

var stopping: std.atomic.Value(bool) = .init(false);

fn stop(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

pub fn run(session: *Session) !void {
    const io = session.io;
    const allocator = session.allocator;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    var previous_int: std.posix.Sigaction = undefined;
    var previous_term: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = stop }, .mask = std.posix.sigemptyset(), .flags = 0 };
    stopping.store(false, .monotonic);
    std.posix.sigaction(.INT, &action, &previous_int);
    std.posix.sigaction(.TERM, &action, &previous_term);
    defer std.posix.sigaction(.INT, &previous_int, null);
    defer std.posix.sigaction(.TERM, &previous_term, null);
    var watched: Dependencies = .init(allocator, io, cwd);
    defer watched.deinit();
    defer session.frontend.dependency_observer = null;

    while (!stopping.load(.monotonic)) {
        var observed: Dependencies = .init(allocator, io, cwd);
        var transferred = false;
        defer if (!transferred) observed.deinit();
        try observed.addInput(session.options.script.?);
        for (session.options.fonts) |font| try observed.addInput(font);
        session.frontend.dependency_observer = .{ .ptr = &observed, .vtable = &.{ .observe = Dependencies.observe } };
        const succeeded = try rebuild(session, cwd);
        session.frontend.dependency_observer = null;
        if (!succeeded) {
            // A syntax error may stop discovery before an old dependency is
            // visited. Keep those paths until the next successful build.
            try observed.retain(&watched);
        }
        watched.deinit();
        watched = observed;
        transferred = true;
        try watched.waitForChange();
    }
}

fn rebuild(session: *Session, cwd: []const u8) !bool {
    const io = session.io;
    var temporary: std.heap.ArenaAllocator = .init(session.allocator);
    defer temporary.deinit();
    var report: Report = .{ .allocator = temporary.allocator(), .io = io };
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    if (session.options.json) {
        try event(io, .{ .event = "build_start" });
    } else std.debug.print("watch: building {s}\n", .{session.options.script.?});
    session.build(&report) catch |err| {
        if (session.options.json) {
            try event(io, .{ .event = "error", .message = report.message orelse @errorName(err) });
        } else {
            if (err != error.Reported) std.debug.print("huak: {s}\n", .{@errorName(err)});
            std.debug.print("watch: build failed; waiting for changes\n", .{});
        }
        return false;
    };
    const duration_ms = started.untilNow(io).raw.toMilliseconds();
    if (session.options.json) {
        const absolute = try report.allocator.alloc(Output, session.options.outputs.len);
        for (absolute, session.options.outputs) |*to, from| to.* = .{
            .name = from.name,
            .path = try std.fs.path.resolve(report.allocator, &.{ cwd, from.path }),
        };
        try event(io, .{ .event = "success", .outputs = absolute, .duration_ms = duration_ms });
    } else std.debug.print("watch: built in {d} ms; waiting for changes\n", .{duration_ms});
    return true;
}

fn event(io: std.Io, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

const Stamp = union(enum) {
    file: struct { inode: std.Io.File.INode, size: u64, mtime: i96, ctime: i96 },
    failure: anyerror,

    fn read(io: std.Io, path: []const u8) Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return .{ .failure = err };
        return .{ .file = .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds } };
    }
};

const Dependencies = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    cwd: []const u8,
    files: std.StringHashMapUnmanaged(Stamp) = .{},

    fn init(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) Dependencies {
        return .{ .arena = .init(allocator), .io = io, .cwd = cwd };
    }

    fn deinit(self: *Dependencies) void {
        self.arena.deinit();
    }

    fn observe(context: *anyopaque, path: []const u8) !void {
        const self: *Dependencies = @ptrCast(@alignCast(context));
        if (std.fs.path.isAbsolute(path) and self.files.contains(path)) return;
        const absolute = try std.fs.path.resolve(self.arena.allocator(), &.{ self.cwd, path });
        if (!self.files.contains(absolute)) try self.files.put(self.arena.allocator(), absolute, Stamp.read(self.io, absolute));
    }

    fn addInput(self: *Dependencies, path: []const u8) !void {
        try observe(self, path);
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.arena.allocator()) catch return;
        try observe(self, canonical);
    }

    fn retain(self: *Dependencies, old: *const Dependencies) !void {
        var entries = old.files.iterator();
        while (entries.next()) |entry| {
            if (self.files.contains(entry.key_ptr.*)) continue;
            const path = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
            try self.files.put(self.arena.allocator(), path, entry.value_ptr.*);
        }
    }

    fn changed(self: *Dependencies) bool {
        var any_changed = false;
        var entries = self.files.iterator();
        while (entries.next()) |entry| {
            const next = Stamp.read(self.io, entry.key_ptr.*);
            if (!std.meta.eql(entry.value_ptr.*, next)) {
                entry.value_ptr.* = next;
                any_changed = true;
            }
        }
        return any_changed;
    }

    fn waitForChange(self: *Dependencies) !void {
        var last_change: ?std.Io.Clock.Timestamp = null;
        while (!stopping.load(.monotonic)) {
            try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
            if (self.changed()) last_change = std.Io.Clock.Timestamp.now(self.io, .awake);
            if (last_change) |last| if (last.untilNow(self.io).raw.toMilliseconds() >= 150) return;
        }
    }
};
