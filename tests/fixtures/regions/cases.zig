//! Deterministic shared inputs; independent filled objects and raw compounds differ.
const std = @import("std");
const core = @import("drawing");
const Path = core.Path;
const Point = core.geometry.Point;
const Element = @import("elements.zig").Element;
pub const Operation = enum(u32) { difference, intersection, unite, xor };
pub const Shape = enum { unchanged, lens, half_circle, holes, opposite_raw, opposite_canonical, evenodd, crossing, large_origin, huge_origin, dynamic_range, dynamic_moderate, dynamic_small, tiny, near_coincident, tangent, shared_edge, collinear_zero, coincident, coincident_reversed };
pub const Case = struct { name: []const u8, shape: Shape, operation: Operation = .difference, fill: u32 = 0, tolerance: f64 = 0.001, repeats: usize = 200, expanded_budget: bool = false };
pub const cases = [_]Case{
    .{ .name = "cubic_unchanged", .shape = .unchanged },
    .{ .name = "cubic_lens", .shape = .lens, .operation = .intersection },
    .{ .name = "cubic_half", .shape = .half_circle },
    .{ .name = "256_curved_holes", .shape = .holes, .repeats = 20 },
    .{ .name = "256_holes_expanded_budget", .shape = .holes, .repeats = 3, .expanded_budget = true },
    .{ .name = "opposite_raw_nonzero", .shape = .opposite_raw },
    .{ .name = "independent_canonical", .shape = .opposite_canonical },
    .{ .name = "evenodd_ring", .shape = .evenodd, .operation = .unite, .fill = 1 },
    .{ .name = "self_intersection_clip", .shape = .crossing },
    .{ .name = "large_origin_1e12", .shape = .large_origin },
    .{ .name = "huge_origin_1e16", .shape = .huge_origin, .tolerance = 16, .repeats = 50 },
    .{ .name = "span_1e8_hole_1e-3", .shape = .dynamic_range, .tolerance = 0.00001 },
    .{ .name = "span_1e6_hole_1e-3", .shape = .dynamic_moderate, .tolerance = 0.0001 },
    .{ .name = "span_1e5_hole_1e-3", .shape = .dynamic_small, .tolerance = 0.00001 },
    .{ .name = "tiny_coordinates_1e-24", .shape = .tiny, .tolerance = 1e-29 },
    .{ .name = "near_coincident_1e-4", .shape = .near_coincident, .tolerance = 0.00001 },
    .{ .name = "tangent_circles", .shape = .tangent, .operation = .unite },
    .{ .name = "shared_edge_rectangles", .shape = .shared_edge, .operation = .unite },
    .{ .name = "collinear_zero_repeated", .shape = .collinear_zero },
    .{ .name = "coincident_same_difference", .shape = .coincident, .fill = 1 },
    .{ .name = "coincident_reversed_difference", .shape = .coincident_reversed, .fill = 1 },
};
pub const Probe = struct { point: Point, expected: bool };
pub const Inputs = struct {
    a: Path,
    b: Path,
    ae: []Element,
    be: []Element,
    probes: []Probe,
    pub fn deinit(self: *Inputs, allocator: std.mem.Allocator) void {
        self.a.deinit();
        self.b.deinit();
        allocator.free(self.ae);
        allocator.free(self.be);
        allocator.free(self.probes);
    }
};
fn rectangle(allocator: std.mem.Allocator, x: f64, y: f64, w: f64, h: f64) !Path {
    var path = Path.init(allocator);
    errdefer path.deinit();
    try path.moveTo(.{ .x = x, .y = y });
    try path.lineTo(.{ .x = x + w, .y = y });
    try path.lineTo(.{ .x = x + w, .y = y + h });
    try path.lineTo(.{ .x = x, .y = y + h });
    try path.close();
    return path;
}
fn appendOwned(destination: *Path, source: Path) !void {
    var owned = source;
    defer owned.deinit();
    try destination.append(owned);
}
pub fn elements(allocator: std.mem.Allocator, path: Path) ![]Element {
    const output = try allocator.alloc(Element, path.segments.items.len);
    for (output, path.segments.items) |*out, segment| out.* = switch (segment) {
        .move => |p| .{ .verb = 0, .data = .{ p.x, p.y, 0, 0, 0, 0 } },
        .line => |p| .{ .verb = 1, .data = .{ p.x, p.y, 0, 0, 0, 0 } },
        .cubic => |c| .{ .verb = 4, .data = .{ c.c1.x, c.c1.y, c.c2.x, c.c2.y, c.end.x, c.end.y } },
        .close => .{ .verb = 5 },
    };
    return output;
}
pub fn input(allocator: std.mem.Allocator, case: Case) !Inputs {
    var a = Path.init(allocator);
    errdefer a.deinit();
    var b = Path.init(allocator);
    errdefer b.deinit();
    var probes: std.ArrayList(Probe) = .empty;
    errdefer probes.deinit(allocator);
    switch (case.shape) {
        .unchanged => {
            a = try Path.circle(allocator, .{ .x = 50, .y = 50 }, 35);
            b = try rectangle(allocator, 140, 20, 20, 20);
        },
        .lens => {
            a = try Path.circle(allocator, .{ .x = 45, .y = 50 }, 35);
            b = try Path.circle(allocator, .{ .x = 75, .y = 50 }, 35);
        },
        .half_circle => {
            a = try Path.circle(allocator, .{ .x = 50, .y = 50 }, 35);
            b = try rectangle(allocator, 55, 0, 50, 100);
        },
        .holes => {
            a = try rectangle(allocator, 0, 0, 100, 100);
            for (0..16) |row| for (0..16) |column| {
                const center: Point = .{ .x = 3 + 6 * @as(f64, @floatFromInt(column)), .y = 3 + 6 * @as(f64, @floatFromInt(row)) };
                try appendOwned(&b, try Path.circle(allocator, center, 1));
                try probes.append(allocator, .{ .point = center, .expected = false });
            };
        },
        .opposite_raw, .opposite_canonical => {
            a = try rectangle(allocator, 0, 0, 100, 100);
            try appendOwned(&b, try rectangle(allocator, 20, 20, 50, 50));
            var second = try rectangle(allocator, 40, 30, 50, 50);
            defer second.deinit();
            if (case.shape == .opposite_raw) try appendOwned(&b, try second.reverse(allocator)) else try b.append(second);
            try probes.append(allocator, .{ .point = .{ .x = 50, .y = 50 }, .expected = case.shape == .opposite_raw });
        },
        .evenodd => {
            a = try Path.circle(allocator, .{ .x = 50, .y = 50 }, 35);
            try appendOwned(&a, try Path.circle(allocator, .{ .x = 50, .y = 50 }, 15));
            try probes.append(allocator, .{ .point = .{ .x = 50, .y = 50 }, .expected = false });
        },
        .crossing => {
            try a.moveTo(.{ .x = 10, .y = 10 });
            try a.lineTo(.{ .x = 90, .y = 90 });
            try a.lineTo(.{ .x = 10, .y = 90 });
            try a.lineTo(.{ .x = 90, .y = 10 });
            try a.close();
            b = try rectangle(allocator, 30, 0, 40, 100);
        },
        .large_origin => {
            a = try Path.circle(allocator, .{ .x = 1e12 + 50, .y = 1e12 + 50 }, 35);
            b = try rectangle(allocator, 1e12 + 55, 1e12, 50, 100);
            try probes.append(allocator, .{ .point = .{ .x = 1e12 + 40, .y = 1e12 + 50 }, .expected = true });
        },
        .huge_origin => {
            // f64 spacing here is 2. Use even, representable source positions
            // and a tolerance above that spacing, rather than demanding an
            // impossible 1e-3 world-coordinate result from any f64 backend.
            a = try Path.circle(allocator, .{ .x = 1e16 + 500000, .y = 1e16 + 500000 }, 350000);
            b = try rectangle(allocator, 1e16 + 550000, 1e16, 500000, 1000000);
            try probes.append(allocator, .{ .point = .{ .x = 1e16 + 400000, .y = 1e16 + 500000 }, .expected = true });
        },
        .dynamic_range, .dynamic_moderate, .dynamic_small => {
            const span: f64 = if (case.shape == .dynamic_range) 1e8 else if (case.shape == .dynamic_moderate) 1e6 else 1e5;
            a = try rectangle(allocator, 0, 0, span, 100);
            // Keep the fine feature away from the shared normalization origin;
            // centering directly on the feature would accidentally rescue it.
            b = try rectangle(allocator, span * 0.75, 20, 0.001, 20);
            try probes.append(allocator, .{ .point = .{ .x = span * 0.75 + 0.0005, .y = 30 }, .expected = false });
            try probes.append(allocator, .{ .point = .{ .x = span * 0.75 - 0.001, .y = 30 }, .expected = true });
        },
        .tiny => {
            a = try Path.circle(allocator, .{ .x = 50e-24, .y = 50e-24 }, 35e-24);
            b = try rectangle(allocator, 55e-24, 0, 50e-24, 100e-24);
            try probes.append(allocator, .{ .point = .{ .x = 40e-24, .y = 50e-24 }, .expected = true });
        },
        .near_coincident => {
            a = try Path.circle(allocator, .{ .x = 50, .y = 50 }, 30);
            b = try Path.circle(allocator, .{ .x = 50.0001, .y = 50 }, 30);
            try probes.append(allocator, .{ .point = .{ .x = 20.00005, .y = 50 }, .expected = true });
            try probes.append(allocator, .{ .point = .{ .x = 50, .y = 50 }, .expected = false });
        },
        .tangent => {
            a = try Path.circle(allocator, .{ .x = 35, .y = 50 }, 25);
            b = try Path.circle(allocator, .{ .x = 85, .y = 50 }, 25);
            try probes.append(allocator, .{ .point = .{ .x = 35, .y = 50 }, .expected = true });
            try probes.append(allocator, .{ .point = .{ .x = 85, .y = 50 }, .expected = true });
        },
        .shared_edge => {
            a = try rectangle(allocator, 0, 0, 50, 100);
            b = try rectangle(allocator, 50, 0, 50, 100);
            try probes.append(allocator, .{ .point = .{ .x = 49.99, .y = 50 }, .expected = true });
            try probes.append(allocator, .{ .point = .{ .x = 50.01, .y = 50 }, .expected = true });
        },
        .collinear_zero => {
            try a.moveTo(.{ .x = 0, .y = 0 });
            try a.lineTo(.{ .x = 100, .y = 0 });
            try a.lineTo(.{ .x = 100, .y = 0 });
            try a.lineTo(.{ .x = 100, .y = 40 });
            try a.lineTo(.{ .x = 0, .y = 40 });
            try a.lineTo(.{ .x = 0, .y = 40 });
            try a.close();
            b = try rectangle(allocator, 25, 0, 50, 40);
            try probes.append(allocator, .{ .point = .{ .x = 10, .y = 20 }, .expected = true });
            try probes.append(allocator, .{ .point = .{ .x = 50, .y = 20 }, .expected = false });
            try probes.append(allocator, .{ .point = .{ .x = 90, .y = 20 }, .expected = true });
        },
        .coincident, .coincident_reversed => {
            a = try Path.circle(allocator, .{ .x = 50, .y = 50 }, 35);
            b = if (case.shape == .coincident) try a.clone(allocator) else try a.reverse(allocator);
            try probes.append(allocator, .{ .point = .{ .x = 50, .y = 50 }, .expected = false });
        },
    }
    const ae = try elements(allocator, a);
    errdefer allocator.free(ae);
    const be = try elements(allocator, b);
    errdefer allocator.free(be);
    return .{ .a = a, .b = b, .ae = ae, .be = be, .probes = try probes.toOwnedSlice(allocator) };
}

pub fn eoEquivalent(shape: Shape) bool {
    return switch (shape) {
        .opposite_raw, .opposite_canonical, .crossing => false,
        else => true,
    };
}
