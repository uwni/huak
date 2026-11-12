//! Parametric SMIL added to one native Typst SVG export. Static glyph defs are
//! shared unchanged. Typed tracks address marked scene objects, never glyph
//! definitions or an arbitrary path found elsewhere in the document.
const std = @import("std");
const a = @import("../../animation/root.zig");
const xml = @import("xml.zig");
const Path = @import("../../drawing/path/Path.zig");
const SmilEncoder = @import("SmilEncoder.zig");
const Buffer = std.ArrayList(u8);
const Properties = std.EnumSet(std.meta.Tag(a.Property));
const animated_attributes = [_]struct { property: std.meta.Tag(a.Property), names: []const []const u8 }{
    .{ .property = .fill, .names = &.{ "fill", "fill-opacity" } },
    .{ .property = .stroke, .names = &.{ "stroke", "stroke-opacity" } },
    .{ .property = .stroke_width, .names = &.{"stroke-width"} },
    .{ .property = .path, .names = &.{"d"} },
};
const paint_properties = blk: {
    var properties: Properties = .empty;
    for (animated_attributes) |rule| properties.insert(rule.property);
    break :blk properties;
};
const Locations = std.array_hash_map.Auto(u64, Location);
const Location = struct {
    marker: ?[*]const u8 = null,
    end: usize = 0,
    path: ?*const PathEdit = null,
    path_count: usize = 0,
    drawable_count: usize = 0,
    // A target can have each property only once. Preserve their input order.
    track_indices: [Properties.len]usize = undefined,
    properties: Properties = .empty,
};
const Range = struct { start: usize, end: usize };
const PathEdit = struct { start: usize, end: usize, self_closing: bool, removal_start: usize, removal_count: usize };
/// Owns binding metadata only. Source offsets refer to the caller's SVG; no
/// XML reader, tag or attribute storage is retained during SMIL generation.
const Targets = struct {
    arena: std.heap.ArenaAllocator,
    locations: Locations = .empty,
    paths: std.ArrayList(PathEdit) = .empty,
    removals: std.ArrayList(Range) = .empty,

    fn deinit(self: *Targets) void {
        self.arena.deinit();
    }

    fn reserveMetadata(self: *Targets) !void {
        var path_count: usize = 0;
        var range_count: usize = 0;
        for (self.locations.values()) |location| {
            var paint = false;
            inline for (animated_attributes) |rule| {
                if (location.properties.contains(rule.property)) {
                    paint = true;
                    range_count = std.math.add(usize, range_count, rule.names.len) catch return error.OutOfMemory;
                }
            }
            if (paint) path_count = std.math.add(usize, path_count, 1) catch return error.OutOfMemory;
        }
        const allocator = self.arena.allocator();
        self.paths = .initBuffer(try allocator.alloc(PathEdit, path_count));
        self.removals = .initBuffer(try allocator.alloc(Range, range_count));
    }
};
const Element = struct { target: ?usize, object: bool, defs: bool };
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
        var groups_started = false;
        var paint_started = false;
        for (targets.locations.keys(), targets.locations.values()) |id, *location| {
            if (!groups_started) {
                try groups.xml.elementStart("g");
                try groups.xml.embed("");
                groups_started = true;
            }
            group_sink.clearRetainingCapacity();
            var wrappers: usize = 1;
            const track_indices = location.track_indices[0..location.properties.count()];
            try groups.object(id);
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (isPaint(std.meta.activeTag(track.property))) continue;
                try groups.wrapper(track, animation);
                wrappers += 1;
            }
            try groups.xml.embed("");
            const opening_end = group_sink.written().len;
            for (0..wrappers) |_| try groups.xml.elementEnd();
            const group = try allocator.dupe(u8, group_sink.written());
            const marker = @intFromPtr(location.marker.?) - @intFromPtr(static_svg.ptr);
            // Reuse serialization scratch; edits retain only their exact bytes.
            // The closing edit borrows its owner tail across sorting.
            edits.appendAssumeCapacity(.{ .opening = .{ .position = marker, .storage = group, .content_len = opening_end } });
            edits.appendAssumeCapacity(.{ .closing = .{ .position = location.end, .bytes = group[opening_end..] } });

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
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (!isPaint(std.meta.activeTag(track.property))) continue;
                try paint.basePaint(&track.property);
            }
            try paint.xml.embed("");
            for (track_indices) |track_index| {
                const track = &animation.tracks[track_index];
                if (!isPaint(std.meta.activeTag(track.property))) continue;
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

fn bindTargets(allocator: std.mem.Allocator, source: []const u8, animation: *const a.Animation) !Targets {
    var targets: Targets = .{ .arena = .init(allocator) };
    errdefer targets.deinit();
    targets.locations = indexTracks(targets.arena.allocator(), animation) catch |err| {
        // Invalid animation keeps precedence over SVG and allocation errors.
        // For a valid animation, SVG validation precedes an index allocation
        // error, including malformed input that needs no allocation to reject.
        try animation.validate();
        var cursor: xml.Cursor = .init(allocator, source);
        defer cursor.deinit();
        while (try cursor.next()) |_| {}
        return err;
    };
    var cursor: xml.Cursor = .init(allocator, source);
    defer cursor.deinit();
    try locate(allocator, &cursor, &targets, source);
    return targets;
}

fn indexTracks(allocator: std.mem.Allocator, animation: *const a.Animation) !Locations {
    try animation.validateTiming();
    var locations: Locations = .empty;
    errdefer locations.deinit(allocator);
    // Every target requires at least one track. Reserve this input-derived
    // upper bound once instead of retaining grown tables in the arena.
    try locations.ensureTotalCapacity(allocator, animation.tracks.len);
    for (animation.tracks, 0..) |*track, index| {
        if (track.target == 0) return error.InvalidTarget;
        const entry = try locations.getOrPut(allocator, track.target);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const property = std.meta.activeTag(track.property);
        if (entry.value_ptr.properties.contains(property)) return error.ConflictingTracks;
        try track.validateProperties();
        entry.value_ptr.track_indices[entry.value_ptr.properties.count()] = index;
        entry.value_ptr.properties.insert(property);
    }
    return locations;
}

fn locate(allocator: std.mem.Allocator, cursor: *xml.Cursor, targets: *Targets, source: []const u8) !void {
    targets.reserveMetadata() catch |err| {
        while (try cursor.next()) |_| {}
        return err;
    };
    const locations = targets.locations.values();
    var stack: std.ArrayList(Element) = .empty;
    defer stack.deinit(allocator);
    var failure: ?error{ InvalidTarget, DuplicateTarget, OutOfMemory } = null;
    while (try cursor.next()) |tag| {
        // Input validation always finishes before binding diagnostics, just as
        // when the whole document was indexed before resolving its objects.
        if (failure != null) continue;
        if (tag.closing) {
            const element = stack.pop().?;
            if (element.target) |index| locations[index].end = tag.end;
            continue;
        }
        const local_name = tag.name[if (std.mem.lastIndexOfScalar(u8, tag.name, ':')) |colon| colon + 1 else 0..];
        const defs = definition(local_name) or (stack.items.len != 0 and stack.items[stack.items.len - 1].defs);
        var target: ?usize = null;
        var object = false;
        for (0..cursor.attributeCount()) |attribute_index| {
            const attr = cursor.attribute(attribute_index);
            if (!std.mem.eql(u8, attr.name, "data-typst-label") or !std.mem.startsWith(u8, attr.value, "libtypst-object-")) continue;
            const id = markerId(tag.name, attr.value) catch |err| {
                failure = err;
                break;
            };
            object = true;
            if (targets.locations.getIndex(id)) |index| {
                if (defs) {
                    failure = error.InvalidTarget;
                    break;
                }
                if (locations[index].marker != null) {
                    failure = error.DuplicateTarget;
                    break;
                }
                locations[index].marker = source.ptr + tag.start;
                target = index;
                if (tag.self_closing) locations[index].end = tag.end;
            }
        }
        if (failure != null) continue;
        if (!defs and drawable(local_name)) {
            for (stack.items) |ancestor| {
                if (ancestor.target) |index| locations[index].drawable_count += 1;
            }
        }
        if (!defs and std.mem.eql(u8, tag.name, "path")) {
            var i = stack.items.len;
            while (i > 0) {
                i -= 1;
                if (!stack.items[i].object) continue;
                if (stack.items[i].target) |index| {
                    const location = &locations[index];
                    location.path_count += 1;
                    // Only a unique paint/morph path needs a source edit. Keep
                    // the ambiguity counts; report that error at its old stage.
                    if (location.path_count == 1 and location.properties.intersectWith(paint_properties).count() != 0) {
                        const removal_start = targets.removals.items.len;
                        for (0..cursor.attributeCount()) |attribute_index| {
                            const attr = cursor.attribute(attribute_index);
                            if (animatedAttribute(location, attr.name)) targets.removals.appendAssumeCapacity(.{ .start = attr.nameStart(source), .end = attr.valueEnd(source) + 1 });
                        }
                        const path_index = targets.paths.items.len;
                        targets.paths.appendAssumeCapacity(.{ .start = tag.start, .end = tag.end, .self_closing = tag.self_closing, .removal_start = removal_start, .removal_count = targets.removals.items.len - removal_start });
                        location.path = &targets.paths.items[path_index];
                    }
                }
                break;
            }
        }
        if (!tag.self_closing) stack.append(allocator, .{ .target = target, .object = object, .defs = defs }) catch |err| {
            failure = err;
        };
    }
    if (failure) |err| return err;
    for (targets.locations.keys(), locations) |id, *location| {
        if (location.marker == null or location.end == 0) return error.MissingTarget;
        var scratch: [64]u8 = undefined;
        const stable_id = try std.fmt.bufPrint(&scratch, "huak-object-{d}", .{id});
        if (cursor.ids.contains(stable_id)) return error.IdConflict;
    }
}

fn markerId(name: []const u8, value: []const u8) error{InvalidTarget}!u64 {
    if (!std.mem.eql(u8, name, "g")) return error.InvalidTarget;
    const suffix = value["libtypst-object-".len..];
    if (suffix.len == 0 or suffix[0] == '0') return error.InvalidTarget;
    for (suffix) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidTarget;
    return std.fmt.parseInt(u64, suffix, 10) catch error.InvalidTarget;
}
fn definition(name: []const u8) bool {
    for ([_][]const u8{ "defs", "symbol", "clipPath", "mask", "marker", "pattern", "linearGradient", "radialGradient", "filter" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}
fn drawable(name: []const u8) bool {
    for ([_][]const u8{ "path", "use", "image", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "foreignObject" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isPaint(property: std.meta.Tag(a.Property)) bool {
    return paint_properties.contains(property);
}
fn animatedAttribute(location: *const Location, attribute: []const u8) bool {
    inline for (animated_attributes) |rule| {
        if (location.properties.contains(rule.property)) {
            inline for (rule.names) |name| if (std.mem.eql(u8, attribute, name)) return true;
        }
    }
    return false;
}
const t = std.testing;
const fixture = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100' viewBox='0 0 100 100'><defs><path id='glyph' d='M0 0L1 1'/></defs><g data-typst-label='libtypst-object-7' transform='translate(5 6)'><path fill='red' d='M0 0L10 0Z'/></g><g data-typst-label='libtypst-object-9'><use href='#glyph'/></g></svg>";
test "parametric transforms are nested continuously and shared glyph definitions stay unchanged" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .{ .x = 10, .y = 20 } }, .{ .time = 1, .value = .{ .x = 50, .y = 60 } } } } },
        .{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0.2 }, .{ .time = 1, .value = 1 } } } },
    };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 2, .tracks = &tracks });
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "id=\"huak-object-7\"><g transform=\"translate(10 20)\"><animateTransform") != null);
    try t.expect(std.mem.indexOf(u8, result, "values=\"10 20;50 60\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "values=\"0 0 0;180 0 0\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "transform='translate(5 6)'") != null);
    try t.expect(std.mem.indexOf(u8, result, "<defs><path id='glyph' d='M0 0L1 1'/></defs>") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<defs>"));
    try t.expect(std.mem.indexOf(u8, result, "<g opacity=\"0.2\">") != null);
}

test "paint and compatible d morph animate the instance path and establish static first-key values" {
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 10 } }, .close };
    const last = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 30, .y = 20 } }, .close };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .{ .r = 0, .g = 0, .b = 1, .a = 0.4 } }, .{ .time = 1, .value = .{ .r = 1, .g = 0, .b = 0 } } } }, .easing = .{ .spline = .{ .x1 = 0.3, .y1 = 0, .x2 = 0.7, .y2 = 1 } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1, .g = 1, .b = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 3 } } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } },
    };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 3, .tracks = &tracks, .repeat = false });
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "fill='red'") == null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(0,0,255)\" fill-opacity=\"0.4\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "stroke-width=\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "d=\"M 0 0 L 10 10 Z \"><animate") != null);
    try t.expect(std.mem.indexOf(u8, result, "attributeName=\"d\" values=\"M 0 0 L 10 10 Z ;M 0 0 L 30 20 Z ") != null);
    try t.expect(std.mem.indexOf(u8, result, "keySplines=\"0.3 0 0.7 1\"") != null);
    // A single run is SMIL's default; holding its last value needs freeze.
    try t.expect(std.mem.indexOf(u8, result, "repeatCount") == null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"freeze\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "<defs><path id='glyph' d='M0 0L1 1'/></defs>") != null);
}

