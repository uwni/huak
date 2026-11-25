// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
//! Collinear overlaps of a curve pair, and the endpoint memo of a pair.
const std = @import("std");
const geometry = @import("../../../geometry.zig");
const curve = @import("../curve.zig");
const numerical = @import("../numeric.zig");
const Cubic = geometry.Cubic;
const lines = @import("lines.zig");
const signedDistance = lines.signedDistance;

fn squaredLineLength(v: *const Cubic) f64 {
    const x = v.p3.x - v.p0.x;
    const y = v.p3.y - v.p0.y;
    return x * x + y * y;
}

pub const Pair = struct {
    cubics: [2]*const Cubic,
    epsilon: f64,
    times: [4]?f64 = undefined,
    computed: [4]bool = .{ false, false, false, false },

    // Indices name a0, a1, b0, b1 tested against the opposite curve. A cached
    // null is a completed miss.
    pub fn endpoint(self: *const Pair, index: usize) ?f64 {
        return if (self.computed[index]) self.times[index] else self.query(index);
    }

    fn query(self: *const Pair, index: usize) ?f64 {
        const source = index >> 1;
        const v = self.cubics[source];
        const point = if (index & 1 != 0) v.p3 else v.p0;
        return curve.getTimeOf(self.cubics[source ^ 1], point, self.epsilon);
    }

    pub fn overlaps(self: *Pair) ?[2][2]f64 {
        const a = self.cubics[0];
        const b = self.cubics[1];
        const epsilon = self.epsilon;
        var straight1 = curve.isStraight(a);
        var straight2 = curve.isStraight(b);
        var both = straight1 and straight2;
        const flip = squaredLineLength(a) < squaredLineLength(b);
        const l1 = if (flip) b else a;
        const l2 = if (flip) a else b;
        const px = l1.p0.x;
        const py = l1.p0.y;
        const vx = l1.p3.x - px;
        const vy = l1.p3.y - py;
        if (@abs(signedDistance(px, py, vx, vy, l2.p0.x, l2.p0.y)) < epsilon and
            @abs(signedDistance(px, py, vx, vy, l2.p3.x, l2.p3.y)) < epsilon)
        {
            if (!both and @abs(signedDistance(px, py, vx, vy, l1.p1.x, l1.p1.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l1.p2.x, l1.p2.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l2.p1.x, l2.p1.y)) < epsilon and
                @abs(signedDistance(px, py, vx, vy, l2.p2.x, l2.p2.y)) < epsilon)
            {
                straight1 = true;
                straight2 = true;
                both = true;
            }
        } else if (both) return null;
        if (straight1 != straight2) return null;
        var pairs: [2][2]f64 = undefined;
        var length: usize = 0;
        var i: usize = 0;
        while (i < 4 and length < 2) : (i += 1) {
            const first_index = i & 1;
            const second_index = first_index ^ 1;
            const t1: f64 = @floatFromInt(i >> 1);
            const endpoint_index = (second_index << 1) | (i >> 1);
            const time = self.query(endpoint_index);
            self.times[endpoint_index] = time;
            self.computed[endpoint_index] = true;
            if (time) |t2| {
                const pair_: [2]f64 = if (first_index != 0) .{ t1, t2 } else .{ t2, t1 };
                // As upstream: an overlap shorter than CURVETIME_EPSILON in
                // either curve's time is no overlap.
                if (length == 0 or (@abs(pair_[0] - pairs[0][0]) > numerical.CURVETIME_EPSILON and @abs(pair_[1] - pairs[0][1]) > numerical.CURVETIME_EPSILON)) {
                    pairs[length] = pair_;
                    length += 1;
                }
            }
            if (i > 2 and length == 0) break;
        }
        if (length != 2) return null;
        if (!both) {
            const first = curve.getPart(a, pairs[0][0], pairs[1][0]);
            const second = curve.getPart(b, pairs[0][1], pairs[1][1]);
            if (@abs(second.p1.x - first.p1.x) > epsilon or @abs(second.p1.y - first.p1.y) > epsilon or
                @abs(second.p2.x - first.p2.x) > epsilon or @abs(second.p2.y - first.p2.y) > epsilon) return null;
        }
        return pairs;
    }
};

test "pair endpoint memo keeps completed misses and uses the pair's tolerance" {
    const t = std.testing;
    const a: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 0 }, .p2 = .{ .x = 10, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    const b: Cubic = .{ .p0 = .{ .x = 5, .y = 0 }, .p1 = .{ .x = 5, .y = 0 }, .p2 = .{ .x = 15, .y = 0 }, .p3 = .{ .x = 15, .y = 0 } };
    var pair: Pair = .{ .cubics = .{ &a, &b }, .epsilon = 1e-12 };
    _ = pair.overlaps();
    const expected = [_]?f64{ null, 0.5, 0.5, null };
    for (expected, 0..) |time, index| {
        try t.expectEqual(time, pair.endpoint(index));
        try t.expect(pair.computed[index]);
        try t.expectEqual(time, pair.endpoint(index));
    }
    // An end 1e-8 off the other curve lies on it within a tolerance of 1e-7,
    // and not within 1e-12.
    const nearby: Cubic = .{ .p0 = .{ .x = 0, .y = 1e-8 }, .p1 = .{ .x = 0, .y = 1e-8 }, .p2 = .{ .x = 10, .y = 1e-8 }, .p3 = .{ .x = 10, .y = 1e-8 } };
    for ([_]f64{ 1e-7, 1e-12 }, [_]?f64{ 0, null }) |epsilon, time| {
        var close: Pair = .{ .cubics = .{ &a, &nearby }, .epsilon = epsilon };
        _ = close.overlaps();
        try t.expectEqual(time, close.endpoint(2));
    }
}
