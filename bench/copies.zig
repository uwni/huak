//! Focused measurements for copy and temporary-object elimination. Each case
//! validates that the optimized and reference paths produce identical data
//! before reporting timings.
const std = @import("std");
const typst = @import("libtypst");
const options = @import("host_options");
const typst_inputs = @import("copies/typst_inputs.zig");
const outlines = @import("copies/outlines.zig");
const text_edits = @import("copies/text_edits.zig");
const adoption = @import("copies/adoption.zig");
const layoutCase = typst_inputs.layoutCase;
const sceneCase = typst_inputs.sceneCase;
const outlineCase = outlines.outlineCase;
const outlineTextCase = outlines.outlineTextCase;
const textEditCase = text_edits.textEditCase;
const adoptionCase = adoption.adoptionCase;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        std.debug.print("usage: {s} [TYPST_LIBRARY]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const library_path = if (args.len == 2) args[1] else options.library_path;
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();

    try layoutCase(init, &engine);
    try sceneCase(init, &library);
    try outlineCase(init, &engine);
    try outlineTextCase(init, &engine);
    try textEditCase(init);
    try adoptionCase(init, &library);
}
