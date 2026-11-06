//! A mesh paint becomes one imported PDF graphic at its original scene position.
const std = @import("std");
const c = @import("pdf_mesh_c");
const typst = @import("libtypst");
const g = @import("../../drawing/geometry.zig");
const Mesh = @import("../../drawing/style.zig").Gradient.Mesh;

pub fn encode(allocator: std.mem.Allocator, mesh: Mesh, clip: *const typst.c.TypstPath, evenodd: bool) !struct { buffer: c.HuakMeshBuffer, bounds: g.BBox } {
    if (mesh.vertices.len == 0) return error.InvalidStyle;
    var bounds: g.BBox = .{ .min = .{ .x = mesh.vertices[0].x, .y = mesh.vertices[0].y }, .max = .{ .x = mesh.vertices[0].x, .y = mesh.vertices[0].y } };
    for (mesh.vertices) |vertex| {
        bounds.min.x = @min(bounds.min.x, vertex.x);
        bounds.min.y = @min(bounds.min.y, vertex.y);
        bounds.max.x = @max(bounds.max.x, vertex.x);
        bounds.max.y = @max(bounds.max.y, vertex.y);
    }
    const segments = try allocator.alloc(c.HuakMeshClip, clip.segment_count);
    defer allocator.free(segments);
    for (segments, clip.segments[0..clip.segment_count]) |*dest, source| {
        dest.* = .{ .kind = switch (source.kind) {
            typst.c.TYPST_SEGMENT_MOVE => 0,
            typst.c.TYPST_SEGMENT_LINE => 1,
            typst.c.TYPST_SEGMENT_CUBIC => 2,
            typst.c.TYPST_SEGMENT_CLOSE => 3,
            else => return error.InvalidPath,
        }, .points = .{ source.p1.x, source.p1.y, source.p2.x, source.p2.y, source.p3.x, source.p3.y } };
    }
    comptime {
        std.debug.assert(@sizeOf(Mesh.Vertex) == @sizeOf(c.HuakMeshVertex));
        for (@typeInfo(Mesh.Vertex).@"struct".field_names) |field| std.debug.assert(@offsetOf(Mesh.Vertex, field) == @offsetOf(c.HuakMeshVertex, field));
    }
    var buffer: c.HuakMeshBuffer = .{ .data = null, .len = 0, .capacity = 0 };
    const status = c.huak_mesh_pdf(&.{
        .vertices = @ptrCast(mesh.vertices.ptr),
        .vertex_count = mesh.vertices.len,
        .triangles = @ptrCast(mesh.triangles.ptr),
        .triangle_count = mesh.triangles.len,
        .clip = segments.ptr,
        .clip_count = segments.len,
        .bounds = .{ bounds.min.x, bounds.min.y, bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y },
        .evenodd = evenodd,
    }, &buffer);
    if (status != 0) return error.MeshEncodingFailed;
    return .{ .buffer = buffer, .bounds = bounds };
}

pub const release = c.huak_mesh_pdf_free;