test "constant tracks write base attributes without interpolation elements" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .{ .x = 20, .y = 30 } }, .{ .time = 1, .value = .{ .x = 20, .y = 30 } } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .black } } } },
    };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "transform=\"translate(20 30)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(0,0,0)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "<animate") == null);
}

test "path morph retains nonidentity base transforms and writes local d coordinates" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><g data-typst-label='libtypst-object-7' transform='matrix(2 0 0 3 11 13)'><path transform='translate(4 6)' d='M0 0L1 1'/></g></svg>";
    const first = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 4, .y = 5 } } };
    const last = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 6, .y = 7 } } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } }} };
    const result = try encodeAnimatedSvg(t.allocator, input, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "transform='matrix(2 0 0 3 11 13)'") != null);
    try t.expect(std.mem.indexOf(u8, result, "transform='translate(4 6)'") != null);
    try t.expect(std.mem.indexOf(u8, result, "d=\"M 1 2 L 4 5 \"><animate attributeName=\"d\" values=\"M 1 2 L 4 5 ;M 1 2 L 6 7 \"") != null);
}

test "constant RGB and alpha components omit redundant animation while retaining first-key base paint" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .{ .r = 1, .g = 0, .b = 0 } }, .{ .time = 1, .value = .{ .r = 0, .g = 0, .b = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .{ .a = 0.25 } }, .{ .time = 1, .value = .{ .a = 0.75 } } } } },
    } };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "fill=\"rgb(255,0,0)\" fill-opacity=\"1\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "stroke=\"rgb(0,0,0)\" stroke-opacity=\"0.25\"") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<animate attributeName=\"fill\""));
    try t.expectEqual(@as(usize, 0), std.mem.count(u8, result, "<animate attributeName=\"fill-opacity\""));
    try t.expectEqual(@as(usize, 0), std.mem.count(u8, result, "<animate attributeName=\"stroke\""));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, result, "<animate attributeName=\"stroke-opacity\""));
}

