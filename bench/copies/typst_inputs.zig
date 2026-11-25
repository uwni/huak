//! Cases layout_request and scene_submit: the copies of what is handed to libtypst.
const std = @import("std");
const metrics = @import("metrics");
const typst = @import("libtypst");
const huak = @import("huak");
const backend = huak.backend;
const Path = huak.core.Path;
const DisplayList = huak.core.DisplayList;
const microseconds = metrics.microseconds;

const layout_sources = [_][]const u8{
    "Plain text with office café Ω",
    "#strong[Bold] and #emph[emphasis]",
    "$ sum_(i=1)^n i^2 $",
    "#block(width: 35pt)[wrapped words in a narrow region]",
};

pub fn layoutCase(init: std.process.Init, engine: *typst.Engine) !void {
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

pub fn sceneCase(init: std.process.Init, library: *typst.Library) !void {
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
        try picture.addPath(path, .{ .pen = .{ .paint = .{ .color = .{ .r = 0.2, .g = 0.4, .b = 0.8 } }, .width = 1.5 }, .fill = .{ .color = .{ .r = 0.9, .g = 0.8, .b = 0.1, .a = 0.5 } } }, .{});
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
