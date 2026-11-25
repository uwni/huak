//! Tests of placement: excluded children, enclosed objects, identity through growth and removal, placement across owners, transform and parent commits.
const std = @import("std");
const DisplayList = @import("../DisplayList.zig");
const g = @import("../geometry.zig");
const Path = @import("../path/Path.zig");
const Scene = @import("../Scene.zig");
const placement = @import("placement.zig");
const snapshots = @import("snapshots.zig");
const testing = @import("testing.zig");
const Index = Scene.Index;
const TestIds = testing.TestIds;

test "excluded child placements validate atomically and copy with their parent" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var hole = try Path.circle(a, .zero, 5);
    defer hole.deinit();
    const layer = try scene.addPath(0, &hole, &.{ .fill = .black }, .{});
    const outside = try scene.addPicture(null, .{}, null);
    try std.testing.expectError(error.DifferentParents, placement.exclude(&scene, 0, &.{ scene.object(layer), scene.object(outside) }, hole));
    try std.testing.expect(scene.object(layer).link().excluded == null);
    try placement.exclude(&scene, 0, &.{ scene.object(layer), scene.object(layer) }, hole);
    var clipped = try snapshots.snapshot(&scene, a, 0, null);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(usize, 5), clipped.picture.commands.items.len);
    var cloned = try scene.copy(a, null, 0);
    defer cloned.deinit();
    var copy_view = try snapshots.snapshot(&cloned, a, 0, null);
    defer copy_view.deinit();
    try std.testing.expectEqualDeep(clipped.picture.commands.items[1].push.clip, copy_view.picture.commands.items[1].push.clip);
    try placement.place(&scene, outside, scene.object(layer), null);
    try std.testing.expect(scene.object(layer).link().excluded == null);
}

test "an enclosed object keeps its place and its hole inside a new picture" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var disc = try Path.circle(a, .zero, 5);
    defer disc.deinit();
    const first = try scene.addPath(0, &disc, &.{ .fill = .black }, .{});
    const middle = try scene.addPath(0, &disc, &.{ .fill = .black }, .translation(20, 0));
    const last = try scene.addPath(0, &disc, &.{ .fill = .black }, .translation(40, 0));
    var hole = try Path.circle(a, .{ .x = 20, .y = 0 }, 2);
    defer hole.deinit();
    try placement.exclude(&scene, 0, &.{scene.object(middle)}, hole);
    try scene.setVisible(last, false);
    var before_ = try snapshots.snapshot(&scene, a, 0, null);
    defer before_.deinit();
    const box = try placement.enclose(&scene, middle);
    const end_ = try placement.enclose(&scene, last);
    try std.testing.expectError(error.NoParent, placement.enclose(&scene, 0));
    var order = try scene.children(0);
    try std.testing.expectEqual(first, order.next().?.index);
    try std.testing.expectEqual(box, order.next().?.index);
    try std.testing.expectEqual(end_, order.next().?.index);
    try std.testing.expect(order.next() == null);
    var inside = try scene.children(box);
    try std.testing.expectEqual(middle, inside.next().?.index);
    try std.testing.expect(inside.next() == null);
    try std.testing.expect(scene.object(middle).link().excluded == null);
    try std.testing.expect(scene.object(box).link().excluded != null);
    try std.testing.expect(!try scene.isVisible(last));
    // The same drawing one level deeper: the hole, then the new picture.
    var after = try snapshots.snapshot(&scene, a, 0, null);
    defer after.deinit();
    try std.testing.expectEqual(before_.picture.commands.items.len + 4, after.picture.commands.items.len);
    try std.testing.expect(after.picture.commands.items[2].push.clip != null);
    try std.testing.expect(after.picture.commands.items[3].push.clip == null);
    try std.testing.expectEqual(box, (try scene.parentObject(middle)).?.index);
    try std.testing.expectEqualDeep(try before_.picture.bounds(), try after.picture.bounds());
    // A new child still goes after the last one.
    const added = try scene.addPath(0, &disc, &.{ .fill = .black }, .{});
    order = try scene.children(0);
    _ = order.next();
    _ = order.next();
    try std.testing.expectEqual(end_, order.next().?.index);
    try std.testing.expectEqual(added, order.next().?.index);

    // At the nesting limit the object cannot go one level deeper.
    var deep = try Scene.init(a);
    defer deep.deinit();
    var parent: Index = 0;
    for (1..DisplayList.max_scope_depth) |_| parent = try deep.addPicture(parent, .{}, null);
    const leaf = try deep.addPath(parent, &disc, &.{ .fill = .black }, .{});
    const count = deep.nodes.items.len;
    try std.testing.expectError(error.GroupNestingTooDeep, placement.enclose(&deep, leaf));
    try std.testing.expectEqual(count, deep.nodes.items.len);
    try std.testing.expectEqual(parent, (try deep.parentObject(leaf)).?.index);
}

