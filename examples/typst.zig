//! Compile one in-memory Typst document through the native C ABI.
const std = @import("std");
const typst = @import("libtypst");
const sample = @import("typst_sample");
const workflow = @import("typst_workflow");
const options = @import("host_options");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1 and args.len != 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const output_path = if (args.len == 3) args[2] else "target/typst.svg";
    var library = typst.Library.open(if (args.len == 3) args[1] else options.library_path) catch |err| {
        std.debug.print("Cannot load libtypst: {s}\n", .{@errorName(err)});
        return err;
    };
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var output = try workflow.render(&engine, sample.source);
    defer output.deinit();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output.bytes() });
    std.debug.print("libtypst source rendering: {d} SVG bytes at {s}\n", .{ output.bytes().len, output_path });
}
