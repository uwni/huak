//! Parametric animation added to one native Typst SVG export, as CSS or SMIL.
//! Static glyph defs are shared unchanged. Typed tracks address marked scene
//! objects, never glyph definitions or an arbitrary path found elsewhere in
//! the document.
const std = @import("std");
const a = @import("../../animation/root.zig");
const Path = @import("../../drawing/path/Path.zig");
const SmilEncoder = @import("SmilEncoder.zig");
const CssEncoder = @import("CssEncoder.zig");
const XmlWriter = @import("xml_parser").Writer;
const target_index = @import("animation/targets.zig");
const testing = @import("animation/testing.zig");
const Range = target_index.Range;
const bindTargets = target_index.bindTargets;
const isPaint = target_index.isPaint;
const paint_properties = target_index.paint_properties;
const Properties = target_index.Properties;
const encodeSmil = testing.encodeSmil;
const fixture = testing.fixture;
/// Native scene tag of a marked object's group, before its id. Typst writes
/// it as `data-typst-label`.
pub const object_label = "libtypst-object-";
const Buffer = std.ArrayList(u8);
const Edit = union(enum) {
    opening: struct { position: usize, storage: []u8, content_len: usize },
    closing: struct { position: usize, bytes: []const u8 },
    replacement: struct { source: Range, bytes: []u8 },

    fn start(edit: *const Edit) usize {
        return switch (edit.*) {
            .opening => |value| value.position,
            .closing => |value| value.position,
            .replacement => |value| value.source.start,
        };
    }
    fn end(edit: *const Edit) usize {
        return switch (edit.*) {
            .opening => |value| value.position,
            .closing => |value| value.position,
            .replacement => |value| value.source.end,
        };
    }
    fn bytes(edit: *const Edit) []const u8 {
        return switch (edit.*) {
            .opening => |value| value.storage[0..value.content_len],
            .closing => |value| value.bytes,
            .replacement => |value| value.bytes,
        };
    }
    fn order(edit: *const Edit) u8 {
        return switch (edit.*) {
            .closing => 0,
            .replacement => 1,
            .opening => 2,
        };
    }
    fn deinit(edit: *Edit, allocator: std.mem.Allocator) void {
        switch (edit.*) {
            .opening => |value| allocator.free(value.storage),
            .replacement => |value| allocator.free(value.bytes),
            .closing => {},
        }
        edit.* = undefined;
    }
};
comptime {
    std.debug.assert(@sizeOf(Edit) <= 40);
}

/// Transform and motion tracks (including rotation centers) use each marked
/// group's parent coordinates; huak supplies a y-up parent group. Path-morph
/// keys and stroke widths use the actual instance path's local coordinates,
/// before its preserved base/ancestor transforms. Typed angles are radians.
/// Tracks play as CSS animations, which share keyframes between elements and
/// stop for readers who prefer reduced motion. A track marked `smil` plays as
/// SMIL instead, for browsers lacking a CSS property such as `d`.
pub fn encodeAnimatedSvg(allocator: std.mem.Allocator, static_svg: []const u8, animation: *const a.Animation) ![]u8 {
    return encode(allocator, static_svg, animation) catch |err| switch (err) {
        // Both writer sinks are memory-only; WriteFailed can only be allocation failure.
        error.WriteFailed => error.OutOfMemory,
        else => return err,
    };
}

