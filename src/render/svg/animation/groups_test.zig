//! Tests of wrapper-group tracks and timing: nested parametric transforms, native motion poses and fallbacks, SMIL timing and phases.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const Path = @import("../../../drawing/path/Path.zig");
const t = std.testing;
const testing = @import("testing.zig");
const encodeSmil = testing.encodeSmil;
const fixture = testing.fixture;

test "parametric transforms are nested continuously and shared glyph definitions stay unchanged" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .{ .x = 10, .y = 20 } }, .{ .time = 1, .value = .{ .x = 50, .y = 60 } } } } },
        .{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0.2 }, .{ .time = 1, .value = 1 } } } },
    };
    const result = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 2, .tracks = &tracks });
    defer t.allocator.free(result);
    try t.expect(std.mem.find(u8, result, "<g transform=\"translate(10 20)\"><animateTransform") != null);
    // Wrappers carry no IDs, which several SVG files on one page would share.
    try t.expect(std.mem.find(u8, result, " id=\"") == null);
    try t.expect(std.mem.find(u8, result, "values=\"10 20;50 60\"") != null);
    try t.expect(std.mem.find(u8, result, "values=\"0 0 0;180 0 0\"") != null);
    try t.expect(std.mem.find(u8, result, "transform='translate(5 6)'") != null);
    try t.expect(std.mem.find(u8, result, "<defs><path id='glyph' d='M0 0L1 1'/></defs>") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<defs>"));
    try t.expect(std.mem.find(u8, result, "<g opacity=\"0.2\">") != null);
}

test "native motion uses exact fallback pose without double translation and constant motion stays static" {
    const route = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .line = .{ .x = 100, .y = 30 } } };
    const dynamic: a.Animation = .{ .duration_seconds = 2, .repeat = false, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &route, .keys = &.{ .{ .time = 0, .value = 0.25 }, .{ .time = 1, .value = 0.75 } } } } }} };
    const result = try encodeSmil(t.allocator, fixture, &dynamic);
    defer t.allocator.free(result);
    try expectMotionPose(result, 40, 30, 0);
    try t.expect(std.mem.find(u8, result, "<animateTransform attributeName=\"transform\" type=\"translate\" additive=\"replace\" values=\"0 0;0 0\" calcMode=\"discrete\"") != null);
    try t.expect(std.mem.find(u8, result, "<set") == null);
    try t.expect(std.mem.find(u8, result, "<animateMotion path=\"M 20 30 L 100 30 \" rotate=\"0\" keyPoints=\"0.25;0.75\"") != null);
    const fixed: a.Animation = .{ .duration_seconds = 2, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &route, .rotate = .auto_reverse, .keys = &.{ .{ .time = 0, .value = 0.5 }, .{ .time = 1, .value = 0.5 } } } } }} };
    const still = try encodeSmil(t.allocator, fixture, &fixed);
    defer t.allocator.free(still);
    try expectMotionPose(still, 60, 30, 180);
    try t.expect(std.mem.find(u8, still, "<animate") == null);
    try t.expect(std.mem.find(u8, still, "<set") == null);
}

test "motion fallbacks match SVG at exact corners subpath jumps and move-only paths" {
    const corner = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } }, .{ .line = .{ .x = 10, .y = 10 } } };
    const jump = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } }, .{ .move = .{ .x = 1000, .y = 1000 } }, .{ .line = .{ .x = 1000, .y = 1010 } } };
    for ([_][]const Path.Segment{ &corner, &jump }) |route| {
        const animation: a.Animation = .{ .duration_seconds = 2, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{
            .path = route,
            .rotate = .auto,
            .keys = &.{ .{ .time = 0, .value = 0.5 }, .{ .time = 1, .value = 1 } },
        } } }} };
        const output = try encodeSmil(t.allocator, fixture, &animation);
        defer t.allocator.free(output);
        try expectMotionPose(output, 10, 0, 0);
    }
    const moves = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .move = .{ .x = 50, .y = 60 } } };
    const animation: a.Animation = .{ .duration_seconds = 2, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &moves, .rotate = .auto } } }} };
    const output = try encodeSmil(t.allocator, fixture, &animation);
    defer t.allocator.free(output);
    try expectMotionPose(output, 50, 60, 0);
}