test "native motion uses exact fallback pose without double translation and constant motion stays static" {
    const route = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .line = .{ .x = 100, .y = 30 } } };
    const dynamic: a.Animation = .{ .duration_seconds = 2, .repeat = false, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &route, .keys = &.{ .{ .time = 0, .value = 0.25 }, .{ .time = 1, .value = 0.75 } } } } }} };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &dynamic);
    defer t.allocator.free(result);
    try expectMotionPose(result, 40, 30, 0);
    try t.expect(std.mem.indexOf(u8, result, "<animateTransform attributeName=\"transform\" type=\"translate\" additive=\"replace\" values=\"0 0;0 0\" calcMode=\"discrete\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "<set") == null);
    try t.expect(std.mem.indexOf(u8, result, "<animateMotion path=\"M 20 30 L 100 30 \" rotate=\"0\" keyPoints=\"0.25;0.75\"") != null);
    const fixed: a.Animation = .{ .duration_seconds = 2, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &route, .rotate = .auto_reverse, .keys = &.{ .{ .time = 0, .value = 0.5 }, .{ .time = 1, .value = 0.5 } } } } }} };
    const still = try encodeAnimatedSvg(t.allocator, fixture, &fixed);
    defer t.allocator.free(still);
    try expectMotionPose(still, 60, 30, 180);
    try t.expect(std.mem.indexOf(u8, still, "<animate") == null);
    try t.expect(std.mem.indexOf(u8, still, "<set") == null);
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
        const output = try encodeAnimatedSvg(t.allocator, fixture, &animation);
        defer t.allocator.free(output);
        try expectMotionPose(output, 10, 0, 0);
    }
    const moves = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .move = .{ .x = 50, .y = 60 } } };
    const animation: a.Animation = .{ .duration_seconds = 2, .tracks = &.{.{ .target = 7, .property = .{ .motion = .{ .path = &moves, .rotate = .auto } } }} };
    const output = try encodeAnimatedSvg(t.allocator, fixture, &animation);
    defer t.allocator.free(output);
    try expectMotionPose(output, 50, 60, 0);
}

