//! Optional artistic lettering: shaped glyphs become editable huak paths while
//! other labels in the same PDF remain native, selectable text.
const std = @import("std");
const typst = @import("libtypst");
const options = @import("host_options");
const outlines = @import("huak").text.outline;
const backend = @import("huak").backend;
const g = @import("huak").core.geometry;
const DisplayList = @import("huak").core.DisplayList;
const Path = @import("huak").core.Path;

const requests = [_]typst.LayoutRequest{
    request("#text(size: 25pt, fill: rgb(35, 45, 66))[Editable glyph outlines]"),
    request("#text(size: 92pt, fill: rgb(35, 45, 66))[huak]"),
    request("#text(size: 32pt, fill: rgb(35, 45, 66))[$integral_0^1 x^2 dif x = 1/3$]"),
    request("#text(size: 15pt, fill: rgb(35, 45, 66))[Normal label: select and copy this text.]"),
    request("#text(size: 13pt, fill: rgb(35, 45, 66))[Per-glyph rotation, scale, colour and Bezier control edits in Zig]"),
};

fn request(comptime source: []const u8) typst.LayoutRequest {
    return .{
        .source = source,
        .syntax = .markup,
        .region = null,
    };
}
fn metrics(raw: typst.Metrics) DisplayList.Metrics {
    return .{ .width = raw.width, .height = raw.height, .baseline = raw.baseline };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1 and args.len != 3) {
        std.debug.print("usage: {s} [TYPST_LIBRARY OUTPUT.svg|OUTPUT.pdf]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const output = if (args.len == 3) args[2] else "target/huak-outlines.svg";
    const is_pdf = std.mem.endsWith(u8, output, ".pdf");
    if (!is_pdf and !std.mem.endsWith(u8, output, ".svg")) return error.InvalidOutputFormat;
    var library = try typst.Library.open(if (args.len == 3) args[1] else options.library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();
    var measured: [requests.len]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var frames: [measured.len]typst.FrameRef = undefined;
    for (&frames, 0..) |*frame, index| frame.* = try labels.frame(index);
    var batch = outlines.extract(allocator, &labels) catch |err| {
        var message = try library.lastError();
        defer message.deinit();
        std.debug.print("libtypst outlines: {s}\n", .{message.bytes()});
        return err;
    };
    defer batch.deinit();

    var picture = DisplayList.init(allocator);
    defer picture.deinit();
    const width = 680;
    const height = 390;
    var canvas = Path.init(allocator);
    defer canvas.deinit();
    try canvas.moveTo(.zero);
    try canvas.lineTo(.{ .x = width, .y = 0 });
    try canvas.lineTo(.{ .x = width, .y = height });
    try canvas.lineTo(.{ .x = 0, .y = height });
    try canvas.close();
    try picture.fill(canvas, .{ .r = 0.975, .g = 0.98, .b = 0.995 }, .{});
    try picture.labelAtBaseline(0, metrics(measured[0]), .{ .x = 34, .y = 345 }, .{});
    try picture.labelAtBaseline(4, metrics(measured[4]), .{ .x = 34, .y = 316 }, .{});

    const colors = [_]DisplayList.Color{
        .{ .r = 0.12, .g = 0.43, .b = 0.76 },
        .{ .r = 0.84, .g = 0.28, .b = 0.32 },
        .{ .r = 0.12, .g = 0.59, .b = 0.46 },
        .{ .r = 0.58, .g = 0.31, .b = 0.78 },
    };
    for (batch.labels[1].parts, 0..) |*part, index| {
        if (part.path.segmentCount() == 0) continue;
        // These are ordinary huak control points. No call back to Typst is
        // involved in editing or transforming the extracted glyph geometry.
        for (part.path.segments.items) |*segment| switch (segment.*) {
            .cubic => |*curve| {
                curve.c1.x += 2.5;
                curve.c2.y *= 1.08;
            },
            else => {},
        };
        const phase: f64 = @floatFromInt(index);
        try part.path.transform(g.Transform.scaling(1.12, 1.2 + 0.12 * @sin(phase)).then(g.Transform.rotation(0.07 * @sin(phase + 1))));
        part.style.fill = colors[index % colors.len];
        part.style.pen = .{ .color = .{ .r = 0.08, .g = 0.12, .b = 0.2, .a = 0.75 }, .width = 0.8, .join = .round };
        part.transform = part.transform.then(.{ .e = phase * 7, .f = 9 * @sin(phase * 1.3) });
    }
    try batch.labels[1].addToPicture(&picture, .{ .e = 40, .f = 210 });

    // Retain each formula part's fill/stroke choice and stroke width, including
    // fraction bars, while recolouring and shearing the editable geometry.
    const formula_color: DisplayList.Color = .{ .r = 0.12, .g = 0.3, .b = 0.52 };
    for (batch.labels[2].parts) |*part| {
        if (part.style.fill != null) part.style.fill = formula_color;
        if (part.style.pen) |*pen| pen.color = formula_color;
    }
    try batch.labels[2].addToPicture(&picture, .{ .c = 0.10, .e = 40, .f = 115 });
    try picture.labelAtBaseline(3, metrics(measured[3]), .{ .x = 34, .y = 42 }, .{});
    var document = try backend.submit(allocator, &library, &picture, width, height, .{ .frames = &frames });
    defer document.deinit();
    var bytes = if (is_pdf) try document.exportPdf() else try document.exportSvg(0);
    defer bytes.deinit();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = bytes.bytes() });
    std.debug.print("editable lettering: {d} labels, {d} bytes at {s}\n", .{ batch.labels.len, bytes.bytes().len, output });
}
