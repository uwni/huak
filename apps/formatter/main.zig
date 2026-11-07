//! Standalone formatter application; no drawing command or renderer entrypoint.
const std = @import("std");
const clap = @import("clap");
const tooling = @import("huak_tooling");
const typst = @import("libtypst");
const defaults = @import("host_options");
const params = clap.parseParamsComptime(
    \\--help                   Display usage.
    \\--check                  Check formatting without changing files.
    \\--stdin                  Read source from standard input.
    \\--stdin-filepath <PATH>   Resolve stdin imports relative to this file.
    \\--stdout                 Write a single formatted file to standard output.
    \\--libtypst <PATH>         Native syntax library for Typst blocks.
    \\<FILE>...                Files to format in place.
);

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        if (err != error.Reported) std.debug.print("huak-fmt: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try clap.parse(clap.Help, &params, .{ .PATH = clap.parsers.string, .FILE = clap.parsers.string }, init.minimal.args, .{ .allocator = init.gpa });
    defer args.deinit();
    if (args.args.help != 0) {
        var buffer: [4096]u8 = undefined;
        var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try output.interface.writeAll("usage: huak-fmt [--check] FILE...\n       huak-fmt --stdin [--stdin-filepath PATH]\n");
        try clap.help(&output.interface, clap.Help, &params, .{});
        try output.interface.flush();
        return 0;
    }
    const files = args.positionals[0];
    const check = args.args.check != 0;
    const stdin = args.args.stdin != 0;
    const stdout = args.args.stdout != 0;
    const stdin_path = args.args.@"stdin-filepath" orelse "stdin.huak";
    const library_path = args.args.libtypst orelse defaults.library_path;
    if ((stdin and files.len != 0) or (stdout and files.len > 1) or (check and stdout)) return error.InvalidArguments;
    var backend = typst.Library.open(library_path);
    defer if (backend) |*library| library.deinit() else |_| {};
    const frontend: tooling.Frontend = .{ .allocator = init.gpa, .io = init.io, .source_parser = if (backend) |*library| .init(library) else |err| err };
    if (stdin or files.len == 0) {
        var reader_buffer: [8192]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &reader_buffer);
        var source: std.Io.Writer.Allocating = .init(a);
        _ = try reader.interface.streamRemaining(&source.writer);
        const path = try tooling.SourceLoader.canonicalPath(init.io, a, stdin_path);
        const formatted = try format(&frontend, source.written(), path);
        defer init.gpa.free(formatted);
        if (check) return if (std.mem.eql(u8, source.written(), formatted)) 0 else 1;
        try std.Io.File.stdout().writeStreamingAll(init.io, formatted);
        return 0;
    }
    var changed = false;
    for (files) |file| {
        // Keep only the current file. The previous process-wide arena retained
        // every input file until exit, so peak memory grew with the file list.
        var per_file: std.heap.ArenaAllocator = .init(init.gpa);
        defer per_file.deinit();
        const file_arena = per_file.allocator();
        const path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, file, file_arena);
        const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, file_arena, .limited(16 * 1024 * 1024));
        const formatted = try format(&frontend, source, path);
        defer init.gpa.free(formatted);
        if (stdout) {
            try std.Io.File.stdout().writeStreamingAll(init.io, formatted);
        } else if (!std.mem.eql(u8, source, formatted)) {
            changed = true;
            if (check) {
                std.debug.print("{s}\n", .{file});
            } else {
                const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
                var atomic = try std.Io.Dir.cwd().createFileAtomic(init.io, path, .{ .replace = true, .permissions = stat.permissions });
                defer atomic.deinit(init.io);
                try atomic.file.writeStreamingAll(init.io, formatted);
                try atomic.replace(init.io);
            }
        }
    }
    return if (check and changed) 1 else 0;
}

fn format(frontend: *const tooling.Frontend, source: []const u8, path: []const u8) ![]u8 {
    var diagnostic: ?tooling.compiler.Diagnostic = null;
    return tooling.format.format(frontend, source, path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (diagnostic) |*message| {
            tooling.diagnostics.report(frontend.io, frontend.allocator, path, source, message);
            return error.Reported;
        }
        return err;
    };
}
