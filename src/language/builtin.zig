//! Builtin names and signatures shared by the compiler and native runtime.
const std = @import("std");
const Type = @import("types.zig").Type;

/// Native API ownership. These namespaces do not load source standard modules.
pub const Namespace = enum {
    math,
    geometry,
    projection,
    color,
    pen,
    transform,
    picture,
    object,
    text,
    animation,
    solver,

    pub fn parse(value: []const u8) ?Namespace {
        return std.meta.stringToEnum(Namespace, value);
    }

    pub fn name(self: Namespace) []const u8 {
        return @tagName(self);
    }

    pub fn moduleName(self: Namespace) []const u8 {
        inline for (std.enums.values(Namespace)) |namespace| {
            if (self == namespace) return "<native:" ++ @tagName(namespace) ++ ">";
        }
        unreachable;
    }
};

pub const Id = std.meta.FieldEnum(@TypeOf(registry));
pub const Signature = struct {
    id: Id,
    name: []const u8,
    args: []const Type,
    minimum: usize,
    variadic: ?Type = null,
    parameter_names: []const []const u8 = &.{},
    result: Type,
    namespace: ?Namespace = null,
    implicit: bool = false,

    pub fn acceptsCount(self: Signature, count: usize) bool {
        return count >= self.minimum and (self.variadic != null or count <= self.args.len);
    }
};
const a = Type.any;
const n = Type.number;
const s = Type.scalar;
const length = Type.length;
const angle = Type.angle;
const p = Type.vec2;
const u = Type.unit;
const registry = .{
    .print = .{ .namespace = null, .implicit = true, .args = .{ .value = a }, .minimum = 1, .result = u },
    .panic = .{ .namespace = null, .implicit = true, .args = .{ .message = .string }, .minimum = 1, .result = u },
    .len = .{ .namespace = null, .implicit = true, .args = .{ .value = a }, .minimum = 1, .result = .int },
    .to_int = .{ .namespace = null, .implicit = true, .name = "int", .args = .{ .value = a }, .minimum = 1, .result = .int },
    .to_number = .{ .namespace = null, .implicit = true, .name = "float", .args = .{ .value = a }, .minimum = 1, .result = n },
    .to_string = .{ .namespace = null, .implicit = true, .name = "str", .args = .{ .value = a }, .minimum = 1, .result = .string },
    .sin = .{ .namespace = .math, .args = .{ .angle = angle }, .minimum = 1, .result = n },
    .cos = .{ .namespace = .math, .args = .{ .angle = angle }, .minimum = 1, .result = n },
    .tan = .{ .namespace = .math, .args = .{ .angle = angle }, .minimum = 1, .result = n },
    .sqrt = .{ .namespace = .math, .args = .{ .value = s }, .minimum = 1, .result = s },
    .log = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .log10 = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .abs = .{ .namespace = .math, .args = .{ .value = s }, .minimum = 1, .result = s },
    .floor = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .ceil = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .min = .{ .namespace = .math, .args = .{ .a = s, .b = s }, .minimum = 2, .result = s },
    .max = .{ .namespace = .math, .args = .{ .a = s, .b = s }, .minimum = 2, .result = s },
    .pow = .{ .namespace = .math, .args = .{ .base = s, .exponent = n }, .minimum = 2, .result = s },
    .atan2 = .{ .namespace = .math, .args = .{ .y = s, .x = s }, .minimum = 2, .result = angle },
    .seed = .{ .namespace = .math, .args = .{ .value = .int }, .minimum = 1, .result = u },
    .random = .{ .namespace = .math, .args = .{}, .minimum = 0, .result = n },
    .randint = .{ .namespace = .math, .args = .{ .min = .int, .max = .int }, .minimum = 2, .result = .int },
    .randn = .{ .namespace = .math, .args = .{}, .minimum = 0, .result = n },
    .gamma = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .lgamma = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .beta = .{ .namespace = .math, .args = .{ .a = n, .b = n }, .minimum = 2, .result = n },
    .erf = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .erfc = .{ .namespace = .math, .args = .{ .value = n }, .minimum = 1, .result = n },
    .vec2 = .{ .namespace = null, .implicit = true, .args = .{ .x = s, .y = s }, .minimum = 2, .result = p },
    .vec3 = .{ .namespace = null, .implicit = true, .args = .{ .x = s, .y = s, .z = s }, .minimum = 3, .result = .vec3 },
    .project_scene = .{ .namespace = .projection, .args = .{ .shapes = .list, .azimuth = angle, .elevation = angle, .focus = length, .tolerance = length, .faces = .boolean, .light = a, .spot = angle }, .minimum = 6, .result = .list },
    .model_shape = .{ .namespace = .projection, .args = .{ .kind = .string, .arguments = .list }, .minimum = 2, .result = .shape },
    .dot = .{ .namespace = .math, .args = .{ .a = .vector, .b = .vector }, .minimum = 2, .result = s },
    .norm = .{ .namespace = .math, .args = .{ .value = .vector }, .minimum = 1, .result = s },
    .unit = .{ .namespace = .math, .args = .{ .value = .vector }, .minimum = 1, .result = a },
    .lerp = .{ .namespace = .math, .args = .{ .a = .vector, .b = .vector, .t = n }, .minimum = 3, .result = a },
    .rgb = .{ .namespace = .color, .args = .{ .red = n, .green = n, .blue = n, .alpha = n }, .minimum = 3, .result = .color },
    .pen = .{ .namespace = .pen, .implicit = true, .args = .{ .color = .color, .width = length, .cap = .string, .join = .string, .miter_limit = n, .dash = .list, .dash_phase = length, .nib = .pen, .profile = .list, .motion = .list, .tolerance = length }, .minimum = 1, .result = .pen },
    .pencircle = .{ .namespace = .pen, .args = .{ .diameter = length, .color = .color }, .minimum = 0, .result = .pen },
    .pensquare = .{ .namespace = .pen, .args = .{ .width = length, .color = .color }, .minimum = 0, .result = .pen },
    .makepen = .{ .namespace = .pen, .args = .{ .outline = .path, .color = .color }, .minimum = 1, .result = .pen },
    .makepath = .{ .namespace = .pen, .args = .{ .pen = .pen }, .minimum = 1, .result = .path },
    .penoffset = .{ .namespace = .pen, .args = .{ .pen = .pen, .direction = p }, .minimum = 2, .result = p },
    .stroke_outline = .{ .namespace = .pen, .args = .{ .curve = .path, .pen = .pen, .tolerance = length }, .minimum = 2, .result = .path },
    .envelope = .{ .namespace = .pen, .args = .{ .curve = .path, .pen = .pen, .tolerance = length }, .minimum = 2, .result = .path },
    .translate = .{ .namespace = .transform, .args = .{ .offset = .vector }, .minimum = 1, .result = .transform },
    .scale = .{ .namespace = .transform, .args = .{ .x = n, .y = n, .z = n }, .minimum = 1, .result = .transform },
    .rotate = .{ .namespace = .transform, .args = .{ .angle = angle, .axis = .vec3 }, .minimum = 1, .result = .transform },
    .compose = .{ .namespace = .transform, .args = .{ .first = .transform, .second = .transform }, .minimum = 2, .result = .transform },
    .apply = .{ .namespace = .transform, .args = .{ .transform = .transform, .point = .vector }, .minimum = 2, .result = a },
    .rectangle = .{ .namespace = .geometry, .args = .{ .origin = .vector, .width = length, .height = length }, .minimum = 3, .result = .path_or_shape },
    .circle = .{ .namespace = .geometry, .args = .{ .center = .vector, .radius = length }, .minimum = 2, .result = .path_or_shape },
    .ellipse = .{ .namespace = .geometry, .args = .{ .center = .vector, .rx = length, .ry = length }, .minimum = 3, .result = .path_or_shape },
    .arc = .{ .namespace = .geometry, .args = .{ .center = .vector, .radius = length, .start = angle, .sweep = angle }, .minimum = 4, .result = .path_or_shape },
    .path = .{ .namespace = .geometry, .implicit = true, .args = .{}, .minimum = 1, .variadic = .any, .result = .path_or_shape },
    .compound = .{ .namespace = .geometry, .args = .{ .paths = .list }, .minimum = 1, .result = .path },
    .subpaths = .{ .namespace = .geometry, .args = .{ .curve = .path }, .minimum = 1, .result = .list },
    .smooth = .{ .namespace = .geometry, .args = .{ .points = .list, .closed = .boolean, .tension = n }, .minimum = 1, .result = .path },
    .bezier = .{ .namespace = .geometry, .args = .{ .start = .vector, .control1 = .vector, .control2 = .vector, .finish = .vector }, .minimum = 4, .result = .path_or_shape },
    .reverse = .{ .namespace = .geometry, .args = .{ .curve = .path_or_shape }, .minimum = 1, .result = .path_or_shape },
    .closed = .{ .namespace = .geometry, .args = .{ .curve = .path_or_shape }, .minimum = 1, .result = .path_or_shape },
    .transformed = .{ .namespace = .transform, .args = .{ .object = a, .transform = .transform }, .minimum = 2, .result = a },
    .mapped = .{ .namespace = .transform, .args = .{ .object = a, .mapping = a, .context = a, .tolerance = length }, .minimum = 2, .result = a },
    .bent = .{ .namespace = .transform, .args = .{ .object = a, .guide = .path, .offset = length, .tolerance = length }, .minimum = 2, .result = a },
    .matrix = .{ .namespace = .transform, .args = .{ .a = n, .b = n, .c = n, .d = n, .e = length, .f = length }, .minimum = 6, .result = .transform },
    .measure = .{ .namespace = .geometry, .args = .{ .curve = .path, .tolerance = length }, .minimum = 1, .result = .measure },
    .joined = .{ .namespace = .geometry, .args = .{ .first = .path_or_shape, .second = .path_or_shape }, .minimum = 2, .result = .path_or_shape },
    .trimmed = .{ .namespace = .geometry, .args = .{ .curve = .path, .start = n, .stop = n }, .minimum = 3, .result = .path },
    .point_at = .{ .namespace = .geometry, .args = .{ .curve = .path, .time = n }, .minimum = 2, .result = p },
    .tangent_at = .{ .namespace = .geometry, .args = .{ .curve = .path, .time = n }, .minimum = 2, .result = p },
    .arclength = .{ .namespace = .geometry, .args = .{ .curve = a, .tolerance = length }, .minimum = 1, .result = length },
    .sample_path = .{ .namespace = .geometry, .args = .{ .curve = a, .count = .int, .tolerance = length }, .minimum = 2, .result = .list },
    .sample_at_length = .{ .namespace = .geometry, .args = .{ .curve = a, .distance = length, .tolerance = length }, .minimum = 2, .result = .list },
    .sample_at_fraction = .{ .namespace = .geometry, .args = .{ .curve = a, .fraction = n, .tolerance = length }, .minimum = 2, .result = .list },
    .samples_at_length = .{ .namespace = .geometry, .args = .{ .curve = a, .distances = .list, .tolerance = length }, .minimum = 2, .result = .list },
    .path_crossings = .{ .namespace = .geometry, .args = .{ .curves = .list, .tolerance = length }, .minimum = 1, .result = .list },
    .stroke_sections = .{ .namespace = .pen, .args = .{ .curve = .path, .pen = .pen, .ranges = .list, .tolerance = length }, .minimum = 3, .result = .list },
    .profile_outline = .{ .namespace = .pen, .args = .{ .curve = .path, .left = .list, .right = .list, .cap = .string, .join = .string, .miter_limit = n, .tolerance = length }, .minimum = 3, .result = .path },
    .bounds = .{ .namespace = .object, .args = .{ .object = a }, .minimum = 1, .result = .list },
    .intersections = .{ .namespace = .geometry, .args = .{ .first = .path, .second = .path, .tolerance = length }, .minimum = 2, .result = .list },
    .intersection_times = .{ .namespace = .geometry, .args = .{ .first = .path, .second = .path, .tolerance = length }, .minimum = 2, .result = .list },
    .clipped = .{ .namespace = .geometry, .args = .{ .curve = .path, .min = p, .max = p }, .minimum = 3, .result = .path },
    .region = .{ .namespace = .object, .args = .{ .object = a, .tolerance = length }, .minimum = 1, .result = .path },
    .region_union = .{ .namespace = .geometry, .args = .{ .first = .path_or_shape, .second = .path_or_shape, .tolerance = length, .fill_rule = .string }, .minimum = 2, .result = .path_or_shape },
    .region_intersection = .{ .namespace = .geometry, .args = .{ .first = .path_or_shape, .second = .path_or_shape, .tolerance = length, .fill_rule = .string }, .minimum = 2, .result = .path_or_shape },
    .region_difference = .{ .namespace = .geometry, .args = .{ .first = .path_or_shape, .second = .path_or_shape, .tolerance = length, .fill_rule = .string }, .minimum = 2, .result = .path_or_shape },
    .region_xor = .{ .namespace = .geometry, .args = .{ .first = .path, .second = .path, .tolerance = length, .fill_rule = .string }, .minimum = 2, .result = .path },
    .offset = .{ .namespace = .geometry, .args = .{ .curve = .path, .distance = length, .join = .string, .miter_limit = n, .tolerance = length, .fill_rule = .string }, .minimum = 2, .result = .path },
    .stroke_path = .{ .namespace = .pen, .args = .{ .curve = .path, .width = length, .cap = .string, .join = .string, .miter_limit = n, .tolerance = length }, .minimum = 2, .result = .path },
    .clip_region = .{ .namespace = .geometry, .args = .{ .curve = .path, .min = p, .max = p, .tolerance = length, .fill_rule = .string }, .minimum = 3, .result = .path },
    .clip_lines = .{ .namespace = .geometry, .args = .{ .curve = .path, .min = p, .max = p, .tolerance = length }, .minimum = 3, .result = .path },
    .canvas = .{ .namespace = .picture, .args = .{ .target = .picture, .width = length, .height = length }, .minimum = 3, .result = u },
    .draw = .{ .namespace = .object, .args = .{ .curve = .path, .pen = .pen, .transform = .transform }, .minimum = 1, .result = .object },
    .fill = .{ .namespace = .object, .args = .{ .curve = .path, .color = .color, .transform = .transform }, .minimum = 1, .result = .object },
    .linear_stroke = .{ .namespace = .object, .args = .{ .curve = .path, .start = p, .end = p, .colors = .list, .brush = .pen }, .minimum = 5, .result = .object },
    .linear_fill = .{ .namespace = .object, .args = .{ .curve = .path, .start = p, .end = p, .colors = .list }, .minimum = 4, .result = .object },
    .radial_fill = .{ .namespace = .object, .args = .{ .curve = .path, .center = p, .radius = length, .inner = .color, .outer = .color }, .minimum = 5, .result = .object },
    .filldraw = .{ .namespace = .object, .args = .{ .curve = .path, .color = .color, .pen = .pen, .transform = .transform }, .minimum = 3, .result = .object },
    .label = .{ .namespace = .object, .args = .{ .body = .text, .position = p, .transform = .transform }, .minimum = 2, .result = .object },
    .width = .{ .namespace = .text, .args = .{ .body = .text }, .minimum = 1, .result = length },
    .height = .{ .namespace = .text, .args = .{ .body = .text }, .minimum = 1, .result = length },
    .baseline = .{ .namespace = .text, .args = .{ .body = .text }, .minimum = 1, .result = length },
    .outlines = .{ .namespace = .object, .args = .{ .object = a }, .minimum = 1, .result = .object },
    .solver = .{ .namespace = .solver, .implicit = true, .args = .{}, .minimum = 0, .result = .solver },
    .unknown = .{ .namespace = .solver, .args = .{ .solver = .solver }, .minimum = 1, .result = .variable },
    .equation = .{ .namespace = .solver, .args = .{ .solver = .solver, .left = a, .right = a }, .minimum = 3, .result = u },
    .solve = .{ .namespace = .solver, .args = .{ .solver = .solver }, .minimum = 1, .result = .solution },
    .value = .{ .namespace = .solver, .args = .{ .solution = .solution, .variable = .variable }, .minimum = 2, .result = n },
    .picture = .{ .namespace = .picture, .implicit = true, .args = .{ .width = length, .height = length, .transform = .transform, .clip = .path }, .minimum = 0, .result = .picture },
    .append = .{ .namespace = .object, .args = .{ .target = a, .source = .object, .transform = .transform }, .minimum = 2, .result = .object },
    .snapshot = .{ .namespace = .object, .args = .{ .target = .object }, .minimum = 1, .result = .picture },
    .object = .{ .namespace = .object, .implicit = true, .args = .{ .source = a, .fill = .color, .pen = .pen }, .minimum = 1, .result = .object },
    .object_clip = .{ .namespace = .object, .name = "clipped", .args = .{ .target = .object, .clip = .path }, .minimum = 2, .result = .picture },
    .object_exclude = .{ .namespace = .object, .name = "exclude", .args = .{ .parent = .picture, .targets = .list, .hole = .path }, .minimum = 3, .result = u },
    .object_style = .{ .namespace = .object, .name = "style", .args = .{ .target = .object, .fill = a, .pen = a }, .minimum = 1, .result = u },
    .object_visible = .{ .namespace = .object, .name = "show", .args = .{ .target = .object, .visible = .boolean }, .minimum = 2, .result = u },
    .object_transform = .{ .namespace = .object, .name = "transform", .args = .{ .target = .object, .transform = .transform }, .minimum = 2, .result = u },
    .object_remove = .{ .namespace = .object, .name = "remove", .args = .{ .target = .object }, .minimum = 1, .result = u },
    .object_before = .{ .namespace = .object, .name = "before", .args = .{ .target = .object, .sibling = .object }, .minimum = 2, .result = u },
    .timeline = .{ .namespace = .animation, .args = .{ .target = .picture, .duration = n, .repeat = .boolean }, .minimum = 2, .result = u },
    .animate = .{ .namespace = .animation, .args = .{ .object = .object, .property = .string, .keys = .list, .easing = .string }, .minimum = 3, .result = u },
    .motion = .{ .namespace = .animation, .args = .{ .object = .object, .curve = .path, .keys = .list, .rotate = .string }, .minimum = 3, .result = u },
    .dict_contains = .{ .namespace = null, .implicit = true, .args = .{ .dictionary = .dict, .key = .string }, .minimum = 2, .result = .boolean },
    .dict_remove = .{ .namespace = null, .implicit = true, .args = .{ .dictionary = .dict, .key = .string }, .minimum = 2, .result = .boolean },
    .dict_keys = .{ .name = "keys", .namespace = null, .implicit = true, .args = .{ .dictionary = .dict }, .minimum = 1, .result = .list },
    .copy = .{ .namespace = null, .implicit = true, .args = .{ .value = a }, .minimum = 1, .result = a },
    .contour_ranges = .{ .namespace = .geometry, .args = .{ .curve = .path }, .minimum = 1, .result = .list },
};

