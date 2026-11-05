//! Parameter ordering shared by execution and conservative effect analysis.
const std = @import("std");

/// A bound argument names its fixed parameter; variadic entries are positional.
/// New named arguments replace bound values, while new positional arguments
/// occupy the remaining slots. Duplicate arguments within one call are errors.
pub fn bind(comptime T: type, allocator: std.mem.Allocator, parameters: []const []const u8, variadic: bool, prior: []const T, prior_names: []const ?[]const u8, incoming: []const T, names: []const ?[]const u8) ![]?T {
    if (prior.len != prior_names.len or (names.len != 0 and names.len != incoming.len)) return error.InvalidArguments;
    const result = try allocator.alloc(?T, @max(parameters.len, prior.len + incoming.len));
    errdefer allocator.free(result);
    @memset(result, null);
    const supplied = try allocator.alloc(bool, result.len);
    defer allocator.free(supplied);
    @memset(supplied, false);
    var positional: usize = 0;
    for (prior, prior_names) |value, name| {
        const slot = if (name) |label| try parameter(parameters, label) else blk: {
            const index = parameters.len + positional;
            positional += 1;
            break :blk index;
        };
        if (slot >= result.len or (!variadic and slot >= parameters.len) or result[slot] != null) return error.InvalidArguments;
        result[slot] = value;
    }
    positional = 0;
    for (incoming, 0..) |value, i| {
        const name = if (names.len == 0) null else names[i];
        const slot = if (name) |label| try parameter(parameters, label) else blk: {
            if (prior.len != 0) while (positional < result.len and result[positional] != null) : (positional += 1) {};
            const index = positional;
            positional += 1;
            break :blk index;
        };
        if (slot >= result.len or (!variadic and slot >= parameters.len)) return error.TooManyArguments;
        if (supplied[slot]) return error.DuplicateArgument;
        result[slot] = value;
        supplied[slot] = true;
    }
    return result;
}

fn parameter(names: []const []const u8, label: []const u8) !usize {
    for (names, 0..) |name, i| if (std.mem.eql(u8, name, label)) return i;
    return error.UnknownArgument;
}
