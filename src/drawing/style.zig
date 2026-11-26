//! Shared drawing styles with copy-on-write updates inside each picture.
const std = @import("std");
const g = @import("geometry.zig");
const Nib = @import("pen/nib.zig").Nib;
const Motion = @import("pen/Motion.zig");
pub const Pool = @import("style/Pool.zig");

pub const Color = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 1,
    pub const black: Color = .{};
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    /// Outputs write each channel in 8 bits, as a level from 0 to this.
    pub const max_level = 255;
    /// Half a step of the 8-bit channels outputs write: how far a color that
    /// stands in for another may stray from it.
    pub const tolerance = 0.5 / @as(f64, max_level);
    /// The level outputs write for a channel, from 0 to `max_level`.
    pub fn level(channel: f64) f64 {
        return @round(channel * max_level);
    }
    pub fn valid(self: Color) bool {
        inline for (.{ "r", "g", "b", "a" }) |field| {
            const value = @field(self, field);
            if (!std.math.isFinite(value) or value < 0 or value > 1) return false;
        }
        return true;
    }
    pub fn lerp(self: Color, other: Color, t: f64) Color {
        return .{
            .r = self.r + (other.r - self.r) * t,
            .g = self.g + (other.g - self.g) * t,
            .b = self.b + (other.b - self.b) * t,
            .a = self.a + (other.a - self.a) * t,
        };
    }
    pub fn maxDiff(self: Color, other: Color) f64 {
        return @max(@max(@abs(self.r - other.r), @abs(self.g - other.g)), @max(@abs(self.b - other.b), @abs(self.a - other.a)));
    }
};
const strokes = @import("pen/stroke.zig");
pub const Cap = strokes.Cap;
pub const Join = strokes.Join;
pub const FillRule = enum { nonzero, evenodd };

/// What paints a fill or a stroke: one color, or a gradient that varies
/// over the plane in the path's own coordinates. A fill and a stroke each
/// have one.
pub const Paint = union(enum) {
    color: Color,
    gradient: *const Gradient,

    pub const black: Paint = .{ .color = .black };

    /// The colors it paints: its color, or the gradient's.
    pub fn palette(self: *const Paint) []const Color {
        return switch (self.*) {
            .color => |*color| color[0..1],
            .gradient => |gradient| gradient.palette(),
        };
    }

    pub fn hasInk(self: *const Paint) bool {
        for (self.palette()) |color| if (color.a > 0) return true;
        return false;
    }

    /// Whether every color it paints is opaque.
    pub fn isOpaque(self: *const Paint) bool {
        return allOpaque(self.palette());
    }

    /// The color an interface that also takes a gradient still asks for:
    /// its color, or the gradient's first.
    pub fn fallback(self: *const Paint) Color {
        return self.palette()[0];
    }

    /// The color it paints everywhere, if it is one color.
    pub fn solid(self: Paint) ?Color {
        return switch (self) {
            .color => |color| color,
            .gradient => null,
        };
    }

    pub fn hash(self: *const Paint, seed: u64) u64 {
        return switch (self.*) {
            .color => |*color| std.hash.Wyhash.hash(seed, bits(color)),
            .gradient => |gradient| gradient.hash(seed +% 1),
        };
    }

    pub fn eql(a: *const Paint, b: *const Paint) bool {
        return switch (a.*) {
            .color => |*color| b.* == .color and std.mem.eql(u8, bits(color), bits(&b.color)),
            .gradient => |gradient| b.* == .gradient and gradient.eql(b.gradient),
        };
    }

    /// An owned copy, whose gradient arrays come from `store` when it holds
    /// them (see `Gradient.clone`).
    pub fn clone(self: Paint, allocator: std.mem.Allocator, store: ?*Gradient.Store) !Paint {
        const gradient = switch (self) {
            .color => return self,
            .gradient => |gradient| gradient,
        };
        const owned = try allocator.create(Gradient);
        errdefer allocator.destroy(owned);
        owned.* = try gradient.clone(allocator, store);
        return .{ .gradient = owned };
    }

    /// Releases a copy `clone` made.
    pub fn deinit(self: Paint, allocator: std.mem.Allocator) void {
        switch (self) {
            .color => {},
            .gradient => |gradient| {
                gradient.deinit(allocator);
                allocator.destroy(gradient);
            },
        }
    }

    pub fn dataSize(self: Paint) usize {
        return switch (self) {
            .color => 0,
            .gradient => |gradient| @sizeOf(Gradient) + gradient.dataSize(),
        };
    }
};

