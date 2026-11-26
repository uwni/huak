//! The grid of a face's cells in its parameters. Every cell [a, b] satisfies
//! (b - a) * max_{t in [a, b]} r(t) <= h, where r(t) is the rate of normal
//! turn, so neither shading error nor cubic edge bow can grow where a flat
//! region meets a steep shoulder. Stepping symmetrically from both ends to the
//! midpoint keeps the grid strictly invariant under parameter reversal.
//! Cylinders, cones, spheres and tori have constant exact rates and therefore
//! equal cells. Other surfaces take, on each interval of a 65 x 65 grid, the
//! larger derivative of the normal at its two ends over all of the other
//! parameter, which estimates the rate but does not bound it.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const Shading = space_shading.Shading;
const Face = space_shading.Face;
const Info = space_shading.Info;
const Error = space_shading.Error;
const Turn = space_shading.Turn;
const dot = space_shading.dot;

/// The cells along both parameters: the edges of each, from the first
/// parameter to the last, and the turn across a cell along each.
pub const Grid = struct { edges: [2][]const f64, turn: [2]f64 };

/// The cells whose maximum-rate turn across each stays at most `size`.
pub fn grid(shading: *const Shading, allocator: std.mem.Allocator, face: Face, info: Info, period: [2]f64, size: f64, budget: usize) Error!Grid {
    const start: [2]f64 = .{ info.u[0], info.v[0] };
    const span: [2]f64 = .{ info.u[1] - info.u[0], info.v[1] - info.v[0] };
    // The rate of turn along each parameter, per unit of it, on equal
    // intervals of it.
    var conical_rate: [1]f64 = undefined;
    var sampled_rates: [2][rate_intervals]f64 = undefined;
    const profiles: [2][]const f64 = switch (info.kind) {
        .cylindrical => .{ &.{1}, &.{0} },
        .conical => blk: {
            conical_rate[0] = @cos(info.semi_angle);
            break :blk .{ &conical_rate, &.{0} };
        },
        .spherical, .toroidal => .{ &.{1}, &.{1} },
        .planar, .freeform => blk: {
            sampled_rates = try rates(shading, face, info);
            break :blk .{ &sampled_rates[0], &sampled_rates[1] };
        },
    };
    var count: [2]usize = undefined;
    var result: Grid = undefined;
    for (&count, &result.edges, &result.turn, start, span, profiles, period) |*divisions, *placed, *turn, from, extent, profile, wrap| {
        const min_cells: usize = if (wrap > 0) 3 else 1;
        if (profile.len == 1) {
            const cells = @ceil(extent * profile[0] / size);
            if (!(cells < 1e6)) return error.ShadingLimit;
            divisions.* = @max(min_cells, @as(usize, @intFromFloat(cells)));
            placed.* = try uniformEdges(allocator, from, extent, divisions.*);
            turn.* = extent / @as(f64, @floatFromInt(divisions.*)) * profile[0];
        } else {
            const built = try gradedEdges(allocator, from, extent, profile, size, min_cells, budget);
            placed.* = built.edges;
            divisions.* = built.edges.len - 1;
            turn.* = built.turn;
        }
    }
    if (@as(f64, @floatFromInt(count[0])) * @as(f64, @floatFromInt(count[1])) > @as(f64, @floatFromInt(budget))) return error.ShadingLimit;
    return result;
}

fn uniformEdges(allocator: std.mem.Allocator, from: f64, extent: f64, count: usize) Error![]const f64 {
    const result = try allocator.alloc(f64, count + 1);
    for (result, 0..) |*edge, k| edge.* = from + extent * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
    result[0] = from;
    result[count] = from + extent;
    return result;
}

const Graded = struct { edges: []const f64, turn: f64 };

/// Places cell edges over [from, from + extent] by stepping symmetrically from
/// both ends to 0.5 so every cell [a, b] keeps (b - a) * extent * max r <= size
/// while staying bit-for-bit symmetric under parameter reversal.
fn gradedEdges(allocator: std.mem.Allocator, from: f64, extent: f64, profile: []const f64, size: f64, min_cells: usize, budget: usize) Error!Graded {
    var peak_all: f64 = 0;
    for (profile) |rate| peak_all = @max(peak_all, rate);
    if (!(peak_all > 0) or !(extent > 0)) {
        return .{ .edges = try uniformEdges(allocator, from, extent, min_cells), .turn = 0 };
    }
    if (min_cells == 1 and extent * peak_all <= size) {
        return .{ .edges = try uniformEdges(allocator, from, extent, 1), .turn = extent * peak_all };
    }
    const max_step = 0.5 / @as(f64, @floatFromInt(@max(@as(usize, 1), (min_cells + 1) / 2)));
    var left: std.ArrayList(f64) = .empty;
    defer left.deinit(allocator);
    var right: std.ArrayList(f64) = .empty;
    defer right.deinit(allocator);
    var max_turn: f64 = 0;
    try stepHalf(allocator, &left, profile, extent, size, max_step, budget, false, &max_turn);
    try stepHalf(allocator, &right, profile, extent, size, max_step, budget, true, &max_turn);
    const total = left.items.len + right.items.len - 1;
    if (total > budget + 1) return error.ShadingLimit;
    const result = try allocator.alloc(f64, total);
    for (left.items, 0..) |t, k| result[k] = from + extent * t;
    var out = left.items.len;
    var r = right.items.len - 1;
    while (r > 0) {
        r -= 1;
        result[out] = from + extent * (1.0 - right.items[r]);
        out += 1;
    }
    result[0] = from;
    result[total - 1] = from + extent;
    return .{ .edges = result, .turn = max_turn };
}

