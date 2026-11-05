//! Stroke coverage indexed by the original path, including dash provenance.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const dash = @import("dash.zig");
const outline = @import("outline.zig");
const envelope = @import("envelope.zig");
const prep = @import("envelope/prepare.zig");
const region = @import("../region/root.zig");
const Allocator = std.mem.Allocator;

/// Closed source-time interval within one original contour. A wrapped closed
/// interval is expressed as two ranges at the contour seam. Nonstationary
/// contours require begin < end; zero-time contour stamps may use equality.
pub const Range = struct { contour: usize, begin: f64, end: f64 };
const Contour = struct { begin: f64, end: f64 };
const Piece = struct { geometry: prep.Piece, source: dash.SourceSpan };
const Pieces = std.MultiArrayList(Piece);
const Run = struct { first: usize, end: usize, closed: bool };

/// Return one independently owned nonzero-fill coverage per requested range.
/// Each path uses result_allocator; the outer slice uses scratch_allocator.
/// Deinitialize every path, then free that slice with scratch_allocator.
/// Inputs stay borrowed. Real dash/path endpoints retain their original cap;
/// artificial cuts are butt boundaries. Original joins belong to both adjacent
/// closed ranges. Union coverage before clipping the original stroke once.
pub fn extract(allocator: Allocator, result_allocator: Allocator, source: Path, paint: DisplayList.Pen, ranges: []const Range, options: outline.Options) ![]Path {
    try DisplayList.validateStyle(&.{ .pen = paint });
    if (ranges.len > options.max_segments or source.segments.items.len > options.max_segments *| 2 +| 1) return error.StrokeWorkLimit;
    {
        var contours: std.ArrayList(Contour) = .empty;
        defer contours.deinit(allocator);
        var time: f64 = 0;
        var current: ?g.Point = null;
        var start: ?g.Point = null;
        for (source.segments.items) |segment| {
            switch (segment) {
                .move => |point| {
                    if (!point.isFinite()) return error.NonFinite;
                    try contours.append(allocator, .{ .begin = time, .end = time });
                    current = point;
                    start = point;
                },
                .line, .cubic => {
                    if (current == null) return error.InvalidPath;
                    if (segment == .line) {
                        if (!segment.line.isFinite()) return error.NonFinite;
                        current = segment.line;
                    } else {
                        const controls = segment.cubic;
                        if (!controls.c1.isFinite() or !controls.c2.isFinite() or !controls.end.isFinite()) return error.NonFinite;
                        current = controls.end;
                    }
                    time += 1;
                    contours.items[contours.items.len - 1].end = time;
                },
                .close => {
                    if (current == null or start == null) return error.InvalidPath;
                    if (!same(current.?, start.?)) time += 1;
                    contours.items[contours.items.len - 1].end = time;
                    current = null;
                    start = null;
                },
            }
        }
        for (ranges) |range| {
            if (range.contour >= contours.items.len or !std.math.isFinite(range.begin) or !std.math.isFinite(range.end)) return error.InvalidSection;
            const contour = contours.items[range.contour];
            if (range.begin < contour.begin or range.end > contour.end or range.begin > range.end or (range.begin == range.end and contour.begin != contour.end)) return error.InvalidSection;
        }
    }
    var settings = options;
    settings.cap = paint.cap;
    settings.join = paint.join;
    settings.miter_limit = paint.miter_limit;
    try outline.validateOptions(settings);
    if (ranges.len == 0) return allocator.alloc(Path, 0);
    if (paint.color.a == 0) {
        const result = try allocator.alloc(Path, ranges.len);
        for (result) |*path| path.* = Path.init(result_allocator);
        return result;
    }
    var pieces: Pieces = .empty;
    defer pieces.deinit(allocator);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    const nib = paint.nib orelse @import("nib.zig").Nib{ .ellipse = g.Transform.scaling(paint.width, paint.width) };
    const vertices = prepared: {
        var dashed = try dash.mapped(allocator, source, paint.dash, paint.dash_phase, settings);
        defer dashed.deinit();
        const vertices = try outline.nibVertices(allocator, nib, dashed.path, settings);
        errdefer if (nib == .ellipse) allocator.free(vertices);
        var run_first: usize = 0;
        var move_span: dash.SourceSpan = undefined;
        var current: ?g.Point = null;
        var start: ?g.Point = null;
        for (dashed.path.segments.items, dashed.spans) |segment, span| switch (segment) {
            .move => |point| {
                if (current) |previous| try finishRun(allocator, &pieces, &runs, run_first, previous, move_span, false);
                run_first = pieces.len;
                current = point;
                start = point;
                move_span = span;
            },
            .line, .cubic, .close => {
                const point = switch (segment) {
                    .line => segment.line,
                    .cubic => segment.cubic.end,
                    .close => start.?,
                    else => unreachable,
                };
                if (segment != .close or !same(current.?, point)) {
                    const curve = if (segment == .cubic) g.Cubic{ .p0 = current.?, .p1 = segment.cubic.c1, .p2 = segment.cubic.c2, .p3 = point } else g.Cubic{ .p0 = current.?, .p1 = current.?, .p2 = point, .p3 = point };
                    if (pieces.len - run_first >= settings.max_segments) return error.StrokeWorkLimit;
                    try pieces.append(allocator, .{ .geometry = .{ .curve = curve, .cubic = segment == .cubic }, .source = span });
                }
                current = point;
                if (segment == .close) {
                    try finishRun(allocator, &pieces, &runs, run_first, point, move_span, true);
                    current = null;
                    start = null;
                }
            },
        };
        if (current) |point| try finishRun(allocator, &pieces, &runs, run_first, point, move_span, false);
        break :prepared vertices;
    };
    defer if (nib == .ellipse) allocator.free(vertices);
    const geometry = pieces.items(.geometry);
    const provenance = pieces.items(.source);
    var full = normalized: {
        var original = try envelope.Builder.init(allocator, vertices, settings);
        defer original.result.deinit();
        for (runs.items) |run| try original.subpath(geometry[run.first..run.end], geometry[run.first].curve.p0, run.closed);
        break :normalized try region.combine(allocator, original.result, Path.init(allocator), .unite, .{ .tolerance = options.tolerance, .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth });
    };
    defer full.deinit();
    const results = try allocator.alloc(Path, ranges.len);
    for (results) |*path| path.* = Path.init(result_allocator);
    errdefer {
        for (results) |*path| path.deinit();
        allocator.free(results);
    }
    var selected: std.ArrayList(prep.Piece) = .empty;
    defer selected.deinit(allocator);
    var work: usize = 0;
    for (ranges, results) |range, *result| {
        var tracing = Path.init(allocator);
        defer tracing.deinit();
        for (runs.items) |run| {
            const input = geometry[run.first..run.end];
            const source_spans = provenance[run.first..run.end];
            var first: usize = 0;
            while (first < input.len) {
                work += 1;
                if (work > options.max_vertices) return error.StrokeWorkLimit;
                if (!overlaps(source_spans[first], range)) {
                    first += 1;
                    continue;
                }
                var finish = first + 1;
                while (finish < input.len and overlaps(source_spans[finish], range)) : (finish += 1) {}
                const scans = std.math.mul(usize, finish - first, 2) catch return error.StrokeWorkLimit;
                work = std.math.add(usize, work, scans) catch return error.StrokeWorkLimit;
                if (work > options.max_vertices) return error.StrokeWorkLimit;
                selected.clearRetainingCapacity();
                try selected.ensureTotalCapacity(allocator, finish - first);
                for (input[first..finish], source_spans[first..finish]) |piece, span| selected.appendAssumeCapacity(try selection(.{ .geometry = piece, .source = span }, range));
                const whole = first == 0 and finish == input.len and range.begin <= source_spans[first].begin and range.end >= source_spans[finish - 1].end;
                var builder = try envelope.Builder.init(allocator, vertices, settings);
                defer builder.result.deinit();
                if (!(whole and run.closed)) {
                    const from = input[first];
                    const to = input[finish - 1];
                    const original_start = range.begin <= source_spans[first].begin;
                    const original_end = range.end >= source_spans[finish - 1].end;
                    const before = if (original_start) neighbor(input, first, false, run.closed) else null;
                    const after = if (original_end) neighbor(input, finish - 1, true, run.closed) else null;
                    // A stationary source span cannot supply a join direction.
                    // Do not silently invent one for a join-only selection.
                    if ((before != null and prep.stationary(from.curve)) or (after != null and prep.stationary(to.curve))) return error.InvalidSection;
                    builder.ends = .{
                        .start = if (first == 0 and original_start and !run.closed) paint.cap else .butt,
                        .end = if (finish == input.len and original_end and !run.closed) paint.cap else .butt,
                    };
                    try builder.subpath(selected.items, selected.items[0].curve.p0, false);
                    if (before) |piece| try addJoin(allocator, &builder.result, vertices, piece, from, settings);
                    if (after) |piece| try addJoin(allocator, &builder.result, vertices, to, piece, settings);
                } else try builder.subpath(selected.items, selected.items[0].curve.p0, true);
                if (tracing.segments.items.len == 0) std.mem.swap(Path, &tracing, &builder.result) else try tracing.append(builder.result);
                first = finish;
            }
        }
        // A MetaPost tracing is not distributive over centerline splits: its
        // retrograde inner joins can remove ink that overlapping pieces would
        // fill back in. Bound every contribution by the one original tracing.
        var clipped = try region.combine(allocator, tracing, full, .intersect, .{ .tolerance = options.tolerance, .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth });
        defer clipped.deinit();
        // Only retained geometry crosses the allocator/ownership boundary;
        // PathOps graphs and the shared source tracing remain scratch-owned.
        result.* = try clipped.clone(result_allocator);
    }
    return results;
}

