//! Editable outline snapshots of labels and pictures, shared by region, outlines, object paths and the label resolver.
const std = @import("std");
const typst = @import("libtypst");
const Path = @import("../../drawing/path/Path.zig");
const DisplayList = @import("../../drawing/DisplayList.zig");
const geometry_outline = @import("../../drawing/outline.zig");
const outline = @import("../../text/outline.zig");
const types = @import("../types.zig");
const builtin = @import("../builtin.zig");
const testOwner = @import("testing.zig").testOwner;
const Value = types.Value;
const Type = types.Type;
const Runtime = @import("../Runtime.zig");
const typesetting = @import("typesetting.zig");
const object_handles = @import("object_handles.zig");
const conversions = @import("conversions.zig");
const builtin_calls = @import("builtin_calls.zig");
const checkedIndex = conversions.checkedIndex;
const sequence = conversions.sequence;

pub fn outlinedLabel(self: *Runtime, reference: usize) !*const outline.Label {
    if (reference >= self.texts.items.len) return error.InvalidFrameReference;
    const text = self.texts.items[reference];
    const batch = self.outline_cache.getPtr(text.layout) orelse cache: {
        var extracted = outline.extract(self.gpa, text.layout) catch |err| {
            typesetting.captureNative(self);
            return err;
        };
        errdefer extracted.deinit();
        try self.outline_cache.put(self.gpa, text.layout, extracted);
        break :cache self.outline_cache.getPtr(text.layout).?;
    };
    if (text.frame >= batch.labels.len) return error.InvalidFrameReference;
    return &batch.labels[text.frame];
}

/// Preserve drawing data. Numeric region conversion belongs to the
/// polygon adapter and must not be an implicit part of this snapshot.
pub fn vectorPicture(self: *Runtime, allocator: std.mem.Allocator, object: Value, operation: builtin.Id) !DisplayList {
    switch (object.valueType()) {
        .path => return geometry_outline.extract(allocator, .{ .path = try self.path(object) }, self),
        .text => {
            const reference = try checkedIndex(object, .text, self.texts.items.len);
            var result = DisplayList.init(allocator);
            errdefer result.deinit();
            // The cached parts are already an ordinary path picture; build
            // it once instead of copying it through an intermediate
            // picture and a second outline extraction.
            try (try outlinedLabel(self, reference)).addToPicture(&result, .{});
            try geometry_outline.ensureWithinBudget(&result);
            return result;
        },
        .object, .picture => {
            var selected = try object_handles.objectSnapshot(self, object, true);
            defer selected.deinit();
            return geometry_outline.extract(allocator, .{ .picture = &selected.picture }, self);
        },
        else => {
            self.native_message = if (operation == .region) "region requires a path, text, or object" else "outlines requires a path, text, or object";
            return error.TypeMismatch;
        },
    }
}

pub fn extractOutlines(self: *Runtime, object: Value) !Value {
    return object_handles.objectResult(self, try vectorPicture(self, self.scene_allocator, object, .outlines));
}

pub fn rawPaths(self: *Runtime, allocator: std.mem.Allocator, object: Value) !Value {
    var selected = try object_handles.objectSnapshot(self, object, true);
    defer selected.deinit();
    var extracted: ?DisplayList = null;
    defer if (extracted) |*value| value.deinit();
    const source = source: {
        for (selected.picture.commands.items) |command| if (command == .label) {
            extracted = try geometry_outline.extract(self.gpa, .{ .picture = &selected.picture }, self);
            break :source &extracted.?;
        };
        break :source &selected.picture;
    };
    const raw = try geometry_outline.rawPaths(self.gpa, source);
    defer self.gpa.free(raw);
    var moved = false;
    defer if (!moved) for (raw) |*item| item.deinit();
    const result = try allocator.alloc(Value, raw.len);
    errdefer allocator.free(result);
    try conversions.pathResults(self, raw, result);
    moved = true;
    return types.listView(result);
}

fn outlineAllocationExercise(a: std.mem.Allocator) !void {
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const rectangle = try builtin_calls.invoke(&runtime, a, .rectangle, &.{ .{ .vec2 = .zero }, .{ .number = 5 }, .{ .number = 8 } });
    const result = try builtin_calls.invoke(&runtime, a, .outlines, &.{rectangle});
    try std.testing.expectEqual(Type.object, result.valueType());
    const host_value = runtime.host();
    const items = try sequence(try host_value.field(a, result, "paths"));
    defer a.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const path_ = try runtime.path(items[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 5), path_.bounds().?.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 8), path_.bounds().?.max.y, 1e-10);
    try std.testing.expect(runtime.engine == null);
    try std.testing.expectError(error.TypeMismatch, builtin_calls.invoke(&runtime, a, .outlines, &.{.{ .int = 1 }}));
    try std.testing.expectEqualStrings("outlines requires a path, text, or object", runtime.native_message);
    try std.testing.expectError(error.InvalidTolerance, builtin_calls.invoke(&runtime, a, .region, &.{ rectangle, .{ .number = 0 } }));
    try std.testing.expectEqualStrings("region tolerance must be positive", runtime.native_message);
}

