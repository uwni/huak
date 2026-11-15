//! Smooth light fields against exact light, through the desktop projection
//! library. For each scene, on a grid of points inside each front region, the
//! field as an output paints it is compared with n·l and the glint where the
//! line of sight first meets a surface: the constant, the profile, or on the
//! last patch drawn over the point both the bilinear interpolation of its
//! corner values that a PDF patch mesh paints and its cubic field, which
//! other outputs approximate. Points within twice the tolerance of a region's
//! outline are skipped: the outline is traced only that accurately. OCCT
//! answers every geometric question; regions and patches are Huak's own.
const std = @import("std");
const huak = @import("huak");
const c = @import("space_c");
const shading = huak.core.shading;
const g = huak.core.geometry;
const Path = huak.core.Path;
const patch_mesh = huak.core.patches;
const windingAt = huak.core.region.windingAt;
const Model = huak.Projection.Model;
const linework = huak.Projection.linework;

const accuracy = 1.0 / 256.0;
const tolerance = 0.01;
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
    // A cone's apex has no normal: light near it comes from points beside it.
    {
        var nodes: std.ArrayList(c.HuakModelShape) = .empty;
        const roots = [_]usize{try add(a, &nodes, shape(c.HUAK_CONE, &.{ 12, 0, 20 }))};
        _ = try scenes.check("cone", nodes.items, &roots, -80, 36, overhead, 30, null);
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

const Counts = struct { batches: usize = 0, points: usize = 0 };

/// What a scene's check measured.
const Errors = struct { patches: usize = 0, profiles: usize = 0, constants: usize = 0 };

const Scenes = struct {
    a: std.mem.Allocator,
    vtable: *const huak.Projection.VTable,
    accuracy: f64 = accuracy,

    /// Projects `roots` with smooth light, then checks each front region's
    /// field against exact light. `counts`, when given, counts the surface
    /// queries the fields make.
    fn check(self: *Scenes, name: []const u8, nodes: []const c.HuakModelShape, roots: []const usize, azimuth: f64, elevation: f64, sun_direction: [3]f64, spot: f64, counts: ?*Counts) !Errors {
        const a = self.a;
        var message: Model.Message = @splat(0);
        var model = Model.build(a, self.vtable, nodes, roots, tolerance, &message) catch |err| return report(err, &message);
        defer model.deinit(a);
        const degree = std.math.pi / 180.0;
        var view = linework.view(&model, a, .{ .azimuth = azimuth * degree, .elevation = elevation * degree, .focus = 0 }) catch |err| return report(err, &message);
        defer view.deinit();
        const light: linework.Light = .{ .direction = sun_direction, .spot = spot * degree, .isophotes = &.{0}, .smooth = true };
        var work = linework.project(a, &view, .{ .faces = true, .light = light, .tolerance = tolerance }) catch |err| return report(err, &message);
        defer work.deinit(a);

        const sun = unit(light.direction);
        var counting: Counting = .{ .inner = view.surfaces(), .counts = counts };
        var lighting: shading.Shading = try .init(a, if (counts != null) counting.surfaces() else view.surfaces(), .{ .sun = sun, .spot = light.spot, .accuracy = self.accuracy }, work.frame.eye, tolerance);
        defer lighting.deinit();
        const records = work.faces.items;
        const fields = try a.alloc(shading.Field, records.len);
        var out: shading.Output = .{};
        defer out.deinit(a);
        linework.smoothFields(&work, &lighting, &out, fields) catch |err| {
            if (err == error.SurfaceQueryFailed) return report(error.ProjectionFailed, &message);
            return err;
        };

        // Sample points inside each front region.
        const Point = struct { at: g.Point, region: usize };
        var points: std.ArrayList(Point) = .empty;
        var result: Errors = .{};
        for (records, fields, 0..) |record, field, index| {
            if (record.covering != 0) {
                if (field != .none) return fail("{s}: hidden region {d} has a field", .{ name, index });
                continue;
            }
            switch (field) {
                .none => return fail("{s}: front region {d} has no field", .{ name, index }),
                .constant => result.constants += 1,
                .profile => result.profiles += 1,
                .patches => |p| result.patches += p.diffuse.count + p.glint.count,
            }
            var region = try toPath(a, work.commands.items[record.start..][0..record.count]);
            defer region.deinit();
            var band = try patch_mesh.Outline.init(a, region.segments.items, 2 * tolerance);
            defer band.deinit(a);
            const bounds = band.bounds;
            const grid = 120;
            for (0..grid + 1) |j| for (0..grid + 1) |i| {
                const p: g.Point = .{ .x = bounds.min.x + bounds.width() * @as(f64, @floatFromInt(i)) / grid, .y = bounds.min.y + bounds.height() * @as(f64, @floatFromInt(j)) / grid };
                if (band.near(p) or try windingAt(region, p) == 0) continue;
                try points.append(a, .{ .at = p, .region = index });
            };
        }
        // The front surface at each point, and its normal there.
        const screen = try a.alloc(c.HuakXY, points.items.len);
        for (screen, points.items) |*s, point| s.* = .{ .x = point.at.x, .y = point.at.y };
        const found = view.rays(screen) catch |err| return report(err, &message);
        const Front = struct { face: shading.Face, uv: g.Point };
        const fronts = try a.alloc(?Front, points.items.len);
        for (fronts, 0..) |*front, k| {
            front.* = null;
            var best: ?c.HuakShapeHit = null;
            var tied = false;
            for (found.row(k)) |hit| {
                if (best == null or hit.depth > best.?.depth) {
                    tied = best != null and hit.depth - best.?.depth <= 1e-7;
                    best = hit;
                } else if (best.?.depth - hit.depth <= 1e-7) tied = true;
            }
            // A line along the edge of two faces shows either.
            if (tied) continue;
            const hit = best orelse continue;
            front.* = .{ .face = .{ .source = hit.source, .index = hit.face }, .uv = .{ .x = hit.u, .y = hit.v } };
        }
        const normals = try a.alloc(?[3]f64, points.items.len);
        @memset(normals, null);
        var surfaces = view.surfaces();
        for (model.shapes, 0..) |shape_, source| for (0..shape_.faces) |face| {
            var uv: std.ArrayList(g.Point) = .empty;
            var owners: std.ArrayList(usize) = .empty;
            for (fronts, 0..) |front, k| {
                const f = front orelse continue;
                if (f.face.source != source or f.face.index != face) continue;
                try uv.append(a, f.uv);
                try owners.append(a, k);
            }
            const seen = try a.alloc(shading.Look, uv.items.len);
            surfaces.look(a, .{ .source = source, .index = face }, uv.items, seen) catch return report(error.ProjectionFailed, &message);
            for (owners.items, seen) |k, look| normals[k] = look.normal;
        };

        var half: [3]f64 = undefined;
        for (&half, sun, work.frame.eye) |*h, s, e| h.* = s + e;
        half = unit(half);
        const cutoff = @cos(light.spot);
        const Worst = struct { errors: [4]f64 = @splat(0), samples: usize = 0 };
        const worst = try a.alloc(Worst, records.len);
        @memset(worst, .{});
        for (points.items, fronts, normals) |point, front, normal| {
            const record = records[point.region];
            const f = front orelse continue;
            if (f.face.source != record.source or f.face.index != record.face) continue;
            const n = normal orelse continue;
            const diffuse = dot(n, sun);
            const glint = if (light.spot > 0) (dot(n, half) - cutoff) / (1 - cutoff) else -1;
            const painted = paint(fields[point.region], &out, point.at) orelse return fail("{s}: region {d} leaves ({d}, {d}) uncovered", .{ name, point.region, point.at.x, point.at.y });
            const w = &worst[point.region];
            w.samples += 1;
            for (painted, 0..) |shine, k| {
                w.errors[k] = @max(w.errors[k], @abs(shine.diffuse - diffuse));
                // The glint matters where it is positive and the point is lit.
                if (diffuse > 0 and (glint > 0 or shine.glint > 0)) w.errors[2 + k] = @max(w.errors[2 + k], @abs(@max(shine.glint, 0) - @max(glint, 0)));
            }
        }
        var largest: [4]f64 = @splat(0);
        var samples: usize = 0;
        for (records, fields, worst, 0..) |record, field, w, index| {
            if (record.covering != 0) continue;
            std.debug.print("{s}: region {d} (shape {d} face {d}, {s}): {d} samples, n·l error {d:.6} (cubic {d:.6}), glint error {d:.6} (cubic {d:.6})\n", .{ name, index, record.source, record.face, @tagName(field), w.samples, w.errors[0], w.errors[1], w.errors[2], w.errors[3] });
            samples += w.samples;
            for (&largest, w.errors) |*l, e| l.* = @max(l.*, e);
        }
        std.debug.print("{s}: {d} patches, {d} samples: largest n·l error {d:.6} (cubic {d:.6}), glint error {d:.6} (cubic {d:.6}), accuracy {d:.6}\n", .{ name, result.patches, samples, largest[0], largest[1], largest[2], largest[3], self.accuracy });
        if (samples < 1000) return fail("{s}: too few samples: {d}", .{ name, samples });
        if (std.mem.max(f64, &largest) > self.accuracy) return fail("{s}: light differs from its field by more than the accuracy", .{name});
        return result;
    }
};

/// Surface queries counted on their way to OCCT.
const Counting = struct {
    inner: shading.Surfaces,
    counts: ?*Counts,

    const vtable: shading.Surfaces.VTable = .{ .info = info, .look = look, .turns = turns, .roots = roots, .sightings = sightings };

    fn surfaces(self: *Counting) shading.Surfaces {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn of(ptr: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ptr));
    }
    fn count(self: *Counting, points: usize) void {
        const counts = self.counts orelse return;
        counts.batches += 1;
        counts.points += points;
    }
    fn info(ptr: *anyopaque, face: shading.Face) shading.Surfaces.QueryError!shading.Info {
        return of(ptr).inner.info(face);
    }
    fn look(ptr: *anyopaque, a: std.mem.Allocator, face: shading.Face, uv: []const g.Point, out: []shading.Look) shading.Surfaces.QueryError!void {
        of(ptr).count(uv.len);
        return of(ptr).inner.look(a, face, uv, out);
    }
    fn turns(ptr: *anyopaque, a: std.mem.Allocator, face: shading.Face, uv: []const g.Point, out: []?shading.Turn) shading.Surfaces.QueryError!void {
        of(ptr).count(uv.len);
        return of(ptr).inner.turns(a, face, uv, out);
    }
    fn roots(ptr: *anyopaque, a: std.mem.Allocator, face: shading.Face, segments: []const [2]g.Point, direction: shading.Vec3, value: f64, tolerance_: f64, out: []?f64) shading.Surfaces.QueryError!void {
        of(ptr).count(segments.len);
        return of(ptr).inner.roots(a, face, segments, direction, value, tolerance_, out);
    }
    fn sightings(ptr: *anyopaque, a: std.mem.Allocator, face: shading.Face, points: []const g.Point, offsets: []usize, out: *std.ArrayList(shading.Sighting)) shading.Surfaces.QueryError!void {
        of(ptr).count(points.len);
        return of(ptr).inner.sightings(a, face, points, offsets, out);
    }
};

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

