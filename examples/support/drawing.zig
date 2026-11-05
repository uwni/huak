//! Shared native drawing workflow for the example and benchmark.
const std = @import("std");
const typst = @import("libtypst");
const backend = @import("huak").backend;
const demo = @import("drawing_scene");

pub const OutputFormat = enum { svg, pdf };

pub fn render(allocator: std.mem.Allocator, engine: *typst.Engine, delta: f64, format: OutputFormat) !typst.Buffer {
    var measured: [demo.requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&demo.requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var warnings = try labels.warnings();
    defer warnings.deinit();
    if (warnings.bytes().len != 0) {
        std.debug.print("Typst label warnings: {s}\n", .{warnings.bytes()});
        return error.UnexpectedWarning;
    }
    var picture = (try demo.build(allocator, &measured, delta)).picture;
    defer picture.deinit();
    var document = try backend.submit(allocator, engine.library, &picture, demo.width, demo.height, .{ .frames = &frames });
    defer document.deinit();
    return switch (format) {
        .svg => document.exportSvg(0),
        .pdf => document.exportPdf(),
    };
}
