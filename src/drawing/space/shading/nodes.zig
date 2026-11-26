//! Lattice nodes asked for where a step needs them, and evaluated in one batch.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Sheet = @import("Sheet.zig");
const Error = space_shading.Error;
const Look = space_shading.Look;
const Corner = Sheet.Corner;
const Piece = Sheet.Piece;

pub fn ordered(a: u32, b: u32) [2]u32 {
    return .{ @min(a, b), @max(a, b) };
}

/// Requests a node at `uv`, evaluated by the next `flush`.
pub fn request(self: *Sheet, uv: g.Point, place: u8) !u32 {
    const id: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .uv = uv, .place = place });
    return id;
}

/// Evaluates the requested nodes, with the script's field. OCCT's
/// `CSLib::Normal` resolves singular poles and cone apices directly; if a
/// normal is still undefined, returns `UndefinedNormal`.
pub fn flush(self: *Sheet) Error!void {
    const a = self.allocator;
    const fresh = self.nodes.items[self.pending..];
    if (fresh.len == 0) return;
    self.pending = self.nodes.items.len;
    const uv = try a.alloc(g.Point, fresh.len);
    for (uv, fresh) |*position, n| position.* = n.uv;
    const points = try a.alloc(Look, fresh.len);
    try self.shading.surfaces.look(a, self.face, uv, points);
    for (fresh, points) |*n, point| {
        n.* = self.shading.node(n.uv, point, n.place);
        if (n.singular) return error.UndefinedNormal;
    }
    try self.shading.sample(a, fresh);
}

pub fn inFront(self: *const Sheet, corner: Corner) bool {
    return self.nodes.items[corner.node].facing > 0;
}

/// `to` moved by whole periods to lie nearest `from`.
pub fn near(self: *const Sheet, from: g.Point, to: g.Point) g.Point {
    var result = to;
    if (self.period[0] > 0) result.x = to.x - self.period[0] * @round((to.x - from.x) / self.period[0]);
    if (self.period[1] > 0) result.y = to.y - self.period[1] * @round((to.y - from.y) / self.period[1]);
    return result;
}

/// The lattice corner (i, j).
pub fn at(self: *Sheet, i: i64, j: i64) !Corner {
    const wi = if (self.period[0] > 0) @mod(i, self.nu) else i;
    const wj = if (self.period[1] > 0) @mod(j, self.nv) else j;
    const entry = try self.lattice.getOrPut(self.allocator, .{ wi, wj });
    if (!entry.found_existing) {
        var place: u8 = 0;
        if (self.period[0] == 0) place |= @as(u8, if (wi == 0) 2 else 0) | @as(u8, if (wi == self.nu) 4 else 0);
        if (self.period[1] == 0) place |= @as(u8, if (wj == 0) 8 else 0) | @as(u8, if (wj == self.nv) 16 else 0);
        entry.value_ptr.* = try request(self, .{
            .x = self.parameter(0, wi),
            .y = self.parameter(1, wj),
        }, place);
    }
    return .{ .node = entry.value_ptr.*, .i = i, .j = j, .lattice = true };
}

/// The lattice quad with corner (i, j) and sides of `size` steps.
pub fn square(self: *Sheet, i: i64, j: i64, size: i64) !Piece {
    return .{ try at(self, i, j), try at(self, i + size, j), try at(self, i + size, j + size), try at(self, i, j + size) };
}
