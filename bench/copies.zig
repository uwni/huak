//! Focused measurements for copy and temporary-object elimination. Each case
//! validates that the optimized and reference paths produce identical data
//! before reporting timings.
const std = @import("std");
const metrics = @import("metrics");
const typst = @import("libtypst");
const huak = @import("huak");
const backend = huak.backend;
const outline = huak.text.outline;
const outline_geometry = huak.core.outline;
const Path = huak.core.Path;
const DisplayList = huak.core.DisplayList;
const g = huak.core.geometry;
const options = @import("host_options");
const TextEdit = huak.tooling.TextEdit;

fn microseconds(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(start.durationTo(end).toNanoseconds())) / 1000.0;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        std.debug.print("usage: {s} [TYPST_LIBRARY]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const library_path = if (args.len == 2) args[1] else options.library_path;
    var library = try typst.Library.open(library_path);
    defer library.deinit();
    var engine = try library.createEngine();
    defer engine.deinit();

    try layoutCase(init, &engine);
    try sceneCase(init, &library);
    try outlineCase(init, &engine);
    try outlineTextCase(init, &engine);
    try textEditCase(init);
    try adoptionCase(init, &library);
}

const layout_sources = [_][]const u8{
    "Plain text with office café Ω",
    "#strong[Bold] and #emph[emphasis]",
    "$ sum_(i=1)^n i^2 $",
    "#block(width: 35pt)[wrapped words in a narrow region]",
};

fn layoutCase(init: std.process.Init, engine: *typst.Engine) !void {
    const repetitions = 64;
    const rounds = 80;
    var requests: [repetitions]typst.LayoutRequest = undefined;
    var metrics_buffer: [repetitions]typst.Metrics = undefined;
    for (&requests, 0..) |*request, index| request.* = .{ .source = layout_sources[index % layout_sources.len], .syntax = .markup };
    var reference = try engine.layoutContent(&requests, &metrics_buffer, null);
    reference.deinit();

    var legacy_metrics: [repetitions]typst.Metrics = undefined;
    var prewrapped_metrics: [repetitions]typst.Metrics = undefined;
    var borrowed_metrics: [repetitions]typst.Metrics = undefined;
    var prewrapped: [repetitions]typst.LayoutRequest = undefined;
    var wrapped_storage: std.heap.ArenaAllocator = .init(init.gpa);
    defer wrapped_storage.deinit();
    for (&prewrapped, requests) |*request, source| {
        request.* = .{ .source = try std.fmt.allocPrint(wrapped_storage.allocator(), "[{s}]", .{source.source}), .syntax = .code };
    }
    var legacy_time: i96 = 0;
    var prewrapped_time: i96 = 0;
    var markup_time: i96 = 0;
    const rounds_start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const memory = scratch.allocator();
        var wrapped: [repetitions]typst.LayoutRequest = undefined;
        for (&wrapped, requests) |*request, source| {
            request.* = .{ .source = try std.fmt.allocPrint(memory, "[{s}]", .{source.source}), .syntax = .code };
        }
        var layout = try engine.layoutContent(&wrapped, &legacy_metrics, null);
        const end = std.Io.Clock.awake.now(init.io);
        layout.deinit();
        legacy_time += start.durationTo(end).toNanoseconds();
    }
    for (0..rounds) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        var layout = try engine.layoutContent(&prewrapped, &prewrapped_metrics, null);
        const end = std.Io.Clock.awake.now(init.io);
        layout.deinit();
        prewrapped_time += start.durationTo(end).toNanoseconds();
    }
    for (0..rounds) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        var layout = try engine.layoutContent(&requests, &borrowed_metrics, null);
        const end = std.Io.Clock.awake.now(init.io);
        layout.deinit();
        markup_time += start.durationTo(end).toNanoseconds();
    }
    // Reverse the order in a second pass so cache warming and frequency do not
    // favor whichever variant always ran first.
    for (0..rounds) |_| {
        const markup_start = std.Io.Clock.awake.now(init.io);
        var markup_layout = try engine.layoutContent(&requests, &borrowed_metrics, null);
        const markup_end = std.Io.Clock.awake.now(init.io);
        markup_layout.deinit();
        markup_time += markup_start.durationTo(markup_end).toNanoseconds();
        const start = std.Io.Clock.awake.now(init.io);
        var layout = try engine.layoutContent(&prewrapped, &prewrapped_metrics, null);
        const end = std.Io.Clock.awake.now(init.io);
        layout.deinit();
        prewrapped_time += start.durationTo(end).toNanoseconds();
        const legacy_start = std.Io.Clock.awake.now(init.io);
        var scratch: std.heap.ArenaAllocator = .init(init.gpa);
        defer scratch.deinit();
        const memory = scratch.allocator();
        var wrapped: [repetitions]typst.LayoutRequest = undefined;
        for (&wrapped, requests) |*request, source| {
            request.* = .{ .source = try std.fmt.allocPrint(memory, "[{s}]", .{source.source}), .syntax = .code };
        }
        var legacy_layout = try engine.layoutContent(&wrapped, &legacy_metrics, null);
        const legacy_end = std.Io.Clock.awake.now(init.io);
        legacy_layout.deinit();
        legacy_time += legacy_start.durationTo(legacy_end).toNanoseconds();
    }
    const rounds_end = std.Io.Clock.awake.now(init.io);
    if (!std.meta.eql(legacy_metrics, prewrapped_metrics) or !std.meta.eql(legacy_metrics, borrowed_metrics)) return error.NonEquivalentResult;
    const legacy_us = @as(f64, @floatFromInt(legacy_time)) / 1000.0 / (2 * rounds);
    const prewrapped_us = @as(f64, @floatFromInt(prewrapped_time)) / 1000.0 / (2 * rounds);
    const borrowed_us = @as(f64, @floatFromInt(markup_time)) / 1000.0 / (2 * rounds);
    std.debug.print(
        "case=layout_request requests={d} rounds={d}\n" ++
            "legacy_wrapped_copy_us_per_round={d:.3}\nprewrapped_borrowed_code_us_per_round={d:.3}\n" ++
            "borrowed_markup_us_per_round={d:.3}\nremoved_bytes_per_round={d}\nwall_ms={d:.3}\n",
        .{ repetitions, rounds, legacy_us, prewrapped_us, borrowed_us, wrappedBytes(&requests), metrics.milliseconds(rounds_start, rounds_end) },
    );
}