fn addJoin(allocator: Allocator, body: *Path, nib: []const g.Point, before: prep.Piece, after: prep.Piece, options: outline.Options) !void {
    var knot = try envelope.joinOutline(allocator, nib, before, after, options);
    defer knot.deinit();
    const combined = try region.combine(allocator, body.*, knot, .unite, .{ .tolerance = options.tolerance, .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth });
    body.deinit();
    body.* = combined;
}

fn overlaps(source: dash.SourceSpan, range: Range) bool {
    if (source.contour != range.contour or source.end < range.begin or source.begin > range.end) return false;
    return source.begin == source.end or (source.begin < range.end and source.end > range.begin);
}

fn selection(piece: Piece, range: Range) !prep.Piece {
    const source = piece.source;
    if (source.begin == source.end) return piece.geometry;
    const begin = @max(source.begin, range.begin);
    const end = @min(source.end, range.end);
    if (begin == source.begin and end == source.end) return piece.geometry;
    const a = (begin - source.begin) / (source.end - source.begin);
    const b = (end - source.begin) / (source.end - source.begin);
    const curve = piece.geometry.curve;
    const first = if (a == 0) curve.p0 else curve.p0.lerp(curve.p3, a);
    const last = if (b == 1) curve.p3 else curve.p0.lerp(curve.p3, b);
    return .{ .curve = if (piece.geometry.cubic) try curve.trimmed(a, b) else .{ .p0 = first, .p1 = first, .p2 = last, .p3 = last }, .cubic = piece.geometry.cubic };
}

