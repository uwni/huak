//! MetaPost/Hobby interpolation, independent of libtypst.
//!
//! The unknown tangent offsets solve Hobby's linear mock-curvature equations;
//! controls use the Hobby velocity function, not polynomial interpolation of
//! point coordinates. See docs/hobby-reference.md for the original equations,
//! public-domain source attribution, and independent MetaPost reference data.
const std = @import("std");
const geometry = @import("../geometry.zig");
const Point = geometry.Point;
const Cubic = geometry.Cubic;

pub const Knot = struct {
    point: Point,
    incoming_tension: f64 = 1,
    outgoing_tension: f64 = 1,
    /// Tangent vectors point along forward traversal on both sides. One given
    /// direction also constrains the other side; give both to request a corner.
    incoming_direction: ?Point = null,
    outgoing_direction: ?Point = null,

    fn incoming(self: Knot) ?Point {
        return self.incoming_direction orelse self.outgoing_direction;
    }
    fn outgoing(self: Knot) ?Point {
        return self.outgoing_direction orelse self.incoming_direction;
    }
    fn constrained(self: Knot) bool {
        return self.incoming_direction != null or self.outgoing_direction != null;
    }
};

pub const Options = struct {
    closed: bool = false,
    /// Nonnegative endpoint mock-curvature ratios. Ignored when the endpoint
    /// has an explicit direction, or for a closed path.
    start_curl: f64 = 1,
    end_curl: f64 = 1,
    /// Reject adjacent knots at or below this distance in the caller's unit.
    /// Zero rejects exactly coincident knots without imposing a drawing scale.
    minimum_chord: f64 = 0,
};

pub const Error = error{
    OutOfMemory,
    TooFewKnots,
    NonFinite,
    InvalidTension,
    InvalidDirection,
    InvalidCurl,
    InvalidTolerance,
    CoincidentKnots,
    NumericalFailure,
};

/// Returns allocator-owned cubics in input segment order. An open path has
/// knots.len-1 cubics; a closed path has knots.len cubics (do not repeat the
/// first knot). Tensions must be finite and >= 3/4, as in MetaPost. Repeated
/// adjacent knots are diagnosed; no substitute spline or numerical fallback
/// is used. The work and storage are O(knots.len).
pub fn interpolate(allocator: std.mem.Allocator, knots: []const Knot, options: Options) Error![]Cubic {
    try validate(knots, options);
    const count = if (options.closed) knots.len else knots.len - 1;
    const segments = try allocator.alloc(Cubic, count);
    errdefer allocator.free(segments);
    const work = try allocator.alloc(Row, knots.len + 1);
    defer allocator.free(work);
    @memset(work, .{});

    if (!options.closed) {
        var start: usize = 0;
        for (1..knots.len) |end| {
            if (end == knots.len - 1 or knots[end].constrained()) {
                try solveSpan(knots, start, end - start, false, options, work, segments);
                start = end;
            }
        }
    } else {
        var breakpoint: ?usize = null;
        for (knots, 0..) |knot, i| {
            if (knot.constrained()) {
                breakpoint = i;
                break;
            }
        }
        if (breakpoint) |first| {
            var start = first;
            var length: usize = 0;
            for (1..knots.len + 1) |offset| {
                const end = (first + offset) % knots.len;
                length += 1;
                if (end == first or knots[end].constrained()) {
                    try solveSpan(knots, start, length, false, options, work, segments);
                    start = end;
                    length = 0;
                }
            }
        } else {
            try solveSpan(knots, 0, count, true, options, work, segments);
        }
    }
    return segments;
}

