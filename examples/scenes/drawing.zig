//! Two-stage drawing example: measured labels -> Zig constraints -> native scene.
const std = @import("std");
const core = @import("huak").core;
const g = core.geometry;
const Path = core.Path;
const hobby = core.hobby;
const solver = core.solver;
const DisplayList = core.DisplayList;
const typst = @import("libtypst");

pub const width: f64 = 560;
pub const height: f64 = 340;
const ink: DisplayList.Color = .{ .r = 0.12, .g = 0.18, .b = 0.26 };
const blue: DisplayList.Color = .{ .r = 0.13, .g = 0.42, .b = 0.70 };

pub const requests = [_]typst.LayoutRequest{
    request("#text(size: 16pt, fill: rgb(31, 46, 66))[$a = (0, 0)$]"),
    request("#text(size: 16pt, fill: rgb(31, 46, 66))[$b_x = 2 c_x$]"),
    request("#text(size: 16pt, fill: rgb(31, 46, 66))[$integral_0^1 x^2 dif x = 1/3$]"),
    request("#text(size: 22pt, fill: rgb(31, 46, 66))[huak · geometry + Typst]"),
    request("#text(size: 13pt, fill: rgb(31, 46, 66))[Hobby spline]"),
    request("#text(size: 12pt, fill: rgb(31, 46, 66))[Measured text → constraints → native paths]"),
};

fn request(comptime source: []const u8) typst.LayoutRequest {
    return .{
        .source = source,
        .syntax = .markup,
        .region = null,
    };
}

pub fn metrics(raw: typst.Metrics) DisplayList.Metrics {
    return .{ .width = raw.width, .height = raw.height, .baseline = raw.baseline };
}

/// Text widths participate in a real linear system; labels aren't positioned
/// by fixed guessed font sizes. Returns three known point values after solve.
pub fn layoutNodes(allocator: std.mem.Allocator, measured: []const typst.Metrics, delta: f64) ![3]g.Point {
    if (measured.len < 3) return error.InvalidMetrics;
    var system = solver.Solver.init(allocator, .{});
    defer system.deinit();
    const a = try system.newPoint();
    const b = try system.newPoint();
    const d = try system.newPoint();
    _ = try system.addEquation(.{ .terms = &.{.{ .variable = a.x, .coefficient = 1 }} }, .number(80));
    _ = try system.addEquation(.{ .terms = &.{.{ .variable = a.y, .coefficient = 1 }} }, .number(135));
    _ = try system.addEquation(.{ .terms = &.{ .{ .variable = b.x, .coefficient = 1 }, .{ .variable = a.x, .coefficient = -1 } } }, .number((measured[0].width + measured[1].width) / 2 + 115));
    _ = try system.addEquation(.{ .terms = &.{ .{ .variable = b.y, .coefficient = 1 }, .{ .variable = a.y, .coefficient = -1 } } }, .number(75 + delta));
    _ = try system.addEquation(.{ .terms = &.{ .{ .variable = d.x, .coefficient = 1 }, .{ .variable = b.x, .coefficient = -1 } } }, .number((measured[1].width + measured[2].width) / 2 + 100));
    _ = try system.addEquation(.{ .terms = &.{.{ .variable = d.y, .coefficient = 1 }} }, .number(125));
    var solution = try system.solve();
    defer solution.deinit();
    if (solution.status != .unique) return error.UnsolvedGeometry;
    return .{
        .{ .x = solution.values[a.x].?, .y = solution.values[a.y].? },
        .{ .x = solution.values[b.x].?, .y = solution.values[b.y].? },
        .{ .x = solution.values[d.x].?, .y = solution.values[d.y].? },
    };
}

pub const Objects = struct {
    orbit: usize,
    curve: usize,
    caption: usize,
    node_boxes: [3]usize,
    node_labels: [3]usize,
};
pub const Scene = struct {
    picture: DisplayList,
    objects: Objects,
    pub fn deinit(self: *Scene) void {
        self.picture.deinit();
        self.* = undefined;
    }
};