fn finishRun(allocator: Allocator, pieces: *Pieces, runs: *std.ArrayList(Run), first: usize, point: g.Point, span: dash.SourceSpan, closed: bool) !void {
    if (first == pieces.len) try pieces.append(allocator, .{ .geometry = .{ .curve = .{ .p0 = point, .p1 = point, .p2 = point, .p3 = point }, .cubic = false }, .source = span });
    try runs.append(allocator, .{ .first = first, .end = pieces.len, .closed = closed });
}

fn neighbor(pieces: []const prep.Piece, index: usize, forward: bool, closed: bool) ?prep.Piece {
    var current = index;
    for (0..pieces.len) |_| {
        if (forward) {
            if (current + 1 == pieces.len) {
                if (!closed) return null;
                current = 0;
            } else current += 1;
        } else {
            if (current == 0) {
                if (!closed) return null;
                current = pieces.len - 1;
            } else current -= 1;
        }
        if (!prep.stationary(pieces[current].curve)) return pieces[current];
    }
    return null;
}

fn same(a: g.Point, b: g.Point) bool {
    return a.x == b.x and a.y == b.y;
}

test "source stroke sections retain real caps and do not cap artificial boundaries" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    const result = try extract(t.allocator, t.allocator, source, .{ .width = 2, .cap = .round }, &.{ .{ .contour = 0, .begin = 0, .end = 0.5 }, .{ .contour = 0, .begin = 0.5, .end = 1 } }, .{});
    defer {
        for (result) |*path| path.deinit();
        t.allocator.free(result);
    }
    try t.expectApproxEqAbs(@as(f64, -1), result[0].bounds().?.min.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 5), result[0].bounds().?.max.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5), result[1].bounds().?.min.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 11), result[1].bounds().?.max.x, 1e-3);
}

