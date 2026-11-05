//! Arc-length/normal coordinates, shared by all shapes and arrow styles.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Measure = @import("../path/Measure.zig");
const mapping = @import("map.zig");
const DisplayList = @import("../DisplayList.zig");

const Bend = @This();

measure: Measure,
offset: f64,
tolerance: f64,
affine: ?g.Transform,

pub fn init(allocator: std.mem.Allocator, guide: Path, offset: f64, tolerance: f64) !Bend {
    if (!std.math.isFinite(offset)) return error.NonFinite;
    if (!std.math.isFinite(tolerance) or tolerance <= 0) return error.InvalidTolerance;
    var measure = try Measure.init(allocator, guide, .{ .tolerance = tolerance * 0.125 });
    errdefer measure.deinit();
    if (measure.contours.len != 1 or measure.length == 0) return error.InvalidBendGuide;
    const start = try measure.sample(0);
    const end = try measure.sample(measure.length);
    const axis = end.point.sub(start.point);
    const affine = linear: {
        if (axis.x == 0 and axis.y == 0) break :linear null;
        for (measure.curves) |curve| {
            const points = [_]g.Point{ curve.p0, curve.p1, curve.p2, curve.p3 };
            for (points[0..3], points[1..]) |a, b| {
                const delta = b.sub(a);
                if (delta.cross(axis) != 0 or delta.dot(axis) < 0) break :linear null;
            }
        }
        const unit = try axis.normalized();
        const origin = start.point.add(unit.scale(offset));
        break :linear g.Transform{ .a = unit.x, .b = unit.y, .c = -unit.y, .d = unit.x, .e = origin.x, .f = origin.y };
    };
    return .{ .measure = measure, .offset = offset, .tolerance = tolerance, .affine = affine };
}

pub fn deinit(self: *Bend) void {
    self.measure.deinit();
    self.* = undefined;
}

/// Beyond either end, continue on the endpoint tangent instead of
/// collapsing the source. Local x is physical distance, y is normal offset.
pub fn point(self: *const Bend, p: g.Point) !g.Point {
    if (!p.isFinite()) return error.NonFinite;
    if (self.affine) |transform| return transform.apply(p);
    const distance = self.offset + p.x;
    if (!std.math.isFinite(distance)) return error.NonFinite;
    const inside = std.math.clamp(distance, 0, self.measure.length);
    const sample = try self.measure.sample(inside);
    const tangent = sample.tangent;
    if (tangent.x == 0 and tangent.y == 0) return error.InvalidBendGuide;
    return sample.point.add(tangent.scale(distance - inside)).add((g.Point{ .x = -tangent.y, .y = tangent.x }).scale(p.y));
}

pub fn path(self: *const Bend, allocator: std.mem.Allocator, source: Path) !Path {
    // A straight monotone guide is an affine map: reuse exact control
    // point transformation rather than subdividing unchanged geometry.
    if (self.affine) |transform| return source.transformed(allocator, transform);
    return mapping.mapped(allocator, source, self, .{ .tolerance = self.tolerance * 0.5 });
}

pub fn picture(self: *const Bend, allocator: std.mem.Allocator, source: *const DisplayList) !DisplayList {
    if (self.affine) |transform| {
        var result = DisplayList.init(allocator);
        errdefer result.deinit();
        try result.append(source, transform);
        return result;
    }
    return mapping.picture(allocator, source, self, .{ .tolerance = self.tolerance * 0.5 });
}

fn parabola(allocator: std.mem.Allocator) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.zero);
    try result.cubicTo(.{ .x = 20.0 / 3.0, .y = 0 }, .{ .x = 40.0 / 3.0, .y = 20.0 / 3.0 }, .{ .x = 20, .y = 20 });
    return result;
}