fn validate(knots: []const Knot, options: Options) Error!void {
    if (knots.len < 2) return error.TooFewKnots;
    if (!std.math.isFinite(options.start_curl) or !std.math.isFinite(options.end_curl) or
        options.start_curl < 0 or options.end_curl < 0) return error.InvalidCurl;
    if (!std.math.isFinite(options.minimum_chord) or options.minimum_chord < 0) return error.InvalidTolerance;
    for (knots, 0..) |knot, i| {
        if (!knot.point.isFinite()) return error.NonFinite;
        if (!std.math.isFinite(knot.incoming_tension) or !std.math.isFinite(knot.outgoing_tension) or
            knot.incoming_tension < 0.75 or knot.outgoing_tension < 0.75) return error.InvalidTension;
        inline for (.{ knot.incoming_direction, knot.outgoing_direction }) |direction| {
            if (direction) |d| {
                if (!d.isFinite() or (d.x == 0 and d.y == 0)) return error.InvalidDirection;
            }
        }
        if (i + 1 < knots.len or options.closed) {
            const chord = knots[(i + 1) % knots.len].point.sub(knot.point);
            const distance = chord.norm();
            if (!std.math.isFinite(distance)) return error.NumericalFailure;
            if (distance <= options.minimum_chord) return error.CoincidentKnots;
        }
    }
}

const Row = struct {
    distance: f64 = 0,
    chord_angle: f64 = 0,
    psi: f64 = 0,
    lower: f64 = 0,
    diagonal: f64 = 1,
    upper: f64 = 0,
    rhs: f64 = 0,
    auxiliary_rhs: f64 = 0,
    theta: f64 = 0,
    auxiliary: f64 = 0,
    upper_factor: f64 = 0,
    rhs_factor: f64 = 0,
};

fn at(knots: []const Knot, start: usize, offset: usize) Knot {
    return knots[(start + offset) % knots.len];
}

fn wrapped(angle: f64) f64 {
    // Chord and given angles come from atan2, hence their difference is in
    // [-2*pi,2*pi]. MetaPost makes an exact reversal a +pi turning angle.
    if (angle > std.math.pi) return angle - 2 * std.math.pi;
    if (angle <= -std.math.pi) return angle + 2 * std.math.pi;
    return angle;
}

fn solveSpan(knots: []const Knot, start: usize, length: usize, cyclic: bool, options: Options, storage: []Row, segments: []Cubic) Error!void {
    const count = if (cyclic) length else length + 1;
    const work = storage[0..count];
    @memset(work, .{});
    for (0..length) |i| {
        const delta = at(knots, start, i + 1).point.sub(at(knots, start, i).point);
        work[i].distance = delta.norm();
        work[i].chord_angle = std.math.atan2(delta.y, delta.x);
    }
    for (1..length) |i| work[i].psi = wrapped(work[i].chord_angle - work[i - 1].chord_angle);
    if (cyclic) work[0].psi = wrapped(work[0].chord_angle - work[length - 1].chord_angle);

    const first = at(knots, start, 0);
    const last = at(knots, start, length);
    if (!cyclic and length == 1 and first.outgoing() == null and last.incoming() == null) {
        // Two curl endpoints are MetaPost's explicit straight-line case. Their
        // default curl equations alone would be singular when both curls=1.
        work[0].theta = 0;
        work[1].theta = 0;
    } else {
        for (0..count) |i| {
            if (!cyclic and i == 0) {
                if (first.outgoing()) |direction| {
                    work[i].rhs = wrapped(std.math.atan2(direction.y, direction.x) - work[0].chord_angle);
                } else {
                    work[i].upper = curlRatio(options.start_curl, first.outgoing_tension, at(knots, start, 1).incoming_tension);
                    work[i].rhs = -work[i].upper * work[1].psi;
                }
            } else if (!cyclic and i == length) {
                if (last.incoming()) |direction| {
                    work[i].rhs = wrapped(std.math.atan2(direction.y, direction.x) - work[length - 1].chord_angle);
                } else {
                    work[i].lower = curlRatio(options.end_curl, last.incoming_tension, at(knots, start, length - 1).outgoing_tension);
                }
            } else {
                const previous = (i + length - 1) % length;
                const next = (i + 1) % count;
                const current_knot = at(knots, start, i);
                const alpha_previous = 1 / at(knots, start, previous).outgoing_tension;
                const beta_next = 1 / at(knots, start, i + 1).incoming_tension;
                // Normalize A*theta[-1]+(B+C)*theta+D*theta[1] by B+C.
                // Logarithms preserve the B:C ratio for extreme but finite
                // coordinates/tensions without squaring reciprocals to zero.
                const log_b = @log(3 - alpha_previous) + 2 * @log(current_knot.incoming_tension) - @log(work[previous].distance);
                const log_c = @log(3 - beta_next) + 2 * @log(current_knot.outgoing_tension) - @log(work[i].distance);
                var b: f64 = undefined;
                var c: f64 = undefined;
                if (log_b >= log_c) {
                    const ratio = @exp(log_c - log_b);
                    b = 1 / (1 + ratio);
                    c = ratio / (1 + ratio);
                } else {
                    const ratio = @exp(log_b - log_c);
                    b = ratio / (1 + ratio);
                    c = 1 / (1 + ratio);
                }
                work[i].lower = b * alpha_previous / (3 - alpha_previous);
                work[i].upper = c * beta_next / (3 - beta_next);
                work[i].rhs = -b * work[i].psi - work[i].upper * work[next].psi;
            }
        }
        if (cyclic) try solveCyclic(work) else try solveTridiagonal(work, "rhs", "theta");
    }

    for (0..length) |i| {
        const next = if (cyclic) (i + 1) % length else i + 1;
        const theta = work[i].theta;
        const phi = -work[next].psi - work[next].theta;
        const p = at(knots, start, i);
        const q = at(knots, start, i + 1);
        const delta = q.point.sub(p.point);
        const st = @sin(theta);
        const ct = @cos(theta);
        const sf = @sin(phi);
        const cf = @cos(phi);
        const outgoing = velocity(st, ct, sf, cf, p.outgoing_tension);
        const incoming = velocity(sf, cf, st, ct, q.incoming_tension);
        const cubic: Cubic = .{
            .p0 = p.point,
            .p1 = p.point.add(.{ .x = (delta.x * ct - delta.y * st) * outgoing, .y = (delta.y * ct + delta.x * st) * outgoing }),
            .p2 = q.point.sub(.{ .x = (delta.x * cf + delta.y * sf) * incoming, .y = (delta.y * cf - delta.x * sf) * incoming }),
            .p3 = q.point,
        };
        if (!cubic.isFinite()) return error.NumericalFailure;
        segments[(start + i) % segments.len] = cubic;
    }
}