test "mixed glyph uses and one decoration path reject every paint and morph track" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><defs><path id='glyph' d='M0 0L1 1'/></defs><g data-typst-label='libtypst-object-7'><g><use href='#glyph' fill='black'/></g><use href='#glyph' fill='black'/><path fill='none' stroke='black' d='M0 0L10 0'/></g></svg>";
    const first = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    const last = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 20, .y = 0 } } };
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 7, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 2 } } } },
        .{ .target = 7, .property = .{ .path = &.{ .{ .time = 0, .value = &first }, .{ .time = 1, .value = &last } } } },
    };
    for (tracks) |track| {
        try t.expectError(error.AmbiguousPathTarget, encodeAnimatedSvg(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{track} }));
    }
}

test "parent paints reject nested object content while child paths and group transforms remain independent" {
    const input = "<svg xmlns='http://www.w3.org/2000/svg'><g data-typst-label='libtypst-object-8'><path d='M0 0L1 1'/><g data-typst-label='libtypst-object-7'><path d='M0 0L2 2'/></g></g></svg>";
    var fill: a.Track = .{ .target = 8, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } };
    try t.expectError(error.AmbiguousPathTarget, encodeAnimatedSvg(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{fill} }));
    fill.target = 7;
    const translate: a.Track = .{ .target = 8, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 5, .y = 6 } } } } };
    const output = try encodeAnimatedSvg(t.allocator, input, &.{ .duration_seconds = 1, .tracks = &.{ translate, fill } });
    defer t.allocator.free(output);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, output, "attributeName=\"fill\""));
    try t.expect(std.mem.indexOf(u8, output, "<path d='M0 0L1 1'/>") != null);
}

