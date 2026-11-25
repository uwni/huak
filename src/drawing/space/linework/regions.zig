//! The region of each face behind as many layers, bounded by arcs; shared by the line work and the band light.
const std = @import("std");
const c = @import("space_c");
const Model = @import("../Model.zig");
const Work = @import("Work.zig");
const Drawn = Work.Drawn;
const Sides = @import("../shading.zig").Sides;

/// A face behind `covering` layers.
pub const Key = struct { covering: usize, source: usize, face: usize };

pub fn keyOf(covering: usize, layer: c.HuakLayer) Key {
    return .{ .covering = covering, .source = layer.source, .face = layer.face };
}

pub fn keyBefore(x: Key, y: Key) bool {
    if (x.covering != y.covering) return x.covering < y.covering;
    if (x.source != y.source) return x.source < y.source;
    return x.face < y.face;
}

/// Indices of `keys` in `keyBefore` order.
pub fn sortedOrder(s: std.mem.Allocator, keys: []const Key) ![]usize {
    const order = try s.alloc(usize, keys.len);
    for (order, 0..) |*k, i| k.* = i;
    std.mem.sort(usize, order, keys, struct {
        fn less(all: []const Key, a: usize, b: usize) bool {
            return keyBefore(all[a], all[b]);
        }
    }.less);
    return order;
}

/// The sides of each face behind as many layers that lines of sight meet:
/// an open sheet may show its back, the side its normal points away from.
pub const Shown = struct {
    sides: std.AutoHashMapUnmanaged(Key, Sides) = .empty,

    pub fn add(self: *Shown, s: std.mem.Allocator, covering: usize, layer: c.HuakLayer) !void {
        const entry = try self.sides.getOrPut(s, keyOf(covering, layer));
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (layer.facing < 0) entry.value_ptr.back = true else entry.value_ptr.front = true;
    }

    pub fn of(self: *const Shown, key: Key) Sides {
        return self.sides.get(key) orelse .{};
    }
};

/// For each of the regions that arcs bound, the arcs around it, each turned
/// to keep the region on its left.
pub fn Bounding(comptime Region: type) type {
    return struct {
        arcs: std.AutoArrayHashMapUnmanaged(Region, std.ArrayList(c.HuakTurnedArc)) = .empty,

        /// An arc with `here` on its left and `there` on its right bounds
        /// both where they differ.
        pub fn between(self: *@This(), s: std.mem.Allocator, arc: usize, here: ?Region, there: ?Region) !void {
            if (std.meta.eql(here, there)) return;
            if (here) |region| try self.add(s, region, .{ .arc = arc, .reversed = 0 });
            if (there) |region| try self.add(s, region, .{ .arc = arc, .reversed = 1 });
        }

        pub fn add(self: *@This(), s: std.mem.Allocator, region: Region, arc: c.HuakTurnedArc) !void {
            const entry = try self.arcs.getOrPut(s, region);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(s, arc);
        }

        pub fn of(self: *const @This(), region: Region) ?[]const c.HuakTurnedArc {
            return if (self.arcs.get(region)) |list| list.items else null;
        }
    };
}

/// Sets of arcs to ask OCCT for the regions of together.
pub const Sets = struct {
    offsets: std.ArrayList(usize) = .empty,
    arcs: std.ArrayList(c.HuakTurnedArc) = .empty,

    /// Adds a set and returns which it is.
    pub fn add(self: *Sets, s: std.mem.Allocator, arcs: []const c.HuakTurnedArc) !usize {
        if (self.offsets.items.len == 0) try self.offsets.append(s, 0);
        try self.arcs.appendSlice(s, arcs);
        try self.offsets.append(s, self.arcs.items.len);
        return self.offsets.items.len - 2;
    }
};

/// The regions of the faces. Behind each number of layers, a face's
/// region is where the next layer is of that face; the arcs across
/// which that changes bound it.
const Bodies = struct {
    /// Each face behind as many layers, in order.
    keys: []const Key,
    /// For each, the arcs around its region.
    sets: Sets,
    /// The sides of the faces that show.
    shown: Shown,
};

pub fn bodies(self: *Work, drawn: Drawn) Model.Error!Bodies {
    const s = self.scratch;
    var bounding: Bounding(Key) = .{};
    var shown: Shown = .{};
    for (0..drawn.arcs.arcs.len) |k| {
        const left = drawn.left(k);
        const right = drawn.right(k);
        for (0..@max(left.len, right.len)) |covering| try bounding.between(
            s,
            k,
            if (covering < left.len) keyOf(covering, left[covering]) else null,
            if (covering < right.len) keyOf(covering, right[covering]) else null,
        );
        for ([2][]const c.HuakLayer{ left, right }) |layers| for (layers, 0..) |layer, covering| try shown.add(s, covering, layer);
    }
    const keys = bounding.arcs.keys();
    const order = try sortedOrder(s, keys);
    const sorted = try s.alloc(Key, keys.len);
    var sets: Sets = .{};
    for (order, sorted) |k, *key| {
        key.* = keys[k];
        _ = try sets.add(s, bounding.arcs.values()[k].items);
    }
    return .{ .keys = sorted, .sets = sets, .shown = shown };
}
