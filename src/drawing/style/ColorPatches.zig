//! Tensor-product Bézier patches with a color at each corner. Patch k maps
//! (u, v) in the unit square to the sum of `points[k][i * 4 + j]`
//! B_i(u) B_j(v), and its color there interpolates `colors[k]`, given at
//! (u, v) = (0, 0), (0, 1), (1, 1) and (1, 0), bilinearly in u and v: what
//! a PDF patch mesh with colors at its corners draws. Only the patches
//! paint, later ones over earlier ones. Every color is opaque: flattening
//! transparency makes these where two fields on the same patches combine.
const std = @import("std");
const g = @import("../geometry.zig");
const drawing_style = @import("../style.zig");
const bits = drawing_style.bits;
const Store = drawing_style.Gradient.Store;
const Color = drawing_style.Color;
const ColorPatches = @This();

points: []const [16]g.Point,
colors: []const [4]Color,
margin: f64 = 0,
/// Set by style pools on the values they own: the immutable arrays
/// that the slices view. Leave it null when building a style; the
/// pool copies the arrays once.
shared: ?*Shared = null,

pub fn validate(self: ColorPatches) error{ InvalidStyle, InvalidColor, NonFinite }!void {
    if (self.points.len == 0 or self.points.len != self.colors.len) return error.InvalidStyle;
    if (!std.math.isFinite(self.margin) or !(self.margin >= 0)) return error.InvalidStyle;
    for (self.points) |patch| for (patch) |point| if (!point.isFinite()) return error.NonFinite;
    for (self.colors) |corners| for (corners) |color| if (!color.valid() or color.a != 1) return error.InvalidColor;
}

/// Immutable arrays referenced by pool entries. With a store they
/// come from the store and are shared by its pools; without one they
/// belong to the single pool that copied them.
pub const Shared = struct {
    references: std.atomic.Value(usize),
    store: ?*Store,
    allocator: std.mem.Allocator,
    digest: u64,
    /// The owned arrays; their own `shared` is null.
    arrays: ColorPatches,

    fn create(allocator: std.mem.Allocator, store: ?*Store, patches: ColorPatches) !*Shared {
        const digest_ = patches.digest();
        const heap = if (store) |owner| owner.allocator else allocator;
        if (store) |owner| std.Io.Threaded.mutexLockUncancelable(&owner.mutex);
        defer if (store) |owner| std.Io.Threaded.mutexUnlock(&owner.mutex);
        const arrays = try patches.dupe(heap);
        errdefer arrays.free(heap);
        const shared = try heap.create(Shared);
        shared.* = .{ .references = .init(1), .store = store, .allocator = heap, .digest = digest_, .arrays = arrays };
        if (store) |owner| _ = owner.live.fetchAdd(1, .monotonic);
        return shared;
    }

    /// Takes ownership of `patches` whose slices were already allocated from
    /// `store.lockedAllocator()` (when `store != null`) or `allocator`.
    /// On failure, `patches` remains owned by the caller.
    pub fn adopt(allocator: std.mem.Allocator, store: ?*Store, patches: ColorPatches) !*Shared {
        var owned = patches;
        owned.shared = null;
        const digest_ = owned.digest();
        const heap = if (store) |owner| owner.allocator else allocator;
        if (store) |owner| std.Io.Threaded.mutexLockUncancelable(&owner.mutex);
        defer if (store) |owner| std.Io.Threaded.mutexUnlock(&owner.mutex);
        const shared = try heap.create(Shared);
        shared.* = .{ .references = .init(1), .store = store, .allocator = heap, .digest = digest_, .arrays = owned };
        if (store) |owner| _ = owner.live.fetchAdd(1, .monotonic);
        return shared;
    }

    pub fn view(self: *Shared) ColorPatches {
        var patches = self.arrays;
        patches.shared = self;
        return patches;
    }

    pub fn release(self: *Shared) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        const store = self.store;
        const heap = self.allocator;
        if (store) |owner| std.Io.Threaded.mutexLockUncancelable(&owner.mutex);
        defer if (store) |owner| std.Io.Threaded.mutexUnlock(&owner.mutex);
        self.arrays.free(heap);
        heap.destroy(self);
        if (store) |owner| _ = owner.live.fetchSub(1, .release);
    }

    /// Pool entries referencing these arrays, including the caller's.
    pub fn referenceCount(self: *const Shared) usize {
        return self.references.load(.acquire);
    }
};

/// The arrays for a pool attached to `store`, or to none: the same
/// arrays when they already belong to that store, a fresh copy
/// otherwise.
pub fn pooled(self: ColorPatches, allocator: std.mem.Allocator, store: ?*Store) !ColorPatches {
    if (self.shared) |shared| {
        if (store != null and shared.store == store) {
            _ = shared.references.fetchAdd(1, .monotonic);
            return shared.view();
        }
    }
    return (try Shared.create(allocator, store, self)).view();
}

/// Adopts arrays already allocated from `store.lockedAllocator()` or `allocator`.
pub fn adopt(self: ColorPatches, allocator: std.mem.Allocator, store: ?*Store) !ColorPatches {
    return (try Shared.adopt(allocator, store, self)).view();
}

/// Pooled color patches hash once, when their arrays are created or adopted.
pub fn digest(self: ColorPatches) u64 {
    if (self.shared) |shared| return shared.digest;
    const hashBytes = std.hash.Wyhash.hash;
    var h = hashBytes(0, bits(self.points));
    h = hashBytes(h, bits(self.colors));
    return hashBytes(h, bits(&self.margin));
}

pub fn eql(a: ColorPatches, b: ColorPatches) bool {
    if (a.shared != null and b.shared != null) {
        if (a.shared == b.shared) return true;
        if (a.shared.?.digest != b.shared.?.digest) return false;
    }
    return std.mem.eql(u8, bits(&a.margin), bits(&b.margin)) and
        (a.points.len == b.points.len and (a.points.ptr == b.points.ptr or std.mem.eql(u8, bits(a.points), bits(b.points)))) and
        (a.colors.len == b.colors.len and (a.colors.ptr == b.colors.ptr or std.mem.eql(u8, bits(a.colors), bits(b.colors))));
}

pub fn dupe(self: ColorPatches, allocator: std.mem.Allocator) !ColorPatches {
    const points = try allocator.dupe([16]g.Point, self.points);
    errdefer allocator.free(points);
    return .{ .points = points, .colors = try allocator.dupe([4]Color, self.colors), .margin = self.margin };
}

pub fn free(self: ColorPatches, allocator: std.mem.Allocator) void {
    allocator.free(self.points);
    allocator.free(self.colors);
}