fn buildSignature(comptime name: [:0]const u8) Signature {
    const entry = @field(registry, name);
    const Parameters = struct {
        const fields_ = std.meta.fieldNames(@TypeOf(entry.args));
        const data: struct { kinds: [fields_.len]Type, names: [fields_.len][]const u8 } = data: {
            var kinds: [fields_.len]Type = undefined;
            var names: [fields_.len][]const u8 = undefined;
            for (fields_, 0..) |parameter, i| {
                kinds[i] = @field(entry.args, parameter);
                names[i] = parameter;
            }
            break :data .{ .kinds = kinds, .names = names };
        };
    };
    return .{
        .id = @field(Id, name),
        .name = if (@hasField(@TypeOf(entry), "name")) entry.name else name,
        .args = &Parameters.data.kinds,
        .minimum = entry.minimum,
        .variadic = if (@hasField(@TypeOf(entry), "variadic")) entry.variadic else null,
        .parameter_names = &Parameters.data.names,
        .result = entry.result,
        .namespace = entry.namespace,
        .implicit = if (@hasField(@TypeOf(entry), "implicit")) entry.implicit else false,
    };
}

/// The declaration order defines local bytecode IDs and public iteration order.
pub const signatures = build: {
    @setEvalBranchQuota(10000);
    const fields = std.meta.fieldNames(@TypeOf(registry));
    var result: [fields.len]Signature = undefined;
    for (fields, 0..) |name, index| result[index] = buildSignature(name);
    break :build result;
};

