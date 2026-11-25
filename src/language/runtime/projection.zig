//! Convert one complete model for OCCT and its projection back. Inputs and
//! kernel output are scratch; only ordinary 2D paths, line metadata and the
//! smooth fields computed here survive the projection.
const std = @import("std");
const Runtime = @import("../Runtime.zig");
const Machine = @import("../Machine.zig");
const convert = @import("conversions.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Path = @import("../../drawing/path/Path.zig");
const c = @import("space_c");
const shading = @import("../../drawing/space/shading.zig");
const Model = @import("../../drawing/space/Model.zig");
const linework = @import("../../drawing/space/linework.zig");
const Value = types.Value;

pub const Graph = @import("projection/Graph.zig");
pub const fields = @import("projection/fields.zig");

fn point(p: c.HuakXY) Path.Point {
    return .{ .x = p.x, .y = p.y };
}

fn projectedPath(rt: *Runtime, commands: []const c.HuakPathCommand) !Value {
    const projected = projected: {
        var path = Path.init(rt.gpa);
        errdefer path.deinit();
        try path.segments.ensureTotalCapacityPrecise(path.allocator, commands.len);
        for (commands) |command| switch (command.op) {
            c.HUAK_MOVE => try path.moveTo(point(command.p[0])),
            c.HUAK_LINE => try path.lineTo(point(command.p[0])),
            c.HUAK_BEZIER => try path.cubicTo(point(command.p[0]), point(command.p[1]), point(command.p[2])),
            c.HUAK_CLOSE => try path.close(),
            else => unreachable,
        };
        break :projected path;
    };
    return rt.pathResult(projected);
}

fn failure(rt: *Runtime, err: Model.Error, message: *const Model.Message) error{ ProjectionFailed, OutOfMemory } {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    rt.setMessage(std.mem.sliceTo(message, 0));
    return error.ProjectionFailed;
}

/// `machine` runs the script's field; without one a field cannot be
/// projected.
pub fn project(rt: *Runtime, output: std.mem.Allocator, arg: builtin.Arguments(.project_scene), machine: ?*Machine) !Value {
    const backend = rt.backends.projection orelse {
        rt.native_message = "3D projection is unavailable: no compatible OCCT projection backend is loaded";
        return error.ProjectionUnavailable;
    };
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = types.sequence(arg.shapes) orelse return error.TypeMismatch;
    var graph: Graph = .{ .rt = rt, .arena = scratch };
    const roots = try scratch.alloc(usize, input.len);
    for (input, roots) |v, *id| id.* = try graph.add(v, 0);
    const camera: linework.Camera = .{ .azimuth = try convert.angular(arg.azimuth), .elevation = try convert.angular(arg.elevation), .focus = try convert.lengthPoints(arg.focus) };
    const tolerance = try convert.lengthPoints(arg.tolerance);
    if (camera.focus < 0 or tolerance <= 0) return error.InvalidProjection;
    if (arg.faces != .boolean) return error.TypeMismatch;
    const spot = try convert.angular(arg.spot);
    if (!(spot >= 0 and spot < std.math.pi / 2.0)) return error.InvalidHighlightAngle;
    var script: ?fields.ScriptField = null;
    var field_tolerance: f64 = 0;
    if (arg.field) |given| if (!(given == .boolean and !given.boolean)) {
        if (given != .function) return error.TypeMismatch;
        field_tolerance = try convert.numeric(arg.field_tolerance orelse return error.FieldRequiresTolerance);
        if (!(field_tolerance > 0 and std.math.isFinite(field_tolerance))) return error.InvalidFieldTolerance;
        script = .{ .machine = machine orelse return error.CallbackUnavailable, .function = given };
    };
    const smooth_light = if (arg.smooth) |given| given == .boolean and given.boolean else false;
    // A field varies within regions, as smooth light does; bands cannot hold it.
    const smooth = smooth_light or script != null;
    var light: ?linework.Light = null;
    if (!(arg.light == .boolean and !arg.light.boolean)) {
        const d = try Graph.coordinates(arg.light, true);
        const scale = @max(@abs(d[0]), @abs(d[1]), @abs(d[2]));
        if (scale == 0) return error.InvalidLightDirection;
        const levels = types.sequence(arg.isophotes) orelse return error.TypeMismatch;
        if (levels.len == 0) return error.InvalidIsophotes;
        const thresholds = try scratch.alloc(f64, levels.len);
        for (levels, thresholds, 0..) |value, *threshold, i| {
            threshold.* = try convert.numeric(value);
            if (!(threshold.* >= 0 and threshold.* < 1) or
                (if (i == 0) threshold.* != 0 else threshold.* <= thresholds[i - 1])) return error.InvalidIsophotes;
        }
        light = .{ .direction = .{ d[0] / scale, d[1] / scale, d[2] / scale }, .spot = spot, .isophotes = thresholds };
        if (script != null and !smooth_light) return error.FieldRequiresSmoothLight;
    } else if (spot != 0) return error.HighlightRequiresLight else if (smooth_light) return error.SmoothShadingRequiresLight;
    var message: Model.Message = @splat(0);
    var model = Model.build(scratch, backend, graph.nodes.items, roots, tolerance, &message) catch |err| return failure(rt, err, &message);
    defer model.deinit(scratch);
    var view = linework.view(&model, scratch, camera) catch |err| return failure(rt, err, &message);
    defer view.deinit();
    const work = linework.project(scratch, &view, .{ .faces = arg.faces.boolean, .light = light, .tolerance = tolerance, .smooth = smooth }) catch |err| return failure(rt, err, &message);
    const face_fields = try scratch.alloc(shading.Field, work.faces.items.len);
    @memset(face_fields, .none);
    var shaded: shading.Output = .{};
    var step: f64 = if (arg.field_step) |given| try convert.lengthPoints(given) else 0;
    if (!(step >= 0 and std.math.isFinite(step))) return error.InvalidFieldStep;
    // By default the field is sampled 32 times across what the faces cover.
    if (step == 0) step = fields.pageExtent(&work) / 32;
    if (step == 0) step = std.math.inf(f64);
    const scalar: ?shading.Scalar = if (script) |*f| .{ .sampler = f.sampler(), .tolerance = field_tolerance, .step = step } else null;
    if (smooth) fields.shade(scratch, &view, &work, light, tolerance, scalar, face_fields, &shaded) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SurfaceQueryFailed => return failure(rt, error.ProjectionFailed, &message),
        // The script's own error, with the VM's diagnostic.
        error.FieldFailed => return script.?.failure.?,
        error.ShadingLimit => {
            rt.setMessage("shading patches exceed the limit");
            return error.ProjectionFailed;
        },
        error.FieldLimit => {
            rt.setMessage("the field strays from the finest patches by more than field_tolerance");
            return error.ProjectionFailed;
        },
        error.UndefinedNormal => {
            rt.setMessage("undefined surface normal at shading sample");
            return error.ProjectionFailed;
        },
    };
    const commands = work.commands.items;
    var layer_count: usize = 0;
    const result = try output.alloc(Value, work.lines.items.len);
    for (result, work.lines.items) |*row, line| {
        const path = try projectedPath(rt, commands[line.start..][0..line.count]);
        layer_count = @max(layer_count, line.covering + 1);
        row.* = types.listView(try output.dupe(Value, &.{ path, .{ .int = @intCast(line.source) }, .{ .string = @tagName(line.kind) }, .{ .int = @intCast(line.covering) }, .{ .int = line.other } }));
    }
    const faces = try output.alloc(Value, work.faces.items.len);
    for (faces, work.faces.items, face_fields) |*row, face, field| {
        const path = try projectedPath(rt, commands[face.start..][0..face.count]);
        layer_count = @max(layer_count, face.covering + 1);
        const spot_path: Value = if (face.spot_count == 0)
            .{ .boolean = false }
        else if (face.spot_start == face.start and face.spot_count == face.count)
            path
        else
            try projectedPath(rt, commands[face.spot_start..][0..face.spot_count]);
        const lobes = try output.alloc(Value, face.lobe_count);
        for (lobes, work.lobes.items[face.lobe_start..][0..face.lobe_count]) |*lobe, ellipse| {
            lobe.* = types.listView(try output.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(ellipse.center) }, .{ .vec2 = .{ .x = ellipse.u.x, .y = ellipse.u.y } }, .{ .vec2 = .{ .x = ellipse.v.x, .y = ellipse.v.y } } }));
        }
        const shades = try output.alloc(Value, face.shade_count);
        for (shades, work.shades.items[face.shade_start..][0..face.shade_count]) |*shade_value, band| {
            const region = if (band.start == face.start and band.count == face.count) path else try projectedPath(rt, commands[band.start..][0..band.count]);
            shade_value.* = types.listView(try output.dupe(Value, &.{ region, .{ .number = band.diffuse } }));
        }
        row.* = types.listView(try output.dupe(Value, &.{ path, .{ .int = @intCast(face.source) }, .{ .int = @intCast(face.face) }, .{ .int = @intCast(face.covering) }, types.listView(shades), spot_path, types.listView(lobes), try fields.fieldValue(output, &shaded, field, tolerance, light != null, if (script != null) field_tolerance else null) }));
    }
    return types.listView(try output.dupe(Value, &.{ types.listView(result), types.listView(faces), .{ .int = if (arg.faces.boolean) @intCast(layer_count) else 0 } }));
}
