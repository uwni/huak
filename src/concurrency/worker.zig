//! Bounded work on the I/O backend's reusable threads. Callbacks own their
//! indexed results; scheduling never retains application objects after return.
const std = @import("std");

pub fn workerCount(task_count: usize, jobs: ?usize) usize {
    const requested = jobs orelse (std.Thread.getCpuCount() catch 1);
    return @min(task_count, @max(@as(usize, 1), requested));
}

/// Runs independent indexed tasks. A callback returning false stops further
/// claims; callbacks already running finish before return. Results and errors
/// belong to the caller, which can report them in index order.
pub fn run(
    io: std.Io,
    task_count: usize,
    jobs: ?usize,
    context: anytype,
    comptime task: fn (@TypeOf(context), usize) bool,
) std.Io.Cancelable!void {
    if (task_count == 0) return;
    const State = struct {
        context: @TypeOf(context),
        count: usize,
        next: std.atomic.Value(usize) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),

        fn work(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                const index = self.next.fetchAdd(1, .monotonic);
                if (index >= self.count) return;
                if (!task(self.context, index)) self.stop.store(true, .release);
            }
        }
    };
    var state: State = .{ .context = context, .count = task_count };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (1..workerCount(task_count, jobs)) |_| {
        // The caller and tasks already started drain the queue when this
        // backend cannot supply another concurrent worker.
        group.concurrent(io, State.work, .{&state}) catch break;
    }
    state.work();
    try group.await(io);
}

pub const GraphError = std.mem.Allocator.Error || std.Io.Cancelable || error{InvalidDependency};

/// Runs a graph in which every dependency precedes its node in source order.
/// A node is claimed only after all dependencies finish successfully. Failed
/// nodes suppress their descendants; independent work continues. Metadata is
/// O(nodes + edges), and all callbacks finish before its storage is released.
pub fn runGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: ?usize,
    dependencies: []const []const usize,
    context: anytype,
    comptime task: fn (@TypeOf(context), usize) bool,
) GraphError!void {
    const count = dependencies.len;
    if (count == 0) return;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const offsets = try a.alloc(usize, std.math.add(usize, count, 1) catch return error.InvalidDependency);
    @memset(offsets, 0);
    var edge_count: usize = 0;
    for (dependencies, 0..) |parents, index| {
        edge_count = std.math.add(usize, edge_count, parents.len) catch return error.InvalidDependency;
        for (parents) |parent| {
            if (parent >= index) return error.InvalidDependency;
            offsets[parent + 1] += 1;
        }
    }
    for (1..offsets.len) |index| offsets[index] += offsets[index - 1];
    const children = try a.alloc(usize, edge_count);
    const cursors = try a.dupe(usize, offsets[0..count]);
    for (dependencies, 0..) |parents, index| for (parents) |parent| {
        children[cursors[parent]] = index;
        cursors[parent] += 1;
    };
    const remaining = try a.alloc(usize, count);
    const blocked = try a.alloc(bool, count);
    @memset(blocked, false);
    const ready = try a.alloc(usize, count);
    var tail: usize = 0;
    for (dependencies, 0..) |parents, index| {
        remaining[index] = parents.len;
        if (parents.len == 0) {
            ready[tail] = index;
            tail += 1;
        }
    }
    const State = struct {
        io: std.Io,
        context: @TypeOf(context),
        offsets: []const usize,
        children: []const usize,
        remaining: []usize,
        blocked: []bool,
        ready: []usize,
        head: usize = 0,
        tail: usize,
        completed: usize = 0,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,

        fn work(self: *@This()) std.Io.Cancelable!void {
            while (try self.take()) |index| {
                const succeeded = task(self.context, index);
                // Completion must be published even if cancellation arrived
                // during a callback; dependents must not wait on a lost node.
                self.mutex.lockUncancelable(self.io);
                self.finish(index, succeeded);
                self.changed.broadcast(self.io);
                self.mutex.unlock(self.io);
            }
        }

        fn take(self: *@This()) std.Io.Cancelable!?usize {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                while (self.head < self.tail) {
                    const index = self.ready[self.head];
                    self.head += 1;
                    if (!self.blocked[index]) return index;
                    // Propagate skipped descendants iteratively, using the
                    // same bounded queue rather than recursion along a chain.
                    self.finish(index, false);
                    self.changed.broadcast(self.io);
                }
                if (self.completed == self.ready.len) return null;
                // Idle workers wait for ready work, never claim a node and
                // wait for its dependencies while occupying the work queue.
                try self.changed.wait(self.io, &self.mutex);
            }
        }

        fn finish(self: *@This(), index: usize, succeeded: bool) void {
            self.completed += 1;
            for (self.children[self.offsets[index]..self.offsets[index + 1]]) |child| {
                self.blocked[child] = self.blocked[child] or !succeeded;
                self.remaining[child] -= 1;
                if (self.remaining[child] == 0) {
                    self.ready[self.tail] = child;
                    self.tail += 1;
                }
            }
        }
    };
    var state: State = .{
        .io = io,
        .context = context,
        .offsets = offsets,
        .children = children,
        .remaining = remaining,
        .blocked = blocked,
        .ready = ready,
        .tail = tail,
    };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (1..workerCount(count, jobs)) |_| {
        group.concurrent(io, State.work, .{&state}) catch break;
    }
    try state.work();
    try group.await(io);
}

