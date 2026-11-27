//! Builtins of the pen, gradient, picture, object, text and animation
//! namespaces: pens, gradients, pictures, drawing objects, typeset-text
//! metrics and animation. See `../builtin.zig`.

pub const pen = .{
    .pen = .{ .implicit = true, .args = .{ .paint = .paint, .width = .length, .cap = .string, .join = .string, .miter_limit = .number, .dash = .list, .dash_phase = .length, .nib = .pen, .profile = .list, .motion = .list, .tolerance = .length }, .minimum = 1, .result = .pen },
    .pencircle = .{ .args = .{ .diameter = .length, .paint = .paint }, .minimum = 0, .result = .pen },
    .pensquare = .{ .args = .{ .width = .length, .paint = .paint }, .minimum = 0, .result = .pen },
    .makepen = .{ .args = .{ .outline = .path, .paint = .paint }, .minimum = 1, .result = .pen },
    .makepath = .{ .args = .{ .pen = .pen }, .minimum = 1, .result = .path },
    .penoffset = .{ .args = .{ .pen = .pen, .direction = .vec2 }, .minimum = 2, .result = .vec2 },
    .stroke_outline = .{ .args = .{ .curve = .path, .pen = .pen, .tolerance = .length }, .minimum = 2, .result = .path },
    .envelope = .{ .args = .{ .curve = .path, .pen = .pen, .tolerance = .length }, .minimum = 2, .result = .path },
    .stroke_sections = .{ .args = .{ .curve = .path, .pen = .pen, .ranges = .list, .tolerance = .length }, .minimum = 3, .result = .list },
    .profile_outline = .{ .args = .{ .curve = .path, .left = .list, .right = .list, .cap = .string, .join = .string, .miter_limit = .number, .tolerance = .length }, .minimum = 3, .result = .path },
    .stroke_path = .{ .args = .{ .curve = .path, .width = .length, .cap = .string, .join = .string, .miter_limit = .number, .tolerance = .length }, .minimum = 2, .result = .path },
};

pub const gradient = .{
    .gradient_linear = .{ .name = "linear", .args = .{ .start = .vec2, .end = .vec2, .colors = .list, .offsets = .list }, .minimum = 3, .result = .gradient },
    .gradient_radial = .{ .name = "radial", .args = .{ .center = .vec2, .radius = .length, .colors = .list, .offsets = .list }, .minimum = 3, .result = .gradient },
    .gradient_patches = .{ .name = "patches", .args = .{ .points = .list, .values = .list, .colors = .list, .levels = .list, .tolerance = .number, .margin = .length }, .minimum = 5, .result = .gradient },
    .gradient_fan = .{ .name = "fan", .args = .{ .center = .vec2, .points = .list, .values = .list, .colors = .list, .levels = .list, .tolerance = .number }, .minimum = 6, .result = .gradient },
};

pub const picture = .{
    .canvas = .{ .args = .{ .target = .picture, .width = .length, .height = .length }, .minimum = 3, .result = .unit },
    .picture = .{ .implicit = true, .args = .{ .width = .length, .height = .length, .mesh_rasterize = .boolean, .mesh_dpi = .number }, .minimum = 0, .result = .picture },
};

pub const object = .{
    .bounds = .{ .args = .{ .object = .any }, .minimum = 1, .result = .list },
    .region = .{ .args = .{ .object = .any, .tolerance = .length }, .minimum = 1, .result = .path },
    .draw = .{ .args = .{ .curve = .path, .pen = .pen, .transform = .transform }, .minimum = 1, .result = .object },
    .fill = .{ .args = .{ .curve = .path, .paint = .paint, .transform = .transform }, .minimum = 1, .result = .object },
    .filldraw = .{ .args = .{ .curve = .path, .paint = .paint, .pen = .pen, .transform = .transform }, .minimum = 3, .result = .object },
    .label = .{ .args = .{ .body = .text, .position = .vec2, .transform = .transform }, .minimum = 2, .result = .object },
    .outlines = .{ .args = .{ .object = .any }, .minimum = 1, .result = .object },
    .append = .{ .args = .{ .target = .any, .source = .object, .transform = .transform }, .minimum = 2, .result = .object },
    .snapshot = .{ .args = .{ .target = .object }, .minimum = 1, .result = .picture },
    .flatten_transparency = .{ .args = .{ .target = .object, .paper = .color }, .minimum = 1, .result = .picture },
    .object = .{ .implicit = true, .args = .{ .source = .any, .fill = .paint, .pen = .pen }, .minimum = 1, .result = .object },
    .object_clip = .{ .name = "clip", .args = .{ .target = .picture, .region = .path }, .minimum = 2, .result = .unit },
    .object_reset_clip = .{ .name = "reset_clip", .args = .{ .target = .picture }, .minimum = 1, .result = .unit },
    .object_opacity = .{ .name = "opacity", .args = .{ .target = .picture, .value = .number }, .minimum = 2, .result = .unit },
    .object_exclude = .{ .name = "exclude", .args = .{ .parent = .picture, .targets = .list, .hole = .path, .brush = .pen }, .minimum = 3, .result = .unit },
    .object_style = .{ .name = "style", .args = .{ .target = .object, .fill = .any, .pen = .any }, .minimum = 1, .result = .unit },
    .object_visible = .{ .name = "show", .args = .{ .target = .object, .visible = .boolean }, .minimum = 2, .result = .unit },
    .object_transform = .{ .name = "transform", .args = .{ .target = .object, .transform = .transform }, .minimum = 2, .result = .unit },
    .object_remove = .{ .name = "remove", .args = .{ .target = .object }, .minimum = 1, .result = .unit },
    .object_before = .{ .name = "before", .args = .{ .target = .object, .sibling = .object }, .minimum = 2, .result = .unit },
};

pub const text = .{
    .width = .{ .args = .{ .body = .text }, .minimum = 1, .result = .length },
    .height = .{ .args = .{ .body = .text }, .minimum = 1, .result = .length },
    .baseline = .{ .args = .{ .body = .text }, .minimum = 1, .result = .length },
    .anchors = .{ .args = .{ .body = .text }, .minimum = 1, .result = .dict },
};

pub const animation = .{
    .timeline = .{ .args = .{ .target = .picture, .duration = .number, .repeat = .boolean }, .minimum = 2, .result = .unit },
    .animate = .{ .args = .{ .object = .object, .property = .string, .keys = .list, .easing = .any, .phase = .number, .smil = .boolean }, .minimum = 3, .result = .unit },
    .motion = .{ .args = .{ .object = .object, .curve = .path, .keys = .list, .rotate = .string, .phase = .number, .smil = .boolean }, .minimum = 3, .result = .unit },
    .animation_snapshot = .{ .name = "snapshot", .args = .{ .target = .picture, .time = .number }, .minimum = 2, .result = .picture },
};