/// Hobby's endpoint ratio, capped at 4 as in MetaPost's curl_ratio.
fn curlRatio(curl: f64, a_tension: f64, b_tension: f64) f64 {
    const alpha = 1 / a_tension;
    const beta = 1 / b_tension;
    if (curl == 0) return beta / (3 - beta);
    const log_chi = 2 * (@log(alpha) - @log(beta)) + @log(curl);
    var numerator: f64 = undefined;
    var denominator: f64 = undefined;
    if (log_chi >= 0) {
        const inverse_chi = @exp(-log_chi);
        numerator = (3 - alpha) + beta * inverse_chi;
        denominator = alpha + (3 - beta) * inverse_chi;
    } else {
        const chi = @exp(log_chi);
        numerator = (3 - alpha) * chi + beta;
        denominator = alpha * chi + (3 - beta);
    }
    return if (numerator >= 4 * denominator) 4 else numerator / denominator;
}

/// Distance from a knot to its control, divided by chord length: f/(3*tension).
fn velocity(st: f64, ct: f64, sf: f64, cf: f64, tension: f64) f64 {
    const numerator = (2 + @sqrt(@as(f64, 2)) * (st - sf / 16) * (sf - st / 16) * (ct - cf)) / tension;
    const denominator = 3 * (1 + 0.5 * (@sqrt(@as(f64, 5)) - 1) * ct + 0.5 * (3 - @sqrt(@as(f64, 5))) * cf);
    return if (numerator >= 4 * denominator) 4 else numerator / denominator;
}

fn solveTridiagonal(work: []Row, comptime rhs_field: []const u8, comptime output_field: []const u8) Error!void {
    for (work, 0..) |*row, i| {
        const previous_upper = if (i == 0) 0 else work[i - 1].upper_factor;
        const previous_rhs = if (i == 0) 0 else work[i - 1].rhs_factor;
        const pivot = row.diagonal - row.lower * previous_upper;
        if (pivot == 0 or !std.math.isFinite(pivot)) return error.NumericalFailure;
        row.upper_factor = row.upper / pivot;
        row.rhs_factor = (@field(row, rhs_field) - row.lower * previous_rhs) / pivot;
    }
    var i = work.len;
    var next: f64 = 0;
    while (i != 0) {
        i -= 1;
        next = work[i].rhs_factor - work[i].upper_factor * next;
        if (!std.math.isFinite(next)) return error.NumericalFailure;
        @field(work[i], output_field) = next;
    }
}

