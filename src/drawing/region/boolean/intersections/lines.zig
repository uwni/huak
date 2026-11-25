// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
//! Straight curves, after Paper's Line.js and the line cases of Curve.js: signed distances, line-line and curve-line intersections.
const std = @import("std");
const types = @import("../types.zig");
const geometry = @import("../../../geometry.zig");
const curve = @import("../curve.zig");
const numerical = @import("../numeric.zig");
const Cubic = geometry.Cubic;
const Point = types.Point;
const intersections = @import("../intersections.zig");
const Builder = intersections.Builder;

pub fn addLineIntersection(self: *Builder, a: *const Cubic, b: *const Cubic, c1: usize, c2: usize) !void {
    if (lineIntersection(a, b)) |point| try self.addLocation(c1, curve.getTimeOf(a, point, null), c2, curve.getTimeOf(b, point, null), false);
}

pub fn addCurveLineIntersections(self: *Builder, a: *const Cubic, b: *const Cubic, c1: usize, c2: usize, flip: bool) !void {
    const times = lineTimes(a, b.p0.x, b.p0.y, b.p3.x - b.p0.x, b.p3.y - b.p0.y);
    for (times.items[0..times.len]) |t1| {
        const point = curve.getPoint(a, t1);
        if (curve.getTimeOf(b, point, null)) |t2| try self.addLocation(if (flip) c2 else c1, if (flip) t2 else t1, if (flip) c1 else c2, if (flip) t1 else t2, false);
    }
}

pub const BaselineDistance = struct {
    px: f64,
    py: f64,
    vx: f64,
    vy: f64,
    denominator: f64,

    pub fn init(px: f64, py: f64, vx: f64, vy: f64) BaselineDistance {
        const denominator = if (vx == 0 or vy == 0) 0 else if (vy > vx)
            @abs(vy) * @sqrt(1 + (vx * vx) / (vy * vy))
        else
            @abs(vx) * @sqrt(1 + (vy * vy) / (vx * vx));
        return .{ .px = px, .py = py, .vx = vx, .vy = vy, .denominator = denominator };
    }

    pub fn at(self: BaselineDistance, x: f64, y: f64) f64 {
        if (self.vx == 0) return if (self.vy > 0) x - self.px else self.px - x;
        if (self.vy == 0) return if (self.vx < 0) y - self.py else self.py - y;
        return ((x - self.px) * self.vy - (y - self.py) * self.vx) / self.denominator;
    }
};

pub fn signedDistance(px: f64, py: f64, vx: f64, vy: f64, x: f64, y: f64) f64 {
    return BaselineDistance.init(px, py, vx, vy).at(x, y);
}

fn lineIntersection(a: *const Cubic, b: *const Cubic) ?Point {
    const vx1 = a.p3.x - a.p0.x;
    const vy1 = a.p3.y - a.p0.y;
    const vx2 = b.p3.x - b.p0.x;
    const vy2 = b.p3.y - b.p0.y;
    const cross = vx1 * vy2 - vy1 * vx2;
    // As Line.intersect: a cross product within MACHINE_EPSILON of zero means
    // parallel lines, and both parameters may pass their ends by EPSILON.
    if (@abs(cross) <= numerical.MACHINE_EPSILON) return null;
    const dx = a.p0.x - b.p0.x;
    const dy = a.p0.y - b.p0.y;
    var first_parameter = (vx2 * dy - vy2 * dx) / cross;
    const second_parameter = (vx1 * dy - vy1 * dx) / cross;
    const low = -numerical.EPSILON;
    const high = 1 + numerical.EPSILON;
    if (!(low < first_parameter and first_parameter < high and low < second_parameter and second_parameter < high)) return null;
    first_parameter = numerical.clamp(first_parameter, 0, 1);
    return .{ .x = a.p0.x + first_parameter * vx1, .y = a.p0.y + first_parameter * vy1 };
}

const LineTimes = struct { items: [5]f64 = undefined, len: usize = 0 };

fn lineTimes(v: *const Cubic, px: f64, py: f64, vx: f64, vy: f64) LineTimes {
    var result: LineTimes = .{};
    if (numerical.isZero(vx) and numerical.isZero(vy)) {
        if (curve.getTimeOf(v, .{ .x = px, .y = py }, null)) |time| {
            result.items[0] = time;
            result.len = 1;
        }
        return result;
    }
    const angle = std.math.atan2(-vy, vx);
    const sine = @sin(angle);
    const cosine = @cos(angle);
    var rotated = Cubic{
        .p0 = undefined,
        .p1 = undefined,
        .p2 = undefined,
        .p3 = undefined,
    };
    inline for ([_]Point{ v.p0, v.p1, v.p2, v.p3 }, 0..) |point, i| {
        const x = point.x - px;
        const y = point.y - py;
        const rx = x * cosine - y * sine;
        const ry = x * sine + y * cosine;
        switch (i) {
            0 => rotated.p0 = .{ .x = rx, .y = ry },
            1 => rotated.p1 = .{ .x = rx, .y = ry },
            2 => rotated.p2 = .{ .x = rx, .y = ry },
            3 => rotated.p3 = .{ .x = rx, .y = ry },
            else => unreachable,
        }
    }
    var roots: [3]f64 = undefined;
    const count = curve.solveCubic(&rotated, 1, 0, &roots, 0, 1);
    result.len = @intCast(@max(0, count));
    @memcpy(result.items[0..result.len], roots[0..result.len]);
    // As upstream (paper.js #1848): an end whose rotated y is within
    // GEOMETRIC_EPSILON of zero lies on the line, even when rounding keeps
    // the root solver from finding it.
    if (@abs(rotated.p0.y) < numerical.GEOMETRIC_EPSILON) {
        result.items[result.len] = 0;
        result.len += 1;
    }
    if (@abs(rotated.p3.y) < numerical.GEOMETRIC_EPSILON) {
        result.items[result.len] = 1;
        result.len += 1;
    }
    return result;
}
