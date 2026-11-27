//! Scanline rasterizer for the vector clip path on a 2x2 SSAA strip grid.
//! Tracks which subpixel centers lie inside the clip path so edge dilation
//! never bleeds into genuinely transparent areas inside the clip.
const std = @import("std");
const g = @import("../../../drawing/geometry.zig");
const Path = @import("../../../drawing/path/Path.zig");

/// One directed non-horizontal segment in subpixel coordinates (y-down).
pub const Edge = struct {
    /// Upper endpoint (y0 < y1).
    x0: f64,
    y0: f64,
    /// Lower endpoint.
    x1: f64,
    y1: f64,
    /// Inverse slope dx / dy.
    inv_slope: f64,
    /// +1 if original segment went downward (increasing y), -1 if upward.
    dir: i8,
};

pub const Mask = struct {
    edges: []Edge,
    evenodd: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        segments: []const Path.Segment,
        evenodd: bool,
        box: g.BBox,
        sub_w: u32,
        sub_h: u32,
    ) !Mask {
        const scale_x = @as(f64, @floatFromInt(sub_w)) / box.width();
        const scale_y = @as(f64, @floatFromInt(sub_h)) / box.height();
        const max_y: f64 = @floatFromInt(sub_h);

        var edges: std.ArrayList(Edge) = .empty;
        errdefer edges.deinit(allocator);

        var current = g.Point.zero;
        var start = g.Point.zero;
        var has_start = false;

        for (segments) |seg| switch (seg) {
            .move => |p| {
                if (has_start and !current.eql(start)) {
                    try appendLine(allocator, &edges, toSub(current, box, scale_x, scale_y), toSub(start, box, scale_x, scale_y), max_y);
                }
                current = p;
                start = p;
                has_start = true;
            },
            .line => |p| {
                try appendLine(allocator, &edges, toSub(current, box, scale_x, scale_y), toSub(p, box, scale_x, scale_y), max_y);
                current = p;
            },
            .cubic => |curve| {
                const p0 = toSub(current, box, scale_x, scale_y);
                const p1 = toSub(curve.c1, box, scale_x, scale_y);
                const p2 = toSub(curve.c2, box, scale_x, scale_y);
                const p3 = toSub(curve.end, box, scale_x, scale_y);
                try appendCubic(allocator, &edges, p0, p1, p2, p3, max_y);
                current = curve.end;
            },
            .close => {
                if (has_start) {
                    try appendLine(allocator, &edges, toSub(current, box, scale_x, scale_y), toSub(start, box, scale_x, scale_y), max_y);
                    current = start;
                }
            },
        };
        if (has_start and !current.eql(start)) {
            try appendLine(allocator, &edges, toSub(current, box, scale_x, scale_y), toSub(start, box, scale_x, scale_y), max_y);
        }

        // Sort by y0 ascending so each scanline can early-break.
        std.mem.sort(Edge, edges.items, {}, struct {
            fn lessThan(_: void, a: Edge, b: Edge) bool {
                return a.y0 < b.y0;
            }
        }.lessThan);

        return .{ .edges = try edges.toOwnedSlice(allocator), .evenodd = evenodd };
    }

    pub fn deinit(self: Mask, allocator: std.mem.Allocator) void {
        allocator.free(self.edges);
    }

    /// Fills `bits` (one byte per subpixel, 1 = inside clip, 0 = outside) for
    /// subpixel rows `[sy_start .. sy_start + rows)` of width `sub_w`.
    pub fn fillStrip(
        self: *const Mask,
        crossings: *std.ArrayList(Crossing),
        allocator: std.mem.Allocator,
        sy_start: u32,
        rows: u32,
        sub_w: u32,
        bits: []u8,
    ) !void {
        @memset(bits, 0);
        if (self.edges.len == 0) return;

        // First collect edges overlapping [sy_start + 0.5, sy_start + rows - 0.5].
        const strip_top = @as(f64, @floatFromInt(sy_start)) + 0.5;
        const strip_bot = @as(f64, @floatFromInt(sy_start + rows)) - 0.5;

        for (0..rows) |r| {
            const y = @as(f64, @floatFromInt(sy_start + @as(u32, @intCast(r)))) + 0.5;
            if (y < strip_top or y > strip_bot) continue;
            crossings.clearRetainingCapacity();

            for (self.edges) |edge| {
                if (edge.y0 > y) break;
                if (edge.y1 <= y) continue;
                const x = edge.x0 + (y - edge.y0) * edge.inv_slope;
                try crossings.append(allocator, .{ .x = x, .dir = edge.dir });
            }
            if (crossings.items.len == 0) continue;

            std.mem.sort(Crossing, crossings.items, {}, struct {
                fn lessThan(_: void, a: Crossing, b: Crossing) bool {
                    return a.x < b.x;
                }
            }.lessThan);

            const row_bits = bits[r * sub_w ..][0..sub_w];
            const width_f: f64 = @floatFromInt(sub_w);
            var winding: i32 = 0;
            var inside = false;
            var span_start: f64 = 0;

            for (crossings.items) |cross| {
                winding += cross.dir;
                const now_inside = if (self.evenodd) (@mod(winding, 2) != 0) else (winding != 0);
                if (!inside and now_inside) {
                    span_start = cross.x;
                } else if (inside and !now_inside) {
                    markSpan(row_bits, span_start, cross.x, width_f);
                }
                inside = now_inside;
            }
            if (inside) {
                markSpan(row_bits, span_start, width_f, width_f);
            }
        }
    }
};

