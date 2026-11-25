//! Local coordinates of a drawable segment. The origin travels on the
//! source curve; the axes follow its tangent and left normal.
const std = @import("std");
const g = @import("../geometry.zig");
const Point = g.Point;
const Cubic = g.Cubic;
const Direction = @import("Direction.zig");
const SegmentFrame = @This();

curve: Cubic,
cubic: bool,
direction: Direction,
start: Point = .zero,
end: Point = .zero,

pub fn init(curve: Cubic, cubic: bool) !SegmentFrame {
    return .{ .curve = curve, .cubic = cubic, .direction = try Direction.init(curve, cubic) };
}

pub fn ray(self: *const SegmentFrame, u: f64) Direction.Ray {
    if (u == 0 and !self.start.eql(.zero)) return .{ self.start.x, self.start.y };
    if (u == 1 and !self.end.eql(.zero)) return .{ self.end.x, self.end.y };
    return self.direction.ray(u);
}

pub fn useSolved(self: *SegmentFrame, dirs: [2]Point, max_delta: f64) !void {
    self.start = dirs[0];
    self.end = dirs[1];
    // Interior derivatives still belong to the stored cubic. Charge the
    // endpoint rotation difference to the sweep's spatial error budget.
    inline for (.{ self.start, self.end }, .{ @as(f64, 0), @as(f64, 1) }) |v, u| {
        if (!v.eql(.zero)) {
            const raw = try (try self.direction.at(u)).normalized();
            if (raw.distance(try v.normalized()) > max_delta) return error.PrecisionRange;
        }
    }
}

pub fn point(self: *const SegmentFrame, u: f64) Point {
    return if (self.cubic) self.curve.at(u) else self.curve.p0.lerp(self.curve.p3, u);
}

pub fn at(self: *const SegmentFrame, u: f64) !g.Transform {
    if (!std.math.isFinite(u) or u < 0 or u > 1) return error.InvalidParameter;
    const origin = self.point(u);
    const basis = try g.Transform.fromXAxis(try Direction.narrow(self.ray(u)));
    return basis.then(.translation(origin.x, origin.y));
}

test "segment-local basis retains the derivative through cancellation" {
    const e = 0x1p-54;
    const curve: Cubic = .{
        .p0 = .{ .x = -1, .y = 0 },
        .p1 = .{ .x = e, .y = e },
        .p2 = .{ .x = -1, .y = 2 * e },
        .p3 = .{ .x = 2 * e, .y = 3 * e },
    };
    const frame = try SegmentFrame.init(curve, true);
    const basis = try frame.at(0.5);
    // At u=1/2 the Bernstein derivative is proportional to (1,4).
    // Rounding the control-point differences to f64 first loses its x part.
    try std.testing.expectEqual(curve.at(0.5), basis.apply(.zero));
    try std.testing.expectApproxEqAbs(1 / @sqrt(@as(f64, 17)), basis.a, 1e-15);
    try std.testing.expectEqual(4 * basis.a, basis.b);
    try std.testing.expectEqual(-basis.b, basis.c);
    try std.testing.expectEqual(basis.a, basis.d);
    try std.testing.expectError(error.InvalidParameter, frame.at(1.1));
}
