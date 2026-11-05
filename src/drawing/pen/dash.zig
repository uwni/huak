//! Dash placement in the original path's physical arc metric. The output is
//! one owned compound path; arc lookup uses shared metrics while each retained
//! cubic is an exact de Casteljau restriction of its source curve.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const flattening = @import("../path/flatten.zig");
const Measure = @import("../path/Measure.zig");
const Options = @import("outline.zig").Options;
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

const State = struct {
    pattern: []const f64,
    index: usize = 0,
    remaining: f64 = 0,
    fn on(self: State) bool {
        return self.index % 2 == 0;
    }
    fn next(self: *State) void {
        self.index = (self.index + 1) % (if (self.pattern.len % 2 == 0) self.pattern.len else self.pattern.len * 2);
        self.remaining = self.pattern[self.index % self.pattern.len];
    }
    fn init(pattern: []const f64, phase: f64, period: f64) State {
        var state: State = .{ .pattern = pattern, .remaining = pattern[0] };
        var offset = @mod(phase, period);
        while (offset > 0) {
            if (offset < state.remaining) {
                state.remaining -= offset;
                break;
            }
            offset -= state.remaining;
            state.next();
        }
        return state;
    }
};

const Builder = struct {
    result: Path,
    state: State,
    options: Options,
    open: bool = false,
    visits: usize = 0,
    mapping: ?*std.ArrayList(SourceSpan) = null,
    contour: usize = 0,

    fn record(self: *Builder, begin: f64, end: f64) Error!void {
        if (self.mapping) |mapping| try mapping.append(self.result.allocator, .{ .contour = self.contour, .begin = begin, .end = end });
    }
    fn move(self: *Builder, point: g.Point, time: f64) Error!void {
        try self.result.moveTo(point);
        try self.record(time, time);
    }
    fn emitLine(self: *Builder, point: g.Point, begin: f64, end: f64) Error!void {
        try self.result.lineTo(point);
        try self.record(begin, end);
    }
    fn emitCubic(self: *Builder, curve: g.Cubic, begin: f64, end: f64) Error!void {
        try self.result.cubicTo(curve.p1, curve.p2, curve.p3);
        try self.record(begin, end);
    }

    fn visit(self: *Builder) Error!void {
        self.visits += 1;
        if (self.visits > self.options.max_segments) return error.StrokeWorkLimit;
    }
    fn zeros(self: *Builder, point: g.Point, time: f64) Error!void {
        while (self.state.remaining == 0) {
            try self.visit();
            if (self.state.on()) {
                try self.move(point, time);
                try self.emitLine(point, time, time);
                self.open = false;
            }
            self.state.next();
        }
        if (!self.state.on()) self.open = false;
    }
    fn line(self: *Builder, start: g.Point, end: g.Point, begin_time: f64, end_time: f64) Error!void {
        const delta = end.sub(start);
        const length = delta.norm();
        if (!delta.isFinite() or !std.math.isFinite(length)) return error.NonFinite;
        try self.zeros(start, begin_time);
        if (length == 0) {
            if (self.state.on() and !self.open) {
                try self.visit();
                try self.move(start, begin_time);
                try self.emitLine(start, begin_time, end_time);
                self.open = true;
            }
            return;
        }
        var consumed: f64 = 0;
        var point = start;
        while (consumed < length) {
            try self.visit();
            const amount = @min(self.state.remaining, length - consumed);
            const next = consumed + amount;
            if (next == consumed) return error.PrecisionRange;
            const finish = if (next >= length) end else start.add(delta.scale(next / length));
            if (same(point, finish)) return error.PrecisionRange;
            if (self.state.on()) {
                const from = begin_time + (end_time - begin_time) * (consumed / length);
                const to = if (next >= length) end_time else begin_time + (end_time - begin_time) * (next / length);
                if (!self.open) try self.move(point, from);
                try self.emitLine(finish, from, to);
                self.open = true;
            } else self.open = false;
            consumed = next;
            point = finish;
            self.state.remaining -= amount;
            if (self.state.remaining <= 0) {
                self.state.next();
                try self.zeros(point, if (next >= length) end_time else begin_time + (end_time - begin_time) * (next / length));
            }
        }
    }
    fn cubic(self: *Builder, curve: g.Cubic, measured: Measure, begin: f64, end: f64, time: f64) Error!void {
        const length = end - begin;
        try self.zeros(curve.p0, time);
        if (length == 0) {
            if (self.state.on()) {
                try self.visit();
                if (!self.open) try self.move(curve.p0, time);
                try self.emitCubic(curve, time, time + 1);
                self.open = true;
            }
            return;
        }
        var consumed: f64 = 0;
        var parameter: f64 = 0;
        var point = curve.p0;
        while (consumed < length) {
            try self.visit();
            const amount = @min(self.state.remaining, length - consumed);
            const next = consumed + amount;
            if (next == consumed) return error.PrecisionRange;
            const finish = if (next >= length) 1 else std.math.clamp((measured.sample(begin + next) catch |err| switch (err) {
                error.InvalidParameter => return error.PrecisionRange,
                error.ZeroVector => return error.PrecisionRange,
                error.EmptyPath => return error.InvalidPath,
                error.NonFinite => return error.NonFinite,
            }).time - time, 0, 1);
            if (finish <= parameter) return error.PrecisionRange;
            const cut = curve.trimmed(parameter, finish) catch return error.PrecisionRange;
            if (!cut.isFinite()) return error.NonFinite;
            if (same(cut.p0, cut.p1) and same(cut.p0, cut.p2) and same(cut.p0, cut.p3)) return error.PrecisionRange;
            if (self.state.on()) {
                if (!self.open) try self.move(cut.p0, time + parameter);
                try self.emitCubic(cut, time + parameter, time + finish);
                self.open = true;
            } else self.open = false;
            consumed = next;
            parameter = finish;
            point = cut.p3;
            self.state.remaining -= amount;
            if (self.state.remaining <= 0) {
                self.state.next();
                try self.zeros(point, time + finish);
            }
        }
    }
};