pub fn lookup(name: []const u8) ?Signature {
    for (signatures) |item| if (std.mem.eql(u8, name, item.name)) return item;
    return null;
}

/// Canonical identities use registry IDs, independent of public names shared
/// by different native namespaces.
pub fn identity(name: []const u8) ?Signature {
    return signature(std.meta.stringToEnum(Id, name) orelse return null);
}

/// Data/diagnostic primitives and primary type constructors form the prelude.
pub fn isImplicit(id: Id) bool {
    return signature(id).implicit;
}

pub fn implicit(name: []const u8) ?Signature {
    const found = lookup(name) orelse return null;
    return if (found.implicit) found else null;
}

pub fn namespaceOf(id: Id) ?Namespace {
    return signature(id).namespace;
}

pub fn namespaceLookup(namespace: Namespace, name: []const u8) ?Signature {
    for (signatures) |item| if (item.namespace == namespace and std.mem.eql(u8, name, item.name)) return item;
    return null;
}

/// A primary type name can construct values and expose its native operations.
/// An unrelated module alias must never revive the default constructor.
pub fn namespaceConstructor(namespace: Namespace, name: []const u8) ?Signature {
    if (!std.mem.eql(u8, namespace.name(), name)) return null;
    const found = implicit(name) orelse return null;
    return if (found.namespace == namespace) found else null;
}

pub fn constantNames(namespace: Namespace) []const []const u8 {
    return if (namespace == .math) &.{ "PI", "TAU", "E" } else &.{};
}

pub fn namespaceConstant(namespace: Namespace, name: []const u8) ?@import("types.zig").Value {
    if (namespace != .math) return null;
    const value: f64 = if (std.mem.eql(u8, name, "PI")) std.math.pi else if (std.mem.eql(u8, name, "TAU")) 2 * std.math.pi else if (std.mem.eql(u8, name, "E")) std.math.e else return null;
    return .{ .number = value };
}

pub fn signature(id: Id) Signature {
    return signatures[@backingInt(id)];
}

test "native parameter names form a complete unique signature" {
    for (signatures) |item| {
        try std.testing.expectEqualDeep(item, signature(item.id));
        try std.testing.expectEqual(item.namespace, namespaceOf(item.id));
        try std.testing.expectEqual(item.implicit, isImplicit(item.id));
        try std.testing.expectEqual(item.args.len, item.parameter_names.len);
        for (item.parameter_names, 0..) |name, index| {
            try std.testing.expect(name.len != 0);
            for (item.parameter_names[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, name, previous));
        }
    }
}
