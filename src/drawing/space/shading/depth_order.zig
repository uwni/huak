//! Newell, Newell & Sancha (ACM 1972) far-to-near depth ordering for curved
//! tensor-product cubic Bézier patches in camera space (x, y, z), where z
//! increases toward the camera.
//!
//! Uses sweep-and-prune over 2D bounding boxes, pairwise comparison in
//! `depth_patch.zig`, batch de Casteljau subdivision of mutually straddling
//! pairs, and Kahn's topological sort with Newell §3 cycle-breaking.
const std = @import("std");
const g = @import("../../geometry.zig");
const space_shading = @import("../shading.zig");
const patches_mod = @import("patches.zig");
const depth_patch = @import("depth_patch.zig");
const Patch = space_shading.Patch;
const DepthPatch = patches_mod.DepthPatch;
const Error = space_shading.Error;
const NodePatch = depth_patch.NodePatch;

const max_rounds: usize = 32;
const Edge = struct { from: u32, to: u32 };

/// Orders `input` patches strictly far to near and appends them to `out`.
pub fn emit(allocator: std.mem.Allocator, scratch: std.mem.Allocator, input: []const DepthPatch, tolerance: f64, budget: *usize, out: *std.ArrayList(Patch)) Error!void {
    if (input.len == 0) return;
    const min_size = 0.5 * tolerance;

    var items: std.ArrayList(NodePatch) = .empty;
    try items.ensureTotalCapacity(scratch, input.len + input.len / 4);
    var scale: f64 = 1.0;
    for (input) |dp| {
        const np = NodePatch.fromDepth(dp);
        scale = @max(scale, @abs(np.x_min), @abs(np.x_max), @abs(np.y_min), @abs(np.y_max), @abs(np.z_min), @abs(np.z_max));
        items.appendAssumeCapacity(np);
    }

    var active: std.ArrayList(u32) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var order: std.ArrayList(u32) = .empty;
    var alive_count = input.len;

    for (0..max_rounds) |_| {
        active.clearRetainingCapacity();
        for (items.items, 0..) |*np, idx| if (np.alive) try active.append(scratch, @intCast(idx));
        std.mem.sort(u32, active.items, items.items, struct {
            fn less(all: []const NodePatch, a: u32, b: u32) bool {
                return all[a].x_min < all[b].x_min;
            }
        }.less);

        const m = active.items.len;
        edges.clearRetainingCapacity();
        const to_split = try scratch.alloc(bool, m);
        @memset(to_split, false);
        var any_split = false;

        for (0..m) |i| {
            const a = &items.items[active.items[i]];
            for (i + 1..m) |j| {
                const b = &items.items[active.items[j]];
                if (b.x_min >= a.x_max) break;
                if (b.y_max <= a.y_min or a.y_max <= b.y_min) continue;
                if (any_split and to_split[i] and to_split[j]) continue;
                switch (depth_patch.compare(a, b, scale)) {
                    .disjoint => {},
                    .a_behind_b => if (!any_split) try edges.append(scratch, .{ .from = @intCast(i), .to = @intCast(j) }),
                    .b_behind_a => if (!any_split) try edges.append(scratch, .{ .from = @intCast(j), .to = @intCast(i) }),
                    .straddle => {
                        const a_ok = a.canSubdivide(min_size);
                        const b_ok = b.canSubdivide(min_size);
                        if (a_ok or b_ok) {
                            const pick = if (a_ok and b_ok) (if (a.screenSize() >= b.screenSize()) i else j) else if (a_ok) i else j;
                            to_split[pick] = true;
                            any_split = true;
                        } else if (!any_split) {
                            if (a.z_avg <= b.z_avg) {
                                try edges.append(scratch, .{ .from = @intCast(i), .to = @intCast(j) });
                            } else try edges.append(scratch, .{ .from = @intCast(j), .to = @intCast(i) });
                        }
                    },
                }
            }
        }

        if (any_split) {
            for (0..m) |k| if (to_split[k]) {
                if (alive_count + 1 > budget.*) return error.ShadingLimit;
                try splitAt(scratch, &items, active.items[k]);
                alive_count += 1;
            };
            continue;
        }

        order.clearRetainingCapacity();
        if (try topoSort(scratch, items.items, active.items, edges.items, min_size, &order)) |split_idx| {
            if (alive_count + 1 > budget.*) return error.ShadingLimit;
            try splitAt(scratch, &items, split_idx);
            alive_count += 1;
            continue;
        }

        if (order.items.len > budget.*) return error.ShadingLimit;
        try out.ensureUnusedCapacity(allocator, order.items.len);
        for (order.items) |local_idx| out.appendAssumeCapacity(items.items[active.items[local_idx]].toPatch());
        budget.* -= order.items.len;
        return;
    }

    active.clearRetainingCapacity();
    for (items.items, 0..) |*np, idx| if (np.alive) try active.append(scratch, @intCast(idx));
    std.mem.sort(u32, active.items, items.items, struct {
        fn less(all: []const NodePatch, a: u32, b: u32) bool {
            return all[a].z_avg < all[b].z_avg;
        }
    }.less);
    if (active.items.len > budget.*) return error.ShadingLimit;
    try out.ensureUnusedCapacity(allocator, active.items.len);
    for (active.items) |idx| out.appendAssumeCapacity(items.items[idx].toPatch());
    budget.* -= active.items.len;
}

