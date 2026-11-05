//! Optional bulk geometry kernels. The scalar and explicit SIMD interfaces
//! share validation, ownership and aliasing contracts. They are not selected
//! automatically by the geometry core; see docs/simd.md for measured results.
const std = @import("std");
const geometry = @import("geometry.zig");

pub const Point = geometry.Point;
pub const Transform = geometry.Transform;
pub const lanes: usize = std.simd.suggestVectorLength(f64) orelse 1;
const Vector = @Vector(lanes, f64);

pub const Error = error{ LengthMismatch, NonFinite, PartialOverlap };

/// Caller owns both slices, which must have equal lengths. Exact in-place
/// transformation is supported; partial overlap is rejected. On NonFinite,
/// destination may be partially written, but written points are finite.
pub fn transformPointsScalar(source: []const Point, destination: []Point, transform: Transform) Error!void {
    try validateSlices(source, destination, transform);
    for (source, destination) |point, *out| {
        if (!point.isFinite()) return error.NonFinite;
        const transformed = transform.apply(point);
        if (!transformed.isFinite()) return error.NonFinite;
        out.* = transformed;
    }
}

/// Explicit @Vector implementation with the same contract as the scalar
/// kernel. AoS input is gathered into x/y vectors, then scattered back without
/// pointer reinterpretation, special alignment, or platform-specific code.
/// The final incomplete vector is evaluated by the scalar kernel.
pub fn transformPointsSimd(source: []const Point, destination: []Point, transform: Transform) Error!void {
    try validateSlices(source, destination, transform);
    const a: Vector = @splat(transform.a);
    const b: Vector = @splat(transform.b);
    const c: Vector = @splat(transform.c);
    const d: Vector = @splat(transform.d);
    const e: Vector = @splat(transform.e);
    const f: Vector = @splat(transform.f);
    var i: usize = 0;
    while (source.len - i >= lanes) : (i += lanes) {
        var x: Vector = undefined;
        var y: Vector = undefined;
        inline for (0..lanes) |lane| {
            x[lane] = source[i + lane].x;
            y[lane] = source[i + lane].y;
        }
        if (!finitePair(x, y)) return error.NonFinite;
        const out_x = a * x + c * y + e;
        const out_y = b * x + d * y + f;
        if (!finitePair(out_x, out_y)) return error.NonFinite;
        inline for (0..lanes) |lane| {
            destination[i + lane] = .{ .x = out_x[lane], .y = out_y[lane] };
        }
    }
    // Do not recheck slices or transform for the already-validated tail.
    while (i < source.len) : (i += 1) {
        const point = source[i];
        if (!point.isFinite()) return error.NonFinite;
        const transformed = transform.apply(point);
        if (!transformed.isFinite()) return error.NonFinite;
        destination[i] = transformed;
    }
}

fn finitePair(x: Vector, y: Vector) bool {
    const maximum: Vector = @splat(std.math.floatMax(f64));
    // Combine the two masks before the horizontal reduction. @max(abs(x),
    // abs(y)) would not be equivalent: it can discard one NaN operand.
    const finite = @select(bool, @abs(x) <= maximum, @abs(y) <= maximum, @as(@Vector(lanes, bool), @splat(false)));
    return @reduce(.And, finite);
}

fn validateSlices(source: []const Point, destination: []Point, transform: Transform) Error!void {
    if (source.len != destination.len) return error.LengthMismatch;
    if (!transform.isFinite()) return error.NonFinite;
    if (source.len == 0) return;
    const s = @intFromPtr(source.ptr);
    const d = @intFromPtr(destination.ptr);
    if (s == d) return;
    const distance = if (s < d) d - s else s - d;
    if (distance / @sizeOf(Point) < source.len) return error.PartialOverlap;
}

fn example(i: usize) Point {
    const x: f64 = @floatFromInt(i);
    return .{ .x = (x - 17) * 0.1237, .y = (x * x - 43) * -0.031 };
}

test "SIMD matches scalar at zero, lane boundaries, tails and unaligned point offsets" {
    const capacity = @max(65, 2 * lanes + 3);
    var source: [capacity]Point = undefined;
    var scalar: [capacity + 2]Point = undefined;
    var vector: [capacity + 2]Point = undefined;
    for (&source, 0..) |*point, i| point.* = example(i);
    const transform: Transform = .{ .a = 1.3, .b = -0.7, .c = 0.231, .d = -2.1, .e = 43, .f = -91 };
    const sentinel: Point = .{ .x = 777, .y = -999 };
    for (0..capacity + 1) |length| {
        @memset(&scalar, sentinel);
        @memset(&vector, sentinel);
        try transformPointsScalar(source[0..length], scalar[1..][0..length], transform);
        try transformPointsSimd(source[0..length], vector[1..][0..length], transform);
        for (scalar[1..][0..length], vector[1..][0..length]) |expected, actual| {
            try std.testing.expect(geometry.tolerance.points(expected, actual));
        }
        try std.testing.expectEqual(sentinel, scalar[0]);
        try std.testing.expectEqual(sentinel, vector[0]);
        try std.testing.expectEqual(sentinel, scalar[length + 1]);
        try std.testing.expectEqual(sentinel, vector[length + 1]);
    }
}

test "both kernels support exact in-place transformation" {
    var scalar: [2 * lanes + 1]Point = undefined;
    for (&scalar, 0..) |*point, i| point.* = example(i);
    var vector = scalar;
    const original = scalar;
    const transform = Transform.rotation(0.329).then(Transform.translation(-72, 8));
    try transformPointsScalar(&scalar, &scalar, transform);
    try transformPointsSimd(&vector, &vector, transform);
    for (original, scalar, vector) |point, expected, actual| {
        try std.testing.expect(geometry.tolerance.points(transform.apply(point), expected));
        try std.testing.expect(geometry.tolerance.points(expected, actual));
    }
}

test "both kernels reject partial overlap, mismatched slices and nonfinite arithmetic" {
    inline for (.{ transformPointsScalar, transformPointsSimd }) |kernel| {
        var points: [2 * lanes + 2]Point = @splat(.{ .x = 3, .y = -7 });
        var output: [2 * lanes + 2]Point = undefined;
        try std.testing.expectError(error.PartialOverlap, kernel(points[0 .. points.len - 1], points[1..], .{}));
        try std.testing.expectError(error.PartialOverlap, kernel(points[1..], points[0 .. points.len - 1], .{}));
        try std.testing.expectError(error.LengthMismatch, kernel(&points, output[0..1], .{}));
        try std.testing.expectError(error.NonFinite, kernel(&points, &output, .{ .e = std.math.inf(f64) }));
        for (0..points.len) |index| {
            points[index].x = std.math.nan(f64);
            try std.testing.expectError(error.NonFinite, kernel(&points, &output, .{}));
            points[index].x = 3;
            points[index].y = std.math.inf(f64);
            try std.testing.expectError(error.NonFinite, kernel(&points, &output, .{}));
            points[index].y = -7;
        }
        points[lanes].x = 1e308;
        try std.testing.expectError(error.NonFinite, kernel(&points, &output, .{ .a = 8 }));
    }
}
