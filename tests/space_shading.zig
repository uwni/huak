//! Smooth light fields against exact light, through the desktop projection
//! library. For each scene, on a grid of points inside each front region, the
//! field as an output paints it is compared with n·l and the glint where the
//! line of sight first meets a surface: the constant, the profile, a fan
//! both as a PDF patch mesh paints it and as the triangles other outputs
//! draw, or on the last patch drawn over the point both the bilinear
//! interpolation of its corner values that a PDF patch mesh paints and its
//! cubic field, which other outputs approximate. Points within twice the
//! tolerance of a region's outline are skipped: the outline is traced only
//! that accurately. OCCT answers every geometric question; regions, fans and
//! patches are Huak's own.
const std = @import("std");
const huak = @import("huak");
const c = @import("space_c");
const check = @import("space_shading/check.zig");
const harness = @import("space_shading/harness.zig");
const Scenes = check.Scenes;
const fail = harness.fail;
const Counts = harness.Counts;
const accuracy = check.accuracy;

/// Toward the light of the examples.
const overhead: [3]f64 = .{ -1.0 / 3.0, -2.0 / 3.0, 1 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) {
        std.debug.print("usage: {s} PROJECTION_LIBRARY\n", .{args[0]});
        return error.InvalidArguments;
    }
    var library = try huak.Projection.open(args[1]);
    defer library.close();
    var scenes: Scenes = .{ .a = a, .vtable = library.vtable };

    // The scene of examples/space/highlight.huak.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const torus = try add(a, &nodes, shape(c.HUAK_TORUS, &.{ 21, 8 }));
        const sphere = try add(a, &nodes, shape(c.HUAK_SPHERE, &.{18}));
        const brick = try add(a, &nodes, try box(a, 20, 20, 28));
        const roots = [_]usize{
            try add(a, &nodes, try moved(a, torus, .{ -36, 0, 0 })),
            try add(a, &nodes, try moved(a, sphere, .{ 12, 0, 5 })),
            try add(a, &nodes, try moved(a, brick, .{ 28, -7, -10 })),
        };
        const errors = try scenes.check("highlight", nodes.items, &roots, -80, 36, overhead, 24, null);
        if (errors.patches < 5000) return fail("highlight: too few patches: {d}", .{errors.patches});
    }
    // A sphere: every query a sheet makes comes in a few batches.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_SPHERE, &.{18}))};
        var counts: Counts = .{};
        _ = try scenes.check("sphere", nodes.items, &roots, -80, 36, overhead, 0, &counts);
        if (counts.batches > 12 or counts.points < 5000) return fail("sphere: {d} batches for {d} points", .{ counts.batches, counts.points });
        counts = .{};
        _ = try scenes.check("sphere with highlight", nodes.items, &roots, -80, 36, overhead, 24, &counts);
        if (counts.batches > 20) return fail("sphere with highlight: {d} batches", .{counts.batches});
    }
    // A cone shades as a fan around its apex: seen from the side, from above
    // where the fan goes all the way around, and as a frustum, whose apex
    // lies off the face.
    for ([_]struct { name: []const u8, radii: [2]f64, height: f64, view: [2]f64, spot: f64 }{
        .{ .name = "cone", .radii = .{ 12, 0 }, .height = 20, .view = .{ -80, 36 }, .spot = 30 },
        .{ .name = "steep cone", .radii = .{ 14, 0 }, .height = 38, .view = .{ -70, 28 }, .spot = 24 },
        .{ .name = "cone from above", .radii = .{ 12, 0 }, .height = 20, .view = .{ 20, 80 }, .spot = 24 },
        .{ .name = "frustum", .radii = .{ 12, 5 }, .height = 20, .view = .{ -80, 36 }, .spot = 24 },
    }) |scene| {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_CONE, &.{ scene.radii[0], scene.radii[1], scene.height }))};
        const errors = try scenes.check(scene.name, nodes.items, &roots, scene.view[0], scene.view[1], overhead, scene.spot, null);
        if (errors.fans == 0 or errors.patches != 0) return fail("{s}: {d} fans, {d} patches", .{ scene.name, errors.fans, errors.patches });
    }
    // Light from behind this cone puts its highlight on the terminator, where
    // the highlight's fan stops at the glint it has there.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_CONE, &.{ 14, 0, 38 }))};
        const errors = try scenes.check("cone against the light", nodes.items, &roots, -70, 28, .{ 0.163, 0.925, -0.342 }, 30, null);
        if (errors.fans == 0 or !(errors.cut > 0.5)) return fail("cone against the light: {d} fans, glint {d} where the highlight ends", .{ errors.fans, errors.cut });
    }
    // Seen along one of its rulings a cone has no fan and gets patches. Its
    // apex has no normal: light near it comes from points beside it, and the
    // glint patches there cross the terminator, where the glint of lit
    // points far from the highlight is well below that of unlit ones.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_CONE, &.{ 14, 0, 38 }))};
        const along = std.math.atan2(@as(f64, 38), @as(f64, 14)) * 180.0 / std.math.pi;
        const errors = try scenes.check("cone along a ruling", nodes.items, &roots, 20, along, overhead, 24, null);
        if (errors.fans != 0 or errors.patches == 0) return fail("cone along a ruling: {d} fans, {d} patches", .{ errors.fans, errors.patches });
    }
    // A cylinder seen across its axis shades along a profile; its caps are
    // constant.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_CYLINDER, &.{ 10, 30 }))};
        const errors = try scenes.check("cylinder", nodes.items, &roots, -80, 36, overhead, 20, null);
        if (errors.profiles == 0 or errors.constants == 0) return fail("cylinder: {d} profiles, {d} constant fields", .{ errors.profiles, errors.constants });
    }
    // A sheet finer than the patch budget reports the limit.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_SPHERE, &.{18}))};
        scenes.accuracy = 1e-7;
        defer scenes.accuracy = accuracy;
        if (scenes.check("budget", nodes.items, &roots, -80, 36, overhead, 0, null)) |_| {
            return fail("budget: an exhausting sheet was shaded", .{});
        } else |err| if (err != error.ShadingLimit) return err;
    }
}

