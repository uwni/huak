//! Explicit owner of the patch arrays a host's pictures share. Pools attached
//! to the same store reference one copy of each paint's arrays; any other pool
//! copies them for itself. Like an allocator, a store stays at a stable address
//! until every pool attached to it is gone; `deinit` asserts that no arrays are
//! left. Pools on several threads may use one store: it serializes its
//! allocator.
const std = @import("std");
const Store = @This();

allocator: std.mem.Allocator,
mutex: std.Io.Mutex = .init,
live: std.atomic.Value(usize) = .init(0),

pub fn init(allocator: std.mem.Allocator) Store {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Store) void {
    std.debug.assert(self.live.load(.acquire) == 0);
    self.* = undefined;
}

/// Paints whose arrays the store currently holds.
pub fn count(self: *const Store) usize {
    return self.live.load(.acquire);
}

/// Thread-safe allocator serialized by `self.mutex`, matching the backing
/// allocator used when `Shared.release` frees adopted arrays.
pub fn lockedAllocator(self: *Store) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &locked_vtable };
}

const locked_vtable: std.mem.Allocator.VTable = .{
    .alloc = lockedAlloc,
    .resize = lockedResize,
    .remap = lockedRemap,
    .free = lockedFree,
};

fn lockedAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Store = @ptrCast(@alignCast(ctx));
    std.Io.Threaded.mutexLockUncancelable(&self.mutex);
    defer std.Io.Threaded.mutexUnlock(&self.mutex);
    return self.allocator.vtable.alloc(self.allocator.ptr, len, alignment, ret_addr);
}

fn lockedResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Store = @ptrCast(@alignCast(ctx));
    std.Io.Threaded.mutexLockUncancelable(&self.mutex);
    defer std.Io.Threaded.mutexUnlock(&self.mutex);
    return self.allocator.vtable.resize(self.allocator.ptr, memory, alignment, new_len, ret_addr);
}

fn lockedRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Store = @ptrCast(@alignCast(ctx));
    std.Io.Threaded.mutexLockUncancelable(&self.mutex);
    defer std.Io.Threaded.mutexUnlock(&self.mutex);
    return self.allocator.vtable.remap(self.allocator.ptr, memory, alignment, new_len, ret_addr);
}

fn lockedFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Store = @ptrCast(@alignCast(ctx));
    std.Io.Threaded.mutexLockUncancelable(&self.mutex);
    defer std.Io.Threaded.mutexUnlock(&self.mutex);
    self.allocator.vtable.free(self.allocator.ptr, memory, alignment, ret_addr);
}
