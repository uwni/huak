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
const SortKey = struct { x_min: f64, idx: u32 };
const Box3D = struct { x_min: f64, x_max: f64, y_min: f64, y_max: f64, z_min: f64, z_max: f64 };

const TopoScratch = struct {
    out_offsets: std.ArrayList(u32) = .empty,
    in_deg: std.ArrayList(u32) = .empty,
    out_targets: std.ArrayList(u32) = .empty,
    cursor: std.ArrayList(u32) = .empty,
    emitted: std.ArrayList(bool) = .empty,
    queue: std.ArrayList(u32) = .empty,
    pred: std.ArrayList(u32) = .empty,
    seen: std.ArrayList(bool) = .empty,

    fn deinit(self: *TopoScratch, allocator: std.mem.Allocator) void {
        self.out_offsets.deinit(allocator);
        self.in_deg.deinit(allocator);
        self.out_targets.deinit(allocator);
        self.cursor.deinit(allocator);
        self.emitted.deinit(allocator);
        self.queue.deinit(allocator);
        self.pred.deinit(allocator);
        self.seen.deinit(allocator);
    }
};

/// Orders `input` patches strictly far to near and appends them to `out`.
pub fn emit(allocator: std.mem.Allocator, scratch: std.mem.Allocator, input: []const *const DepthPatch, tolerance: f64, budget: *usize, out: *std.ArrayList(Patch)) Error!void {
    if (input.len == 0) return;
    const min_size = 0.5 * tolerance;
    const initial_cap = input.len + input.len / 4;

    var items: std.ArrayList(NodePatch) = .empty;
    defer items.deinit(scratch);
    try items.ensureTotalCapacity(scratch, initial_cap);
    var scale: f64 = 1.0;
    for (input) |dp| {
        const np = items.addOneAssumeCapacity();
        np.fromDepthInto(dp);
        scale = @max(scale, @abs(np.x_min), @abs(np.x_max), @abs(np.y_min), @abs(np.y_max), @abs(np.z_min), @abs(np.z_max));
    }

    var active: std.ArrayList(u32) = .empty;
    defer active.deinit(scratch);
    try active.ensureTotalCapacity(scratch, initial_cap);
    var sort_keys: std.ArrayList(SortKey) = .empty;
    defer sort_keys.deinit(scratch);
    try sort_keys.ensureTotalCapacity(scratch, initial_cap);
    var boxes: std.ArrayList(Box3D) = .empty;
    defer boxes.deinit(scratch);
    try boxes.ensureTotalCapacity(scratch, initial_cap);
    var to_split: std.ArrayList(bool) = .empty;
    defer to_split.deinit(scratch);
    try to_split.ensureTotalCapacity(scratch, initial_cap);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(scratch);
    try edges.ensureTotalCapacity(scratch, input.len * 2);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(scratch);
    try order.ensureTotalCapacity(scratch, initial_cap);
    var ts: TopoScratch = .{};
    defer ts.deinit(scratch);
    var alive_count = input.len;

    for (0..max_rounds) |_| {
        sort_keys.clearRetainingCapacity();
        try sort_keys.ensureTotalCapacity(scratch, alive_count);
        for (items.items, 0..) |*np, idx| if (np.alive) sort_keys.appendAssumeCapacity(.{ .x_min = np.x_min, .idx = @intCast(idx) });
        std.mem.sort(SortKey, sort_keys.items, {}, struct {
            fn less(_: void, a: SortKey, b: SortKey) bool {
                return a.x_min < b.x_min;
            }
        }.less);

        const m = sort_keys.items.len;
        active.clearRetainingCapacity();
        try active.ensureTotalCapacity(scratch, m);
        boxes.clearRetainingCapacity();
        try boxes.ensureTotalCapacity(scratch, m);
        for (sort_keys.items) |key| {
            active.appendAssumeCapacity(key.idx);
            const np = &items.items[key.idx];
            boxes.appendAssumeCapacity(.{
                .x_min = np.x_min,
                .x_max = np.x_max,
                .y_min = np.y_min,
                .y_max = np.y_max,
                .z_min = np.z_min,
                .z_max = np.z_max,
            });
        }

        edges.clearRetainingCapacity();
        try to_split.resize(scratch, m);
        const split_flags = to_split.items;
        @memset(split_flags, false);
        var any_split = false;

        const box_slice = boxes.items;
        const act_slice = active.items;
        const all_items = items.items;
        for (0..m) |i| {
            const ba = box_slice[i];
            for (i + 1..m) |j| {
                const bb = box_slice[j];
                if (bb.x_min >= ba.x_max) break;
                if (bb.y_max <= ba.y_min or ba.y_max <= bb.y_min) continue;
                if (any_split and split_flags[i] and split_flags[j]) continue;
                if (ba.z_max <= bb.z_min) {
                    if (!any_split) try edges.append(scratch, .{ .from = @intCast(i), .to = @intCast(j) });
                    continue;
                }
                if (bb.z_max <= ba.z_min) {
                    if (!any_split) try edges.append(scratch, .{ .from = @intCast(j), .to = @intCast(i) });
                    continue;
                }
                const a = &all_items[act_slice[i]];
                const b = &all_items[act_slice[j]];
                switch (depth_patch.compare(a, b, scale)) {
                    .disjoint => {},
                    .a_behind_b => if (!any_split) try edges.append(scratch, .{ .from = @intCast(i), .to = @intCast(j) }),
                    .b_behind_a => if (!any_split) try edges.append(scratch, .{ .from = @intCast(j), .to = @intCast(i) }),
                    .straddle => {
                        const a_ok = a.canSubdivide(min_size);
                        const b_ok = b.canSubdivide(min_size);
                        if (a_ok or b_ok) {
                            const pick = if (a_ok and b_ok) (if (a.screenSize() >= b.screenSize()) i else j) else if (a_ok) i else j;
                            split_flags[pick] = true;
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
            var splits: usize = 0;
            for (split_flags) |flag| splits += @intFromBool(flag);
            if (alive_count + splits > budget.*) return error.ShadingLimit;
            try items.ensureUnusedCapacity(scratch, splits * 2);
            for (0..m) |k| if (split_flags[k]) {
                splitAtAssumeCapacity(&items, active.items[k]);
                alive_count += 1;
            };
            continue;
        }

        order.clearRetainingCapacity();
        if (try topoSort(scratch, &ts, items.items, active.items, edges.items, min_size, &order)) |split_idx| {
            if (alive_count + 1 > budget.*) return error.ShadingLimit;
            try items.ensureUnusedCapacity(scratch, 2);
            splitAtAssumeCapacity(&items, split_idx);
            alive_count += 1;
            continue;
        }

        if (order.items.len > budget.*) return error.ShadingLimit;
        try out.ensureUnusedCapacity(allocator, order.items.len);
        for (order.items) |local_idx| items.items[active.items[local_idx]].toPatchInto(out.addOneAssumeCapacity());
        budget.* -= order.items.len;
        return;
    }

    active.clearRetainingCapacity();
    try active.ensureTotalCapacity(scratch, alive_count);
    for (items.items, 0..) |*np, idx| if (np.alive) active.appendAssumeCapacity(@intCast(idx));
    std.mem.sort(u32, active.items, items.items, struct {
        fn less(all: []const NodePatch, a: u32, b: u32) bool {
            return all[a].z_avg < all[b].z_avg;
        }
    }.less);
    if (active.items.len > budget.*) return error.ShadingLimit;
    try out.ensureUnusedCapacity(allocator, active.items.len);
    for (active.items) |idx| items.items[idx].toPatchInto(out.addOneAssumeCapacity());
    budget.* -= active.items.len;
}

fn splitAtAssumeCapacity(items: *std.ArrayList(NodePatch), index: u32) void {
    const dst = items.addManyAsArrayAssumeCapacity(2);
    const parent = &items.items[index];
    parent.subdivideInto(dst);
    parent.alive = false;
}

/// Runs Kahn's topological sort. Returns null when all nodes are ordered, or
/// the global item index of the largest subdividable patch on a directed cycle.
fn topoSort(scratch: std.mem.Allocator, ts: *TopoScratch, items: []const NodePatch, active: []const u32, edges: []const Edge, min_size: f64, order: *std.ArrayList(u32)) Error!?u32 {
    const m = active.len;
    try ts.out_offsets.resize(scratch, m + 1);
    const out_offsets = ts.out_offsets.items;
    @memset(out_offsets, 0);
    try ts.in_deg.resize(scratch, m);
    const in_deg = ts.in_deg.items;
    @memset(in_deg, 0);
    for (edges) |e| {
        out_offsets[e.from + 1] += 1;
        in_deg[e.to] += 1;
    }
    for (1..m + 1) |i| out_offsets[i] += out_offsets[i - 1];
    try ts.out_targets.resize(scratch, edges.len);
    const out_targets = ts.out_targets.items;
    try ts.cursor.resize(scratch, m);
    const cursor = ts.cursor.items;
    @memcpy(cursor, out_offsets[0..m]);
    for (edges) |e| {
        out_targets[cursor[e.from]] = e.to;
        cursor[e.from] += 1;
    }

    try ts.emitted.resize(scratch, m);
    const emitted = ts.emitted.items;
    @memset(emitted, false);
    ts.queue.clearRetainingCapacity();
    try ts.queue.ensureTotalCapacity(scratch, m);
    for (0..m) |i| if (in_deg[i] == 0) ts.queue.appendAssumeCapacity(@intCast(i));
    const QueueCtx = struct { all: []const NodePatch, act: []const u32 };
    std.mem.sort(u32, ts.queue.items, QueueCtx{ .all = items, .act = active }, struct {
        fn less(ctx: QueueCtx, a: u32, b: u32) bool {
            return ctx.all[ctx.act[a]].z_avg < ctx.all[ctx.act[b]].z_avg;
        }
    }.less);

    try order.ensureTotalCapacity(scratch, m);
    var head: usize = 0;
    while (order.items.len < m) {
        while (head < ts.queue.items.len) : (head += 1) {
            const u = ts.queue.items[head];
            if (emitted[u]) continue;
            emitted[u] = true;
            order.appendAssumeCapacity(u);
            for (out_targets[out_offsets[u]..out_offsets[u + 1]]) |v| {
                if (emitted[v] or in_deg[v] == 0) continue;
                in_deg[v] -= 1;
                if (in_deg[v] == 0) ts.queue.appendAssumeCapacity(v);
            }
        }
        if (order.items.len == m) return null;

        try ts.pred.resize(scratch, m);
        const pred = ts.pred.items;
        @memset(pred, std.math.maxInt(u32));
        for (edges) |e| {
            if (!emitted[e.from] and !emitted[e.to]) pred[e.to] = e.from;
        }
        try ts.seen.resize(scratch, m);
        const seen = ts.seen.items;
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
        ts.queue.appendAssumeCapacity(farthest);
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
    try emit(t.allocator, arena.allocator(), &.{ &near, &far }, 0.01, &budget, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(@as(f64, 1), out.items[0].diffuse[0]);
    try t.expectEqual(@as(f64, 2), out.items[1].diffuse[0]);

    // 2. Overlapping z intervals separated by supporting planes: no subdivision.
    out.clearRetainingCapacity();
    budget = 1000;
    const low = testFlatPatch(0, 0, 10, 10, 0, 4, 4, 0, 1);
    const high = testFlatPatch(0, 0, 10, 10, 2, 6, 6, 2, 2);
    try emit(t.allocator, arena.allocator(), &.{ &high, &low }, 0.01, &budget, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqual(@as(f64, 1), out.items[0].diffuse[0]);
    try t.expectEqual(@as(f64, 2), out.items[1].diffuse[0]);

    // 3. Mutually straddling patches (crossing along x = 5): subdivides and
    // paints tag 1 in front on the right (x > 5) and tag 2 in front on the left (x < 5).
    out.clearRetainingCapacity();
    budget = 1000;
    const rising = testFlatPatch(0, 0, 10, 10, 0, 10, 10, 0, 1);
    const falling = testFlatPatch(0, 0, 10, 10, 10, 0, 0, 10, 2);
    try emit(t.allocator, arena.allocator(), &.{ &rising, &falling }, 0.01, &budget, &out);
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
    try emit(t.allocator, arena.allocator(), &.{ &c1, &c2, &c3, &c4 }, 0.01, &budget, &out);
    try t.expect(out.items.len > 4);
    try t.expectEqual(@as(?f64, 10), testLastTagAt(out.items, 8.5, 1.5));
    try t.expectEqual(@as(?f64, 20), testLastTagAt(out.items, 8.5, 8.5));
    try t.expectEqual(@as(?f64, 30), testLastTagAt(out.items, 1.5, 8.5));
    try t.expectEqual(@as(?f64, 40), testLastTagAt(out.items, 1.5, 1.5));
}
