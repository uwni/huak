//! Builtins over plain values: the prelude, and the math, color and solver
//! namespaces. Each table is named after its namespace; see `../builtin.zig`.

/// Outside every namespace: diagnostics, conversions, vectors, dictionary
/// operations and copies.
pub const prelude = .{
    .print = .{ .implicit = true, .args = .{ .value = .any }, .minimum = 1, .result = .unit },
    .panic = .{ .implicit = true, .args = .{ .message = .string }, .minimum = 1, .result = .unit },
    .len = .{ .implicit = true, .args = .{ .value = .any }, .minimum = 1, .result = .int },
    .to_int = .{ .implicit = true, .name = "int", .args = .{ .value = .any }, .minimum = 1, .result = .int },
    .to_number = .{ .implicit = true, .name = "float", .args = .{ .value = .any }, .minimum = 1, .result = .number },
    .to_string = .{ .implicit = true, .name = "str", .args = .{ .value = .any }, .minimum = 1, .result = .string },
    .vec2 = .{ .implicit = true, .args = .{ .x = .scalar, .y = .scalar }, .minimum = 2, .result = .vec2 },
    .vec3 = .{ .implicit = true, .args = .{ .x = .scalar, .y = .scalar, .z = .scalar }, .minimum = 3, .result = .vec3 },
    .dict_contains = .{ .implicit = true, .args = .{ .dictionary = .dict, .key = .string }, .minimum = 2, .result = .boolean },
    .dict_remove = .{ .implicit = true, .args = .{ .dictionary = .dict, .key = .string }, .minimum = 2, .result = .boolean },
    .dict_keys = .{ .name = "keys", .implicit = true, .args = .{ .dictionary = .dict }, .minimum = 1, .result = .list },
    .copy = .{ .implicit = true, .args = .{ .value = .any }, .minimum = 1, .result = .any },
};

pub const math = .{
    .sin = .{ .args = .{ .angle = .angle }, .minimum = 1, .result = .number },
    .cos = .{ .args = .{ .angle = .angle }, .minimum = 1, .result = .number },
    .tan = .{ .args = .{ .angle = .angle }, .minimum = 1, .result = .number },
    .sqrt = .{ .args = .{ .value = .scalar }, .minimum = 1, .result = .scalar },
    .log = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .log10 = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .abs = .{ .args = .{ .value = .scalar }, .minimum = 1, .result = .scalar },
    .floor = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .ceil = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .round = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .min = .{ .args = .{ .a = .scalar, .b = .scalar }, .minimum = 2, .result = .scalar },
    .max = .{ .args = .{ .a = .scalar, .b = .scalar }, .minimum = 2, .result = .scalar },
    .pow = .{ .args = .{ .base = .scalar, .exponent = .number }, .minimum = 2, .result = .scalar },
    .atan2 = .{ .args = .{ .y = .scalar, .x = .scalar }, .minimum = 2, .result = .angle },
    .seed = .{ .args = .{ .value = .int }, .minimum = 1, .result = .unit },
    .random = .{ .args = .{}, .minimum = 0, .result = .number },
    .randint = .{ .args = .{ .min = .int, .max = .int }, .minimum = 2, .result = .int },
    .randn = .{ .args = .{}, .minimum = 0, .result = .number },
    .gamma = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .lgamma = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .beta = .{ .args = .{ .a = .number, .b = .number }, .minimum = 2, .result = .number },
    .erf = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .erfc = .{ .args = .{ .value = .number }, .minimum = 1, .result = .number },
    .dot = .{ .args = .{ .a = .vector, .b = .vector }, .minimum = 2, .result = .scalar },
    .norm = .{ .args = .{ .value = .vector }, .minimum = 1, .result = .scalar },
    .unit = .{ .args = .{ .value = .vector }, .minimum = 1, .result = .any },
    .lerp = .{ .args = .{ .a = .vector, .b = .vector, .t = .number }, .minimum = 3, .result = .any },
};

pub const color = .{
    .rgb = .{ .args = .{ .red = .number, .green = .number, .blue = .number, .alpha = .number }, .minimum = 3, .result = .color },
};

pub const solver = .{
    .solver = .{ .implicit = true, .args = .{}, .minimum = 0, .result = .solver },
    .unknown = .{ .args = .{ .solver = .solver }, .minimum = 1, .result = .variable },
    .equation = .{ .args = .{ .solver = .solver, .left = .any, .right = .any }, .minimum = 3, .result = .unit },
    .solve = .{ .args = .{ .solver = .solver }, .minimum = 1, .result = .solution },
    .value = .{ .args = .{ .solution = .solution, .variable = .variable }, .minimum = 2, .result = .number },
};
