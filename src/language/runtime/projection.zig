//! Convert one complete model for OCCT. Inputs and kernel output are scratch;
//! only ordinary 2D paths and line metadata survive the projection.
const std = @import("std");
const Runtime = @import("../Runtime.zig");
const types = @import("../types.zig");
const Path = @import("../../drawing/path/Path.zig");
const c = @import("space_c");
const Value = types.Value;

fn coordinates(v: Value, direction: bool) ![3]f64 {
    if (v != .vec3 or !v.vec3.isFinite()) return error.ExpectedVec3;
    const p = v.vec3;
    if (direction and !p.dimension.eql(.scalar)) return error.DimensionMismatch;
    return p.points();
}

fn xy(p: Path.Point) c.HuakXY {
    return .{ .x = p.x, .y = p.y };
}
fn point(p: c.HuakXY) Path.Point {
    return .{ .x = p.x, .y = p.y };
}
fn profile(a: std.mem.Allocator, shape: *c.HuakModelShape, curve: Path) !void {
    const commands = try a.alloc(c.HuakPathCommand, curve.segments.items.len);
    for (curve.segments.items, commands) |s, *cmd| {
        cmd.* = std.mem.zeroes(c.HuakPathCommand);
        switch (s) {
            .move, .line => |p| {
                cmd.op = if (s == .move) c.HUAK_MOVE else c.HUAK_LINE;
                cmd.p[0] = xy(p);
            },
            .cubic => |b| {
                cmd.op = c.HUAK_BEZIER;
                cmd.p = .{ xy(b.c1), xy(b.c2), xy(b.end) };
            },
            .close => cmd.op = c.HUAK_CLOSE,
        }
    }
    shape.profile = commands.ptr;
    shape.count = commands.len;
}

