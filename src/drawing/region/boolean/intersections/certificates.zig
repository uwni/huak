// Paper.js v0.16.0: Curve.js, CurveLocation.js and Line.js.
// Copyright (c) 2011–2020 Jürg Lehni & Jonathan Puckey. MIT license.
//! Control-hull certificates that reject or short-cut a curve pair before the search: shared endpoints, half planes and hull relations.
const std = @import("std");
const types = @import("../types.zig");
const geometry = @import("../../../geometry.zig");
const curve = @import("../curve.zig");
const numerical = @import("../numeric.zig");
const Cubic = geometry.Cubic;
const Point = types.Point;

const HullRelation = enum { disjoint, touch, overlap };

const SharedEndpoint = struct { point: Point, first_time: f64, second_time: f64 };

/// The relative rounding the hull certificates allow for, well above the few
/// roundings of a projected coordinate. A wider margin only sends more pairs
/// on to the full intersection search.
const certificate_rounding = 256 * numerical.MACHINE_EPSILON;

pub fn sharedEndpoint(a: *const Cubic, b: *const Cubic) ?SharedEndpoint {
    var found: ?SharedEndpoint = null;
    var count: usize = 0;
    if (a.p0.eql(b.p0)) {
        found = .{ .point = a.p0, .first_time = 0, .second_time = 0 };
        count += 1;
    }
    if (a.p3.eql(b.p0)) {
        found = .{ .point = a.p3, .first_time = 1, .second_time = 0 };
        count += 1;
    }
    if (a.p0.eql(b.p3)) {
        found = .{ .point = a.p0, .first_time = 0, .second_time = 1 };
        count += 1;
    }
    if (a.p3.eql(b.p3)) {
        found = .{ .point = a.p3, .first_time = 1, .second_time = 1 };
        count += 1;
    }
    // A second shared endpoint can be a second intersection; keep the general
    // path for that case.
    if (count != 1 or found == null) return null;
    return found;
}

const HalfPlane = enum { positive, negative, zero, ambiguous };

/// Conservative half-plane classification. A value outside the rounded dot
/// product's error bound has a reliable sign. Only zero operands establish a
/// structural zero; rounded products may underflow and must remain ambiguous.
fn halfPlane(x: f64, y: f64, origin: Point, nx: f64, ny: f64) HalfPlane {
    const dx = x - origin.x;
    const dy = y - origin.y;
    const first = dx * nx;
    const second = dy * ny;
    const zero: @Vector(2, f64) = @splat(0);
    const delta: @Vector(2, f64) = .{ dx, dy };
    const normal: @Vector(2, f64) = .{ nx, ny };
    const structural_zero = @select(bool, normal == zero, @as(@Vector(2, bool), @splat(true)), delta == zero);
    if (@reduce(.And, structural_zero)) return .zero;
    const value = first + second;
    // Round the bound outward; the absolute term also covers subnormal
    // subtraction and multiplication.
    const bound = certificate_rounding *
        ((@abs(x) + @abs(origin.x)) * @abs(nx) + (@abs(y) + @abs(origin.y)) * @abs(ny) + 1);
    if (value > bound) return .positive;
    if (value < -bound) return .negative;
    return .ambiguous;
}

