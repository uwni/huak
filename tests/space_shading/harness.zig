//! The counting Surfaces wrapper, and the helpers the checks and main share.
const std = @import("std");
const huak = @import("huak");
const c = @import("space_c");
const shading = huak.core.shading;
const g = huak.core.geometry;
const Path = huak.core.Path;
const Model = huak.Projection.Model;

pub const Counts = struct { batches: usize = 0, points: usize = 0 };

/// Surface queries counted on their way to OCCT.
pub const Counting = struct {
    inner: shading.Surfaces,
    counts: ?*Counts,

    pub const vtable: shading.Surfaces.VTable = .{ .info = info, .look = look, .turns = turns, .roots = roots, .sightings = sightings };

    pub fn surfaces(self: *Counting) shading.Surfaces {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn of(ptr: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ptr));
    }
    pub fn count(self: *Counting, points: usize) void {
        const counts = self.counts orelse return;
        counts.batches += 1;
        counts.points += points;
    }
    fn info(ptr: *anyopaque, face: shading.Face) shading.Surfaces.QueryError!shading.Info {
        return of(ptr).inner.info(face);
    }
    pub fn look(ptr: *anyopaque, a: std.mem.Allocator, face: shading.Face, uv: []const g.Point, out: []shading.Look) shading.Surfaces.QueryError!void {
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

pub fn toPath(a: std.mem.Allocator, commands: []const c.HuakPathCommand) !Path {
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

pub fn report(err: anyerror, message: *const Model.Message) anyerror {
    std.debug.print("projection failed: {s}\n", .{std.mem.sliceTo(message, 0)});
    return err;
}

pub fn fail(comptime format: []const u8, args: anytype) error{ShadingTestFailed} {
    std.debug.print(format ++ "\n", args);
    return error.ShadingTestFailed;
}