fn checkPartition(allocator: Allocator, source: Path, paint: DisplayList.Pen, ranges: []const Range, whole: Range) !void {
    const options: outline.Options = .{ .tolerance = 1e-4 };
    const pieces = try extract(allocator, allocator, source, paint, ranges, options);
    defer {
        for (pieces) |*path| path.deinit();
        allocator.free(pieces);
    }
    const full = try extract(allocator, allocator, source, paint, &.{whole}, options);
    defer {
        full[0].deinit();
        allocator.free(full);
    }
    var settings = options;
    settings.cap = paint.cap;
    settings.join = paint.join;
    settings.miter_limit = paint.miter_limit;
    var original_dash = try dash.dashed(allocator, source, paint.dash, paint.dash_phase, settings);
    defer original_dash.deinit();
    const nib = paint.nib orelse @import("nib.zig").Nib{ .ellipse = g.Transform.scaling(paint.width, paint.width) };
    var native_tracing = try outline.strokeOutline(allocator, nib, original_dash, settings);
    defer native_tracing.deinit();
    var native = try region.combine(allocator, native_tracing, Path.init(allocator), .unite, .{ .tolerance = options.tolerance });
    defer native.deinit();
    var native_difference = try region.combine(allocator, native, full[0], .xor, .{ .tolerance = 1e-6 });
    defer native_difference.deinit();
    try std.testing.expect(@abs(native_difference.signedArea()) < 1e-5);
    var combined = Path.init(allocator);
    defer combined.deinit();
    for (pieces) |path| {
        const united = try region.combine(allocator, combined, path, .unite, .{ .tolerance = 1e-6 });
        combined.deinit();
        combined = united;
    }
    var missing = try region.combine(allocator, full[0], combined, .xor, .{ .tolerance = 1e-6 });
    defer missing.deinit();
    if (@abs(missing.signedArea()) >= 1e-5) {
        std.debug.print("section partition: cap={s}, join={s}, dash={any}, full={d}, combined={d}, xor={d}\n", .{ @tagName(paint.cap), @tagName(paint.join), paint.dash, full[0].signedArea(), combined.signedArea(), missing.signedArea() });
        var left = try region.combine(allocator, full[0], combined, .difference, .{ .tolerance = 1e-6 });
        defer left.deinit();
        var right = try region.combine(allocator, combined, full[0], .difference, .{ .tolerance = 1e-6 });
        defer right.deinit();
        std.debug.print("missing={d} {any}; extra={d} {any}\n", .{ left.signedArea(), left.segments.items, right.signedArea(), right.segments.items });
    }
    try std.testing.expect(@abs(missing.signedArea()) < 1e-5);
}

test "source sections partition original joins dash phases and closed seams" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    const ranges = [_]Range{ .{ .contour = 0, .begin = 0, .end = 1 }, .{ .contour = 0, .begin = 1, .end = 2 } };
    inline for (.{ DisplayList.Join.miter, .round, .bevel }) |join| {
        try checkPartition(t.allocator, source, .{ .width = 2, .cap = .square, .join = join }, &ranges, .{ .contour = 0, .begin = 0, .end = 2 });
        try checkPartition(t.allocator, source, .{ .width = 2, .cap = .round, .join = join, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &ranges, .{ .contour = 0, .begin = 0, .end = 2 });
    }
    try source.lineTo(.{ .x = 0, .y = 10 });
    try source.close();
    const seam = [_]Range{ .{ .contour = 0, .begin = 0, .end = 2 }, .{ .contour = 0, .begin = 2, .end = 4 } };
    try checkPartition(t.allocator, source, .{ .nib = .{ .polygon = &.{ .{ .x = -1, .y = -0.5 }, .{ .x = 1, .y = -0.5 }, .{ .x = 1, .y = 0.5 }, .{ .x = -1, .y = 0.5 } } }, .join = .miter }, &seam, .{ .contour = 0, .begin = 0, .end = 4 });
    try checkPartition(t.allocator, source, .{ .width = 2, .cap = .round, .dash = &.{ 15, 10 } }, &seam, .{ .contour = 0, .begin = 0, .end = 4 });
    var curve = Path.init(t.allocator);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 });
    try checkPartition(t.allocator, curve, .{ .nib = @import("nib.zig").Nib.square(), .cap = .round, .dash = &.{ 3, 2 }, .dash_phase = 0.7 }, &.{ .{ .contour = 0, .begin = 0, .end = 0.37 }, .{ .contour = 0, .begin = 0.37, .end = 1 } }, .{ .contour = 0, .begin = 0, .end = 1 });
}

