//! Tests of texts under translucency: refused in a layer, and repeated as glyphs in the translucent paint's colors.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const transparency = @import("../transparency.zig");
const fixtures = @import("testing.zig");
const rectangle = fixtures.rectangle;
const flatten = transparency.flatten;
const expectOpaque = fixtures.expectOpaque;
const paths = fixtures.paths;

test "a text in a layer is refused, and a text under translucency needs its glyphs" {
    const a = testing.allocator;
    var veil = try rectangle(a, 0, 0, 10, 10);
    defer veil.deinit();
    var layered = DisplayList.init(a);
    defer layered.deinit();
    try layered.beginLayer(.{}, null, 0.5);
    try layered.addLabel(0, .{ .width = 5, .height = 5, .baseline = 4 }, .{});
    try layered.endScope();
    try testing.expectError(error.TranslucentText, flatten(a, &layered, .{}, null));
    var under = DisplayList.init(a);
    defer under.deinit();
    try under.addLabel(0, .{ .width = 5, .height = 5, .baseline = 4 }, .translation(1, 8));
    try under.fill(veil, .{ .color = .{ .r = 0.5, .a = 0.5 } }, .{});
    try testing.expectError(error.LabelResolverRequired, flatten(a, &under, .{}, null));
}

test "text under a translucent fill is repeated as glyphs in the fill's colors" {
    const a = testing.allocator;
    const Glyphs = struct {
        pub fn resolveOutline(_: @This(), allocator: Allocator, reference: u32) !DisplayList {
            try testing.expectEqual(@as(u32, 3), reference);
            var result = DisplayList.init(allocator);
            errdefer result.deinit();
            var stem = try rectangle(allocator, 1, 0, 1, 4);
            defer stem.deinit();
            try result.fill(stem, .{ .color = .{ .r = 0.1, .g = 0.1, .b = 0.4 } }, .{});
            return result;
        }
    };
    var veil = try rectangle(a, 0, 0, 10, 10);
    defer veil.deinit();
    var source = DisplayList.init(a);
    defer source.deinit();
    try source.addLabel(3, .{ .width = 5, .height = 5, .baseline = 4 }, .translation(2, 2));
    try source.fill(veil, .{ .color = .{ .r = 0.9, .g = 0.5, .a = 0.5 } }, .{});
    var result = try flatten(a, &source, .{}, Glyphs{});
    defer result.deinit();
    try expectOpaque(&result);
    // The text itself, the veil, and the glyph in the veil's colors.
    var labels: usize = 0;
    for (result.commands.items) |command| labels += @intFromBool(command == .label);
    try testing.expectEqual(@as(usize, 1), labels);
    try testing.expectEqual(@as(usize, 2), paths(&result));
}
