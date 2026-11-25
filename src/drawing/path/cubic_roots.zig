//! Real roots of a cubic on [0, 1].
const std = @import("std");
const g = @import("../geometry.zig");

fn polynomial(coeff: [4]f64, t: f64) f64 {
    return ((coeff[0] * t + coeff[1]) * t + coeff[2]) * t + coeff[3];
}

/// A common scale does not change roots. Apply it before differences and
/// factors of three so finite Bezier values do not overflow the power basis.
pub fn bezierPolynomial(v0: f64, v1: f64, v2: f64, v3: f64, value: f64) [4]f64 {
    const magnitude = @max(@max(@max(@abs(v0), @abs(v1)), @max(@abs(v2), @abs(v3))), @abs(value));
    const scale = if (magnitude == 0) 1 else magnitude;
    const a = v0 / scale;
    const ab = v1 / scale - a;
    const bc = v2 / scale - v1 / scale;
    const cd = v3 / scale - v2 / scale;
    return .{ ab - 2 * bc + cd, 3 * (bc - ab), 3 * ab, a - value / scale };
}

fn insertRoot(roots: *std.ArrayList(f64), allocator: std.mem.Allocator, t: f64) !void {
    const value = std.math.clamp(t, 0, 1);
    for (roots.items) |old| if (@abs(old - value) < 16 * std.math.floatEps(f64)) return;
    try roots.append(allocator, value);
}

/// All roots in [0,1], including double roots at derivative extrema. The
/// derivative partitions the cubic into monotone intervals, then bisection
/// isolates crossings; no flatness approximation is used.
pub fn cubicRootsUnit(allocator: std.mem.Allocator, coeff: [4]f64) ![]f64 {
    var roots: std.ArrayList(f64) = .empty;
    errdefer roots.deinit(allocator);
    var scale: f64 = 0;
    for (coeff) |c| {
        if (!std.math.isFinite(c)) return error.NonFinite;
        scale = @max(scale, @abs(c));
    }
    if (scale == 0) return error.CoincidentCurves;
    var normalized: [4]f64 = undefined;
    for (coeff, 0..) |c, i| normalized[i] = c / scale;
    var critical: [2]f64 = undefined;
    const n = g.quadraticRoots(3 * normalized[0], 2 * normalized[1], normalized[2], &critical);
    var divisions: [4]f64 = undefined;
    var length: usize = 1;
    divisions[0] = 0;
    for (critical[0..n]) |t| if (t > 0 and t < 1) {
        divisions[length] = t;
        length += 1;
    };
    divisions[length] = 1;
    length += 1;
    var crossing: [3]bool = @splat(false);
    for (0..length - 1) |i| {
        var lo = divisions[i];
        var hi = divisions[i + 1];
        var flo = polynomial(normalized, lo);
        const fhi = polynomial(normalized, hi);
        if (flo == 0 or fhi == 0 or (flo > 0) == (fhi > 0)) continue;
        crossing[i] = true;
        var step: usize = 0;
        while (step < 64 and hi - lo > 2e-15) : (step += 1) {
            const mid = (lo + hi) * 0.5;
            const fmid = polynomial(normalized, mid);
            if (fmid == 0) {
                lo = mid;
                hi = mid;
                break;
            }
            if ((fmid > 0) == (flo > 0)) {
                lo = mid;
                flo = fmid;
            } else hi = mid;
        }
        try insertRoot(&roots, allocator, (lo + hi) * 0.5);
    }
    const epsilon = 64 * std.math.floatEps(f64);
    for (divisions[0..length], 0..) |t, i| {
        const value = polynomial(normalized, t);
        const adjacent_crossing = (i > 0 and crossing[i - 1]) or (i + 1 < length and crossing[i]);
        // A near-zero extremum between two crossings is not a third root.
        // Retain approximate tangencies only when neither neighboring interval
        // already supplies a crossing; strict callers verify spatial residuals.
        if (value == 0 or (@abs(value) <= epsilon and !adjacent_crossing)) try insertRoot(&roots, allocator, t);
    }
    std.mem.sort(f64, roots.items, {}, std.sort.asc(f64));
    return roots.toOwnedSlice(allocator);
}
