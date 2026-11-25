//! One native segment array per picture: the intervals of its paths and clips, merged, each range converted once.
const std = @import("std");
const typst = @import("libtypst");
const c = typst.c;
const DisplayList = @import("../../../drawing/DisplayList.zig");
const Path = @import("../../../drawing/path/Path.zig");
const typst_scene = @import("../scene.zig");
const native_records = @import("native.zig");
const NativeSegments = @This();
const pathSegment = native_records.pathSegment;
const Builder = typst_scene.Builder;

pub const Interval = struct {
    source: u32,
    first: usize,
    end: usize,
    native_first: usize = 0,

    fn tryMerge(self: *Interval, other: *const Interval) bool {
        if (self.source != other.source or other.first > self.end or self.first > other.end) return false;
        self.first = @min(self.first, other.first);
        self.end = @max(self.end, other.end);
        return true;
    }
    fn less(_: void, a: Interval, b: Interval) bool {
        if (a.source != b.source) return a.source < b.source;
        return a.first < b.first;
    }
    fn startsAtOrBefore(range: DisplayList.PathRef, interval: Interval) bool {
        if (interval.source != range.source) return interval.source < range.source;
        return interval.first <= range.first;
    }
};

geometry: DisplayList.Geometry,
data: []const c.TypstPathSegment,
intervals: []const Interval,

pub fn init(allocator: std.mem.Allocator, picture: *const DisplayList) !NativeSegments {
    var intervals: std.ArrayList(Interval) = .empty;
    defer intervals.deinit(allocator);
    for (picture.commands.items) |*command| {
        const range = switch (command.*) {
            .path => |*draw| range: {
                if (draw.style.fill == null) if (draw.style.pen) |pen| if (pen.resolvesStroke()) continue;
                break :range draw.path;
            },
            .push => |*group| group.clip orelse continue,
            else => continue,
        };
        if (range.count == 0) continue;
        // Report invalid ranges only where their path or clip is submitted.
        // In particular, an unmatched group must retain its earlier error.
        _ = picture.range(range) catch continue;
        const interval: Interval = .{ .source = range.source, .first = range.first, .end = range.first + range.count };
        if (intervals.items.len != 0 and intervals.items[intervals.items.len - 1].tryMerge(&interval)) continue;
        try intervals.append(allocator, interval);
    }
    std.mem.sort(Interval, intervals.items, {}, Interval.less);
    var count: usize = 0;
    for (intervals.items) |*interval| {
        if (count != 0 and intervals.items[count - 1].tryMerge(interval)) continue;
        intervals.items[count] = interval.*;
        count += 1;
    }
    intervals.items.len = count;
    const retained = try intervals.toOwnedSlice(allocator);
    errdefer allocator.free(retained);
    var segment_count: usize = 0;
    for (retained) |*interval| {
        interval.native_first = segment_count;
        segment_count = std.math.add(usize, segment_count, interval.end - interval.first) catch return error.OutOfMemory;
    }
    const data = try allocator.alloc(c.TypstPathSegment, segment_count);
    for (retained) |interval| {
        const source = try picture.geometry().source(interval.source);
        const input = source[interval.first..interval.end];
        for (input, data[interval.native_first..][0..input.len]) |segment, *out| out.* = pathSegment(segment);
    }
    return .{ .geometry = picture.geometry(), .data = data, .intervals = retained };
}

pub fn deinit(self: NativeSegments, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
    allocator.free(self.intervals);
}

pub fn slice(self: *const NativeSegments, range: DisplayList.PathRef) ![]const c.TypstPathSegment {
    _ = try self.geometry.range(range);
    if (range.count == 0) return &.{};
    const stop = std.sort.partitionPoint(Interval, self.intervals, range, Interval.startsAtOrBefore);
    if (stop == 0) return error.InvalidPath;
    const interval = self.intervals[stop - 1];
    if (interval.source != range.source or range.first >= interval.end or range.count > interval.end - range.first) return error.InvalidPath;
    const first = interval.native_first + (range.first - interval.first);
    return self.data[first..][0..range.count];
}

