//! Lattice nodes asked for where a step needs them, and evaluated in one batch.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Sheet = @import("Sheet.zig");
const Error = space_shading.Error;
const Look = space_shading.Look;
const dot = space_shading.dot;
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

/// Evaluates the requested nodes, with the script's field. Where the normal
/// is undefined, such as at a cone's apex, the facing that decides which
/// side of the contour a node lies on is the mean over points a little way
/// into the face in each parameter direction.
pub fn flush(self: *Sheet) Error!void {
    const a = self.allocator;
    const fresh = self.nodes.items[self.pending..];
    if (fresh.len == 0) return;
    self.pending = self.nodes.items.len;
    const uv = try a.alloc(g.Point, fresh.len);
    for (uv, fresh) |*position, n| position.* = n.uv;
    const points = try a.alloc(Look, fresh.len);
    try self.shading.surfaces.look(a, self.face, uv, points);
    var probes: std.ArrayList(g.Point) = .empty;
    var owners: std.ArrayList(usize) = .empty;
    const du = (self.u[1] - self.u[0]) / @as(f64, @floatFromInt(self.nu)) * 1e-3;
    const dv = (self.v[1] - self.v[0]) / @as(f64, @floatFromInt(self.nv)) * 1e-3;
    for (fresh, points, 0..) |*n, point, index| {
        n.* = self.shading.node(n.uv, point, n.place);
        if (!n.singular) continue;
        const before = probes.items.len;
        for ([_]g.Point{ .{ .x = du, .y = 0 }, .{ .x = -du, .y = 0 }, .{ .x = 0, .y = dv }, .{ .x = 0, .y = -dv } }) |step| {
            const probe = n.uv.add(step);
            if ((self.period[0] == 0 and (probe.x < self.u[0] or probe.x > self.u[1])) or
                (self.period[1] == 0 and (probe.y < self.v[0] or probe.y > self.v[1]))) continue;
            try probes.append(a, probe);
            try owners.append(a, index);
        }
        if (probes.items.len == before) return error.UndefinedNormal;
    }
    const nearby = try a.alloc(Look, probes.items.len);
    try self.shading.surfaces.look(a, self.face, probes.items, nearby);
    var k: usize = 0;
    while (k < owners.items.len) {
        const owner = owners.items[k];
        var facing: f64 = 0;
        var count: f64 = 0;
        while (k < owners.items.len and owners.items[k] == owner) : (k += 1) {
            const normal = nearby[k].normal orelse continue;
            facing += dot(normal, self.shading.eye);
            count += 1;
        }
        if (count == 0) return error.UndefinedNormal;
        fresh[owner].facing = facing / count;
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
            .x = self.u[0] + (self.u[1] - self.u[0]) * @as(f64, @floatFromInt(wi)) / @as(f64, @floatFromInt(self.nu)),
            .y = self.v[0] + (self.v[1] - self.v[0]) * @as(f64, @floatFromInt(wj)) / @as(f64, @floatFromInt(self.nv)),
        }, place);
    }
    return .{ .node = entry.value_ptr.*, .i = i, .j = j, .lattice = true };
}

/// The lattice quad with corner (i, j) and sides of `size` steps.
pub fn square(self: *Sheet, i: i64, j: i64, size: i64) !Piece {
    return .{ try at(self, i, j), try at(self, i + size, j), try at(self, i + size, j + size), try at(self, i, j + size) };
}
