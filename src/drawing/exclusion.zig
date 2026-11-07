//! Resolve parent-space exclusions against the current extent of the visible
//! child. The retained objects and native text stay intact. Snapshots own
//! only the extra clip geometry, sharing all original scene geometry.
const std = @import("std");
const DisplayList = @import("DisplayList.zig");
const Path = @import("path/Path.zig");
const regions = @import("region/root.zig");

pub const Scope = struct { start: usize, stop: usize, hole: []const Path.Segment };

pub fn borrowed(allocator: std.mem.Allocator, segments: []const Path.Segment) Path {
    return .{ .allocator = allocator, .segments = .fromOwnedSlice(@constCast(segments)) };
}

pub fn resolve(picture: *DisplayList, ids: []const u64, scopes: []const Scope, generated: *std.ArrayList(Path.Segment), labels: anytype) !void {
    if (scopes.len == 0) return;
    const allocator = picture.storage.allocator;
    const bank = std.math.cast(u32, picture.sources.items.len + 1) orelse return error.TooManyObjects;
    try picture.sources.append(allocator, .{});
    // Innermost scopes close first, so bounds can use their resolved clips.
    for (scopes) |scope| {
        const hole = borrowed(allocator, scope.hole);
        const hole_box = hole.bounds() orelse continue;
        if (ids.len != 0) {
            for (ids[scope.start + 1 .. scope.stop]) |id| if (id != 0) return error.AnimatedExclusion;
        }
        var content = picture.*;
        content.commands.items = picture.commands.items[scope.start + 1 .. scope.stop];
        const bounds = (try content.boundsWith(labels)) orelse continue;
        if (!bounds.overlaps(hole_box, 0)) continue;
        const domain = bounds.expanded(0.001);
        var rectangle = Path.init(allocator);
        defer rectangle.deinit();
        try rectangle.moveTo(domain.min);
        try rectangle.lineTo(.{ .x = domain.max.x, .y = domain.min.y });
        try rectangle.lineTo(domain.max);
        try rectangle.lineTo(.{ .x = domain.min.x, .y = domain.max.y });
        try rectangle.close();
        var keep = try regions.combine(allocator, rectangle, hole, .difference, .{});
        defer keep.deinit();
        // SVG and PDF both honor an explicit closed, zero-area contour.
        // A clip with no drawing operators can be dropped by a PDF exporter.
        if (keep.segments.items.len == 0) {
            try keep.moveTo(domain.min);
            try keep.lineTo(domain.min);
            try keep.close();
        }
        const first = generated.items.len;
        try generated.appendSlice(allocator, keep.segments.items);
        picture.sources.items[bank - 1].segments = generated.items;
        picture.commands.items[scope.start].push.clip = .{ .first = first, .count = keep.segments.items.len, .source = bank };
    }
}
