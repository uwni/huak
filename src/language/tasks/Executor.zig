//! Executes compiler-proved construction regions. Computation runs in isolated
//! VMs; small publication nodes commit owners in source order. Ready workers
//! never block on a future or touch another execution's mutable arena.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Machine = @import("../Machine.zig");
const Runtime = @import("../Runtime.zig");
const Value = @import("../types.zig").Value;
const workers = @import("../../concurrency/worker.zig");

pub const Stats = struct {
    regions: usize = 0,
    tasks: usize = 0,
    peak_active: usize = 0,
};

const Executor = @This();

allocator: std.mem.Allocator,
io: std.Io,
runtime: *Runtime,
jobs: ?usize = null,
stats: Stats = .{},

/// Keep the executor and Runtime at stable addresses through execution.
/// The allocator must support allocation/free on the I/O worker threads.
pub fn attach(self: *Executor, machine: *Machine) void {
    if (workers.workerCount(2, self.jobs) <= 1 or machine.program.task_regions.len == 0) return;
    // Effect proofs describe the canonical Runtime callbacks. A wrapper or
    // another task hook can change observable behavior; keep that host's
    // execution path rather than replacing its callbacks in child VMs.
    const expected = self.runtime.host();
    if (machine.host.ptr != expected.ptr or machine.host.tasks != null or
        !std.meta.eql(machine.host.vtable.*, expected.vtable.*)) return;
    machine.host.tasks = .{ .ptr = self, .vtable = &.{ .dispatch = dispatch } };
}

fn dispatch(context: ?*anyopaque, parent: *Machine, region: *const bc.TaskRegion) Machine.Error!bool {
    const self: *Executor = @ptrCast(@alignCast(context.?));
    const concurrency = workers.workerCount(region.tasks.len, self.jobs);
    if (concurrency <= 1) return false;
    if (region.function >= parent.program.functions.len or region.tasks.len < 2) return false;
    const code = parent.program.functions[region.function].code;
    if (region.start >= region.end or region.end > code.len) return false;
    var next = region.start;
    for (region.tasks) |task| {
        if (task.function != region.function or task.start != next or task.start >= task.end or
            task.end >= code.len or code[task.end].op != .store_global or code[task.end].a != task.global or
            task.global >= parent.globals.len or parent.program.readonly_globals[task.global]) return false;
        for (task.reads) |global| if (global >= parent.globals.len) return false;
        next = task.end + 1;
    }
    if (next != region.end) return false;
    if (parent.stack.items.len != parent.frames.items[parent.frames.items.len - 1].stack_base) return false;
    const remaining = parent.limits.instructions - parent.steps;
    if (remaining == 0) return false;
    // A tiny bounded region amortizes planning and owner transfer; the
    // compiler supplies only whole construction expressions, never glyphs.
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outcomes = try a.alloc(Outcome, region.tasks.len);
    @memset(outcomes, .{});
    defer for (outcomes) |*outcome| outcome.deinit();
    const dependencies = try a.alloc([]const usize, region.tasks.len * 2);
    const inputs = try a.alloc([]const Input, region.tasks.len);
    const producers = try a.alloc(?usize, parent.globals.len);
    @memset(producers, null);
    // Source-order publication can be delayed by one expensive early
    // task. Bound completed-but-unpublished VMs as well as active workers.
    const window = @min(region.tasks.len, concurrency * 2);
    var needs_typst = false;
    for (region.tasks, 0..) |task, index| {
        needs_typst = needs_typst or task.uses_typst;
        var predecessors: std.ArrayList(usize) = .empty;
        var bindings: std.ArrayList(Input) = .empty;
        for (task.reads) |global| {
            if (producers[global]) |previous| {
                try predecessors.append(a, previous * 2 + 1);
                try bindings.append(a, .{ .global = global, .producer = previous });
            }
        }
        if (index >= window) {
            const credit = (index - window) * 2 + 1;
            if (std.mem.indexOfScalar(usize, predecessors.items, credit) == null) try predecessors.append(a, credit);
        }
        dependencies[index * 2] = predecessors.items;
        inputs[index] = bindings.items;
        producers[task.global] = index;
        dependencies[index * 2 + 1] = if (index == 0)
            try a.dupe(usize, &.{index * 2})
        else
            try a.dupe(usize, &.{ index * 2, index * 2 - 1 });
    }
    parent.current_span = parent.program.functions[region.function].code[region.start].span;
    parent.current_module = parent.program.functions[region.function].code[region.start].module;
    const previous_diagnostic = self.runtime.native_message;
    self.runtime.prepareTasks(needs_typst) catch |err| {
        // Preparation is speculative: a later text request must not hide
        // an earlier arithmetic error or erase its successful prefix.
        self.runtime.native_message = previous_diagnostic;
        if (err == error.OutOfMemory or err == error.TypstPanic) return parent.taskFailure(err);
        return false;
    };
    const checkpoint = self.runtime.checkpointTasks();
    var committed = false;
    defer if (!committed) self.runtime.rollbackTasks(checkpoint);
    var shared: Shared = .{
        .owner = self,
        .parent = parent,
        .region = region,
        .outcomes = outcomes,
        .inputs = inputs,
        .remaining = remaining,
    };
    workers.runGraph(self.allocator, self.io, concurrency, dependencies, &shared, Shared.one) catch |err|
        return parent.taskFailure(err);
    self.stats.regions += 1;
    self.stats.tasks += shared.executed.load(.acquire);
    self.stats.peak_active = @max(self.stats.peak_active, shared.peak.load(.acquire));
    if (shared.budget_fallback) return false;
    // Failed computations do not have publication nodes. An earlier budget
    // failure takes precedence over a later worker's arithmetic/layout error.
    for (outcomes, 0..) |*outcome, index| {
        if (outcome.cause != null) {
            if (outcome.steps > remaining - shared.spent) return false;
            // Diagnostic copies may allocate. Finish them before publishing
            // language handles whose owners rollback would otherwise free.
            if (outcome.machine) |*child| try parent.copyTaskFailure(child);
            for (outcomes[0..index], region.tasks[0..index]) |prefix, task| {
                if (!prefix.published) break;
                parent.globals[task.global] = prefix.value;
                parent.initialized[task.global] = true;
            }
            parent.steps += shared.spent + outcome.steps;
            committed = true;
            if (outcome.infrastructure) |err| return parent.taskFailure(err);
            return outcome.cause.?;
        }
    }
    // A validated acyclic region must publish every task unless execution
    // failed. Do not silently skip bytecode on a malformed host plan.
    for (outcomes) |outcome| if (!outcome.published) return parent.taskFailure(error.InvalidTaskGraph);
    for (outcomes, region.tasks) |outcome, task| {
        parent.globals[task.global] = outcome.value;
        parent.initialized[task.global] = true;
    }
    parent.steps += shared.spent;
    parent.current_span = parent.program.functions[region.function].code[region.end - 1].span;
    parent.current_module = parent.program.functions[region.function].code[region.end - 1].module;
    parent.frames.items[parent.frames.items.len - 1].ip = region.end;
    committed = true;
    return true;
}

