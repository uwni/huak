//! Generate one mathematical picture through the native drawing backend.
const std = @import("std");
const typst = @import("libtypst");
const workflow = @import("drawing_workflow");
const options = @import("host_options");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1 and args.len != 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg|OUTPUT.pdf]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const output_path = if (args.len == 3) args[2] else "target/huak.svg";
    const format: workflow.OutputFormat = if (std.mem.endsWith(u8, output_path, ".svg")) .svg else if (std.mem.endsWith(u8, output_path, ".pdf")) .pdf else return error.InvalidOutputFormat;
    var library = try typst.Library.open(if (args.len == 3) args[1] else options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var output = workflow.render(init.gpa, &engine, 0, format) catch |err| {
        var diagnostic = try library.lastError();
        defer diagnostic.deinit();
        std.debug.print("libtypst: {s}\n", .{diagnostic.bytes()});
        return err;
    };
    defer output.deinit();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output.bytes() });
    std.debug.print("huak native scene: {d} bytes at {s}\n", .{ output.bytes().len, output_path });
}
