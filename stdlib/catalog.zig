//! Bundled Huak source modules. They use the same compiler as user modules.
const std = @import("std");
pub const Module = struct { name: []const u8, source: []const u8, aliases: []const []const u8 = &.{} };
pub const modules = [_]Module{
    .{ .name = "std/std.huak", .source = @embedFile("std.huak"), .aliases = &.{"std"} },
    .{ .name = "std/assertions.huak", .source = @embedFile("assertions.huak"), .aliases = &.{"assertions"} },
    .{ .name = "std/collections.huak", .source = @embedFile("collections.huak"), .aliases = &.{"collections"} },
    .{ .name = "std/paint.huak", .source = @embedFile("paint.huak"), .aliases = &.{"paint"} },
    .{ .name = "std/drawing.huak", .source = @embedFile("drawing.huak"), .aliases = &.{"drawing"} },
    .{ .name = "std/brush.huak", .source = @embedFile("brush.huak"), .aliases = &.{"brush"} },
    .{ .name = "std/engraving.huak", .source = @embedFile("engraving.huak"), .aliases = &.{"engraving"} },
    .{ .name = "std/weave.huak", .source = @embedFile("weave.huak"), .aliases = &.{"weave"} },
    .{ .name = "std/weave/analysis.huak", .source = @embedFile("weave/analysis.huak") },
    .{ .name = "std/weave/render.huak", .source = @embedFile("weave/render.huak") },
};

/// Aliases retain the canonical module identity, including initialization.
pub fn resolve(name: []const u8) ?Module {
    for (modules) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
        for (entry.aliases) |alias| if (std.mem.eql(u8, name, alias)) return entry;
    }
    return null;
}

pub fn source(name: []const u8) ?[]const u8 {
    return if (resolve(name)) |entry| entry.source else null;
}

test "standard aliases retain canonical source identity" {
    try std.testing.expectEqualStrings("std/paint.huak", resolve("paint").?.name);
    try std.testing.expectEqualStrings("std/std.huak", resolve("std").?.name);
    try std.testing.expect(resolve("math") == null);
    try std.testing.expect(resolve("std/math.huak") == null);
    try std.testing.expectEqualStrings("std/drawing.huak", resolve("drawing").?.name);
    try std.testing.expectEqualStrings("std/collections.huak", resolve("collections").?.name);
    try std.testing.expectEqualStrings("std/assertions.huak", resolve("assertions").?.name);
    try std.testing.expectEqualStrings(source("std/paint.huak").?, source("paint").?);
    for (modules) |entry| {
        for (entry.aliases) |alias| {
            try std.testing.expectEqualStrings(entry.name, resolve(alias).?.name);
            try std.testing.expectEqualStrings(entry.source, source(alias).?);
        }
    }
    try std.testing.expect(resolve("missing") == null);
}
