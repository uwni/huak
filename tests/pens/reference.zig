//! The retained MetaPost cubic-control oracle (envelope-reference.csv): reference cases, their centerlines and the expected paths. MetaPost is used only to refresh the CSV.
const std = @import("std");
const t = std.testing;
const core = @import("huak").core;
const g = core.geometry;
const Path = core.Path;
const pens = core.pen;
const Point = g.Point;
const Cubic = g.Cubic;
const harness = @import("harness.zig");

const reference = @embedFile("../fixtures/envelope-reference.csv");

const Shape = enum { monotone, inflection, cusp, near_cusp, semicusp, semicusp_tiny, semicusp_near, corner, acute, reversal, closed_cubic, closed_reflex, zero, singleton };

const Nib = enum { rectangle, sheared, triangle };

pub const rectangle = [_]Point{ .{ .x = -2, .y = -1 }, .{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, .{ .x = -2, .y = 1 } };

const sheared = [_]Point{ .{ .x = 0.5, .y = -3 }, .{ .x = 4.5, .y = -3 }, .{ .x = 5.5, .y = -1 }, .{ .x = 1.5, .y = -1 } };

const triangle = [_]Point{ .{ .x = -2, .y = -1 }, .{ .x = 3, .y = 0 }, .{ .x = -1, .y = 4 } };

pub const Case = struct {
    name: []const u8,
    shape: Shape,
    nib: Nib = .rectangle,
    reverse: bool = false,
    cap: pens.Cap = .round,
    join: pens.Join = .round,
    miter_limit: f64 = 4,

    pub fn vertices(self: Case) []const Point {
        return switch (self.nib) {
            .rectangle => &rectangle,
            .sheared => &sheared,
            .triangle => &triangle,
        };
    }
    pub fn options(self: Case) pens.StrokeOptions {
        return .{ .tolerance = 1e-4, .cap = self.cap, .join = self.join, .miter_limit = self.miter_limit };
    }
};

pub const cases = [_]Case{
    .{ .name = "cubic-monotone", .shape = .monotone },
    .{ .name = "cubic-inflection", .shape = .inflection },
    .{ .name = "cubic-inflection-reversed", .shape = .inflection, .reverse = true },
    .{ .name = "cubic-sheared-offset", .shape = .inflection, .nib = .sheared },
    .{ .name = "cubic-triangle", .shape = .inflection, .nib = .triangle },
    .{ .name = "cubic-cusp", .shape = .cusp },
    .{ .name = "cubic-cusp-reversed", .shape = .cusp, .reverse = true },
    .{ .name = "cubic-near-cusp", .shape = .near_cusp },
    .{ .name = "cubic-near-cusp-reversed", .shape = .near_cusp, .reverse = true },
    .{ .name = "semicusp", .shape = .semicusp },
    .{ .name = "semicusp-reversed", .shape = .semicusp, .reverse = true },
    .{ .name = "semicusp-sheared", .shape = .semicusp, .nib = .sheared },
    .{ .name = "semicusp-sheared-reversed", .shape = .semicusp, .nib = .sheared, .reverse = true },
    .{ .name = "semicusp-tiny", .shape = .semicusp_tiny },
    .{ .name = "semicusp-tiny-reversed", .shape = .semicusp_tiny, .reverse = true },
    .{ .name = "semicusp-tiny-sheared", .shape = .semicusp_tiny, .nib = .sheared },
    .{ .name = "semicusp-tiny-sheared-reversed", .shape = .semicusp_tiny, .nib = .sheared, .reverse = true },
    .{ .name = "semicusp-near", .shape = .semicusp_near },
    .{ .name = "semicusp-near-reversed", .shape = .semicusp_near, .reverse = true },
    .{ .name = "semicusp-near-sheared", .shape = .semicusp_near, .nib = .sheared },
    .{ .name = "semicusp-near-sheared-reversed", .shape = .semicusp_near, .nib = .sheared, .reverse = true },
    .{ .name = "corner-butt-bevel", .shape = .corner, .cap = .butt, .join = .bevel },
    .{ .name = "corner-square-bevel", .shape = .corner, .cap = .square, .join = .bevel },
    .{ .name = "corner-round-bevel", .shape = .corner, .join = .bevel },
    .{ .name = "corner-butt-miter", .shape = .corner, .cap = .butt, .join = .miter },
    .{ .name = "corner-square-miter", .shape = .corner, .cap = .square, .join = .miter },
    .{ .name = "corner-round-miter", .shape = .corner, .join = .miter },
    .{ .name = "corner-butt-round", .shape = .corner, .cap = .butt },
    .{ .name = "corner-square-round", .shape = .corner, .cap = .square },
    .{ .name = "corner-round-round", .shape = .corner },
    .{ .name = "acute-miter", .shape = .acute, .cap = .butt, .join = .miter },
    .{ .name = "acute-miter-limited", .shape = .acute, .cap = .butt, .join = .miter, .miter_limit = 1 },
    .{ .name = "reversal-round", .shape = .reversal },
    .{ .name = "closed-cubic", .shape = .closed_cubic, .cap = .butt },
    .{ .name = "closed-cubic-reversed", .shape = .closed_cubic, .reverse = true, .cap = .butt },
    .{ .name = "closed-reflex-bevel", .shape = .closed_reflex, .cap = .butt, .join = .bevel },
    .{ .name = "closed-reflex-miter", .shape = .closed_reflex, .cap = .butt, .join = .miter },
    .{ .name = "closed-reflex-round", .shape = .closed_reflex, .cap = .butt },
    .{ .name = "closed-reflex-limited", .shape = .closed_reflex, .cap = .butt, .join = .miter, .miter_limit = 1 },
    .{ .name = "zero-butt", .shape = .zero, .cap = .butt },
    .{ .name = "zero-square", .shape = .zero, .cap = .square },
    .{ .name = "zero-round", .shape = .zero },
    .{ .name = "singleton-butt", .shape = .singleton, .cap = .butt },
    .{ .name = "singleton-square", .shape = .singleton, .cap = .square },
    .{ .name = "singleton-round", .shape = .singleton },
};

pub const Row = struct { name: []const u8, contour: usize, segment: usize, curve: Cubic };

pub fn readReference(a: std.mem.Allocator) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(a);
    var lines = std.mem.tokenizeScalar(u8, reference, '\n');
    try t.expectEqualStrings("case,contour,segment,p0x,p0y,p1x,p1y,p2x,p2y,p3x,p3y", lines.next().?);
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ',');
        const name = fields.next() orelse return error.InvalidFixture;
        const contour = try std.fmt.parseInt(usize, fields.next().?, 10);
        const segment = try std.fmt.parseInt(usize, fields.next().?, 10);
        var coordinates: [8]f64 = undefined;
        for (&coordinates) |*coordinate| coordinate.* = try std.fmt.parseFloat(f64, fields.next() orelse return error.InvalidFixture);
        try t.expect(fields.next() == null);
        try rows.append(a, .{ .name = name, .contour = contour, .segment = segment, .curve = .{
            .p0 = .{ .x = coordinates[0], .y = coordinates[1] },
            .p1 = .{ .x = coordinates[2], .y = coordinates[3] },
            .p2 = .{ .x = coordinates[4], .y = coordinates[5] },
            .p3 = .{ .x = coordinates[6], .y = coordinates[7] },
        } });
    }
    return rows.toOwnedSlice(a);
}

