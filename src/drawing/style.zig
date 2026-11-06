//! Shared drawing styles with copy-on-write updates inside each picture.
const std = @import("std");
const g = @import("geometry.zig");
const Nib = @import("pen/nib.zig").Nib;
const Motion = @import("pen/Motion.zig");

pub const Color = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 1,
    pub const black: Color = .{};
    pub fn valid(self: Color) bool {
        inline for (.{ "r", "g", "b", "a" }) |field| {
            const value = @field(self, field);
            if (!std.math.isFinite(value) or value < 0 or value > 1) return false;
        }
        return true;
    }
};
pub const Cap = @import("pen/stroke.zig").Cap;
pub const Join = @import("pen/stroke.zig").Join;
pub const FillRule = enum { nonzero, evenodd };
pub const Pen = struct {
    color: Color = .black,
    width: f64 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f64 = 4,
    /// Borrowed while drawing; DisplayList takes an owned snapshot.
    dash: []const f64 = &.{},
    dash_phase: f64 = 0,
    /// Explicit physical nib, independent of the centerline and width field.
    nib: ?Nib = null,
    /// Borrowed from the caller; the style pool retains an immutable snapshot.
    motion: ?*const Motion = null,

    pub fn needsGeometry(self: *const Pen) bool {
        return self.nib != null or self.motion != null;
    }

    pub fn fixedNib(self: *const Pen) !Nib {
        if (self.motion != null) return error.MotionHasNoFixedNib;
        if (self.nib) |nib| return nib;
        if (!std.math.isFinite(self.width) or self.width < 0) return error.InvalidPen;
        return .{ .ellipse = .scaling(self.width, self.width) };
    }

    /// Replace borrowed arrays with owned copies. Failure leaves this value
    /// unchanged; release successful copies with freeData or their arena.
    pub fn cloneData(self: *Pen, allocator: std.mem.Allocator) !void {
        const dash = try allocator.dupe(f64, self.dash);
        errdefer allocator.free(dash);
        const motion = if (self.motion) |p| try p.clone(allocator) else null;
        errdefer if (motion) |p| p.destroy(allocator);
        if (self.nib) |*value| if (value.* == .polygon) {
            value.* = .{ .polygon = try allocator.dupe(g.Point, value.polygon) };
        };
        self.dash = dash;
        self.motion = motion;
    }

    pub fn freeData(self: *const Pen, allocator: std.mem.Allocator) void {
        allocator.free(self.dash);
        if (self.motion) |p| p.destroy(allocator);
        if (self.nib) |nib| if (nib == .polygon) allocator.free(nib.polygon);
    }
};
pub const Gradient = union(enum) {
    radial_fill: Ramp,
    linear_fill: Ramp,
    linear_stroke: Ramp,
    mesh_fill: Mesh,

    pub const Ramp = struct { start: g.Point, end: g.Point, colors: []const Color };
    pub const Mesh = struct {
        vertices: []const Vertex,
        triangles: []const [3]u32,
        pub const Vertex = extern struct {
            x: f64,
            y: f64,
            r: f64,
            g: f64,
            b: f64,
            a: f64 = 1,
            pub fn color(self: Vertex) Color {
                return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
            }
        };
    };

    pub fn clone(self: Gradient, allocator: std.mem.Allocator) !Gradient {
        switch (self) {
            .mesh_fill => |mesh| {
                const vertices = try allocator.dupe(Mesh.Vertex, mesh.vertices);
                errdefer allocator.free(vertices);
                return .{ .mesh_fill = .{ .vertices = vertices, .triangles = try allocator.dupe([3]u32, mesh.triangles) } };
            },
            inline else => |ramp, tag| return @unionInit(Gradient, @tagName(tag), Ramp{ .start = ramp.start, .end = ramp.end, .colors = try allocator.dupe(Color, ramp.colors) }),
        }
    }

    pub fn deinit(self: Gradient, allocator: std.mem.Allocator) void {
        switch (self) {
            .mesh_fill => |mesh| {
                allocator.free(mesh.vertices);
                allocator.free(mesh.triangles);
            },
            inline else => |ramp| allocator.free(ramp.colors),
        }
    }

    pub fn dataSize(self: Gradient) usize {
        return switch (self) {
            .mesh_fill => |mesh| mesh.vertices.len * @sizeOf(Mesh.Vertex) + mesh.triangles.len * @sizeOf([3]u32),
            inline else => |ramp| ramp.colors.len * @sizeOf(Color),
        };
    }

    pub fn hasInk(self: Gradient) bool {
        switch (self) {
            .mesh_fill => |mesh| {
                for (mesh.vertices) |vertex| if (vertex.a > 0) return true;
            },
            inline else => |ramp| {
                for (ramp.colors) |color| if (color.a > 0) return true;
            },
        }
        return false;
    }
};