fn splitAt(scratch: std.mem.Allocator, items: *std.ArrayList(NodePatch), index: u32) Error!void {
    const children = items.items[index].subdivide();
    items.items[index].alive = false;
    try items.append(scratch, children[0]);
    try items.append(scratch, children[1]);
}

/// Runs Kahn's topological sort. Returns null when all nodes are ordered, or
/// the global item index of the largest subdividable patch on a directed cycle.
fn topoSort(scratch: std.mem.Allocator, items: []const NodePatch, active: []const u32, edges: []const Edge, min_size: f64, order: *std.ArrayList(u32)) Error!?u32 {
    const m = active.len;
    const out_offsets = try scratch.alloc(u32, m + 1);
    @memset(out_offsets, 0);
    const in_deg = try scratch.alloc(u32, m);
    @memset(in_deg, 0);
    for (edges) |e| {
        out_offsets[e.from + 1] += 1;
        in_deg[e.to] += 1;
    }
    for (1..m + 1) |i| out_offsets[i] += out_offsets[i - 1];
    const out_targets = try scratch.alloc(u32, edges.len);
    const cursor = try scratch.dupe(u32, out_offsets[0..m]);
    for (edges) |e| {
        out_targets[cursor[e.from]] = e.to;
        cursor[e.from] += 1;
    }

    const emitted = try scratch.alloc(bool, m);
    @memset(emitted, false);
    var queue: std.ArrayList(u32) = .empty;
    for (0..m) |i| if (in_deg[i] == 0) try queue.append(scratch, @intCast(i));
    const QueueCtx = struct { all: []const NodePatch, act: []const u32 };
    std.mem.sort(u32, queue.items, QueueCtx{ .all = items, .act = active }, struct {
        fn less(ctx: QueueCtx, a: u32, b: u32) bool {
            return ctx.all[ctx.act[a]].z_avg < ctx.all[ctx.act[b]].z_avg;
        }
    }.less);

    var head: usize = 0;
    while (order.items.len < m) {
        while (head < queue.items.len) : (head += 1) {
            const u = queue.items[head];
            if (emitted[u]) continue;
            emitted[u] = true;
            try order.append(scratch, u);
            for (out_targets[out_offsets[u]..out_offsets[u + 1]]) |v| {
                if (emitted[v] or in_deg[v] == 0) continue;
                in_deg[v] -= 1;
                if (in_deg[v] == 0) try queue.append(scratch, v);
            }
        }
        if (order.items.len == m) return null;

        const pred = try scratch.alloc(u32, m);
        @memset(pred, std.math.maxInt(u32));
        for (edges) |e| {
            if (!emitted[e.from] and !emitted[e.to]) pred[e.to] = e.from;
        }
        const seen = try scratch.alloc(bool, m);
        @memset(seen, false);
        var cur: u32 = 0;
        while (emitted[cur] or pred[cur] == std.math.maxInt(u32)) : (cur += 1) {}
        while (!seen[cur]) {
            seen[cur] = true;
            cur = pred[cur];
        }
        const start = cur;
        var best_split: ?u32 = null;
        var best_size: f64 = -1;
        var farthest: u32 = start;
        var min_z = items[active[start]].z_avg;
        while (true) {
            const global = active[cur];
            const np = &items[global];
            if (np.canSubdivide(min_size)) {
                const sz = np.screenSize();
                if (sz > best_size) {
                    best_size = sz;
                    best_split = global;
                }
            }
            if (np.z_avg < min_z) {
                min_z = np.z_avg;
                farthest = cur;
            }
            cur = pred[cur];
            if (cur == start) break;
        }
        if (best_split) |idx| return idx;
        in_deg[farthest] = 0;
        try queue.append(scratch, farthest);
    }
    return null;
}

