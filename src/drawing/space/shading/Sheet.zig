//! A face's sheet: the cells of a grid of its parameters, their patches, and
//! the region fields made from them.
//!
//! Other faces get tensor-product Bézier patches over a grid of their
//! parameters. A patch interpolates the projected surface and the field at
//! sixteen samples; PDF interpolates its corner values bilinearly in the
//! parameters, and other outputs approximate its cubic field. The normal
//! turns at most h across a cell, and bilinear interpolation of a function
//! of that angle whose second derivative is at most 1 errs by at most
//! h^2 / 4, so cells turn by h = sqrt(4 e). The glint turns 1 / (1 - c)
//! times faster: where it can be positive, finer patches turning by
//! sqrt(4 e (1 - c)) carry it, and n·l with it; elsewhere the glint is 0, so
//! both fields lie on the same patches. Interpolating in the parameters,
//! patches need no refinement where the projection folds at the contour.
//!
//! Normal rates per parameter are exact for cylinders, cones, spheres and
//! tori. Other surfaces use the largest derivative of the normal on a 33 x 33
//! grid, which estimates the rate but does not bound it.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const lattice_nodes = @import("nodes.zig");
const contour = @import("contour.zig");
const patches = @import("patches.zig");
const Node = @import("Node.zig");
const Sheet = @This();
const Shading = space_shading.Shading;
const Face = space_shading.Face;
const Info = space_shading.Info;
const Error = space_shading.Error;
const Turn = space_shading.Turn;
const dot = space_shading.dot;
const Patch = space_shading.Patch;
const Output = space_shading.Output;
const Field = space_shading.Field;
const max_steps = space_shading.max_steps;
const side_ends = patches.side_ends;
const on_contour = Node.on_contour;
const on_bounds = Node.on_bounds;
const skirt = patches.skirt;
const Sighting = space_shading.Sighting;
const bilinear = patches.bilinear;

shading: *const Shading,
/// An arena that holds everything the sheet makes.
allocator: std.mem.Allocator,
face: Face,
u: [2]f64,
v: [2]f64,
/// The period of a parameter around which the face closes, or zero.
period: [2]f64,
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

pub fn init(shading: *const Shading, allocator: std.mem.Allocator, face: Face, info: Info) Error!Sheet {
    const span: [2]f64 = .{ info.u[1] - info.u[0], info.v[1] - info.v[0] };
    // Normal turn per unit of each parameter.
    const rate: [2]f64 = switch (info.kind) {
        .cylindrical => .{ 1, 0 },
        .conical => .{ @cos(info.semi_angle), 0 },
        .spherical, .toroidal => .{ 1, 1 },
        .planar, .freeform => try rates(shading, allocator, face, info),
    };
    var period: [2]f64 = .{ 0, 0 };
    for (&period, [2]f64{ info.u_period, info.v_period }, span) |*wrap, length, extent| {
        if (length > 0 and @abs(extent - length) <= 1e-9 * length) wrap.* = length;
    }
    const size = @sqrt(4 * shading.accuracy);
    var count: [2]usize = undefined;
    for (&count, span, rate, period) |*divisions, extent, turn, wrap| {
        const cells = @ceil(extent * turn / size);
        if (!(cells < 1e6)) return error.ShadingLimit;
        divisions.* = @intCast(@max(@as(i64, if (wrap > 0) 3 else 1), @as(i64, @intFromFloat(cells))));
    }
    const cu = count[0];
    const cv = count[1];
    if (@as(f64, @floatFromInt(cu)) * @as(f64, @floatFromInt(cv)) > @as(f64, @floatFromInt(shading.budget))) return error.ShadingLimit;
    const turn = @max(span[0] / @as(f64, @floatFromInt(cu)) * rate[0], span[1] / @as(f64, @floatFromInt(cv)) * rate[1]);
    var m: i64 = 1;
    if (shading.half != null) {
        const steps = @ceil(turn / @sqrt(4 * shading.accuracy * (1 - shading.cutoff)));
        if (!(steps <= max_steps)) return error.ShadingLimit;
        m = @max(1, @as(i64, @intFromFloat(steps)));
    }
    // The script's field may halve the glint's squares `field_levels` times;
    // the lattice holds the corners and thirds of every square it makes.
    const levels: u6 = if (shading.scalar != null) space_shading.field_levels else 0;
    const n = 3 * m * (@as(i64, 1) << levels);
    const cells = try allocator.alloc(Cell, cu * cv);
    @memset(cells, .{});
    return .{
        .shading = shading,
        .allocator = allocator,
        .face = face,
        .u = info.u,
        .v = info.v,
        .period = period,
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
    try patches.centers(self, front.items);
    const coarse = try a.alloc(Patch, front.items.len);
    const offs = try a.alloc(f64, front.items.len);
    try patches.patches(self, front.items, false, coarse, offs);
    const stray = try a.alloc(f64, self.cells.len);
    @memset(stray, 0);
    for (front.items, coarse, offs) |placed, patch, off| {
        const cell = &self.cells[placed.cell];
        stray[placed.cell] = @max(stray[placed.cell], off);
        try cell.add(a, &cell.patches, patch);
        for (side_ends, 0..) |ends, side| {
            const p = self.nodes.items[placed.piece[ends[0]].node];
            const q = self.nodes.items[placed.piece[ends[1]].node];
            if (p.place & q.place & (on_contour | on_bounds) == 0) continue;
            if (skirt(patch, side, self.shading.tolerance)) |made| try cell.add(a, &cell.skirts, made);
        }
    }
    // Finer squares carry the glint where the highlight can reach, m to a
    // cell's side: the glint changes by at most turn / (1 - c) across the
    // cell. The script's field is sampled at least every step of it on the
    // page, and a cell whose patches it strays from halves.
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
        } else if (self.strays(stray[quad.cell])) try halves(a, &squares, .{ .cell = quad.cell, .i = origin.i, .j = origin.j, .size = self.n });
    }
    try self.refine(squares.items);
}