fn expectMotionPose(svg: []const u8, x: f64, y: f64, angle: f64) !void {
    const needle = "id=\"huak-object-7\"><g transform=\"translate(";
    const begin = (std.mem.indexOf(u8, svg, needle) orelse return error.TestUnexpectedResult) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, svg, begin, '"').?;
    var values = std.mem.tokenizeAny(u8, svg[begin..end], " ()");
    try t.expectApproxEqAbs(x, try std.fmt.parseFloat(f64, values.next().?), 1e-5);
    try t.expectApproxEqAbs(y, try std.fmt.parseFloat(f64, values.next().?), 1e-5);
    try t.expectEqualStrings("rotate", values.next().?);
    try t.expectApproxEqAbs(angle, try std.fmt.parseFloat(f64, values.next().?), 1e-7);
}

test "missing duplicate ambiguous definition and overflowing angle targets fail" {
    const opacity = a.Track{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } };
    const animation = a.Animation{ .duration_seconds = 1, .tracks = &.{opacity} };
    try t.expectError(error.MissingTarget, encodeAnimatedSvg(t.allocator, "<svg/>", &animation));
    try t.expectError(error.DuplicateTarget, encodeAnimatedSvg(t.allocator, "<svg><g data-typst-label='libtypst-object-7'/><g data-typst-label='libtypst-object-7'/></svg>", &animation));
    try t.expectError(error.InvalidTarget, encodeAnimatedSvg(t.allocator, "<svg><defs><g data-typst-label='libtypst-object-7'/></defs></svg>", &animation));
    try t.expectError(error.InvalidTarget, encodeAnimatedSvg(t.allocator, "<svg xmlns:s='http://www.w3.org/2000/svg'><s:defs><g data-typst-label='libtypst-object-7'/></s:defs></svg>", &animation));
    const paint: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 9, .property = .{ .stroke_width = &.{ .{ .time = 0, .value = 1 }, .{ .time = 1, .value = 2 } } } }} };
    try t.expectError(error.AmbiguousPathTarget, encodeAnimatedSvg(t.allocator, fixture, &paint));
    const rotation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1e308 } } } } }} };
    try t.expectError(error.NonFinite, encodeAnimatedSvg(t.allocator, fixture, &rotation));
}