fn wrappedBytes(requests: []const typst.LayoutRequest) usize {
    var total: usize = 0;
    for (requests) |request| total += request.source.len + 2;
    return total;
}

fn sceneCase(init: std.process.Init, library: *typst.Library) !void {
    const allocator = init.gpa;
    var picture = DisplayList.init(allocator);
    defer picture.deinit();
    const path_count = 800;
    const curves_per_path = 48;
    for (0..path_count) |index| {
        var path = Path.init(allocator);
        defer path.deinit();
        if (index % 40 == 0) try picture.beginScope(.{ .e = @floatFromInt(index % 7), .f = @floatFromInt(index % 5) }, null);
        try path.moveTo(.{ .x = @floatFromInt(index % 100), .y = 0 });
        for (0..curves_per_path) |curve| {
            const x: f64 = @floatFromInt(curve * 2 + index % 17);
            const y: f64 = @floatFromInt((curve + index) % 23);
            try path.cubicTo(.{ .x = x + 1, .y = y + 2 }, .{ .x = x + 2, .y = y - 2 }, .{ .x = x + 3, .y = y + 1 });
        }
        try picture.addPath(path, .{ .pen = .{ .color = .{ .r = 0.2, .g = 0.4, .b = 0.8 }, .width = 1.5 }, .fill = .{ .r = 0.9, .g = 0.8, .b = 0.1, .a = 0.5 } }, .{});
        if (index % 40 == 39) try picture.endScope();
    }
    var document = try backend.submit(allocator, library, &picture, 640, 480, .{});
    document.deinit();
    const rounds: usize = 40;
    const start = std.Io.Clock.awake.now(init.io);
    for (0..rounds) |_| {
        var result = try backend.submit(allocator, library, &picture, 640, 480, .{});
        result.deinit();
    }
    const end = std.Io.Clock.awake.now(init.io);
    std.debug.print(
        "case=scene_submit path_commands={d} segments={d} rounds={d}\n" ++
            "submit_us_per_round={d:.3}\nremoved_intermediate_segment_bytes={d}\n",
        .{ path_count, picture.storage.segments.items.len, rounds, microseconds(start, end) / rounds, picture.storage.segments.items.len * @sizeOf(Path.Segment) },
    );
}

