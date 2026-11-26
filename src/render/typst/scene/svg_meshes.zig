//! Mesh paints as SVG triangles with linear gradients, in one labeled group clipped to the path.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const Workers = @import("workers");
const g = @import("../../../drawing/geometry.zig");
const DisplayList = @import("../../../drawing/DisplayList.zig");
const Gradient = @import("../../../drawing/style.zig").Gradient;
const Path = @import("../../../drawing/path/Path.zig");
const svg_mesh = @import("../../svg/mesh.zig");
const patch_mesh = @import("../../../drawing/patches.zig");
const fan_mesh = @import("../../../drawing/conic.zig");
const field = @import("../../../drawing/field.zig");
const color_patches = @import("../../../drawing/color_patches.zig");
/// Triangles one patch paint may become for SVG, before and after its
/// cuts at the stop levels: the bound on other generated geometry.
const geometry_limit = @import("../../../drawing/outline.zig").max_items;
const region = @import("../../../drawing/region/root.zig");
const typst_scene = @import("../scene.zig");
const native_records = @import("native.zig");
const paint_routes = @import("paint.zig");
const Builder = typst_scene.Builder;
const Painted = paint_routes.Painted;
const pointOf = native_records.pointOf;
const controlBounds = paint_routes.controlBounds;
const pathSegment = native_records.pathSegment;
const nativeTransform = native_records.nativeTransform;

fn buildOutline(scratch: std.mem.Allocator, path_: *const c.TypstPath, margin: f64) !?patch_mesh.Outline {
    if (!(margin > 0)) return null;
    const segments = try scratch.alloc(Path.Segment, path_.segment_count);
    defer scratch.free(segments);
    for (path_.segments[0..path_.segment_count], segments) |segment, *out| out.* = switch (segment.kind) {
        c.TYPST_SEGMENT_MOVE => .{ .move = pointOf(segment.p1) },
        c.TYPST_SEGMENT_LINE => .{ .line = pointOf(segment.p1) },
        c.TYPST_SEGMENT_CUBIC => .{ .cubic = .{ .c1 = pointOf(segment.p1), .c2 = pointOf(segment.p2), .end = pointOf(segment.p3) } },
        c.TYPST_SEGMENT_CLOSE => .close,
        else => return error.InvalidPath,
    };
    return try patch_mesh.Outline.init(scratch, segments, margin);
}

/// SVG has no patch shading: the field is triangulated within the paint's
/// tolerance, outside the margin along the filled outline, and each
/// triangle cut along the stop levels so that its colors stay linear.
pub fn svgPatches(self: *Builder, path_: *const c.TypstPath, evenodd: bool, all: Gradient.Patches, transform: g.Transform, id: u64) !void {
    const scratch = self.arena.child_allocator;
    var shown = try Painted.of(scratch, all) orelse return;
    defer shown.deinit(scratch);
    const patches = shown.patches;
    var band = try buildOutline(scratch, path_, patches.margin);
    defer if (band) |*outline| outline.deinit(scratch);
    const triangulated = try patch_mesh.triangulate(scratch, patches.points, patches.values, .{
        .tolerance = patches.tolerance,
        .free = if (band) |*outline| outline else null,
        .max_triangles = geometry_limit,
    });
    defer triangulated.deinit(scratch);
    const colored = try field.colorMesh(scratch, triangulated.points, triangulated.values, triangulated.triangles, patches.stops, geometry_limit);
    defer colored.deinit(scratch);
    try svgTriangles(self, path_, evenodd, colored, transform, id);
}

/// SVG has no conic shading: the fan becomes triangles within the
/// paint's tolerance, each cut along the stop levels like a patch's.
pub fn svgFan(self: *Builder, path_: *const c.TypstPath, evenodd: bool, conic: Gradient.Conic, transform: g.Transform, id: u64) !void {
    const scratch = self.arena.child_allocator;
    const triangulated = try fan_mesh.triangulate(scratch, conic, try controlBounds(path_), geometry_limit);
    defer triangulated.deinit(scratch);
    const colored = try field.colorMesh(scratch, triangulated.points, triangulated.values, triangulated.triangles, conic.stops, geometry_limit);
    defer colored.deinit(scratch);
    try svgTriangles(self, path_, evenodd, colored, transform, id);
}