/// A square of the lattice in one cell: its corner and its side, in steps.
const Square = struct { cell: usize, i: i64, j: i64, size: i64 };

/// Whether the script's field strays from patches by `off`.
fn strays(self: *const Sheet, off: f64) bool {
    const scalar = self.shading.scalar orelse return false;
    return off > scalar.tolerance;
}

/// How often a square `side` long on the page halves before the samples of
/// its patches, at its thirds, lie within the script's step of each other;
/// at most as often as the lattice allows.
fn halvings(self: *const Sheet, side: f64) u6 {
    const scalar = self.shading.scalar orelse return 0;
    var count: u6 = 0;
    var extent = side;
    while (extent > 3 * scalar.step and count < space_shading.field_levels) : (count += 1) extent /= 2;
    return count;
}

/// The four halves of a square, when the lattice holds their corners and
/// thirds.
fn halves(a: std.mem.Allocator, list: *std.ArrayList(Square), square: Square) Error!void {
    if (@rem(square.size, 6) != 0) return error.FieldLimit;
    const half = @divExact(square.size, 2);
    for ([4][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |at| try list.append(a, .{ .cell = square.cell, .i = square.i + at[0] * half, .j = square.j + at[1] * half, .size = half });
}

/// Patches over `squares` that take the place of their cells' own, whose
/// skirts stay. A square whose patches the script's field strays from
/// halves, round by round, until none does.
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
        const finer = try a.alloc(Patch, placed.items.len);
        const found = try a.alloc(f64, placed.items.len);
        try patches.patches(self, placed.items, true, finer, found);
        const off = try a.alloc(f64, pending.len);
        @memset(off, 0);
        for (placed.items, found) |p, s| off[p.group] = @max(off[p.group], s);
        var next: std.ArrayList(Square) = .empty;
        for (pending, off) |square, s| if (self.strays(s)) try halves(a, &next, square);
        for (placed.items, finer) |p, patch| {
            if (self.strays(off[p.group])) continue;
            const cell = &self.cells[p.cell];
            if (!cell.refined) {
                cell.refined = true;
                cell.patches.clearRetainingCapacity();
            }
            try cell.add(a, &cell.patches, patch);
        }
        pending = next.items;
    }
}

