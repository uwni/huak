//! Command selection. Single builds, watching, execution and output scheduling
//! have separate owners and lifetimes.
const std = @import("std");
const huak = @import("huak");
const flags = @import("options.zig");
const defaults = @import("host_options");
const Frontend = huak.tooling.Frontend;
const Session = @import("Session.zig");
const Report = @import("Report.zig");
const watch = @import("watch.zig");
const use_safe_allocator = switch (@import("builtin").mode) {
    .debug, .safe => true,
    .fast, .small => false,
};
var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});

pub fn main(init: std.process.Init.Minimal) void {
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.c_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    run(init.args, threaded.io(), arena.allocator()) catch |err| {
        if (err != error.Reported) std.debug.print("huak: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(arguments: std.process.Args, io: std.Io, allocator: std.mem.Allocator) !void {
    const args = try arguments.toSlice(allocator);
    var option_error: ?[]const u8 = null;
    const options = flags.parse(allocator, args[1..], &option_error) catch |err| {
        if (option_error) |message| {
            std.debug.print("huak: {s}\n\n", .{message});
            try printUsage(io, .stderr());
            return error.Reported;
        }
        return err;
    };
    if (options.command == .help) return printUsage(io, .stdout());
    // Rendering releases shared picture/layout owners on worker threads.
    const shared_allocator = std.heap.smp_allocator;
    var frontend: Frontend = .{ .allocator = shared_allocator, .io = io, .library_path = options.library orelse defaults.library_path };
    defer frontend.deinit();
    var session: Session = .{ .allocator = shared_allocator, .io = io, .frontend = &frontend, .options = options };
    if (options.command == .watch) return watch.run(&session);
    var scratch: std.heap.ArenaAllocator = .init(shared_allocator);
    defer scratch.deinit();
    var report: Report = .{ .allocator = scratch.allocator(), .io = io };
    try session.build(&report);
}

fn printUsage(io: std.Io, file: std.Io.File) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try flags.writeUsage(&writer.interface);
    try writer.interface.flush();
}
