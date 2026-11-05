//! Huak drawing policy and submission through libtypst's native scene API.
const std = @import("std");
const DisplayList = @import("../../drawing/DisplayList.zig");
const typst = @import("libtypst");
const scenes = @import("scene.zig");

pub const SubmitOptions = scenes.Options;

/// Drawing defaults, grouping, IDs and physical-nib expansion belong to huak.
/// Native calls submit complete paths and whole scene-item arrays.
pub fn submit(allocator: std.mem.Allocator, library: *typst.Library, picture: *const DisplayList, width: f64, height: f64, options: SubmitOptions) !typst.Document {
    library.clearError();
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0) return error.InvalidCanvas;
    if (options.object_ids) |ids| {
        if (ids.len != picture.commands.items.len) return error.InvalidObjectIds;
        var seen: std.AutoHashMap(u64, void) = .init(allocator);
        defer seen.deinit();
        for (ids, picture.commands.items) |id, *command| {
            if (id == 0) continue;
            if (id == std.math.maxInt(u64) or command.* == .pop or (try seen.getOrPut(id)).found_existing) return error.InvalidObjectIds;
        }
    }
    _ = try picture.bounds();
    return scenes.document(allocator, library, picture, .{ .x = width, .y = height }, options);
}

test {
    _ = @import("pen.zig");
    _ = scenes;
}
