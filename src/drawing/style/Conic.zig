//! A scalar field constant along each ray from `center`, colored by
//! stops. Each of `points` lies on its own ray, and each ray turns less
//! than half a turn from the one before it. Two consecutive points span a
//! wedge: along the chord between them the field is linear in `values`,
//! and each ray through the wedge carries the value where it crosses the
//! chord. Two consecutive points on one ray make a step. Only the wedges
//! are painted, later ones over earlier ones.
//!
//! Outputs draw the wedges from the center, as patches in a PDF patch
//! mesh and as triangles elsewhere, adding at most `tolerance` to the
//! field (see `conic.zig`).
const std = @import("std");
const g = @import("../geometry.zig");
const drawing_style = @import("../style.zig");
const bits = drawing_style.bits;
const Color = drawing_style.Color;
const Stops = drawing_style.Gradient.Stops;
const Conic = @This();

center: g.Point,
points: []const g.Point,
values: []const f64,
stops: Stops,
tolerance: f64,

pub fn validate(self: Conic) error{ InvalidStyle, InvalidColor, NonFinite }!void {
    if (self.points.len < 2 or self.points.len != self.values.len) return error.InvalidStyle;
    if (!std.math.isFinite(self.tolerance) or !(self.tolerance > 0)) return error.InvalidStyle;
    try self.stops.validate();
    if (!self.center.isFinite()) return error.NonFinite;
    for (self.points, self.values) |point, value| {
        if (!point.isFinite() or !std.math.isFinite(value)) return error.NonFinite;
        if (point.eql(self.center)) return error.InvalidStyle;
    }
    for (self.points[0 .. self.points.len - 1], self.points[1..]) |a, b| {
        const from = a.sub(self.center);
        const to = b.sub(self.center);
        // Rays half a turn apart span no wedge.
        if (from.cross(to) == 0 and from.dot(to) < 0) return error.InvalidStyle;
    }
}

pub fn hash(self: Conic, seed: u64) u64 {
    const hashBytes = std.hash.Wyhash.hash;
    var h = hashBytes(seed, bits(&self.center));
    h = hashBytes(h, bits(self.points));
    h = hashBytes(h, bits(self.values));
    h = hashBytes(h, bits(self.stops.levels));
    h = hashBytes(h, bits(self.stops.colors));
    return hashBytes(h, bits(&self.tolerance));
}

pub fn eql(a: Conic, b: Conic) bool {
    return std.mem.eql(u8, bits(&a.center), bits(&b.center)) and std.mem.eql(u8, bits(a.points), bits(b.points)) and
        std.mem.eql(u8, bits(a.values), bits(b.values)) and std.mem.eql(u8, bits(a.stops.levels), bits(b.stops.levels)) and
        std.mem.eql(u8, bits(a.stops.colors), bits(b.stops.colors)) and std.mem.eql(u8, bits(&a.tolerance), bits(&b.tolerance));
}

pub fn dupe(self: Conic, allocator: std.mem.Allocator) !Conic {
    const points = try allocator.dupe(g.Point, self.points);
    errdefer allocator.free(points);
    const values = try allocator.dupe(f64, self.values);
    errdefer allocator.free(values);
    const levels = try allocator.dupe(f64, self.stops.levels);
    errdefer allocator.free(levels);
    const colors = try allocator.dupe(Color, self.stops.colors);
    return .{ .center = self.center, .points = points, .values = values, .stops = .{ .levels = levels, .colors = colors }, .tolerance = self.tolerance };
}

pub fn free(self: Conic, allocator: std.mem.Allocator) void {
    allocator.free(self.points);
    allocator.free(self.values);
    allocator.free(self.stops.levels);
    allocator.free(self.stops.colors);
}