pub const Pen = struct {
    paint: Paint = .black,
    width: f64 = 1,
    cap: Cap = strokes.default_cap,
    join: Join = strokes.default_join,
    miter_limit: f64 = strokes.default_miter_limit,
    /// Borrowed while drawing; DisplayList takes an owned snapshot.
    dash: []const f64 = &.{},
    dash_phase: f64 = 0,
    /// Explicit physical nib, independent of the centerline and width field.
    nib: ?Nib = null,
    /// Borrowed from the caller; the style pool retains an immutable snapshot.
    motion: ?*const Motion = null,

    /// Whether a nib or a motion shapes its stroke, rather than its width.
    pub fn needsGeometry(self: *const Pen) bool {
        return self.nib != null or self.motion != null;
    }

    /// Whether outputs draw its stroke from the shape the geometry kernel
    /// resolves, not as a native stroke: when a nib or a motion shapes it,
    /// and when a mesh paints it, since a mesh paints only as a fill.
    pub fn resolvesStroke(self: *const Pen) bool {
        return self.needsGeometry() or switch (self.paint) {
            .color => false,
            .gradient => |gradient| gradient.isMesh(),
        };
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
    /// Colors along the line from start to end, constant across it.
    linear: Ramp,
    /// Colors from the center at `start` out to the radius |end - start|.
    radial: Ramp,
    /// A scalar field on tensor-product Bézier patches through color stops.
    patches: Patches,
    /// A scalar field around a center through color stops (see `Conic`).
    fan: Conic,
    color_patches: ColorPatches,

    /// Empty `offsets` space the colors evenly; otherwise each color has a
    /// position from 0 to 1, in non-decreasing order.
    pub const Ramp = struct {
        start: g.Point,
        end: g.Point,
        colors: []const Color,
        offsets: []const f64 = &.{},

        pub fn validate(self: Ramp) error{ InvalidStyle, InvalidColor }!void {
            if (!self.start.isFinite() or !self.end.isFinite() or self.start.eql(self.end) or self.colors.len < 2) return error.InvalidStyle;
            for (self.colors) |color| if (!color.valid()) return error.InvalidColor;
            if (self.offsets.len == 0) return;
            if (self.offsets.len != self.colors.len or self.offsets[0] != 0 or self.offsets[self.offsets.len - 1] != 1) return error.InvalidStyle;
            for (self.offsets[0 .. self.offsets.len - 1], self.offsets[1..]) |previous, next| {
                if (!(previous <= next)) return error.InvalidStyle;
            }
        }
    };

    /// Colors at strictly increasing finite levels of a scalar field, linear
    /// between levels. Values beyond the first or last level keep its color.
    pub const Stops = struct {
        levels: []const f64,
        colors: []const Color,

        pub fn validate(self: Stops) error{ InvalidStyle, InvalidColor }!void {
            if (self.levels.len == 0 or self.levels.len != self.colors.len) return error.InvalidStyle;
            for (self.levels, self.colors, 0..) |level, color, index| {
                if (!std.math.isFinite(level)) return error.InvalidStyle;
                if (!color.valid()) return error.InvalidColor;
                if (index != 0 and !(self.levels[index - 1] < level)) return error.InvalidStyle;
            }
        }

        pub fn isOpaque(self: Stops) bool {
            return allOpaque(self.colors);
        }

        /// Whether they paint any color on a field with these
        /// coefficients, which a field on a patch stays within.
        pub fn paints(self: Stops, coefficients: []const f64) bool {
            const low = std.mem.min(f64, coefficients);
            const high = std.mem.max(f64, coefficients);
            if (self.at(low).a != 0 or self.at(high).a != 0) return true;
            for (self.levels, self.colors) |level, color| {
                if (level > low and level < high and color.a != 0) return true;
            }
            return false;
        }

        pub fn at(self: Stops, value: f64) Color {
            const next = std.sort.partitionPoint(f64, self.levels, value, struct {
                fn below(target: f64, level: f64) bool {
                    return level <= target;
                }
            }.below);
            if (next == 0) return self.colors[0];
            if (next == self.levels.len) return self.colors[next - 1];
            const low = self.levels[next - 1];
            const fraction = (value - low) / (self.levels[next] - low);
            return self.colors[next - 1].lerp(self.colors[next], fraction);
        }
    };

    pub const Patches = @import("style/Patches.zig");

    pub const Conic = @import("style/Conic.zig");

    pub const ColorPatches = @import("style/ColorPatches.zig");

    pub const Store = @import("style/Store.zig");

    pub fn clone(self: Gradient, allocator: std.mem.Allocator, store: ?*Store) !Gradient {
        switch (self) {
            .patches => |patches| return .{ .patches = try patches.pooled(allocator, store) },
            .fan => |conic| return .{ .fan = try conic.dupe(allocator) },
            .color_patches => |patches| return .{ .color_patches = try patches.pooled(allocator, store) },
            inline .linear, .radial => |ramp, tag| {
                const colors = try allocator.dupe(Color, ramp.colors);
                errdefer allocator.free(colors);
                const offsets = try allocator.dupe(f64, ramp.offsets);
                return @unionInit(Gradient, @tagName(tag), Ramp{ .start = ramp.start, .end = ramp.end, .colors = colors, .offsets = offsets });
            },
        }
    }

    /// Only pooled values, made by `clone`, are released.
    pub fn deinit(self: Gradient, allocator: std.mem.Allocator) void {
        switch (self) {
            .patches => |patches| patches.shared.?.release(),
            .fan => |conic| conic.free(allocator),
            .color_patches => |patches| patches.shared.?.release(),
            .linear, .radial => |ramp| {
                allocator.free(ramp.colors);
                allocator.free(ramp.offsets);
            },
        }
    }

    pub fn dataSize(self: Gradient) usize {
        return switch (self) {
            .patches => |patches| patches.points.len * (@sizeOf([16]g.Point) + @sizeOf([16]f64)) + patches.stops.levels.len * (@sizeOf(f64) + @sizeOf(Color)),
            .fan => |conic| conic.points.len * (@sizeOf(g.Point) + @sizeOf(f64)) + conic.stops.levels.len * (@sizeOf(f64) + @sizeOf(Color)),
            .color_patches => |patches| patches.points.len * (@sizeOf([16]g.Point) + @sizeOf([4]Color)),
            .linear, .radial => |ramp| ramp.colors.len * @sizeOf(Color) + ramp.offsets.len * @sizeOf(f64),
        };
    }

    /// The colors it interpolates between: its stops, or its patches'
    /// corners.
    pub fn palette(self: Gradient) []const Color {
        return switch (self) {
            .patches => |patches| patches.stops.colors,
            .fan => |conic| conic.stops.colors,
            .color_patches => |patches| std.mem.bytesAsSlice(Color, std.mem.sliceAsBytes(patches.colors)),
            .linear, .radial => |ramp| ramp.colors,
        };
    }

    pub fn hasInk(self: Gradient) bool {
        for (self.palette()) |color| if (color.a > 0) return true;
        return false;
    }

    /// Whether every color it paints is opaque.
    pub fn isOpaque(self: Gradient) bool {
        return allOpaque(self.palette());
    }

    /// Whether it is a mesh of patches or wedges, which paints only them,
    /// not all of what it fills or strokes, and which outputs draw only as a
    /// fill: a stroke painted with a mesh is drawn as its footprint.
    pub fn isMesh(self: Gradient) bool {
        return switch (self) {
            .patches, .fan, .color_patches => true,
            .linear, .radial => false,
        };
    }

    /// Hashes the kind and the active payload only.
    pub fn hash(self: *const Gradient, seed: u64) u64 {
        const hashBytes = std.hash.Wyhash.hash;
        var h = hashBytes(seed, &.{@backingInt(std.meta.activeTag(self.*))});
        switch (self.*) {
            .patches => |patches| {
                const digest = patches.digest();
                h = hashBytes(h, std.mem.asBytes(&digest));
            },
            .fan => |conic| h = conic.hash(h),
            .color_patches => |patches| {
                const digest = patches.digest();
                h = hashBytes(h, std.mem.asBytes(&digest));
            },
            .linear, .radial => |ramp| {
                h = hashBytes(h, bits(&ramp.start));
                h = hashBytes(h, bits(&ramp.end));
                h = hashBytes(h, bits(ramp.colors));
                h = hashBytes(h, bits(ramp.offsets));
            },
        }
        return h;
    }

    pub fn eql(a: *const Gradient, b: *const Gradient) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .patches => |patches| patches.eql(b.patches),
            .fan => |conic| conic.eql(b.fan),
            .color_patches => |patches| patches.eql(b.color_patches),
            inline .linear, .radial => |ramp, tag| {
                const other = @field(b.*, @tagName(tag));
                return std.mem.eql(u8, bits(&ramp.start), bits(&other.start)) and std.mem.eql(u8, bits(&ramp.end), bits(&other.end)) and
                    std.mem.eql(u8, bits(ramp.colors), bits(other.colors)) and std.mem.eql(u8, bits(ramp.offsets), bits(other.offsets));
            },
        };
    }
};

