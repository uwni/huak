//! Binary64 curve Boolean operations and public coordinate-budget accounting.
const std = @import("std");
const Path = @import("../path/Path.zig");
pub const combine = @import("boolean/operation.zig").combine;

pub fn vertexCount(path: Path) !usize {
    var count: usize = 0;
    for (path.segments.items) |segment| count = std.math.add(usize, count, switch (segment) {
        .move, .line => @as(usize, 1),
        .cubic => @as(usize, 3),
        .close => @as(usize, 0),
    }) catch return error.GeometryWorkLimit;
    return count;
}