fn testFlatPatch(x0: f64, y0: f64, w: f64, h: f64, z00: f64, z10: f64, z11: f64, z01: f64, tag: f64) DepthPatch {
    var pts: [16]g.Point = undefined;
    var pz: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        const u = @as(f64, @floatFromInt(i)) / 3.0;
        const v = @as(f64, @floatFromInt(j)) / 3.0;
        pts[i * 4 + j] = .{ .x = x0 + w * u, .y = y0 + h * v };
        pz[i * 4 + j] = (1 - u) * (1 - v) * z00 + u * (1 - v) * z10 + u * v * z11 + (1 - u) * v * z01;
    };
    return .{ .patch = .{ .points = pts, .diffuse = @splat(tag), .glint = @splat(0), .values = @splat(0) }, .pz = pz };
}

fn testLastTagAt(patches: []const Patch, x: f64, y: f64) ?f64 {
    var k = patches.len;
    while (k > 0) {
        k -= 1;
        const p = patches[k];
        if (x >= p.points[0].x - 1e-9 and x <= p.points[15].x + 1e-9 and y >= p.points[0].y - 1e-9 and y <= p.points[15].y + 1e-9) {
            return p.diffuse[0];
        }
    }
    return null;
}

test "Newell depth order handles strict z separation, overlapping-z subdivision, and cycle breaking" {
    const t = std.testing;
    var out: std.ArrayList(Patch) = .empty;
    defer out.deinit(t.allocator);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    // 1. Strict z-interval separation (z_max <= z_min): no subdivision.
    const far = testFlatPatch(0, 0, 10, 10, 0, 1, 1, 0, 1);
    const near = testFlatPatch(0, 0, 10, 10, 3, 4, 4, 3, 2);
    var budget: usize = 1000;
    try emit(t.allocator, arena.allocator(), &.{ near, far }, 0.01, &budget, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(@as(f64, 1), out.items[0].diffuse[0]);
    try t.expectEqual(@as(f64, 2), out.items[1].diffuse[0]);

    // 2. Overlapping z intervals separated by supporting planes: no subdivision.
    out.clearRetainingCapacity();
    budget = 1000;
    const low = testFlatPatch(0, 0, 10, 10, 0, 4, 4, 0, 1);
    const high = testFlatPatch(0, 0, 10, 10, 2, 6, 6, 2, 2);
    try emit(t.allocator, arena.allocator(), &.{ high, low }, 0.01, &budget, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(@as(f64, 1), out.items[0].diffuse[0]);
    try t.expectEqual(@as(f64, 2), out.items[1].diffuse[0]);

    // 3. Mutually straddling patches (crossing along x = 5): subdivides and
    // paints tag 1 in front on the right (x > 5) and tag 2 in front on the left (x < 5).
    out.clearRetainingCapacity();
    budget = 1000;
    const rising = testFlatPatch(0, 0, 10, 10, 0, 10, 10, 0, 1);
    const falling = testFlatPatch(0, 0, 10, 10, 10, 0, 0, 10, 2);
    try emit(t.allocator, arena.allocator(), &.{ rising, falling }, 0.01, &budget, &out);
    try t.expect(out.items.len > 2);
    try t.expectEqual(@as(?f64, 2), testLastTagAt(out.items, 1.5, 5.0));
    try t.expectEqual(@as(?f64, 1), testLastTagAt(out.items, 8.5, 5.0));

    // 4. 4-patch Newell overlap cycle: breaks by subdividing a cycle member.
    out.clearRetainingCapacity();
    budget = 1000;
    const c1 = testFlatPatch(0, 0, 10, 3, 0, 10, 10, 0, 10);
    const c2 = testFlatPatch(7, 0, 3, 10, 1, 1, 11, 11, 20);
    const c3 = testFlatPatch(0, 7, 10, 3, 12, 2, 2, 12, 30);
    const c4 = testFlatPatch(0, 0, 3, 10, 11, 11, 1, 1, 40);
    try emit(t.allocator, arena.allocator(), &.{ c1, c2, c3, c4 }, 0.01, &budget, &out);
    try t.expect(out.items.len > 4);
    try t.expectEqual(@as(?f64, 10), testLastTagAt(out.items, 8.5, 1.5));
    try t.expectEqual(@as(?f64, 20), testLastTagAt(out.items, 8.5, 8.5));
    try t.expectEqual(@as(?f64, 30), testLastTagAt(out.items, 1.5, 8.5));
    try t.expectEqual(@as(?f64, 40), testLastTagAt(out.items, 1.5, 1.5));
}
