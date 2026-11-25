//! Compiling and executing scripts against the bundled standard library.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;

pub fn compile(library: *typst.Library, source: []const u8, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "standard-library-test.huak", .{
        .source_parser = .init(library),
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

pub fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| {
            std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
            for (detail.trace) |entry| std.debug.print("  {s} in {s}\n", .{ entry.function, machine.program.modules[entry.module].name });
        }
        return err;
    };
}
