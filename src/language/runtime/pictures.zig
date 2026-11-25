//! Builtins for pictures and drawing objects.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const Scene = @import("../../drawing/Scene.zig");
const regions = @import("../../drawing/region/root.zig");
const transparency = @import("../../drawing/transparency.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const renderer = @import("../../render/root.zig");
const Value = types.Value;
const SceneOwner = @import("objects.zig").Owner;
const Runtime = @import("../Runtime.zig");
const object_handles = @import("object_handles.zig");
const conversions = @import("conversions.zig");
const transforms = @import("transforms.zig");
const Instance = object_handles.Instance;
const objectHandle = object_handles.objectHandle;
const boolean = conversions.boolean;
const numeric = conversions.numeric;
const sequence = conversions.sequence;
const lengthPoints = conversions.lengthPoints;
const checkedIndex = conversions.checkedIndex;
const point = conversions.point;

/// Accumulated display clip. The scene stores one root path, so each call
/// intersects the current path with the new region before replacing it.
fn intersectClip(self: *Runtime, instance: Instance, region: *const Path) !void {
    var current = (try instance.owner.scene.currentClip(instance.index)) orelse {
        try instance.owner.scene.setClip(instance.index, region);
        return;
    };
    defer current.deinit();
    // An already empty clip stays empty, but the new region is still checked.
    if (current.segments.items.len == 0) {
        try Scene.validateClip(region);
        return;
    }
    var combined = try regions.combine(self.scene_allocator, current, region.*, .intersect, .{ .fill_rule = .nonzero });
    defer combined.deinit();
    if (combined.segments.items.len == 0) {
        try instance.owner.scene.setEmptyClip(instance.index);
    } else {
        try instance.owner.scene.setClip(instance.index, &combined);
    }
}

fn place(self: *Runtime, destination: Value, value: Value, transform: ?g.Transform) !Value {
    const target = try object_handles.objectValue(self, destination, true);
    const source = try object_handles.objectValue(self, value, true);
    if (try source.owner.scene.parentObject(source.index)) |parent| _ = try object_handles.objectValue(self, objectHandle(parent), true);
    // A new descendant must satisfy the tracks on all destination ancestors.
    if (source.owner.hasResolvedStroke(source.index)) try checkStrokeAncestors(target);
    try Scene.placement.place(&target.owner.scene, target.index, source.owner.scene.object(source.index), transform);
    return value;
}

fn checkStrokeAncestors(instance: Instance) !void {
    var ancestor: ?Scene.Object = instance.owner.scene.object(instance.index);
    while (ancestor) |node| : (ancestor = try node.scene.parentObject(node.index)) {
        const owner: *SceneOwner = @fieldParentPtr("scene", node.scene);
        var tracks = owner.animation_state.iterator();
        while (tracks.next()) |track| {
            if (track.target != @as(u64, node.index) + 1) continue;
            switch (track.property) {
                .path, .stroke_width, .stroke, .fill => return error.UnsupportedResolvedStrokeAnimation,
                else => {},
            }
        }
    }
}

/// Pictures and drawing objects.
pub fn invoke(self: *Runtime, comptime id: builtin.Id, arg: builtin.Arguments(id)) !Value {
    switch (id) {
        .object_transform, .object_remove, .object_before, .object_style, .object_visible, .object_clip, .object_reset_clip, .object_opacity => {
            const instance = try object_handles.objectValue(self, arg.target, true);
            switch (id) {
                .object_visible => {
                    try instance.owner.scene.setVisible(instance.index, try boolean(arg.visible));
                },
                .object_style => {
                    const command = try instance.owner.scene.getNode(instance.index);
                    if (command.* != .path) return error.ExpectedPathObject;
                    var style = command.path.style.*;
                    if (arg.fill) |fill| style.fill = if (fill == .boolean and !fill.boolean) null else try conversions.paint(self, fill);
                    if (arg.pen) |pen| style.pen = if (pen == .boolean and !pen.boolean) null else try conversions.penValue(self, pen);
                    if (style.pen) |stroke| if (stroke.resolvesStroke()) try checkStrokeAncestors(instance);
                    try instance.owner.scene.setStyle(instance.index, &style);
                },
                .object_transform => try instance.owner.scene.applyTransform(instance.index, try conversions.transformValue(self, arg.transform)),
                .object_clip => {
                    const region = try self.path(arg.region);
                    try intersectClip(self, instance, &region);
                },
                .object_reset_clip => try instance.owner.scene.setClip(instance.index, null),
                .object_opacity => instance.owner.scene.setOpacity(instance.index, try numeric(arg.value)) catch |err| {
                    if (err == error.InvalidStyle) self.native_message = "a picture's opacity runs from 0 to 1";
                    return err;
                },
                .object_remove => {
                    try Scene.placement.remove(&instance.owner.scene, instance.index);
                },
                .object_before => {
                    const sibling = try object_handles.objectValue(self, arg.sibling, true);
                    try Scene.placement.before(&instance.owner.scene, instance.index, sibling.owner.scene.object(sibling.index));
                },
                else => unreachable,
            }
            return .unit;
        },
        .copy => {
            const source = try object_handles.objectValue(self, arg.value, false);
            try object_handles.requireStatic(self, source);
            const target = try object_handles.storeScene(self, try source.owner.scene.copy(self.scene_allocator, self.backends.meshes, source.index));
            return objectHandle(target.scene.object(0));
        },
        .object_exclude => {
            const sweep = try self.path(arg.hole);
            var painted: ?Path = null;
            defer if (painted) |*path_| path_.deinit();
            if (arg.brush) |value| {
                const brush = try conversions.penValue(self, value);
                painted = try renderer.strokeFootprint(self.gpa, sweep, &brush, null);
            }
            const parent = try object_handles.objectValue(self, arg.parent, true);
            const values = try sequence(arg.targets);
            const targets = try self.gpa.alloc(Scene.Object, values.len);
            defer self.gpa.free(targets);
            for (values, targets) |value, *object| {
                const target = try object_handles.objectValue(self, value, true);
                object.* = target.owner.scene.object(target.index);
            }
            Scene.placement.exclude(&parent.owner.scene, parent.index, targets, painted orelse sweep) catch |err| {
                if (err == error.DifferentParents) self.native_message = "erase targets must be direct children of the current drawing";
                return err;
            };
            return .unit;
        },
        .snapshot => return transforms.transformedObject(self, arg.target, .{}),
        .flatten_transparency => {
            var options: transparency.Options = .{ .meshes = self.backends.meshes };
            if (arg.paper) |value| options.paper = try conversions.color(self, value);
            if (options.paper.a != 1) {
                self.native_message = "flatten_transparency needs an opaque paper";
                return error.InvalidColor;
            }
            var selected = try object_handles.objectSnapshot(self, arg.target, true);
            defer selected.deinit();
            const flattened = transparency.flatten(self.scene_allocator, &selected.picture, options, self) catch |err| {
                switch (err) {
                    error.TranslucentText => self.native_message = "flatten_transparency cannot change the color of a native text; convert it with outlines first",
                    error.OverlappingVaryingPaints => self.native_message = "flatten_transparency combines at most four overlapping gradients, and only on one geometry: ramps between the same points, or fields on the same patches or rays",
                    else => {},
                }
                return err;
            };
            return object_handles.objectResult(self, flattened);
        },
        .canvas => {
            const target = try object_handles.objectValue(self, arg.target, true);
            const settings = try target.owner.scene.settings(target.index);
            const w = try lengthPoints(arg.width);
            const h = try lengthPoints(arg.height);
            try validateCanvas(w, h);
            settings.size = .{ .x = w, .y = h };
            return .unit;
        },
        .append => return place(self, arg.target, arg.source, if (arg.transform) |transform| try conversions.transformValue(self, transform) else null),
        .draw, .fill, .filldraw, .label => {
            return switch (id) {
                .draw, .fill, .filldraw => result: {
                    const path_ = try self.path(arg.curve);
                    const style: DisplayList.Style = switch (id) {
                        .draw => .{ .pen = if (arg.pen) |pen| try conversions.penValue(self, pen) else .{} },
                        .fill => .{ .fill = if (arg.paint) |given| try conversions.paint(self, given) else .black },
                        .filldraw => .{ .fill = try conversions.paint(self, arg.paint), .pen = try conversions.penValue(self, arg.pen) },
                        else => unreachable,
                    };
                    break :result object_handles.pathObject(self, &path_, &style, if (arg.transform) |placement| try conversions.transformValue(self, placement) else .{});
                },
                .label => result: {
                    const i = try checkedIndex(arg.body, .text, self.texts.items.len);
                    break :result object_handles.labelObject(self, @intCast(i), try point(arg.position), if (arg.transform) |placement| try conversions.transformValue(self, placement) else .{});
                },
                else => unreachable,
            };
        },
        .object => {
            if (arg.source == .omitted) return error.InvalidArguments;
            return switch (arg.source.valueType()) {
                .path => result: {
                    const curve = try self.path(arg.source);
                    const style: DisplayList.Style = .{
                        .fill = if (arg.fill) |fill| try conversions.paint(self, fill) else if (arg.pen != null) null else .black,
                        .pen = if (arg.pen) |pen| try conversions.penValue(self, pen) else null,
                    };
                    break :result object_handles.pathObject(self, &curve, &style, .{});
                },
                .text => result: {
                    if (arg.fill != null or arg.pen != null) return error.InvalidStyle;
                    const reference = try checkedIndex(arg.source, .text, self.texts.items.len);
                    break :result object_handles.labelObject(self, @intCast(reference), .zero, .{});
                },
                else => {
                    self.native_message = "object source must be a path or text";
                    return error.TypeMismatch;
                },
            };
        },
        .picture => {
            if ((arg.width == null) != (arg.height == null)) return error.InvalidCanvas;
            const size: ?g.Point = if (arg.width) |width| .{ .x = try lengthPoints(width), .y = try lengthPoints(arg.height.?) } else null;
            if (size) |value| try validateCanvas(value.x, value.y);
            const owner = try self.gpa.create(SceneOwner);
            errdefer self.gpa.destroy(owner);
            owner.* = .{ .scene = .{ .storage = .initWithMeshes(self.scene_allocator, self.backends.meshes) }, .owner_index = try object_handles.nextOwnerIndex(self), .animation_state = .init(self.gpa) };
            errdefer owner.scene.deinit();
            const index = try owner.scene.addPicture(null, .{}, null);
            (try owner.scene.settings(index)).size = size;
            try self.scene_values.append(self.gpa, owner);
            return objectHandle(owner.scene.object(index));
        },
        else => comptime unreachable,
    }
}

fn validateCanvas(w: f64, h: f64) !void {
    if (w <= 0 or h <= 0 or !std.math.isFinite(w) or !std.math.isFinite(h)) return error.InvalidCanvas;
}
