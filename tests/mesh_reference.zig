//! Replay the original lighting fixture through the real scene/PDF backend.
//! The fixture stores little-endian f64 geometry and RGB, never PDF bytes.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const DisplayList = huak.core.DisplayList;
const options = @import("host_options");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedMeshFixtureAndOutputPdf;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(256 * 1024 * 1024));
    defer init.gpa.free(data);
    var input = std.Io.Reader.fixed(data);
    const width = try number(&input);
    const height = try number(&input);
    const count = try input.takeInt(u64, .little);
    var picture = DisplayList.init(init.gpa);
    defer picture.deinit();
    for (0..@intCast(count)) |_| {
        const commands: usize = @intCast(try input.takeInt(u64, .little));
        const vertex_count: usize = @intCast(try input.takeInt(u64, .little));
        if (vertex_count % 3 != 0) return error.InvalidFixture;
        var boundary = huak.core.Path.init(init.gpa);
        defer boundary.deinit();
        for (0..commands) |_| {
            const kind = try input.takeInt(u32, .little);
            var points: [3]huak.core.geometry.Point = undefined;
            for (&points) |*point| point.* = .{ .x = try number(&input), .y = height - try number(&input) };
            switch (kind) {
                0 => try boundary.moveTo(points[0]),
                1 => try boundary.lineTo(points[0]),
                2 => try boundary.cubicTo(points[0], points[1], points[2]),
                3 => try boundary.close(),
                else => return error.InvalidFixture,
            }
        }
        const vertices = try init.gpa.alloc(DisplayList.Gradient.Mesh.Vertex, vertex_count);
        defer init.gpa.free(vertices);
        for (vertices) |*vertex| vertex.* = .{ .x = try number(&input), .y = height - try number(&input), .r = try number(&input), .g = try number(&input), .b = try number(&input) };
        const triangles = try init.gpa.alloc([3]u32, vertex_count / 3);
        defer init.gpa.free(triangles);
        for (triangles, 0..) |*triangle, index| triangle.* = .{ @intCast(index * 3), @intCast(index * 3 + 1), @intCast(index * 3 + 2) };
        try picture.addPath(boundary, .{ .fill = .black, .gradient = &.{ .mesh_fill = .{ .vertices = vertices, .triangles = triangles } } }, .{});
    }
    if (input.buffered().len != 0) return error.TrailingFixtureData;
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    var document = try huak.backend.submit(init.gpa, &library, &picture, width, height, .{ .pdf_mesh = true });
    defer document.deinit();
    var pdf = document.exportPdf() catch |err| {
        var diagnostic = try library.lastError();
        defer diagnostic.deinit();
        std.debug.print("{s}\n", .{diagnostic.bytes()});
        return err;
    };
    defer pdf.deinit();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = pdf.bytes() });
    std.debug.print("{d} mesh objects, {d} PDF bytes: {s}\n", .{ count, pdf.bytes().len, args[2] });
}

fn number(input: *std.Io.Reader) !f64 {
    return @bitCast(try input.takeInt(u64, .little));
}
