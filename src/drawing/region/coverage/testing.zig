//! Fixtures shared by the coverage tests: rectangles, signed area, a flattening containment oracle and extraction of a fixture picture.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const regions = @import("../root.zig");
const Allocator = std.mem.Allocator;
const vectorization = @import("../../outline.zig");
const coverage = @import("../coverage.zig");
const Collection = coverage.Collection;
const collect = coverage.collect;

pub fn rectangle(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    return Path.rectangle(allocator, .{ .x = x, .y = y }, width, height);
}

pub fn area(path: Path) f64 {
    return path.signedArea();
}

pub fn contains(path: Path, point: g.Point) bool {
    // Independent test probes are deliberately away from the boundary. Only
    // this test oracle samples curves; region construction keeps them native.
    for (path.segments.items) |segment| if (segment == .cubic) {
        var flat = @import("../../path/flatten.zig").flatten(std.testing.allocator, path, .{ .tolerance = 1e-8, .length_tolerance = 1e-8, .max_segments = 1048576, .max_depth = 32 }) catch @panic("test reference flattening failed");
        defer flat.deinit();
        return contains(flat, point);
    };
    var winding: i32 = 0;
    var current = g.Point.zero;
    var start = g.Point.zero;
    for (path.segments.items) |segment| {
        const end = switch (segment) {
            .move => |value| {
                current = value;
                start = value;
                continue;
            },
            .line => |value| value,
            .close => start,
            .cubic => unreachable,
        };
        const cross = end.sub(current).cross(point.sub(current));
        if (current.y <= point.y and end.y > point.y and cross > 0) winding += 1;
        if (current.y > point.y and end.y <= point.y and cross < 0) winding -= 1;
        current = end;
    }
    return winding != 0;
}

pub fn extractFixture(allocator: Allocator, source: vectorization.Source, options: regions.Options, resolver: anytype) !Collection {
    // The adapter itself never resolves labels. Tests can supply an already
    // vector picture or exercise the complete vectorization-to-region route.
    if (@TypeOf(resolver) == @TypeOf(null) and source == .picture) return collect(allocator, source.picture, options);
    var vector = try vectorization.extract(allocator, source, resolver);
    defer vector.deinit();
    return collect(allocator, &vector, options);
}
