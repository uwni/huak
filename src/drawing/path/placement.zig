//! A segment seen through a transform: mapped in place, checked for finite coordinates, and bounded as geometry or as ink.
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Path = @import("Path.zig");
const Segment = Path.Segment;

pub inline fn mapSegment(segment: *Segment, matrix: *const g.Transform) void {
    switch (segment.*) {
        .move, .line => |*point| point.* = matrix.apply(point.*),
        .cubic => |*curve| {
            curve.c1 = matrix.apply(curve.c1);
            curve.c2 = matrix.apply(curve.c2);
            curve.end = matrix.apply(curve.end);
        },
        .close => {},
    }
}

inline fn pointFinite(point: Point, matrix: ?g.Transform) bool {
    return (if (matrix) |mapping| mapping.apply(point) else point).isFinite();
}

pub inline fn segmentFinite(segment: *const Segment, matrix: ?g.Transform) bool {
    return switch (segment.*) {
        .move, .line => |point| pointFinite(point, matrix),
        .cubic => |curve| pointFinite(curve.c1, matrix) and pointFinite(curve.c2, matrix) and pointFinite(curve.end, matrix),
        .close => true,
    };
}

pub fn segmentBounds(segments: []const Segment, placement: g.Transform, comptime kind: enum { geometry, ink }) error{NonFinite}!?g.BBox {
    var result: ?g.BBox = null;
    var current: Point = if (kind == .ink) placement.apply(.zero) else .zero;
    var start = current;
    for (segments) |raw| {
        var segment = raw;
        if (kind == .ink) mapSegment(&segment, &placement);
        const box: g.BBox = switch (segment) {
            .move => |p| blk: {
                current = p;
                start = p;
                if (kind == .ink) continue;
                break :blk .fromPoint(p);
            },
            .line => |p| blk: {
                const b = g.BBox.fromPoints(current, p);
                current = p;
                break :blk b;
            },
            .cubic => |c| blk: {
                const curve: Cubic = .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end };
                if (kind == .ink and !curve.isFinite()) return error.NonFinite;
                current = c.end;
                break :blk curve.bounds();
            },
            .close => blk: {
                const b = g.BBox.fromPoints(current, start);
                current = start;
                break :blk b;
            },
        };
        if (kind == .ink and (!box.min.isFinite() or !box.max.isFinite())) return error.NonFinite;
        result = if (result) |b| b.unite(box) else box;
    }
    return result;
}
