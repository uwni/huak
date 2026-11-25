//! Binding animation tracks to the marked objects of the static SVG and their unique path: the target index, locations, path edits and animated attributes.
const std = @import("std");
const a = @import("../../../animation/root.zig");
const xml = @import("../xml.zig");
const svg_animation = @import("../animation.zig");
const object_label = svg_animation.object_label;

pub const Properties = std.EnumSet(std.meta.Tag(a.Property));

const animated_attributes = [_]struct { property: std.meta.Tag(a.Property), names: []const []const u8 }{
    .{ .property = .fill, .names = &.{ "fill", "fill-opacity" } },
    .{ .property = .stroke, .names = &.{ "stroke", "stroke-opacity" } },
    .{ .property = .stroke_width, .names = &.{"stroke-width"} },
    .{ .property = .path, .names = &.{"d"} },
};

pub const paint_properties = blk: {
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

pub const Range = struct { start: usize, end: usize };

/// styled: the source path has a class or style attribute of its own.
pub const PathEdit = struct { start: usize, end: usize, self_closing: bool, removal_start: usize, removal_count: usize, styled: bool };

/// Owns binding metadata only. Source offsets refer to the caller's SVG; no
/// XML reader, tag or attribute storage is retained during SMIL generation.
pub const Targets = struct {
    arena: std.heap.ArenaAllocator,
    locations: Locations = .empty,
    paths: std.ArrayList(PathEdit) = .empty,
    /// Where the root element's closing tag starts, which a stylesheet precedes.
    root_close: usize = 0,
    removals: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *Targets) void {
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

pub fn bindTargets(allocator: std.mem.Allocator, source: []const u8, animation: *const a.Animation) !Targets {
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

pub fn indexTracks(allocator: std.mem.Allocator, animation: *const a.Animation) !Locations {
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

pub fn locate(allocator: std.mem.Allocator, cursor: *xml.Cursor, targets: *Targets, source: []const u8) !void {
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
            if (stack.items.len == 0) targets.root_close = tag.start;
            continue;
        }
        const local_name = tag.name[if (std.mem.lastIndexOfScalar(u8, tag.name, ':')) |colon| colon + 1 else 0..];
        const defs = definition(local_name) or (stack.items.len != 0 and stack.items[stack.items.len - 1].defs);
        var target: ?usize = null;
        var object = false;
        for (0..cursor.attributeCount()) |attribute_index| {
            const attr = cursor.attribute(attribute_index);
            if (!std.mem.eql(u8, attr.name, "data-typst-label") or !std.mem.startsWith(u8, attr.value, object_label)) continue;
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
                        var styled = false;
                        for (0..cursor.attributeCount()) |attribute_index| {
                            const attr = cursor.attribute(attribute_index);
                            if (animatedAttribute(location, attr.name)) targets.removals.appendAssumeCapacity(.{ .start = attr.nameStart(source), .end = attr.valueEnd(source) + 1 });
                            styled = styled or std.mem.eql(u8, attr.name, "class") or std.mem.eql(u8, attr.name, "style");
                        }
                        const path_index = targets.paths.items.len;
                        targets.paths.appendAssumeCapacity(.{ .start = tag.start, .end = tag.end, .self_closing = tag.self_closing, .removal_start = removal_start, .removal_count = targets.removals.items.len - removal_start, .styled = styled });
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
    for (locations) |*location| {
        if (location.marker == null or location.end == 0) return error.MissingTarget;
    }
}

fn markerId(name: []const u8, value: []const u8) error{InvalidTarget}!u64 {
    if (!std.mem.eql(u8, name, "g")) return error.InvalidTarget;
    const suffix = value[object_label.len..];
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

pub fn isPaint(property: std.meta.Tag(a.Property)) bool {
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
