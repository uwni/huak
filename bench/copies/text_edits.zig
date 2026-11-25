//! Cases text_edit_*: legacy and borrowed text edits.
const std = @import("std");
const huak = @import("huak");
const TextEdit = huak.tooling.TextEdit;

pub fn textEditCase(init: std.process.Init) !void {
    const size = 4 * 1024 * 1024;
    const original = try init.gpa.alloc(u8, size);
    defer init.gpa.free(original);
    for (original, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));

    for ([_]struct { name: []const u8, full: bool, count: usize, rounds: usize }{
        .{ .name = "full_document", .full = true, .count = 1, .rounds = 40 },
        .{ .name = "single_range", .full = false, .count = 1, .rounds = 40 },
        .{ .name = "many_ranges", .full = false, .count = 160, .rounds = 8 },
    }) |case| {
        const legacy = try legacyEdits(init.gpa, original, case.full, case.count);
        defer init.gpa.free(legacy);
        var counted = std.testing.FailingAllocator.init(init.gpa, .{});
        const borrowed = try borrowedEdits(counted.allocator(), original, case.full, case.count);
        defer counted.allocator().free(borrowed);
        if (!std.mem.eql(u8, legacy, borrowed)) return error.NonEquivalentResult;
        var legacy_time: i96 = 0;
        var borrowed_time: i96 = 0;
        for (0..case.rounds) |_| {
            const start = std.Io.Clock.awake.now(init.io);
            const result = try legacyEdits(init.gpa, original, case.full, case.count);
            const end = std.Io.Clock.awake.now(init.io);
            init.gpa.free(result);
            legacy_time += start.durationTo(end).toNanoseconds();
        }
        for (0..case.rounds) |_| {
            const start = std.Io.Clock.awake.now(init.io);
            const result = try borrowedEdits(init.gpa, original, case.full, case.count);
            const end = std.Io.Clock.awake.now(init.io);
            init.gpa.free(result);
            borrowed_time += start.durationTo(end).toNanoseconds();
        }
        for (0..case.rounds) |_| {
            const start = std.Io.Clock.awake.now(init.io);
            const result = try borrowedEdits(init.gpa, original, case.full, case.count);
            const end = std.Io.Clock.awake.now(init.io);
            init.gpa.free(result);
            borrowed_time += start.durationTo(end).toNanoseconds();
            const legacy_start = std.Io.Clock.awake.now(init.io);
            const legacy_result = try legacyEdits(init.gpa, original, case.full, case.count);
            const legacy_end = std.Io.Clock.awake.now(init.io);
            init.gpa.free(legacy_result);
            legacy_time += legacy_start.durationTo(legacy_end).toNanoseconds();
        }
        const divisor = 1000.0 * @as(f64, @floatFromInt(2 * case.rounds));
        std.debug.print(
            "case=text_edit_{s} bytes={d} edits={d} rounds={d}\n" ++
                "legacy_dupe_and_concat_us_per_round={d:.3}\nborrowed_splice_us_per_round={d:.3}\nallocations={d} allocated_bytes={d}\n",
            .{ case.name, size, case.count, case.rounds, @as(f64, @floatFromInt(legacy_time)) / divisor, @as(f64, @floatFromInt(borrowed_time)) / divisor, counted.allocations, counted.allocated_bytes },
        );
    }
}

fn legacyEdits(allocator: std.mem.Allocator, original: []const u8, full: bool, count: usize) ![]u8 {
    var text = try allocator.dupe(u8, original);
    errdefer allocator.free(text);
    for (0..count) |index| {
        const start = if (full) 0 else (index * 7919) % text.len;
        const end = if (full) text.len else @min(start + 3, text.len);
        const replacement = if (full) original else "XY";
        const changed = try std.mem.concat(allocator, u8, &.{ text[0..start], replacement, text[end..] });
        allocator.free(text);
        text = changed;
    }
    return text;
}

fn borrowedEdits(allocator: std.mem.Allocator, original: []const u8, full: bool, count: usize) ![]u8 {
    var edit: TextEdit = .{ .source = original };
    defer edit.deinit(allocator);
    for (0..count) |index| {
        const text = edit.bytes();
        const start = if (full) 0 else (index * 7919) % text.len;
        const end = if (full) text.len else @min(start + 3, text.len);
        try edit.replace(allocator, start, end, if (full) original else "XY");
    }
    return (try edit.take(allocator)) orelse allocator.dupe(u8, original);
}