test "input has one static SVG root with only whitespace declaration and comments outside" {
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{} };
    const allowed = "<?xml version='1.0'?>\n<!--before--><svg xmlns='http://www.w3.org/2000/svg'><g/></svg>\n<!--after-->";
    const result = try encodeAnimatedSvg(t.allocator, allowed, &animation);
    defer t.allocator.free(result);
    try t.expectEqualStrings(allowed, result);
    for ([_][]const u8{ "", "<g/>", "<svg/><svg/>", "outside<svg/>", "<svg/>outside", "<![CDATA[outside]]><svg/>" }) |invalid| {
        try t.expectError(error.InvalidSvg, encodeAnimatedSvg(t.allocator, invalid, &animation));
    }
    for ([_][]const u8{
        "<svg xmlns='urn:not-svg'/>",
        "<svg><animate/></svg>",
        "<svg><animateTransform/></svg>",
        "<svg><animateMotion/></svg>",
        "<svg><set/></svg>",
        "<svg><?xml version='1.0'?></svg>",
    }) |unsupported| {
        try t.expectError(error.UnsupportedSvg, encodeAnimatedSvg(t.allocator, unsupported, &animation));
    }
}

test "writer fragments preserve nonempty path content and untouched attributes" {
    const source = "<svg><g data-typst-label='libtypst-object-7'><path data-note='A&amp;B' d='M0 0L1 1' fill='red'><!--keep--><![CDATA[<>&]]></path></g></svg>";
    const tracks = [_]a.Track{.{ .target = 7, .property = .{ .fill = &.{
        .{ .time = 0, .value = .black },
        .{ .time = 1, .value = .black },
    } } }};
    const output = try encodeAnimatedSvg(t.allocator, source, &.{ .duration_seconds = 1, .tracks = &tracks });
    defer t.allocator.free(output);
    try t.expect(std.mem.indexOf(u8, output, "data-note='A&amp;B' d='M0 0L1 1'") != null);
    try t.expect(std.mem.indexOf(u8, output, "fill-opacity=\"1\"><!--keep--><![CDATA[<>&]]></path>") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, output, "</path>"));
    var source_reader: @import("xml_parser").Reader.Static = .init(t.allocator, output, .{});
    defer source_reader.deinit();
    while (try source_reader.interface.read() != .eof) {}
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const route = [_]Path.Segment{ .{ .move = .{ .x = 20, .y = 30 } }, .{ .line = .{ .x = 100, .y = 30 } } };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 20, .y = 30 } } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 9, .property = .{ .motion = .{ .path = &route } } },
    } };
    const result = try encodeAnimatedSvg(allocator, fixture, &animation);
    defer allocator.free(result);
}
test "all allocation failures clean up locations edits and final SVG" {
    // Keep failure indices independent of heap placement and in-place growth,
    // using the same standard allocation fallback as the XML reader tests.
    var moving = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(moving.allocator(), allocationFailures, .{});
}