/// Sufficient control-hull relation for two cubics. A cubic lies inside the
/// convex hull of its controls, so a separating line proves disjointness. For
/// a single shared endpoint, a line through it with all controls of one curve
/// on one side and all controls of the other on the other side proves the
/// curves meet only there: the Bernstein basis keeps each curve strictly on
/// its side for all interior parameters, and neither other endpoint is shared.
/// Every control-point pair supplies a candidate normal; the convex hull's
/// edge normals are a subset, so a separating hull edge is always tried.
/// Projection gaps are rounded outward. A disjoint result can only reject
/// work that cannot contribute an accepted event; a touch result replaces a
/// provably unique endpoint search with that exact endpoint.
pub fn hullRelation(a: *const Cubic, b: *const Cubic, shared: ?SharedEndpoint, threshold: f64, magnitude: f64) HullRelation {
    const coordinate_error = certificate_rounding * magnitude;
    for ([_]*const Cubic{ a, b }) |values| {
        const candidates = [_]struct { a: Point, b: Point }{
            .{ .a = values.p0, .b = values.p1 },
            .{ .a = values.p0, .b = values.p2 },
            .{ .a = values.p0, .b = values.p3 },
            .{ .a = values.p1, .b = values.p2 },
            .{ .a = values.p1, .b = values.p3 },
            .{ .a = values.p2, .b = values.p3 },
        };
        for (candidates) |candidate| {
            {
                const dx = candidate.a.x - candidate.b.x;
                const dy = candidate.a.y - candidate.b.y;
                if (dx != 0 or dy != 0) {
                    const nx = -dy;
                    const ny = dx;
                    var first = [4]f64{ undefined, undefined, undefined, undefined };
                    var second = [4]f64{ undefined, undefined, undefined, undefined };
                    var low_a = std.math.inf(f64);
                    var high_a = -std.math.inf(f64);
                    var low_b = std.math.inf(f64);
                    var high_b = -std.math.inf(f64);
                    var largest: f64 = 0;
                    inline for ([_]struct { a: Point, b: Point }{
                        .{ .a = a.p0, .b = b.p0 },
                        .{ .a = a.p1, .b = b.p1 },
                        .{ .a = a.p2, .b = b.p2 },
                        .{ .a = a.p3, .b = b.p3 },
                    }, 0..) |points, k| {
                        first[k] = points.a.x * nx + points.a.y * ny;
                        second[k] = points.b.x * nx + points.b.y * ny;
                        low_a = @min(low_a, first[k]);
                        high_a = @max(high_a, first[k]);
                        low_b = @min(low_b, second[k]);
                        high_b = @max(high_b, second[k]);
                        largest = @max(largest, @abs(first[k]), @abs(second[k]));
                    }
                    const span = @abs(nx) + @abs(ny);
                    const margin = (threshold + coordinate_error) * span + certificate_rounding * largest;
                    if (high_a + margin < low_b or high_b + margin < low_a) return .disjoint;
                    if (shared) |endpoint| {
                        var a_nonpositive = true;
                        var a_nonnegative = true;
                        var a_negative = false;
                        var a_positive = false;
                        var b_nonpositive = true;
                        var b_nonnegative = true;
                        var b_negative = false;
                        var b_positive = false;
                        var ambiguous = false;
                        inline for ([_]struct { a: Point, b: Point }{
                            .{ .a = a.p0, .b = b.p0 },
                            .{ .a = a.p1, .b = b.p1 },
                            .{ .a = a.p2, .b = b.p2 },
                            .{ .a = a.p3, .b = b.p3 },
                        }) |points| {
                            switch (halfPlane(points.a.x, points.a.y, endpoint.point, nx, ny)) {
                                .positive => {
                                    a_nonpositive = false;
                                    a_positive = true;
                                },
                                .negative => {
                                    a_nonnegative = false;
                                    a_negative = true;
                                },
                                .zero => {},
                                .ambiguous => ambiguous = true,
                            }
                            switch (halfPlane(points.b.x, points.b.y, endpoint.point, nx, ny)) {
                                .positive => {
                                    b_nonpositive = false;
                                    b_positive = true;
                                },
                                .negative => {
                                    b_nonnegative = false;
                                    b_negative = true;
                                },
                                .zero => {},
                                .ambiguous => ambiguous = true,
                            }
                        }
                        if (!ambiguous and ((a_nonpositive and a_negative and b_nonnegative and b_positive) or
                            (b_nonpositive and b_negative and a_nonnegative and a_positive))) return .touch;
                    }
                }
            }
        }
    }
    return .overlap;
}

