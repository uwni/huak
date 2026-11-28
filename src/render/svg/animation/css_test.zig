//! Tests of the CSS encoding: shared keyframes, phases as delays, reduced motion, paint and motion classes beside SMIL tracks.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const Path = @import("../../../drawing/path/Path.zig");
const CssEncoder = @import("../CssEncoder.zig");
const t = std.testing;
const svg_animation = @import("../animation.zig");
const testing = @import("testing.zig");
const encodeAnimatedSvg = svg_animation.encodeAnimatedSvg;
const fixture = testing.fixture;
const encodeSmil = testing.encodeSmil;

/// Whether `svg` contains the text that `format` makes of `args`.
fn contains(svg: []const u8, comptime format: []const u8, args: anytype) !bool {
    var buffer: [512]u8 = undefined;
    return std.mem.find(u8, svg, try std.mem.print(&buffer, format, args)) != null;
}

test "CSS shares keyframes, writes phases as delays and keeps start states for reduced motion" {
    const pulse = [_]a.ScalarKey{ .{ .time = 0, .value = 0.2 }, .{ .time = 0.5, .value = 1 }, .{ .time = 1, .value = 0.2 } };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .opacity = &pulse } },
        .{ .target = 9, .property = .{ .opacity = &pulse }, .phase = 0.25 },
    };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 4, .tracks = &tracks });
    defer t.allocator.free(result);
    // One keyframes and one class serve both; the second differs by its delay.
    const body = "0%{opacity:0.2}50%{opacity:1}100%{opacity:0.2}";
    const keyframes: CssEncoder.Name = .of(.keyframes, body);
    var rule: [128]u8 = undefined;
    const rule_text = try std.mem.print(&rule, "animation:{f} 4s linear infinite", .{keyframes});
    const class: CssEncoder.Name = .of(.class, rule_text);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "@keyframes"));
    try t.expect(try contains(result, "<g opacity=\"0.2\" class=\"{f}\">", .{class}));
    // A quarter cycle in, the pulse is halfway up: its start state is 0.6.
    try t.expect(try contains(result, "<g opacity=\"0.6\" class=\"{f}\" style=\"animation-delay:-1s\">", .{class}));
    try t.expect(try contains(result, "<style>@keyframes {f}{{{s}}}@media (prefers-reduced-motion:no-preference){{.{f}{{{s}}}}}</style></svg>", .{ keyframes, body, class, rule_text }));
    try t.expect(std.mem.find(u8, result, "<animate") == null);
}

test "CSS paints and motion use classes while tracks marked smil keep SMIL" {
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 10 } }, .close };
    const last = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 30, .y = 20 } }, .close };
    const route = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .line = .{ .x = 100, .y = 30 } } };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .{ .r = 0, .g = 0, .b = 1, .a = 0.4 } }, .{ .time = 1, .value = .{ .r = 1, .g = 0, .b = 0 } } } }, .easing = .{ .spline = .{ .x1 = 0.3, .y1 = 0, .x2 = 0.7, .y2 = 1 } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } }, .smil = true },
        .{ .target = 9, .property = .{ .motion = .{ .path = &route, .rotate = .auto } } },
    };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 3, .repeat = false, .tracks = &tracks });
    defer t.allocator.free(result);
    const fill_body = "0%{fill:rgb(0,0,255);fill-opacity:0.4}100%{fill:rgb(255,0,0);fill-opacity:1}";
    const fill_keyframes: CssEncoder.Name = .of(.keyframes, fill_body);
    var fill_rule: [128]u8 = undefined;
    const fill_text = try std.mem.print(&fill_rule, "animation:{f} 3s cubic-bezier(0.3,0,0.7,1) both", .{fill_keyframes});
    const fill_class: CssEncoder.Name = .of(.class, fill_text);
    try t.expect(try contains(result, "fill=\"rgb(0,0,255)\" fill-opacity=\"0.4\" d=\"M 0 0 L 10 10 Z \" class=\"{f}\"><animate attributeName=\"d\"", .{fill_class}));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<animate"));
    try t.expect(try contains(result, "@keyframes {f}{{{s}}}", .{ fill_keyframes, fill_body }));
    try t.expect(try contains(result, ".{f}{{{s}}}", .{ fill_class, fill_text }));
    // Motion trades the group's start pose for a place on the path.
    const motion_body = "0%{offset-distance:0%}100%{offset-distance:100%}";
    const motion_keyframes: CssEncoder.Name = .of(.keyframes, motion_body);
    var motion_rule: [160]u8 = undefined;
    const motion_text = try std.mem.print(&motion_rule, "transform:none;offset-path:path(\"M 20 30 L 100 30 \");offset-rotate:auto;animation:{f} 3s linear both", .{motion_keyframes});
    const motion_class: CssEncoder.Name = .of(.class, motion_text);
    try t.expect(try contains(result, "<g transform=\"translate(20 30) rotate(0)\" class=\"{f}\">", .{motion_class}));
    try t.expect(try contains(result, "@keyframes {f}{{{s}}}", .{ motion_keyframes, motion_body }));
    try t.expect(try contains(result, ".{f}{{{s}}}", .{ motion_class, motion_text }));
    // Half a run ahead, the start pose lies halfway along the route; written
    // inline, the distance keeps it there when a page removes the animation.
    var phased = tracks;
    phased[2].phase = 0.5;
    const ahead = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 3, .repeat = false, .tracks = &phased });
    defer t.allocator.free(ahead);
    try t.expect(try contains(ahead, "<g transform=\"translate(60 30) rotate(0)\" class=\"{f}\" style=\"animation-delay:-1.5s;offset-distance:50%\">", .{motion_class}));
    const styled = "<svg xmlns='http://www.w3.org/2000/svg'><g data-typst-label='libtypst-object-7'><path class='x' fill='red' d='M0 0L1 1'/></g></svg>";
    const fill: a.Track = tracks[0];
    try t.expectError(error.StyledPathTarget, encodeAnimatedSvg(t.allocator, styled, &.{ .duration_seconds = 1, .tracks = &.{fill} }));
    const kept = try encodeSmil(t.allocator, styled, &.{ .duration_seconds = 1, .tracks = &.{fill} });
    t.allocator.free(kept);
}