test "bending follows an independent analytic parabola normal and arc length" {
    const t = std.testing;
    var guide = try parabola(t.allocator);
    defer guide.deinit();
    var bend = try Bend.init(t.allocator, guide, 0, 1e-4);
    defer bend.deinit();
    for ([_]f64{ 0, 0.2, 0.5, 0.8, 1 }) |u| {
        const norm = @sqrt(1 + 4 * u * u);
        const distance = 10 * u * norm + 5 * std.math.asinh(2 * u);
        for ([_]f64{ -2, 0, 3 }) |y| {
            const p = try bend.point(.{ .x = distance, .y = y });
            try t.expectApproxEqAbs(20 * u - 2 * u * y / norm, p.x, 1e-4);
            try t.expectApproxEqAbs(20 * u * u + y / norm, p.y, 1e-4);
        }
    }
    var source = Path.init(t.allocator);
    defer source.deinit();
    try source.moveTo(.{ .x = 0, .y = 2 });
    try source.lineTo(.{ .x = bend.measure.length, .y = 2 });
    var result = try bend.path(t.allocator, source);
    defer result.deinit();
    for (0..result.segmentCount()) |i| {
        const curve = (try result.curveAt(@floatFromInt(i))).curve;
        for ([_]f64{ 0.13, 0.37, 0.61, 0.91 }) |fraction| {
            const p = curve.at(fraction);
            var lo: f64 = 0;
            var hi: f64 = 1;
            for (0..50) |_| {
                const u = (lo + hi) / 2;
                if (20 * u - 4 * u / @sqrt(1 + 4 * u * u) < p.x) lo = u else hi = u;
            }
            const u = (lo + hi) / 2;
            try t.expectApproxEqAbs(20 * u * u + 2 / @sqrt(1 + 4 * u * u), p.y, 2e-4);
        }
    }
}

test "straight guides retain Bezier segments and extend past both endpoints" {
    const t = std.testing;
    var guide = Path.init(t.allocator);
    defer guide.deinit();
    try guide.moveTo(.{ .x = 5, .y = 7 });
    try guide.lineTo(.{ .x = 5, .y = 27 });
    var bend = try Bend.init(t.allocator, guide, 10, 1e-3);
    defer bend.deinit();
    var source = try parabola(t.allocator);
    defer source.deinit();
    var result = try bend.path(t.allocator, source);
    defer result.deinit();
    var expected = try source.transformed(t.allocator, .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = 5, .f = 17 });
    defer expected.deinit();
    try t.expectEqualDeep(expected.segments.items, result.segments.items);
    try t.expectEqual(g.Point{ .x = 2, .y = -3 }, try bend.point(.{ .x = -20, .y = 3 }));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var guide = try parabola(allocator);
    defer guide.deinit();
    var bend = try Bend.init(allocator, guide, 0, 0.01);
    defer bend.deinit();
    var source = Path.init(allocator);
    defer source.deinit();
    try source.moveTo(.zero);
    try source.lineTo(.{ .x = 4, .y = 1 });
    var result = try bend.path(allocator, source);
    defer result.deinit();
    try source.lineTo(.{ .x = 0, .y = 2 });
    try source.close();
    var drawing = DisplayList.init(allocator);
    defer drawing.deinit();
    try drawing.beginScope(.{}, source);
    try drawing.filldraw(source, .{ .r = 1, .a = 0.5 }, .{ .width = 0.5 }, .{});
    try drawing.endScope();
    var warped = try bend.picture(allocator, &drawing);
    defer warped.deinit();
}

test "bending releases workspaces on every allocation failure" {
    // Force growth through allocation, as in coverage's allocation tests:
    // OS-dependent remap success must not change the injected failure count.
    var moving = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(moving.allocator(), allocationCase, .{});
}

test "bending rejects unusable guides and does not silently outline labels" {
    const t = std.testing;
    var guide = Path.init(t.allocator);
    defer guide.deinit();
    try t.expectError(error.InvalidBendGuide, Bend.init(t.allocator, guide, 0, 0.001));
    try guide.moveTo(.zero);
    try guide.lineTo(.{ .x = 2, .y = 0 });
    try guide.moveTo(.zero);
    try guide.lineTo(.{ .x = 0, .y = 2 });
    try t.expectError(error.InvalidBendGuide, Bend.init(t.allocator, guide, 0, 0.001));
    var curve = try parabola(t.allocator);
    defer curve.deinit();
    var bend = try Bend.init(t.allocator, curve, 0, 0.001);
    defer bend.deinit();
    var source = DisplayList.init(t.allocator);
    defer source.deinit();
    try source.labelAtBaseline(0, .{ .width = 3, .height = 3, .baseline = 2 }, .zero, .{});
    try t.expectError(error.LabelResolverRequired, bend.picture(t.allocator, &source));
    try t.expect(source.commands.items[0] == .label);
}