fn shape(kind: c_int, args: []const f64) c.HuakModelShape {
    var result = std.mem.zeroes(c.HuakModelShape);
    result.kind = kind;
    result.u[0] = 1;
    result.v[1] = 1;
    @memcpy(result.args[0..args.len], args);
    return result;
}

fn add(a: std.mem.Allocator, nodes: *std.ArrayList(c.HuakModelShape), node: c.HuakModelShape) !usize {
    try nodes.append(a, node);
    return nodes.items.len - 1;
}

/// A box extruded upward from a rectangle in the xy plane.
fn box(a: std.mem.Allocator, width: f64, depth: f64, height: f64) !c.HuakModelShape {
    const square = try a.alloc(c.HuakPathCommand, 5);
    const corners = [_][2]f64{ .{ 0, 0 }, .{ width, 0 }, .{ width, depth }, .{ 0, depth } };
    for (square[0..4], corners, 0..) |*cmd, corner, k| {
        cmd.* = std.mem.zeroes(c.HuakPathCommand);
        cmd.op = if (k == 0) c.HUAK_MOVE else c.HUAK_LINE;
        cmd.p[0] = .{ .x = corner[0], .y = corner[1] };
    }
    square[4] = std.mem.zeroes(c.HuakPathCommand);
    square[4].op = c.HUAK_CLOSE;
    var result = shape(c.HUAK_EXTRUDE, &.{ 0, 0, height });
    result.profile = square.ptr;
    result.count = square.len;
    return result;
}

/// `node` translated by `offset`.
fn moved(a: std.mem.Allocator, node: usize, offset: [3]f64) !c.HuakModelShape {
    const input = try a.create(usize);
    input.* = node;
    var result = shape(c.HUAK_TRANSFORMED, &.{ 1, 0, 0, offset[0], 0, 1, 0, offset[1], 0, 0, 1, offset[2] });
    result.inputs = input;
    result.input_count = 1;
    return result;
}
