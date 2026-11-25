//! Helpers shared by the region operation tests: a rectangle contour, signed area and the contour count.
const std = @import("std");
const core = @import("drawing");
const Path = core.Path;
const Allocator = std.mem.Allocator;

pub fn testRectangle(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = x, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y });
    try result.lineTo(.{ .x = x + width, .y = y + height });
    try result.lineTo(.{ .x = x, .y = y + height });
    try result.close();
    return result;
}

pub fn area(path: Path) f64 {
    return path.signedArea();
}

pub fn contourCount(path: Path) usize {
    var count: usize = 0;
    for (path.segments.items) |segment| if (segment == .move) {
        count += 1;
    };
    return count;
}
