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
const Piece = struct { geometry: prep.Piece, source: dash.SourceSpan };
const Pieces = std.MultiArrayList(Piece);
const Run = struct { first: usize, end: usize, closed: bool };

/// Return one independently owned nonzero-fill coverage per requested range.
/// The paths and the slice use `allocator`, which also holds the working data
/// until it returns. Deinitialize every path, then free the slice.
/// Inputs stay borrowed. Real dash/path endpoints retain their original cap;
/// artificial cuts are butt boundaries. Original joins belong to both adjacent
/// closed ranges. Union coverage before clipping the original stroke once.
pub fn extract(allocator: Allocator, source: Path, pen: DisplayList.Pen, ranges: []const Range, options: outline.Options) ![]Path {
    try DisplayList.validateStyle(&.{ .pen = pen });
    if (pen.motion != null) return error.UnsupportedMotionSections;
    if (ranges.len > options.max_segments or source.segments.items.len > options.max_segments *| 2 +| 1) return error.StrokeWorkLimit;
    {
        const contours = try Path.contours.contourRanges(source, allocator);
        defer allocator.free(contours);
        for (ranges) |range| {
            if (range.contour >= contours.len or !std.math.isFinite(range.begin) or !std.math.isFinite(range.end)) return error.InvalidSection;
            const contour = contours[range.contour];
            if (range.begin < contour.begin or range.end > contour.end or range.begin > range.end or (range.begin == range.end and contour.begin != contour.end)) return error.InvalidSection;
        }
    }
    var settings = options;
    settings.cap = pen.cap;
    settings.join = pen.join;
    settings.miter_limit = pen.miter_limit;
    try outline.validateOptions(settings);
    if (ranges.len == 0) return allocator.alloc(Path, 0);
    if (!pen.paint.hasInk()) {
        const result = try allocator.alloc(Path, ranges.len);
        for (result) |*path| path.* = Path.init(allocator);
        return result;
    }
    var pieces: Pieces = .empty;
    defer pieces.deinit(allocator);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    const nib = pen.nib orelse @import("nib.zig").Nib{ .ellipse = g.Transform.scaling(pen.width, pen.width) };
    const vertices = prepared: {
        var dashed = try dash.mapped(allocator, source, pen.dash, pen.dash_phase, settings);
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
                if (segment != .close or !current.?.eql(point)) {
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
    for (results) |*path| path.* = Path.init(allocator);
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
                        .start = if (first == 0 and original_start and !run.closed) pen.cap else .butt,
                        .end = if (finish == input.len and original_end and !run.closed) pen.cap else .butt,
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
        // The empty placeholder owns no memory, so the clipped coverage
        // replaces it directly.
        result.* = try region.combine(allocator, tracing, full, .intersect, .{ .tolerance = options.tolerance, .max_segments = options.max_segments, .max_vertices = options.max_vertices, .max_depth = options.max_depth });
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

test {
    _ = @import("sections/ranges_test.zig");
    _ = @import("sections/partition_test.zig");
    _ = @import("sections/trefoil_test.zig");
}