test "worker counts and empty workloads respect explicit bounds" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), workerCount(0, 4));
    try t.expectEqual(@as(usize, 1), workerCount(1, 4));
    try t.expectEqual(@as(usize, 1), workerCount(8, 0));
    try t.expectEqual(@as(usize, 3), workerCount(8, 3));
    const Never = struct {
        fn call(_: void, _: usize) bool {
            unreachable;
        }
    };
    try run(t.io, 0, 4, {}, Never.call);
    try runGraph(t.allocator, t.io, 4, &.{}, {}, Never.call);
}

test "independent tasks run once with bounded concurrency on reused backend threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    var state: State = .{ .io = threaded.io() };
    // A new batch reuses the same backend and its already-created threads.
    for (0..3) |_| try run(threaded.io(), state.visits.len, 4, &state, State.call);
    try t.expectEqual(@as(usize, 0), state.active.load(.acquire));
    try t.expect(state.peak.load(.monotonic) > 1);
    try t.expect(state.peak.load(.monotonic) <= 4);
    for (&state.visits) |*visits| try t.expectEqual(@as(usize, 3), visits.load(.monotonic));
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
    var state: State = .{ .expected = std.Thread.getCurrentId() };
    try run(threaded.io(), 12, 4, &state, State.call);
    try runGraph(t.allocator, threaded.io(), 4, &.{ &.{}, &.{0}, &.{0}, &.{ 1, 2 } }, &state, State.call);
    try t.expectEqual(@as(usize, 16), state.count);
    try t.expect(state.same_thread);
}

test "a flat failure waits for started callbacks and leaves later tasks unclaimed" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    try run(threaded.io(), 100, 2, &state, State.call);
    try t.expect(state.second_finished.load(.acquire));
    try t.expectEqual(@as(usize, 2), state.visits.load(.monotonic));
}

test "a diamond graph computes every shared dependency once before its consumers" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
        try runGraph(t.allocator, threaded.io(), jobs, dependencies, &state, State.call);
        try t.expectEqualSlices(usize, &.{ 7, 14, 21, 35, 42 }, &state.values);
        try t.expectEqualSlices(usize, &.{ 1, 1, 1, 1, 1 }, &state.visits);
    }
}

test "idle graph workers wake when a narrow dependency opens into parallel work" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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
    try runGraph(t.allocator, threaded.io(), 4, &.{ &.{}, &.{0}, &.{0}, &.{0}, &.{0}, &.{0}, &.{0}, &.{ 1, 2, 3, 4, 5, 6 }, &.{7} }, &state, State.call);
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
    try runGraph(t.allocator, threaded.io(), 4, &.{ &.{}, &.{0}, &.{1}, &.{}, &.{3}, &.{ 2, 4 }, &.{4} }, &state, State.call);
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
    var success: State = .{ .fail = false };
    try runGraph(t.allocator, threaded.io(), 4, &dependencies, &success, State.call);
    try t.expectEqual(links.len, success.count);
    var failure: State = .{ .fail = true };
    try runGraph(t.allocator, threaded.io(), 4, &dependencies, &failure, State.call);
    try t.expectEqual(@as(usize, 1), failure.count);
}

test "canceling graph execution joins running callbacks and idle workers" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
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

        fn execute(self: *@This()) GraphError!void {
            try runGraph(t.allocator, self.io, 2, &.{ &.{}, &.{0} }, self, call);
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
    try t.expectError(error.InvalidDependency, runGraph(t.allocator, t.io, 1, &.{&.{0}}, {}, Never.call));
    try t.expectError(error.InvalidDependency, runGraph(t.allocator, t.io, 1, &.{ &.{1}, &.{0} }, {}, Never.call));
    try t.expectError(error.InvalidDependency, runGraph(t.allocator, t.io, 1, &.{ &.{}, &.{2} }, {}, Never.call));
}

fn graphAllocationScenario(allocator: std.mem.Allocator) !void {
    const State = struct {
        visits: [4]usize = @splat(0),
        fn call(self: *@This(), index: usize) bool {
            self.visits[index] += 1;
            return true;
        }
    };
    var state: State = .{};
    try runGraph(allocator, std.testing.io, 1, &.{ &.{}, &.{0}, &.{0}, &.{ 1, 2 } }, &state, State.call);
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1 }, &state.visits);
}

test "every graph metadata allocation failure releases scheduling storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, graphAllocationScenario, .{});
}
