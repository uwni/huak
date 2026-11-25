//! Cases outline_paths and outline_text: native outline transfer into editable paths and pictures.
const std = @import("std");
const typst = @import("libtypst");
const huak = @import("huak");
const outline = huak.text.outline;
const outline_geometry = huak.core.outline;
const Path = huak.core.Path;
const DisplayList = huak.core.DisplayList;
const metrics = @import("metrics");
const microseconds = metrics.microseconds;

pub fn outlineCase(init: std.process.Init, engine: *typst.Engine) !void {
    const source = "#text(size: 24pt)[Editable outline extraction and copied path geometry Ω]";
    var requests = [_]typst.LayoutRequest{.{ .source = source, .syntax = .markup }};
    var measured: [1]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var batch = try outline.extract(init.gpa, &labels);
    defer batch.deinit();
    var picture = DisplayList.init(init.gpa);
    defer picture.deinit();
    try batch.labels[0].addToPicture(&picture, .{ .d = -1, .f = batch.labels[0].metrics.baseline });

    const rounds: usize = 300;
    var legacy_checksum: f64 = 0;
    var borrowed_checksum: f64 = 0;
    const legacy_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const raw = try outline_geometry.rawPaths(init.gpa, &picture);
        defer {
            for (raw) |*path| path.deinit();
            init.gpa.free(raw);
        }
        for (raw) |path| {
            const copy = try path.clone(scratch.allocator());
            legacy_checksum += checksum(copy.segments.items);
        }
    }
    const legacy_end = std.Io.Clock.awake.now(init.io);
    const borrowed_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const raw = try outline_geometry.rawPaths(scratch.allocator(), &picture);
        for (raw) |path| borrowed_checksum += checksum(path.segments.items);
    }
    const borrowed_end = std.Io.Clock.awake.now(init.io);
    // Second pass in reverse order: borrowed, then legacy.
    const borrowed_second_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const raw = try outline_geometry.rawPaths(scratch.allocator(), &picture);
        for (raw) |path| borrowed_checksum += checksum(path.segments.items);
    }
    const borrowed_second_end = std.Io.Clock.awake.now(init.io);
    const legacy_second_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const raw = try outline_geometry.rawPaths(init.gpa, &picture);
        defer {
            for (raw) |*path| path.deinit();
            init.gpa.free(raw);
        }
        for (raw) |path| {
            const copy = try path.clone(scratch.allocator());
            legacy_checksum += checksum(copy.segments.items);
        }
    }
    const legacy_second_end = std.Io.Clock.awake.now(init.io);
    if (legacy_checksum != borrowed_checksum) return error.NonEquivalentResult;
    const legacy_us = (microseconds(legacy_start, legacy_end) + microseconds(legacy_second_start, legacy_second_end)) / (2 * rounds);
    const borrowed_us = (microseconds(borrowed_start, borrowed_end) + microseconds(borrowed_second_start, borrowed_second_end)) / (2 * rounds);
    std.debug.print(
        "case=outline_paths parts={d} segments={d} rounds={d}\n" ++
            "legacy_extract_plus_clone_us_per_round={d:.3}\nborrowed_extract_us_per_round={d:.3}\nchecksum={d:.3}\n",
        .{ picture.commands.items.len, picture.storage.segments.items.len, rounds, legacy_us, borrowed_us, borrowed_checksum },
    );
}

fn checksum(segments: []const Path.Segment) f64 {
    var result: f64 = 0;
    for (segments) |segment| switch (segment) {
        .move, .line => |point| result += point.x + point.y * 0.25,
        .cubic => |curve| result += curve.c1.x + curve.c2.y + curve.end.x * 0.5,
        .close => result += 1,
    };
    return result;
}

pub fn outlineTextCase(init: std.process.Init, engine: *typst.Engine) !void {
    const source = "#text(size: 24pt)[Editable outline extraction and copied path geometry Ω]";
    var requests = [_]typst.LayoutRequest{.{ .source = source, .syntax = .markup }};
    var measured: [1]typst.Metrics = undefined;
    var labels = try engine.layoutContent(&requests, &measured, null);
    defer labels.deinit();
    var batch = try outline.extract(init.gpa, &labels);
    defer batch.deinit();
    const label = &batch.labels[0];

    const rounds: usize = 300;
    var checksum_before: f64 = 0;
    var checksum_after: f64 = 0;
    var commands: usize = 0;
    var segments: usize = 0;
    const before_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var intermediate = DisplayList.init(init.gpa);
        defer intermediate.deinit();
        try label.addToPicture(&intermediate, .{});
        var copied = try outline_geometry.extract(init.gpa, .{ .picture = &intermediate }, null);
        defer copied.deinit();
        checksum_before += pictureChecksum(&copied);
        commands = copied.commands.items.len;
        segments = copied.storage.segments.items.len;
    }
    const before_end = std.Io.Clock.awake.now(init.io);
    const after_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var direct = DisplayList.init(init.gpa);
        defer direct.deinit();
        try label.addToPicture(&direct, .{});
        try outline_geometry.ensureWithinBudget(&direct);
        checksum_after += pictureChecksum(&direct);
        if (direct.commands.items.len != commands or direct.storage.segments.items.len != segments) return error.NonEquivalentResult;
    }
    const after_end = std.Io.Clock.awake.now(init.io);
    const direct_second_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var direct = DisplayList.init(init.gpa);
        defer direct.deinit();
        try label.addToPicture(&direct, .{});
        try outline_geometry.ensureWithinBudget(&direct);
        checksum_after += pictureChecksum(&direct);
    }
    const direct_second_end = std.Io.Clock.awake.now(init.io);
    const legacy_second_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var intermediate = DisplayList.init(init.gpa);
        defer intermediate.deinit();
        try label.addToPicture(&intermediate, .{});
        var copied = try outline_geometry.extract(init.gpa, .{ .picture = &intermediate }, null);
        defer copied.deinit();
        checksum_before += pictureChecksum(&copied);
    }
    const legacy_second_end = std.Io.Clock.awake.now(init.io);
    if (checksum_before != checksum_after) return error.NonEquivalentResult;
    const legacy_us = (microseconds(before_start, before_end) + microseconds(legacy_second_start, legacy_second_end)) / (2 * rounds);
    const direct_us = (microseconds(after_start, after_end) + microseconds(direct_second_start, direct_second_end)) / (2 * rounds);
    std.debug.print(
        "case=outline_text parts={d} commands={d} segments={d} rounds={d}\n" ++
            "legacy_copy_through_extract_us_per_round={d:.3}\ndirect_picture_us_per_round={d:.3}\n",
        .{ label.parts.len, commands, segments, rounds, legacy_us, direct_us },
    );
}

fn pictureChecksum(p: *const DisplayList) f64 {
    var result: f64 = @floatFromInt(p.commands.items.len + p.storage.segments.items.len);
    for (p.storage.segments.items) |segment| switch (segment) {
        .move, .line => |point| result += point.x + point.y * 0.25,
        .cubic => |curve| result += curve.c1.x + curve.c2.y + curve.end.x * 0.5,
        .close => result += 1,
    };
    return result;
}
