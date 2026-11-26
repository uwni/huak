//! A face's sheet: curvature-graded cells in its parameters (`grid.zig`),
//! fold-only cutting along n·v = 0 (`contour.zig`), patch construction with
//! exact camera depth (`patches.zig`), and fast-path or Newell (1972)
//! far-to-near depth-ordered emission (`depth_order.zig`).
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const lattice_nodes = @import("nodes.zig");
const contour = @import("contour.zig");
const patches = @import("patches.zig");
const grid = @import("grid.zig");
const depth_order = @import("depth_order.zig");
const Node = @import("Node.zig");
const Sheet = @This();
const Shading = space_shading.Shading;
const Face = space_shading.Face;
const Info = space_shading.Info;
const Error = space_shading.Error;
const Patch = space_shading.Patch;
const DepthPatch = patches.DepthPatch;
const SkirtPatch = patches.SkirtPatch;
const Output = space_shading.Output;
const Field = space_shading.Field;
const max_steps = space_shading.max_steps;
const side_ends = patches.side_ends;
const on_contour = Node.on_contour;
const on_bounds = Node.on_bounds;
const skirt = patches.skirt;

shading: *const Shading,
/// An arena that holds everything the sheet makes.
allocator: std.mem.Allocator,
face: Face,
u: [2]f64,
v: [2]f64,
/// The period of a parameter around which the face closes, or zero.
period: [2]f64,
/// Curvature-graded cell edges along u and v: cu + 1 and cv + 1 of them.
edges: [2][]const f64,
cu: usize,
cv: usize,
/// Normal turn across a cell, and lattice steps per cell side.
turn: f64,
m: i64,
n: i64,
nu: i64,
nv: i64,
nodes: std.ArrayList(Node) = .empty,
/// Nodes from this index on await evaluation.
pending: usize = 0,
lattice: std.AutoHashMapUnmanaged([2]i64, u32) = .empty,
/// The node where n·v vanishes on a side, and the nodes a third and two
/// thirds of the way along a side, keyed by the side's ordered nodes.
cuts: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
thirds: std.AutoHashMapUnmanaged([2]u32, [2]u32) = .empty,
/// Index j * cu + i.
cells: []Cell,
/// Flat per-sheet patch link nodes and skirts, avoiding per-cell ArrayLists and
/// DepthPatch value copies.
patch_nodes: std.ArrayList(PatchNode) = .empty,
skirts: std.ArrayList(SkirtPatch) = .empty,

pub fn init(shading: *const Shading, allocator: std.mem.Allocator, face: Face, info: Info) Error!Sheet {
    var period: [2]f64 = .{ 0, 0 };
    const span: [2]f64 = .{ info.u[1] - info.u[0], info.v[1] - info.v[0] };
    for (&period, [2]f64{ info.u_period, info.v_period }, span) |*wrap, length, extent| {
        if (length > 0 and @abs(extent - length) <= 1e-9 * length) wrap.* = length;
    }
    const size = @sqrt(4 * shading.accuracy);
    const cells_ = try grid.grid(shading, allocator, face, info, period, size, shading.budget);
    const turn = @max(cells_.turn[0], cells_.turn[1]);
    var m: i64 = 1;
    if (shading.half != null) {
        const steps = @ceil(turn / @sqrt(4 * shading.accuracy * (1 - shading.cutoff)));
        if (!(steps <= max_steps)) return error.ShadingLimit;
        m = @max(1, @as(i64, @intFromFloat(steps)));
    }
    const n = 3 * m * (@as(i64, 1) << space_shading.field_levels);
    const cu = cells_.edges[0].len - 1;
    const cv = cells_.edges[1].len - 1;
    const cells = try allocator.alloc(Cell, cu * cv);
    @memset(cells, .{});
    return .{
        .shading = shading,
        .allocator = allocator,
        .face = face,
        .u = info.u,
        .v = info.v,
        .period = period,
        .edges = cells_.edges,
        .cu = cu,
        .cv = cv,
        .turn = turn,
        .m = m,
        .n = n,
        .nu = @as(i64, @intCast(cu)) * n,
        .nv = @as(i64, @intCast(cv)) * n,
        .cells = cells,
    };
}