/// Hides the cells whose centers another sheet of the face covers.
pub fn cull(self: *Sheet) Error!void {
    const a = self.allocator;
    var points: std.ArrayList(g.Point) = .empty;
    var owners: std.ArrayList(usize) = .empty;
    for (self.cells, 0..) |cell, index| {
        if (!cell.front or cell.center.singular) continue;
        try points.append(a, .{ .x = cell.center.x, .y = cell.center.y });
        try owners.append(a, index);
    }
    if (points.items.len == 0) return;
    const offsets = try a.alloc(usize, points.items.len + 1);
    var found: std.ArrayList(Sighting) = .empty;
    try self.shading.surfaces.sightings(a, self.face, points.items, offsets, &found);
    for (owners.items, offsets[0..owners.items.len], offsets[1..]) |index, start, end| {
        const cell = &self.cells[index];
        for (found.items[start..end]) |sighting| {
            if (sighting.depth > cell.center.depth + self.shading.tolerance) {
                cell.visible = false;
                break;
            }
        }
    }
}

/// The nodes a patch over `piece` samples at (i / 3, j / 3), index
/// i * 4 + j.
pub fn samples(self: *Sheet, piece: Piece) ![16]u32 {
    var id: [16]u32 = undefined;
    id[0] = piece[0].node;
    id[12] = piece[1].node;
    id[15] = piece[2].node;
    id[3] = piece[3].node;
    for ([_][4]usize{ .{ 0, 1, 4, 8 }, .{ 1, 2, 13, 14 }, .{ 3, 2, 7, 11 }, .{ 0, 3, 1, 2 } }) |side| {
        const made = try patches.thirdsOf(self, piece[side[0]], piece[side[1]]);
        id[side[2]] = made[0];
        id[side[3]] = made[1];
    }
    const a, const b, const c, const d = piece;
    const aligned = a.lattice and b.lattice and c.lattice and d.lattice and
        b.i - a.i == d.j - a.j and b.j == a.j and d.i == a.i and c.i == b.i and c.j == d.j;
    const uv = patches.corners(self, piece);
    for (1..3) |i| for (1..3) |j| {
        id[i * 4 + j] = if (aligned)
            (try lattice_nodes.at(self, a.i + @divTrunc((b.i - a.i) * @as(i64, @intCast(i)), 3), a.j + @divTrunc((d.j - a.j) * @as(i64, @intCast(j)), 3))).node
        else
            try lattice_nodes.request(self, bilinear(uv, @as(f64, @floatFromInt(i)) / 3.0, @as(f64, @floatFromInt(j)) / 3.0), 0);
    };
    return id;
}

/// The largest derivative of the unit normal along each parameter on a
/// 33 x 33 grid: an estimate, not a bound.
pub fn rates(self: *const Shading, scratch: std.mem.Allocator, face: Face, info: Info) Error![2]f64 {
    const probes = 32;
    const side = probes + 1;
    const uv = try scratch.alloc(g.Point, side * side);
    for (0..side) |j| for (0..side) |i| {
        uv[j * side + i] = .{
            .x = info.u[0] + (info.u[1] - info.u[0]) * @as(f64, @floatFromInt(i)) / probes,
            .y = info.v[0] + (info.v[1] - info.v[0]) * @as(f64, @floatFromInt(j)) / probes,
        };
    };
    const found = try scratch.alloc(?Turn, uv.len);
    try self.surfaces.turns(scratch, face, uv, found);
    var rate: [2]f64 = .{ 0, 0 };
    for (found) |turn| if (turn) |t| {
        rate[0] = @max(rate[0], @sqrt(dot(t.du, t.du)));
        rate[1] = @max(rate[1], @sqrt(dot(t.dv, t.dv)));
    };
    return rate;
}

/// A corner of a piece: a node, with its lattice point if it has one.
pub const Corner = struct {
    node: u32,
    i: i64 = 0,
    j: i64 = 0,
    lattice: bool = false,
};

/// A patch's corners at (0, 0), (1, 0), (1, 1) and (0, 1) in its own
/// parameters, joined by straight lines in the face's parameters. A triangle
/// repeats its last corner.
pub const Piece = [4]Corner;