fn triangulateColorPieces(
    allocator: std.mem.Allocator,
    pieces: []const color_patches.scalar.Lined,
    free: ?*const patch_mesh.Outline,
    vertices: *std.ArrayList(field.Vertex),
    triangles: *std.ArrayList([3]u32),
) patch_mesh.Error!void {
    try vertices.ensureUnusedCapacity(allocator, pieces.len * 4);
    try triangles.ensureUnusedCapacity(allocator, pieces.len * 2);
    var workspace_arena: std.heap.ArenaAllocator = .init(allocator);
    defer workspace_arena.deinit();
    var workspace = patch_mesh.Workspace.init(workspace_arena.allocator());
    defer workspace.deinit();
    for (pieces) |*piece| {
        const line: Gradient.Stops = .{ .levels = &.{ 0, 1 }, .colors = &piece.line };
        // The field goes from 0 to 1 along the line, so its error weighs
        // the line's largest change of a channel.
        const span = piece.line[0].maxDiff(piece.line[1]);
        const mesh = try workspace.triangulate(&.{piece.net}, &.{piece.values}, .{
            .tolerance = if (span > 0) DisplayList.Color.tolerance / span else 1,
            .free = free,
            .max_triangles = geometry_limit,
        });
        if (triangles.items.len + mesh.triangles.len > geometry_limit) return error.GeometryWorkLimit;
        const base: u32 = @intCast(vertices.items.len);
        try vertices.ensureUnusedCapacity(allocator, mesh.points.len);
        for (mesh.points, mesh.values) |point, value| vertices.appendAssumeCapacity(.{ .point = point, .color = line.at(value) });
        try triangles.ensureUnusedCapacity(allocator, mesh.triangles.len);
        for (mesh.triangles) |corners| triangles.appendAssumeCapacity(.{ corners[0] + base, corners[1] + base, corners[2] + base });
    }
}

/// SVG has no mesh shading: the patches split into pieces whose colors
/// lie along lines (color_patches/scalar.zig), each piece is triangulated as a
/// field along its line, and the triangles take the line's colors.
pub fn svgColors(self: *Builder, path_: *const c.TypstPath, evenodd: bool, patches: Gradient.ColorPatches, transform: g.Transform, id: u64) !void {
    const scratch = self.arena.child_allocator;
    const pieces = try color_patches.scalar.lines(scratch, patches, DisplayList.Color.tolerance, geometry_limit);
    defer scratch.free(pieces);
    var band = try buildOutline(scratch, path_, patches.margin);
    defer if (band) |*outline| outline.deinit(scratch);
    const free: ?*const patch_mesh.Outline = if (band) |*outline| outline else null;
    var vertices: std.ArrayList(field.Vertex) = .empty;
    defer vertices.deinit(scratch);
    var triangles: std.ArrayList([3]u32) = .empty;
    defer triangles.deinit(scratch);
    const min_parallel_chunk = 256;
    const max_chunks = 32;
    const chunk_count = self.workers.chunkCount(pieces.len, min_parallel_chunk, max_chunks);
    if (chunk_count > 1) {
        const Chunk = struct {
            vertices: std.ArrayList(field.Vertex) = .empty,
            triangles: std.ArrayList([3]u32) = .empty,
            err: ?patch_mesh.Error = null,
        };
        const Shared = struct {
            chunks: []Chunk,
            pieces: []const color_patches.scalar.Lined,
            free: ?*const patch_mesh.Outline,

            fn one(shared: *@This(), index: usize) bool {
                const chunk = &shared.chunks[index];
                const range = Workers.chunkRange(shared.pieces.len, shared.chunks.len, index);
                triangulateColorPieces(std.heap.page_allocator, shared.pieces[range.start..range.end], shared.free, &chunk.vertices, &chunk.triangles) catch |e| {
                    chunk.err = e;
                    return false;
                };
                return true;
            }
        };
        var chunks: [max_chunks]Chunk = undefined;
        @memset(chunks[0..chunk_count], .{});
        defer for (chunks[0..chunk_count]) |*chunk| {
            chunk.vertices.deinit(std.heap.page_allocator);
            chunk.triangles.deinit(std.heap.page_allocator);
        };
        var shared: Shared = .{ .chunks = chunks[0..chunk_count], .pieces = pieces, .free = free };
        try self.workers.run(chunk_count, &shared, Shared.one);
        var total_v: usize = 0;
        var total_t: usize = 0;
        for (chunks[0..chunk_count]) |*chunk| {
            if (chunk.err) |e| return e;
            total_v += chunk.vertices.items.len;
            total_t += chunk.triangles.items.len;
            if (total_t > geometry_limit) return error.GeometryWorkLimit;
        }
        try vertices.ensureTotalCapacity(scratch, total_v);
        try triangles.ensureTotalCapacity(scratch, total_t);
        for (chunks[0..chunk_count]) |*chunk| {
            const base: u32 = @intCast(vertices.items.len);
            vertices.appendSliceAssumeCapacity(chunk.vertices.items);
            for (chunk.triangles.items) |corners| triangles.appendAssumeCapacity(.{ corners[0] + base, corners[1] + base, corners[2] + base });
        }
    } else {
        try triangulateColorPieces(scratch, pieces, free, &vertices, &triangles);
    }
    try svgTriangles(self, path_, evenodd, .{ .vertices = vertices.items, .triangles = triangles.items }, transform, id);
}

