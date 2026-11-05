//! Bounded independent coverage samples and control-point fidelity metrics.
const std = @import("std");
const core = @import("drawing");
const Point = core.geometry.Point;
const Element = @import("elements.zig").Element;
const Inputs = @import("cases.zig").Inputs;
const Case = @import("cases.zig").Case;
const Operation = @import("cases.zig").Operation;
pub fn coordinateCount(verb: u32) usize {
    return switch (verb) {
        0, 1 => 2,
        2, 3 => 4,
        4 => 6,
        else => 0,
    };
}
pub const Normalization = struct {
    origin: Point = .zero,
    scale: f64 = 1,
    pub fn point(self: Normalization, p: Point) Point {
        return .{ .x = (p.x - self.origin.x) / self.scale, .y = (p.y - self.origin.y) / self.scale };
    }
    pub fn restore(self: Normalization, p: Point) Point {
        return .{ .x = p.x * self.scale + self.origin.x, .y = p.y * self.scale + self.origin.y };
    }
};
pub fn normalization(a: []const Element, b: []const Element) Normalization {
    var minimum: Point = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) };
    var maximum: Point = .{ .x = -std.math.inf(f64), .y = -std.math.inf(f64) };
    for ([_][]const Element{ a, b }) |items| for (items) |element| {
        var index: usize = 0;
        while (index < coordinateCount(element.verb)) : (index += 2) {
            minimum.x = @min(minimum.x, element.data[index]);
            minimum.y = @min(minimum.y, element.data[index + 1]);
            maximum.x = @max(maximum.x, element.data[index]);
            maximum.y = @max(maximum.y, element.data[index + 1]);
        }
    };
    if (!minimum.isFinite()) return .{};
    const extent = maximum.sub(minimum);
    const scale = @max(extent.x, extent.y);
    return .{ .origin = minimum.add(extent.scale(0.5)), .scale = if (scale > 0) scale else 1 };
}
pub fn mapElements(result: []Element, n: Normalization) void {
    for (result) |*element| {
        var index: usize = 0;
        while (index < coordinateCount(element.verb)) : (index += 2) {
            const point = n.point(.{ .x = element.data[index], .y = element.data[index + 1] });
            element.data[index] = point.x;
            element.data[index + 1] = point.y;
        }
    }
}