const Outcome = struct {
    runtime: ?Runtime = null,
    machine: ?Machine = null,
    value: Value = .unit,
    cause: ?Machine.Error = null,
    infrastructure: ?anyerror = null,
    steps: u64 = 0,
    published: bool = false,

    fn deinit(self: *Outcome) void {
        if (self.machine) |*machine| machine.deinit();
        if (self.runtime) |*runtime| runtime.deinit();
        self.machine = null;
        self.runtime = null;
    }
};

const Input = struct { global: u32, producer: usize };

const Shared = struct {
    owner: *Executor,
    parent: *Machine,
    region: *const bc.TaskRegion,
    outcomes: []Outcome,
    inputs: []const []const Input,
    remaining: u64,
    spent: u64 = 0,
    budget_fallback: bool = false,
    metadata: std.Io.Mutex = .init,
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    executed: std.atomic.Value(usize) = .init(0),

    fn one(self: *Shared, node: usize) bool {
        const index = node / 2;
        if (node % 2 != 0) return self.publish(index);
        return self.compute(index);
    }

    fn compute(self: *Shared, index: usize) bool {
        const outcome = &self.outcomes[index];
        const task = self.region.tasks[index];
        defer self.owner.runtime.backends.typst.clearError();
        const active = self.active.fetchAdd(1, .acq_rel) + 1;
        _ = self.peak.fetchMax(active, .monotonic);
        _ = self.executed.fetchAdd(1, .monotonic);
        defer _ = self.active.fetchSub(1, .release);
        self.metadata.lockUncancelable(self.owner.io);
        outcome.runtime = self.owner.runtime.forkTask() catch |err| {
            self.metadata.unlock(self.owner.io);
            outcome.cause = hostError(err);
            outcome.infrastructure = err;
            return false;
        };
        self.metadata.unlock(self.owner.io);
        const ancestor_count = self.parent.frames.items.len - 1;
        outcome.machine = Machine.init(self.owner.allocator, self.parent.program, outcome.runtime.?.host(), self.parent.limits) catch |err| {
            outcome.cause = err;
            return false;
        };
        const child = &outcome.machine.?;
        child.steps = self.parent.steps;
        child.outer_call_depth = ancestor_count;
        child.inherit(self.parent) catch |err| {
            outcome.cause = err;
            return false;
        };
        for (self.inputs[index]) |input| {
            const dependency = &self.outcomes[input.producer];
            std.debug.assert(dependency.published);
            child.globals[input.global] = dependency.value;
            child.initialized[input.global] = true;
        }
        outcome.value = child.executeTask(task) catch |err| {
            outcome.steps = child.steps - self.parent.steps;
            outcome.cause = err;
            return false;
        };
        outcome.steps = child.steps - self.parent.steps;
        return true;
    }

    fn publish(self: *Shared, index: usize) bool {
        const outcome = &self.outcomes[index];
        self.metadata.lockUncancelable(self.owner.io);
        defer self.metadata.unlock(self.owner.io);
        const available = self.remaining - self.spent;
        if (outcome.steps >= available) {
            self.budget_fallback = true;
            return false;
        }
        outcome.value = self.owner.runtime.adoptTask(&outcome.runtime.?, outcome.value) catch |err| {
            outcome.cause = hostError(err);
            outcome.infrastructure = err;
            return false;
        };
        outcome.published = true;
        self.spent += outcome.steps + 1; // The coordinator's store_global.
        // No subsequent job borrows child scratch: dependencies consume only
        // the moved parent owner, published by this node's graph completion.
        outcome.deinit();
        return true;
    }
};

fn hostError(err: anyerror) Machine.Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.RuntimeFailed;
}