test "source section phase true dash caps and contour identities stay on the original path" {
    const t = std.testing;
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 20, .y = 0 });
    try source.moveTo(.{ .x = 100, .y = 0 });
    try source.lineTo(.{ .x = 120, .y = 0 });
    const output = try extract(t.allocator, t.allocator, source, .{ .width = 2, .cap = .round, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &.{ .{ .contour = 0, .begin = 0.5, .end = 1 }, .{ .contour = 1, .begin = 1, .end = 1.5 } }, .{});
    defer {
        for (output) |*path| path.deinit();
        t.allocator.free(output);
    }
    try t.expectApproxEqAbs(@as(f64, 10), output[0].bounds().?.min.x, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 21), output[0].bounds().?.max.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 99), output[1].bounds().?.min.x, 1e-3);
    try t.expectApproxEqAbs(@as(f64, 110), output[1].bounds().?.max.x, 1e-9);
    try t.expectError(error.InvalidSection, extract(t.allocator, t.allocator, source, .{}, &.{.{ .contour = 1, .begin = 0, .end = 1 }}, .{}));
    try t.expectError(error.InvalidSection, extract(t.allocator, t.allocator, source, .{}, &.{.{ .contour = 0, .begin = 0.5, .end = 0.5 }}, .{}));
}

test "source closed cubic circle halves retain the full round stroke" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    const paint: DisplayList.Pen = .{ .width = 6, .cap = .round, .join = .round };
    const settings: outline.Options = .{ .tolerance = 0.001, .cap = .round, .join = .round };
    var original = try outline.strokeOutline(t.allocator, .{ .ellipse = .scaling(6, 6) }, source, settings);
    defer original.deinit();
    var whole = try region.combine(t.allocator, original, Path.init(t.allocator), .unite, .{ .tolerance = 0.001 });
    defer whole.deinit();
    const winding = @import("../region/pathops/winding.zig");
    for (0..34) |x| for (0..34) |y| {
        const point: g.Point = .{ .x = 8.37 + 2 * @as(f64, @floatFromInt(x)), .y = 18.59 + 2 * @as(f64, @floatFromInt(y)) };
        try t.expectEqual(try winding.windingAt(original, point) != 0, try winding.windingAt(whole, point) != 0);
    };
    const result = try extract(t.allocator, t.allocator, source, paint, &.{ .{ .contour = 0, .begin = 0, .end = 2 }, .{ .contour = 0, .begin = 2, .end = 4 } }, settings);
    defer {
        for (result) |*path| path.deinit();
        t.allocator.free(result);
    }
    for (0..34) |x| for (0..34) |y| {
        const point: g.Point = .{ .x = 8.37 + 2 * @as(f64, @floatFromInt(x)), .y = 18.59 + 2 * @as(f64, @floatFromInt(y)) };
        const covered = try winding.windingAt(result[0], point) != 0 or try winding.windingAt(result[1], point) != 0;
        try t.expectEqual(try winding.windingAt(original, point) != 0, covered);
    };
    var joined = Path.init(t.allocator);
    defer joined.deinit();
    for (result) |path| {
        const united = try region.combine(t.allocator, joined, path, .unite, .{ .tolerance = 0.001 });
        joined.deinit();
        joined = united;
    }
    var difference = try region.combine(t.allocator, whole, joined, .xor, .{ .tolerance = 0.001 });
    defer difference.deinit();
    if (@abs(difference.signedArea()) >= 1e-5) std.debug.print("circle native={d}, united={d}, xor={d}, bounds={any}\n", .{ whole.signedArea(), joined.signedArea(), difference.signedArea(), difference.bounds() });
    try t.expect(@abs(difference.signedArea()) < 1e-5);
}

test "source circle raw nonzero tracing agrees with its canonical region" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    var original = try outline.strokeOutline(t.allocator, .{ .ellipse = .scaling(6, 6) }, source, .{ .tolerance = 0.001, .cap = .round, .join = .round });
    defer original.deinit();
    var canonical = try region.combine(t.allocator, original, Path.init(t.allocator), .unite, .{ .tolerance = 0.001 });
    defer canonical.deinit();
    var difference = try region.combine(t.allocator, original, canonical, .xor, .{ .tolerance = 0.001 });
    defer difference.deinit();
    try t.expect(@abs(difference.signedArea()) < 1e-5);
}

