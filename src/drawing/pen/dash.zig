//! Dash placement in the original path's physical arc metric. The output is
//! one owned compound path; arc lookup uses shared metrics while each retained
//! cubic is an exact de Casteljau restriction of its source curve.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const flattening = @import("../path/flatten.zig");
const Measure = @import("../path/Measure.zig");
const Options = @import("outline.zig").Options;
const Builder = @import("dash/Builder.zig");
pub const Error = flattening.Error || error{ InvalidDash, PrecisionRange };

/// One entry per emitted segment, including moves and the closing marker.
/// Drawable times refer to the original path, never to the dashed result.
pub const SourceSpan = struct { contour: usize, begin: f64, end: f64 };
pub const Mapped = struct {
    path: Path,
    spans: []SourceSpan,

    pub fn deinit(self: *Mapped) void {
        self.path.allocator.free(self.spans);
        self.path.deinit();
        self.* = undefined;
    }
};

fn appendDraw(path: *Path, segment: Path.Segment) Error!void {
    switch (segment) {
        .move => |point| try path.moveTo(point),
        .line => |point| try path.lineTo(point),
        .cubic => |curve| try path.cubicTo(curve.c1, curve.c2, curve.end),
        .close => unreachable,
    }
}

const Provenance = struct { output: *std.ArrayList(SourceSpan), input: *std.ArrayList(SourceSpan) };

fn copyDraw(output: *Path, segment: Path.Segment, provenance: ?Provenance, index: usize) Error!void {
    try appendDraw(output, segment);
    if (provenance) |mapping| try mapping.output.append(output.allocator, mapping.input.items[index]);
}

fn appendSubpath(output: *Path, subpath: *Path, closed: bool, origin: g.Point, provenance: ?Provenance) !void {
    if (subpath.segments.items.len == 0) return;
    const segments = subpath.segments.items;
    var last_begin: usize = 0;
    var first_end = segments.len;
    for (segments[1..], 1..) |segment, index| if (segment == .move) {
        if (first_end == segments.len) first_end = index;
        last_begin = index;
    };
    const leading = segments[0].move.eql(origin);
    const trailing = subpath.current.?.eql(origin);
    if (closed and leading and trailing) {
        if (last_begin == 0) {
            try subpath.close();
            if (provenance) |mapping| {
                const last = mapping.input.items[mapping.input.items.len - 1];
                try mapping.input.append(output.allocator, .{ .contour = last.contour, .begin = last.end, .end = last.end });
            }
            try output.append(subpath.*);
            if (provenance) |mapping| try mapping.output.appendSlice(output.allocator, mapping.input.items);
        } else {
            // Join the final on-interval through the close seam to the first
            // interval. This avoids introducing two artificial end caps.
            try copyDraw(output, segments[last_begin], provenance, last_begin);
            for (segments[last_begin + 1 ..], last_begin + 1..) |segment, index| try copyDraw(output, segment, provenance, index);
            for (segments[1..first_end], 1..) |segment, index| try copyDraw(output, segment, provenance, index);
            for (segments[first_end..last_begin], first_end..) |segment, index| try copyDraw(output, segment, provenance, index);
        }
    } else {
        try output.append(subpath.*);
        if (provenance) |mapping| try mapping.output.appendSlice(output.allocator, mapping.input.items);
    }
}

/// Pattern elements are nonnegative physical lengths with positive total.
/// Odd patterns repeat with reversed parity. Phase is consumed from the
/// pattern and resets for each moveto, matching native SVG/PDF dash offsets.
/// Zero on-lengths are retained as move+zero line for round-capped dots.
pub fn dashed(allocator: std.mem.Allocator, path: Path, pattern: []const f64, phase: f64, options: Options) Error!Path {
    return build(allocator, path, pattern, phase, options, null);
}

/// The same dash traversal, with source time carried alongside its output.
pub fn mapped(allocator: std.mem.Allocator, path: Path, pattern: []const f64, phase: f64, options: Options) Error!Mapped {
    var spans: std.ArrayList(SourceSpan) = .empty;
    defer spans.deinit(allocator);
    var result = try build(allocator, path, pattern, phase, options, &spans);
    errdefer result.deinit();
    return .{ .path = result, .spans = try spans.toOwnedSlice(allocator) };
}

