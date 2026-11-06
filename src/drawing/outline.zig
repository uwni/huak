//! Editable vectorization with original curves, paints and clipping scopes.
//! Native labels are resolved into independent vector pictures. No polygon
//! operation, stroke expansion, geometric tolerance or flattening occurs here.
const std = @import("std");
const g = @import("geometry.zig");
const Path = @import("path/Path.zig");
const DisplayList = @import("DisplayList.zig");
const Allocator = std.mem.Allocator;

pub const StyledPath = struct {
    path: Path,
    style: DisplayList.Style,
    transform: g.Transform = .{},
};
pub const Source = union(enum) {
    /// A raw path keeps its segments, including open contours, and receives
    /// the ordinary nonzero black fill. Empty paths produce empty pictures.
    path: Path,
    styled: StyledPath,
    picture: *const DisplayList,
};

/// Bound copied commands, geometry and style arrays, including recursive label
/// expansion. DisplayList's existing group limit independently bounds recursion.
pub const max_items: usize = 1_048_576;
const Budget = struct {
    items: usize = 0,
    fn consume(self: *Budget, count: usize) !void {
        if (count > max_items - self.items) return error.GeometryWorkLimit;
        self.items += count;
    }
    fn geometry(self: *Budget, segments: []const Path.Segment) !void {
        for (segments) |segment| try self.consume(if (segment == .cubic) 3 else 1);
    }
    fn style(self: *Budget, value: DisplayList.Style) !void {
        if (value.gradient) |paint| try self.consume(paint.colors.len);
        if (value.pen) |pen| {
            try self.consume(pen.dash.len);
            if (pen.motion) |p| try self.consume(p.keys.len);
            if (pen.nib) |nib| if (nib == .polygon) try self.consume(nib.polygon.len);
        }
    }
};

/// Return an independently owned picture containing only ordinary path and
/// group commands. The input, resolver context and original native labels stay
/// borrowed. All source paints, transforms and control points are copied.
/// The typed resolver provides `resolveOutline(allocator, reference)` and returns
/// an owned temporary display list in frame-local x-right/y-down coordinates.
/// Pass null when no native labels can be resolved; no resolver is retained.
pub fn extract(allocator: Allocator, source: Source, resolver: anytype) !DisplayList {
    var builder: Builder(@TypeOf(resolver)) = .{ .result = DisplayList.init(allocator), .resolver = if (@TypeOf(resolver) == @TypeOf(null)) {} else resolver };
    errdefer builder.result.deinit();
    switch (source) {
        .path => |*path| {
            const style: DisplayList.Style = .{ .fill = .black };
            try builder.add(path, &style, .{});
        },
        .styled => |*styled| try builder.add(&styled.path, &styled.style, styled.transform),
        .picture => |value| try builder.visit(value, 0),
    }
    return builder.result;
}

fn Builder(comptime Resolver: type) type {
    return struct {
        const Self = @This();
        result: DisplayList,
        resolver: if (Resolver == @TypeOf(null)) void else Resolver,
        budget: Budget = .{},

        fn add(self: *Self, path: *const Path, style: *const DisplayList.Style, transform: g.Transform) !void {
            try DisplayList.validateStyle(style);
            if (!transform.isFinite()) return error.NonFinite;
            try self.budget.geometry(path.segments.items);
            try self.budget.style(style.*);
            if (path.segments.items.len == 0) return;
            try self.result.addPathView(path, style, transform);
        }
        fn visit(self: *Self, source: *const DisplayList, recursion: usize) anyerror!void {
            if (recursion > DisplayList.max_scope_depth) return error.GroupNestingTooDeep;
            if (source.scope_depth != 0) return error.UnbalancedGroups;
            const initial_depth = self.result.scope_depth;
            for (source.commands.items) |*command| {
                try self.budget.consume(1);
                switch (command.*) {
                    .path => |*draw| {
                        var path = borrowed(source.storage.allocator, try source.range(draw.path));
                        try self.add(&path, draw.style, draw.transform);
                    },
                    .push => |*group| {
                        var clip: ?Path = null;
                        if (group.clip) |reference| {
                            const segments = try source.range(reference);
                            try self.budget.geometry(segments);
                            clip = borrowed(source.storage.allocator, segments);
                        }
                        if (clip) |*path| try self.result.beginScopeView(group.transform, path) else try self.result.beginScopeView(group.transform, null);
                    },
                    .pop => {
                        if (self.result.scope_depth == initial_depth) return error.UnbalancedGroups;
                        try self.result.endScope();
                    },
                    .label => |*label| {
                        if (comptime Resolver == @TypeOf(null)) return error.LabelResolverRequired;
                        var resolved = try self.resolver.resolveOutline(self.result.storage.allocator, label.reference);
                        defer resolved.deinit();
                        try self.result.beginScope(label.transform, null);
                        try self.visit(&resolved, recursion + 1);
                        try self.result.endScope();
                    },
                }
            }
            if (self.result.scope_depth != initial_depth) return error.UnbalancedGroups;
        }
    };
}

