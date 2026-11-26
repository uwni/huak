//! A scalar field on tensor-product Bézier patches, colored by stops.
//! Patch k maps (u, v) in the unit square to the sum of
//! `points[k][i * 4 + j]` B_i(u) B_j(v) over the cubic Bernstein
//! polynomials B, and the field is the same sum over `values[k]`; the
//! corner coefficients are the field at the corners. Later patches paint
//! over earlier ones where they overlap.
//!
//! A PDF patch mesh (shading type 7) interpolates the field bilinearly
//! between the corner values, so its producer keeps each patch's field
//! that close to bilinear. Outputs without patch meshes approximate the
//! field itself, adding at most `tolerance` to it except within `margin`
//! of the outline they fill: an outline traced only that accurately.
const std = @import("std");
const g = @import("../geometry.zig");
const drawing_style = @import("../style.zig");
const bits = drawing_style.bits;
const Store = drawing_style.Gradient.Store;
const Color = drawing_style.Color;
const Stops = drawing_style.Gradient.Stops;
const Patches = @This();

points: []const [16]g.Point,
values: []const [16]f64,
stops: Stops,
tolerance: f64,
margin: f64 = 0,
/// Set by style pools on the values they own: the immutable arrays
/// that the slices view. Leave it null when building a style; the
/// pool copies the arrays once.
shared: ?*Shared = null,

pub fn validate(self: Patches) error{ InvalidStyle, InvalidColor, NonFinite }!void {
    if (self.points.len == 0 or self.points.len != self.values.len) return error.InvalidStyle;
    if (!std.math.isFinite(self.tolerance) or !(self.tolerance > 0)) return error.InvalidStyle;
    if (!std.math.isFinite(self.margin) or !(self.margin >= 0)) return error.InvalidStyle;
    try self.stops.validate();
    for (self.points) |patch| for (patch) |point| if (!point.isFinite()) return error.NonFinite;
    for (self.values) |patch| for (patch) |value| if (!std.math.isFinite(value)) return error.NonFinite;
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
    arrays: Patches,

    fn create(allocator: std.mem.Allocator, store: ?*Store, patches: Patches) !*Shared {
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
    pub fn adopt(allocator: std.mem.Allocator, store: ?*Store, patches: Patches) !*Shared {
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

    pub fn view(self: *Shared) Patches {
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
pub fn pooled(self: Patches, allocator: std.mem.Allocator, store: ?*Store) !Patches {
    if (self.shared) |shared| {
        if (store != null and shared.store == store) {
            _ = shared.references.fetchAdd(1, .monotonic);
            return shared.view();
        }
    }
    return (try Shared.create(allocator, store, self)).view();
}

/// Adopts arrays already allocated from `store.lockedAllocator()` or `allocator`.
pub fn adopt(self: Patches, allocator: std.mem.Allocator, store: ?*Store) !Patches {
    return (try Shared.adopt(allocator, store, self)).view();
}

/// Pooled patches hash once, when their arrays are copied or adopted.
pub fn digest(self: Patches) u64 {
    if (self.shared) |shared| return shared.digest;
    const hashBytes = std.hash.Wyhash.hash;
    var h = hashBytes(0, bits(self.points));
    h = hashBytes(h, bits(self.values));
    h = hashBytes(h, bits(self.stops.levels));
    h = hashBytes(h, bits(self.stops.colors));
    return hashBytes(h, bits(&[2]f64{ self.tolerance, self.margin }));
}

pub fn eql(a: Patches, b: Patches) bool {
    if (a.shared != null and b.shared != null) {
        if (a.shared == b.shared) return true;
        if (a.shared.?.digest != b.shared.?.digest) return false;
    }
    return std.mem.eql(u8, bits(a.points), bits(b.points)) and std.mem.eql(u8, bits(a.values), bits(b.values)) and
        std.mem.eql(u8, bits(a.stops.levels), bits(b.stops.levels)) and std.mem.eql(u8, bits(a.stops.colors), bits(b.stops.colors)) and
        std.mem.eql(u8, bits(&[2]f64{ a.tolerance, a.margin }), bits(&[2]f64{ b.tolerance, b.margin }));
}

pub fn dupe(self: Patches, allocator: std.mem.Allocator) !Patches {
    const points = try allocator.dupe([16]g.Point, self.points);
    errdefer allocator.free(points);
    const values = try allocator.dupe([16]f64, self.values);
    errdefer allocator.free(values);
    const levels = try allocator.dupe(f64, self.stops.levels);
    errdefer allocator.free(levels);
    const colors = try allocator.dupe(Color, self.stops.colors);
    return .{ .points = points, .values = values, .stops = .{ .levels = levels, .colors = colors }, .tolerance = self.tolerance, .margin = self.margin };
}

pub fn free(self: Patches, allocator: std.mem.Allocator) void {
    allocator.free(self.points);
    allocator.free(self.values);
    allocator.free(self.stops.levels);
    allocator.free(self.stops.colors);
}
