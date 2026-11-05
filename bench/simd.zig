//! Standalone bulk-transform microbenchmark; see docs/simd.md for build flags.
const std = @import("std");
const builtin = @import("builtin");
const simd = @import("simd");
const Point = simd.Point;
const Transform = simd.Transform;

const Kind = enum { scalar, vector };
const trial_count = 8;
const points_per_trial = 4_000_000;
const Result = struct { nanoseconds: f64, checksum: f64 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const sizes = [_]usize{ 1, 2, 3, 4, 8, 16, 64, 256, 1024, 16384, 65536 };
    const capacity = sizes[sizes.len - 1];
    const source = try allocator.alloc(Point, capacity);
    const scalar_out = try allocator.alloc(Point, capacity);
    const vector_out = try allocator.alloc(Point, capacity);
    fill(source);
    std.debug.print("zig={s},mode={s},backend={s},arch={s},cpu={s},lanes={d},trials={d},points_per_trial={d}\n", .{
        builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.zig_backend), @tagName(builtin.cpu.arch),
        builtin.cpu.model.name,     simd.lanes,             trial_count,                   points_per_trial,
    });
    std.debug.print("points,repeats,scalar_ns_per_point,simd_ns_per_point,scalar_over_simd,scalar_min_ns_per_point,scalar_max_ns_per_point,simd_min_ns_per_point,simd_max_ns_per_point,checksum\n", .{});
    for (sizes) |size| {
        const input = source[0..size];
        const scalar = scalar_out[0..size];
        const vector = vector_out[0..size];
        const repeats = @min(@as(usize, 1_000_000), @max(@as(usize, 16), points_per_trial / size));
        // Warm both paths, including the identical validation contract. All
        // point comparisons and reporting remain outside the measured region.
        _ = try trial(.scalar, init.io, input, scalar, 16);
        _ = try trial(.vector, init.io, input, vector, 16);
        var scalar_times: [trial_count]f64 = undefined;
        var vector_times: [trial_count]f64 = undefined;
        var checksum: f64 = 0;
        for (0..trial_count) |i| {
            const scalar_result: Result, const vector_result: Result = if (i % 2 == 0) .{
                try trial(.scalar, init.io, input, scalar, repeats),
                try trial(.vector, init.io, input, vector, repeats),
            } else blk: {
                const v = try trial(.vector, init.io, input, vector, repeats);
                const s = try trial(.scalar, init.io, input, scalar, repeats);
                break :blk .{ s, v };
            };
            try compare(scalar, vector);
            if (!close(scalar_result.checksum, vector_result.checksum)) return error.ChecksumMismatch;
            std.debug.print("trial,points={d},index={d},first={s},scalar_ns={d},simd_ns={d}\n", .{
                size, i, if (i % 2 == 0) "scalar" else "simd", scalar_result.nanoseconds, vector_result.nanoseconds,
            });
            checksum += scalar_result.checksum;
            scalar_times[i] = scalar_result.nanoseconds;
            vector_times[i] = vector_result.nanoseconds;
        }
        std.mem.sort(f64, &scalar_times, {}, std.sort.asc(f64));
        std.mem.sort(f64, &vector_times, {}, std.sort.asc(f64));
        const points: f64 = @floatFromInt(size * repeats);
        std.debug.print("{d},{d},{d:.4},{d:.4},{d:.3},{d:.4},{d:.4},{d:.4},{d:.4},{d:.9}\n", .{
            size,                                          repeats,                  median(&scalar_times) / points,         median(&vector_times) / points,
            median(&scalar_times) / median(&vector_times), scalar_times[0] / points, scalar_times[trial_count - 1] / points, vector_times[0] / points,
            vector_times[trial_count - 1] / points,        checksum,
        });
    }
}

fn fill(points: []Point) void {
    var state: u64 = 0x390eac471b;
    std.mem.doNotOptimizeAway(&state);
    for (points) |*point| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        point.x = @as(f64, @floatFromInt(state >> 11)) / 9007199254740992.0 * 200 - 100;
        state = state *% 6364136223846793005 +% 1442695040888963407;
        point.y = @as(f64, @floatFromInt(state >> 11)) / 9007199254740992.0 * 200 - 100;
    }
}

fn trial(comptime kind: Kind, io: std.Io, source: []const Point, destination: []Point, repeats: usize) !Result {
    var transform: Transform = .{ .a = 1.231, .b = -0.517, .c = 0.193, .d = 0.837, .e = 0.1, .f = -0.2 };
    const start = std.Io.Clock.awake.now(io);
    for (0..repeats) |iteration| {
        const shift = @as(f64, @floatFromInt(iteration & 1023)) * 0.000003;
        transform.e = 0.1 + shift;
        transform.f = -0.2 - shift;
        const kernel = if (kind == .scalar) simd.transformPointsScalar else simd.transformPointsSimd;
        // Equal call boundaries preserve the normal optimizer inside either
        // implementation while stopping whole-benchmark specialization.
        try @call(.never_inline, kernel, .{ source, destination, transform });
        // The pointer escape has a compiler memory clobber. Every output
        // buffer is observable after every call, not merely the last call.
        std.mem.doNotOptimizeAway(destination.ptr);
    }
    const end = std.Io.Clock.awake.now(io);
    var checksum: f64 = 0;
    for (destination, 0..) |point, i| checksum += point.x + point.y * @as(f64, @floatFromInt((i & 7) + 1));
    std.mem.doNotOptimizeAway(checksum);
    return .{ .nanoseconds = @floatFromInt(start.durationTo(end).toNanoseconds()), .checksum = checksum };
}

fn close(a: f64, b: f64) bool {
    return std.math.isFinite(a) and std.math.isFinite(b) and @abs(a - b) <= 1e-9 + 1e-12 * @max(@abs(a), @abs(b));
}

fn median(sorted: []const f64) f64 {
    return (sorted[sorted.len / 2 - 1] + sorted[sorted.len / 2]) * 0.5;
}

fn compare(expected: []const Point, actual: []const Point) !void {
    for (expected, actual) |a, b| {
        if (@as(u64, @bitCast(a.x)) != @as(u64, @bitCast(b.x)) or
            @as(u64, @bitCast(a.y)) != @as(u64, @bitCast(b.y))) return error.PointMismatch;
    }
}