pub const Crossing = struct {
    x: f64,
    dir: i8,
};

fn markSpan(row: []u8, x0: f64, x1: f64, width_f: f64) void {
    const lo = @max(0.0, x0);
    const hi = @min(width_f, x1);
    if (!(hi > lo)) return;
    // Subpixel sx has center sx + 0.5; include sx when lo <= sx + 0.5 < hi.
    const first_f = @ceil(lo - 0.5);
    const last_f = @ceil(hi - 0.5);
    const start: usize = if (first_f <= 0) 0 else @min(row.len, @as(usize, @intFromFloat(first_f)));
    const end: usize = if (last_f <= 0) 0 else @min(row.len, @as(usize, @intFromFloat(last_f)));
    if (end > start) @memset(row[start..end], 1);
}

fn toSub(p: g.Point, box: g.BBox, scale_x: f64, scale_y: f64) g.Point {
    return .{
        .x = (p.x - box.min.x) * scale_x,
        .y = (box.max.y - p.y) * scale_y,
    };
}

fn appendLine(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), a: g.Point, b: g.Point, max_y: f64) !void {
    if (a.y == b.y) return;
    const down = a.y < b.y;
    const p0 = if (down) a else b;
    const p1 = if (down) b else a;
    if (p1.y <= 0 or p0.y >= max_y) return;
    try edges.append(allocator, .{
        .x0 = p0.x,
        .y0 = p0.y,
        .x1 = p1.x,
        .y1 = p1.y,
        .inv_slope = (p1.x - p0.x) / (p1.y - p0.y),
        .dir = if (down) 1 else -1,
    });
}

fn appendCubic(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    p0: g.Point,
    p1: g.Point,
    p2: g.Point,
    p3: g.Point,
    max_y: f64,
) !void {
    const min_y = @min(@min(p0.y, p1.y), @min(p2.y, p3.y));
    const hi_y = @max(@max(p0.y, p1.y), @max(p2.y, p3.y));
    if (hi_y <= 0 or min_y >= max_y) return;

    // Wang's flatness bound: flatten within 0.125 subpixels.
    const d1 = g.Point{ .x = p0.x - 2 * p1.x + p2.x, .y = p0.y - 2 * p1.y + p2.y };
    const d2 = g.Point{ .x = p1.x - 2 * p2.x + p3.x, .y = p1.y - 2 * p2.y + p3.y };
    const m = @max(d1.norm(), d2.norm());
    const steps_f = @ceil(@sqrt(@max(0.0, 0.75 * m / 0.125)));
    const steps: usize = @intFromFloat(@min(1024.0, @max(1.0, steps_f)));

    const curve: g.Cubic = .{ .p0 = p0, .p1 = p1, .p2 = p2, .p3 = p3 };
    var prev = p0;
    for (1..steps + 1) |k| {
        const next = if (k == steps) p3 else curve.at(@as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps)));
        try appendLine(allocator, edges, prev, next, max_y);
        prev = next;
    }
}
