//! Adaptive geometric key states, not rendered frames. Error is the maximum
//! control-point displacement at the three checked interior times per accepted
//! interval. This bounds spatial Bezier error at those times; it is not a
//! proof over time for an arbitrary caller-supplied function.
const std = @import("std");
const g = @import("../drawing/geometry.zig");
const Path = @import("../drawing/path/Path.zig");
const animation = @import("root.zig");

pub const Options = struct {
    tolerance: f64 = 0.05,
    minimum_depth: u8 = 2,
    maximum_depth: u8 = 12,
    maximum_keys: usize = 4096,
};
pub const Samples = struct {
    allocator: std.mem.Allocator,
    keys: []animation.PathKey,
    evaluations: usize,
    max_accepted_error: f64,

    pub fn deinit(self: *Samples) void {
        for (self.keys) |key| self.allocator.free(key.value);
        self.allocator.free(self.keys);
        self.* = undefined;
    }
};

/// evaluate(scratch_allocator, context, normalized_time) returns an owned Path.
/// It must be deterministic. All paths must have corresponding commands and
/// subpaths. The result owns independent copies; the callback owns no result
/// data after returning. This routine never invokes libtypst or an exporter.
pub fn samplePaths(allocator: std.mem.Allocator, context: anytype, comptime evaluate: anytype, options: Options) !Samples {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0 or
        options.maximum_depth > 24 or options.minimum_depth > options.maximum_depth or options.maximum_keys < 2)
        return error.InvalidSamplingOptions;
    const Sampler = struct {
        allocator: std.mem.Allocator,
        context: @TypeOf(context),
        options: Options,
        keys: std.ArrayList(animation.PathKey) = .empty,
        evaluations: usize = 0,
        max_error: f64 = 0,
        const Self = @This();

        fn get(self: *Self, time: f64) !Path {
            var result = try evaluate(self.allocator, self.context, time);
            errdefer result.deinit();
            self.evaluations += 1;
            try animation.validatePath(result.segments.items);
            return result;
        }
        fn append(self: *Self, time: f64, segments: []const Path.Segment) !void {
            if (self.keys.items.len >= self.options.maximum_keys) return error.SamplingLimitExceeded;
            const copy = try self.allocator.dupe(Path.Segment, segments);
            errdefer self.allocator.free(copy);
            try self.keys.append(self.allocator, .{ .time = time, .value = copy });
        }
        fn refine(self: *Self, start: f64, left: []const Path.Segment, end: f64, right: []const Path.Segment, depth: u8) anyerror!void {
            if (!animation.sameTopology(left, right)) return error.IncompatiblePaths;
            const quarter = start * 0.75 + end * 0.25;
            const middle = start * 0.5 + end * 0.5;
            const third = start * 0.25 + end * 0.75;
            var q = try self.get(quarter);
            defer q.deinit();
            var m = try self.get(middle);
            defer m.deinit();
            var r = try self.get(third);
            defer r.deinit();
            const error_value = @max(try deviation(left, right, q.segments.items, 0.25), @max(try deviation(left, right, m.segments.items, 0.5), try deviation(left, right, r.segments.items, 0.75)));
            if (depth >= self.options.minimum_depth and error_value <= self.options.tolerance) {
                self.max_error = @max(self.max_error, error_value);
                try self.append(end, right);
            } else {
                if (depth == self.options.maximum_depth) return error.SamplingToleranceExceeded;
                try self.refine(start, left, middle, m.segments.items, depth + 1);
                try self.refine(middle, m.segments.items, end, right, depth + 1);
            }
        }
    };
    var sampler: Sampler = .{ .allocator = allocator, .context = context, .options = options };
    errdefer {
        for (sampler.keys.items) |key| allocator.free(key.value);
        sampler.keys.deinit(allocator);
    }
    var first = try sampler.get(0);
    defer first.deinit();
    var last = try sampler.get(1);
    defer last.deinit();
    try sampler.append(0, first.segments.items);
    try sampler.refine(0, first.segments.items, 1, last.segments.items, 0);
    return .{ .allocator = allocator, .keys = try sampler.keys.toOwnedSlice(allocator), .evaluations = sampler.evaluations, .max_accepted_error = sampler.max_error };
}

fn pointError(a: g.Point, b: g.Point, actual: g.Point, fraction: f64) !f64 {
    const expected = a.lerp(b, fraction);
    const result = expected.distance(actual);
    if (!expected.isFinite() or !std.math.isFinite(result)) return error.NonFinite;
    return result;
}
fn deviation(left: []const Path.Segment, right: []const Path.Segment, actual: []const Path.Segment, fraction: f64) !f64 {
    // refine checks the interval endpoints once, before evaluating its samples.
    if (!animation.sameTopology(left, actual)) return error.IncompatiblePaths;
    var result: f64 = 0;
    for (left, right, actual) |a, b, value| {
        const current = switch (a) {
            .move => |point| try pointError(point, b.move, value.move, fraction),
            .line => |point| try pointError(point, b.line, value.line, fraction),
            .cubic => |curve| @max(try pointError(curve.c1, b.cubic.c1, value.cubic.c1, fraction), @max(try pointError(curve.c2, b.cubic.c2, value.cubic.c2, fraction), try pointError(curve.end, b.cubic.end, value.cubic.end, fraction))),
            .close => 0,
        };
        result = @max(result, current);
    }
    return result;
}

fn testCurve(allocator: std.mem.Allocator, nonlinear: bool, time: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.zero);
    const y = if (nonlinear) @sin(2 * std.math.pi * time) * 20 else time * 20;
    try result.lineTo(.{ .x = time * 10, .y = y });
    return result;
}
test "adaptive path keys reproduce linear motion with endpoints only" {
    var result = try samplePaths(std.testing.allocator, false, testCurve, .{ .minimum_depth = 0 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.keys.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.max_accepted_error, 1e-12);
}
test "nonlinear paths refine by checked geometric error instead of frame rate" {
    var result = try samplePaths(std.testing.allocator, true, testCurve, .{ .tolerance = 0.02 });
    defer result.deinit();
    try std.testing.expect(result.keys.len > 4 and result.keys.len < 256);
    try std.testing.expect(result.max_accepted_error <= 0.02);
    for (result.keys[0 .. result.keys.len - 1], result.keys[1..]) |left, right| {
        for ([_]f64{ 0.125, 0.375, 0.625, 0.875 }) |fraction| {
            const time = left.time * (1 - fraction) + right.time * fraction;
            var actual = try testCurve(std.testing.allocator, true, time);
            defer actual.deinit();
            try std.testing.expect(try deviation(left.value, right.value, actual.segments.items, fraction) <= 0.021);
        }
    }
}
test "sampling limits and invalid options fail instead of silently losing accuracy" {
    try std.testing.expectError(error.SamplingToleranceExceeded, samplePaths(std.testing.allocator, true, testCurve, .{ .minimum_depth = 0, .maximum_depth = 0 }));
    try std.testing.expectError(error.SamplingLimitExceeded, samplePaths(std.testing.allocator, true, testCurve, .{ .maximum_keys = 2 }));
    try std.testing.expectError(error.InvalidSamplingOptions, samplePaths(std.testing.allocator, true, testCurve, .{ .tolerance = 0 }));
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var result = try samplePaths(allocator, true, testCurve, .{ .tolerance = 2, .minimum_depth = 0 });
    defer result.deinit();
}
test "adaptive path ownership cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