test "instances keep identity through growth order changes and removal" {
    const a = std.testing.allocator;
    var scene = try Scene.init(a);
    defer scene.deinit();
    var path = Path.init(a);
    defer path.deinit();
    try path.moveTo(.zero);
    try path.lineTo(.{ .x = 10, .y = 10 });
    const group = try scene.addPicture(0, .translation(20, 30), null);
    const first = try scene.addPath(null, &path, &.{ .fill = .black }, .{});
    try placement.place(&scene, group, scene.object(first), null);
    try placement.place(&scene, group, scene.object(first), null);
    const second = try scene.addPath(group, &path, &.{ .pen = .{} }, .{});
    for (0..100) |_| _ = try scene.addPath(0, &path, &.{ .fill = .black }, .{});
    try placement.before(&scene, second, scene.object(first));
    try std.testing.expectEqual(second, scene.object(group).container().first.index);
    try scene.applyTransform(first, .translation(3, 4));
    try std.testing.expectEqual(@as(f64, 3), (try scene.getNode(first)).path.transform.e);
    try std.testing.expectEqual(@as(f64, 0), (try scene.getNode(second)).path.transform.e);
    var selected = try snapshots.snapshot(&scene, a, first, null);
    defer selected.deinit();
    const box = (try selected.picture.bounds()).?;
    try std.testing.expectEqual(@as(f64, 23), box.min.x);
    try std.testing.expectEqual(@as(f64, 33), box.max.x);
    try std.testing.expectEqual(@as(usize, 5), selected.picture.commands.items.len);
    try placement.remove(&scene, group);
    try std.testing.expectEqual(group, (try scene.parentObject(first)).?.index);
    try std.testing.expectEqual(null, try scene.parentObject(group));
    try std.testing.expect((try scene.getNode(first)).* == .path);
    try placement.place(&scene, 0, scene.object(group), null);
    try std.testing.expectEqual(@as(Index, 0), (try scene.parentObject(group)).?.index);
    const later = try scene.addPath(0, &path, &.{ .fill = .black }, .{});
    try std.testing.expect(later > second);
}

