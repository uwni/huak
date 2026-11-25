//! Tests of target binding: the target index under allocation failure, lookup, XML validation order and diagnostics.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const xml = @import("../xml.zig");
const Path = @import("../../../drawing/path/Path.zig");
const t = std.testing;
const testing = @import("testing.zig");
const target_index = @import("targets.zig");
const encodeSmil = testing.encodeSmil;
const fixture = testing.fixture;
const bindTargets = target_index.bindTargets;
const PathEdit = target_index.PathEdit;
const Targets = target_index.Targets;
const indexTracks = target_index.indexTracks;
const locate = target_index.locate;
const Properties = target_index.Properties;

test "missing duplicate ambiguous definition and overflowing angle targets fail" {
    const opacity = a.Track{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } };
    const animation = a.Animation{ .duration_seconds = 1, .tracks = &.{opacity} };
    try t.expectError(error.MissingTarget, encodeSmil(t.allocator, "<svg/>", &animation));
    try t.expectError(error.DuplicateTarget, encodeSmil(t.allocator, "<svg><g data-typst-label='libtypst-object-7'/><g data-typst-label='libtypst-object-7'/></svg>", &animation));
    try t.expectError(error.InvalidTarget, encodeSmil(t.allocator, "<svg><defs><g data-typst-label='libtypst-object-7'/></defs></svg>", &animation));
    try t.expectError(error.InvalidTarget, encodeSmil(t.allocator, "<svg xmlns:s='http://www.w3.org/2000/svg'><s:defs><g data-typst-label='libtypst-object-7'/></s:defs></svg>", &animation));
    const paint: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 9, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 2 } } } }} };
    try t.expectError(error.AmbiguousPathTarget, encodeSmil(t.allocator, fixture, &paint));
    const rotation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1e308 } } } } }} };
    try t.expectError(error.NonFinite, encodeSmil(t.allocator, fixture, &rotation));
}

test "input has one static SVG root with only whitespace declaration and comments outside" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{} };
    const allowed = "<?xml version='1.0'?>\n<!--before--><svg xmlns='http://www.w3.org/2000/svg'><g/></svg>\n<!--after-->";
    const result = try encodeSmil(t.allocator, allowed, &animation);
    defer t.allocator.free(result);
    try t.expectEqualStrings(allowed, result);
    for ([_][]const u8{ "", "<g/>", "<svg/><svg/>", "outside<svg/>", "<svg/>outside", "<![CDATA[outside]]><svg/>" }) |invalid| {
        try t.expectError(error.InvalidSvg, encodeSmil(t.allocator, invalid, &animation));
    }
    for ([_][]const u8{
        "<svg xmlns='urn:not-svg'/>",
        "<svg><animate/></svg>",
        "<svg><animateTransform/></svg>",
        "<svg><animateMotion/></svg>",
        "<svg><set/></svg>",
        "<svg><?xml version='1.0'?></svg>",
    }) |unsupported| {
        try t.expectError(error.UnsupportedSvg, encodeSmil(t.allocator, unsupported, &animation));
    }
}

fn targetAllocationFailures(allocator: std.mem.Allocator) !void {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0.2 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
    };
    for (tracks) |track| {
        const result = try encodeSmil(allocator, fixture, &.{ .duration_seconds = 1, .tracks = &.{track} });
        defer allocator.free(result);
    }
}

test "target index survives every allocation failure" {
    var moving = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(moving.allocator(), targetAllocationFailures, .{});
}

test "target index lookup skips unrelated objects and retains marked path" {
    const source = "<svg><g data-typst-label='libtypst-object-9'/><g data-typst-label='libtypst-object-7'><path d='M0 0L1 1'/></g><g data-typst-label='libtypst-object-8'/></svg>";
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .path = &.{
        .{ .time = 0, .value = &.{ .{ .move = .zero }, .{ .line = .{ .x = 1, .y = 1 } } } },
        .{ .time = 1, .value = &.{ .{ .move = .zero }, .{ .line = .{ .x = 2, .y = 2 } } } },
    } } }} };
    var targets = try bindTargets(t.allocator, source, &animation);
    defer targets.deinit();
    const locations = targets.locations.values();
    try t.expectEqual(@as(usize, 1), locations[0].path_count);
    try t.expectEqual(@as(usize, 1), locations[0].drawable_count);
    try t.expectEqual(@as(usize, 1), targets.paths.items.len);
    const path = locations[0].path.?;
    try t.expectEqual(@as(*const PathEdit, &targets.paths.items[0]), path);
    try t.expectEqual(@as(u8, '<'), locations[0].marker.?[0]);
    const marker_offset = @intFromPtr(locations[0].marker.?) - @intFromPtr(source.ptr);
    try t.expect(std.mem.startsWith(u8, source[marker_offset..], "<g data-typst-label='libtypst-object-7'"));
    try t.expectEqualStrings("<path d='M0 0L1 1'/>", source[path.start..path.end]);
    try t.expectEqualStrings("d='M0 0L1 1'", source[targets.removals.items[path.removal_start].start..targets.removals.items[path.removal_start].end]);
}

