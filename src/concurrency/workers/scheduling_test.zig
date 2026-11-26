//! Unit tests for `Workers` scheduling, nesting budgets, chunking and graphs.
const std = @import("std");
const builtin = @import("builtin");
const Workers = @import("../Workers.zig");

test "worker limits, nesting budgets, chunks and empty workloads respect bounds" {
    const t = std.testing;
    const serial = Workers.serial;
    try t.expectEqual(@as(usize, 0), serial.limit(0));
    try t.expectEqual(@as(usize, 1), serial.limit(8));
    try t.expectEqual(@as(?std.Io, null), serial.nested(1).io);
    try t.expectEqual(@as(usize, 1), serial.chunkCount(4096, 256, 32));

    const four = Workers.init(t.io, 4);
    try t.expectEqual(@as(usize, 0), four.limit(0));
    try t.expectEqual(@as(usize, 1), four.limit(1));
    try t.expectEqual(@as(usize, 1), Workers.init(t.io, 0).limit(8));
    try t.expectEqual(@as(usize, 1), Workers.init(t.io, 1).limit(8));
    try t.expectEqual(@as(usize, if (builtin.single_threaded) 1 else 3), Workers.init(t.io, 3).limit(8));

    // Nested budgets keep outer * inner <= total, and outer == 1 passes through.
    const eight = Workers.init(t.io, 8);
    try t.expectEqual(@as(?usize, 8), eight.nested(1).jobs);
    if (!builtin.single_threaded) {
        try t.expectEqual(@as(?usize, 4), eight.nested(2).jobs);
        try t.expectEqual(@as(?usize, 2), eight.nested(3).jobs);
        try t.expectEqual(@as(?usize, 2), eight.nested(4).jobs);
        try t.expectEqual(@as(?std.Io, null), eight.nested(8).io);
        try t.expectEqual(@as(?std.Io, null), Workers.init(t.io, 1).nested(2).io);
        try t.expectEqual(@as(usize, 1), Workers.init(t.io, 1).chunkCount(4096, 256, 32));
        try t.expectEqual(@as(usize, 1), eight.chunkCount(400, 256, 32));
        try t.expectEqual(@as(usize, 2), eight.chunkCount(600, 256, 32));
        try t.expectEqual(@as(usize, 16), four.chunkCount(10_000, 256, 32));
        try t.expectEqual(@as(usize, 32), eight.chunkCount(10_000, 256, 32));
    }

    // Chunk ranges partition 0..item_count contiguously without gaps or overlap.
    const item_count: usize = 1003;
    const chunk_count: usize = 17;
    var cursor: usize = 0;
    for (0..chunk_count) |i| {
        const r = Workers.chunkRange(item_count, chunk_count, i);
        try t.expectEqual(cursor, r.start);
        try t.expect(r.end > r.start);
        cursor = r.end;
    }
    try t.expectEqual(item_count, cursor);

    const Never = struct {
        fn call(_: void, _: usize) bool {
            unreachable;
        }
    };
    try four.run(0, {}, Never.call);
    try serial.run(0, {}, Never.call);
    try four.runGraph(t.allocator, &.{}, {}, Never.call);
    try serial.runGraph(t.allocator, &.{}, {}, Never.call);
}

test "serial workers run flat and graph work synchronously without an Io backend" {
    const t = std.testing;
    const State = struct {
        visited: [5]usize = @splat(0),
        order: [5]usize = @splat(0),
        len: usize = 0,
        fail_at: ?usize = null,

        fn call(self: *@This(), index: usize) bool {
            self.visited[index] += 1;
            self.order[self.len] = index;
            self.len += 1;
            return self.fail_at != index;
        }
    };
    var flat: State = .{ .fail_at = 2 };
    try Workers.serial.run(5, &flat, State.call);
    try t.expectEqual(@as(usize, 3), flat.len);
    try t.expectEqualSlices(usize, &.{ 0, 1, 2 }, flat.order[0..3]);

    var graph: State = .{ .fail_at = 1 };
    try Workers.serial.runGraph(t.allocator, &.{ &.{}, &.{0}, &.{0}, &.{1}, &.{2} }, &graph, State.call);
    try t.expectEqualSlices(usize, &.{ 1, 1, 1, 0, 1 }, &graph.visited);
}