fn solveCyclic(work: []Row) Error!void {
    if (work.len == 2) {
        // For a two-knot cycle both off-diagonal neighbors are the same knot.
        const upper = work[0].lower + work[0].upper;
        const lower = work[1].lower + work[1].upper;
        const determinant = 1 - upper * lower;
        work[0].theta = (work[0].rhs - upper * work[1].rhs) / determinant;
        work[1].theta = (work[1].rhs - lower * work[0].rhs) / determinant;
        if (!std.math.isFinite(work[0].theta) or !std.math.isFinite(work[1].theta)) return error.NumericalFailure;
        return;
    }
    // Sherman-Morrison reduces the cyclic matrix to two tridiagonal solves.
    const last = work.len - 1;
    const alpha = work[0].lower;
    const beta = work[last].upper;
    const gamma = -work[0].diagonal;
    work[0].diagonal -= gamma;
    work[last].diagonal -= alpha * beta / gamma;
    work[0].lower = 0;
    work[last].upper = 0;
    try solveTridiagonal(work, "rhs", "theta");
    work[0].auxiliary_rhs = gamma;
    work[last].auxiliary_rhs = beta;
    try solveTridiagonal(work, "auxiliary_rhs", "auxiliary");
    const denominator = 1 + work[0].auxiliary + alpha * work[last].auxiliary / gamma;
    if (denominator == 0 or !std.math.isFinite(denominator)) return error.NumericalFailure;
    const correction = (work[0].theta + alpha * work[last].theta / gamma) / denominator;
    for (work) |*row| {
        row.theta -= correction * row.auxiliary;
        if (!std.math.isFinite(row.theta)) return error.NumericalFailure;
    }
}

fn expectReference(knots: []const Knot, options: Options, expected: []const [8]f64) !void {
    try expectReferenceTolerance(knots, options, expected, 1e-8);
}

fn expectReferenceTolerance(knots: []const Knot, options: Options, expected: []const [8]f64, tolerance: f64) !void {
    const segments = try interpolate(std.testing.allocator, knots, options);
    defer std.testing.allocator.free(segments);
    try std.testing.expectEqual(expected.len, segments.len);
    for (segments, expected, 0..) |segment, reference, i| {
        const values: [8]f64 = .{ segment.p0.x, segment.p0.y, segment.p1.x, segment.p1.y, segment.p2.x, segment.p2.y, segment.p3.x, segment.p3.y };
        for (values, reference, 0..) |actual, wanted, component| {
            std.testing.expectApproxEqAbs(wanted, actual, tolerance) catch |err| {
                std.debug.print("segment={d} component={d}\n", .{ i, component });
                return err;
            };
        }
    }
}

const up: Point = .{ .x = 0, .y = 1 };
const right: Point = .{ .x = 1, .y = 0 };
const left: Point = .{ .x = -1, .y = 0 };
const example_open = [_]Knot{
    .{ .point = .{ .x = 0, .y = 0 } },    .{ .point = .{ .x = 60, .y = 80 } },
    .{ .point = .{ .x = 130, .y = 20 } }, .{ .point = .{ .x = 210, .y = 90 } },
};
const example_closed = [_]Knot{
    .{ .point = .{ .x = 0, .y = 0 } },     .{ .point = .{ .x = 90, .y = 10 } },
    .{ .point = .{ .x = 110, .y = 100 } }, .{ .point = .{ .x = 10, .y = 80 } },
};
// These control coordinates were generated by the independent MetaPost 3.00
// interpreter, not by this implementation. Source and full CSV are retained in
// tests/fixtures/hobby-reference.mp and hobby-reference.csv.

