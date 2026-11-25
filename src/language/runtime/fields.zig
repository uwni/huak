//! Reading a field of a native value: the host field callback.
const std = @import("std");
const g = @import("../../drawing/geometry.zig");
const Path = @import("../../drawing/path/Path.zig");
const types = @import("../types.zig");
const renderer = @import("../../render/root.zig");
const Value = types.Value;
const Runtime = @import("../Runtime.zig");
const conversions = @import("conversions.zig");
const typeset_text = @import("typeset_text.zig");
const object_handles = @import("object_handles.zig");
const outlines = @import("outlines.zig");
const transforms = @import("transforms.zig");
const pen = @import("pen.zig");
const from = Runtime.from;
const lengthResult = conversions.lengthResult;
const checkedIndex = conversions.checkedIndex;
const objectHandle = object_handles.objectHandle;

pub fn field(ctx: ?*anyopaque, allocator: std.mem.Allocator, object: Value, name: []const u8) !Value {
    const self = from(ctx);
    if (self.outputs_taken) return error.InvalidState;
    if (object.valueType() == .shape) {
        const node = try self.model(object);
        if (std.mem.eql(u8, name, "kind")) return .{ .string = @tagName(node.kind) };
        if (std.mem.eql(u8, name, "arguments")) return types.listView(node.arguments);
    } else if (object.valueType() == .path and std.mem.eql(u8, name, "linear_axis")) {
        const axis = Path.contours.linearAxis(try self.path(object)) orelse return .{ .boolean = false };
        return types.listView(try allocator.dupe(Value, &.{ .{ .vec2 = types.Vec2.fromPoint(axis[0]) }, .{ .vec2 = types.Vec2.fromPoint(axis[1]) } }));
    } else if (object.valueType() == .color) {
        const rgba = try conversions.color(self, object);
        inline for (.{ "r", "g", "b", "a" }) |channel|
            if (std.mem.eql(u8, name, channel)) return .{ .number = @field(rgba, channel) };
    } else if (object.valueType() == .pen) {
        if (std.mem.eql(u8, name, "paint")) return conversions.paintResult(self, (try conversions.penValue(self, object)).paint);
    } else if (object.valueType() == .text) {
        const metrics = (try conversions.textValue(self, object)).metrics;
        if (std.mem.eql(u8, name, "width")) return lengthResult(metrics.width);
        if (std.mem.eql(u8, name, "height")) return lengthResult(metrics.height);
        if (std.mem.eql(u8, name, "baseline")) return lengthResult(metrics.baseline);
        if (std.mem.eql(u8, name, "anchors")) return typeset_text.textAnchors(self, object);
    } else if (object.valueType() == .anchor) {
        const anchor = self.anchors.items[try checkedIndex(object, .anchor, self.anchors.items.len)];
        const point_: g.Point = if (std.mem.eql(u8, name, "position"))
            anchor.position
        else if (std.mem.eql(u8, name, "min"))
            anchor.min
        else if (std.mem.eql(u8, name, "max"))
            anchor.max
        else if (std.mem.eql(u8, name, "center"))
            anchor.min.add(anchor.max).scale(0.5)
        else
            return error.UnknownField;
        return .{ .vec2 = types.Vec2.fromPoint(point_) };
    } else if (object.valueType() == .solution) {
        const solved = self.solutions.items[try checkedIndex(object, .solution, self.solutions.items.len)].solution;
        if (std.mem.eql(u8, name, "status")) return .{ .string = @tagName(solved.status) };
        if (std.mem.eql(u8, name, "rank")) return .{ .int = @intCast(solved.rank) };
    } else if (object == .object) {
        const instance = try object_handles.objectValue(self, object, false);
        if (object.valueType() == .picture) {
            if (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height")) {
                const settings = try instance.owner.scene.settings(instance.index);
                const size = settings.size orelse size: {
                    var selected = try object_handles.objectSnapshot(self, object, false);
                    defer selected.deinit();
                    const viewport = try renderer.viewport(&selected.picture, null, self.frames.items);
                    break :size viewport.max.sub(viewport.min);
                };
                return lengthResult(if (std.mem.eql(u8, name, "width")) size.x else size.y);
            }
        }
        if (std.mem.eql(u8, name, "paths")) return outlines.rawPaths(self, allocator, object);
        if (std.mem.eql(u8, name, "visible")) return .{ .boolean = try instance.owner.scene.isVisible(instance.index) };
        if (std.mem.eql(u8, name, "parent")) return if (try instance.owner.scene.parentObject(instance.index)) |parent| objectHandle(parent) else .{ .boolean = false };
        if (std.mem.eql(u8, name, "children")) {
            var iterator = try instance.owner.scene.children(instance.index);
            var values: std.ArrayList(Value) = .empty;
            errdefer values.deinit(allocator);
            while (iterator.next()) |child| try values.append(allocator, objectHandle(child));
            return types.listView(try values.toOwnedSlice(allocator));
        }
        const command = try instance.owner.scene.getNode(instance.index);
        if (std.mem.eql(u8, name, "transform")) return transforms.transformResult(self, switch (command.*) {
            .path => |draw| draw.transform,
            .label => |label| label.transform,
            .picture => |group| group.transform,
        }, 1);
        if (std.mem.eql(u8, name, "fill") or std.mem.eql(u8, name, "pen")) {
            if (command.* != .path) return error.ExpectedPathObject;
            if (std.mem.eql(u8, name, "fill")) return if (command.path.style.fill) |value| conversions.paintResult(self, value) else .{ .boolean = false };
            return pen.storePen(self, command.path.style.pen orelse return .{ .boolean = false });
        }
        if (std.mem.eql(u8, name, "animated")) {
            return .{ .boolean = object_handles.hasAnimation(self, instance) };
        }
        if (std.mem.eql(u8, name, "kind")) return .{ .string = switch ((try instance.owner.scene.getNode(instance.index)).*) {
            .path => "path",
            .label => "text",
            .picture => "picture",
        } };
    } else if (object.valueType() == .measure) {
        const measure = self.measures.items[try checkedIndex(object, .measure, self.measures.items.len)];
        if (std.mem.eql(u8, name, "length")) return lengthResult(measure.length);
        if (std.mem.eql(u8, name, "contours")) return .{ .int = @intCast(measure.contours.len) };
        if (std.mem.eql(u8, name, "curves")) {
            const curves = try allocator.alloc(Value, measure.curves.len);
            for (curves, measure.curves) |*value, curve| {
                const points = try allocator.alloc(Value, 4);
                for (points, [_]g.Point{ curve.p0, curve.p1, curve.p2, curve.p3 }) |*point_, point_value| point_.* = .{ .vec2 = types.Vec2.fromPoint(point_value) };
                value.* = types.listView(points);
            }
            return types.listView(curves);
        }
    }
    return error.UnknownField;
}
