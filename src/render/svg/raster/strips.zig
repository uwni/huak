//! Spatial strip binning for Bézier patch meshes, preserving exact painter's
//! order within every horizontal strip.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");

/// Maps horizontal strips to the sorted indices of patches overlapping them.
pub const StripIndex = struct {
    offsets: []u32,
    indices: []u32,

    pub fn build(
        allocator: std.mem.Allocator,
        nets: []const [16]g.Point,
        box: g.BBox,
        sub_w: u32,
        sub_h: u32,
        strip_sub_h: u32,
        strip_count: usize,
    ) !StripIndex {
        const scale_x = @as(f64, @floatFromInt(sub_w)) / box.width();
        const scale_y = @as(f64, @floatFromInt(sub_h)) / box.height();
        const max_x: f64 = @floatFromInt(sub_w);
        const max_y: f64 = @floatFromInt(sub_h);

        const offsets = try allocator.alloc(u32, strip_count + 1);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);

        for (nets) |*net| {
            const span = patchStripSpan(net, box, scale_x, scale_y, max_x, max_y, strip_sub_h, strip_count) orelse continue;
            for (span[0]..span[1] + 1) |s| offsets[s + 1] += 1;
        }
        for (0..strip_count) |s| offsets[s + 1] += offsets[s];

        const indices = try allocator.alloc(u32, offsets[strip_count]);
        errdefer allocator.free(indices);
        const cursors = try allocator.alloc(u32, strip_count);
        defer allocator.free(cursors);
        @memcpy(cursors, offsets[0..strip_count]);

        for (nets, 0..) |*net, idx| {
            const span = patchStripSpan(net, box, scale_x, scale_y, max_x, max_y, strip_sub_h, strip_count) orelse continue;
            for (span[0]..span[1] + 1) |s| {
                indices[cursors[s]] = @intCast(idx);
                cursors[s] += 1;
            }
        }
        return .{ .offsets = offsets, .indices = indices };
    }

    pub fn deinit(self: StripIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.indices);
    }

    pub fn slice(self: *const StripIndex, strip_idx: usize) []const u32 {
        return self.indices[self.offsets[strip_idx]..self.offsets[strip_idx + 1]];
    }
};

fn patchStripSpan(
    net: *const [16]g.Point,
    box: g.BBox,
    scale_x: f64,
    scale_y: f64,
    max_x: f64,
    max_y: f64,
    strip_sub_h: u32,
    strip_count: usize,
) ?[2]usize {
    var min_x = std.math.inf(f64);
    var max_px = -std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_py = -std.math.inf(f64);
    for (net) |pt| {
        const sx = (pt.x - box.min.x) * scale_x;
        const sy = (box.max.y - pt.y) * scale_y;
        min_x = @min(min_x, sx);
        max_px = @max(max_px, sx);
        min_y = @min(min_y, sy);
        max_py = @max(max_py, sy);
    }
    if (max_px < 0 or min_x >= max_x or max_py < 0 or min_y >= max_y) return null;
    const lo_y: u32 = if (min_y <= 0) 0 else @min(@as(u32, @intFromFloat(@floor(min_y))), @as(u32, @intCast(strip_count)) * strip_sub_h - 1);
    const hi_y: u32 = if (max_py >= max_y) @as(u32, @intFromFloat(max_y)) - 1 else @as(u32, @intFromFloat(@floor(max_py)));
    const s0 = @min(strip_count - 1, lo_y / strip_sub_h);
    const s1 = @min(strip_count - 1, hi_y / strip_sub_h);
    return .{ s0, s1 };
}