pub fn centerline(a: std.mem.Allocator, case: Case) !Path {
    var path: Path = .init(a);
    errdefer path.deinit();
    const origin: Point = .zero;
    const zero = case.shape == .zero or case.shape == .singleton;
    const cusp = case.shape == .semicusp or case.shape == .semicusp_tiny or case.shape == .semicusp_near;
    try path.moveTo(if (zero) .{ .x = 5, .y = 7 } else if (cusp) .{ .x = 10, .y = -10 } else if (case.shape == .closed_cubic) .{ .x = 20, .y = 0 } else origin);
    switch (case.shape) {
        .monotone => try path.cubicTo(.{ .x = 20, .y = 10 }, .{ .x = 30, .y = 35 }, .{ .x = 60, .y = 40 }),
        .inflection => try path.cubicTo(.{ .x = 15, .y = 35 }, .{ .x = 45, .y = -35 }, .{ .x = 60, .y = 0 }),
        .cusp, .near_cusp => try path.cubicTo(.{ .x = 10, .y = 0 }, .{ .x = -10, .y = if (case.shape == .near_cusp) 0.0001 else 0 }, origin),
        .semicusp, .semicusp_tiny, .semicusp_near => {
            const perturbation: f64 = if (case.shape == .semicusp_tiny) 1e-12 else if (case.shape == .semicusp_near) 1e-6 else 0;
            try path.cubicTo(.{ .x = -10.0 / 3.0, .y = 10 + perturbation }, .{ .x = -10.0 / 3.0, .y = -10 }, .{ .x = 10, .y = 10 });
        },
        .corner, .acute, .reversal => {
            try path.lineTo(.{ .x = 20, .y = 0 });
            try path.lineTo(switch (case.shape) {
                .corner => .{ .x = 20, .y = 20 },
                .acute => .{ .x = 5, .y = 5 },
                else => origin,
            });
        },
        .closed_cubic => {
            try path.cubicTo(.{ .x = 20, .y = 11 }, .{ .x = 11, .y = 20 }, .{ .x = 0, .y = 20 });
            try path.cubicTo(.{ .x = -11, .y = 20 }, .{ .x = -20, .y = 11 }, .{ .x = -20, .y = 0 });
            try path.cubicTo(.{ .x = -20, .y = -11 }, .{ .x = -11, .y = -20 }, .{ .x = 0, .y = -20 });
            try path.cubicTo(.{ .x = 11, .y = -20 }, .{ .x = 20, .y = -11 }, .{ .x = 20, .y = 0 });
            try path.close();
        },
        .closed_reflex => {
            for ([_]Point{ .{ .x = 30, .y = 0 }, .{ .x = 15, .y = 10 }, .{ .x = 30, .y = 25 }, .{ .x = 0, .y = 25 } }) |point| try path.lineTo(point);
            try path.close();
        },
        .zero => try path.lineTo(.{ .x = 5, .y = 7 }),
        .singleton => {},
    }
    if (!case.reverse) return path;
    const result = try path.reverse(a);
    path.deinit();
    return result;
}

pub fn expectedPath(a: std.mem.Allocator, rows: []const Row, name: []const u8) !Path {
    var path: Path = .init(a);
    errdefer path.deinit();
    var contour: ?usize = null;
    var segment: usize = 0;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.name, name)) continue;
        if (contour == null or contour.? != row.contour) {
            if (contour != null) try path.close();
            try t.expectEqual(if (contour) |previous| previous + 1 else 0, row.contour);
            contour = row.contour;
            segment = 0;
            try path.moveTo(row.curve.p0);
        }
        try t.expectEqual(segment, row.segment);
        try t.expect(path.current.?.distance(row.curve.p0) <= harness.control_tolerance);
        try path.cubicTo(row.curve.p1, row.curve.p2, row.curve.p3);
        segment += 1;
    }
    try t.expect(contour != null);
    try path.close();
    return path;
}