test "native intervals share repeated and overlapping ranges without duplicating geometry" {
    const t = std.testing;
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 1, .y = 1 } },
        .{ .move = .{ .x = 2, .y = 2 } }, .{ .line = .{ .x = 3, .y = 3 } },
        .{ .line = .{ .x = 4, .y = 4 } }, .{ .line = .{ .x = 5, .y = 5 } },
        .{ .line = .{ .x = 6, .y = 6 } }, .{ .line = .{ .x = 7, .y = 7 } },
        .{ .line = .{ .x = 8, .y = 8 } }, .{ .line = .{ .x = 9, .y = 9 } },
    };
    var picture = DisplayList.init(t.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    const first: DisplayList.PathRef = .{ .first = 2, .count = 5, .source = 1 };
    const overlap: DisplayList.PathRef = .{ .first = 5, .count = 4, .source = 1 };
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = first, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = overlap } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = first, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .pop);
    const native = try NativeSegments.init(t.allocator, &picture);
    defer native.deinit(t.allocator);
    try t.expectEqual(@as(usize, 7), native.data.len);
    try t.expectEqual(@as(usize, 1), native.intervals.len);
    var library: typst.Library = undefined;
    var builder: Builder = .{ .arena = .init(t.allocator), .library = &library, .picture = &picture, .size = .{ .x = 10, .y = 10 }, .segments = native };
    defer builder.arena.deinit();
    const a = try native_records.path(&builder, first);
    const b = try native_records.path(&builder, overlap);
    const repeated = try native_records.path(&builder, first);
    try t.expect(a.segments == repeated.segments);
    try t.expect(a.segments + 3 == b.segments);
    for (source[2..7], a.segments[0..a.segment_count]) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
    for (source[5..9], b.segments[0..b.segment_count]) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
}

test "consecutive native ranges allocate the same interval storage as one range" {
    const t = std.testing;
    var source: [1600]Path.Segment = undefined;
    for (&source, 0..) |*segment, index| segment.* = if (index % 2 == 0)
        .{ .move = .{ .x = @floatFromInt(index), .y = 0 } }
    else
        .{ .line = .{ .x = @floatFromInt(index), .y = 1 } };
    var whole = DisplayList.init(t.allocator);
    defer whole.deinit();
    try whole.sources.append(whole.storage.allocator, .{ .segments = &source });
    try whole.commands.append(whole.storage.allocator, .{ .path = .{ .path = .{ .first = 0, .count = source.len, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    var separate = DisplayList.init(t.allocator);
    defer separate.deinit();
    try separate.sources.append(separate.storage.allocator, .{ .segments = &source });
    for (0..800) |index| try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = .{ .first = index * 2, .count = 2, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    // Repeating the final reference must not grow its interval storage either.
    try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = .{ .first = source.len - 2, .count = 2, .source = 1 }, .style = &.{ .fill = .black }, .transform = .{} } });
    var whole_counter = t.FailingAllocator.init(t.allocator, .{});
    const one = try NativeSegments.init(whole_counter.allocator(), &whole);
    defer one.deinit(whole_counter.allocator());
    var separate_counter = t.FailingAllocator.init(t.allocator, .{});
    const many = try NativeSegments.init(separate_counter.allocator(), &separate);
    defer many.deinit(separate_counter.allocator());
    try t.expectEqual(@as(usize, 1), many.intervals.len);
    try t.expectEqual(source.len, many.data.len);
    try t.expectEqualDeep(one.data, many.data);
    try t.expectEqual(whole_counter.allocations, separate_counter.allocations);
    try t.expectEqual(whole_counter.allocated_bytes, separate_counter.allocated_bytes);
    try t.expectEqual(whole_counter.freed_bytes, separate_counter.freed_bytes);
    try t.expectEqual(source.len * @sizeOf(c.TypstPathSegment) + @sizeOf(NativeSegments.Interval), separate_counter.allocated_bytes - separate_counter.freed_bytes);

    separate.commands.clearRetainingCapacity();
    for ([_]DisplayList.PathRef{
        .{ .first = 8, .count = 2, .source = 1 },
        .{ .first = 0, .count = 2, .source = 1 },
        .{ .first = 4, .count = 4, .source = 1 },
        .{ .first = 2, .count = 3, .source = 1 },
    }) |range| try separate.commands.append(separate.storage.allocator, .{ .path = .{ .path = range, .style = &.{ .fill = .black }, .transform = .{} } });
    const unordered = try NativeSegments.init(t.allocator, &separate);
    defer unordered.deinit(t.allocator);
    try t.expectEqual(@as(usize, 1), unordered.intervals.len);
    try t.expectEqual(@as(usize, 10), unordered.data.len);
    for (source[0..10], unordered.data) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
}

fn nativeIntervalExercise(allocator: std.mem.Allocator) !void {
    const source = [_]Path.Segment{
        .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 8, .y = 0 } }, .{ .line = .{ .x = 8, .y = 8 } }, .{ .line = .{ .x = 0, .y = 8 } }, .close,
        .{ .move = .{ .x = 2, .y = 2 } }, .{ .line = .{ .x = 2, .y = 6 } }, .{ .line = .{ .x = 6, .y = 2 } }, .close,
    };
    var picture = DisplayList.init(std.testing.allocator);
    defer picture.deinit();
    try picture.sources.append(picture.storage.allocator, .{ .segments = &source });
    const clip: DisplayList.PathRef = .{ .first = 0, .count = source.len, .source = 1 };
    const hole: DisplayList.PathRef = .{ .first = 5, .count = 4, .source = 1 };
    const owned: DisplayList.PathRef = .{ .first = 0, .count = source.len };
    try picture.storage.segments.appendSlice(picture.storage.allocator, &source);
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = clip } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = owned, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = hole } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = clip, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .pop);
    try picture.commands.append(picture.storage.allocator, .pop);
    const native = try NativeSegments.init(allocator, &picture);
    defer native.deinit(allocator);
    try std.testing.expectEqual(source.len * 2, native.data.len);
    // Actual path/inner-clip/outer-clip submission order differs from sorted
    // storage. The original controls and contour/hole order must stay intact.
    for ([_]DisplayList.PathRef{ owned, clip, hole, clip }) |range| {
        for (try picture.range(range), try native.slice(range)) |segment, converted| try std.testing.expectEqualDeep(pathSegment(segment), converted);
    }
}