/// Validate an already assembled picture against the same work budget used by
/// extract without copying it. This is used when an outline picture is built
/// directly from its cached parts.
pub fn ensureWithinBudget(source: *const DisplayList) !void {
    if (source.scope_depth != 0) return error.UnbalancedGroups;
    var budget: Budget = .{};
    for (source.commands.items) |*command| {
        try budget.consume(1);
        switch (command.*) {
            .path => |*draw| {
                try budget.geometry(try source.range(draw.path));
                try budget.style(draw.style.*);
            },
            .push => |*group| if (group.clip) |reference| try budget.geometry(try source.range(reference)),
            .label => return error.LabelResolverRequired,
            .pop => {},
        }
    }
}

/// Copy path commands in paint order, applying path and ancestor transforms to
/// their original control points. This is a raw geometry view: clips are not
/// baked in, fill rules are not normalized, and strokes remain centerlines.
/// Labels must first be vectorized with extract. The caller owns every returned
/// path and frees the slice after deinitializing those paths.
pub fn rawPaths(allocator: Allocator, source: *const DisplayList) ![]Path {
    if (source.scope_depth != 0) return error.UnbalancedGroups;
    var result: std.ArrayList(Path) = .empty;
    errdefer {
        for (result.items) |*path| path.deinit();
        result.deinit(allocator);
    }
    var stack: [DisplayList.max_scope_depth]g.Transform = undefined;
    var depth: usize = 0;
    var transform: g.Transform = .{};
    var budget: Budget = .{};
    for (source.commands.items) |command| {
        try budget.consume(1);
        switch (command) {
            .path => |draw| {
                const segments = try source.range(draw.path);
                try budget.geometry(segments);
                const world = draw.transform.then(transform);
                if (!world.isFinite()) return error.NonFinite;
                var copied = try copyPath(allocator, segments);
                errdefer copied.deinit();
                // Pure copies preserve all f64 bits, including signed zero.
                if (!std.meta.eql(world, g.Transform{})) try copied.transform(world);
                try result.append(allocator, copied);
            },
            .push => |group| {
                if (depth == stack.len) return error.GroupNestingTooDeep;
                if (group.clip) |reference| try budget.geometry(try source.range(reference));
                stack[depth] = transform;
                depth += 1;
                transform = group.transform.then(transform);
                if (!transform.isFinite()) return error.NonFinite;
            },
            .pop => {
                if (depth == 0) return error.UnbalancedGroups;
                depth -= 1;
                transform = stack[depth];
            },
            .label => return error.LabelResolverRequired,
        }
    }
    if (depth != 0) return error.UnbalancedGroups;
    return result.toOwnedSlice(allocator);
}

fn borrowed(allocator: Allocator, segments: []const Path.Segment) Path {
    var result = Path.init(allocator);
    result.segments.items = @constCast(segments);
    result.segments.capacity = segments.len;
    return result;
}

fn copyPath(allocator: Allocator, segments: []const Path.Segment) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.segments.ensureTotalCapacity(allocator, segments.len);
    // Public constructors retain Path's validated topology and cached endpoint
    // state. No borrowed picture geometry escapes through a returned Path.
    for (segments) |segment| switch (segment) {
        .move => |point| try result.moveTo(point),
        .line => |point| try result.lineTo(point),
        .cubic => |curve| try result.cubicTo(curve.c1, curve.c2, curve.end),
        .close => try result.close(),
    };
    return result;
}

