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
    return interpolateAs(Cubic, allocator, knots, options);
}

pub const Span = struct {
    curve: Cubic,
    start: Point = .zero,
    end: Point = .zero,
};
pub fn interpolateSpans(allocator: std.mem.Allocator, knots: []const Knot, options: Options) Error![]Span {
    return interpolateAs(Span, allocator, knots, options);
}

fn interpolateAs(comptime T: type, allocator: std.mem.Allocator, knots: []const Knot, options: Options) Error![]T {
    try validate(knots, options);
    const count = if (options.closed) knots.len else knots.len - 1;
    const segments = try allocator.alloc(T, count);
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

pub fn wrapped(angle: f64) f64 {
    // Chord and given angles come from atan2, hence their difference is in
    // [-2*pi,2*pi]. MetaPost makes an exact reversal a +pi turning angle.
    if (angle > std.math.pi) return angle - 2 * std.math.pi;
    if (angle <= -std.math.pi) return angle + 2 * std.math.pi;
    return angle;
}

fn solveSpan(knots: []const Knot, start: usize, length: usize, cyclic: bool, options: Options, storage: []Row, segments: anytype) Error!void {
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
        segments[(start + i) % segments.len] = if (@TypeOf(segments) == []Cubic) cubic else .{ .curve = cubic };
    }
    if (@TypeOf(segments) == []Span) {
        // A smooth knot has one solved direction. Compute it once, before
        // either adjacent handle is rounded into an absolute control point.
        for (@as(usize, if (cyclic) 0 else 1)..length) |i| {
            const delta = at(knots, start, i + 1).point.sub(at(knots, start, i).point);
            const theta = work[i].theta;
            const chord = delta.normalized() catch return error.NumericalFailure;
            const tangent = geometry.Transform.rotation(theta).apply(chord);
            const index = (start + i) % segments.len;
            segments[index].start = tangent;
            segments[(index + segments.len - 1) % segments.len].end = tangent;
        }
        if (!cyclic) {
            if (first.outgoing()) |v| segments[start].start = v;
            if (last.incoming()) |v| segments[(start + length - 1) % segments.len].end = v;
        }
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

test {
    _ = @import("hobby/reference_test.zig");
    _ = @import("hobby/properties_test.zig");
}