const Edge = struct { a: Point, b: Point };
fn edges(allocator: std.mem.Allocator, items: []const Element, n: Normalization) ![]Edge {
    var output: std.ArrayList(Edge) = .empty;
    errdefer output.deinit(allocator);
    var current: Point = .zero;
    var first: Point = .zero;
    for (items) |element| {
        if (element.verb == 0) {
            current = n.point(.{ .x = element.data[0], .y = element.data[1] });
            first = current;
            continue;
        }
        if (element.verb == 5) {
            if (current.x != first.x or current.y != first.y) try output.append(allocator, .{ .a = current, .b = first });
            current = first;
            continue;
        }
        const count = coordinateCount(element.verb);
        if (count == 0) return error.InvalidVerb;
        const end = n.point(.{ .x = element.data[count - 2], .y = element.data[count - 1] });
        if (element.verb == 1) {
            try output.append(allocator, .{ .a = current, .b = end });
            current = end;
            continue;
        }
        const start = current;
        const control = n.point(.{ .x = element.data[0], .y = element.data[1] });
        const second = n.point(.{ .x = element.data[2], .y = element.data[3] });
        for (1..65) |index| {
            const t = @as(f64, @floatFromInt(index)) / 64;
            const s = 1 - t;
            const next: Point = switch (element.verb) {
                2 => start.scale(s * s).add(control.scale(2 * s * t)).add(end.scale(t * t)),
                3 => start.scale(s * s).add(control.scale(2 * element.data[4] * s * t)).add(end.scale(t * t)).scale(1 / (s * s + 2 * element.data[4] * s * t + t * t)),
                4 => start.scale(s * s * s).add(control.scale(3 * s * s * t)).add(second.scale(3 * s * t * t)).add(end.scale(t * t * t)),
                else => return error.InvalidVerb,
            };
            try output.append(allocator, .{ .a = current, .b = next });
            current = next;
        }
    }
    return output.toOwnedSlice(allocator);
}
const Coverage = struct { inside: bool, near: bool };
fn covered(lines: []const Edge, p: Point, fill: u32, margin: f64) Coverage {
    var winding: i32 = 0;
    var near = false;
    for (lines) |edge| {
        const d = edge.b.sub(edge.a);
        const relative = p.sub(edge.a);
        const cross = d.cross(relative);
        if (edge.a.y <= p.y and edge.b.y > p.y and cross > 0) winding += 1;
        if (edge.a.y > p.y and edge.b.y <= p.y and cross < 0) winding -= 1;
        if (margin > 0) {
            const length = d.dot(d);
            const t = if (length > 0) std.math.clamp(relative.dot(d) / length, 0, 1) else 0;
            if (p.sub(edge.a.add(d.scale(t))).dot(p.sub(edge.a.add(d.scale(t)))) < margin * margin) near = true;
        }
    }
    const inside = if (fill % 2 == 0) winding != 0 else @mod(winding, 2) != 0;
    return .{ .inside = if (fill >= 2) !inside else inside, .near = near };
}
fn truth(a: bool, b: bool, op: Operation) bool {
    return switch (op) {
        .difference => a and !b,
        .intersection => a and b,
        .unite => a or b,
        .xor => a != b,
    };
}
pub const Verification = struct { grid_checked: usize = 0, grid_mismatch: usize = 0, special_checked: usize = 0, special_mismatch: usize = 0 };
pub fn verify(allocator: std.mem.Allocator, data: Inputs, case: Case, actual: []const Element, fill: u32) !Verification {
    return verifyImpl(allocator, data, case, actual, fill, false);
}
/// Reuse the same source coverage and special locations for another Boolean
/// operation. Original-case probes retain their independent known answers;
/// alternate operations derive expectations from the original input curves.
pub fn verifyOperation(allocator: std.mem.Allocator, data: Inputs, original: Case, actual: []const Element, fill: u32, operation: Operation) !Verification {
    var case = original;
    case.operation = operation;
    return verifyImpl(allocator, data, case, actual, fill, operation != original.operation);
}
fn verifyImpl(allocator: std.mem.Allocator, data: Inputs, case: Case, actual: []const Element, fill: u32, reference_probes: bool) !Verification {
    const n = normalization(data.ae, data.be);
    const ae = try edges(allocator, data.ae, n);
    defer allocator.free(ae);
    const be = try edges(allocator, data.be, n);
    defer allocator.free(be);
    const output = try edges(allocator, actual, n);
    defer allocator.free(output);
    var report: Verification = .{};
    // Sampling is a bounded geometric check, not a proof. A conservative guard
    // excludes points near the reference's sampled cubic boundary; tiny local
    // features additionally have explicit known-result probes below.
    const box = if (data.a.bounds()) |one| if (data.b.bounds()) |two| one.unite(two) else one else data.b.bounds().?;
    const minimum = n.point(box.min);
    const maximum = n.point(box.max);
    const extent = maximum.sub(minimum);
    const margin = @max(case.tolerance / n.scale * 2, @min(extent.x, extent.y) * 0.0001);
    for (0..29) |y| for (0..31) |x| {
        const point: Point = .{ .x = minimum.x + extent.x * (-0.05 + 1.1 * (@as(f64, @floatFromInt(x)) + 0.371) / 31), .y = minimum.y + extent.y * (-0.05 + 1.1 * (@as(f64, @floatFromInt(y)) + 0.613) / 29) };
        const a = covered(ae, point, case.fill, margin);
        const b = covered(be, point, case.fill, margin);
        if (a.near or b.near) continue;
        report.grid_checked += 1;
        if (truth(a.inside, b.inside, case.operation) != covered(output, point, fill, 0).inside) report.grid_mismatch += 1;
    };
    for (data.probes) |probe| {
        report.special_checked += 1;
        const point = n.point(probe.point);
        const expected = if (reference_probes)
            truth(covered(ae, point, case.fill, 0).inside, covered(be, point, case.fill, 0).inside, case.operation)
        else
            probe.expected;
        if (covered(output, point, fill, 0).inside != expected) report.special_mismatch += 1;
    }
    return report;
}
pub const Counts = struct { elements: usize = 0, moves: usize = 0, lines: usize = 0, quads: usize = 0, conics: usize = 0, cubics: usize = 0, closes: usize = 0 };
pub fn counts(items: []const Element) Counts {
    var result: Counts = .{ .elements = items.len };
    for (items) |e| switch (e.verb) {
        0 => result.moves += 1,
        1 => result.lines += 1,
        2 => result.quads += 1,
        3 => result.conics += 1,
        4 => result.cubics += 1,
        5 => result.closes += 1,
        else => {},
    };
    return result;
}
fn cubicControls(allocator: std.mem.Allocator, items: []const Element) ![][4]Point {
    var output: std.ArrayList([4]Point) = .empty;
    errdefer output.deinit(allocator);
    var current: Point = .zero;
    var first: Point = .zero;
    for (items) |e| switch (e.verb) {
        0 => {
            current = .{ .x = e.data[0], .y = e.data[1] };
            first = current;
        },
        1 => current = .{ .x = e.data[0], .y = e.data[1] },
        2, 3 => current = .{ .x = e.data[2], .y = e.data[3] },
        4 => {
            const end: Point = .{ .x = e.data[4], .y = e.data[5] };
            try output.append(allocator, .{ current, .{ .x = e.data[0], .y = e.data[1] }, .{ .x = e.data[2], .y = e.data[3] }, end });
            current = end;
        },
        5 => current = first,
        else => {},
    };
    return output.toOwnedSlice(allocator);
}
pub fn preservation(allocator: std.mem.Allocator, source: []const Element, actual: []const Element) !f64 {
    const original = try cubicControls(allocator, source);
    defer allocator.free(original);
    const output = try cubicControls(allocator, actual);
    defer allocator.free(output);
    if (output.len < original.len) return std.math.inf(f64);
    var worst: f64 = 0;
    for (original) |curve| {
        var best: f64 = std.math.inf(f64);
        for (output) |candidate| {
            var direct: f64 = 0;
            var reverse: f64 = 0;
            for (0..4) |i| {
                direct = @max(direct, @max(@abs(curve[i].x - candidate[i].x), @abs(curve[i].y - candidate[i].y)));
                reverse = @max(reverse, @max(@abs(curve[i].x - candidate[3 - i].x), @abs(curve[i].y - candidate[3 - i].y)));
            }
            best = @min(best, @min(direct, reverse));
        }
        worst = @max(worst, best);
    }
    return worst;
}
