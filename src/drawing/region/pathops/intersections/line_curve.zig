// Copyright 2012 Google Inc.; Zig adaptation copyright 2026 Huak contributors.
// BSD-style license: ../LICENSE.
//! Skia LineCubicIntersections / LineQuadraticIntersections. Their common
//! endpoint/coincidence flow is shared; degree-specific pinning stays explicit.
const n = @import("../numeric.zig");
const Point = @import("../point.zig").Point;
const curve_types = @import("../curve.zig");
const Line = curve_types.Line;
const Intersections = @import("../Intersections.zig");

pub fn ray(comptime Curve: type, result: *Intersections, curve: Curve, origin: Point, direction: Point) usize {
    var rotated = curve;
    for (&rotated.points, curve.points) |*out, point| {
        const relative = point.sub(origin);
        out.* = .{
            .x = @mulAdd(f64, relative.y, direction.x, -(relative.x * direction.y)),
            .y = if (Curve == curve_types.Cubic) @mulAdd(f64, relative.y, direction.y, relative.x * direction.x) else relative.y * direction.y + relative.x * direction.x,
        };
    }
    var roots: [curve.points.len - 1]f64 = undefined;
    const count = rotated.verticalIntersect(0, &roots);
    result.max = curve.points.len - 1;
    result.used = count;
    for (roots[0..count], 0..) |t, index| {
        result.parameters[0][index] = t;
        result.points[index] = curve.ptAtT(t);
    }
    return count;
}

pub fn intersect(comptime Curve: type, result: *Intersections, curve: Curve, line: Line) usize {
    var query: Query(Curve) = .{ .curve = curve, .line = line, .result = result };
    result.max = if (Curve == curve_types.Cubic) 4 else 5;
    query.addEndpoints(null);
    var rotated = curve;
    const direction = line.points[1].sub(line.points[0]);
    for (&rotated.points, curve.points) |*out, point| {
        const relative = point.sub(line.points[0]);
        out.* = .{
            .x = @mulAdd(f64, relative.y, direction.x, -(relative.x * direction.y)),
            .y = if (Curve == curve_types.Cubic) @mulAdd(f64, relative.y, direction.y, relative.x * direction.x) else relative.y * direction.y + relative.x * direction.x,
        };
    }
    var roots: [curve.points.len - 1]f64 = undefined;
    const count = rotated.verticalIntersect(0, &roots);
    for (roots[0..count]) |t| {
        var curve_t = t;
        var line_t = query.findLineT(t);
        var point: Point = undefined;
        if (query.pinTs(&curve_t, &line_t, &point, false) and query.uniqueAnswer(curve_t, point)) _ = result.insert(curve_t, line_t, point);
    }
    query.checkCoincident();
    return result.used;
}

pub fn axis(comptime Curve: type, result: *Intersections, curve: Curve, low: f64, high: f64, constant: f64, vertical: bool, flipped: bool) usize {
    const line: Line = .{ .points = if (vertical) .{ .{ .x = constant, .y = low }, .{ .x = constant, .y = high } } else .{ .{ .x = low, .y = constant }, .{ .x = high, .y = constant } } };
    var query: Query(Curve) = .{ .curve = curve, .line = line, .result = result };
    result.max = if (Curve == curve_types.Cubic) 4 else 5;
    query.addEndpoints(vertical);
    var roots: [curve.points.len - 1]f64 = undefined;
    const count = if (vertical) curve.verticalIntersect(constant, &roots) else curve.horizontalIntersect(constant, &roots);
    for (roots[0..count]) |t| {
        var curve_t = t;
        var point = curve.ptAtT(t);
        if (Curve == curve_types.Cubic or !vertical) {
            if (vertical) point.x = constant else point.y = constant;
        }
        var line_t = ((if (vertical) point.y else point.x) - low) / (high - low);
        if (query.pinTs(&curve_t, &line_t, &point, true) and query.uniqueAnswer(curve_t, point)) _ = result.insert(curve_t, line_t, point);
    }
    if (flipped) result.flip();
    query.checkCoincident();
    return result.used;
}