test "mapped dashes preserve the shared traversal and original contour times" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.cubicTo(.zero, .zero, .{ .x = 100, .y = 0 });
    try source.moveTo(.{ .x = 200, .y = 0 });
    try source.lineTo(.{ .x = 210, .y = 0 });
    var plain = try dashed(t.allocator, source, &.{ 50, 50 }, 0, .{ .tolerance = 1e-4 });
    defer plain.deinit();
    var traced = try mapped(t.allocator, source, &.{ 50, 50 }, 0, .{ .tolerance = 1e-4 });
    defer traced.deinit();
    try t.expectEqualSlices(Path.Segment, plain.segments.items, traced.path.segments.items);
    try t.expectEqual(plain.segments.items.len, traced.spans.len);
    try t.expectEqual(@as(usize, 0), traced.spans[1].contour);
    try t.expectApproxEqAbs(std.math.pow(f64, 0.5, 1.0 / 3.0), traced.spans[1].end, 1e-4);
    try t.expectEqual(@as(usize, 1), traced.spans[3].contour);
    try t.expectEqual(@as(f64, 1), traced.spans[3].begin);
    try t.expectEqual(@as(f64, 2), traced.spans[3].end);
}

fn build(allocator: std.mem.Allocator, path: Path, pattern: []const f64, phase: f64, options: Options, output_mapping: ?*std.ArrayList(SourceSpan)) Error!Path {
    if (!std.math.isFinite(phase)) return error.InvalidDash;
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidTolerance;
    if (options.max_segments == 0 or options.max_vertices < 3 or options.max_depth > 64) return error.StrokeWorkLimit;
    if (pattern.len == 0) {
        if (output_mapping) |mapping| {
            var time: f64 = 0;
            var contour: usize = 0;
            var current: ?g.Point = null;
            var start: ?g.Point = null;
            for (path.segments.items) |segment| {
                const begin = time;
                switch (segment) {
                    .move => |point| {
                        if (mapping.items.len != 0) contour += 1;
                        current = point;
                        start = point;
                    },
                    .line, .cubic => {
                        if (current == null) return error.InvalidPath;
                        current = if (segment == .line) segment.line else segment.cubic.end;
                        time += 1;
                    },
                    .close => {
                        if (current == null or start == null) return error.InvalidPath;
                        if (!current.?.eql(start.?)) time += 1;
                        current = null;
                        start = null;
                    },
                }
                try mapping.append(allocator, .{ .contour = contour, .begin = begin, .end = time });
            }
        }
        return path.clone(allocator);
    }
    if (pattern.len > options.max_segments or pattern.len > std.math.maxInt(usize) / 2) return error.StrokeWorkLimit;
    var period: f64 = 0;
    for (pattern) |length| {
        if (!std.math.isFinite(length) or length < 0) return error.InvalidDash;
        period += length;
    }
    if (pattern.len % 2 != 0) period *= 2;
    if (!std.math.isFinite(period) or period <= 0) return error.InvalidDash;
    var measured = Measure.init(allocator, path, .{
        .tolerance = options.tolerance * 0.25,
        .max_segments = options.max_segments,
        .max_depth = options.max_depth,
    }) catch |err| switch (err) {
        error.GeometryWorkLimit => return error.StrokeWorkLimit,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTolerance => return error.InvalidTolerance,
        error.NonFinite => return error.NonFinite,
        error.PrecisionRange => return error.PrecisionRange,
        else => return error.InvalidPath,
    };
    defer measured.deinit();
    var result = Path.init(allocator);
    errdefer result.deinit();
    var subpath_mapping: std.ArrayList(SourceSpan) = .empty;
    defer subpath_mapping.deinit(allocator);
    const provenance: ?Provenance = if (output_mapping) |mapping| .{ .output = mapping, .input = &subpath_mapping } else null;
    var builder: Builder = .{ .result = Path.init(allocator), .state = Builder.State.init(pattern, phase, period), .options = options, .mapping = if (output_mapping != null) &subpath_mapping else null };
    defer builder.result.deinit();
    var current: ?g.Point = null;
    var start: ?g.Point = null;
    var edge: usize = 0;
    var time: f64 = 0;
    var contour: usize = 0;
    var distance: f64 = 0;
    for (path.segments.items) |segment| switch (segment) {
        .move => |point| {
            if (current != null) try appendSubpath(&result, &builder.result, false, start.?, provenance);
            builder.result.segments.clearRetainingCapacity();
            subpath_mapping.clearRetainingCapacity();
            builder.result.current = null;
            builder.result.start = null;
            builder.result.open = false;
            builder.state = Builder.State.init(pattern, phase, period);
            builder.open = false;
            builder.contour = contour;
            contour += 1;
            current = point;
            start = point;
        },
        .line, .cubic, .close => {
            const previous = current orelse return error.InvalidPath;
            const point = switch (segment) {
                .line => segment.line,
                .cubic => segment.cubic.end,
                .close => start.?,
                else => unreachable,
            };
            const begin = distance;
            const source_time = time;
            if (segment != .close or !previous.eql(point)) {
                time += 1;
                // Measure's table already maps physical distance to source
                // segment time. Use its exact segment endpoints to delimit
                // this curve, without a second arc-length implementation.
                while (edge < measured.edges.len and measured.edges[edge].end_time <= time) : (edge += 1) distance = measured.edges[edge].end;
            }
            if (segment == .cubic) {
                const curve = segment.cubic;
                try builder.cubic(.{ .p0 = previous, .p1 = curve.c1, .p2 = curve.c2, .p3 = curve.end }, measured, begin, distance, source_time);
            } else try builder.line(previous, point, source_time, time);
            current = point;
            if (segment == .close) {
                try appendSubpath(&result, &builder.result, true, start.?, provenance);
                builder.result.segments.clearRetainingCapacity();
                subpath_mapping.clearRetainingCapacity();
                builder.result.current = null;
                builder.result.start = null;
                builder.result.open = false;
                current = null;
                start = null;
            }
        },
    };
    if (current != null) try appendSubpath(&result, &builder.result, false, start.?, provenance);
    return result;
}