test "outline results own geometry and pure paths require no Typst engine across OOM" {
    try outlineAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), outlineAllocationExercise, .{});
}

test "outline snapshots preserve original cubic controls styles and independent path storage" {
    const a = std.testing.allocator;
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(a, a, &unused_library, .{});
    defer runtime.deinit();
    const curve = try builtin_calls.invoke(&runtime, a, .bezier, &.{
        .{ .vec2 = .{ .x = 0.125, .y = -0.375 } },
        .{ .vec2 = .{ .x = 1.0 / 3.0, .y = 17.0 / 11.0 } },
        .{ .vec2 = .{ .x = 9.0 / 7.0, .y = -3.0 / 13.0 } },
        .{ .vec2 = .{ .x = 2.625, .y = 0.875 } },
    });
    const source = try runtime.path(curve);
    const snapshot = try builtin_calls.invoke(&runtime, a, .outlines, &.{curve});
    const picture = (try object_handles.objectValue(&runtime, snapshot, false)).owner;
    try std.testing.expectEqualDeep(source.segments.items, picture.scene.storage.segments.items);
    try std.testing.expect(source.segments.items.ptr != picture.scene.storage.segments.items.ptr);
    const host_value = runtime.host();
    const entries = try sequence(try host_value.field(a, snapshot, "paths"));
    defer a.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const returned = try runtime.path(entries[0]);
    try std.testing.expectEqualDeep(source.segments.items, returned.segments.items);
    try std.testing.expectEqual(@as(usize, 1), returned.segmentCount());
    const marker = try builtin_calls.invoke(&runtime, a, .path, &.{.{ .vec2 = .{ .x = 4, .y = -2 } }});
    const marker_copy = try builtin_calls.invoke(&runtime, a, .outlines, &.{marker});
    try std.testing.expectEqualDeep((try runtime.path(marker)).segments.items, (try object_handles.objectValue(&runtime, marker_copy, false)).owner.scene.storage.segments.items);
    const marker_region = try builtin_calls.invoke(&runtime, a, .region, &.{marker});
    try std.testing.expectEqual(@as(usize, 0), (try runtime.path(marker_region)).segments.items.len);
    try std.testing.expect(runtime.engine == null);
}

test "raw vector paths borrow source paints without copying their storage and retain animation guards" {
    const a = std.testing.allocator;
    var tracking = std.testing.FailingAllocator.init(a, .{});
    const counted = tracking.allocator();
    var unused_library: typst.Library = undefined;
    var runtime = try Runtime.init(counted, counted, &unused_library, .{});
    defer runtime.deinit();
    const target = try builtin_calls.invoke(&runtime, counted, .picture, &.{});
    const original = testOwner(target);
    var curve = Path.init(a);
    defer curve.deinit();
    try curve.moveTo(.zero);
    try curve.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = -2 }, .{ .x = 5, .y = 0 });
    var dashes: [4096]f64 = @splat(1);
    const drawn = try original.scene.addPath(0, &curve, &.{ .pen = .{ .width = 1, .dash = &dashes } }, .{});
    const before = tracking.allocated_bytes;
    const host_value = runtime.host();
    const entries = try sequence(try host_value.field(counted, target, "paths"));
    defer counted.free(entries);
    // Reading one short curve must not allocate another copy of its much
    // larger paint data. The bound allows normal path/list/arena overhead.
    try std.testing.expect(tracking.allocated_bytes - before < @sizeOf(@TypeOf(dashes)));
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const returned = try runtime.path(entries[0]);
    try std.testing.expectEqualDeep(curve.segments.items, returned.segments.items);
    try std.testing.expect(returned.segments.items.ptr != original.scene.storage.segments.items.ptr);
    try std.testing.expectEqual(@as(usize, 2), original.scene.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.scene_values.items.len);
    try std.testing.expect(runtime.engine == null);
    _ = try builtin_calls.invoke(&runtime, counted, .timeline, &.{ target, .{ .number = 2 } });
    const id: Value = .{ .object = .{ .owner = original, .index = drawn } };
    _ = try builtin_calls.invoke(&runtime, counted, .animate, &.{ id, .{ .string = "opacity" }, types.listView(&.{
        types.listView(&.{ .{ .int = 0 }, .{ .number = 0 } }),
        types.listView(&.{ .{ .int = 1 }, .{ .number = 1 } }),
    }) });
    try std.testing.expectError(error.AnimatedPicture, host_value.field(counted, target, "paths"));
    try std.testing.expectEqualStrings("operation requires a static object (including its ancestors and descendants)", runtime.native_message);
}