test "independent tasks run once with bounded concurrency on reused backend threads" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const State = struct {
        io: std.Io,
        visits: [64]std.atomic.Value(usize) = @splat(.init(0)),
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),

        fn call(self: *@This(), index: usize) bool {
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .release);
            _ = self.peak.fetchMax(active, .monotonic);
            _ = self.visits[index].fetchAdd(1, .monotonic);
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch return false;
            return true;
        }
    };
    const workers = Workers.init(threaded.io(), 4);
    var state: State = .{ .io = threaded.io() };
    // A new batch reuses the same backend and its already-created threads.
    for (0..3) |_| try workers.run(state.visits.len, &state, State.call);
    try t.expectEqual(@as(usize, 0), state.active.load(.acquire));
    try t.expect(state.peak.load(.monotonic) > 1);
    try t.expect(state.peak.load(.monotonic) <= 4);
    for (&state.visits) |*visits| try t.expectEqual(@as(usize, 3), visits.load(.monotonic));
}

test "nested worker runs respect total budget and never deadlock under tight limits" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    for ([_]std.Io.Limit{ .nothing, .limited(2), .limited(7) }) |cap| {
        var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = cap });
        defer threaded.deinit();
        const total_jobs: usize = 6;
        const outer_count: usize = 2;
        const inner_count: usize = 8;
        const outer_workers = Workers.init(threaded.io(), total_jobs);
        const inner_workers = outer_workers.nested(outer_workers.limit(outer_count));
        const State = struct {
            inner: Workers,
            active: std.atomic.Value(usize) = .init(0),
            peak: std.atomic.Value(usize) = .init(0),
            visits: [outer_count * inner_count]std.atomic.Value(usize) = @splat(.init(0)),

            fn runOuter(self: *@This(), outer: usize) bool {
                const Inner = struct {
                    parent: *@TypeOf(self.*),
                    outer: usize,
                    fn call(ctx: @This(), i: usize) bool {
                        const active = ctx.parent.active.fetchAdd(1, .acq_rel) + 1;
                        defer _ = ctx.parent.active.fetchSub(1, .release);
                        _ = ctx.parent.peak.fetchMax(active, .monotonic);
                        _ = ctx.parent.visits[ctx.outer * inner_count + i].fetchAdd(1, .monotonic);
                        return true;
                    }
                };
                self.inner.run(inner_count, Inner{ .parent = self, .outer = outer }, Inner.call) catch return false;
                return true;
            }
        };
        var state: State = .{ .inner = inner_workers };
        try outer_workers.run(outer_count, &state, State.runOuter);
        try t.expectEqual(@as(usize, 0), state.active.load(.acquire));
        try t.expect(state.peak.load(.monotonic) <= total_jobs);
        for (&state.visits) |*v| try t.expectEqual(@as(usize, 1), v.load(.monotonic));
    }
}

test "unavailable concurrency falls back to the caller for flat and graph work" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const State = struct {
        count: usize = 0,
        expected: std.Thread.Id,
        same_thread: bool = true,
        fn call(self: *@This(), _: usize) bool {
            self.count += 1;
            self.same_thread = self.same_thread and std.Thread.getCurrentId() == self.expected;
            return true;
        }
    };
    const workers = Workers.init(threaded.io(), 4);
    var state: State = .{ .expected = std.Thread.getCurrentId() };
    try workers.run(12, &state, State.call);
    try workers.runGraph(t.allocator, &.{ &.{}, &.{0}, &.{0}, &.{ 1, 2 } }, &state, State.call);
    try t.expectEqual(@as(usize, 16), state.count);
    try t.expect(state.same_thread);
}

