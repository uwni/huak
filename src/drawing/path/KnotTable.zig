//! Sparse, ordered solved knot directions. A boundary index is the index of
//! the departing command (one past the arriving command for an open end).
//! A shared closing seam stays at the first cubic and also serves the last.
const std = @import("std");
const g = @import("../geometry.zig");
const Segment = @import("Path.zig").Segment;
const Table = @This();

entries: std.ArrayList(Knot) = .empty,

const Witness = struct { depth: u2 = 0, handle: g.Point = .zero };

fn witness(anchor: g.Point, controls: [3]g.Point) Witness {
    for (controls, 1..) |p, depth| if (!p.eql(anchor)) return .{ .depth = @intCast(depth), .handle = p };
    return .{};
}

pub const Knot = struct {
    index: u32,
    // Zero means absent. Otherwise the order and first distinct control
    // point together identify the first nonzero endpoint derivative.
    incoming: u2 = 0,
    outgoing: u2 = 0,
    seam: bool = false,
    point: g.Point,
    before: g.Point = .zero,
    after: g.Point = .zero,
    tangent: g.Point,

    fn compareIndex(index: usize, knot: Knot) std.math.Order {
        return std.math.order(index, @as(usize, knot.index));
    }

    fn matches(k: *const Knot, c: g.Cubic, start: bool) bool {
        if (start) {
            if (k.outgoing == 0 or !k.point.eql(c.p0)) return false;
            const w = witness(c.p0, .{ c.p1, c.p2, c.p3 });
            return k.outgoing == w.depth and k.after.eql(w.handle);
        }
        if (k.incoming == 0 or !k.point.eql(c.p3)) return false;
        const w = witness(c.p3, .{ c.p2, c.p1, c.p0 });
        return k.incoming == w.depth and k.before.eql(w.handle);
    }

    pub fn mapped(k: Knot, segments: []const Segment, t: g.Transform) error{NonFinite}!Knot {
        var out = k;
        // An affine map may round two different handles to the same point.
        // Invalidate edited witnesses before mapping either coordinate.
        if (k.incoming != 0) {
            var boundary: usize = k.index;
            if (k.seam) {
                while (boundary < segments.len and segments[boundary] != .move and segments[boundary] != .close) boundary += 1;
                if (boundary >= segments.len or segments[boundary] != .close) boundary = 0;
            }
            const c = if (boundary > 0) cubicAt(segments, boundary - 1) else null;
            if (c == null or !k.matches(c.?, false)) out.incoming = 0;
        }
        if (k.outgoing != 0) {
            const c = cubicAt(segments, k.index);
            if (c == null or !k.matches(c.?, true)) out.outgoing = 0;
        }
        if (out.incoming == 0 and out.outgoing == 0) return out;
        var linear = t;
        linear.e = 0;
        linear.f = 0;
        out.point = t.apply(k.point);
        out.tangent = linear.apply(k.tangent);
        if (out.incoming != 0) out.before = t.apply(k.before);
        if (out.outgoing != 0) out.after = t.apply(k.after);
        if (!out.point.isFinite() or !out.tangent.isFinite() or !out.before.isFinite() or !out.after.isFinite()) return error.NonFinite;
        return out;
    }
};

fn cubicAt(segments: []const Segment, index: usize) ?g.Cubic {
    if (index == 0 or index >= segments.len or segments[index] != .cubic) return null;
    const p0 = switch (segments[index - 1]) {
        .move, .line => |p| p,
        .cubic => |c| c.end,
        .close => return null,
    };
    const c = segments[index].cubic;
    return .{ .p0 = p0, .p1 = c.c1, .p2 = c.c2, .p3 = c.end };
}

pub fn clone(self: *const Table, a: std.mem.Allocator) !Table {
    return .{ .entries = .fromOwnedSlice(try a.dupe(Knot, self.entries.items)) };
}

fn lowerBound(self: *const Table, index: usize) usize {
    return std.sort.lowerBound(Knot, self.entries.items, index, Knot.compareIndex);
}

const Side = enum { outgoing, incoming, seam_incoming };

fn at(records: []const Knot, key: usize, c: g.Cubic, side: Side) g.Point {
    for (records) |*k| {
        if (k.index > key) break;
        if (k.index != key) continue;
        if (side != .outgoing and k.seam != (side == .seam_incoming)) continue;
        if (k.matches(c, side == .outgoing)) return k.tangent;
    }
    return .zero;
}

pub fn directions(self: *const Table, segments: []const Segment, index: usize, c: g.Cubic) [2]g.Point {
    var cursor = self.lowerBound(index);
    return self.directionsForward(segments, index, c, &cursor);
}

/// Sweeping a contour visits every source cubic in increasing command order.
pub fn directionsForward(self: *const Table, segments: []const Segment, index: usize, c: g.Cubic, cursor: *usize) [2]g.Point {
    while (cursor.* < self.entries.items.len and self.entries.items[cursor.*].index < index) cursor.* += 1;
    const records = self.entries.items[cursor.*..];
    var end = at(records, index + 1, c, .incoming);
    if (end.eql(.zero) and index + 1 < segments.len and segments[index + 1] == .close) {
        var move = index;
        while (move > 0 and segments[move] != .move) move -= 1;
        const head = move + 1;
        end = at(self.entries.items[self.lowerBound(head)..], head, c, .seam_incoming);
    }
    return .{ at(records, index, c, .outgoing), end };
}

/// Append records in command order. Distinct one-sided directions at a
/// deliberate corner remain distinct even if their index is the same.
pub fn push(self: *Table, k: Knot) void {
    if (self.mergesStart(k)) {
        const shared = &self.entries.items[self.entries.items.len - 1];
        shared.outgoing = k.outgoing;
        shared.after = k.after;
        return;
    }
    self.entries.appendAssumeCapacity(k);
}

pub fn sides(index: u32, c: g.Cubic, start: g.Point, end: g.Point) [2]?Knot {
    const a = witness(c.p0, .{ c.p1, c.p2, c.p3 });
    const b = witness(c.p3, .{ c.p2, c.p1, c.p0 });
    return .{
        if (a.depth == 0 or start.eql(.zero)) null else .{ .index = index, .point = c.p0, .after = a.handle, .outgoing = a.depth, .tangent = start },
        if (b.depth == 0 or end.eql(.zero)) null else .{ .index = index + 1, .point = c.p3, .before = b.handle, .incoming = b.depth, .tangent = end },
    };
}

pub fn mergesStart(self: *const Table, k: Knot) bool {
    const prev = self.entries.getLastOrNull() orelse return false;
    return !k.seam and k.incoming == 0 and k.outgoing != 0 and prev.index == k.index and prev.incoming != 0 and prev.outgoing == 0 and prev.point.eql(k.point) and prev.tangent.eql(k.tangent);
}

pub fn close(self: *Table, segments: []const Segment) void {
    // Called after CLOSE is appended. A nonzero closing line has its own tangent.
    const tail = self.entries.getLastOrNull() orelse return;
    const stop = segments.len - 1;
    if (tail.index != stop or tail.incoming == 0 or tail.outgoing != 0) return;
    var move = stop;
    while (move > 0 and segments[move] != .move) move -= 1;
    const first = self.lowerBound(move + 1);
    if (first >= self.entries.items.len - 1) return;
    const head = &self.entries.items[first];
    if (head.index != move + 1 or head.incoming != 0 or head.outgoing == 0 or !head.point.eql(tail.point) or !head.tangent.eql(tail.tangent)) return;
    head.incoming = tail.incoming;
    head.before = tail.before;
    head.seam = true;
    _ = self.entries.pop();
}
