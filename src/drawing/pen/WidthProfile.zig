//! Full circular stroke widths at fractions of each contour's arc length.
const std = @import("std");
const WidthProfile = @This();

positions: []const f64,
widths: []const f64,

pub fn maxSlope(self: *const WidthProfile) error{InvalidProfile}!f64 {
    if (self.positions.len < 2 or self.positions.len != self.widths.len) return error.InvalidProfile;
    if (self.positions[0] != 0 or self.positions[self.positions.len - 1] != 1) return error.InvalidProfile;
    var slope: f64 = 0;
    for (self.positions, self.widths, 0..) |position, width, index| {
        if (!std.math.isFinite(position) or !std.math.isFinite(width) or width < 0) return error.InvalidProfile;
        if (index == 0) continue;
        if (position <= self.positions[index - 1]) return error.InvalidProfile;
        const change = @abs(width - self.widths[index - 1]) / (position - self.positions[index - 1]);
        if (!std.math.isFinite(change)) return error.InvalidProfile;
        slope = @max(slope, change);
    }
    return slope;
}

pub fn clone(self: *const WidthProfile, allocator: std.mem.Allocator) !*const WidthProfile {
    const result = try allocator.create(WidthProfile);
    errdefer allocator.destroy(result);
    const positions = try allocator.dupe(f64, self.positions);
    errdefer allocator.free(positions);
    result.* = .{ .positions = positions, .widths = try allocator.dupe(f64, self.widths) };
    return result;
}

/// Release a profile created by clone, including its control points.
pub fn destroy(self: *const WidthProfile, allocator: std.mem.Allocator) void {
    allocator.free(self.positions);
    allocator.free(self.widths);
    allocator.destroy(self);
}