fn encode(allocator: std.mem.Allocator, static_svg: []const u8, animation: *const a.Animation) ![]u8 {
    var edits: std.ArrayList(Edit) = .empty;
    defer {
        for (edits.items) |*edit| edit.deinit(allocator);
        edits.deinit(allocator);
    }
    {
        var group_sink: std.Io.Writer.Allocating = .init(allocator);
        defer group_sink.deinit();
        var fragment: std.Io.Writer.Allocating = .init(allocator);
        defer fragment.deinit();
        var value: std.Io.Writer.Allocating = .init(allocator);
        defer value.deinit();
        var targets = try bindTargets(allocator, static_svg, animation);
        defer targets.deinit();
        const group_edits = std.math.mul(usize, targets.locations.count(), 2) catch return error.OutOfMemory;
        const edit_count = std.math.add(usize, group_edits, targets.paths.items.len) catch return error.OutOfMemory;
        try edits.ensureTotalCapacity(allocator, edit_count);
        var groups: SmilEncoder = .init(allocator, &group_sink.writer, &value);
        defer groups.deinit();
        var paint: SmilEncoder = .init(allocator, &fragment.writer, &value);
        defer paint.deinit();
        var css: CssEncoder = .init(allocator);
        defer css.deinit();
        var groups_started = false;
        var paint_started = false;
        for (targets.locations.values()) |*location| {
            const track_indices = location.track_indices[0..location.properties.count()];
            // Each group track wraps the object's own group, without IDs:
            // several SVG files may share one page.
            var wrappers: usize = 0;
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (isPaint(std.meta.activeTag(track.property))) continue;
                if (!groups_started) {
                    try groups.xml.elementStart("g");
                    try groups.xml.embed("");
                    groups_started = true;
                }
                if (wrappers == 0) group_sink.clearRetainingCapacity();
                try groups.wrapper(track, animation);
                if (track.smil) {
                    try groups.wrapperAnimation(track, animation);
                } else if (try css.element(&.{track}, animation)) |class| {
                    try groups.attribute("class", "{f}", .{class});
                    if (css.style().len != 0) try groups.attribute("style", "{s}", .{css.style()});
                }
                wrappers += 1;
            }
            if (wrappers != 0) {
                try groups.xml.embed("");
                const opening_end = group_sink.written().len;
                for (0..wrappers) |_| try groups.xml.elementEnd();
                const group = try allocator.dupe(u8, group_sink.written());
                const marker = @intFromPtr(location.marker.?) - @intFromPtr(static_svg.ptr);
                // Reuse serialization scratch; edits retain only their exact bytes.
                // The closing edit borrows its owner tail across sorting.
                edits.appendAssumeCapacity(.{ .opening = .{ .position = marker, .storage = group, .content_len = opening_end } });
                edits.appendAssumeCapacity(.{ .closing = .{ .position = location.end, .bytes = group[opening_end..] } });
            }

            if (location.properties.intersectWith(paint_properties).count() == 0) continue;
            if (location.path_count != 1 or location.drawable_count != 1) return error.AmbiguousPathTarget;
            const tag = location.path.?;
            if (!paint_started) {
                try paint.xml.elementStart("g");
                try paint.xml.embed("");
                paint_started = true;
            }
            fragment.clearRetainingCapacity();
            try paint.xml.elementStart("path");
            const attributes_start = fragment.written().len;
            var styled: [Properties.len]*const a.Track = undefined;
            var styled_count: usize = 0;
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (!isPaint(std.meta.activeTag(track.property))) continue;
                try paint.basePaint(track, animation);
                if (track.smil) continue;
                styled[styled_count] = track;
                styled_count += 1;
            }
            if (try css.element(styled[0..styled_count], animation)) |class| {
                if (tag.styled) return error.StyledPathTarget;
                try paint.attribute("class", "{f}", .{class});
                if (css.style().len != 0) try paint.attribute("style", "{s}", .{css.style()});
            }
            try paint.xml.embed("");
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (!isPaint(std.meta.activeTag(track.property))) continue;
                if (!track.smil) continue;
                try paint.paintAnimation(track, animation);
            }
            const content_end = fragment.written().len;
            try paint.xml.elementEnd();
            const tail = fragment.written()[attributes_start..if (tag.self_closing) fragment.written().len else content_end];
            const removals = targets.removals.items[tag.removal_start..][0..tag.removal_count];
            const tag_end = tag.end - (if (tag.self_closing) @as(usize, 2) else 1);
            var length = tag_end - tag.start;
            for (removals) |range| length -= range.end - range.start;
            length = std.math.add(usize, length, tail.len) catch return error.OutOfMemory;
            var replacement = try Buffer.initCapacity(allocator, length);
            defer replacement.deinit(allocator);
            var copied = tag.start;
            for (removals) |range| {
                replacement.appendSliceAssumeCapacity(static_svg[copied..range.start]);
                copied = range.end;
            }
            replacement.appendSliceAssumeCapacity(static_svg[copied..tag_end]);
            replacement.appendSliceAssumeCapacity(tail);
            edits.appendAssumeCapacity(.{ .replacement = .{ .source = .{ .start = tag.start, .end = tag.end }, .bytes = replacement.toOwnedSliceAssert() } });
        }
        if (!css.empty()) {
            // Classes apply wherever the stylesheet sits; it ends the root.
            var text: std.Io.Writer.Allocating = .init(allocator);
            defer text.deinit();
            try css.stylesheet(&text.writer);
            var sheet: std.Io.Writer.Allocating = .init(allocator);
            defer sheet.deinit();
            var style: XmlWriter = .init(allocator, &sheet.writer, .{ .namespace_aware = false });
            defer style.deinit();
            try style.elementStart("g");
            try style.embed("");
            sheet.clearRetainingCapacity();
            try style.elementStart("style");
            try style.text(text.written());
            try style.elementEnd();
            const bytes = try allocator.dupe(u8, sheet.written());
            edits.append(allocator, .{ .opening = .{ .position = targets.root_close, .storage = bytes, .content_len = bytes.len } }) catch |err| {
                allocator.free(bytes);
                return err;
            };
        }
    }
    std.mem.sort(Edit, edits.items, {}, struct {
        fn less(_: void, left: Edit, right: Edit) bool {
            const left_start = left.start();
            const right_start = right.start();
            return left_start < right_start or (left_start == right_start and left.order() < right.order());
        }
    }.less);
    var length: usize = 0;
    var copied: usize = 0;
    for (edits.items) |*edit| {
        const edit_start = edit.start();
        const edit_end = edit.end();
        if (edit_start < copied or edit_end < edit_start or edit_end > static_svg.len) return error.InvalidSvg;
        length = std.math.add(usize, length, edit_start - copied) catch return error.OutOfMemory;
        length = std.math.add(usize, length, edit.bytes().len) catch return error.OutOfMemory;
        copied = edit_end;
    }
    length = std.math.add(usize, length, static_svg.len - copied) catch return error.OutOfMemory;
    var output = try Buffer.initCapacity(allocator, length);
    copied = 0;
    for (edits.items) |*edit| {
        output.appendSliceAssumeCapacity(static_svg[copied..edit.start()]);
        output.appendSliceAssumeCapacity(edit.bytes());
        copied = edit.end();
    }
    output.appendSliceAssumeCapacity(static_svg[copied..]);
    return output.toOwnedSliceAssert();
}

const t = std.testing;

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const route = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .line = .{ .x = 100, .y = 30 } } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 20, .y = 30 } } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 9, .property = .{ .motion = .{ .path = &route } } },
    } };
    const result = try encodeSmil(allocator, fixture, &animation);
    defer allocator.free(result);
}
test "all allocation failures clean up locations edits and final SVG" {
    // Keep failure indices independent of heap placement and in-place growth,
    // using the same standard allocation fallback as the XML reader tests.
    var moving = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(moving.allocator(), allocationFailures, .{});
}

test {
    _ = SmilEncoder;
    _ = CssEncoder;
    _ = @import("values.zig");
    _ = @import("animation/targets_test.zig");
    _ = @import("animation/paths_test.zig");
    _ = @import("animation/groups_test.zig");
    _ = @import("animation/css_test.zig");
}