/// SVG has no mesh shading: each triangle becomes a path with its own
/// linear gradient (svg/mesh.zig), in one labeled group clipped to the
/// paint's path.
pub fn svgTriangles(self: *Builder, path_: *const c.TypstPath, evenodd: bool, mesh: field.Colored, transform: g.Transform, id: u64) !void {
    const memory = self.arena.allocator();
    // Temporary C records for the triangles are consumed synchronously by
    // `childScene` below; keep them on a function-local arena so they do not
    // stay pinned in the document builder's arena.
    var local: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
    defer local.deinit();
    const scratch = local.allocator();
    const outlines = try scratch.alloc(c.TypstPathSegment, mesh.triangles.len * 4);
    const items = try scratch.alloc(c.TypstSceneItem, mesh.triangles.len);
    // A gradient paints a filled path; its own color is unused.
    const shaded = try native_records.styleIn(scratch, &.{ .fill = .{ .color = .black } });
    // Opaque meshes overlap their triangles by a fraction of the page,
    // converted to the mesh's own units.
    const opaque_mesh = for (mesh.vertices) |vertex| {
        if (vertex.color.a != 1) break false;
    } else true;
    var placement = transform;
    var level = self.levels.items.len;
    while (level > 0) {
        level -= 1;
        placement = placement.then(self.levels.items[level].transform);
    }
    const scale = @sqrt(@abs(placement.a * placement.d - placement.b * placement.c));
    const distance = if (opaque_mesh and scale > 0) svg_mesh.overlap * @max(self.size.x, self.size.y) / scale else 0;
    var count: usize = 0;
    for (mesh.triangles) |indices| {
        var points: [3]g.Point = undefined;
        var colors: [3]DisplayList.Color = undefined;
        for (indices, &points, &colors) |index, *point, *color| {
            point.* = mesh.vertices[index].point;
            color.* = mesh.vertices[index].color;
        }
        // Each piece's colors lie in one stop band, so on one line.
        const triangle_paint = svg_mesh.triangle(points, colors) orelse unreachable;
        if (triangle_paint == .none) continue;
        const corners = svg_mesh.expanded(points, distance);
        const outline = outlines[count * 4 ..][0..4];
        outline.* = .{ pathSegment(.{ .move = corners[0] }), pathSegment(.{ .line = corners[1] }), pathSegment(.{ .line = corners[2] }), pathSegment(.close) };
        var raw = switch (triangle_paint) {
            .none => unreachable,
            .flat => |color| flat: {
                var result = try native_records.itemIn(self, scratch, .{}, null, 0, null);
                result.style = try native_records.styleIn(scratch, &.{ .fill = .{ .color = color } });
                break :flat result;
            },
            .linear => |linear| ramp: {
                const gradient: Gradient = .{ .linear = .{ .start = linear.start, .end = linear.end, .colors = &linear.colors } };
                var result = try native_records.itemIn(self, scratch, .{}, null, 0, &.{ .fill = .{ .gradient = &gradient } });
                result.style = shaded;
                break :ramp result;
            },
        };
        raw.kind = c.TYPST_ITEM_PATH;
        raw.path = try native_records.pathDataIn(scratch, outline);
        items[count] = raw;
        count += 1;
    }
    const options = try memory.create(c.TypstSceneItemOptions);
    options.* = std.mem.zeroes(c.TypstSceneItemOptions);
    options.struct_size = @sizeOf(c.TypstSceneItemOptions);
    options.tag = .{ .data = svg_mesh.label.ptr, .len = svg_mesh.label.len };
    var mesh_group = std.mem.zeroes(c.TypstSceneItem);
    mesh_group.kind = c.TYPST_ITEM_SCENE;
    mesh_group.scene = try native_records.childScene(self, items[0..count]);
    mesh_group.clip = if (evenodd) try nonzeroClip(self, path_) else path_;
    mesh_group.options = options;
    if (id == 0) {
        mesh_group.transform = nativeTransform(transform);
        return self.append(mesh_group);
    }
    mesh_group.transform = nativeTransform(.{});
    var outer = try native_records.item(self, transform, null, id, null);
    outer.kind = c.TYPST_ITEM_SCENE;
    outer.scene = try native_records.childScene(self, &.{mesh_group});
    try self.append(outer);
}

/// Typst clips with the nonzero rule. The region union of an even-odd
/// path is a nonzero path covering the same area.
pub fn nonzeroClip(self: *Builder, path_: *const c.TypstPath) !*const c.TypstPath {
    const scratch = self.arena.child_allocator;
    var source = Path.init(scratch);
    defer source.deinit();
    for (path_.segments[0..path_.segment_count]) |segment| switch (segment.kind) {
        c.TYPST_SEGMENT_MOVE => try source.moveTo(pointOf(segment.p1)),
        c.TYPST_SEGMENT_LINE => try source.lineTo(pointOf(segment.p1)),
        c.TYPST_SEGMENT_CUBIC => try source.cubicTo(pointOf(segment.p1), pointOf(segment.p2), pointOf(segment.p3)),
        c.TYPST_SEGMENT_CLOSE => try source.close(),
        else => return error.InvalidPath,
    };
    var empty = Path.init(scratch);
    defer empty.deinit();
    var normalized = try region.combine(scratch, source, empty, .unite, .{ .fill_rule = .evenodd });
    defer normalized.deinit();
    const data = try self.arena.allocator().alloc(c.TypstPathSegment, normalized.segments.items.len);
    for (normalized.segments.items, data) |segment, *out| out.* = pathSegment(segment);
    return native_records.pathData(self, data);
}
