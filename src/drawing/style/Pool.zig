//! Styles interned by value with copy-on-write: entries, release and replacement, and the key that hashes and compares a style's active fields by bits.
const std = @import("std");
const g = @import("../geometry.zig");
const Motion = @import("../pen/Motion.zig");
const drawing_style = @import("../style.zig");
const Pool = @This();
const Gradient = drawing_style.Gradient;
const Style = drawing_style.Style;
const bits = drawing_style.bits;

allocator: std.mem.Allocator,
/// Pools attached to the same store share mesh arrays instead of copying.
meshes: ?*Gradient.Store = null,
nodes: std.heap.MemoryPool(Entry) = .empty,
entries: std.HashMapUnmanaged(*Entry, void, Entry.Context, 80) = .empty,
data_bytes: usize = 0,

const Entry = struct {
    value: Style,
    references: usize,
    hash_code: u64,

    fn of(value: *const Style) *Entry {
        return @fieldParentPtr("value", @constCast(value));
    }

    const Context = struct {
        pub fn hash(_: @This(), entry: *Entry) u64 {
            return entry.hash_code;
        }
        pub fn eql(_: @This(), a: *Entry, b: *Entry) bool {
            // Stored keys are owned identities. Borrowed value lookup uses Query.
            return a == b;
        }
    };
    const Query = struct {
        hash_code: u64,
        pub fn hash(self: @This(), _: *const Style) u64 {
            return self.hash_code;
        }
        pub fn eql(_: @This(), value: *const Style, entry: *Entry) bool {
            return ValueContext.eql(.{}, value, &entry.value);
        }
    };
};

pub fn init(allocator: std.mem.Allocator) Pool {
    return .{ .allocator = allocator };
}

pub fn initWithMeshes(allocator: std.mem.Allocator, meshes: ?*Gradient.Store) Pool {
    return .{ .allocator = allocator, .meshes = meshes };
}

pub fn deinit(self: *Pool) void {
    var values = self.entries.keyIterator();
    while (values.next()) |value| self.freeData(&value.*.value);
    self.entries.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.* = undefined;
}

pub fn allocatedBytes(self: *const Pool) usize {
    // Used only as the soft storage-page budget, not allocator telemetry.
    return self.nodes.arena_state.promote(self.allocator).queryCapacity() + self.data_bytes +
        self.entries.capacity() * (@sizeOf(*const Style) + 1);
}

pub fn intern(self: *Pool, value: *const Style) std.mem.Allocator.Error!*const Style {
    const hash_code = ValueContext.hash(.{}, value);
    const entry = try self.entries.getOrPutAdapted(self.allocator, value, Entry.Query{ .hash_code = hash_code });
    if (entry.found_existing) {
        entry.key_ptr.*.references += 1;
        return &entry.key_ptr.*.value;
    }
    errdefer self.entries.removeByPtr(entry.key_ptr);
    const owned = try self.nodes.create(self.allocator);
    errdefer self.nodes.destroy(owned);
    try self.copyData(&owned.value, value);
    owned.references = 1;
    owned.hash_code = hash_code;
    entry.key_ptr.* = owned;
    return &owned.value;
}

pub fn release(self: *Pool, value: *const Style) void {
    const owned = Entry.of(value);
    std.debug.assert(owned.references != 0);
    owned.references -= 1;
    if (owned.references != 0) return;
    const removed = self.entries.remove(owned);
    std.debug.assert(removed);
    self.destroy(owned);
}

/// Leaves the old reference intact on allocation failure. Inputs may
/// borrow its arrays; copy them before releasing or overwriting anything.
pub fn replace(self: *Pool, previous: *const Style, value: *const Style) !*const Style {
    const owned = Entry.of(previous);
    if (owned.references != 1) {
        const next = try self.intern(value);
        self.release(previous);
        return next;
    }
    if (ValueContext.eql(.{}, previous, value)) return previous;
    const hash_code = ValueContext.hash(.{}, value);
    // Removing the old key reserves one slot without allocating or moving
    // entries. Restore it if copying the borrowed replacement fails.
    const removed = self.entries.remove(owned);
    std.debug.assert(removed);
    const entry = self.entries.getOrPutAssumeCapacityAdapted(value, Entry.Query{ .hash_code = hash_code });
    if (entry.found_existing) {
        const existing = entry.key_ptr.*;
        existing.references += 1;
        self.destroy(owned);
        return &existing.value;
    }
    errdefer {
        self.entries.removeByPtr(entry.key_ptr);
        self.entries.putAssumeCapacityNoClobber(owned, {});
    }
    var replacement: Style = undefined;
    try self.copyData(&replacement, value);
    self.freeData(previous);
    owned.value = replacement;
    owned.hash_code = hash_code;
    entry.key_ptr.* = owned;
    return &owned.value;
}

pub fn destroy(self: *Pool, entry: *Entry) void {
    self.freeData(&entry.value);
    self.nodes.destroy(entry);
}

fn copyData(self: *Pool, result: *Style, value: *const Style) !void {
    result.* = value.*;
    if (value.fill) |fill| result.fill = try fill.clone(self.allocator, self.meshes);
    errdefer if (result.fill) |fill| fill.deinit(self.allocator);
    if (result.pen) |*pen| {
        pen.paint = try value.pen.?.paint.clone(self.allocator, self.meshes);
        errdefer pen.paint.deinit(self.allocator);
        try pen.cloneData(self.allocator);
    }
    self.data_bytes += dataSize(result);
}

fn freeData(self: *Pool, value: *const Style) void {
    self.data_bytes -= dataSize(value);
    if (value.fill) |fill| fill.deinit(self.allocator);
    if (value.pen) |*pen| {
        pen.paint.deinit(self.allocator);
        pen.freeData(self.allocator);
    }
}