test "complete XML validation precedes streamed binding diagnostics" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } }} };
    try t.expectError(error.InvalidSvg, encodeSmil(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><g></svg>", &animation));
    try t.expectError(error.InvalidSvg, encodeSmil(t.allocator, "<svg><g data-typst-label='libtypst-object-7'/><g data-typst-label='libtypst-object-7'/><g></svg>", &animation));
    try t.expectError(error.UnsupportedSvg, encodeSmil(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><style/></svg>", &animation));
    try t.expectError(error.InvalidSvg, encodeSmil(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><path id='same'/><path id='same'/></svg>", &animation));
}

test "metadata arena allocation failure still finishes XML validation" {
    const source = "<svg><g data-typst-label='libtypst-object-7'><path fill='black'/></g><style/></svg>";
    const colors = [_]a.ColorKey{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .fill = &colors } }} };
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    var targets: Targets = .{ .arena = .init(failing.allocator()) };
    defer targets.deinit();
    // Isolate metadata failure from index and Reader allocations, without
    // depending on spare capacity or the index's allocation count.
    targets.locations = try indexTracks(t.allocator, &animation);
    defer targets.locations.deinit(t.allocator);
    var cursor: xml.Cursor = .init(t.allocator, source);
    defer cursor.deinit();
    try t.expectError(error.UnsupportedSvg, locate(t.allocator, &cursor, &targets, source));
    try t.expect(failing.has_induced_failure);
    try t.expectEqual(@as(usize, 0), targets.removals.capacity);
}

test "binding stack allocation failure still finishes XML validation" {
    const source = "<svg><g data-typst-label='libtypst-object-7'><path fill='black'/></g><style/></svg>";
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } } } }} };
    var targets: Targets = .{ .arena = .init(t.allocator) };
    defer targets.deinit();
    targets.locations = try indexTracks(targets.arena.allocator(), &animation);
    var failing_stack = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var cursor: xml.Cursor = .init(t.allocator, source);
    defer cursor.deinit();
    try t.expectError(error.UnsupportedSvg, locate(failing_stack.allocator(), &cursor, &targets, source));
    try t.expect(failing_stack.has_induced_failure);
    try t.expectEqual(@as(usize, 2), targets.removals.capacity);
}

test "animation semantic errors precede SVG parsing and allocation failure" {
    const invalid: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 } } } }} };
    try t.expectError(error.InvalidKeys, encodeSmil(t.allocator, "<svg><script/></svg>", &invalid));
    try t.expectError(error.InvalidKeys, encodeSmil(t.failing_allocator, fixture, &invalid));
}

test "late animation errors survive XML and target index allocation failures" {
    var tracks: [40]a.Track = undefined;
    for (&tracks, 0..) |*track, index| track.* = .{
        .target = index + 1,
        .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } },
    };
    tracks[tracks.len - 1].property.opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &tracks };
    var induced_failures: usize = 0;
    for (0..32) |fail_index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        try t.expectError(error.InvalidKeys, encodeSmil(failing.allocator(), fixture, &animation));
        if (failing.has_induced_failure) induced_failures += 1;
    }
    try t.expect(induced_failures > 0);
}

fn indexAllocationFailures(allocator: std.mem.Allocator) !void {
    var tracks: [64]a.Track = undefined;
    for (&tracks, 0..) |*track, index| track.* = .{
        .target = index + 1,
        .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } },
    };
    var locations = try indexTracks(allocator, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer locations.deinit(allocator);
    try t.expectEqual(@as(usize, tracks.len), locations.count());
}

test "target index growth releases partial storage at every allocation failure" {
    var moving = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(moving.allocator(), indexAllocationFailures, .{});
}

test "SVG parse errors precede target index allocation errors for valid animation" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } }} };
    try t.expectError(error.InvalidSvg, encodeSmil(t.failing_allocator, "", &animation));
}

test "one ordered target index stores every property and rejects duplicates before invalid keys" {
    const route = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 10 } } };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .zero } } } },
        .{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 0 } } } } },
        .{ .target = 7, .property = .{ .scale = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .zero } } } },
        .{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } } } },
        .{ .target = 7, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &route }, .{ .time = 1, .value = &route } } } },
        .{ .target = 7, .property = .{ .motion = .{ .path = &route } } },
    };
    var locations = try indexTracks(t.allocator, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer locations.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), locations.count());
    const location = &locations.values()[0];
    try t.expectEqual(@as(usize, Properties.len), location.properties.count());
    for (location.track_indices, 0..) |index, expected| try t.expectEqual(expected, index);
    const duplicate = tracks ++ [_]a.Track{.{ .target = 7, .property = .{ .opacity = &.{} } }};
    try t.expectError(error.ConflictingTracks, indexTracks(t.allocator, &.{ .duration_seconds = 1, .tracks = &duplicate }));
}
