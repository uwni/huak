//! Reading the source: its groups as items, its paints and clips as the
//! flattener's leaves and clips, in world coordinates.
const std = @import("std");
const g = @import("../geometry.zig");
const DisplayList = @import("../DisplayList.zig");
const transparency = @import("../transparency.zig");
const Component = transparency.Component;
const Item = transparency.Item;
const intersectBoxes = transparency.intersectBoxes;

pub fn parse(self: anytype, picture: *const DisplayList, base: g.Transform, clip: ?u32) ![]const Item {
    if (picture.scope_depth != 0) return error.UnbalancedGroups;
    var index: usize = 0;
    return scope(self, picture, &index, base, clip, false);
}

fn scope(self: anytype, picture: *const DisplayList, index: *usize, transform: g.Transform, clip: ?u32, grouped: bool) anyerror![]const Item {
    var items: std.ArrayList(Item) = .empty;
    while (index.* < picture.commands.items.len) {
        const command = picture.commands.items[index.*];
        index.* += 1;
        switch (command) {
            .pop => {
                if (!grouped) return error.UnbalancedGroups;
                return items.items;
            },
            .push => |group| {
                const inner = group.transform.then(transform);
                if (!inner.isFinite()) return error.NonFinite;
                var inner_clip = clip;
                if (group.clip) |reference| inner_clip = try addClip(self, picture, reference, inner, clip);
                const content = try scope(self, picture, index, inner, inner_clip, true);
                if (group.opacity == 0) continue;
                if (group.opacity == 1) {
                    try items.appendSlice(self.arena, content);
                } else try items.append(self.arena, .{ .layer = .{ .opacity = group.opacity, .items = content } });
            },
            .path => |draw| {
                const world = draw.transform.then(transform);
                if (!world.isFinite()) return error.NonFinite;
                if (draw.style.hasInk(.fill)) {
                    if (try addLeaf(self, picture, command, .fill, world, clip)) |id| try items.append(self.arena, .{ .leaf = id });
                }
                if (draw.style.pen) |pen| if (draw.style.hasInk(.stroke) and (pen.needsGeometry() or pen.width != 0)) {
                    if (try addLeaf(self, picture, command, .stroke, world, clip)) |id| try items.append(self.arena, .{ .leaf = id });
                };
            },
            .label => |label| {
                const world = label.transform.then(transform);
                if (!world.isFinite()) return error.NonFinite;
                if (try addLeaf(self, picture, command, .text, world, clip)) |id| try items.append(self.arena, .{ .leaf = id });
            },
        }
    }
    if (grouped) return error.UnbalancedGroups;
    return items.items;
}

fn addClip(self: anytype, picture: *const DisplayList, reference: DisplayList.PathRef, transform: g.Transform, parent: ?u32) !u32 {
    const local = try picture.geometry().view(self.arena, reference);
    const path = try local.transformed(self.arena, transform);
    var box = path.bounds() orelse return error.InvalidPath;
    if (parent) |outer| box = intersectBoxes(box, self.clips.items[outer].bounds) orelse g.BBox{ .min = box.min, .max = box.min };
    try self.clips.append(self.arena, .{ .path = path, .parent = parent, .bounds = box });
    return @intCast(self.clips.items.len - 1);
}

/// Null when the clips around it leave nothing to paint.
fn addLeaf(self: anytype, picture: *const DisplayList, command: DisplayList.Command, component: Component, transform: g.Transform, clip: ?u32) !?u32 {
    var box: g.BBox = switch (component) {
        .text => (g.BBox{ .min = .zero, .max = .{ .x = command.label.metrics.width, .y = command.label.metrics.height } }).transformed(transform),
        else => (try DisplayList.pathBounds(try picture.range(command.path.path), if (component == .stroke) command.path.style.pen else null, transform)) orelse return null,
    };
    if (clip) |inner| box = intersectBoxes(box, self.clips.items[inner].bounds) orelse return null;
    try self.leaves.append(self.arena, .{ .picture = picture, .command = command, .component = component, .transform = transform, .clip = clip, .bounds = box });
    return @intCast(self.leaves.items.len - 1);
}