fn allOpaque(colors: []const Color) bool {
    for (colors) |color| if (color.a != 1) return false;
    return true;
}

pub const Style = struct {
    fill: ?Paint = null,
    pen: ?Pen = null,
    fill_rule: FillRule = .nonzero,

    pub const Component = enum { fill, stroke };

    /// What paints the component, if the style has it.
    pub fn paint(self: *const Style, component: Component) ?*const Paint {
        return switch (component) {
            .fill => if (self.fill) |*fill| fill else null,
            .stroke => if (self.pen) |*pen| &pen.paint else null,
        };
    }

    /// The component's gradient, if a gradient paints it.
    pub fn gradientFor(self: *const Style, component: Component) ?*const Gradient {
        const found = self.paint(component) orelse return null;
        return switch (found.*) {
            .color => null,
            .gradient => |gradient| gradient,
        };
    }

    pub fn hasInk(self: *const Style, component: Component) bool {
        const found = self.paint(component) orelse return false;
        return found.hasInk();
    }
};

pub fn bits(value: anytype) []const u8 {
    const pointer = @typeInfo(@TypeOf(value)).pointer;
    comptime std.debug.assert(dense(pointer.child));
    return if (pointer.size == .slice) std.mem.sliceAsBytes(value) else std.mem.asBytes(value);
}

/// Every byte of a T belongs to a value: no padding or unused bits.
fn dense(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .array => |array| return dense(array.child),
        .@"struct" => |info| {
            var size: usize = 0;
            for (info.field_types) |Field| {
                if (@typeInfo(Field) != .float) return false;
                size += @sizeOf(Field);
            }
            return size == @sizeOf(T);
        },
        else => return @bitSizeOf(T) == @sizeOf(T) * 8,
    }
}

test {
    _ = @import("style/Pool.zig");
    _ = @import("style/pool_test.zig");
}