pub const Style = struct {
    gradient: ?*const Gradient = null,
    fill: ?Color = null,
    pen: ?Pen = null,
    fill_rule: FillRule = .nonzero,

    pub const Component = enum { fill, stroke };
    pub fn gradientFor(self: *const Style, component: Component) ?*const Gradient {
        const paint = self.gradient orelse return null;
        return if ((paint.* == .linear_stroke) == (component == .stroke)) paint else null;
    }

    pub fn hasInk(self: *const Style, component: Component) bool {
        if (self.gradientFor(component)) |paint| {
            return paint.hasInk();
        }
        return if (component == .fill) (self.fill != null and self.fill.?.a > 0) else (self.pen != null and self.pen.?.color.a > 0);
    }
};

/// Commands retain references to styles interned by value. Shared entries are immutable; replacing
/// the sole reference reuses its slot. Borrowed render views require the owner
/// to remain frozen, just like the owner's geometry banks.
pub const Pool = struct {
    allocator: std.mem.Allocator,
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

    fn destroy(self: *Pool, entry: *Entry) void {
        self.freeData(&entry.value);
        self.nodes.destroy(entry);
    }

    fn copyData(self: *Pool, result: *Style, value: *const Style) !void {
        result.* = value.*;
        if (result.gradient) |paint| {
            const owned = try self.allocator.create(Gradient);
            errdefer self.allocator.destroy(owned);
            owned.* = try paint.clone(self.allocator);
            result.gradient = owned;
        }
        errdefer self.freeGradient(result);
        if (result.pen) |*pen| try pen.cloneData(self.allocator);
        self.data_bytes += dataSize(result);
    }

    fn freeData(self: *Pool, value: *const Style) void {
        self.data_bytes -= dataSize(value);
        self.freeGradient(value);
        if (value.pen) |*pen| pen.freeData(self.allocator);
    }

    fn freeGradient(self: *Pool, value: *const Style) void {
        if (value.gradient) |paint| {
            paint.deinit(self.allocator);
            self.allocator.destroy(paint);
        }
    }

    fn dataSize(value: *const Style) usize {
        const paint_bytes = if (value.gradient) |paint| @sizeOf(Gradient) + paint.dataSize() else 0;
        const pen = value.pen orelse return paint_bytes;
        const vertices = if (pen.nib) |nib| (if (nib == .polygon) nib.polygon.len else 0) else 0;
        const profile_bytes = if (pen.motion) |p| @sizeOf(Motion) + p.tracks.len * @sizeOf(Motion.Track) + p.keys.len * @sizeOf(Motion.Key) else 0;
        return paint_bytes + profile_bytes + pen.dash.len * @sizeOf(f64) + vertices * @sizeOf(g.Point);
    }
};

