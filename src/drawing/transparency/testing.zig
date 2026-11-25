//! Fixtures shared by the transparency tests: rectangles, an exact compositing reference, patch nets and fields, and checks of a result's colors and opacity.
const std = @import("std");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const DisplayList = @import("../DisplayList.zig");
const style = @import("../style.zig");
const regions = @import("../region/root.zig");
const enclosure = @import("../enclosure.zig");
const color_patches = @import("../color_patches.zig");
const conic_mesh = @import("../conic.zig");
const Allocator = std.mem.Allocator;
const Color = style.Color;
const Gradient = style.Gradient;
const Real = enclosure.Real;
const Rgba = enclosure.Rgba;
const testing = std.testing;
const transparency = @import("../transparency.zig");
const premultiplied = transparency.premultiplied;
const over = transparency.over;
const scaled = transparency.scaled;
const mix = transparency.mix;

pub fn rectangle(allocator: Allocator, x: f64, y: f64, width: f64, height: f64) !Path {
    return Path.rectangle(allocator, .{ .x = x, .y = y }, width, height);
}

/// The color at `point` of a picture drawn on `paper`, compositing exactly
/// as the definition of the picture says: an independent reference for the
/// tests. Strokes and texts are not sampled.
const Reference = struct {
    allocator: Allocator,
    picture: *const DisplayList,
    paper: Color,

    const Premultiplied = Rgba(Real);

    fn at(self: Reference, point: g.Point) !Color {
        var index: usize = 0;
        const color = try self.content(&index, .{}, true, point, premultiplied(Real, enclosure.constants(Real, self.paper)), false);
        return .{ .r = color.r.value, .g = color.g.value, .b = color.b.value, .a = color.a.value };
    }

    fn content(self: Reference, index: *usize, transform: g.Transform, inside: bool, point: g.Point, start: Premultiplied, grouped: bool) !Premultiplied {
        var color = start;
        while (index.* < self.picture.commands.items.len) {
            const command = self.picture.commands.items[index.*];
            index.* += 1;
            switch (command) {
                .pop => {
                    if (!grouped) return error.UnbalancedGroups;
                    return color;
                },
                .push => |group| {
                    const inner = group.transform.then(transform);
                    var within = inside;
                    if (group.clip) |reference| {
                        const local = try self.picture.geometry().view(self.allocator, reference);
                        var world = try local.transformed(self.allocator, inner);
                        defer world.deinit();
                        within = within and try regions.windingAt(world, point) != 0;
                    }
                    if (group.opacity == 1) {
                        color = try self.content(index, inner, within, point, color, true);
                    } else {
                        const layer = try self.content(index, inner, within, point, enclosure.constants(Real, Color{ .a = 0 }), true);
                        color = over(Real, scaled(Real, layer, group.opacity), color);
                    }
                },
                .path => |draw| {
                    if (!inside) continue;
                    const world = draw.transform.then(transform);
                    const local = try self.picture.geometry().view(self.allocator, draw.path);
                    var path = try local.transformed(self.allocator, world);
                    defer path.deinit();
                    const winding = try regions.windingAt(path, point);
                    const covered = if (draw.style.fill_rule == .evenodd) @mod(winding, 2) != 0 else winding != 0;
                    if (!covered) continue;
                    const paint: Color = switch (draw.style.fill orelse continue) {
                        .color => |solid| solid,
                        .gradient => |gradient| gradientAt(gradient, (try world.inverse()).apply(point)) orelse continue,
                    };
                    color = over(Real, premultiplied(Real, enclosure.constants(Real, paint)), color);
                },
                .label => {},
            }
        }
        if (grouped) return error.UnbalancedGroups;
        return color;
    }
};

/// A gradient's color at `local`, in its own coordinates; null where it does
/// not paint. Patches must be bilinear, as planes and lowered fans are.
fn gradientAt(gradient: *const Gradient, local: g.Point) ?Color {
    switch (gradient.*) {
        .linear => |ramp| {
            const axis = ramp.end.sub(ramp.start);
            const t = std.math.clamp(local.sub(ramp.start).dot(axis) / axis.dot(axis), 0, 1);
            var k: usize = 1;
            const positions = ramp.offsets;
            while (k + 1 < positions.len and positions[k] < t) k += 1;
            const span = positions[k] - positions[k - 1];
            return mix(ramp.colors[k - 1], ramp.colors[k], if (span == 0) 1 else (t - positions[k - 1]) / span);
        },
        .patches => |patches| {
            const k, const u, const v = topmostPatch(patches.points, local) orelse return null;
            return patches.stops.at(color_patches.bilinear(color_patches.cornerValues(patches.values[k]), u, v));
        },
        .color_patches => |patches| {
            const k, const u, const v = topmostPatch(patches.points, local) orelse return null;
            return color_patches.bilinearColor(patches.colors[k], u, v);
        },
        .fan => |conic| return conic.stops.at(conic_mesh.evaluate(conic, local) orelse return null),
        .radial => unreachable,
    }
}