test "source section offset retains a long inactive boundary" {
    const t = std.testing;
    var source = try Path.circle(t.allocator, .{ .x = 40, .y = 50 }, 25);
    defer source.deinit();
    const result = try extract(t.allocator, t.allocator, source, .{ .width = 6, .cap = .round, .join = .round }, &.{.{ .contour = 0, .begin = 0, .end = 2 }}, .{ .tolerance = 0.001 });
    defer {
        result[0].deinit();
        t.allocator.free(result);
    }
    // The normalized offset band has more than a thousand consecutive
    // inactive spans. Its union must finish the chase rather than stop at an
    // input-independent traversal limit.
    var expanded = try region.offset(t.allocator, result[0], 2, .{ .tolerance = 0.001, .join = .round });
    defer expanded.deinit();
    try t.expect(!expanded.open);
    const winding = @import("../region/pathops/winding.zig");
    try t.expect(try winding.windingAt(expanded, .{ .x = 40, .y = 79 }) != 0);
    try t.expectEqual(@as(i32, 0), try winding.windingAt(expanded, .{ .x = 40, .y = 81 }));
    try t.expectEqual(@as(i32, 0), try winding.windingAt(expanded, .{ .x = 40, .y = 50 }));
}

fn allocationCase(allocator: Allocator) !void {
    var source = Path.init(std.testing.allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    try source.lineTo(.{ .x = 10, .y = 10 });
    var retained: std.heap.ArenaAllocator = .init(allocator);
    defer retained.deinit();
    const result = try extract(allocator, retained.allocator(), source, .{ .nib = @import("nib.zig").Nib.square(), .cap = .round, .join = .bevel, .dash = &.{ 3, 2 }, .dash_phase = 1 }, &.{ .{ .contour = 0, .begin = 0, .end = 1 }, .{ .contour = 0, .begin = 1, .end = 2 } }, .{});
    defer {
        for (result) |*path| path.deinit();
        allocator.free(result);
    }
    try std.testing.expect(result[0].segments.items.len != 0 and result[1].segments.items.len != 0);
}

test "source section coverage separates scratch and result ownership at every allocation failure" {
    try allocationCase(std.testing.allocator);
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationCase, .{});
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var source = Path.init(std.testing.allocator);
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 10, .y = 0 });
    const results = try extract(scratch.allocator(), std.testing.allocator, source, .{ .width = 2, .cap = .square }, &.{.{ .contour = 0, .begin = 0, .end = 1 }}, .{});
    var retained = results[0];
    source.deinit();
    scratch.deinit();
    defer retained.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 24), retained.signedArea(), 1e-5);
}