test "MetaPost 3.00 reference: open" {
    const knots = example_open;
    try expectReference(&knots, .{}, &.{
        .{ 0, 0, -26.89934595132959, 41.592101827632661, 12.539765379100359, 94.177583601539268, 60, 80 },
        .{ 60, 80, 90.623309286523408, 70.852035793049154, 101.2577036620732, 32.930409011839203, 130, 20 },
        .{ 130, 20, 175.63665808768383, -0.5307414574438809, 224.29109001697748, 42.041886480688071, 210, 90 },
    });
}

test "MetaPost 3.00 reference: closed" {
    const knots = example_closed;
    try expectReference(&knots, .{ .closed = true }, &.{
        .{ 0, 0, 22.415467406020174, -25.181541126102129, 62.176866152585475, -15.054891024936087, 90, 10 },
        .{ 90, 10, 118.16225220888151, 35.360269047329481, 132.70372572815771, 74.288631586769654, 110, 100 },
        .{ 110, 100, 84.522345081129671, 128.85276979503843, 38.07228155246753, 114.50193683856797, 10, 80 },
        .{ 10, 80, -9.9919898148426398, 55.42905913864471, -19.685315514812448, 22.114487877393664, 0, 0 },
    });
}

test "MetaPost 3.00 reference: directions" {
    var knots = example_open[0..3].*;
    knots[0].outgoing_direction = up;
    knots[2].incoming_direction = right;
    try expectReference(&knots, .{}, &.{
        .{ 0, 0, 0, 46.694674296881139, 24.197275169291373, 89.623032714539434, 60, 80 },
        .{ 60, 80, 91.08830714196894, 71.644105355628724, 95.018540025064141, 20.000000000000004, 130, 20 },
    });
}

test "MetaPost 3.00 scaled reference: tension" {
    var knots = example_open;
    knots[0].outgoing_tension = 1.7;
    knots[1].incoming_tension = 0.8;
    knots[1].outgoing_tension = 0.75;
    knots[2].incoming_tension = 2.2;
    knots[2].outgoing_tension = 1.3;
    knots[3].incoming_tension = 1.1;
    try expectReferenceTolerance(&knots, .{}, &.{
        .{ 0, 0, -5.12157, 23.65804, 9.65222, 78.77109, 60, 80 },
        .{ 60, 80, 103.8322, 81.06987, 121.20847, 32.32655, 130, 20 },
        .{ 130, 20, 168.48444, -33.95872, 266.79073, 45.66685, 210, 90 },
    }, 0.03125);
}

test "MetaPost 3.00 reference: curl" {
    const knots = example_open;
    try expectReference(&knots, .{ .start_curl = 0, .end_curl = 2.5 }, &.{
        .{ 0, 0, 6.1184399944289769, 40.543512165505923, 23.454792365765464, 82.200720582846841, 60, 80 },
        .{ 60, 80, 93.045422061274422, 78.010033457000191, 104.57236764495347, 38.932832748385735, 130, 20 },
        .{ 130, 20, 199.21289792717573, -31.534338792901522, 255.74036546037081, 57.965738401800969, 210, 90 },
    });
}

test "MetaPost 3.00 reference: corner" {
    var knots = example_open;
    knots[1].outgoing_direction = right;
    knots[2].incoming_direction = up;
    knots[2].outgoing_direction = left;
    try expectReference(&knots, .{}, &.{
        .{ 0, 0, -11.666666666666666, 40, 18.333333333333336, 80, 60, 80 },
        .{ 60, 80, 82.311075300921942, 80, 130, -87.786650949264583, 130, 20 },
        .{ 130, 20, -156.42264991006994, 20.000000000000057, 248.02070574027471, 373.88793619405163, 210, 90 },
    });
}

test "MetaPost 3.00 reference: closed_direction" {
    var knots = example_closed;
    knots[0].outgoing_direction = right;
    try expectReference(&knots, .{ .closed = true }, &.{
        .{ 0, 0, 30.700861140543569, 0, 62.763947200311442, -4.4909321750144802, 90, 10 },
        .{ 90, 10, 126.60933410150687, 29.477983147523002, 137.78993214174065, 75.588051378220939, 110, 100 },
        .{ 110, 100, 82.133988469249459, 124.47878024001452, 42.583911257915027, 103.47434615982699, 10, 80 },
        .{ 10, 80, -33.224145846542669, 48.860136094984057, -29.017509997348419, 7.6721118012432357e-15, 0, 0 },
    });
}

