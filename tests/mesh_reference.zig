//! Replay the original lighting fixture through the real scene/PDF backend.
//! The fixture stores little-endian f64 geometry and RGB, never PDF bytes.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const DisplayList = huak.core.DisplayList;
const Vertex = DisplayList.Gradient.Mesh.Vertex;
const options = @import("host_options");

/// Vertex indices hashed by the vertex they name, so the set stores only
/// indices. Lookups compare a candidate's bits with the stored vertex.
const Corners = struct {
    vertices: []const Vertex,

    pub fn hash(self: Corners, index: u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.vertices[index]));
    }
    pub fn eql(_: Corners, a: u32, b: u32) bool {
        return a == b;
    }

    const Candidate = struct {
        vertices: []const Vertex,

        pub fn hash(_: Candidate, vertex: Vertex) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&vertex));
        }
        pub fn eql(self: Candidate, vertex: Vertex, index: u32) bool {
            return std.mem.eql(u8, std.mem.asBytes(&vertex), std.mem.asBytes(&self.vertices[index]));
        }
    };
};

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
        // The fixture stores every triangle corner. Equal corners become one
        // vertex, as a mesh producer emits them; the encoded records are the
        // same, since the encoder still writes one record per corner.
        var vertices: std.ArrayList(Vertex) = .empty;
        defer vertices.deinit(init.gpa);
        var corners: std.HashMapUnmanaged(u32, void, Corners, std.hash_map.default_max_load_percentage) = .empty;
        defer corners.deinit(init.gpa);
        // Each corner adds at most one vertex, so the set never rehashes.
        try corners.ensureTotalCapacityContext(init.gpa, std.math.cast(u32, vertex_count) orelse return error.InvalidFixture, .{ .vertices = &.{} });
        const triangles = try init.gpa.alloc([3]u32, vertex_count / 3);
        defer init.gpa.free(triangles);
        for (0..vertex_count) |corner| {
            const vertex: Vertex = .{ .x = try number(&input), .y = height - try number(&input), .r = try number(&input), .g = try number(&input), .b = try number(&input) };
            const slot = corners.getOrPutAssumeCapacityAdapted(vertex, Corners.Candidate{ .vertices = vertices.items });
            if (!slot.found_existing) {
                slot.key_ptr.* = @intCast(vertices.items.len);
                try vertices.append(init.gpa, vertex);
            }
            triangles[corner / 3][corner % 3] = slot.key_ptr.*;
        }
        try picture.addPath(boundary, .{ .fill = .black, .gradient = &.{ .mesh_fill = .{ .vertices = vertices.items, .triangles = triangles } } }, .{});
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