fn dataSize(value: *const Style) usize {
    const fill_bytes = if (value.fill) |fill| fill.dataSize() else 0;
    const pen = value.pen orelse return fill_bytes;
    const vertices = if (pen.nib) |nib| (if (nib == .polygon) nib.polygon.len else 0) else 0;
    const profile_bytes = if (pen.motion) |p| @sizeOf(Motion) + p.tracks.len * @sizeOf(Motion.Track) + p.keys.len * @sizeOf(Motion.Key) else 0;
    return fill_bytes + pen.paint.dataSize() + profile_bytes + pen.dash.len * @sizeOf(f64) + vertices * @sizeOf(g.Point);
}

// Compare and hash the active fields only. Padding and inactive optional/union
// payloads are excluded; f64 bits (including signed zero) remain distinct.
pub const ValueContext = struct {
    pub fn hash(_: ValueContext, value: *const Style) u64 {
        const hashBytes = std.hash.Wyhash.hash;
        // The discrete style header is the seed; hash only the active payloads.
        var h: u64 = (@as(u64, @backingInt(value.fill_rule)) << 2) |
            (@as(u64, @intFromBool(value.pen != null)) << 1) | @intFromBool(value.fill != null);
        if (value.fill) |*fill| h = fill.hash(h);
        if (value.pen) |*pen| {
            h = pen.paint.hash(h);
            h = hashBytes(h, bits(&[_]f64{ pen.width, pen.miter_limit, pen.dash_phase }));
            h = hashBytes(h, &.{ @backingInt(pen.cap), @backingInt(pen.join), @intFromBool(pen.nib != null) });
            h = hashBytes(h, bits(pen.dash));
            if (pen.motion) |p| h = p.hash(h);
            if (pen.nib) |*nib| {
                h = hashBytes(h, &.{@backingInt(std.meta.activeTag(nib.*))});
                h = switch (nib.*) {
                    .ellipse => |*ellipse| hashBytes(h, bits(ellipse)),
                    .polygon => |points| hashBytes(h, bits(points)),
                };
            }
        }
        return h;
    }

    pub fn eql(_: ValueContext, a: *const Style, b: *const Style) bool {
        if (a.fill_rule != b.fill_rule or (a.fill != null) != (b.fill != null) or (a.pen != null) != (b.pen != null)) return false;
        if (a.fill) |*fill| if (!fill.eql(&b.fill.?)) return false;
        if (a.pen) |*pen| {
            const other = &b.pen.?;
            if (pen.cap != other.cap or pen.join != other.join or (pen.nib != null) != (other.nib != null)) return false;
            if (!pen.paint.eql(&other.paint)) return false;
            if (!std.mem.eql(u8, bits(&[_]f64{ pen.width, pen.miter_limit, pen.dash_phase }), bits(&[_]f64{ other.width, other.miter_limit, other.dash_phase }))) return false;
            if (!std.mem.eql(u8, bits(pen.dash), bits(other.dash))) return false;
            if ((pen.motion != null) != (other.motion != null)) return false;
            if (pen.motion) |p| if (!p.eql(other.motion.?)) return false;
            if (pen.nib) |*nib| {
                if (std.meta.activeTag(nib.*) != std.meta.activeTag(other.nib.?)) return false;
                switch (nib.*) {
                    .ellipse => |*ellipse| if (!std.mem.eql(u8, bits(ellipse), bits(&other.nib.?.ellipse))) return false,
                    .polygon => |points| if (!std.mem.eql(u8, bits(points), bits(other.nib.?.polygon))) return false,
                }
            }
        }
        return true;
    }
};

fn replaceExercise(allocator: std.mem.Allocator) !void {
    const t = std.testing;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const initial: Style = .{ .pen = .{ .dash = &.{ 2, 3 }, .nib = .{ .polygon = &.{ .zero, .{ .x = 1, .y = 2 } } } } };
    const first = try pool.intern(&initial);
    var second = try pool.intern(first);
    var changed = initial;
    changed.pen.?.width = 2;
    second = pool.replace(second, &changed) catch |err| {
        try t.expect(ValueContext.eql(.{}, &initial, first));
        try t.expectEqual(@as(usize, 2), Pool.Entry.of(first).references);
        return err;
    };
    try t.expect(first != second);
    try t.expectEqual(@as(f64, 1), first.pen.?.width);
    try t.expectEqual(@as(f64, 2), second.pen.?.width);
    // Alias the previous owned arrays while replacing the unique reference.
    changed = second.*;
    changed.pen.?.width = 3;
    const previous = second.*;
    second = pool.replace(second, &changed) catch |err| {
        try t.expect(ValueContext.eql(.{}, &previous, second));
        try t.expectEqual(@as(usize, 1), Pool.Entry.of(second).references);
        const restored = pool.entries.getKeyAdapted(&previous, Pool.Entry.Query{ .hash_code = ValueContext.hash(.{}, &previous) });
        try t.expect(restored == Pool.Entry.of(second));
        return err;
    };
    try t.expectEqualSlices(f64, initial.pen.?.dash, second.pen.?.dash);
    second = try pool.replace(second, &initial);
    try t.expect(first == second);
    try t.expectEqual(@as(u32, 1), pool.entries.count());
    pool.release(first);
    pool.release(second);
    try t.expectEqual(@as(u32, 0), pool.entries.count());
    try t.expectEqual(@as(usize, 0), pool.data_bytes);
}

test "style replacement isolates shared values reuses entries and rolls back every allocation failure" {
    try replaceExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, replaceExercise, .{});
}