fn testCurve(allocator: Allocator) !Path {
    var result = Path.init(allocator);
    errdefer result.deinit();
    try result.moveTo(.{ .x = -0.0, .y = 1e-200 });
    try result.cubicTo(.{ .x = 1.0 + std.math.floatEps(f64), .y = -0.0 }, .{ .x = 7.125, .y = 12.5 }, .{ .x = 13.75, .y = -5.25 });
    return result;
}
fn expectPointBits(expected: g.Point, actual: g.Point) !void {
    try std.testing.expectEqual(@as(u64, @bitCast(expected.x)), @as(u64, @bitCast(actual.x)));
    try std.testing.expectEqual(@as(u64, @bitCast(expected.y)), @as(u64, @bitCast(actual.y)));
}
fn expectSegmentBits(expected: []const Path.Segment, actual: []const Path.Segment) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| {
        try std.testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
        switch (a) {
            .move => |point| try expectPointBits(point, b.move),
            .line => |point| try expectPointBits(point, b.line),
            .cubic => |curve| {
                try expectPointBits(curve.c1, b.cubic.c1);
                try expectPointBits(curve.c2, b.cubic.c2);
                try expectPointBits(curve.end, b.cubic.end);
            },
            .close => {},
        }
    }
}

test "vectorization preserves original cubic bits open contours fill rules pens and transforms" {
    const t = std.testing;
    var original = try testCurve(t.allocator);
    defer original.deinit();
    const style: DisplayList.Style = .{
        .fill = .{ .r = 0.3, .a = 0 },
        .fill_rule = .evenodd,
        .pen = .{ .width = 2.5, .dash = &.{ 1, 2 }, .nib = @import("pen/nib.zig").Nib.square() },
    };
    const transform: g.Transform = .{ .a = -1, .c = 0.25, .d = 3, .e = 1e16, .f = 7 };
    var result = try extract(t.allocator, .{ .styled = .{ .path = original, .style = style, .transform = transform } }, null);
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), result.commands.items.len);
    const command = result.commands.items[0].path;
    try expectSegmentBits(original.segments.items, try result.range(command.path));
    try t.expectEqualDeep(transform, command.transform);
    try t.expectEqualDeep(style, command.style.*);
    try t.expect(command.style.pen.?.dash.ptr != style.pen.?.dash.ptr);
    try t.expect(command.style.pen.?.nib.?.polygon.ptr != style.pen.?.nib.?.polygon.ptr);
    try t.expect(result.storage.segments.items[result.storage.segments.items.len - 1] != .close);
    var raw = try extract(t.allocator, .{ .path = original }, null);
    defer raw.deinit();
    const editable = try rawPaths(t.allocator, &raw);
    defer {
        for (editable) |*path| path.deinit();
        t.allocator.free(editable);
    }
    try expectSegmentBits(original.segments.items, editable[0].segments.items);
    try t.expect(editable[0].open);
    try t.expectEqualDeep(original.current, editable[0].current);
    try editable[0].lineTo(.{ .x = 20, .y = 10 });
    try t.expectEqual(@as(usize, 2), raw.storage.segments.items.len);
    var empty = try extract(t.allocator, .{ .path = Path.init(t.allocator) }, null);
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.commands.items.len);
}