// Compare and hash the active fields only. Padding and inactive optional/union
// payloads are excluded; f64 bits (including signed zero) remain distinct.
const ValueContext = struct {
    pub fn hash(_: ValueContext, value: *const Style) u64 {
        const hashBytes = std.hash.Wyhash.hash;
        // The discrete style header is the seed; hash only the active payloads.
        var h: u64 = (@as(u64, @backingInt(value.fill_rule)) << 2) |
            (@as(u64, @intFromBool(value.pen != null)) << 1) | @intFromBool(value.fill != null);
        if (value.gradient) |paint| {
            h = hashBytes(h, &.{@backingInt(std.meta.activeTag(paint.*))});
            switch (paint.*) {
                .mesh_fill => |mesh| {
                    h = hashBytes(h, bits(mesh.vertices));
                    h = hashBytes(h, bits(mesh.triangles));
                },
                inline else => |ramp| {
                    h = hashBytes(h, bits(&ramp.start));
                    h = hashBytes(h, bits(&ramp.end));
                    h = hashBytes(h, bits(ramp.colors));
                },
            }
        }
        if (value.fill) |*fill| h = hashBytes(h, bits(fill));
        if (value.pen) |*pen| {
            h = hashBytes(h, bits(&pen.color));
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
        if ((a.gradient != null) != (b.gradient != null)) return false;
        if (a.gradient) |paint| {
            const other = b.gradient.?;
            if (std.meta.activeTag(paint.*) != std.meta.activeTag(other.*)) return false;
            switch (paint.*) {
                .mesh_fill => |mesh| if (!std.mem.eql(u8, bits(mesh.vertices), bits(other.mesh_fill.vertices)) or !std.mem.eql(u8, bits(mesh.triangles), bits(other.mesh_fill.triangles))) return false,
                inline else => |ramp, tag| {
                    const next = @field(other.*, @tagName(tag));
                    if (!std.mem.eql(u8, bits(&ramp.start), bits(&next.start)) or !std.mem.eql(u8, bits(&ramp.end), bits(&next.end)) or !std.mem.eql(u8, bits(ramp.colors), bits(next.colors))) return false;
                },
            }
        }
        if (a.fill_rule != b.fill_rule or (a.fill != null) != (b.fill != null) or (a.pen != null) != (b.pen != null)) return false;
        if (a.fill) |*fill| if (!std.mem.eql(u8, bits(fill), bits(&b.fill.?))) return false;
        if (a.pen) |*pen| {
            const other = &b.pen.?;
            if (pen.cap != other.cap or pen.join != other.join or (pen.nib != null) != (other.nib != null)) return false;
            if (!std.mem.eql(u8, bits(&pen.color), bits(&other.color))) return false;
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

fn bits(value: anytype) []const u8 {
    const pointer = @typeInfo(@TypeOf(value)).pointer;
    const T = pointer.child;
    comptime {
        if (@typeInfo(T) == .@"struct") {
            var size: usize = 0;
            for (@typeInfo(T).@"struct".field_types) |Field| {
                std.debug.assert(@typeInfo(Field) == .float);
                size += @sizeOf(Field);
            }
            std.debug.assert(size == @sizeOf(T));
        } else std.debug.assert(@bitSizeOf(T) == @sizeOf(T) * 8);
    }
    return if (pointer.size == .slice) std.mem.sliceAsBytes(value) else std.mem.asBytes(value);
}

fn poolExercise(allocator: std.mem.Allocator) !void {
    var pool = Pool.init(allocator);
    defer pool.deinit();
    var dash = [_]f64{ 1, 2 };
    var vertices = [_]g.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    var colors = [_]Color{ .black, .{ .r = 1 } };
    var style: Style = .{ .fill = .black, .gradient = &.{ .radial_fill = .{ .start = .zero, .end = .{ .x = 1, .y = 0 }, .colors = &colors } }, .pen = .{ .dash = &dash, .nib = .{ .polygon = &vertices } } };
    const saved = try pool.intern(&style);
    try std.testing.expect(saved == try pool.intern(&style));
    var other = Pool.init(allocator);
    defer other.deinit();
    const independent = try other.intern(saved);
    try std.testing.expect(saved != independent);
    try std.testing.expect(ValueContext.eql(.{}, saved, independent));
    try std.testing.expect(saved == try pool.intern(independent));
    dash[0] = 3;
    vertices[0].x = -1;
    colors[0].r = 0.5;
    try std.testing.expectEqual(Color.black, saved.gradient.?.radial_fill.colors[0]);
    try std.testing.expectEqual(@as(f64, 1), saved.pen.?.dash[0]);
    try std.testing.expectEqual(@as(f64, 0), saved.pen.?.nib.?.polygon[0].x);
    try std.testing.expect(saved != try pool.intern(&style));
    for (0..20) |index| {
        style.pen.?.width = @floatFromInt(index);
        const stored = try pool.intern(&style);
        try std.testing.expect(ValueContext.eql(.{}, &style, stored));
        try std.testing.expectEqual(ValueContext.hash(.{}, &style), ValueContext.hash(.{}, stored));
    }
    style = saved.*;
    style.pen.?.dash_phase = -0.0;
    try std.testing.expect(saved != try pool.intern(&style));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast((try pool.intern(&style)).pen.?.dash_phase)));

    var keys = [_]Motion.Key{ .{ .t = 0, .value = 2 }, .{ .t = 0.5, .value = 14 }, .{ .t = 1, .value = 2 } };
    const pressure: Style = .{ .pen = .{ .motion = &.{ .tracks = &.{.{ .kind = .scale, .first = 0, .len = 3 }}, .keys = &keys } } };
    const first_profile = try pool.intern(&pressure);
    try std.testing.expect(first_profile.pen.?.motion.? != pressure.pen.?.motion.?);
    try std.testing.expect(first_profile == try pool.intern(&pressure));
    keys[1].value = 8;
    try std.testing.expect(first_profile != try pool.intern(&pressure));
    try std.testing.expectEqual(@as(f64, 14), first_profile.pen.?.motion.?.keys[1].value);

    var mesh_vertices = [_]Gradient.Mesh.Vertex{
        .{ .x = 0, .y = 0, .r = 1, .g = 0, .b = 0 },
        .{ .x = 1, .y = 0, .r = 0, .g = 1, .b = 0 },
        .{ .x = 0, .y = 1, .r = 0, .g = 0, .b = 1 },
    };
    var triangles = [_][3]u32{.{ 0, 1, 2 }};
    const mesh_style: Style = .{ .fill = .black, .gradient = &.{ .mesh_fill = .{ .vertices = &mesh_vertices, .triangles = &triangles } } };
    const mesh = try pool.intern(&mesh_style);
    try std.testing.expect(mesh == try pool.intern(&mesh_style));
    mesh_vertices[0].r = 0;
    triangles[0][2] = 1;
    try std.testing.expectEqual(@as(f64, 1), mesh.gradient.?.mesh_fill.vertices[0].r);
    try std.testing.expectEqual(@as(u32, 2), mesh.gradient.?.mesh_fill.triangles[0][2]);
    try std.testing.expect(mesh != try pool.intern(&mesh_style));
}

test "immutable styles share equal values own slices and preserve float bits across OOM" {
    try poolExercise(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, poolExercise, .{});
}

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

test "unique style edits do not retain history or allocate new entries" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var pool = Pool.init(failing.allocator());
    defer pool.deinit();
    var value = try pool.intern(&.{ .fill = .black });
    failing.fail_index = failing.alloc_index;
    const bytes = pool.allocatedBytes();
    for (1..10001) |i| {
        value = try pool.replace(value, &.{ .fill = .{ .r = @as(f64, @floatFromInt(i)) / 10001 } });
        try t.expectEqual(@as(u32, 1), pool.entries.count());
        try t.expectEqual(bytes, pool.allocatedBytes());
    }
    pool.release(value);
}