test "a flat failure waits for started callbacks and leaves later tasks unclaimed" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const State = struct {
        io: std.Io,
        second_started: std.Io.Event = .unset,
        first_failed: std.Io.Event = .unset,
        second_finished: std.atomic.Value(bool) = .init(false),
        visits: std.atomic.Value(usize) = .init(0),

        fn call(self: *@This(), index: usize) bool {
            _ = self.visits.fetchAdd(1, .monotonic);
            if (index == 0) {
                self.second_started.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } }) catch return false;
                self.first_failed.set(self.io);
                return false;
            }
            if (index == 1) {
                self.second_started.set(self.io);
                self.first_failed.wait(self.io) catch return false;
                self.second_finished.store(true, .release);
                return false;
            }
            return true;
        }
    };
    var state: State = .{ .io = threaded.io() };
    try Workers.init(threaded.io(), 2).run(100, &state, State.call);
    try t.expect(state.second_finished.load(.acquire));
    try t.expectEqual(@as(usize, 2), state.visits.load(.monotonic));
}

test "a diamond graph computes every shared dependency once before its consumers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const State = struct {
        values: [5]usize = @splat(0),
        visits: [5]usize = @splat(0),
        fn call(self: *@This(), index: usize) bool {
            self.visits[index] += 1;
            self.values[index] = switch (index) {
                0 => 7,
                1 => self.values[0] * 2,
                2 => self.values[0] * 3,
                3 => self.values[1] + self.values[2],
                4 => self.values[3] + self.values[0],
                else => unreachable,
            };
            return true;
        }
    };
    const dependencies: []const []const usize = &.{ &.{}, &.{0}, &.{0}, &.{ 1, 2 }, &.{ 0, 3 } };
    for ([_]usize{ 1, 4, 4 }) |jobs| {
        var state: State = .{};
        try Workers.init(threaded.io(), jobs).runGraph(t.allocator, dependencies, &state, State.call);
        try t.expectEqualSlices(usize, &.{ 7, 14, 21, 35, 42 }, &state.values);
        try t.expectEqualSlices(usize, &.{ 1, 1, 1, 1, 1 }, &state.visits);
    }
}

test "idle graph workers wake when a narrow dependency opens into parallel work" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const State = struct {
        io: std.Io,
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        visits: [9]std.atomic.Value(usize) = @splat(.init(0)),

        fn call(self: *@This(), index: usize) bool {
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .release);
            _ = self.peak.fetchMax(active, .monotonic);
            _ = self.visits[index].fetchAdd(1, .monotonic);
            std.Io.sleep(self.io, .fromMilliseconds(2), .awake) catch return false;
            return true;
        }
    };
    var state: State = .{ .io = threaded.io() };
    try Workers.init(threaded.io(), 4).runGraph(t.allocator, &.{ &.{}, &.{0}, &.{0}, &.{0}, &.{0}, &.{0}, &.{0}, &.{ 1, 2, 3, 4, 5, 6 }, &.{7} }, &state, State.call);
    try t.expectEqual(@as(usize, 0), state.active.load(.acquire));
    try t.expect(state.peak.load(.monotonic) > 1);
    try t.expect(state.peak.load(.monotonic) <= 4);
    for (&state.visits) |*visits| try t.expectEqual(@as(usize, 1), visits.load(.monotonic));
}

test "failed graph nodes suppress descendants while independent tasks complete" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const State = struct {
        visits: [7]usize = @splat(0),
        fn call(self: *@This(), index: usize) bool {
            self.visits[index] += 1;
            return index != 0;
        }
    };
    var state: State = .{};
    try Workers.init(threaded.io(), 4).runGraph(t.allocator, &.{ &.{}, &.{0}, &.{1}, &.{}, &.{3}, &.{ 2, 4 }, &.{4} }, &state, State.call);
    try t.expectEqualSlices(usize, &.{ 1, 0, 0, 1, 1, 0, 1 }, &state.visits);
}