test "source sections preserve actual millimetre trefoil stroke coverage" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mm = 72.0 / 25.4;
    const tolerance = 0.001;
    const root3 = @sqrt(@as(f64, 3));
    const first: g.Point = .{ .x = 60, .y = 90 };
    const second: g.Point = .{ .x = 60 - root3 * 20, .y = 30 };
    const third: g.Point = .{ .x = 60 + root3 * 20, .y = 30 };
    var source = Path.init(a);
    try source.moveTo(first.scale(mm));
    try source.cubicTo(first.add(.{ .x = 44, .y = 0 }).scale(mm), second.add(.{ .x = 22, .y = -root3 * 22 }).scale(mm), second.scale(mm));
    try source.cubicTo(second.add(.{ .x = -22, .y = root3 * 22 }).scale(mm), third.add(.{ .x = 22, .y = root3 * 22 }).scale(mm), third.scale(mm));
    try source.cubicTo(third.add(.{ .x = -22, .y = -root3 * 22 }).scale(mm), first.add(.{ .x = -44, .y = 0 }).scale(mm), first.scale(mm));
    try source.close();
    const hits = try @import("../path/crossings.zig").find(a, &.{source}, .{ .tolerance = tolerance });
    try t.expectEqual(@as(usize, 3), hits.len);
    var visits: [6]f64 = undefined;
    for (hits, 0..) |hit, i| {
        visits[2 * i] = hit.first.time;
        visits[2 * i + 1] = hit.second.time;
    }
    std.mem.sort(f64, &visits, {}, std.sort.asc(f64));
    var cuts: [7]f64 = undefined;
    cuts[0] = 0;
    cuts[6] = 3;
    for (0..5) |i| {
        const middle = (visits[i] + visits[i + 1]) / 2;
        const node = @floor(middle) + @as(f64, if (middle - @floor(middle) > 0.5) 1 else 0);
        cuts[i + 1] = if (visits[i] < node and node < visits[i + 1]) node else middle;
    }
    var ranges: [6]Range = undefined;
    for (&ranges, 0..) |*range, i| range.* = .{ .contour = 0, .begin = cuts[i], .end = cuts[i + 1] };
    const paint: DisplayList.Pen = .{ .width = 3 * mm, .cap = .round, .join = .round };
    const raw = try outline.strokeOutline(a, .{ .ellipse = g.Transform.scaling(paint.width, paint.width) }, source, .{ .tolerance = tolerance, .cap = .round, .join = .round });
    const full = try region.combine(a, raw, Path.init(a), .unite, .{ .tolerance = tolerance });
    const parts = try extract(a, a, source, paint, &ranges, .{ .tolerance = tolerance });
    var combined = Path.init(a);
    for (parts) |part| combined = try region.combine(a, combined, part, .unite, .{ .tolerance = tolerance });
    // This oracle only uses bounded path subdivision and half-open line rays;
    // it does not call the Boolean kernel's curve roots or face windings.
    const Probe = struct {
        fn flat(allocator: Allocator, path: Path) !Path {
            return @import("../path/flatten.zig").flatten(allocator, path, .{ .tolerance = 1e-5, .length_tolerance = 1e-5, .max_segments = 1048576, .max_depth = 32 });
        }
        fn inside(path: Path, p: g.Point, margin: f64) ?bool {
            var winding: i32 = 0;
            var current = g.Point.zero;
            var start = g.Point.zero;
            for (path.segments.items) |segment| {
                const end = switch (segment) {
                    .move => |point| {
                        current = point;
                        start = point;
                        continue;
                    },
                    .line => |point| point,
                    .close => start,
                    .cubic => unreachable,
                };
                const delta = end.sub(current);
                const relative = p.sub(current);
                if (margin > 0) {
                    const length = delta.dot(delta);
                    const along = if (length > 0) std.math.clamp(relative.dot(delta) / length, 0, 1) else 0;
                    const distance = relative.sub(delta.scale(along));
                    if (distance.dot(distance) < margin * margin) return null;
                }
                if (current.y <= p.y and end.y > p.y and delta.cross(relative) > 0) winding += 1;
                if (current.y > p.y and end.y <= p.y and delta.cross(relative) < 0) winding -= 1;
                current = end;
            }
            return winding != 0;
        }
    };
    const raw_flat = try Probe.flat(a, raw);
    const full_flat = try Probe.flat(a, full);
    const union_flat = try Probe.flat(a, combined);
    var part_flats: [6]Path = undefined;
    for (parts, &part_flats) |part, *flat| flat.* = try Probe.flat(a, part);
    var checked: usize = 0;
    for (0..61) |x| for (0..59) |y| {
        const p: g.Point = .{ .x = (2 * @as(f64, @floatFromInt(x)) + 0.123) * mm, .y = (2 * @as(f64, @floatFromInt(y)) + 0.217) * mm };
        const expected = Probe.inside(raw_flat, p, 2 * tolerance) orelse continue;
        checked += 1;
        try t.expectEqual(expected, Probe.inside(full_flat, p, 0).?);
        try t.expectEqual(expected, Probe.inside(union_flat, p, 0).?);
        var covered = false;
        for (part_flats) |part| {
            const inside = Probe.inside(part, p, 0).?;
            try t.expect(expected or !inside);
            covered = covered or inside;
        }
        try t.expectEqual(expected, covered);
    };
    try t.expect(checked > 3500);
    for (0..900) |i| {
        const position = try source.curveAt((@as(f64, @floatFromInt(i)) + 0.371) / 300);
        const center = position.curve.at(position.t);
        const tangent = try position.curve.derivative(position.t).normalized();
        for ([_]f64{ -0.45, -0.2, 0, 0.2, 0.45 }) |offset| {
            const p = center.add((g.Point{ .x = -tangent.y, .y = tangent.x }).scale(offset * paint.width));
            try t.expect(Probe.inside(raw_flat, p, 0).?);
            try t.expect(Probe.inside(union_flat, p, 0).?);
        }
    }
}