fn stepHalf(allocator: std.mem.Allocator, out: *std.ArrayList(f64), profile: []const f64, extent: f64, size: f64, max_step: f64, budget: usize, reversed: bool, max_turn: *f64) Error!void {
    const intervals: f64 = @floatFromInt(profile.len);
    const half_intervals = profile.len / 2;
    try out.append(allocator, 0);
    var x: f64 = 0;
    while (x < 0.5 - 1e-12) {
        if (out.items.len > budget) return error.ShadingLimit;
        var idx: usize = @min(half_intervals - 1, @as(usize, @intFromFloat(@floor(x * intervals))));
        var peak = rateAt(profile, idx, reversed);
        var next_x = @min(0.5, x + max_step);
        if (peak > 0) next_x = @min(next_x, x + size / (extent * peak));
        while (idx + 1 < half_intervals) {
            const boundary = @as(f64, @floatFromInt(idx + 1)) / intervals;
            if (boundary >= next_x - 1e-15) break;
            const next_peak = @max(peak, rateAt(profile, idx + 1, reversed));
            const candidate = if (next_peak > 0) @min(next_x, x + size / (extent * next_peak)) else next_x;
            if (candidate <= boundary + 1e-15) {
                next_x = boundary;
                break;
            }
            peak = next_peak;
            next_x = candidate;
            idx += 1;
        }
        if (0.5 - next_x < 1e-12) next_x = 0.5;
        if (!(next_x > x)) return error.ShadingLimit;
        max_turn.* = @max(max_turn.*, (next_x - x) * extent * peak);
        try out.append(allocator, next_x);
        x = next_x;
    }
}

fn rateAt(profile: []const f64, idx: usize, reversed: bool) f64 {
    return if (reversed) profile[profile.len - 1 - idx] else profile[idx];
}

const rate_intervals = 64;

/// The rate of turn along each parameter on the 64 intervals of a 65 x 65
/// grid of it: on each interval, the larger of the largest derivatives of
/// the unit normal at its two ends over all of the other parameter. An
/// estimate, not a bound.
fn rates(self: *const Shading, face: Face, info: Info) Error![2][rate_intervals]f64 {
    const side = rate_intervals + 1;
    const tmp = self.allocator;
    const uv = try tmp.alloc(g.Point, side * side);
    defer tmp.free(uv);
    for (0..side) |j| for (0..side) |i| {
        uv[j * side + i] = .{
            .x = info.u[0] + (info.u[1] - info.u[0]) * @as(f64, @floatFromInt(i)) / rate_intervals,
            .y = info.v[0] + (info.v[1] - info.v[0]) * @as(f64, @floatFromInt(j)) / rate_intervals,
        };
    };
    const found = try tmp.alloc(?Turn, uv.len);
    defer tmp.free(found);
    try self.surfaces.turns(tmp, face, uv, found);
    // The largest rate along u on each line of constant u, and along v on
    // each line of constant v.
    var lines: [2][side]f64 = .{ @splat(0), @splat(0) };
    for (found, 0..) |turn, index| if (turn) |t| {
        lines[0][index % side] = @max(lines[0][index % side], @sqrt(dot(t.du, t.du)));
        lines[1][index / side] = @max(lines[1][index / side], @sqrt(dot(t.dv, t.dv)));
    };
    var result: [2][rate_intervals]f64 = undefined;
    for (&result, lines) |*profile, line| {
        for (profile, line[0..rate_intervals], line[1..]) |*rate, a, b| rate.* = @max(a, b);
    }
    return result;
}

test "gradedEdges satisfies max-rate bound and parameter-reversal symmetry" {
    const alloc = std.testing.allocator;
    var profile: [64]f64 = undefined;
    var reversed: [64]f64 = undefined;
    for (0..64) |i| {
        const t = (@as(f64, @floatFromInt(i)) + 0.5) / 64.0;
        const d = (t - 0.72) / 0.12;
        profile[i] = 0.001 + 2.5 * @exp(-d * d);
        reversed[63 - i] = profile[i];
    }
    const size = 0.125;
    const extent = 6.0;
    const fwd = try gradedEdges(alloc, 0, extent, &profile, size, 1, 10_000);
    defer alloc.free(fwd.edges);
    const rev = try gradedEdges(alloc, 0, extent, &reversed, size, 1, 10_000);
    defer alloc.free(rev.edges);
    try std.testing.expectEqual(fwd.edges.len, rev.edges.len);
    try std.testing.expect(fwd.turn <= size * (1.0 + 1e-8));
    for (0..fwd.edges.len) |k| {
        try std.testing.expectApproxEqAbs(extent, fwd.edges[k] + rev.edges[fwd.edges.len - 1 - k], 1e-12);
    }
    // Directly verify (b - a) * max_{t in [a, b]} r(t) <= size on every cell.
    for (0..fwd.edges.len - 1) |k| {
        const a = fwd.edges[k];
        const b = fwd.edges[k + 1];
        try std.testing.expect(b > a);
        var peak: f64 = 0;
        for (0..64) |i| {
            const lo = extent * @as(f64, @floatFromInt(i)) / 64.0;
            const hi = extent * @as(f64, @floatFromInt(i + 1)) / 64.0;
            if (hi > a + 1e-12 and lo < b - 1e-12) peak = @max(peak, profile[i]);
        }
        try std.testing.expect((b - a) * peak <= size * (1.0 + 1e-8));
    }
}