test "closed all-on dashes retain closure and on intervals join across seam" {
    var square = Path.init(std.testing.allocator);
    defer square.deinit();
    try square.moveTo(.zero);
    try square.lineTo(.{ .x = 10, .y = 0 });
    try square.lineTo(.{ .x = 10, .y = 10 });
    try square.lineTo(.{ .x = 0, .y = 10 });
    try square.close();
    var whole = try dashed(std.testing.allocator, square, &.{ 50, 10 }, 0, .{});
    defer whole.deinit();
    try std.testing.expect(whole.segments.items[whole.segments.items.len - 1] == .close);
    var seamed = try dashed(std.testing.allocator, square, &.{ 15, 10 }, 0, .{});
    defer seamed.deinit();
    var contours: usize = 0;
    for (seamed.segments.items) |segment| if (segment == .move) {
        contours += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), contours);
}

test "curved dash subpaths reset and closed seam stitching preserves cubics" {
    var curves = Path.init(std.testing.allocator);
    defer curves.deinit();
    try curves.moveTo(.zero);
    try curves.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    try curves.moveTo(.{ .x = 500, .y = 0 });
    try curves.cubicTo(.{ .x = 500, .y = 100 }, .{ .x = 600, .y = 100 }, .{ .x = 600, .y = 0 });
    var reset = try dashed(std.testing.allocator, curves, &.{ 100, 300 }, 0, .{});
    defer reset.deinit();
    try std.testing.expectEqual(@as(usize, 4), reset.segments.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 500), reset.segments.items[3].cubic.end.x - reset.segments.items[1].cubic.end.x, 1e-9);
    var circle = try Path.circle(std.testing.allocator, .zero, 10);
    defer circle.deinit();
    var whole = try dashed(std.testing.allocator, circle, &.{ 100, 10 }, 0, .{});
    defer whole.deinit();
    try std.testing.expectEqualSlices(Path.Segment, circle.segments.items, whole.segments.items);
    var seamed = try dashed(std.testing.allocator, circle, &.{ 20, 10 }, 0, .{});
    defer seamed.deinit();
    var contours: usize = 0;
    var cubics: usize = 0;
    for (seamed.segments.items) |segment| switch (segment) {
        .move => contours += 1,
        .cubic => cubics += 1,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), contours);
    try std.testing.expect(cubics >= 4);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var line = Path.init(allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.cubicTo(.{ .x = 0, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 0 });
    try line.lineTo(.{ .x = 3, .y = 3 });
    try line.close();
    var result = try dashed(allocator, line, &.{ 2, 1 }, -1, .{});
    defer result.deinit();
    try std.testing.expect(result.segments.items.len != 0);
}
test "dash allocation failures release subdivision and closed-seam buffers" {
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationExercise, .{});
}

test {
    _ = @import("dash/placement_test.zig");
}