test "half-plane certificate keeps underflow ambiguous" {
    const t = std.testing;
    const tiny: f64 = @bitCast(@as(u64, 1));
    for ([_]f64{ tiny, -tiny }) |value| {
        try t.expectEqual(HalfPlane.ambiguous, halfPlane(value, 0, .zero, 0.5, 0));
        try t.expectEqual(HalfPlane.ambiguous, halfPlane(0, value, .zero, 0, 0.5));
    }
    try t.expectEqual(HalfPlane.zero, halfPlane(0, tiny, .zero, 0.5, 0));
    try t.expectEqual(HalfPlane.zero, halfPlane(tiny, 0, .zero, 0, 0.5));
}

test "control-hull certificate separates disjoint curves and leaves crossings" {
    const t = std.testing;
    const above: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 3 }, .p2 = .{ .x = 10, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    const below: Cubic = .{ .p0 = .{ .x = 0, .y = -10 }, .p1 = .{ .x = 0, .y = -7 }, .p2 = .{ .x = 10, .y = -7 }, .p3 = .{ .x = 10, .y = -10 } };
    try t.expectEqual(HullRelation.disjoint, hullRelation(&above, &below, null, 0.01, 10));
    const diagonal: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 3, .y = 3 }, .p2 = .{ .x = 7, .y = 7 }, .p3 = .{ .x = 10, .y = 10 } };
    const crossing: Cubic = .{ .p0 = .{ .x = 0, .y = 10 }, .p1 = .{ .x = 3, .y = 7 }, .p2 = .{ .x = 7, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expectEqual(HullRelation.overlap, hullRelation(&diagonal, &crossing, null, 0.01, 10));
}

test "shared-endpoint certificate recognizes a single tangency" {
    const t = std.testing;
    const first: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 1 }, .p2 = .{ .x = 1, .y = 1 }, .p3 = .{ .x = 1, .y = 0 } };
    const second: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = -1 }, .p2 = .{ .x = -1, .y = -1 }, .p3 = .{ .x = -1, .y = 0 } };
    const endpoint = sharedEndpoint(&first, &second) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(f64, 0), endpoint.first_time);
    try t.expectEqual(@as(f64, 0), endpoint.second_time);
    try t.expectEqual(HullRelation.touch, hullRelation(&first, &second, endpoint, 1e-6, 1));
    const closed: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 1 }, .p2 = .{ .x = 1, .y = 1 }, .p3 = .{ .x = 1, .y = 0 } };
    try t.expect(sharedEndpoint(&first, &closed) == null);
}

test "chord strip keeps tolerance contacts on both sides and for a zero chord" {
    const t = std.testing;
    const arch: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 3 }, .p2 = .{ .x = 10, .y = 3 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expect(curve.outsideChordStrip(&arch, .{ .x = 5, .y = -1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&arch, .{ .x = 5, .y = -0.1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&arch, .{ .x = 5, .y = 2 }, 0.5));
    var s = arch;
    s.p1.y = -2;
    try t.expect(curve.outsideChordStrip(&s, .{ .x = 5, .y = 4 }, 0.5));
    try t.expect(curve.outsideChordStrip(&s, .{ .x = 5, .y = -3 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&s, .{ .x = 5, .y = 3.5 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&s, .{ .x = 5, .y = -2.5 }, 0.5));
    s.p3 = s.p0;
    try t.expect(!curve.outsideChordStrip(&s, s.at(0.4), 0));
    const tiny = Cubic.line(.zero, .{ .x = 1e-200, .y = 0 });
    try t.expect(!curve.outsideChordStrip(&tiny, .{ .x = 0, .y = 0.1 }, 0.5));
    const line: Cubic = .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 0, .y = 0 }, .p2 = .{ .x = 10, .y = 0 }, .p3 = .{ .x = 10, .y = 0 } };
    try t.expect(curve.outsideChordStrip(&line, .{ .x = 5, .y = 1 }, 0.5));
    try t.expect(!curve.outsideChordStrip(&line, .{ .x = 5, .y = 0.25 }, 0.5));
}