fn expectMotionPose(svg: []const u8, x: f64, y: f64, angle: f64) !void {
    // The motion wrapper; the static fixture quotes its attributes with '.
    const needle = "<g transform=\"translate(";
    const begin = (std.mem.find(u8, svg, needle) orelse return error.TestUnexpectedResult) + needle.len;
    const end = std.mem.findScalarPos(u8, svg, begin, '"').?;
    var values = std.mem.tokenizeAny(u8, svg[begin..end], " ()");
    try t.expectApproxEqAbs(x, try std.fmt.parseFloat(f64, values.next().?), 1e-5);
    try t.expectApproxEqAbs(y, try std.fmt.parseFloat(f64, values.next().?), 1e-5);
    try t.expectEqualStrings("rotate", values.next().?);
    try t.expectApproxEqAbs(angle, try std.fmt.parseFloat(f64, values.next().?), 1e-7);
}

test "SMIL timing omits defaults and numbers follow Typst's SVG precision" {
    // Evenly spaced linear keys, begin at 0, linear calcMode and the freeze of
    // an endless loop are all SMIL defaults.
    var keys: [26]a.ScalarKey = undefined;
    for (&keys, 0..) |*key, index| key.* = .{ .time = @as(f64, @floatFromInt(index)) / 25.0, .value = if (index % 2 == 0) 0.30974058379240427 else 0.1 };
    const looped = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 60, .tracks = &.{.{ .target = 9, .property = .{ .opacity = &keys } }} });
    defer t.allocator.free(looped);
    try t.expect(std.mem.find(u8, looped, "<g opacity=\"0.309740584\"><animate attributeName=\"opacity\" values=\"0.309740584;0.1;0.309740584;") != null);
    try t.expect(std.mem.find(u8, looped, ";0.1\" dur=\"60s\" repeatCount=\"indefinite\"/>") != null);
    for ([_][]const u8{ "keyTimes", "calcMode", "begin", "fill=\"freeze\"" }) |omitted| try t.expect(std.mem.find(u8, looped, omitted) == null);
    // Uneven, discrete and motion timing stay explicit, as does the freeze of
    // a single run.
    const route = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    const explicit = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 2, .repeat = false, .tracks = &.{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 0.37, .value = .{ .x = 1, .y = 0 } }, .{ .time = 1, .value = .{ .x = 2, .y = 0 } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 }, .{ .time = 1, .value = 0 } } }, .easing = .discrete },
        .{ .target = 9, .property = .{ .motion = .{ .path = &route } } },
    } });
    defer t.allocator.free(explicit);
    try t.expect(std.mem.find(u8, explicit, "values=\"0 0;1 0;2 0\" dur=\"2s\" fill=\"freeze\" keyTimes=\"0;0.37;1\"/>") != null);
    try t.expect(std.mem.find(u8, explicit, "values=\"0;1;0\" dur=\"2s\" fill=\"freeze\" calcMode=\"discrete\" keyTimes=\"0;0.5;1\"/>") != null);
    try t.expect(std.mem.find(u8, explicit, "keyPoints=\"0;1\" dur=\"2s\" fill=\"freeze\" calcMode=\"linear\" keyTimes=\"0;1\"/>") != null);
    try t.expect(std.mem.find(u8, explicit, "repeatCount") == null);
    try t.expect(std.mem.find(u8, explicit, "begin") == null);
}

test "SMIL writes phases as begin offsets over evaluated start states" {
    const pulse = [_]a.ScalarKey{ .{ .time = 0, .value = 0.2 }, .{ .time = 0.5, .value = 1 }, .{ .time = 1, .value = 0.2 } };
    const tracks = [_]a.Track{.{ .target = 9, .property = .{ .opacity = &pulse }, .phase = -0.25 }};
    // A loop runs three quarters ahead, starting on the falling half.
    const looped = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 4, .tracks = &tracks });
    defer t.allocator.free(looped);
    try t.expect(std.mem.find(u8, looped, "<g opacity=\"0.6\"><animate attributeName=\"opacity\" values=\"0.2;1;0.2\" dur=\"4s\" begin=\"-3s\" repeatCount=\"indefinite\"/>") != null);
    // A single run starts a quarter cycle late and holds its first key.
    const late = try encodeSmil(t.allocator, fixture, &.{ .duration_seconds = 4, .repeat = false, .tracks = &tracks });
    defer t.allocator.free(late);
    try t.expect(std.mem.find(u8, late, "<g opacity=\"0.2\"><animate attributeName=\"opacity\" values=\"0.2;1;0.2\" dur=\"4s\" begin=\"1s\" fill=\"freeze\"/>") != null);
}