/// A piece, the cell it belongs to, and the square of a round of the
/// construction it was cut from.
pub const Placed = struct { cell: usize, group: usize = 0, piece: Piece };

const Cell = struct {
    patches: std.ArrayList(Patch) = .empty,
    skirts: std.ArrayList(Patch) = .empty,
    /// Of all the cell's patches.
    bounds: ?g.BBox = null,
    center: Node = .{ .uv = .zero },
    front: bool = false,
    visible: bool = true,
    /// Whether the highlight can reach the cell, whose finer patches then
    /// carry the glint.
    gleams: bool = false,
    /// Whether finer patches have taken the place of its own.
    refined: bool = false,

    pub fn add(cell: *Cell, allocator: std.mem.Allocator, list: *std.ArrayList(Patch), patch: Patch) !void {
        try list.append(allocator, patch);
        for (patch.points) |point| cell.bounds = if (cell.bounds) |bounds| bounds.include(point) else .fromPoint(point);
    }
};

/// The patches field of each of `regions`, from the cells of the face's
/// sheets, one for each side it shows; `covers` when a sheet may lie in
/// front of another part of the face.
pub fn regionFields(self: *Shading, sheets: []const Sheet, scratch: std.mem.Allocator, out: *Output, regions: []const g.BBox, result: []Field, covers: bool) Error!void {
    // A region shows the sheet in front, and a visible cell lies where its
    // sheet is in front, so the visible cells over a region's bounds cover
    // it. Their neighbours fill edges that are only partly covered. Skirts
    // go under all patches; a face that can cover itself paints far cells
    // first.
    const Member = struct { sheet: usize, cell: usize };
    const member = try scratch.alloc([]bool, sheets.len);
    for (member, sheets) |*flags, sheet| flags.* = try scratch.alloc(bool, sheet.cells.len);
    var primary: std.ArrayList(Member) = .empty;
    var members: std.ArrayList(Member) = .empty;
    for (regions, result) |box, *field| {
        for (member) |flags| @memset(flags, false);
        primary.clearRetainingCapacity();
        for (sheets, 0..) |sheet, s| for (sheet.cells, 0..) |cell, index| {
            const bounds = cell.bounds orelse continue;
            if (!cell.front or !cell.visible or !box.overlaps(bounds, 0)) continue;
            member[s][index] = true;
            try primary.append(scratch, .{ .sheet = s, .cell = index });
        };
        members.clearRetainingCapacity();
        try members.appendSlice(scratch, primary.items);
        for (primary.items) |at| {
            const sheet = sheets[at.sheet];
            const i: i64 = @intCast(at.cell % sheet.cu);
            const j: i64 = @intCast(at.cell / sheet.cu);
            for ([3]i64{ -1, 0, 1 }) |dj| for ([3]i64{ -1, 0, 1 }) |di| {
                const neighbour = sheet.cellAt(i + di, j + dj) orelse continue;
                if (member[at.sheet][neighbour] or !sheet.cells[neighbour].front) continue;
                member[at.sheet][neighbour] = true;
                try members.append(scratch, .{ .sheet = at.sheet, .cell = neighbour });
            };
        }
        if (members.items.len == 0) continue;
        if (covers) {
            std.mem.sort(Member, members.items, sheets, struct {
                fn farther(all: []const Sheet, a: Member, b: Member) bool {
                    return all[a.sheet].cells[a.cell].center.depth < all[b.sheet].cells[b.cell].center.depth;
                }
            }.farther);
        } else std.mem.sort(Member, members.items, {}, struct {
            fn before(_: void, a: Member, b: Member) bool {
                return if (a.sheet != b.sheet) a.sheet < b.sheet else a.cell < b.cell;
            }
        }.before);
        const start = out.patches.items.len;
        for (primary.items) |at| try out.patches.appendSlice(self.allocator, sheets[at.sheet].cells[at.cell].skirts.items);
        for (members.items) |at| try out.patches.appendSlice(self.allocator, sheets[at.sheet].cells[at.cell].patches.items);
        const used = out.patches.items.len - start;
        if (used > self.budget) return error.ShadingLimit;
        self.budget -= used;
        field.* = .{ .patches = .{ .start = start, .count = used } };
    }
}
