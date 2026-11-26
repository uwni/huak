//! Bounded parallel work on the I/O backend's reusable threads.
//!
//! A `Workers` value carries an optional `std.Io` handle and concurrency
//! ceiling without owning threads of its own. `.serial` runs work synchronously
//! on the calling thread. Callbacks own their indexed results; scheduling never
//! retains application objects after return.
const std = @import("std");
const builtin = @import("builtin");

const Workers = @This();

/// I/O backend whose reusable thread pool runs concurrent tasks.
/// Null runs work synchronously on the calling thread.
io: ?std.Io = null,
/// Maximum concurrent tasks including the calling thread. Null uses the
/// system CPU count.
jobs: ?usize = null,

/// Synchronous single-threaded execution on the calling thread.
pub const serial: Workers = .{};

pub fn init(io: std.Io, jobs: ?usize) Workers {
    return .{ .io = io, .jobs = jobs };
}

/// Maximum concurrent tasks (including the caller) for `task_count` items.
/// Returns 0 for empty work and 1 when serial or single-threaded.
pub fn limit(self: Workers, task_count: usize) usize {
    if (task_count == 0) return 0;
    if (builtin.single_threaded or self.io == null) return 1;
    const requested = self.jobs orelse (std.Thread.getCpuCount() catch 1);
    return @min(task_count, @max(@as(usize, 1), requested));
}

/// Remaining concurrency budget for each of `outer` concurrent tasks, so
/// nested parallel stages never exceed this budget's ceiling. When `outer <= 1`,
/// the full budget passes through unchanged.
pub fn nested(self: Workers, outer: usize) Workers {
    const io = self.io orelse return .serial;
    if (builtin.single_threaded) return .serial;
    const active = @max(@as(usize, 1), outer);
    if (active == 1) return self;
    const total = @max(@as(usize, 1), self.jobs orelse (std.Thread.getCpuCount() catch 1));
    const share = total / active;
    if (share <= 1) return .serial;
    return .{ .io = io, .jobs = share };
}

/// Inclusive-exclusive slice bounds `[start, end)` of one contiguous chunk.
pub const Range = struct {
    start: usize,
    end: usize,
};

/// Number of contiguous chunks to partition `item_count` items into under this
/// budget. Returns 0 for empty work, 1 when serial or below `2 * min_chunk`,
/// and otherwise oversubscribes chunks up to `4 * workers` (capped by
/// `max_chunks` and `item_count / min_chunk`) so dynamic claiming balances
/// uneven per-item workloads.
pub fn chunkCount(self: Workers, item_count: usize, min_chunk: usize, max_chunks: usize) usize {
    if (item_count == 0) return 0;
    const step = @max(@as(usize, 1), min_chunk);
    if (max_chunks <= 1 or item_count < step * 2) return 1;
    const capacity = @min(max_chunks, item_count / step);
    const parallel = self.limit(capacity);
    if (parallel <= 1) return 1;
    return @min(capacity, parallel * 4);
}

/// Balanced contiguous range for chunk `index` out of `chunk_count`.
pub fn chunkRange(item_count: usize, chunk_count: usize, index: usize) Range {
    return .{
        .start = index * item_count / chunk_count,
        .end = (index + 1) * item_count / chunk_count,
    };
}

/// Runs independent indexed tasks `0..task_count`. A callback returning false
/// stops further claims; callbacks already running finish before return.
/// Results and errors belong to the caller, which can report them in order.
pub fn run(
    self: Workers,
    task_count: usize,
    context: anytype,
    comptime task: fn (@TypeOf(context), usize) bool,
) std.Io.Cancelable!void {
    if (task_count == 0) return;
    const count = self.limit(task_count);
    if (count <= 1) {
        for (0..task_count) |index| if (!task(context, index)) break;
        return;
    }
    const io = self.io.?;
    const State = struct {
        context: @TypeOf(context),
        count: usize,
        next: std.atomic.Value(usize) = .init(0),
        stop: std.atomic.Value(bool) = .init(false),

        fn work(state: *@This()) void {
            while (!state.stop.load(.acquire)) {
                const index = state.next.fetchAdd(1, .monotonic);
                if (index >= state.count) return;
                if (!task(state.context, index)) state.stop.store(true, .release);
            }
        }
    };
    var state: State = .{ .context = context, .count = task_count };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (1..count) |_| {
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
    self: Workers,
    allocator: std.mem.Allocator,
    dependencies: []const []const usize,
    context: anytype,
    comptime task: fn (@TypeOf(context), usize) bool,
) GraphError!void {
    const count = dependencies.len;
    if (count == 0) return;
    for (dependencies, 0..) |parents, index| {
        for (parents) |parent| if (parent >= index) return error.InvalidDependency;
    }
    const count_workers = self.limit(count);
    if (count_workers <= 1) {
        const succeeded = try allocator.alloc(bool, count);
        defer allocator.free(succeeded);
        for (dependencies, 0..) |parents, index| {
            const ready = for (parents) |parent| {
                if (!succeeded[parent]) break false;
            } else true;
            succeeded[index] = if (ready) task(context, index) else false;
        }
        return;
    }
    const io = self.io.?;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const offsets = try a.alloc(usize, std.math.add(usize, count, 1) catch return error.InvalidDependency);
    @memset(offsets, 0);
    var edge_count: usize = 0;
    for (dependencies) |parents| {
        edge_count = std.math.add(usize, edge_count, parents.len) catch return error.InvalidDependency;
        for (parents) |parent| offsets[parent + 1] += 1;
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

        fn work(state: *@This()) std.Io.Cancelable!void {
            while (try state.take()) |index| {
                const succeeded = task(state.context, index);
                // Completion must be published even if cancellation arrived
                // during a callback; dependents must not wait on a lost node.
                state.mutex.lockUncancelable(state.io);
                state.finish(index, succeeded);
                state.changed.broadcast(state.io);
                state.mutex.unlock(state.io);
            }
        }

        fn take(state: *@This()) std.Io.Cancelable!?usize {
            try state.mutex.lock(state.io);
            defer state.mutex.unlock(state.io);
            while (true) {
                while (state.head < state.tail) {
                    const index = state.ready[state.head];
                    state.head += 1;
                    if (!state.blocked[index]) return index;
                    // Propagate skipped descendants iteratively, using the
                    // same bounded queue rather than recursion along a chain.
                    state.finish(index, false);
                    state.changed.broadcast(state.io);
                }
                if (state.completed == state.ready.len) return null;
                // Idle workers wait for ready work, never claim a node and
                // wait for its dependencies while occupying the work queue.
                try state.changed.wait(state.io, &state.mutex);
            }
        }

        fn finish(state: *@This(), index: usize, succeeded: bool) void {
            state.completed += 1;
            for (state.children[state.offsets[index]..state.offsets[index + 1]]) |child| {
                state.blocked[child] = state.blocked[child] or !succeeded;
                state.remaining[child] -= 1;
                if (state.remaining[child] == 0) {
                    state.ready[state.tail] = child;
                    state.tail += 1;
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
    for (1..count_workers) |_| {
        group.concurrent(io, State.work, .{&state}) catch break;
    }
    try state.work();
    try group.await(io);
}

test {
    _ = @import("workers/scheduling_test.zig");
}
