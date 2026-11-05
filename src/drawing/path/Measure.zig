//! Owned arc-length measurements of native paths. Shared adaptive flattening
//! bounds both spatial error and total chord-length deficit by tolerance.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("Path.zig");
const flattening = @import("flatten.zig");

pub const Options = struct {
    tolerance: f64 = 1e-3,
    max_segments: usize = 65536,
    max_depth: usize = 24,
};
pub const Sample = struct {
    /// Physical length along all subpaths; pen-up moves consume no length.
    distance: f64,
    /// distance / total length, or zero for a zero-length path.
    u: f64,
    /// Source drawable-segment parameter, compatible with Path.pointAt.
    time: f64,
    point: g.Point,
    /// Unit direction; zero only for a wholly stationary subpath.
    tangent: g.Point,
    contour: usize,
};
const Edge = struct {
    begin: f64,
    end: f64,
    start_time: f64,
    end_time: f64,
    from: g.Point,
    to: g.Point,
};
const Contour = struct {
    first: usize,
    count: usize,
    begin: f64,
    end: f64,
    point: g.Point,
    time: f64,
};

const Measure = @This();

allocator: std.mem.Allocator,
length: f64,
options: Options,
curves: []g.Cubic,
edges: []Edge,
contours: []Contour,

/// Source storage may be freed or changed after this returns. No fonts,
/// typesetting, renderer or native geometry library is required.
pub fn init(allocator: std.mem.Allocator, path: Path, options: Options) !Measure {
    if (path.segments.items.len > options.max_segments *| 2 +| 1) return error.GeometryWorkLimit;
    var flat = flattening.detailed(allocator, path, .{
        .tolerance = options.tolerance,
        .length_tolerance = options.tolerance,
        .parameter_tolerance = options.tolerance,
        .max_segments = options.max_segments,
        .max_depth = options.max_depth,
    }) catch |err| switch (err) {
        error.StrokeWorkLimit => return error.GeometryWorkLimit,
        else => return err,
    };
    defer flat.deinit();
    var curves: std.ArrayList(g.Cubic) = .empty;
    defer curves.deinit(allocator);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    var contours: std.ArrayList(Contour) = .empty;
    defer contours.deinit(allocator);
    var current: ?g.Point = null;
    var start: ?g.Point = null;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            current = point;
            start = point;
        },
        .line => |point| {
            try curves.append(allocator, g.Cubic.line(current orelse return error.InvalidPath, point));
            current = point;
        },
        .cubic => |curve| {
            try curves.append(allocator, .{ .p0 = current orelse return error.InvalidPath, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end });
            current = curve.end;
        },
        .close => {
            const from = current orelse return error.InvalidPath;
            if (from.x != start.?.x or from.y != start.?.y) try curves.append(allocator, g.Cubic.line(from, start.?));
            current = null;
            start = null;
        },
    };
    var length: f64 = 0;
    var previous_time: f64 = 0;
    var active: ?usize = null;
    for (flat.path.segments.items, flat.marks) |segment, mark| switch (segment) {
        .move => |point| {
            try contours.append(allocator, .{ .first = edges.items.len, .count = 0, .begin = length, .end = length, .point = point, .time = mark.time });
            active = contours.items.len - 1;
            current = point;
            start = point;
            previous_time = mark.time;
        },
        .line, .close => {
            const index = active orelse return error.InvalidPath;
            const from = current orelse return error.InvalidPath;
            const to = if (segment == .line) segment.line else start.?;
            const distance = from.distance(to);
            const next = length + distance;
            if (!std.math.isFinite(distance) or !std.math.isFinite(next)) return error.NonFinite;
            if (distance > 0 and next == length) return error.PrecisionRange;
            if (mark.time != previous_time) {
                try edges.append(allocator, .{ .begin = length, .end = next, .start_time = previous_time, .end_time = mark.time, .from = from, .to = to });
                contours.items[index].count += 1;
            }
            length = next;
            contours.items[index].end = length;
            current = to;
            previous_time = mark.time;
            if (segment == .close) {
                active = null;
                current = null;
                start = null;
            }
        },
        .cubic => unreachable,
    };
    const owned_curves = try curves.toOwnedSlice(allocator);
    errdefer allocator.free(owned_curves);
    const owned_edges = try edges.toOwnedSlice(allocator);
    errdefer allocator.free(owned_edges);
    return .{ .allocator = allocator, .length = length, .options = options, .curves = owned_curves, .edges = owned_edges, .contours = try contours.toOwnedSlice(allocator) };
}