test "nested compound clips preserve contour order and release every failed interval allocation" {
    try nativeIntervalExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), nativeIntervalExercise, .{});
}

test "independent geometry banks preserve source identity and convert each used range once" {
    const t = std.testing;
    const first = [_]Path.Segment{ .{ .move = .{ .x = 1, .y = 2 } }, .{ .line = .{ .x = 3, .y = 4 } } };
    const second = [_]Path.Segment{ .{ .move = .{ .x = 10, .y = 20 } }, .{ .line = .{ .x = 30, .y = 40 } } };
    var picture = DisplayList.init(t.allocator);
    try picture.sources.appendSlice(t.allocator, &.{ .{ .segments = &first }, .{ .segments = &second } });
    defer picture.deinit();
    const one: DisplayList.PathRef = .{ .first = 0, .count = first.len, .source = 1 };
    const two: DisplayList.PathRef = .{ .first = 0, .count = second.len, .source = 2 };
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = two, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .path = .{ .path = one, .style = &.{ .fill = .black }, .transform = .{} } });
    try picture.commands.append(picture.storage.allocator, .{ .push = .{ .transform = .{}, .clip = two } });
    try picture.commands.append(picture.storage.allocator, .pop);
    try t.expectEqual(first[0..].ptr, (try picture.range(one)).ptr);
    try t.expectEqual(second[0..].ptr, (try picture.range(two)).ptr);
    const native = try NativeSegments.init(t.allocator, &picture);
    defer native.deinit(t.allocator);
    try t.expectEqual(first.len + second.len, native.data.len);
    for ([_]DisplayList.PathRef{ one, two }) |range| {
        for (try picture.range(range), try native.slice(range)) |segment, converted| try t.expectEqualDeep(pathSegment(segment), converted);
    }
    try t.expectError(error.InvalidPath, native.slice(.{ .source = 3, .first = 0, .count = 1 }));
}
