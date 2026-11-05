//! One build shared by run and watch. Every invocation releases source,
//! bytecode, VM and native objects; only the library frontend spans builds.
const std = @import("std");
const huak = @import("huak");
const flags = @import("options.zig");
const disassemble = @import("disassemble.zig");
const execution = @import("execution.zig");
const outputs = @import("outputs.zig");
const output_paths = @import("output_paths.zig");
const Report = @import("Report.zig");

const Session = @This();

allocator: std.mem.Allocator,
io: std.Io,
frontend: *huak.tooling.Frontend,
options: flags.Options,

pub fn build(self: *Session, report: *Report) !void {
    try output_paths.validate(self.io, report.allocator, self.options.outputs, report);
    const path = self.options.script.?;
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, report.allocator) catch |err|
        return report.fail("{s}: cannot read script: {s}", .{ path, @errorName(err) });
    const source = std.Io.Dir.cwd().readFileAlloc(self.io, canonical, report.allocator, .unlimited) catch |err|
        return report.fail("{s}: cannot read script: {s}", .{ path, @errorName(err) });
    var selected = try self.prepare(path, canonical, source, report);
    if (selected) |*batch| {
        defer batch.deinit();
        const publication: outputs.Publication = if (self.options.command == .watch) .atomic else .in_place;
        try outputs.write(self.io, self.allocator, batch, self.options.outputs, self.options.jobs, path, publication, report);
    }
}

/// Execution storage ends before output workers start. The library wrapper
/// stays at a stable address while the batch retains its native resources.
fn prepare(self: *Session, path: []const u8, canonical: []const u8, source: []const u8, report: *Report) !?huak.language.OutputBatch {
    var diagnostic: ?huak.language.compiler.Diagnostic = null;
    if (self.options.command == .check) {
        self.frontend.check(source, canonical, &diagnostic) catch |err| return self.compilationFailure(path, source, &diagnostic, err, report);
        return null;
    }
    var program = self.frontend.compile(source, canonical, &diagnostic) catch |err| return self.compilationFailure(path, source, &diagnostic, err, report);
    defer program.deinit();
    switch (self.options.command) {
        .disassemble => {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(self.io, &buffer);
            try disassemble.write(&program, &writer.interface);
            try writer.interface.flush();
            return null;
        },
        .run, .watch => {},
        .check, .help => unreachable,
    }
    const library = self.frontend.getLibrary() catch |err|
        return report.fail("huak: cannot load libtypst '{s}': {s}", .{ self.frontend.library_path, @errorName(err) });
    return try execution.execute(self.allocator, self.io, library, &program, self.options, path, source, report);
}

fn compilationFailure(self: *Session, path: []const u8, source: []const u8, diagnostic: *const ?huak.language.compiler.Diagnostic, cause: anyerror, report: *Report) anyerror {
    if (self.frontend.native_error) |native_error|
        return report.fail("huak: cannot load libtypst '{s}': {s}", .{ self.frontend.library_path, @errorName(native_error) });
    if (diagnostic.*) |*detail| {
        report.print(path, source, detail);
        return error.Reported;
    }
    return cause;
}
