//! Advances in drawable-segment time. Moves and empty closing edges consume no time.
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Path = @import("Path.zig");
const CurveReader = @This();
const Segment = Path.Segment;
const PathError = Path.PathError;

segments: []const Segment,
current: Point = .zero,
start: Point = .zero,
open: bool = false,

pub fn read(self: *CurveReader, skip: usize) PathError!struct { curve: Cubic, is_cubic: bool } {
    var remaining = skip;
    var current = self.current;
    var start = self.start;
    var open = self.open;
    for (self.segments, 0..) |segment, i| {
        if (segment == .move) {
            if (!segment.move.isFinite()) return error.NonFinite;
            current = segment.move;
            start = current;
            open = true;
            continue;
        }
        if (!open) return error.InvalidPath;
        open = segment != .close;
        if (!open and current.eql(start)) continue;
        const curve: Cubic = switch (segment) {
            .line => |point| .line(current, point),
            .cubic => |c| .{ .p0 = current, .p1 = c.c1, .p2 = c.c2, .p3 = c.end },
            .close => .line(current, start),
            .move => unreachable,
        };
        if (!curve.isFinite()) return error.NonFinite;
        current = curve.p3;
        if (remaining == 0) {
            self.* = .{ .segments = self.segments[i + 1 ..], .current = current, .start = start, .open = open };
            return .{ .curve = curve, .is_cubic = segment == .cubic };
        }
        remaining -= 1;
    }
    return error.InvalidPath;
}
