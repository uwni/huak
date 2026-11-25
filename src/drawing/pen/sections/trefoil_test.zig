//! Tests of the stroke coverage of a millimetre trefoil.
const std = @import("std");
const g = @import("../../geometry.zig");
const Path = @import("../../path/Path.zig");
const DisplayList = @import("../../DisplayList.zig");
const outline = @import("../outline.zig");
const region = @import("../../region/root.zig");
const Allocator = std.mem.Allocator;
const sections = @import("../sections.zig");

test "source sections preserve actual millimetre trefoil stroke coverage" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mm = 72.0 / 25.4;
    const tolerance = 0.001;
    const root3 = @sqrt(@as(f64, 3));
    const first: g.Point = .{ .x = 60, .y = 90 };
    const second: g.Point = .{ .x = 60 - root3 * 20, .y = 30 };
    const third: g.Point = .{ .x = 60 + root3 * 20, .y = 30 };
    var source = Path.init(a);
    try source.moveTo(first.scale(mm));
    try source.cubicTo(first.add(.{ .x = 44, .y = 0 }).scale(mm), second.add(.{ .x = 22, .y = -root3 * 22 }).scale(mm), second.scale(mm));
    try source.cubicTo(second.add(.{ .x = -22, .y = root3 * 22 }).scale(mm), third.add(.{ .x = 22, .y = root3 * 22 }).scale(mm), third.scale(mm));
    try source.cubicTo(third.add(.{ .x = -22, .y = -root3 * 22 }).scale(mm), first.add(.{ .x = -44, .y = 0 }).scale(mm), first.scale(mm));
    try source.close();
    const hits = try @import("../../path/crossings.zig").find(a, &.{source}, .{ .tolerance = tolerance });
    try t.expectEqual(@as(usize, 3), hits.len);
    var visits: [6]f64 = undefined;
    for (hits, 0..) |hit, i| {
        visits[2 * i] = hit.first.time;
        visits[2 * i + 1] = hit.second.time;
    }
    std.mem.sort(f64, &visits, {}, std.sort.asc(f64));
    var cuts: [7]f64 = undefined;
    cuts[0] = 0;
    cuts[6] = 3;
    for (0..5) |i| {
        const middle = (visits[i] + visits[i + 1]) / 2;
        const node = @floor(middle) + @as(f64, if (middle - @floor(middle) > 0.5) 1 else 0);
        cuts[i + 1] = if (visits[i] < node and node < visits[i + 1]) node else middle;
    }
    var ranges: [6]sections.Range = undefined;
    for (&ranges, 0..) |*range, i| range.* = .{ .contour = 0, .begin = cuts[i], .end = cuts[i + 1] };
    const paint: DisplayList.Pen = .{ .width = 3 * mm, .cap = .round, .join = .round };
    const raw = try outline.strokeOutline(a, .{ .ellipse = g.Transform.scaling(paint.width, paint.width) }, source, .{ .tolerance = tolerance, .cap = .round, .join = .round });
    const full = try region.combine(a, raw, Path.init(a), .unite, .{ .tolerance = tolerance });
    const parts = try sections.extract(a, source, paint, &ranges, .{ .tolerance = tolerance });
    var combined = Path.init(a);
    for (parts) |part| combined = try region.combine(a, combined, part, .unite, .{ .tolerance = tolerance });
    // This oracle only uses bounded path subdivision and half-open line rays;
    // it does not call the Boolean kernel's curve roots or face windings.
    const Probe = struct {
        fn flat(allocator: Allocator, path: Path) !Path {
            return @import("../../path/flatten.zig").flatten(allocator, path, .{ .tolerance = 1e-5, .length_tolerance = 1e-5, .max_segments = 1048576, .max_depth = 32 });
        }
        fn inside(path: Path, p: g.Point, margin: f64) ?bool {
            var winding: i32 = 0;
            var current = g.Point.zero;
            var start = g.Point.zero;
            for (path.segments.items) |segment| {
                const end = switch (segment) {
                    .move => |point| {
                        current = point;
                        start = point;
                        continue;
                    },
                    .line => |point| point,
                    .close => start,
                    .cubic => unreachable,
                };
                const delta = end.sub(current);
                const relative = p.sub(current);
                if (margin > 0) {
                    const length = delta.dot(delta);
                    const along = if (length > 0) std.math.clamp(relative.dot(delta) / length, 0, 1) else 0;
                    const distance = relative.sub(delta.scale(along));
                    if (distance.dot(distance) < margin * margin) return null;
                }
                if (current.y <= p.y and end.y > p.y and delta.cross(relative) > 0) winding += 1;
                if (current.y > p.y and end.y <= p.y and delta.cross(relative) < 0) winding -= 1;
                current = end;
            }
            return winding != 0;
        }
    };
    const raw_flat = try Probe.flat(a, raw);
    const full_flat = try Probe.flat(a, full);
    const union_flat = try Probe.flat(a, combined);
    var part_flats: [6]Path = undefined;
    for (parts, &part_flats) |part, *flat| flat.* = try Probe.flat(a, part);
    var checked: usize = 0;
    for (0..61) |x| for (0..59) |y| {
        const p: g.Point = .{ .x = (2 * @as(f64, @floatFromInt(x)) + 0.123) * mm, .y = (2 * @as(f64, @floatFromInt(y)) + 0.217) * mm };
        const expected = Probe.inside(raw_flat, p, 2 * tolerance) orelse continue;
        checked += 1;
        try t.expectEqual(expected, Probe.inside(full_flat, p, 0).?);
        try t.expectEqual(expected, Probe.inside(union_flat, p, 0).?);
        var covered = false;
        for (part_flats) |part| {
            const inside = Probe.inside(part, p, 0).?;
            try t.expect(expected or !inside);
            covered = covered or inside;
        }
        try t.expectEqual(expected, covered);
    };
    try t.expect(checked > 3500);
    for (0..900) |i| {
        const position = try source.curveAt((@as(f64, @floatFromInt(i)) + 0.371) / 300);
        const center = position.curve.at(position.t);
        const tangent = try position.curve.derivative(position.t).normalized();
        for ([_]f64{ -0.45, -0.2, 0, 0.2, 0.45 }) |offset| {
            const p = center.add((g.Point{ .x = -tangent.y, .y = tangent.x }).scale(offset * paint.width));
            try t.expect(Probe.inside(raw_flat, p, 0).?);
            try t.expect(Probe.inside(union_flat, p, 0).?);
        }
    }
}
