//! Compiling and executing aggregate programs, and checks of the list values they return.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const Value = l.types.Value;
const modules = @import("../support/modules.zig");

pub fn compile(allocator: std.mem.Allocator, library: *typst.Library, text: []const u8, sources: []const modules.ModuleSource, optimize: bool, diagnostic: *?l.compiler.Diagnostic) !l.bytecode.Program {
    var resolver: modules.ModuleResolver = .{ .sources = sources };
    return l.compiler.compile(allocator, text, "/aggregates/main.huak", .{
        .source_parser = .init(library),
        .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = modules.ModuleResolver.resolve } },
        .optimize = optimize,
    }, diagnostic);
}

pub fn compileValid(library: *typst.Library, text: []const u8, sources: []const modules.ModuleSource, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return compile(t.allocator, library, text, sources, optimize, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("aggregate compiler: {s}: {s}\n", .{ detail.fileName() orelse "/aggregates/main.huak", detail.text() });
        return err;
    };
}

pub fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("aggregate VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

pub fn expectInts(value: Value, expected: []const i64) !void {
    const items = l.types.sequence(value) orelse return error.ExpectedList;
    try t.expectEqual(expected.len, items.len);
    for (items, expected) |item, integer| try t.expectEqualDeep(Value{ .int = integer }, item);
}

pub fn expectStrings(value: Value, expected: []const []const u8) !void {
    const items = l.types.sequence(value) orelse return error.ExpectedList;
    try t.expectEqual(expected.len, items.len);
    for (items, expected) |item, text| try t.expectEqualStrings(text, item.string);
}