pub fn deinit(self: *Measure) void {
    self.allocator.free(self.curves);
    self.allocator.free(self.edges);
    self.allocator.free(self.contours);
    self.* = undefined;
}

/// A distance exactly at a pen-up boundary selects the following subpath.
/// The final endpoint selects the last subpath. A move-only subpath has
/// zero length and a zero tangent, while an empty path returns EmptyPath.
pub fn sample(self: Measure, distance: f64) !Sample {
    if (!std.math.isFinite(distance) or distance < 0 or distance > self.length) return error.InvalidParameter;
    if (self.contours.len == 0) return error.EmptyPath;
    var low: usize = 0;
    var high = self.contours.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (self.contours[middle].end <= distance) low = middle + 1 else high = middle;
    }
    return self.sampleContour(@min(low, self.contours.len - 1), distance);
}

pub fn sampleNormalized(self: Measure, u: f64) !Sample {
    if (!std.math.isFinite(u) or u < 0 or u > 1) return error.InvalidParameter;
    return self.sample(u * self.length);
}

/// Return count equal-distance samples for EACH subpath, including both
/// endpoints. This preserves pen-up boundaries even when they do not fall
/// on a global distance grid. The caller owns the returned slice.
pub fn samples(self: Measure, allocator: std.mem.Allocator, count: usize) ![]Sample {
    if (count < 2) return error.InvalidParameter;
    if (self.contours.len == 0) return error.EmptyPath;
    const total = std.math.mul(usize, count, self.contours.len) catch return error.GeometryWorkLimit;
    if (total > self.options.max_segments) return error.GeometryWorkLimit;
    const result = try allocator.alloc(Sample, total);
    errdefer allocator.free(result);
    for (self.contours, 0..) |contour, index| {
        for (0..count) |i| {
            const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1));
            const distance = if (i == count - 1) contour.end else contour.begin + (contour.end - contour.begin) * u;
            result[index * count + i] = try self.sampleContour(index, distance);
        }
    }
    return result;
}

fn sampleContour(self: Measure, index: usize, distance: f64) !Sample {
    const contour = self.contours[index];
    var result: Sample = .{ .distance = distance, .u = if (self.length == 0) 0 else distance / self.length, .time = contour.time, .point = contour.point, .tangent = .zero, .contour = index };
    if (contour.count == 0) return result;
    const candidates = self.edges[contour.first..][0..contour.count];
    var low: usize = 0;
    var high = candidates.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (candidates[middle].end <= distance) low = middle + 1 else high = middle;
    }
    const edge = candidates[@min(low, candidates.len - 1)];
    const fraction = if (edge.end == edge.begin) 1 else std.math.clamp((distance - edge.begin) / (edge.end - edge.begin), 0, 1);
    result.time = edge.start_time * (1 - fraction) + edge.end_time * fraction;
    const curve_index: usize = @intFromFloat(@floor(edge.start_time * 0.5 + edge.end_time * 0.5));
    const curve = self.curves[curve_index];
    const t = std.math.clamp(result.time - @as(f64, @floatFromInt(curve_index)), 0, 1);
    result.point = curve.at(t);
    if (!result.point.isFinite()) return error.NonFinite;
    result.tangent = curve.derivative(t).normalized() catch |err| switch (err) {
        error.NonFinite => return err,
        error.ZeroVector => edge.to.sub(edge.from).normalized() catch .zero,
    };
    if (result.tangent.x == 0 and result.tangent.y == 0) {
        for (candidates) |candidate| {
            result.tangent = candidate.to.sub(candidate.from).normalized() catch continue;
            break;
        }
    }
    return result;
}