fn targetAllocationFailures(allocator: std.mem.Allocator) !void {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0.2 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
    };
    for (tracks) |track| {
        const result = try encodeAnimatedSvg(allocator, fixture, &.{ .duration_seconds = 1, .tracks = &.{track} });
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
    try t.expectError(error.InvalidSvg, encodeAnimatedSvg(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><g></svg>", &animation));
    try t.expectError(error.InvalidSvg, encodeAnimatedSvg(t.allocator, "<svg><g data-typst-label='libtypst-object-7'/><g data-typst-label='libtypst-object-7'/><g></svg>", &animation));
    try t.expectError(error.UnsupportedSvg, encodeAnimatedSvg(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><style/></svg>", &animation));
    try t.expectError(error.InvalidSvg, encodeAnimatedSvg(t.allocator, "<svg><g data-typst-label='libtypst-object-01'/><path id='same'/><path id='same'/></svg>", &animation));
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

test "interleaved target tracks preserve the original SVG byte order" {
    const tracks = [_]a.Track{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 1, .value = .{ .x = 2, .y = 3 } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = 1 } } } },
        .{ .target = 7, .property = .{ .fill = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .r = 1 } } } } },
        .{ .target = 9, .property = .{ .scale = &.{ .{ .time = 0, .value = .{ .x = 1, .y = 1 } }, .{ .time = 1, .value = .{ .x = 2, .y = 2 } } } } },
        .{ .target = 7, .property = .{ .rotate = .{ .keys = &.{ .{ .time = 0, .value = 0 }, .{ .time = 1, .value = std.math.pi } } } } },
        .{ .target = 7, .property = .{ .stroke = &.{ .{ .time = 0, .value = .black }, .{ .time = 1, .value = .{ .b = 1 } } } } },
    };
    const expected =
        "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100' viewBox='0 0 100 100'>" ++
        "<defs>" ++
        "<path id='glyph' d='M0 0L1 1'/>" ++
        "</defs>" ++
        "<g id=\"huak-object-7\">" ++
        "<g transform=\"translate(0 0)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"translate\" values=\"0 0;2 3\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g transform=\"rotate(0 0 0)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"rotate\" values=\"0 0 0;180 0 0\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g data-typst-label='libtypst-object-7' transform='translate(5 6)'>" ++
        "<path  d='M0 0L10 0Z' fill=\"rgb(0,0,0)\" fill-opacity=\"1\" stroke=\"rgb(0,0,0)\" stroke-opacity=\"1\">" ++
        "<animate attributeName=\"fill\" values=\"rgb(0,0,0);rgb(255,0,0)\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<animate attributeName=\"stroke\" values=\"rgb(0,0,0);rgb(0,0,255)\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "</path>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "<g id=\"huak-object-9\">" ++
        "<g opacity=\"0\">" ++
        "<animate attributeName=\"opacity\" values=\"0;1\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g transform=\"scale(1 1)\">" ++
        "<animateTransform attributeName=\"transform\" type=\"scale\" values=\"1 1;2 2\" dur=\"2s\" repeatCount=\"indefinite\"/>" ++
        "<g data-typst-label='libtypst-object-9'>" ++
        "<use href='#glyph'/>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "</g>" ++
        "</svg>";
    const output = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 2, .tracks = &tracks });
    defer t.allocator.free(output);
    try t.expectEqualStrings(expected, output);
}

test {
    _ = SmilEncoder;
}