/// The parameter at lattice step `w` along u (axis 0) or v (axis 1), from 0
/// to nu or nv: linear within each curvature-graded cell.
pub fn parameter(self: *const Sheet, axis: usize, w: i64) f64 {
    std.debug.assert(w >= 0);
    const edges = self.edges[axis];
    const cell = @divFloor(w, self.n);
    if (cell >= edges.len - 1) return edges[edges.len - 1];
    const at: usize = @intCast(cell);
    const step: f64 = @floatFromInt(w - cell * self.n);
    return edges[at] + (edges[at + 1] - edges[at]) * step / @as(f64, @floatFromInt(self.n));
}

/// The cell at (i, j), wrapping around periodic parameters; null outside.
pub fn cellAt(self: *const Sheet, i: i64, j: i64) ?usize {
    const cu: i64 = @intCast(self.cu);
    const cv: i64 = @intCast(self.cv);
    const ci = if (self.period[0] > 0) @mod(i, cu) else i;
    const cj = if (self.period[1] > 0) @mod(j, cv) else j;
    if (ci < 0 or ci >= cu or cj < 0 or cj >= cv) return null;
    return @intCast(cj * cu + ci);
}

pub fn build(self: *Sheet) Error!void {
    const a = self.allocator;
    const quads = try a.alloc(Placed, self.cells.len);
    for (quads, 0..) |*quad, index| {
        const i: i64 = @intCast(index % self.cu);
        const j: i64 = @intCast(index / self.cu);
        quad.* = .{ .cell = index, .group = index, .piece = try lattice_nodes.square(self, i * self.n, j * self.n, self.n) };
    }
    try lattice_nodes.flush(self);
    var front: std.ArrayList(Placed) = .empty;
    try contour.frontPieces(self, quads, &front);
    for (front.items) |placed| self.cells[placed.cell].front = true;
    const coarse = try a.alloc(DepthPatch, front.items.len);
    const offs = try a.alloc(f64, front.items.len);
    try patches.depthPatches(self, front.items, false, coarse, offs);
    const stray = try a.alloc(f64, self.cells.len);
    @memset(stray, 0);
    const flipped = try a.alloc(bool, self.cells.len);
    @memset(flipped, false);
    var max_skirts: usize = 0;
    for (front.items) |placed| for (side_ends) |ends| {
        const p = self.nodes.items[placed.piece[ends[0]].node];
        const q = self.nodes.items[placed.piece[ends[1]].node];
        if (p.place & q.place & (on_contour | on_bounds) != 0) max_skirts += 1;
    };
    try self.patch_nodes.ensureUnusedCapacity(a, front.items.len);
    try self.skirts.ensureUnusedCapacity(a, max_skirts);
    for (front.items, coarse, offs) |placed, *dp, off| {
        const cell = &self.cells[placed.cell];
        stray[placed.cell] = @max(stray[placed.cell], off);
        if (dp.facing_flipped) flipped[placed.cell] = true;
        self.addPatch(cell, dp);
        for (side_ends, 0..) |ends, side| {
            const p = self.nodes.items[placed.piece[ends[0]].node];
            const q = self.nodes.items[placed.piece[ends[1]].node];
            if (p.place & q.place & (on_contour | on_bounds) == 0) continue;
            if (skirt(dp.*, side, self.shading.tolerance)) |made| self.addSkirt(cell, made);
        }
    }
    var squares: std.ArrayList(Square) = .empty;
    for (quads) |quad| {
        const cell = &self.cells[quad.cell];
        if (!cell.front) continue;
        var across: i64 = 1;
        if (self.shading.half != null) {
            var glint = -std.math.inf(f64);
            for (quad.piece) |corner| glint = @max(glint, self.nodes.items[corner.node].raw);
            if (glint > -self.turn / (1 - self.shading.cutoff)) {
                cell.gleams = true;
                across = self.m;
            }
        }
        const box = cell.bounds.?;
        const side = @max(box.max.x - box.min.x, box.max.y - box.min.y) / @as(f64, @floatFromInt(across));
        across <<= self.halvings(side);
        const origin = quad.piece[0];
        if (across > 1) {
            const size = @divExact(self.n, across);
            var fj: i64 = 0;
            while (fj < across) : (fj += 1) {
                var fi: i64 = 0;
                while (fi < across) : (fi += 1) try squares.append(a, .{ .cell = quad.cell, .i = origin.i + size * fi, .j = origin.j + size * fj, .size = size });
            }
        } else if (self.strays(stray[quad.cell]) or flipped[quad.cell]) {
            try halves(a, &squares, .{ .cell = quad.cell, .i = origin.i, .j = origin.j, .size = self.n });
        }
    }
    try self.refine(squares.items);
}