fn toPath(a: std.mem.Allocator, commands: []const c.HuakPathCommand) !Path {
    var path = Path.init(a);
    errdefer path.deinit();
    for (commands) |command| switch (command.op) {
        c.HUAK_MOVE => try path.moveTo(toPoint(command.p[0])),
        c.HUAK_LINE => try path.lineTo(toPoint(command.p[0])),
        c.HUAK_BEZIER => try path.cubicTo(toPoint(command.p[0]), toPoint(command.p[1]), toPoint(command.p[2])),
        else => try path.close(),
    };
    return path;
}

fn toPoint(p: c.HuakXY) g.Point {
    return .{ .x = p.x, .y = p.y };
}

fn report(err: anyerror, message: *const Model.Message) anyerror {
    std.debug.print("projection failed: {s}\n", .{std.mem.sliceTo(message, 0)});
    return err;
}

fn fail(comptime format: []const u8, args: anytype) error{ShadingTestFailed} {
    std.debug.print(format ++ "\n", args);
    return error.ShadingTestFailed;
}

fn dot(p: [3]f64, q: [3]f64) f64 {
    return p[0] * q[0] + p[1] * q[1] + p[2] * q[2];
}

fn unit(v: [3]f64) [3]f64 {
    const length = @sqrt(dot(v, v));
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

/// The light a field paints at `p`: [0] bilinear in a patch's corner values
/// or as given, [1] the cubic field. Null where no patch covers `p`.
fn paint(field: shading.Field, out: *const shading.Output, p: g.Point) ?[2]shading.Shine {
    switch (field) {
        .none => return null,
        .constant => |shine| return .{ shine, shine },
        .profile => |profile| {
            const axis = profile.end.sub(profile.start);
            const t = std.math.clamp(p.sub(profile.start).dot(axis) / axis.dot(axis), 0, 1);
            const list = out.samples.items[profile.samples.start..][0..profile.samples.count];
            for (list[1..], list[0 .. list.len - 1]) |next, previous| {
                if (t > next.position) continue;
                const w = if (next.position > previous.position) (t - previous.position) / (next.position - previous.position) else 1;
                const shine: shading.Shine = .{ .diffuse = previous.shine.diffuse + (next.shine.diffuse - previous.shine.diffuse) * w, .glint = previous.shine.glint + (next.shine.glint - previous.shine.glint) * w };
                return .{ shine, shine };
            }
            return null;
        },
        .patches => |patches| {
            const d = topmost(out.patches.items[patches.diffuse.start..][0..patches.diffuse.count], p) orelse return null;
            // Without a glint patch over the point the highlight is absent.
            const h = topmost(out.patches.items[patches.glint.start..][0..patches.glint.count], p) orelse [2]f64{ -1, -1 };
            return .{ .{ .diffuse = d[0], .glint = h[0] }, .{ .diffuse = d[1], .glint = h[1] } };
        },
    }
}

/// The field of the last patch drawn over `p`: bilinear between its corner
/// values, as a PDF patch mesh paints it, and its cubic field.
fn topmost(patches: []const shading.Patch, p: g.Point) ?[2]f64 {
    var k = patches.len;
    while (k > 0) {
        k -= 1;
        const patch = &patches[k];
        const s, const t = locate(patch, p) orelse continue;
        const v = patch.values;
        const cubic = patch_mesh.evaluate(&patch.points, &patch.values, s, t).value;
        return .{ v[0] * (1 - s) * (1 - t) + v[12] * s * (1 - t) + v[15] * s * t + v[3] * (1 - s) * t, cubic };
    }
    return null;
}

/// Where in a patch's own parameters `p` lies, by Newton's method on the
/// patch's points from a few starting points; null when no solution lies in
/// the unit square. The patch is Huak's output, not an OCCT surface.
fn locate(patch: *const shading.Patch, p: g.Point) ?[2]f64 {
    var box_: g.BBox = .fromPoint(patch.points[0]);
    for (patch.points) |q| box_ = box_.include(q);
    if (!box_.expanded(1e-9).contains(p)) return null;
    const step = 1e-6;
    for ([_][2]f64{ .{ 0.5, 0.5 }, .{ 0.15, 0.15 }, .{ 0.85, 0.15 }, .{ 0.15, 0.85 }, .{ 0.85, 0.85 } }) |start| {
        var s, var t = start;
        for (0..40) |_| {
            const at = patch_mesh.evaluate(&patch.points, &patch.values, s, t).point;
            const r = at.sub(p);
            if (r.norm() < 1e-10) return if (s > -1e-7 and s < 1 + 1e-7 and t > -1e-7 and t < 1 + 1e-7) .{ s, t } else null;
            const du = patch_mesh.evaluate(&patch.points, &patch.values, s + step, t).point.sub(patch_mesh.evaluate(&patch.points, &patch.values, s - step, t).point).scale(0.5 / step);
            const dv = patch_mesh.evaluate(&patch.points, &patch.values, s, t + step).point.sub(patch_mesh.evaluate(&patch.points, &patch.values, s, t - step).point).scale(0.5 / step);
            const det = du.cross(dv);
            if (!(@abs(det) > 1e-300)) break;
            s = std.math.clamp(s - r.cross(dv) / det, -0.5, 1.5);
            t = std.math.clamp(t - du.cross(r) / det, -0.5, 1.5);
        }
    }
    return null;
}
