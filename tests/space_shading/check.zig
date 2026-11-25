//! Projecting a scene with smooth light and comparing every sampled point with exact n·l and glint.
const std = @import("std");
const huak = @import("huak");
const c = @import("space_c");
const shading = huak.core.shading;
const dot = shading.dot;
const unit = shading.unit;
const g = huak.core.geometry;
const patch_mesh = huak.core.patches;
const windingAt = huak.core.region.windingAt;
const Model = huak.Projection.Model;
const linework = huak.Projection.linework;
const harness = @import("harness.zig");
const painting = @import("painting.zig");
const Counts = harness.Counts;
const report = harness.report;
const Counting = harness.Counting;
const Fan = painting.Fan;
const fail = harness.fail;
const toPath = harness.toPath;
const paint = painting.paint;

pub const accuracy = 1.0 / 256.0;

const tolerance = 0.01;

/// What a scene's check measured.
const Errors = struct {
    patches: usize = 0,
    fans: usize = 0,
    /// The highest glint on an end ray of a highlight's fan: positive where
    /// the highlight stops short, as on a terminator.
    cut: f64 = 0,
    profiles: usize = 0,
    constants: usize = 0,
};

pub const Scenes = struct {
    a: std.mem.Allocator,
    vtable: *const huak.Projection.VTable,
    accuracy: f64 = accuracy,

    /// Projects `roots` with smooth light, then checks each front region's
    /// field against exact light. `counts`, when given, counts the surface
    /// queries the fields make.
    pub fn check(self: *Scenes, name: []const u8, nodes: []const c.HuakModelShape, roots: []const usize, azimuth: f64, elevation: f64, sun_direction: [3]f64, spot: f64, counts: ?*Counts) !Errors {
        const a = self.a;
        var message: Model.Message = @splat(0);
        var model = Model.build(a, self.vtable, nodes, roots, tolerance, &message) catch |err| return report(err, &message);
        defer model.deinit(a);
        const degree = std.math.pi / 180.0;
        var view = linework.view(&model, a, .{ .azimuth = azimuth * degree, .elevation = elevation * degree, .focus = 0 }) catch |err| return report(err, &message);
        defer view.deinit();
        const light: linework.Light = .{ .direction = sun_direction, .spot = spot * degree, .isophotes = &.{0} };
        var work = linework.project(a, &view, .{ .faces = true, .light = light, .tolerance = tolerance, .smooth = true }) catch |err| return report(err, &message);
        defer work.deinit(a);

        const sun = unit(light.direction);
        var counting: Counting = .{ .inner = view.surfaces(), .counts = counts };
        var lighting: shading.Shading = try .init(a, if (counts != null) counting.surfaces() else view.surfaces(), .{ .sun = sun, .spot = light.spot, .accuracy = self.accuracy }, .{ .x = work.frame.x, .y = work.frame.y, .eye = work.frame.eye }, tolerance, null);
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
        const fans = try a.alloc(?Fan, records.len);
        @memset(fans, null);
        for (records, fields, 0..) |record, field, index| {
            if (record.covering != 0) {
                if (field != .none) return fail("{s}: hidden region {d} has a field", .{ name, index });
                continue;
            }
            switch (field) {
                .none => return fail("{s}: front region {d} has no field", .{ name, index }),
                .constant => result.constants += 1,
                .profile => result.profiles += 1,
                .fan => result.fans += 1,
                .patches => |p| result.patches += p.count,
            }
            var region = try toPath(a, work.commands.items[record.start..][0..record.count]);
            defer region.deinit();
            var band = try patch_mesh.Outline.init(a, region.segments.items, 2 * tolerance);
            defer band.deinit(a);
            const bounds = band.bounds;
            if (field == .fan) {
                const fan: Fan = try .init(a, &out, field.fan, bounds);
                std.debug.print("{s}: region {d} fan on {d} rays: n·l as {d} patches or {d} triangles, glint stopping at {d:.3} as {d} patches or {d} triangles\n", .{ name, index, fan.rays, fan.patches[0].len, fan.triangles[0].triangles.len, fan.cut, fan.patches[1].len, fan.triangles[1].triangles.len });
                result.cut = @max(result.cut, fan.cut);
                fans[index] = fan;
            }
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
            const painted = paint(fields[point.region], &out, fans[point.region], point.at) orelse return fail("{s}: region {d} leaves ({d}, {d}) uncovered", .{ name, point.region, point.at.x, point.at.y });
            const w = &worst[point.region];
            w.samples += 1;
            for (painted, 0..) |shine, k| {
                w.errors[k] = @max(w.errors[k], @abs(shine.diffuse - diffuse));
                // The highlight shows wherever the painted glint is positive:
                // it must be the lit glint there, and absent where the point is
                // unlit.
                const lit = if (diffuse > 0) @max(glint, 0) else 0;
                const shown = @max(shine.glint, 0);
                if (lit > 0 or shown > 0) w.errors[2 + k] = @max(w.errors[2 + k], @abs(shown - lit));
            }
        }
        var largest: [4]f64 = @splat(0);
        var samples: usize = 0;
        for (records, fields, worst, 0..) |record, field, w, index| {
            if (record.covering != 0) continue;
            std.debug.print("{s}: region {d} (shape {d} face {d}, {s}): {d} samples, n·l error {d:.6} (others {d:.6}), glint error {d:.6} (others {d:.6})\n", .{ name, index, record.source, record.face, @tagName(field), w.samples, w.errors[0], w.errors[1], w.errors[2], w.errors[3] });
            samples += w.samples;
            for (&largest, w.errors) |*l, e| l.* = @max(l.*, e);
        }
        std.debug.print("{s}: {d} patches, {d} samples: largest n·l error {d:.6} (others {d:.6}), glint error {d:.6} (others {d:.6}), accuracy {d:.6}\n", .{ name, result.patches, samples, largest[0], largest[1], largest[2], largest[3], self.accuracy });
        if (samples < 1000) return fail("{s}: too few samples: {d}", .{ name, samples });
        if (std.mem.max(f64, &largest) > self.accuracy) return fail("{s}: light differs from its field by more than the accuracy", .{name});
        return result;
    }
};