// Lower only reachable geometry, once per handle. Operands precede their
// users; roots separately preserve the script's source indices.
const Graph = struct {
    rt: *Runtime,
    arena: std.mem.Allocator,
    nodes: std.ArrayList(c.HuakModelShape) = .empty,
    indices: std.AutoHashMapUnmanaged(types.Handle, usize) = .empty,

    fn inputs(self: *Graph, out: *c.HuakModelShape, values: []const Value, depth: usize) anyerror!void {
        const ids = try self.arena.alloc(usize, values.len);
        for (ids, values) |*id, value| id.* = try self.add(value, depth + 1);
        out.inputs = ids.ptr;
        out.input_count = ids.len;
    }

    fn add(self: *Graph, value: Value, depth: usize) anyerror!usize {
        if (value != .handle) return error.ExpectedModelGeometry;
        if (self.indices.get(value.handle)) |id| return id;
        if (depth > 512) return error.ModelNestingLimit;
        var out = std.mem.zeroes(c.HuakModelShape);
        out.u[0] = 1;
        out.v[1] = 1;
        if (value.valueType() == .path) {
            out.kind = c.HUAK_PROFILE;
            try profile(self.arena, &out, try self.rt.path(value));
        } else {
            const node = try self.rt.model(value);
            const args = node.arguments;
            const count: usize = switch (node.kind) {
                .sphere, .reverse, .closed => 1,
                .segment, .torus, .cylinder, .circle, .joined, .transformed, .sweep, .fuse, .common, .cut => 2,
                .cone, .surface_curve, .ellipse => 3,
                .cubic, .arc, .profile, .face => 4,
                .extrude => 5,
                .revolve => 7,
                .polygon, .polyline, .loft, .solid_loft => args.len,
            };
            if (args.len != count) return error.InvalidModelArguments;
            out.kind = switch (node.kind) {
                inline else => |op| @field(c, name: {
                    const tag = @tagName(op);
                    var upper: [tag.len]u8 = undefined;
                    break :name "HUAK_" ++ std.ascii.upperString(&upper, tag);
                }),
            };
            switch (node.kind) {
                .segment, .cubic => for (args, 0..) |v, i| {
                    out.args[i * 3 ..][0..3].* = try coordinates(v, false);
                },
                .polygon, .polyline => {
                    if (args.len < (if (node.kind == .polygon) @as(usize, 3) else 2)) return error.TooFewKnots;
                    const points = try self.arena.alloc(c.HuakXYZ, args.len);
                    for (args, points) |v, *p| p.xyz = try coordinates(v, false);
                    out.points = points.ptr;
                    out.count = points.len;
                },
                .sphere, .torus, .cylinder, .cone => {
                    for (args, 0..) |v, i| out.args[i] = try Runtime.lengthPoints(v);
                    if (node.kind == .torus and !(out.args[0] > out.args[1] and out.args[1] > 0)) return error.InvalidTorusRadii;
                    if (node.kind == .cone) {
                        if (out.args[0] < 0 or out.args[1] < 0 or out.args[0] == out.args[1] or out.args[2] <= 0) return error.InvalidConeDimensions;
                    } else for (out.args[0..count]) |v| {
                        if (!(v > 0)) return error.InvalidModelDimensions;
                    }
                },
                .circle, .arc, .ellipse => {
                    out.origin = try coordinates(args[0], false);
                    out.args[0] = try Runtime.lengthPoints(args[1]);
                    if (out.args[0] <= 0) return error.InvalidRadius;
                    if (node.kind == .ellipse) {
                        out.args[1] = try Runtime.lengthPoints(args[2]);
                        if (out.args[1] <= 0) return error.InvalidRadius;
                    } else if (node.kind == .arc) {
                        out.args[1] = try Runtime.angular(args[2]);
                        out.args[2] = try Runtime.angular(args[3]);
                        if (out.args[2] == 0 or @abs(out.args[2]) > 2 * std.math.pi) return error.InvalidArcSweep;
                    }
                },
                .surface_curve => {
                    try self.inputs(&out, args[0..1], depth);
                    if (args[2] != .int) return error.InvalidSurface;
                    out.face = std.math.cast(c_int, args[2].int) orelse return error.InvalidSurface;
                    try profile(self.arena, &out, try self.rt.path(args[1]));
                },
                .profile, .face, .extrude, .revolve => {
                    out.origin = try coordinates(args[1], false);
                    out.u = try coordinates(args[2], true);
                    out.v = try coordinates(args[3], true);
                    if (args[0].valueType() == .path) {
                        try profile(self.arena, &out, try self.rt.path(args[0]));
                    } else {
                        const default_v: [3]f64 = if (node.kind == .revolve) .{ 0, 0, 1 } else .{ 0, 1, 0 };
                        if (!std.meta.eql(out.origin, [3]f64{ 0, 0, 0 }) or !std.meta.eql(out.u, [3]f64{ 1, 0, 0 }) or !std.meta.eql(out.v, default_v)) return error.PlaneRequiresPlanarPath;
                        try self.inputs(&out, args[0..1], depth);
                    }
                    if (node.kind == .extrude) out.args[0..3].* = try coordinates(args[4], false);
                    if (node.kind == .revolve) {
                        out.args[0..3].* = try coordinates(args[4], false);
                        out.args[3..6].* = try coordinates(args[5], true);
                        out.args[6] = try Runtime.angular(args[6]);
                    }
                },
                .transformed => {
                    try self.inputs(&out, args[0..1], depth);
                    out.args = @bitCast((try self.rt.affineValue(args[1])).matrix3().rows);
                },
                .reverse, .closed, .joined, .sweep, .loft, .solid_loft, .fuse, .common, .cut => try self.inputs(&out, args, depth),
            }
        }
        const id = self.nodes.items.len;
        try self.nodes.append(self.arena, out);
        try self.indices.put(self.arena, value.handle, id);
        return id;
    }
};

fn projectedPath(rt: *Runtime, commands: []const c.HuakPathCommand) !Value {
    var path = Path.init(rt.mem());
    try path.segments.ensureTotalCapacityPrecise(path.allocator, commands.len);
    for (commands) |command| switch (command.op) {
        c.HUAK_MOVE => try path.moveTo(point(command.p[0])),
        c.HUAK_LINE => try path.lineTo(point(command.p[0])),
        c.HUAK_BEZIER => try path.cubicTo(point(command.p[0]), point(command.p[1]), point(command.p[2])),
        c.HUAK_CLOSE => try path.close(),
        else => return error.InvalidProjectedPath,
    };
    return rt.pathResult(path);
}