fn outlineCase(init: std.process.Init, engine: *typst.Engine) !void {
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

fn outlineTextCase(init: std.process.Init, engine: *typst.Engine) !void {
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

fn textEditCase(init: std.process.Init) !void {
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

// Measure the coordinator handoff separately from layout and export. All text
// owners are real native layouts; the child dies before the result is rendered.
fn adoptionCase(init: std.process.Init, library: *typst.Library) !void {
    const l = huak.language;
    const rounds = 8;
    for ([_]struct { created: usize, retained: usize, copies: usize = 1 }{
        .{ .created = 0, .retained = 0 },
        .{ .created = 1, .retained = 1 },
        .{ .created = 64, .retained = 64 },
        .{ .created = 1024, .retained = 1024 },
        .{ .created = 4096, .retained = 4096 },
        .{ .created = 1, .retained = 1, .copies = 4096 },
        .{ .created = 4096, .retained = 1 },
    }) |case| {
        var elapsed: i96 = 0;
        var allocated: usize = 0;
        var digest: [32]u8 = undefined;
        for (0..rounds) |round| {
            var counted = std.testing.FailingAllocator.init(init.gpa, .{});
            const a = counted.allocator();
            var parent = try l.Runtime.init(a, a, library, .{});
            defer parent.deinit();
            _ = try parent.host().typeset(a, .{ .source = "[Borrowed caption]" });
            var child = try parent.forkTask();
            var alive = true;
            defer if (alive) child.deinit();
            const host = child.host();
            const result = try host.callBuiltin(a, .picture, &.{ .{ .number = 100 }, .{ .number = 100 } }, null);
            for (0..case.created) |index| {
                const text = try host.typeset(a, .{ .source = "[Worker text $x^2$]" });
                if (index >= case.retained) continue;
                for (0..case.copies) |copy| {
                    const label = index * case.copies + copy;
                    const object = try host.callBuiltin(a, .label, &.{ text, .{ .vec2 = .{ .x = @floatFromInt(label % 64), .y = @floatFromInt(label / 64) } } }, null);
                    _ = try host.callBuiltin(a, .append, &.{ result, object }, null);
                }
            }
            const before = counted.allocated_bytes;
            const start = std.Io.Clock.awake.now(init.io);
            const adopted = try parent.adoptTask(&child, result);
            const end = std.Io.Clock.awake.now(init.io);
            elapsed += start.durationTo(end).toNanoseconds();
            allocated += counted.allocated_bytes - before;
            child.deinit();
            alive = false;
            if (parent.layouts.items.len != case.retained + 1) return error.IncorrectLayoutCount;
            var svg = try parent.render(adopted, .svg);
            defer svg.deinit();
            var actual: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(svg.bytes(), &actual, .{});
            if (round == 0) digest = actual else if (!std.mem.eql(u8, &digest, &actual)) return error.NonEquivalentResult;
        }
        std.debug.print("case=task_adoption created={d} retained={d} copies={d} rounds={d} us={d:.3} allocated_bytes={d} svg_hash={x}\n", .{
            case.created, case.retained, case.copies, rounds, @as(f64, @floatFromInt(elapsed)) / (rounds * 1000), allocated / rounds, digest,
        });
    }
}
