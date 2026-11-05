//! Production curve-region benchmark. Includes coordinate mapping and
//! result destruction; excludes fixture generation, validation and rendering.
const std = @import("std");
const builtin = @import("builtin");
const fixtures = @import("region_fixtures");
const core = fixtures.drawing;
const metrics = @import("metrics");
const clap = @import("clap");
const params = clap.parseParamsComptime(
    \\--case <NAME>   Measure just one original fixture.
    \\--repeats <N>   Override repetitions per trial.
    \\--trials <N>    Number of trials, from 1 to 31 (default: 3).
    \\--allocations   Count one untimed operation's backing allocations.
);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try clap.parse(clap.Help, &params, .{ .NAME = clap.parsers.string, .N = clap.parsers.int(usize, 10) }, init.minimal.args, .{ .allocator = allocator });
    defer args.deinit();
    const trials = args.args.trials orelse 3;
    if (trials == 0 or trials > 31 or args.args.repeats == 0) return error.InvalidArguments;
    var selected_case = false;
    const baseline = metrics.peakRssBytes();
    std.debug.print(
        "regions / Zig {s} / {s} / {s}-{s}; trials={d}\n" ++
            "timing=production combine + coordinate mapping + result destruction; no rendering\n" ++
            "first_call_us=first call for each case in this process, not a fresh-process cold start\n" ++
            "fixture generation and coverage checks are outside timed intervals\n" ++
            "peak_rss_bytes=cumulative process high-water mark including fixtures and validation; baseline_peak_rss_bytes={d}\n",
        .{ builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), trials, baseline },
    );
    for (fixtures.cases) |case| {
        if (args.args.case) |name| if (!std.mem.eql(u8, name, case.name)) continue;
        selected_case = true;
        const repeats = args.args.repeats orelse case.repeats;
        var data = try fixtures.input(allocator, case);
        defer data.deinit(allocator);
        const settings = fixtures.options(case);
        const selected = fixtures.operation(case.operation);

        const first_start = std.Io.Clock.awake.now(io);
        var checked = core.region.combine(allocator, data.a, data.b, selected, settings) catch |err| {
            std.debug.print("case={s} operation={s} failed={s}; no timing accepted\n", .{ case.name, @tagName(case.operation), @errorName(err) });
            return err;
        };
        const first_constructed = std.Io.Clock.awake.now(io);
        const shape = fixtures.verify(allocator, data, case, checked, case.operation) catch |err| {
            checked.deinit();
            return err;
        };
        const release_start = std.Io.Clock.awake.now(io);
        checked.deinit();
        const released = std.Io.Clock.awake.now(io);
        // Validation runs between construction and release. Add only the two
        // measured lifecycle intervals, never its independent sampling work.
        const first_us = microseconds(first_start, first_constructed) + microseconds(release_start, released);

        var storage: [31]f64 = undefined;
        const times = storage[0..trials];
        var checksum: usize = 0;
        for (times) |*elapsed| {
            const start = std.Io.Clock.awake.now(io);
            for (0..repeats) |_| {
                var result = try core.region.combine(allocator, data.a, data.b, selected, settings);
                defer result.deinit();
                if (result.segments.items.len != shape.elements) return error.RegionOutputChanged;
                checksum +%= result.segments.items.len;
                std.mem.doNotOptimizeAway(result.segments.items.ptr);
            }
            elapsed.* = microseconds(start, std.Io.Clock.awake.now(io)) / @as(f64, @floatFromInt(repeats));
        }
        var ordered: [31]f64 = undefined;
        @memcpy(ordered[0..trials], times);
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        std.debug.print(
            "case={s} operation={s} tolerance={e} repeats={d} first_call_us={d:.3} hot_median_us={d:.3} trials_us=[",
            .{ case.name, @tagName(case.operation), case.tolerance, repeats, first_us, times[trials / 2] },
        );
        for (ordered[0..trials], 0..) |elapsed, index| std.debug.print("{s}{d:.3}", .{ if (index == 0) "" else ",", elapsed });
        std.debug.print("] elements={d} cubics={d} lines={d} peak_rss_bytes={d} checksum={d}\n", .{ shape.elements, shape.cubics, shape.lines, metrics.peakRssBytes(), checksum });
        if (args.args.allocations != 0) {
            var tracking = std.testing.FailingAllocator.init(allocator, .{});
            var measured = try core.region.combine(tracking.allocator(), data.a, data.b, selected, settings);
            measured.deinit();
            if (tracking.allocated_bytes != tracking.freed_bytes) return error.AllocationLeak;
            std.debug.print("allocation_case={s} allocations={d} deallocations={d} resizes={d} allocated_bytes={d} freed_bytes={d}; untimed, not peak live bytes\n", .{ case.name, tracking.allocations, tracking.deallocations, tracking.resize_index, tracking.allocated_bytes, tracking.freed_bytes });
        }
    }
    if (!selected_case) return error.UnknownCase;
}

fn microseconds(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return metrics.milliseconds(start, end) * 1000;
}