pub fn project(rt: *Runtime, output: std.mem.Allocator, args: []const Value) !Value {
    const backend = rt.backends.projection orelse {
        rt.native_message = "3D projection is unavailable: no compatible OCCT projection backend is loaded";
        return error.ProjectionUnavailable;
    };
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = types.sequence(args[0]) orelse return error.TypeMismatch;
    var graph: Graph = .{ .rt = rt, .arena = scratch };
    const roots = try scratch.alloc(usize, input.len);
    for (input, roots) |v, *id| id.* = try graph.add(v, 0);
    const focus = try Runtime.lengthPoints(args[3]);
    const tolerance = try Runtime.lengthPoints(args[4]);
    if (focus < 0 or tolerance <= 0) return error.InvalidProjection;
    if (args[5] != .boolean) return error.TypeMismatch;
    const spot = try Runtime.angular(args[7]);
    if (!(spot >= 0 and spot < std.math.pi / 2.0)) return error.InvalidHighlightAngle;
    var light: ?c.HuakLight = null;
    if (!(args[6] == .boolean and !args[6].boolean)) {
        const d = try coordinates(args[6], true);
        const scale = @max(@abs(d[0]), @abs(d[1]), @abs(d[2]));
        if (scale == 0) return error.InvalidLightDirection;
        const levels = types.sequence(args[8]) orelse return error.TypeMismatch;
        if (levels.len == 0) return error.InvalidIsophotes;
        const thresholds = try scratch.alloc(f64, levels.len);
        for (levels, thresholds, 0..) |value, *threshold, i| {
            threshold.* = try Runtime.numeric(value);
            if (!(threshold.* >= 0 and threshold.* < 1) or
                (if (i == 0) threshold.* != 0 else threshold.* <= thresholds[i - 1])) return error.InvalidIsophotes;
        }
        light = .{ .direction = .{ d[0] / scale, d[1] / scale, d[2] / scale }, .spot_angle = spot, .isophotes = thresholds.ptr, .isophote_count = thresholds.len };
    } else if (spot != 0) return error.HighlightRequiresLight;
    var work: c.HuakLinework = undefined;
    var message: [512]u8 = @splat(0);
    switch (backend.project.?(graph.nodes.items.ptr, graph.nodes.items.len, roots.ptr, roots.len, try Runtime.angular(args[1]), try Runtime.angular(args[2]), focus, tolerance, @intFromBool(args[5].boolean), if (light) |*l| l else null, &work, &message, message.len)) {
        0 => {},
        2 => return error.OutOfMemory,
        else => {
            rt.native_message = try rt.mem().dupe(u8, std.mem.sliceTo(&message, 0));
            return error.ProjectionFailed;
        },
    }
    defer backend.release.?(&work);
    var layer_count: usize = 0;
    const result = try output.alloc(Value, work.count);
    for (result, 0..) |*row, i| {
        const line = work.lines[i];
        const path = try projectedPath(rt, work.commands[line.start..][0..line.count]);
        const kind: []const u8 = switch (line.kind) {
            c.HUAK_EDGE => "edge",
            c.HUAK_CURVE => "curve",
            c.HUAK_OUTLINE => "outline",
            c.HUAK_SMOOTH => "smooth",
            c.HUAK_SEAM => "seam",
            c.HUAK_INTERSECTION => "intersection",
            else => return error.InvalidProjectedPath,
        };
        layer_count = @max(layer_count, line.covering + 1);
        row.* = types.listView(try output.dupe(Value, &.{ path, .{ .int = @intCast(line.source) }, .{ .string = kind }, .{ .int = @intCast(line.covering) }, .{ .int = line.other_source } }));
    }
    const faces = try output.alloc(Value, work.face_count);
    for (faces, 0..) |*row, i| {
        const face = work.faces[i];
        const path = try projectedPath(rt, work.commands[face.start..][0..face.count]);
        layer_count = @max(layer_count, face.covering + 1);
        const spot_path: Value = if (face.spot_count == 0)
            .{ .boolean = false }
        else if (face.spot_start == face.start and face.spot_count == face.count)
            path
        else
            try projectedPath(rt, work.commands[face.spot_start..][0..face.spot_count]);
        const lobes = try output.alloc(Value, face.lobe_count);
        for (lobes, 0..) |*lobe, index| {
            const ellipse = work.lobes[face.lobe_start + index];
            lobe.* = types.listView(try output.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(point(ellipse.center)) }, .{ .vec2 = .{ .x = ellipse.u.x, .y = ellipse.u.y } }, .{ .vec2 = .{ .x = ellipse.v.x, .y = ellipse.v.y } } }));
        }
        const shades = try output.alloc(Value, face.shade_count);
        for (shades, 0..) |*shade, index| {
            const native = work.shades[face.shade_start + index];
            const region = if (native.start == face.start and native.count == face.count) path else try projectedPath(rt, work.commands[native.start..][0..native.count]);
            shade.* = types.listView(try output.dupe(Value, &.{ region, .{ .number = native.diffuse } }));
        }
        row.* = types.listView(try output.dupe(Value, &.{ path, .{ .int = @intCast(face.source) }, .{ .int = @intCast(face.face) }, .{ .int = @intCast(face.covering) }, types.listView(shades), spot_path, types.listView(lobes) }));
    }
    return types.listView(try output.dupe(Value, &.{ types.listView(result), types.listView(faces), .{ .int = if (args[5].boolean) @intCast(layer_count) else 0 } }));
}