test "MetaPost 3.00 reference: closed_tension" {
    var knots = example_closed;
    knots[0].outgoing_tension = 1.7;
    knots[1].incoming_tension = 0.8;
    knots[1].outgoing_tension = 0.75;
    knots[2].incoming_tension = 2.2;
    knots[2].outgoing_tension = 1.3;
    knots[3].incoming_tension = 1.1;
    knots[3].outgoing_tension = 1.1;
    knots[0].incoming_tension = 1.4;
    try expectReference(&knots, .{ .closed = true }, &.{
        .{ 0, 0, 12.593144133505181, -15.46010340671072, 55.26860059266599, -23.063720501549895, 90, 10 },
        .{ 90, 10, 124.60315969475566, 42.941638406205513, 118.63787163317532, 87.173219652820592, 110, 100 },
        .{ 110, 100, 93.394643945447413, 124.65807131011444, 35.939081974622866, 115.25522179135768, 10, 80 },
        .{ 10, 80, -6.6904173058939698, 57.315143053818048, -13.230121394970501, 16.242095117881284, 0, 0 },
    });
}

test "MetaPost 3.00 reference: two_closed" {
    const knots = example_closed[0..2].*;
    try expectReference(&knots, .{ .closed = true }, &.{
        .{ 0, 0, 6.6666666666666661, -60, 96.666666666666671, -50, 90, 10 },
        .{ 90, 10, 83.333333333333329, 70, -6.6666666666666661, 60, 0, 0 },
    });
}

test "MetaPost 3.00 reference: two_open" {
    var knots = example_closed[0..2].*;
    knots[0].outgoing_tension = 1.7;
    knots[1].incoming_tension = 0.8;
    try expectReference(&knots, .{}, &.{
        .{ 0, 0, 17.647058823529413, 1.9607843137254903, 52.5, 5.8333333333333339, 90, 10 },
    });
}

test "MetaPost 3.00 reference: two_given" {
    var knots = example_closed[0..2].*;
    knots[0].outgoing_tension = 1.7;
    knots[1].incoming_tension = 0.8;
    knots[0].outgoing_direction = up;
    knots[1].incoming_direction = right;
    try expectReference(&knots, .{}, &.{
        .{ 0, 0, 1.4003773332495435e-15, 23.795812136435909, 43.086341144585617, 10, 90, 10 },
    });
}

test "MetaPost 3.00 scaled reference: one_given" {
    var knots = example_closed[0..2].*;
    knots[0].outgoing_tension = 1.7;
    knots[1].incoming_tension = 0.8;
    knots[0].outgoing_direction = up;
    try expectReferenceTolerance(&knots, .{}, &.{
        .{ 0, 0, 0, 34.4552, 80.38048, 76.93054, 90, 10 },
    }, 0.03125);
}

test "MetaPost 3.00 scaled reference: tension_curl" {
    var knots = example_open;
    knots[0].outgoing_tension = 0.75;
    knots[1].incoming_tension = 2.2;
    knots[2].outgoing_tension = 1.3;
    knots[3].incoming_tension = 1.1;
    try expectReferenceTolerance(&knots, .{ .start_curl = 2.5, .end_curl = 0.2 }, &.{
        .{ 0, 0, -87.06512, 32.11069, 28.69981, 104.9684, 60, 80 },
        .{ 60, 80, 85.09882, 59.97849, 96.08899, 18.209, 130, 20 },
        .{ 130, 20, 158.95169, 21.52908, 193.55852, 59.12325, 210, 90 },
    }, 0.03125);
}

