//! Cutting a path by segment time or by a rectangle, keeping cubics and knot directions.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Path = @import("Path.zig");
const cubic_roots = @import("cubic_roots.zig");
const cubicRootsUnit = cubic_roots.cubicRootsUnit;
const bezierPolynomial = cubic_roots.bezierPolynomial;

/// Cut by drawable-segment parameter, preserving exact cubic geometry and
/// pen-up discontinuities. A reversed interval returns the reversed cut.
/// A zero-width cut selects the same segment boundary as curveAt.
pub fn trimmed(self: Path, allocator: std.mem.Allocator, begin: f64, end: f64) anyerror!Path {
    const count: f64 = @floatFromInt(self.segmentCount());
    if (!std.math.isFinite(begin) or !std.math.isFinite(end) or begin < 0 or end < 0 or begin > count or end > count) return error.InvalidParameter;
    if (begin > end) {
        var forward = try trimmed(self, allocator, end, begin);
        defer forward.deinit();
        return forward.reverse(allocator);
    }
    if (begin == 0 and end == count) return self.clone(allocator);
    var result = Path.init(allocator);
    errdefer result.deinit();
    if (begin == end) {
        const selected = try self.selectCurveAt(begin);
        const point = selected.position.curve.at(selected.position.t);
        try result.moveTo(point);
        if (selected.is_cubic) try result.cubicTo(point, point, point) else try result.lineTo(point);
        return result;
    }
    var time: f64 = 0;
    var current: Point = .zero;
    var start: Point = .zero;
    var need_move = true;
    var subpath_time: f64 = 0;
    for (self.segments.items, 0..) |segment, index| {
        if (segment == .move) {
            current = segment.move;
            start = current;
            need_move = true;
            subpath_time = time;
            continue;
        }
        if (segment == .close and current.eql(start)) {
            if (begin <= subpath_time and end >= time and result.open) try result.close();
            current = start;
            continue;
        }
        const curve: Cubic = switch (segment) {
            .line => |p| .line(current, p),
            .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
            .close => .line(current, start),
            .move => unreachable,
        };
        const lo = @max(0, begin - time);
        const hi = @min(1, end - time);
        if (lo <= hi and hi >= 0 and lo <= 1 and time <= end and time + 1 >= begin) {
            // Skip boundary-only fragments when a nonempty interval exists.
            if (hi > lo) {
                const cut = try curve.trimmed(lo, hi);
                if (need_move or result.current == null) try result.moveTo(cut.p0);
                if (segment == .cubic) {
                    const dirs = self.solvedAt(index, curve);
                    try result.solvedCubicTo(cut, if (lo == 0) dirs[0] else .zero, if (hi == 1) dirs[1] else .zero);
                } else if (segment == .close and begin <= subpath_time and hi == 1) {
                    try result.close();
                } else try result.lineTo(cut.p3);
                need_move = false;
            }
        }
        current = curve.p3;
        time += 1;
    }
    return result;
}

/// Exact centerline clipping to a rectangle. Intersections split native
/// cubics using de Casteljau; retained fragments keep their controls.
/// This operation clips drawn paths. Filled pictures use a scene clip group
/// so the renderer can preserve the fill rule and boundary edges.
pub fn clippedToRect(self: Path, allocator: std.mem.Allocator, rect: g.BBox) !Path {
    if (!rect.min.isFinite() or !rect.max.isFinite() or rect.min.x > rect.max.x or rect.min.y > rect.max.y) return error.InvalidParameter;
    var result = Path.init(allocator);
    errdefer result.deinit();
    var current: Point = .zero;
    var start: Point = .zero;
    var need_move = true;
    var contour_kept = true;
    for (self.segments.items, 0..) |segment, index| {
        if (segment == .move) {
            current = segment.move;
            start = current;
            need_move = true;
            contour_kept = true;
            continue;
        }
        const curve: Cubic = switch (segment) {
            .line => |p| .line(current, p),
            .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
            .close => .line(current, start),
            .move => unreachable,
        };
        var cuts: std.ArrayList(f64) = .empty;
        defer cuts.deinit(allocator);
        try cuts.appendSlice(allocator, &.{ 0, 1 });
        inline for (.{ "x", "y" }) |axis| {
            const v0 = @field(curve.p0, axis);
            const v1 = @field(curve.p1, axis);
            const v2 = @field(curve.p2, axis);
            const v3 = @field(curve.p3, axis);
            for ([_]f64{ @field(rect.min, axis), @field(rect.max, axis) }) |boundary| {
                const roots = cubicRootsUnit(allocator, bezierPolynomial(v0, v1, v2, v3, boundary)) catch |err| switch (err) {
                    error.CoincidentCurves => continue,
                    else => return err,
                };
                defer allocator.free(roots);
                // Distinct rectangle crossings may be very close in
                // parameter space while far apart in path coordinates.
                // Keep their event identities; exact duplicates are
                // discarded by the interval loop below.
                try cuts.appendSlice(allocator, roots);
            }
        }
        std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
        for (0..cuts.items.len - 1) |i| {
            const lo = cuts.items[i];
            const hi = cuts.items[i + 1];
            if (hi <= lo) continue;
            if (!rect.contains(curve.at((lo + hi) * 0.5))) {
                need_move = true;
                contour_kept = false;
                continue;
            }
            var fragment = try curve.trimmed(lo, hi);
            // Both adjoining fragments use the same source event point,
            // rather than comparing coordinates with an origin-dependent
            // relative tolerance.
            fragment.p0 = curve.at(lo);
            fragment.p3 = curve.at(hi);
            if (need_move or result.current == null or !result.current.?.eql(fragment.p0)) try result.moveTo(fragment.p0);
            if (segment == .cubic) {
                const dirs = self.solvedAt(index, curve);
                try result.solvedCubicTo(fragment, if (lo == 0) dirs[0] else .zero, if (hi == 1) dirs[1] else .zero);
            } else try result.lineTo(fragment.p3);
            need_move = false;
        }
        // A fully retained contour must keep its closed stroke join. Only
        // the final retained line is replaced; partially cut contours stay
        // open and retain their clipping endpoints and cap semantics.
        if (segment == .close and contour_kept and result.open and result.segments.items.len != 0 and result.segments.items[result.segments.items.len - 1] == .line) {
            _ = result.segments.pop();
            try result.close();
        }
        current = curve.p3;
    }
    return result;
}