/// Object references are captured when commands are appended, never inferred
/// from the number or order of unrelated commands in a completed picture.
pub fn build(allocator: std.mem.Allocator, measured: []const typst.Metrics, delta: f64) !Scene {
    if (measured.len != requests.len) return error.InvalidMetrics;
    var picture = DisplayList.init(allocator);
    errdefer picture.deinit();
    var canvas = try rectangle(allocator, .{ .x = 0, .y = 0 }, width, height);
    defer canvas.deinit();
    try picture.fill(canvas, .{ .r = 0.98, .g = 0.985, .b = 1 }, .{});
    try picture.labelAtBaseline(3, metrics(measured[3]), .{ .x = 32, .y = 294 }, .{});
    try picture.labelAtBaseline(5, metrics(measured[5]), .{ .x = 32, .y = 267 }, .{});
    const nodes = try layoutNodes(allocator, measured, delta);
    const knots = [_]hobby.Knot{
        .{ .point = nodes[0], .outgoing_direction = .{ .x = 1, .y = 0.45 } },
        .{ .point = nodes[1] },
        .{ .point = nodes[2], .incoming_direction = .{ .x = 1, .y = -0.15 } },
    };
    const curves = try hobby.interpolate(allocator, &knots, .{});
    defer allocator.free(curves);
    var curve = try Path.fromCubics(allocator, curves, false);
    defer curve.deinit();

    var clip = try rectangle(allocator, .{ .x = 24, .y = 65 }, 512, 170);
    defer clip.deinit();
    try picture.beginScope(.{}, clip);
    const orbit_knots = [_]hobby.Knot{
        .{ .point = .{ .x = 70, .y = 150 } },  .{ .point = .{ .x = 255, .y = 235 } },
        .{ .point = .{ .x = 465, .y = 155 } }, .{ .point = .{ .x = 260, .y = 70 } },
    };
    const orbit_curves = try hobby.interpolate(allocator, &orbit_knots, .{ .closed = true });
    defer allocator.free(orbit_curves);
    var orbit = try Path.fromCubics(allocator, orbit_curves, true);
    defer orbit.deinit();
    const orbit_ref = picture.commands.items.len;
    try picture.filldraw(orbit, .{ .r = 0.55, .g = 0.72, .b = 0.95, .a = 0.18 }, .{ .color = .{ .r = 0.55, .g = 0.72, .b = 0.95, .a = 0.4 }, .width = 1 }, .{});
    const curve_ref = picture.commands.items.len;
    try picture.draw(curve, .{ .color = blue, .width = 2.5, .cap = .round, .join = .round }, .{});
    try picture.endScope();
    const caption_ref = picture.commands.items.len;
    try picture.labelAlong(4, metrics(measured[4]), curves[0].at(0.38), curves[0].derivative(0.38), 11);

    var box_refs: [3]usize = undefined;
    var label_refs: [3]usize = undefined;
    for (nodes, 0..) |node, index| {
        const m = measured[index];
        var box = try rectangle(allocator, .{ .x = node.x - m.width / 2 - 9, .y = node.y - (m.height - m.baseline) - 8 }, m.width + 18, m.height + 16);
        defer box.deinit();
        box_refs[index] = picture.commands.items.len;
        try picture.filldraw(box, .{ .r = 1, .g = 1, .b = 1, .a = 0.96 }, .{ .color = ink, .width = 0.8 }, .{});
        label_refs[index] = picture.commands.items.len;
        try picture.labelAtBaseline(@intCast(index), metrics(m), .{ .x = node.x - m.width / 2, .y = node.y }, .{});
    }
    return .{ .picture = picture, .objects = .{ .orbit = orbit_ref, .curve = curve_ref, .caption = caption_ref, .node_boxes = box_refs, .node_labels = label_refs } };
}

pub fn rectangle(allocator: std.mem.Allocator, origin: g.Point, w: f64, h: f64) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(origin);
    try result.lineTo(origin.add(.{ .x = w, .y = 0 }));
    try result.lineTo(origin.add(.{ .x = w, .y = h }));
    try result.lineTo(origin.add(.{ .x = 0, .y = h }));
    try result.close();
    return result;
}