fn expectMockCurvature(knots: []const Knot, options: Options) !void {
    const curves = try interpolate(std.testing.allocator, knots, options);
    defer std.testing.allocator.free(curves);
    var previous_end: f64 = 0;
    var first_start: f64 = 0;
    for (curves, 0..) |curve, i| {
        const chord = curve.p3.sub(curve.p0);
        const angle = std.math.atan2(chord.y, chord.x);
        const outgoing = curve.p1.sub(curve.p0);
        const incoming = curve.p3.sub(curve.p2);
        const theta = wrapped(std.math.atan2(outgoing.y, outgoing.x) - angle);
        const phi = wrapped(angle - std.math.atan2(incoming.y, incoming.x));
        const alpha = 1 / knots[i].outgoing_tension;
        const beta = 1 / knots[(i + 1) % knots.len].incoming_tension;
        // Independently evaluate the published endpoint mock-curvatures from
        // the actual returned cubics, not the internal solver coefficients.
        const start = (2 * beta * (theta + phi) - 6 * theta) / (alpha * alpha * chord.norm());
        const end = (2 * alpha * (theta + phi) - 6 * phi) / (beta * beta * chord.norm());
        if (i == 0) {
            first_start = start;
            if (!options.closed) try std.testing.expectApproxEqAbs(options.start_curl * end, start, 1e-10);
        } else {
            try std.testing.expectApproxEqAbs(previous_end, start, 1e-10);
            const prior_tangent = curves[i - 1].p3.sub(curves[i - 1].p2);
            try std.testing.expectApproxEqAbs(@as(f64, 0), prior_tangent.cross(outgoing) / (prior_tangent.norm() * outgoing.norm()), 1e-12);
            try std.testing.expect(prior_tangent.dot(outgoing) > 0);
        }
        previous_end = end;
        if (!options.closed and i + 1 == curves.len) try std.testing.expectApproxEqAbs(options.end_curl * start, end, 1e-10);
    }
    if (options.closed) try std.testing.expectApproxEqAbs(previous_end, first_start, 1e-10);
}

test "returned controls preserve the published mock-curvature and curl equations" {
    try expectMockCurvature(&example_open, .{});
    try expectMockCurvature(&example_closed, .{ .closed = true });
    var knots = example_open;
    knots[0].outgoing_tension = 0.75;
    knots[1].incoming_tension = 2.2;
    knots[2].outgoing_tension = 1.3;
    knots[3].incoming_tension = 1.1;
    try expectMockCurvature(&knots, .{ .start_curl = 2.5, .end_curl = 0.2 });
}