test "placement across storage owners preserves identity geometry order and ancestry" {
    const a = std.testing.allocator;
    var source = try Scene.init(a);
    defer source.deinit();
    var first = try Scene.init(a);
    defer first.deinit();
    var second = try Scene.init(a);
    defer second.deinit();
    var curve = try Path.circle(a, .zero, 5);
    defer curve.deinit();
    const group_ = try source.addPicture(0, .translation(10, 20), &curve);
    const path = try source.addPath(group_, &curve, &.{ .fill = .black }, .{});
    const text = try source.label(group_, 7, .{ .width = 2, .height = 3, .baseline = 2 }, .zero, .{});
    const own = try first.addPath(0, &curve, &.{ .fill = .black }, .translation(30, 0));
    const geometry = source.storage.segments.items;
    const count = source.links.items.len;

    try placement.place(&first, 0, source.object(group_), null);
    try placement.place(&first, 0, source.object(group_), null);
    try placement.before(&source, group_, first.object(own));
    var children_ = try first.children(0);
    try std.testing.expect(children_.next().?.eql(source.object(group_)));
    try std.testing.expect(children_.next().?.eql(first.object(own)));
    try std.testing.expectEqual(null, children_.next());
    try std.testing.expect((try source.parentObject(group_)).?.eql(first.object(0)));
    try std.testing.expectError(error.ObjectCycle, placement.place(&source, group_, first.object(0), null));
    try std.testing.expect(first.contains(0, source.object(text)));

    {
        var view = try snapshots.snapshot(&first, a, 0, TestIds{ .scene = &first });
        defer view.deinit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 0, 0, 0, 0, 2, 0 }, view.ids.items);
        try std.testing.expectEqual(@as(usize, 2), view.owners.count());
        const borrowed = try view.picture.range(view.picture.commands.items[2].path.path);
        const original = try source.storage.range((try source.getNode(path)).path.path);
        try std.testing.expectEqual(original.ptr, borrowed.ptr);
        try std.testing.expectEqualDeep(try first.storage.range((try first.getNode(own)).path.path), try view.picture.range(view.picture.commands.items[5].path.path));
        var independent = try first.copy(a, null, 0);
        defer independent.deinit();
        var copied = try snapshots.snapshot(&independent, a, 0, null);
        defer copied.deinit();
        try std.testing.expectEqualDeep(try view.picture.bounds(), try copied.picture.bounds());
        try std.testing.expect((try copied.picture.range(copied.picture.commands.items[2].path.path)).ptr != borrowed.ptr);
    }
    try placement.place(&second, 0, source.object(group_), null);
    try std.testing.expect(!first.contains(0, source.object(path)));
    try placement.remove(&source, group_);
    try std.testing.expectEqual(null, try source.parentObject(group_));
    try std.testing.expect((try source.parentObject(text)).?.eql(source.object(group_)));
    try std.testing.expectEqual(geometry.ptr, source.storage.segments.items.ptr);
    try std.testing.expectEqual(geometry.len, source.storage.segments.items.len);
    try std.testing.expectEqual(count, source.links.items.len);
}

test "placement commits transform and parent together and preserves failure order" {
    const t = std.testing;
    var source = try Scene.init(t.allocator);
    defer source.deinit();
    var destination = try Scene.init(t.allocator);
    defer destination.deinit();
    const group_ = try source.addPicture(0, .translation(2, 3), null);
    const label_ = try source.label(group_, 0, .{ .width = 1, .height = 1, .baseline = 1 }, .zero, .{});
    const original = (try source.getNode(group_)).*;
    const invalid: g.Transform = .{ .a = std.math.inf(f64) };
    try t.expectError(error.NonFinite, placement.place(&source, label_, source.object(group_), invalid));
    try t.expectError(error.ExpectedPicture, placement.place(&source, label_, source.object(group_), .translation(4, 5)));
    try t.expectError(error.ObjectCycle, placement.place(&source, group_, source.object(group_), .translation(4, 5)));
    try t.expectEqualDeep(original, (try source.getNode(group_)).*);
    try t.expect((try source.parentObject(group_)).?.eql(source.object(0)));
    var deepest: Index = 0;
    for (1..DisplayList.max_scope_depth) |_| deepest = try destination.addPicture(deepest, .{}, null);
    try t.expectError(error.GroupNestingTooDeep, placement.place(&destination, deepest, source.object(group_), .translation(4, 5)));
    try t.expectEqualDeep(original, (try source.getNode(group_)).*);
    try t.expect((try source.parentObject(group_)).?.eql(source.object(0)));
    try placement.place(&destination, 0, source.object(group_), .translation(4, 5));
    try t.expectEqualDeep(g.Transform.translation(6, 8), (try source.getNode(group_)).picture.transform);
    try placement.place(&destination, 0, source.object(group_), .translation(4, 5));
    try t.expectEqualDeep(g.Transform.translation(10, 13), (try source.getNode(group_)).picture.transform);
    try t.expect((try source.parentObject(group_)).?.eql(destination.object(0)));
    const overflow: g.Transform = .{ .a = std.math.floatMax(f64), .e = std.math.floatMax(f64) };
    const before_value = (try source.getNode(group_)).*;
    try t.expectError(error.NonFinite, placement.place(&source, group_, source.object(group_), overflow));
    try t.expectEqualDeep(before_value, (try source.getNode(group_)).*);
    var children_ = try destination.children(0);
    _ = children_.next(); // Existing nested group remains first.
    try t.expect(children_.next().?.eql(source.object(group_)));
    try t.expectEqual(null, children_.next());
}