test "vectorization owns nested cubic clips while raw paths apply transforms without clipping or expansion" {
    const t = std.testing;
    var curve = try testCurve(t.allocator);
    defer curve.deinit();
    var clip = try Path.circle(t.allocator, .zero, 5);
    defer clip.deinit();
    var source = DisplayList.init(t.allocator);
    defer source.deinit();
    const outer = g.Transform.translation(100, 50);
    const inner = g.Transform.scaling(-2, 3);
    const placement = g.Transform.translation(7, 9);
    try source.beginScope(outer, clip);
    try source.beginScope(inner, clip);
    try source.addPath(curve, .{ .fill = .{ .a = 0 }, .fill_rule = .evenodd, .pen = .{ .width = 3 } }, placement);
    try source.endScope();
    try source.endScope();
    var result = try extract(t.allocator, .{ .picture = &source }, null);
    defer result.deinit();
    try t.expectEqualDeep(source.commands.items, result.commands.items);
    try expectSegmentBits(source.storage.segments.items, result.storage.segments.items);
    source.storage.segments.clearRetainingCapacity();
    const found = try rawPaths(t.allocator, &result);
    defer {
        for (found) |*path| path.deinit();
        t.allocator.free(found);
    }
    try t.expectEqual(@as(usize, 1), found.len);
    var expected = try curve.transformed(t.allocator, placement.then(inner).then(outer));
    defer expected.deinit();
    try expectSegmentBits(expected.segments.items, found[0].segments.items);
    try t.expect(found[0].open);
    try t.expectEqual(@as(usize, 2), found[0].segments.items.len);
}

const TestLabels = struct {
    calls: *usize,
    pub fn resolveOutline(self: @This(), allocator: Allocator, reference: u32) !DisplayList {
        if (reference != 7) return error.UnknownTestReference;
        self.calls.* += 1;
        var result = DisplayList.init(allocator);
        errdefer result.deinit();
        var curve = try testCurve(allocator);
        defer curve.deinit();
        var clip = try Path.circle(allocator, .zero, 5);
        defer clip.deinit();
        try result.beginScope(.{}, clip);
        try result.fill(curve, .black, .{});
        try result.endScope();
        return result;
    }
};

fn allocationExercise(allocator: Allocator) !void {
    var curve = try testCurve(allocator);
    defer curve.deinit();
    var source = DisplayList.init(allocator);
    defer source.deinit();
    try source.filldraw(curve, .black, .{ .dash = &.{ 3, 2 }, .nib = @import("pen/nib.zig").Nib.square() }, .{});
    try source.addLabel(7, .{ .width = 20, .height = 15, .baseline = 8 }, .{ .d = -1, .e = 30, .f = 10 });
    var calls: usize = 0;
    var result = try extract(allocator, .{ .picture = &source }, TestLabels{ .calls = &calls });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), calls);
    for (result.commands.items) |command| try std.testing.expect(command != .label);
    const raw = try rawPaths(allocator, &result);
    defer {
        for (raw) |*path| path.deinit();
        allocator.free(raw);
    }
    try std.testing.expectEqual(@as(usize, 2), raw.len);
    try std.testing.expectEqual(@as(usize, 2), source.commands.items.len);
}

test "recursive label vectorization and raw paths release all independent owners on OOM" {
    try allocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), allocationExercise, .{});
}

const RecursiveLabels = struct {
    pub fn resolveOutline(_: @This(), allocator: Allocator, _: u32) !DisplayList {
        var result = DisplayList.init(allocator);
        errdefer result.deinit();
        try result.addLabel(0, .{ .width = 1, .height = 1, .baseline = 0 }, .{});
        return result;
    }
};

test "unresolved labels malformed groups and recursive resolvers have explicit bounds" {
    const t = std.testing;
    var source = try RecursiveLabels.resolveOutline(.{}, t.allocator, 0);
    defer source.deinit();
    try t.expectError(error.LabelResolverRequired, rawPaths(t.allocator, &source));
    try t.expectError(error.LabelResolverRequired, extract(t.allocator, .{ .picture = &source }, null));
    try t.expectError(error.GroupNestingTooDeep, extract(t.allocator, .{ .picture = &source }, RecursiveLabels{}));
    var malformed = DisplayList.init(t.allocator);
    defer malformed.deinit();
    try malformed.commands.append(t.allocator, .pop);
    try t.expectError(error.UnbalancedGroups, extract(t.allocator, .{ .picture = &malformed }, null));
    try t.expectError(error.UnbalancedGroups, rawPaths(t.allocator, &malformed));
    var budget: Budget = .{};
    try budget.consume(max_items);
    try t.expectError(error.GeometryWorkLimit, budget.consume(1));
}