test "translation rotation scaling reflection and reverse traversal" {
    var knots = example_open;
    knots[0].outgoing_direction = up;
    knots[2].outgoing_tension = 1.5;
    const options: Options = .{ .end_curl = 0.3 };
    const reference = try interpolate(std.testing.allocator, &knots, options);
    defer std.testing.allocator.free(reference);
    const transform = geometry.Transform.rotation(0.713).then(geometry.Transform.scaling(2.5, -2.5)).then(geometry.Transform.translation(83, -17));
    const linear = geometry.Transform.rotation(0.713).then(geometry.Transform.scaling(2.5, -2.5));
    var transformed = knots;
    for (&transformed) |*knot| {
        knot.point = transform.apply(knot.point);
        if (knot.incoming_direction) |d| knot.incoming_direction = linear.apply(d);
        if (knot.outgoing_direction) |d| knot.outgoing_direction = linear.apply(d);
    }
    const result = try interpolate(std.testing.allocator, &transformed, options);
    defer std.testing.allocator.free(result);
    for (result, reference) |actual, original| {
        const expected = original.transformed(transform);
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
    var reverse: [knots.len]Knot = undefined;
    for (&reverse, 0..) |*target, i| {
        const source = knots[knots.len - 1 - i];
        target.* = .{ .point = source.point, .incoming_tension = source.outgoing_tension, .outgoing_tension = source.incoming_tension, .incoming_direction = if (source.outgoing_direction) |d| d.scale(-1) else null, .outgoing_direction = if (source.incoming_direction) |d| d.scale(-1) else null };
    }
    const reversed = try interpolate(std.testing.allocator, &reverse, .{ .start_curl = options.end_curl, .end_curl = options.start_curl });
    defer std.testing.allocator.free(reversed);
    for (reversed, 0..) |actual, i| {
        const expected = reference[reference.len - 1 - i].reversed();
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
}

test "closed constrained paths are independent of the first knot index" {
    var knots = example_closed;
    knots[1].outgoing_direction = right;
    knots[3].incoming_direction = up;
    knots[3].outgoing_direction = left;
    const original = try interpolate(std.testing.allocator, &knots, .{ .closed = true });
    defer std.testing.allocator.free(original);
    var shifted: [knots.len]Knot = undefined;
    for (&shifted, 0..) |*knot, i| knot.* = knots[(i + 2) % knots.len];
    const result = try interpolate(std.testing.allocator, &shifted, .{ .closed = true });
    defer std.testing.allocator.free(result);
    for (result, 0..) |actual, i| {
        const expected = original[(i + 2) % knots.len];
        inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
            try std.testing.expect(geometry.tolerance.points(@field(actual, field), @field(expected, field)));
        }
    }
}

test "finite extreme scales and large batches keep valid controls" {
    const reference = try interpolate(std.testing.allocator, &example_open, .{});
    defer std.testing.allocator.free(reference);
    for ([_]f64{ 1e-250, 1e250 }) |scale| {
        var knots = example_open;
        for (&knots) |*knot| knot.point = knot.point.scale(scale);
        const result = try interpolate(std.testing.allocator, &knots, .{});
        defer std.testing.allocator.free(result);
        for (result, reference) |actual, expected| {
            inline for (.{ "p0", "p1", "p2", "p3" }) |field| {
                const rescaled = @field(actual, field).scale(1 / scale);
                try std.testing.expectApproxEqAbs(@field(expected, field).x, rescaled.x, 1e-9);
                try std.testing.expectApproxEqAbs(@field(expected, field).y, rescaled.y, 1e-9);
            }
        }
    }
    var batch: [2048]Knot = undefined;
    for (&batch, 0..) |*knot, i| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / batch.len;
        knot.* = .{ .point = .{ .x = 100 * @cos(angle), .y = 100 * @sin(angle) } };
    }
    const result = try interpolate(std.testing.allocator, &batch, .{ .closed = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(batch.len, result.len);
    for (result) |curve| try std.testing.expect(curve.isFinite());
}

test "invalid inputs and unrepresentable arithmetic are diagnosed" {
    try std.testing.expectError(error.TooFewKnots, interpolate(std.testing.allocator, &.{}, .{}));
    var knots = example_open;
    knots[1].point = knots[0].point;
    try std.testing.expectError(error.CoincidentKnots, interpolate(std.testing.allocator, &knots, .{}));
    knots = example_open;
    knots[3].point = knots[0].point;
    try std.testing.expectError(error.CoincidentKnots, interpolate(std.testing.allocator, &knots, .{ .closed = true }));
    knots = example_open;
    try std.testing.expectError(error.CoincidentKnots, interpolate(std.testing.allocator, &knots, .{ .minimum_chord = 101 }));
    knots[0].point.x = std.math.nan(f64);
    try std.testing.expectError(error.NonFinite, interpolate(std.testing.allocator, &knots, .{}));
    knots = example_open;
    knots[0].incoming_tension = 0.74;
    try std.testing.expectError(error.InvalidTension, interpolate(std.testing.allocator, &knots, .{}));
    knots = example_open;
    knots[2].outgoing_tension = std.math.inf(f64);
    try std.testing.expectError(error.InvalidTension, interpolate(std.testing.allocator, &knots, .{}));
    knots = example_open;
    knots[1].outgoing_direction = Point.zero;
    try std.testing.expectError(error.InvalidDirection, interpolate(std.testing.allocator, &knots, .{}));
    knots[1].outgoing_direction = .{ .x = std.math.inf(f64), .y = 0 };
    try std.testing.expectError(error.InvalidDirection, interpolate(std.testing.allocator, &knots, .{}));
    try std.testing.expectError(error.InvalidCurl, interpolate(std.testing.allocator, &example_open, .{ .start_curl = -1 }));
    try std.testing.expectError(error.InvalidTolerance, interpolate(std.testing.allocator, &example_open, .{ .minimum_chord = -1 }));
    knots = example_open;
    knots[0].point.x = -1e308;
    knots[1].point.x = 1e308;
    try std.testing.expectError(error.NumericalFailure, interpolate(std.testing.allocator, &knots, .{}));
}

fn allocationFailureExercise(allocator: std.mem.Allocator) !void {
    const result = try interpolate(allocator, &example_closed, .{ .closed = true });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 4), result.len);
}

test "allocation failure frees all partially allocated storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExercise, .{});
}
