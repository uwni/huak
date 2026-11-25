//! Writing each image arc by arc, in runs behind as many layers.
const std = @import("std");
const c = @import("space_c");
const Model = @import("../Model.zig");
const Work = @import("Work.zig");
const Drawn = Work.Drawn;
const Run = Work.Run;

/// OCCT's tolerances: points closer than `confusion` coincide, and curve
/// parameters closer than `parametric`.
const confusion = 1e-7;

const parametric = 1e-9;

fn sameFace(a: c.HuakShapeHit, b: c.HuakShapeHit) bool {
    return a.source == b.source and a.face == b.face;
}

/// How many of the layers are of the face that a line of sight meets.
fn layersOf(layers: []const c.HuakLayer, hit: c.HuakShapeHit) usize {
    var count: usize = 0;
    for (layers) |layer| {
        if (layer.source == hit.source and layer.face == hit.face) count += 1;
    }
    return count;
}

/// How far a depth stands from the nearest of the depths of an arc's curves.
fn fromCurves(curves: []const c.HuakArcOrigin, depth: f64) f64 {
    var least = std.math.inf(f64);
    for (curves) |curve| least = @min(least, @abs(depth - curve.depth));
    return least;
}

/// Which of the meetings of the line of sight through an arc's middle are
/// with faces that end at the arc. A face ends there as many times as it
/// has more layers on one side of the arc than on the other, where curves
/// along the arc bound it: of the face's meetings, as many as that are
/// those nearest the depths of the arc's curves.
fn endings(s: std.mem.Allocator, drawn: Drawn, arc: usize) ![]const bool {
    const hits = drawn.middles.row(arc);
    const ends = try s.alloc(bool, hits.len);
    @memset(ends, false);
    const ones = try s.alloc(usize, hits.len);
    const Nearer = struct {
        hits: []const c.HuakShapeHit,
        curves: []const c.HuakArcOrigin,

        fn less(self: @This(), x: usize, y: usize) bool {
            return fromCurves(self.curves, self.hits[x].depth) < fromCurves(self.curves, self.hits[y].depth);
        }
    };
    for (hits, 0..) |hit, i| {
        const seen = for (hits[0..i]) |other| {
            if (sameFace(other, hit)) break true;
        } else false;
        if (seen) continue;
        var count: usize = 0;
        for (hits, 0..) |other, j| if (sameFace(other, hit)) {
            ones[count] = j;
            count += 1;
        };
        const across = @min(layersOf(drawn.left(arc), hit), layersOf(drawn.right(arc), hit));
        if (count <= across) continue;
        std.mem.sort(usize, ones[0..count], Nearer{ .hits = hits, .curves = drawn.arcs.along(arc) }, Nearer.less);
        for (ones[0 .. count - across]) |j| ends[j] = true;
    }
    return ends;
}

/// How many layers stand in front of the curve of an image along an arc
/// over the arc's middle: of the faces that the line of sight there meets
/// and that do not end at the arc, as `endings` tells, those nearer than the
/// curve by more than its tolerance.
fn layersOver(hits: []const c.HuakShapeHit, ends: []const bool, along: c.HuakArcOrigin) usize {
    var count: usize = 0;
    for (hits, ends) |hit, end| {
        if (!end and hit.depth - along.depth > along.tolerance + confusion) count += 1;
    }
    return count;
}

/// Writes each image that is a line arc by arc in order along it, in
/// runs behind as many layers.
pub fn drawArcs(self: *Work, drawn: Drawn) Model.Error!void {
    const s = self.scratch;
    var by_image: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    for (drawn.tools, 0..) |tool, t| try by_image.put(s, tool.image, t);
    const Piece = struct { first: f64, last: f64, covering: usize, leaves: c_int };
    const pieces = try s.alloc(std.ArrayList(Piece), drawn.tools.len);
    @memset(pieces, .empty);
    for (0..drawn.arcs.arcs.len) |k| {
        const ends = try endings(s, drawn, k);
        for (drawn.arcs.along(k)) |origin| {
            const t = by_image.get(origin.image) orelse return self.model.failWith("an arc shows an image that was not arranged");
            if (drawn.tools[t].kind == null) continue;
            const covering = layersOver(drawn.middles.row(k), ends, origin);
            try pieces[t].append(s, .{ .first = origin.first, .last = origin.last, .covering = if (self.layered) covering else @min(covering, 1), .leaves = origin.leaves });
        }
    }
    var written: std.ArrayList(c.HuakPiece) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    for (drawn.tools, pieces) |tool, *list| {
        const kind = tool.kind orelse continue;
        std.mem.sort(Piece, list.items, {}, struct {
            fn before(_: void, x: Piece, y: Piece) bool {
                return x.first < y.first;
            }
        }.before);
        // Along a stretch where the image runs within tolerance of
        // another, what covers it cannot be told: it is covered as
        // where it leaves the stretch.
        var back = list.items.len;
        while (back > 0) {
            back -= 1;
            const piece = &list.items[back];
            if (piece.leaves > 0 and back + 1 < list.items.len and list.items[back + 1].first - piece.last <= parametric) piece.covering = list.items[back + 1].covering;
        }
        for (list.items, 0..) |*piece, at| {
            if (piece.leaves < 0 and at > 0 and piece.first - list.items[at - 1].last <= parametric) piece.covering = list.items[at - 1].covering;
        }
        var start: usize = 0;
        while (start < list.items.len) {
            var end = start + 1;
            while (end < list.items.len and list.items[end].covering == list.items[start].covering) end += 1;
            const first = list.items[start].first;
            const last = list.items[end - 1].last;
            if (last - first > parametric) {
                try written.append(s, .{ .image = tool.image, .whole = 0, .first = first, .last = last });
                try runs.append(s, .{ .source = tool.source, .kind = kind, .other = tool.other, .covering = list.items[start].covering });
            }
            start = end;
        }
    }
    try writeRuns(self, written.items, runs.items);
}

/// Writes each piece as a line of its run.
pub fn writeRuns(self: *Work, pieces: []const c.HuakPiece, runs: []const Run) Model.Error!void {
    std.debug.assert(pieces.len == runs.len);
    if (pieces.len == 0) return;
    const approximated = try self.view.approximate(pieces, self.tolerance);
    for (runs, 0..) |run, k| {
        const start = self.out.commands.items.len;
        try self.out.commands.appendSlice(self.allocator, approximated.row(k));
        try self.out.lines.append(self.allocator, .{ .source = run.source, .start = start, .count = self.out.commands.items.len - start, .covering = run.covering, .kind = run.kind, .other = run.other });
    }
}