/// The last of bilinear patches holding `p`, and where in it.
fn topmostPatch(nets: []const [16]g.Point, p: g.Point) ?struct { usize, f64, f64 } {
    var k = nets.len;
    while (k > 0) {
        k -= 1;
        // p = a + u e + v f + u v w: crossing with e + v w leaves v.
        const a = nets[k][0];
        const e = nets[k][12].sub(a);
        const f = nets[k][3].sub(a);
        const w = a.sub(nets[k][3]).add(nets[k][15]).sub(nets[k][12]);
        const h = p.sub(a);
        const quadratic = -f.cross(w);
        const linear = h.cross(w) - f.cross(e);
        const rest = h.cross(e);
        var roots: [2]f64 = undefined;
        var count: usize = 0;
        if (@abs(quadratic) < 1e-12) {
            if (linear != 0) {
                roots[0] = -rest / linear;
                count = 1;
            }
        } else {
            const discriminant = linear * linear - 4 * quadratic * rest;
            if (discriminant < 0) continue;
            roots = .{ (-linear - @sqrt(discriminant)) / (2 * quadratic), (-linear + @sqrt(discriminant)) / (2 * quadratic) };
            count = 2;
        }
        for (roots[0..count]) |v| {
            if (v < -1e-9 or v > 1 + 1e-9) continue;
            const along = e.add(w.scale(v));
            const u = h.sub(f.scale(v)).dot(along) / along.dot(along);
            if (u >= -1e-9 and u <= 1 + 1e-9) return .{ k, std.math.clamp(u, 0, 1), std.math.clamp(v, 0, 1) };
        }
    }
    return null;
}

/// A patch over the rectangle from `origin`, `width` by `height`.
pub fn plane(origin: g.Point, width: f64, height: f64) [16]g.Point {
    var net: [16]g.Point = undefined;
    for (0..4) |i| for (0..4) |j| {
        net[i * 4 + j] = origin.add(.{ .x = width * @as(f64, @floatFromInt(i)) / 3, .y = height * @as(f64, @floatFromInt(j)) / 3 });
    };
    return net;
}

/// A bilinear field's coefficients, from its values at the corners in
/// `color_patches.corner_uv` order.
pub fn bilinearField(corners: [4]f64) [16]f64 {
    var values: [16]f64 = undefined;
    for (0..4) |i| for (0..4) |j| {
        values[i * 4 + j] = color_patches.bilinear(corners, @as(f64, @floatFromInt(i)) / 3, @as(f64, @floatFromInt(j)) / 3);
    };
    return values;
}

/// Every sample point of a grid inside `box` farther than `margin` from any
/// edge of the picture's paths gives the same color before and after.
pub fn expectSameColors(source: *const DisplayList, result: *const DisplayList, paper: Color, box: g.BBox, steps: usize) !void {
    const before: Reference = .{ .allocator = testing.allocator, .picture = source, .paper = paper };
    const after: Reference = .{ .allocator = testing.allocator, .picture = result, .paper = paper };
    for (0..steps) |i| for (0..steps) |j| {
        // Offset from the grid that edges lie on.
        const point: g.Point = .{
            .x = box.min.x + (box.max.x - box.min.x) * (@as(f64, @floatFromInt(i)) + 0.37) / @as(f64, @floatFromInt(steps)),
            .y = box.min.y + (box.max.y - box.min.y) * (@as(f64, @floatFromInt(j)) + 0.61) / @as(f64, @floatFromInt(steps)),
        };
        const want = try before.at(point);
        const got = try after.at(point);
        try testing.expectApproxEqAbs(@as(f64, 1), got.a, 1e-9);
        inline for (.{ "r", "g", "b" }) |channel| {
            testing.expectApproxEqAbs(@field(want, channel), @field(got, channel), 1.0 / @as(f64, Color.max_level)) catch |err| {
                std.debug.print("at ({d}, {d}) {s}: source {d}, flattened {d}\n", .{ point.x, point.y, channel, @field(want, channel), @field(got, channel) });
                return err;
            };
        }
    };
}

/// No paint of the result is translucent, and no group has an opacity.
pub fn expectOpaque(picture: *const DisplayList) !void {
    for (picture.commands.items) |command| switch (command) {
        .push => |group| try testing.expectEqual(@as(f64, 1), group.opacity),
        .path => |draw| for ([_]style.Style.Component{ .fill, .stroke }) |component| {
            if (draw.style.paint(component)) |paint| try testing.expect(paint.isOpaque());
        },
        .label, .pop => {},
    };
}

pub fn paths(picture: *const DisplayList) usize {
    var count: usize = 0;
    for (picture.commands.items) |command| count += @intFromBool(command == .path);
    return count;
}