fn same(a: g.Point, b: g.Point) bool {
    return a.x == b.x and a.y == b.y;
}

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
    const leading = same(segments[0].move, origin);
    const trailing = same(subpath.current.?, origin);
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
                        if (!same(current.?, start.?)) time += 1;
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
    var builder: Builder = .{ .result = Path.init(allocator), .state = State.init(pattern, phase, period), .options = options, .mapping = if (output_mapping != null) &subpath_mapping else null };
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
            builder.state = State.init(pattern, phase, period);
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
            if (segment != .close or !same(previous, point)) {
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

test "physical dash placement handles phases odd patterns and subpath resets" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 12, .y = 0 });
    try line.moveTo(.{ .x = 100, .y = 0 });
    try line.lineTo(.{ .x = 112, .y = 0 });
    var result = try dashed(std.testing.allocator, line, &.{ 3, 2 }, 1, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(f64, 2), result.segments.items[1].line.x);
    try std.testing.expectEqual(@as(f64, 4), result.segments.items[2].move.x);
    try std.testing.expectEqual(@as(f64, 100), result.segments.items[6].move.x);
    var odd = try dashed(std.testing.allocator, line, &.{3}, 0, .{});
    defer odd.deinit();
    try std.testing.expectEqual(@as(f64, 6), odd.segments.items[2].move.x);
}

test "zero on lengths preserve physical dots without infinite loops" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.zero);
    try line.lineTo(.{ .x = 10, .y = 0 });
    var dots = try dashed(std.testing.allocator, line, &.{ 0, 5 }, 0, .{});
    defer dots.deinit();
    try std.testing.expectEqual(@as(usize, 6), dots.segments.items.len);
    try std.testing.expectEqual(@as(f64, 5), dots.segments.items[2].move.x);
    try std.testing.expectEqual(@as(f64, 10), dots.segments.items[5].line.x);
    try std.testing.expectError(error.InvalidDash, dashed(std.testing.allocator, line, &.{ 0, 0 }, 0, .{}));
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

test "cubic dash distances follow arc length rather than Bezier time" {
    var cubic = Path.init(std.testing.allocator);
    defer cubic.deinit();
    try cubic.moveTo(.zero);
    try cubic.cubicTo(.zero, .zero, .{ .x = 100, .y = 0 });
    var result = try dashed(std.testing.allocator, cubic, &.{ 50, 50 }, 0, .{});
    defer result.deinit();
    try std.testing.expect(result.segments.items[1] == .cubic);
    try std.testing.expectApproxEqAbs(@as(f64, 50), result.segments.items[1].cubic.end.x, 0.001);
}

test "physical dashes retain native curved controls and whole on cubics" {
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 100 }, .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 0 });
    var whole = try dashed(std.testing.allocator, curve, &.{ 300, 10 }, 0, .{});
    defer whole.deinit();
    try std.testing.expectEqualSlices(Path.Segment, curve.segments.items, whole.segments.items);
    // This symmetric cubic has total arc length 200. The half-length cut is
    // t=1/2, whose de Casteljau controls are independently known exactly.
    var half = try dashed(std.testing.allocator, curve, &.{ 100, 300 }, 0, .{ .tolerance = 1e-4 });
    defer half.deinit();
    try std.testing.expectEqual(@as(usize, 2), half.segments.items.len);
    try std.testing.expect(half.segments.items[1] == .cubic);
    const retained = half.segments.items[1].cubic;
    try std.testing.expectApproxEqAbs(@as(f64, 0), retained.c1.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 50), retained.c1.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 25), retained.c2.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 75), retained.c2.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 50), retained.end.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 75), retained.end.y, 1e-4);
    try std.testing.expectError(error.StrokeWorkLimit, dashed(std.testing.allocator, curve, &.{ 10, 5 }, 0, .{ .max_depth = 0 }));
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

test "unrepresentable physical dash steps and invalid empty-pattern budgets fail" {
    var line = Path.init(std.testing.allocator);
    defer line.deinit();
    try line.moveTo(.{ .x = 1e20, .y = 0 });
    try line.lineTo(.{ .x = 1e20 + 1e6, .y = 0 });
    try std.testing.expectError(error.PrecisionRange, dashed(std.testing.allocator, line, &.{ 1, 1 }, 0, .{}));
    var curve = Path.init(std.testing.allocator);
    defer curve.deinit();
    try curve.moveTo(.{ .x = 1e20, .y = 0 });
    try curve.cubicTo(.{ .x = 1e20 + 3e5, .y = 0 }, .{ .x = 1e20 + 6e5, .y = 0 }, .{ .x = 1e20 + 1e6, .y = 0 });
    // Permit the shared metric table's coordinate error at this magnitude;
    // the one-unit dash still cannot be represented by native curve points.
    try std.testing.expectError(error.PrecisionRange, dashed(std.testing.allocator, curve, &.{ 1, 1 }, 0, .{ .tolerance = 1e5 }));
    try std.testing.expectError(error.InvalidTolerance, dashed(std.testing.allocator, line, &.{}, 0, .{ .tolerance = 0 }));
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