fn Query(comptime Curve: type) type {
    return struct {
        curve: Curve,
        line: Line,
        result: *Intersections,
        const Self = @This();
        const cubic = Curve == curve_types.Cubic;
        const last = if (cubic) 3 else 2;

        fn addEndpoints(self: *Self, direction: ?bool) void {
            for ([_]usize{ 0, last }, 0..) |index, endpoint| {
                const point = self.curve.points[index];
                const t = self.endpointT(point, direction, false);
                if (t >= 0) _ = self.result.insert(@floatFromInt(endpoint), t, point);
            }
            // The upstream specialized horizontal/vertical wrappers permit
            // near endpoints by default; the general line respects allowNear.
            if (!self.result.allow_near and direction == null) return;
            for ([_]usize{ 0, last }, 0..) |index, endpoint| {
                const curve_t: f64 = @floatFromInt(endpoint);
                if (self.result.hasT(curve_t)) continue;
                const point = self.curve.points[index];
                const line_t = self.endpointT(point, direction, true);
                if (line_t >= 0) _ = self.result.insert(curve_t, line_t, point);
            }
            for (self.line.points, 0..) |point, endpoint| {
                const line_t: f64 = @floatFromInt(endpoint);
                if (self.result.hasOppT(line_t)) continue;
                const curve_t = self.curve.nearPoint(point, self.line.points[1 - endpoint]);
                if (curve_t >= 0) _ = self.result.insert(curve_t, line_t, point);
            }
        }
        fn endpointT(self: *Self, point: Point, direction: ?bool, near: bool) f64 {
            const vertical = direction orelse return if (near) self.line.nearPoint(point, null) else self.line.exactPoint(point);
            if (vertical) return if (near) Line.nearPointV(point, self.line.points[0].y, self.line.points[1].y, self.line.points[0].x) else Line.exactPointV(point, self.line.points[0].y, self.line.points[1].y, self.line.points[0].x);
            return if (near) Line.nearPointH(point, self.line.points[0].x, self.line.points[1].x, self.line.points[0].y) else Line.exactPointH(point, self.line.points[0].x, self.line.points[1].x, self.line.points[0].y);
        }
        fn findLineT(self: *Self, t: f64) f64 {
            const point = self.curve.ptAtT(t);
            const direction = self.line.points[1].sub(self.line.points[0]);
            return if (@abs(direction.x) > @abs(direction.y)) (point.x - self.line.points[0].x) / direction.x else (point.y - self.line.points[0].y) / direction.y;
        }
        fn pinTs(self: *Self, curve_t: *f64, line_t: *f64, point: *Point, initialized: bool) bool {
            if (cubic) {
                if (!n.approximatelyOneOrLess(line_t.*) or !n.approximatelyZeroOrMore(line_t.*)) return false;
            } else {
                if (!n.approximatelyOneOrLessDouble(line_t.*) or !n.approximatelyZeroOrMoreDouble(line_t.*)) return false;
            }
            curve_t.* = n.pinT(curve_t.*);
            line_t.* = n.pinT(line_t.*);
            const line_point = self.line.ptAtT(line_t.*);
            const curve_point = self.curve.ptAtT(curve_t.*);
            if (cubic and !line_point.roughlyEqual(curve_point)) return false;
            if (n.zeroOrOne(line_t.*) or (!initialized and !n.zeroOrOne(curve_t.*))) point.* = line_point else if (!initialized) point.* = curve_point;
            const grid_point = point.*;
            if (cubic) {
                if (grid_point.eql(self.line.points[0])) line_t.* = 0 else if (grid_point.eql(self.line.points[1])) line_t.* = 1;
                if (grid_point.eql(self.curve.points[0]) and n.approximatelyEqual(curve_t.*, 0)) curve_t.* = 0 else if (grid_point.eql(self.curve.points[last]) and n.approximatelyEqual(curve_t.*, 1)) curve_t.* = 1;
            } else {
                if (grid_point.approximatelyEqual(self.line.points[0])) {
                    point.* = self.line.points[0];
                    line_t.* = 0;
                } else if (grid_point.approximatelyEqual(self.line.points[1])) {
                    point.* = self.line.points[1];
                    line_t.* = 1;
                }
                if (self.result.used > 0 and n.approximatelyEqual(self.result.parameters[1][0], line_t.*)) return false;
                if (grid_point.eql(self.curve.points[0])) {
                    point.* = self.curve.points[0];
                    curve_t.* = 0;
                } else if (grid_point.eql(self.curve.points[last])) {
                    point.* = self.curve.points[last];
                    curve_t.* = 1;
                }
            }
            return true;
        }
        fn uniqueAnswer(self: *Self, curve_t: f64, point: Point) bool {
            for (self.result.points[0..self.result.used], self.result.parameters[0][0..self.result.used]) |old_point, old_t| {
                if (!old_point.eql(point)) continue;
                if (curve_t == old_t or self.curve.ptAtT((old_t + curve_t) / 2).approximatelyEqual(point)) return false;
            }
            return true;
        }
        fn checkCoincident(self: *Self) void {
            var index: usize = 0;
            while (index + 1 < self.result.used) {
                const middle = self.curve.ptAtT((self.result.parameters[0][index] + self.result.parameters[0][index + 1]) / 2);
                if (self.line.nearPoint(middle, null) < 0) {
                    index += 1;
                    continue;
                }
                if (self.result.isCoincident(index)) {
                    self.result.removeOne(index);
                } else if (self.result.isCoincident(index + 1)) {
                    self.result.removeOne(index + 1);
                } else {
                    self.result.setCoincident(index);
                    index += 1;
                }
                self.result.setCoincident(index);
            }
        }
    };
}