test "long chains complete or suppress descendants without recursive propagation" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    var links: [2048][1]usize = undefined;
    var dependencies: [links.len][]const usize = undefined;
    dependencies[0] = &.{};
    for (links[1..], dependencies[1..], 0..) |*link, *parents, index| {
        link.* = .{index};
        parents.* = link;
    }
    const State = struct {
        count: usize = 0,
        fail: bool,
        fn call(self: *@This(), index: usize) bool {
            std.debug.assert(index == self.count);
            self.count += 1;
            return !self.fail;
        }
    };
    const workers = Workers.init(threaded.io(), 4);
    var success: State = .{ .fail = false };
    try workers.runGraph(t.allocator, &dependencies, &success, State.call);
    try t.expectEqual(links.len, success.count);
    var failure: State = .{ .fail = true };
    try workers.runGraph(t.allocator, &dependencies, &failure, State.call);
    try t.expectEqual(@as(usize, 1), failure.count);
}

test "canceling graph execution joins running callbacks and idle workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const State = struct {
        io: std.Io,
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        active: std.atomic.Value(usize) = .init(0),
        canceled: std.atomic.Value(bool) = .init(false),
        descendant_ran: std.atomic.Value(bool) = .init(false),

        fn call(self: *@This(), index: usize) bool {
            if (index != 0) {
                self.descendant_ran.store(true, .release);
                return true;
            }
            _ = self.active.fetchAdd(1, .acq_rel);
            defer _ = self.active.fetchSub(1, .release);
            self.started.set(self.io);
            self.release.wait(self.io) catch {
                self.canceled.store(true, .release);
                return false;
            };
            return true;
        }

        fn execute(self: *@This()) Workers.GraphError!void {
            try Workers.init(self.io, 2).runGraph(t.allocator, &.{ &.{}, &.{0} }, self, call);
        }
    };
    var state: State = .{ .io = threaded.io() };
    var execution = try threaded.io().concurrent(State.execute, .{&state});
    defer _ = execution.cancel(threaded.io()) catch {};
    try state.started.waitTimeout(threaded.io(), .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
    execution.cancel(threaded.io()) catch |err| if (err != error.Canceled) return err;
    try t.expectEqual(@as(usize, 0), state.active.load(.acquire));
    try t.expect(state.canceled.load(.acquire));
    try t.expect(!state.descendant_ran.load(.acquire));
}

test "invalid graph edges fail before any callback runs" {
    const t = std.testing;
    const Never = struct {
        fn call(_: void, _: usize) bool {
            unreachable;
        }
    };
    const serial = Workers.init(t.io, 1);
    const parallel = Workers.init(t.io, 4);
    for ([_]Workers{ .serial, serial, parallel }) |w| {
        try t.expectError(error.InvalidDependency, w.runGraph(t.allocator, &.{&.{0}}, {}, Never.call));
        try t.expectError(error.InvalidDependency, w.runGraph(t.allocator, &.{ &.{1}, &.{0} }, {}, Never.call));
        try t.expectError(error.InvalidDependency, w.runGraph(t.allocator, &.{ &.{}, &.{2} }, {}, Never.call));
    }
}

fn graphAllocationScenario(allocator: std.mem.Allocator, workers: Workers) !void {
    const State = struct {
        visits: [4]usize = @splat(0),
        fn call(self: *@This(), index: usize) bool {
            self.visits[index] += 1;
            return true;
        }
    };
    var state: State = .{};
    try workers.runGraph(allocator, &.{ &.{}, &.{0}, &.{0}, &.{ 1, 2 } }, &state, State.call);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1 }, &state.visits);
}

test "every graph metadata allocation failure releases scheduling storage" {
    const t = std.testing;
    var threaded: std.Io.Threaded = .init(t.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    try t.checkAllAllocationFailures(t.allocator, graphAllocationScenario, .{Workers.serial});
    try t.checkAllAllocationFailures(t.allocator, graphAllocationScenario, .{Workers.init(threaded.io(), 4)});
}