const Square = struct { cell: usize, i: i64, j: i64, size: i64 };

fn strays(self: *const Sheet, off: f64) bool {
    const scalar = self.shading.scalar orelse return false;
    return off > scalar.tolerance;
}

fn halvings(self: *const Sheet, side: f64) u6 {
    const scalar = self.shading.scalar orelse return 0;
    var count: u6 = 0;
    var extent = side;
    while (extent > 3 * scalar.step and count < space_shading.field_levels) : (count += 1) extent /= 2;
    return count;
}

fn halves(a: std.mem.Allocator, list: *std.ArrayList(Square), square: Square) Error!void {
    if (@rem(square.size, 6) != 0) return error.FieldLimit;
    const half = @divExact(square.size, 2);
    for ([4][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |at| try list.append(a, .{ .cell = square.cell, .i = square.i + at[0] * half, .j = square.j + at[1] * half, .size = half });
}

fn refine(self: *Sheet, squares: []const Square) Error!void {
    const a = self.allocator;
    var pending = squares;
    var made: usize = 0;
    while (pending.len > 0) {
        const quads = try a.alloc(Placed, pending.len);
        for (quads, pending, 0..) |*quad, square, k| quad.* = .{ .cell = square.cell, .group = k, .piece = try lattice_nodes.square(self, square.i, square.j, square.size) };
        try lattice_nodes.flush(self);
        var placed: std.ArrayList(Placed) = .empty;
        try contour.frontPieces(self, quads, &placed);
        made += placed.items.len;
        if (made > self.shading.budget) return error.ShadingLimit;
        const finer = try a.alloc(DepthPatch, placed.items.len);
        const found = try a.alloc(f64, placed.items.len);
        try patches.depthPatches(self, placed.items, true, finer, found);
        const off = try a.alloc(f64, pending.len);
        @memset(off, 0);
        const flipped = try a.alloc(bool, pending.len);
        @memset(flipped, false);
        for (placed.items, finer, found) |p, *dp, s| {
            off[p.group] = @max(off[p.group], s);
            if (dp.facing_flipped) flipped[p.group] = true;
        }
        var next: std.ArrayList(Square) = .empty;
        const split_group = try a.alloc(bool, pending.len);
        @memset(split_group, false);
        for (pending, off, flipped, split_group) |square, s, flip, *split| {
            if (self.strays(s)) {
                try halves(a, &next, square);
                split.* = true;
            } else if (flip and @rem(square.size, 6) == 0) {
                try halves(a, &next, square);
                split.* = true;
            }
        }
        var keep_count: usize = 0;
        for (placed.items) |p| keep_count += @intFromBool(!split_group[p.group]);
        try self.patch_nodes.ensureUnusedCapacity(a, keep_count);
        for (placed.items, finer) |p, *dp| {
            if (split_group[p.group]) continue;
            const cell = &self.cells[p.cell];
            if (!cell.refined) {
                cell.refined = true;
                cell.patch_head = no_patch;
                cell.patch_tail = no_patch;
                cell.patch_count = 0;
            }
            self.addPatch(cell, dp);
        }
        pending = next.items;
    }
}

/// The nodes a patch over `piece` samples at (i / 3, j / 3), index i * 4 + j.
pub fn samples(self: *Sheet, piece: Piece, cell: usize, contour_list: *std.ArrayList(patches.ContourThird)) ![16]u32 {
    var id: [16]u32 = undefined;
    id[0] = piece[0].node;
    id[12] = piece[1].node;
    id[15] = piece[2].node;
    id[3] = piece[3].node;
    for ([_][4]usize{ .{ 0, 1, 4, 8 }, .{ 1, 2, 13, 14 }, .{ 3, 2, 7, 11 }, .{ 0, 3, 1, 2 } }) |side| {
        const made = try patches.thirdsOf(self, piece[side[0]], piece[side[1]], cell, contour_list);
        id[side[2]] = made[0];
        id[side[3]] = made[1];
    }
    const a, const b, const c, const d = piece;
    const aligned = a.lattice and b.lattice and c.lattice and d.lattice and
        b.i - a.i == d.j - a.j and b.j == a.j and d.i == a.i and c.i == b.i and c.j == d.j;
    if (aligned) {
        for (1..3) |i| for (1..3) |j| {
            id[i * 4 + j] = (try lattice_nodes.at(self, a.i + @divTrunc((b.i - a.i) * @as(i64, @intCast(i)), 3), a.j + @divTrunc((d.j - a.j) * @as(i64, @intCast(j)), 3))).node;
        };
    }
    return id;
}

pub const Corner = struct {
    node: u32,
    i: i64 = 0,
    j: i64 = 0,
    lattice: bool = false,
};

pub const Piece = [4]Corner;

pub const Placed = struct { cell: usize, group: usize = 0, piece: Piece };

const no_patch = std.math.maxInt(u32);
const PatchNode = struct { dp: *const DepthPatch, next: u32 };

const Cell = struct {
    patch_head: u32 = no_patch,
    patch_tail: u32 = no_patch,
    patch_count: u32 = 0,
    skirt_start: u32 = 0,
    skirt_len: u32 = 0,
    bounds: ?g.BBox = null,
    front: bool = false,
    gleams: bool = false,
    refined: bool = false,
};

fn addPatch(self: *Sheet, cell: *Cell, dp: *const DepthPatch) void {
    const id: u32 = @intCast(self.patch_nodes.items.len);
    self.patch_nodes.appendAssumeCapacity(.{ .dp = dp, .next = no_patch });
    if (cell.patch_tail == no_patch) {
        cell.patch_head = id;
    } else {
        self.patch_nodes.items[cell.patch_tail].next = id;
    }
    cell.patch_tail = id;
    cell.patch_count += 1;
    const box = g.BBox.fromSlice(&dp.patch.points);
    cell.bounds = if (cell.bounds) |bounds| bounds.unite(box) else box;
}

fn addSkirt(self: *Sheet, cell: *Cell, sp: SkirtPatch) void {
    if (cell.skirt_len == 0) cell.skirt_start = @intCast(self.skirts.items.len);
    std.debug.assert(cell.skirt_start + cell.skirt_len == self.skirts.items.len);
    self.skirts.appendAssumeCapacity(sp);
    cell.skirt_len += 1;
    const box = g.BBox.fromSlice(&sp.patch.points);
    cell.bounds = if (cell.bounds) |bounds| bounds.unite(box) else box;
}

fn patchBounds(points: *const [16]g.Point) g.BBox {
    var box: g.BBox = .fromPoint(points[0]);
    for (points[1..]) |pt| box = box.include(pt);
    return box;
}

/// Emits patches for each of `regions`. Non-self-occluding single-layer faces
/// take the fast path with zero depth-ordering work; self-occluding or
/// two-sided faces sort all patches overlapping each region strictly far to
/// near with Newell, Newell & Sancha (1972).
pub fn regionFields(self: *Shading, sheets: []const Sheet, scratch: std.mem.Allocator, out: *Output, regions: []const g.BBox, result: []Field, single_layer: bool) Error!void {
    if (single_layer) {
        std.debug.assert(sheets.len == 1);
        const sheet = &sheets[0];
        const member = try scratch.alloc(bool, sheet.cells.len);
        var primary: std.ArrayList(usize) = .empty;
        var members: std.ArrayList(usize) = .empty;
        for (regions, result) |box, *field| {
            @memset(member, false);
            primary.clearRetainingCapacity();
            for (sheet.cells, 0..) |cell, index| {
                const bounds = cell.bounds orelse continue;
                if (!cell.front or !box.overlaps(bounds, 0)) continue;
                member[index] = true;
                try primary.append(scratch, index);
            }
            members.clearRetainingCapacity();
            try members.appendSlice(scratch, primary.items);
            for (primary.items) |index| {
                const i: i64 = @intCast(index % sheet.cu);
                const j: i64 = @intCast(index / sheet.cu);
                for ([3]i64{ -1, 0, 1 }) |dj| for ([3]i64{ -1, 0, 1 }) |di| {
                    const neighbour = sheet.cellAt(i + di, j + dj) orelse continue;
                    if (member[neighbour] or !sheet.cells[neighbour].front) continue;
                    member[neighbour] = true;
                    try members.append(scratch, neighbour);
                };
            }
            if (members.items.len == 0) continue;
            std.mem.sort(usize, members.items, {}, std.sort.asc(usize));
            var total: usize = 0;
            for (primary.items) |index| total += sheet.cells[index].skirt_len;
            for (members.items) |index| total += sheet.cells[index].patch_count;
            if (total > self.budget) return error.ShadingLimit;
            const start = out.patches.items.len;
            try out.patches.ensureUnusedCapacity(self.allocator, total);
            for (primary.items) |index| {
                const c = sheet.cells[index];
                for (sheet.skirts.items[c.skirt_start..][0..c.skirt_len]) |*sp| out.patches.appendAssumeCapacity(sp.patch);
            }
            for (members.items) |index| {
                var cur = sheet.cells[index].patch_head;
                while (cur != no_patch) {
                    const node = sheet.patch_nodes.items[cur];
                    out.patches.appendAssumeCapacity(node.dp.patch);
                    cur = node.next;
                }
            }
            self.budget -= total;
            field.* = .{ .patches = .{ .start = start, .count = total } };
        }
        return;
    }

    var skirts_list: std.ArrayList(*const SkirtPatch) = .empty;
    var depth_list: std.ArrayList(*const DepthPatch) = .empty;
    for (regions, result) |box, *field| {
        skirts_list.clearRetainingCapacity();
        depth_list.clearRetainingCapacity();
        for (sheets) |*sheet| for (sheet.cells) |cell| {
            const bounds = cell.bounds orelse continue;
            if (!cell.front or !box.overlaps(bounds, 0)) continue;
            for (sheet.skirts.items[cell.skirt_start..][0..cell.skirt_len]) |*sp| {
                if (box.overlaps(patchBounds(&sp.patch.points), 0)) try skirts_list.append(scratch, sp);
            }
            var cur = cell.patch_head;
            while (cur != no_patch) {
                const node = sheet.patch_nodes.items[cur];
                if (box.overlaps(patchBounds(&node.dp.patch.points), 0)) try depth_list.append(scratch, node.dp);
                cur = node.next;
            }
        };
        if (depth_list.items.len == 0 and skirts_list.items.len == 0) continue;
        std.mem.sort(*const SkirtPatch, skirts_list.items, {}, struct {
            fn farther(_: void, a: *const SkirtPatch, b: *const SkirtPatch) bool {
                return a.depth < b.depth;
            }
        }.farther);
        if (skirts_list.items.len + depth_list.items.len > self.budget) return error.ShadingLimit;
        const start = out.patches.items.len;
        try out.patches.ensureUnusedCapacity(self.allocator, skirts_list.items.len + depth_list.items.len);
        for (skirts_list.items) |sp| out.patches.appendAssumeCapacity(sp.patch);
        self.budget -= skirts_list.items.len;
        try depth_order.emit(self.allocator, scratch, depth_list.items, self.tolerance, &self.budget, &out.patches);
        field.* = .{ .patches = .{ .start = start, .count = out.patches.items.len - start } };
    }
}