test "arc metrics follow physical length and preserve source curve parameters" {
    const t = std.testing;
    var path = Path.init(t.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.zero, .zero, .{ .x = 100, .y = 0 });
    var measured = try Measure.init(t.allocator, path, .{ .tolerance = 1e-5 });
    defer measured.deinit();
    try t.expectApproxEqAbs(@as(f64, 100), measured.length, 1e-5);
    const middle = try measured.sample(50);
    try t.expectApproxEqAbs(@as(f64, 50), middle.point.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 0.5), middle.u, 1e-12);
    try t.expect(middle.time > 0.79 and middle.time < 0.80);
    try t.expectApproxEqAbs(@as(f64, 1), middle.tangent.x, 1e-12);
    try t.expect(g.tolerance.points(middle.point, try path.pointAt(middle.time)));
}

test "arc sampling includes every contour endpoint without counting pen-up motion" {
    const t = std.testing;
    var path = Path.init(t.allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 0 });
    try path.moveTo(.{ .x = 100, .y = 20 });
    try path.lineTo(.{ .x = 100, .y = 50 });
    var measured = try Measure.init(t.allocator, path, .{});
    defer measured.deinit();
    try t.expectEqual(@as(f64, 40), measured.length);
    const points = try measured.samples(t.allocator, 3);
    defer t.allocator.free(points);
    try t.expectEqual(@as(usize, 6), points.len);
    try t.expectEqual(@as(usize, 0), points[2].contour);
    try t.expectEqual(@as(usize, 1), points[3].contour);
    try t.expectEqual(@as(f64, 10), points[2].distance);
    try t.expectEqual(@as(f64, 10), points[3].distance);
    try t.expectEqual(@as(f64, 1), points[5].u);
    try t.expectEqual(@as(usize, 1), (try measured.sample(10)).contour);
}

test "arc metrics own data handle stationary contours and enforce work limits" {
    const t = std.testing;
    var path = Path.init(t.allocator);
    try path.moveTo(.{ .x = 3, .y = 4 });
    try path.lineTo(.{ .x = 3, .y = 4 });
    var measured = try Measure.init(t.allocator, path, .{ .max_segments = 10 });
    defer measured.deinit();
    path.deinit();
    const sample_result = try measured.sample(0);
    try t.expectEqual(@as(f64, 3), sample_result.point.x);
    try t.expectEqual(g.Point.zero, sample_result.tangent);
    try t.expectError(error.InvalidParameter, measured.sample(-1));
    try t.expectError(error.InvalidParameter, measured.sampleNormalized(2));
    try t.expectError(error.InvalidParameter, measured.samples(t.allocator, 1));
    try t.expectError(error.GeometryWorkLimit, measured.samples(t.allocator, 11));
    var empty = Path.init(t.allocator);
    defer empty.deinit();
    var empty_measure = try Measure.init(t.allocator, empty, .{});
    defer empty_measure.deinit();
    try t.expectEqual(@as(f64, 0), empty_measure.length);
    try t.expectError(error.EmptyPath, empty_measure.sample(0));
    try t.expectError(error.InvalidTolerance, Measure.init(t.allocator, empty, .{ .tolerance = 0 }));
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var path = Path.init(allocator);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.cubicTo(.{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 });
    try path.close();
    var measured = try Measure.init(allocator, path, .{ .tolerance = 0.05 });
    defer measured.deinit();
    const sample_results = try measured.samples(allocator, 4);
    defer allocator.free(sample_results);
}
test "arc metric allocations release every partial result" {
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}
