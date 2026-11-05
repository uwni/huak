//! Standalone stdio language server. Standard output is JSON-RPC only.
const std = @import("std");
const clap = @import("clap");
const tooling = @import("huak_tooling");
const defaults = @import("host_options");
const params = clap.parseParamsComptime(
    \\--help              Display usage.
    \\--stdio             Use standard input/output (the default transport).
    \\--libtypst <PATH>    Native syntax library for Typst blocks.
);

pub fn main(init: std.process.Init) void {
    const clean_exit = run(init) catch |err| {
        std.debug.print("huak-lsp: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    if (!clean_exit) std.process.exit(1);
}

fn run(init: std.process.Init) !bool {
    const result = try clap.parse(clap.Help, &params, .{ .PATH = clap.parsers.string }, init.minimal.args, .{ .allocator = init.gpa });
    defer result.deinit();
    if (result.args.help != 0) {
        // Help goes to stderr so stdout remains a protocol channel.
        var help_buffer: [4096]u8 = undefined;
        var output = std.Io.File.stderr().writerStreaming(init.io, &help_buffer);
        try output.interface.writeAll("usage: huak-lsp [--stdio] [--libtypst PATH]\n");
        try clap.help(&output.interface, clap.Help, &params, .{});
        try output.interface.flush();
        return true;
    }
    const path = result.args.libtypst orelse defaults.library_path;
    var frontend: tooling.Frontend = .{ .allocator = init.gpa, .io = init.io, .library_path = path };
    defer frontend.deinit();
    var session: tooling.lsp.Session = .{ .frontend = &frontend };
    defer session.deinit();
    var read_buffer: [8192]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &read_buffer);
    var write_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &write_buffer);
    while (!session.exited) {
        const body = (try tooling.lsp.readMessage(init.gpa, &input.interface)) orelse return session.shutdown;
        defer init.gpa.free(body);
        try session.handle(body, &output.interface);
    }
    return session.shutdown;
}
