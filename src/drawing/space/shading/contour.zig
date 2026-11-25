//! Cutting cells where n·v vanishes, and keeping their front parts.
//!
//! A cell crossing the contour n·v = 0 splits along a diagonal, and each
//! half keeps its front part, cut where n·v vanishes on its edges, as a
//! patch with straight sides in the parameters. Patches sharing a side share
//! its samples and so its control points; skirts carry the light of contour
//! and face-boundary sides past the outline's tolerance and past the chords
//! an output may draw for them.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const lattice_nodes = @import("nodes.zig");
const Sheet = @import("Sheet.zig");
const Node = @import("Node.zig");
const Piece = Sheet.Piece;
const Corner = Sheet.Corner;
const Placed = Sheet.Placed;
const Error = space_shading.Error;
const ordered = lattice_nodes.ordered;
const on_bounds = Node.on_bounds;
const on_contour = Node.on_contour;

/// How closely a contour cut is placed, as a fraction of its side.
const root_tolerance = 1e-12;

/// The halves of a quad on either side of its diagonal from corner 0.
fn halves(quad: Piece) [2][3]Corner {
    return .{ .{ quad[0], quad[1], quad[2] }, .{ quad[0], quad[2], quad[3] } };
}

/// The front parts of quads, in order, after cutting the sides that cross
/// the contour.
pub fn frontPieces(self: *Sheet, quads: []const Placed, out: *std.ArrayList(Placed)) Error!void {
    var sides: std.ArrayList([2]u32) = .empty;
    for (quads) |quad| {
        const count = frontCount(self, quad.piece);
        if (count == 0 or count == 4) continue;
        for (halves(quad.piece)) |half| for (0..3) |k| {
            const p = half[k];
            const q = half[(k + 1) % 3];
            if (lattice_nodes.inFront(self, p) == lattice_nodes.inFront(self, q)) continue;
            const key = ordered(p.node, q.node);
            const entry = try self.cuts.getOrPut(self.allocator, key);
            if (entry.found_existing) continue;
            entry.value_ptr.* = undefined;
            try sides.append(self.allocator, key);
        };
    }
    try cut(self, sides.items);
    for (quads) |quad| try pieces(self, quad, out);
}

pub fn frontCount(self: *const Sheet, quad: Piece) usize {
    var count: usize = 0;
    for (quad) |corner| count += @intFromBool(lattice_nodes.inFront(self, corner));
    return count;
}

/// The point on each side where n·v vanishes, which OCCT finds along the
/// straight side in the parameters from its lower node, all sides in one
/// batch. A side is cut once and shared by both cells on it.
pub fn cut(self: *Sheet, sides: []const [2]u32) Error!void {
    if (sides.len == 0) return;
    const a = self.allocator;
    const segments = try a.alloc([2]g.Point, sides.len);
    for (sides, segments) |key, *segment| {
        const from = self.nodes.items[key[0]].uv;
        segment.* = .{ from, lattice_nodes.near(self, from, self.nodes.items[key[1]].uv) };
    }
    const found = try a.alloc(?f64, sides.len);
    try self.shading.surfaces.roots(a, self.face, segments, self.shading.eye, 0, root_tolerance, found);
    for (sides, segments, found) |key, segment, root| {
        const p = self.nodes.items[key[0]];
        const q = self.nodes.items[key[1]];
        // Without a root, as where the normal is undefined on the way,
        // interpolate the facing at the ends.
        const s = root orelse p.facing / (p.facing - q.facing);
        const place = (p.place & q.place & on_bounds) | on_contour;
        self.cuts.getPtr(key).?.* = try lattice_nodes.request(self, segment[0].add(segment[1].sub(segment[0]).scale(s)), place);
    }
    try lattice_nodes.flush(self);
}

/// The front parts of a quad: the whole quad, or, where it crosses the
/// contour, the front parts of the two halves on either side of a
/// diagonal.
pub fn pieces(self: *Sheet, quad: Placed, out: *std.ArrayList(Placed)) !void {
    switch (frontCount(self, quad.piece)) {
        0 => return,
        4 => return out.append(self.allocator, quad),
        else => {},
    }
    for (halves(quad.piece)) |half| {
        var ring: [4]Corner = undefined;
        var size: usize = 0;
        for (0..3) |k| {
            const p = half[k];
            const q = half[(k + 1) % 3];
            const inside = lattice_nodes.inFront(self, p);
            if (inside) {
                ring[size] = p;
                size += 1;
            }
            if (inside != lattice_nodes.inFront(self, q)) {
                ring[size] = .{ .node = self.cuts.get(ordered(p.node, q.node)).? };
                size += 1;
            }
        }
        switch (size) {
            3 => try out.append(self.allocator, .{ .cell = quad.cell, .group = quad.group, .piece = .{ ring[0], ring[1], ring[2], ring[2] } }),
            4 => try out.append(self.allocator, .{ .cell = quad.cell, .group = quad.group, .piece = ring }),
            else => {},
        }
    }
}