test "SMIL timing omits defaults and numbers follow Typst's SVG precision" {
    // Evenly spaced linear keys, begin at 0, linear calcMode and the freeze of
    // an endless loop are all SMIL defaults.
    var keys: [26]a.ScalarKey = undefined;
    for (&keys, 0..) |*key, index| key.* = .{ .time = @as(f64, @floatFromInt(index)) / 25.0, .value = if (index % 2 == 0) 0.30974058379240427 else 0.1 };
    const looped = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 60, .tracks = &.{.{ .target = 9, .property = .{ .opacity = &keys } }} });
    defer t.allocator.free(looped);
    try t.expect(std.mem.indexOf(u8, looped, "<g opacity=\"0.309740584\"><animate attributeName=\"opacity\" values=\"0.309740584;0.1;0.309740584;") != null);
    try t.expect(std.mem.indexOf(u8, looped, ";0.1\" dur=\"60s\" repeatCount=\"indefinite\"/>") != null);
    for ([_][]const u8{ "keyTimes", "calcMode", "begin", "fill=\"freeze\"" }) |omitted| try t.expect(std.mem.indexOf(u8, looped, omitted) == null);
    // Uneven, discrete and motion timing stay explicit, as does the freeze of
    // a single run.
    const route = [_]Path.Segment{ .{ .move = .zero }, .{ .line = .{ .x = 10, .y = 0 } } };
    const explicit = try encodeAnimatedSvg(t.allocator, fixture, &.{ .duration_seconds = 2, .repeat = false, .tracks = &.{
        .{ .target = 7, .property = .{ .translate = &.{ .{ .time = 0, .value = .zero }, .{ .time = 0.37, .value = .{ .x = 1, .y = 0 } }, .{ .time = 1, .value = .{ .x = 2, .y = 0 } } } } },
        .{ .target = 9, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 }, .{ .time = 1, .value = 0 } } }, .easing = .discrete },
        .{ .target = 9, .property = .{ .motion = .{ .path = &route } } },
    } });
    defer t.allocator.free(explicit);
    try t.expect(std.mem.indexOf(u8, explicit, "values=\"0 0;1 0;2 0\" dur=\"2s\" fill=\"freeze\" keyTimes=\"0;0.37;1\"/>") != null);
    try t.expect(std.mem.indexOf(u8, explicit, "values=\"0;1;0\" dur=\"2s\" fill=\"freeze\" calcMode=\"discrete\" keyTimes=\"0;0.5;1\"/>") != null);
    try t.expect(std.mem.indexOf(u8, explicit, "keyPoints=\"0;1\" dur=\"2s\" fill=\"freeze\" calcMode=\"linear\" keyTimes=\"0;1\"/>") != null);
    try t.expect(std.mem.indexOf(u8, explicit, "repeatCount") == null);
    try t.expect(std.mem.indexOf(u8, explicit, "begin") == null);
}

test "animation semantic errors precede SVG parsing and allocation failure" {
    const invalid: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .opacity = &.{ .{ .time = 0, .value = 0 }, .{ .time = 0.5, .value = 1 } } } }} };
    try t.expectError(error.InvalidKeys, encodeAnimatedSvg(t.allocator, "<svg><script/></svg>", &invalid));
    try t.expectError(error.InvalidKeys, encodeAnimatedSvg(t.failing_allocator, fixture, &invalid));
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
        try t.expectError(error.InvalidKeys, encodeAnimatedSvg(failing.allocator(), fixture, &animation));
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
    try t.expectError(error.InvalidSvg, encodeAnimatedSvg(t.failing_allocator, "", &animation));
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

test "color constancy completion preserves every key and late validation" {
    var keys = [_]a.ColorKey{
        .{ .time = 0, .value = .{ .a = 0 } },
        .{ .time = 0.25, .value = .{ .r = 1, .a = 1 } },
        .{ .time = 0.75, .value = .{ .g = 1, .a = 0.4 } },
        .{ .time = 1, .value = .{ .b = 1, .a = 0.8 } },
    };
    const animation: a.Animation = .{ .duration_seconds = 1, .tracks = &.{.{ .target = 7, .property = .{ .fill = &keys } }} };
    const result = try encodeAnimatedSvg(t.allocator, fixture, &animation);
    defer t.allocator.free(result);
    try t.expect(std.mem.indexOf(u8, result, "values=\"rgb(0,0,0);rgb(255,0,0);rgb(0,255,0);rgb(0,0,255)\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "values=\"0;1;0.4;0.8\"") != null);
    keys[3].value.r = std.math.nan(f64);
    try t.expectError(error.InvalidColor, encodeAnimatedSvg(t.allocator, fixture, &animation));
}
