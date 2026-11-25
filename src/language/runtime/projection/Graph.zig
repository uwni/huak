//! Lower reachable model handles into flat OCCT build nodes, once per handle.
//! Operands precede their users; roots separately preserve the script's source
//! indices.
const std = @import("std");
const Runtime = @import("../../Runtime.zig");
const convert = @import("../conversions.zig");
const types = @import("../../types.zig");
const Path = @import("../../../drawing/path/Path.zig");
const c = @import("space_c");
const Value = types.Value;
const Graph = @This();

rt: *Runtime,
arena: std.mem.Allocator,
nodes: std.ArrayList(c.HuakModelShape) = .empty,
indices: std.AutoHashMapUnmanaged(types.Handle, usize) = .empty,

pub fn coordinates(v: Value, direction: bool) ![3]f64 {
    if (v != .vec3 or !v.vec3.isFinite()) return error.ExpectedVec3;
    const p = v.vec3;
    if (direction and !p.dimension.eql(.scalar)) return error.DimensionMismatch;
    return p.points();
}

fn xy(p: Path.Point) c.HuakXY {
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

fn inputs(self: *Graph, out: *c.HuakModelShape, values: []const Value, depth: usize) anyerror!void {
    const ids = try self.arena.alloc(usize, values.len);
    for (ids, values) |*id, value| id.* = try self.add(value, depth + 1);
    out.inputs = ids.ptr;
    out.input_count = ids.len;
}

pub fn add(self: *Graph, value: Value, depth: usize) anyerror!usize {
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
            .polygon, .polyline, .loft, .solid_loft, .grid => args.len,
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
            // Rows, points to a row, then the points row after row.
            .grid => {
                if (args.len < 2 or args[0] != .int or args[1] != .int) return error.InvalidSurfaceGrid;
                const rows = std.math.cast(usize, args[0].int) orelse return error.InvalidSurfaceGrid;
                const columns = std.math.cast(usize, args[1].int) orelse return error.InvalidSurfaceGrid;
                if (rows < 2 or columns < 2 or args.len - 2 != rows * columns) return error.InvalidSurfaceGrid;
                const points = try self.arena.alloc(c.HuakXYZ, rows * columns);
                for (args[2..], points) |v, *p| p.xyz = try coordinates(v, false);
                out.points = points.ptr;
                out.count = points.len;
                out.args[0] = @floatFromInt(rows);
                out.args[1] = @floatFromInt(columns);
            },
            .sphere, .torus, .cylinder, .cone => {
                for (args, 0..) |v, i| out.args[i] = try convert.lengthPoints(v);
                if (node.kind == .torus and !(out.args[0] > out.args[1] and out.args[1] > 0)) return error.InvalidTorusRadii;
                if (node.kind == .cone) {
                    if (out.args[0] < 0 or out.args[1] < 0 or out.args[0] == out.args[1] or out.args[2] <= 0) return error.InvalidConeDimensions;
                } else for (out.args[0..count]) |v| {
                    if (!(v > 0)) return error.InvalidModelDimensions;
                }
            },
            .circle, .arc, .ellipse => {
                out.origin = try coordinates(args[0], false);
                out.args[0] = try convert.lengthPoints(args[1]);
                if (out.args[0] <= 0) return error.InvalidRadius;
                if (node.kind == .ellipse) {
                    out.args[1] = try convert.lengthPoints(args[2]);
                    if (out.args[1] <= 0) return error.InvalidRadius;
                } else if (node.kind == .arc) {
                    out.args[1] = try convert.angular(args[2]);
                    out.args[2] = try convert.angular(args[3]);
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
                    out.args[6] = try convert.angular(args[6]);
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
