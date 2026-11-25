//! Routing a path's paint: a native item with its gradient, or the PDF or SVG mesh route; and the control bounds both routes share.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const g = @import("../../../drawing/geometry.zig");
const Gradient = @import("../../../drawing/style.zig").Gradient;
const DisplayList = @import("../../../drawing/DisplayList.zig");
const typst_scene = @import("../scene.zig");
const pdf_graphics = @import("pdf_graphics.zig");
const svg_meshes = @import("svg_meshes.zig");
const native_records = @import("native.zig");
const Builder = typst_scene.Builder;
const pointOf = native_records.pointOf;

/// Paints a path with its fill and stroke: a mesh fill by the PDF or SVG
/// mesh route, with the stroke after it, and everything else as one native
/// item, each component with its own gradient. A stroke painted with a mesh
/// never comes here: it is drawn as its footprint (see `Pen.resolvesStroke`).
pub fn paint(self: *Builder, path_: *const c.TypstPath, style_: *const DisplayList.Style, transform: g.Transform, id: u64) !void {
    if (style_.gradientFor(.fill)) |value| if (value.isMesh()) {
        const evenodd = style_.fill_rule == .evenodd;
        switch (value.*) {
            .patches => |patches| if (self.pdf)
                try pdf_graphics.pdfPatches(self, path_, evenodd, patches, transform, id)
            else
                try svg_meshes.svgPatches(self, path_, evenodd, patches, transform, id),
            .fan => |conic| if (self.pdf)
                try pdf_graphics.pdfFan(self, path_, evenodd, conic, transform, id)
            else
                try svg_meshes.svgFan(self, path_, evenodd, conic, transform, id),
            .color_patches => |patches| if (self.pdf)
                try pdf_graphics.pdfColors(self, path_, evenodd, patches, transform, id)
            else
                try svg_meshes.svgColors(self, path_, evenodd, patches, transform, id),
            .linear, .radial => unreachable,
        }
        if (style_.pen) |pen| try paint(self, path_, &.{ .pen = pen }, transform, 0);
        return;
    };
    var raw = try native_records.item(self, transform, null, id, style_);
    raw.kind = c.TYPST_ITEM_PATH;
    raw.path = path_;
    raw.style = try native_records.style(self, style_);
    try self.append(raw);
}

/// The patches of a paint that paint any color: those where its stops are
/// transparent across the field are left out, into arrays of their own.
pub const Painted = struct {
    patches: Gradient.Patches,
    owned: bool = false,

    /// Null when no patch paints.
    pub fn of(allocator: std.mem.Allocator, patches: Gradient.Patches) !?Painted {
        var count: usize = 0;
        for (patches.values) |*values| count += @intFromBool(patches.stops.paints(values));
        if (count == 0) return null;
        if (count == patches.values.len) return .{ .patches = patches };
        const points = try allocator.alloc([16]g.Point, count);
        errdefer allocator.free(points);
        const values = try allocator.alloc([16]f64, count);
        var next: usize = 0;
        for (patches.points, patches.values) |*net, *coefficients| if (patches.stops.paints(coefficients)) {
            points[next] = net.*;
            values[next] = coefficients.*;
            next += 1;
        };
        var result = patches;
        result.points = points;
        result.values = values;
        result.shared = null;
        return .{ .patches = result, .owned = true };
    }

    pub fn deinit(self: Painted, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.patches.points);
        allocator.free(self.patches.values);
    }
};

/// The extent of a path's control points, which holds its curves.
pub fn controlBounds(path_: *const c.TypstPath) !g.BBox {
    var box: ?g.BBox = null;
    for (path_.segments[0..path_.segment_count]) |segment| {
        const count: usize = switch (segment.kind) {
            c.TYPST_SEGMENT_MOVE, c.TYPST_SEGMENT_LINE => 1,
            c.TYPST_SEGMENT_CUBIC => 3,
            c.TYPST_SEGMENT_CLOSE => 0,
            else => return error.InvalidPath,
        };
        const controls = [3]c.TypstPoint{ segment.p1, segment.p2, segment.p3 };
        for (controls[0..count]) |control| {
            const point = pointOf(control);
            box = if (box) |found| found.include(point) else .fromPoint(point);
        }
    }
    return box orelse error.InvalidPath;
}
