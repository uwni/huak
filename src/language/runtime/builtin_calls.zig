//! Builtin calls from the VM: the host entry, positional arguments read by name, and the router that sends each builtin to the family implementing it.
const std = @import("std");
const Machine = @import("../Machine.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const Value = types.Value;
const Model = @import("model.zig");
const Runtime = @import("../Runtime.zig");
const transforms = @import("transforms.zig");
const paths = @import("paths.zig");
const conversions = @import("conversions.zig");
const outlines = @import("outlines.zig");
const formatting = @import("formatting.zig");
const paints = @import("paints.zig");
const pen = @import("pen.zig");
const path_queries = @import("path_queries.zig");
const region_builtins = @import("regions.zig");
const pictures = @import("pictures.zig");
const animation = @import("animation.zig");
const typeset_text = @import("typeset_text.zig");
const solver = @import("solver.zig");
const math = @import("math.zig");
const from = Runtime.from;
const string = conversions.string;
const sequence = conversions.sequence;

pub fn call(ctx: ?*anyopaque, a: std.mem.Allocator, id: builtin.Id, args: []const Value, machine: ?*Machine) anyerror!Value {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    self.native_message = "";
    if (id == .mapped) return transforms.mapObject(self, machine orelse return error.CallbackUnavailable, args);
    // A projection may call the script's field back.
    if (id == .project_scene) return @import("projection.zig").project(self, a, builtin.arguments(.project_scene, args), machine);
    return invoke(self, a, id, args);
}

pub fn invoke(self: *Runtime, a: std.mem.Allocator, id: builtin.Id, args: []const Value) !Value {
    return switch (id) {
        // A path's points have no parameter names.
        .path => paths.pathFromPoints(self, args),
        inline else => |tag| invokeNamed(self, a, tag, builtin.arguments(tag, args)),
    };
}

/// One builtin call, its arguments read by parameter name.
/// Every builtin goes to the family that implements it; one without a
/// family does not compile.
fn invokeNamed(self: *Runtime, a: std.mem.Allocator, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .path => unreachable,
        .project_scene => return @import("projection.zig").project(self, a, arg, null),
        .model_shape => return conversions.modelResult(self, std.meta.stringToEnum(Model.Kind, try string(arg.kind)) orelse return error.InvalidModelShape, try sequence(arg.arguments)),
        .panic, .dict_contains, .dict_remove, .dict_keys, .seed, .random, .randint, .randn => return error.InvalidBuiltin,
        .outlines => return outlines.extractOutlines(self, arg.object),
        .print, .to_int, .to_number, .to_string => return formatting.invoke(self, a, id, arg),
        .sin, .cos, .tan, .gamma, .lgamma, .beta, .erf, .erfc, .sqrt, .abs, .log, .log10, .floor, .ceil, .round, .min, .max, .pow, .atan2, .vec2, .vec3, .dot, .norm, .unit, .lerp => return math.invoke(id, arg),
        .rgb, .gradient_linear, .gradient_radial, .gradient_patches, .gradient_fan => return paints.invoke(self, id, arg),
        .pen, .pencircle, .pensquare, .makepen, .makepath, .penoffset, .envelope, .stroke_outline, .stroke_sections => return pen.invoke(self, a, id, arg),
        .matrix, .translate, .scale, .rotate, .compose, .apply, .mapped, .bent, .transformed => return transforms.invoke(self, id, arg),
        .len, .bezier, .rectangle, .circle, .ellipse, .arc, .smooth, .compound, .contour_ranges, .subpaths, .reverse, .closed, .joined, .trimmed, .clipped, .fillet => return paths.invoke(self, a, id, arg),
        .measure, .point_at, .tangent_at, .arclength, .signed_area, .sample_path, .sample_at_length, .sample_at_fraction, .samples_at_length, .bounds, .intersections, .intersection_times, .path_crossings => return path_queries.invoke(self, a, id, arg),
        .profile_outline, .region, .region_union, .region_intersection, .region_difference, .region_xor, .offset, .stroke_path, .clip_region, .clip_lines => return region_builtins.invoke(self, id, arg),
        .object_transform, .object_remove, .object_before, .object_style, .object_visible, .object_clip, .object_reset_clip, .object_opacity, .copy, .object_exclude, .snapshot, .flatten_transparency, .canvas, .append, .draw, .fill, .filldraw, .label, .object, .picture => return pictures.invoke(self, id, arg),
        .timeline, .animate, .motion, .animation_snapshot => return animation.invoke(self, id, arg),
        .anchors, .width, .height, .baseline => return typeset_text.invoke(self, id, arg),
        .solver, .unknown, .equation, .solve, .value => return solver.invoke(self, id, arg),
    }
}
