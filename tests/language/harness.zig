//! Compiling and running test scripts against the native library, alone or with in-memory modules.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const ModuleSource = @import("../support/modules.zig").ModuleSource;
const ModuleResolver = @import("../support/modules.zig").ModuleResolver;

pub fn compile(library: *typst.Library, source: []const u8) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "native-test.huak", .{ .source_parser = .init(library) }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}\n", .{detail.text()});
        return err;
    };
}

pub fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

pub fn linkedModule(program: *const l.bytecode.Program, name: []const u8) !l.bytecode.Module {
    var found: ?l.bytecode.Module = null;
    for (program.modules) |module| {
        if (!std.mem.eql(u8, module.name, name)) continue;
        try t.expect(found == null);
        found = module;
    }
    return found orelse error.MissingModule;
}

pub fn compileModules(library: *typst.Library, source: []const u8, sources: []const ModuleSource) !l.bytecode.Program {
    return compileModulesOptimized(library, source, sources, true);
}

pub fn compileModulesOptimized(library: *typst.Library, source: []const u8, sources: []const ModuleSource, optimize: bool) !l.bytecode.Program {
    var resolver: ModuleResolver = .{ .sources = sources };
    var diagnostic: ?l.compiler.Diagnostic = null;
    return l.compiler.compile(t.allocator, source, "/native/main.huak", .{
        .source_parser = .init(library),
        .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } },
        .optimize = optimize,
    }, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("compiler: {s}: {s}\n", .{ detail.fileName() orelse "/native/main.huak", detail.text() });
        return err;
    };
}
