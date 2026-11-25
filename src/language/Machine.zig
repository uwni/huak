//! The bytecode executor. Runtime arithmetic checks remain enabled in every
//! build mode so a malformed drawing cannot invoke undefined behaviour.
const std = @import("std");

const bytecode = @import("bytecode.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const Value = types.Value;
const Span = source.Span;
pub const Host = @import("machine/Host.zig");
const function_calls = @import("machine/function_calls.zig");
const interpreter = @import("machine/interpreter.zig");
const validation = @import("machine/validation.zig");
const failures = @import("machine/failures.zig");

/// Error payload for batch callbacks. The error union carries the category;
/// these fields identify its request and the successfully initialized prefix.
/// Fatal failures may identify a later request without a recoverable prefix.
/// message is borrowed until the callback's host is changed or destroyed.
pub const TypstBatchDiagnostic = struct {
    completed: usize = 0,
    request_index: ?usize = null,
    message: []const u8 = "",
};

/// Request-local immutable values. The host borrows the descriptor and values
/// only for the callback; no callback into Huak is needed during evaluation.
pub const TypstBinding = struct { name: []const u8, value: Value };
/// A member of a typ.module value applied as a show rule. `path` names the
/// member, with '.' between the names of nested members.
pub const TypstShow = struct { value: Value, path: []const u8 };
pub const TypstRequest = struct {
    source: []const u8,
    bindings: []const TypstBinding = &.{},
    /// Applied around the content, outermost first.
    shows: []const TypstShow = &.{},
    /// The code uses `huak` as a whole value, so the host binds it even when
    /// `bindings` is empty.
    whole: bool = false,
};
/// Where Typst code given to the host begins: its module's name and the
/// 0-based line and byte column of the code's first byte in that source.
pub const TypstOrigin = struct { name: []const u8, line: usize, column: usize };
/// Typst file content to make a typ.module from, borrowed for the callback.
/// `name` names the Typst module, as a file's stem would; `bindings` are
/// the Huak values its code reads; `whole` is as in a request; `origin`
/// locates the code.
pub const TypstModule = struct { code: []const u8, name: []const u8, bindings: []const TypstBinding, whole: bool = false, origin: TypstOrigin };

pub const Limits = struct {
    instructions: u64 = 100_000_000,
    call_depth: usize = 1024,
};
pub const Override = struct { name: []const u8, value: []const u8 };
pub const TraceEntry = struct { function: []const u8, span: Span, module: u32 = 0 };
pub const RuntimeDiagnostic = struct {
    diagnostic: source.Diagnostic,
    native_message: []const u8 = "",
    trace: []const TraceEntry = &.{},

    pub fn text(self: *const RuntimeDiagnostic) []const u8 {
        return self.diagnostic.text();
    }
};
pub const Error = error{ RuntimeFailed, OutOfMemory };
const Frame = struct { module_init: ?u32 = null, function: u32, ip: usize = 0, local_base: usize, stack_base: usize, call_span: Span, call_module: u32 };

/// One execution owns all mutable state and temporary values. Program is
/// immutable and may be executed by multiple independently created Machines.
/// Keep Program and Host alive until deinit; diagnostic borrows this Machine.
const Machine = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
program: *const bytecode.Program,
host: Host,
limits: Limits,
globals: []Value,
initialized: []bool,
module_states: []u8,
current_module: u32 = 0,
stack: std.ArrayList(Value) = .empty,
locals: std.ArrayList(Value) = .empty,
local_initialized: std.ArrayList(bool) = .empty,
frames: std.ArrayList(Frame) = .empty,
/// Stable identity survives moves of Machine itself. Collection nodes and
/// their buffers belong to this execution's arena.
identity: *const types.Ownership,
failure: ?RuntimeDiagnostic = null,
steps: u64 = 0,
/// Frames retained by a suspended coordinating execution. They count
/// towards the same limit and keep diagnostic limits in user units.
outer_call_depth: usize = 0,
started: bool = false,
parameters_prepared: bool = false,
/// Execution-local, reproducible stream; never shared with isolated tasks.
random: std.Random.Xoshiro256 = .init(0),
current_span: Span = .{ .start = 0, .end = 0 },

pub fn init(gpa: std.mem.Allocator, program: *const bytecode.Program, host: Host, limits: Limits) Error!Machine {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const globals = try arena.allocator().alloc(Value, program.global_types.len);
    const initialized = try arena.allocator().alloc(bool, globals.len);
    @memset(globals, .unit);
    @memset(initialized, false);
    const module_states = try arena.allocator().alloc(u8, program.modules.len);
    @memset(module_states, 0);
    const identity = try arena.allocator().create(types.Ownership);
    identity.* = .{};
    return .{ .gpa = gpa, .arena = arena, .identity = identity, .program = program, .host = host, .limits = limits, .globals = globals, .initialized = initialized, .module_states = module_states };
}

pub fn deinit(self: *Machine) void {
    self.frames.deinit(self.gpa);
    self.local_initialized.deinit(self.gpa);
    self.locals.deinit(self.gpa);
    self.stack.deinit(self.gpa);
    self.arena.deinit();
    self.* = undefined;
}

pub fn getGlobal(self: *const Machine, name: []const u8) ?Value {
    for (self.program.global_names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return self.getGlobalAt(index);
    }
    return null;
}

pub fn getGlobalAt(self: *const Machine, index: usize) ?Value {
    if (index >= self.globals.len or index >= self.initialized.len or !self.initialized[index]) return null;
    return self.globals[index];
}

pub fn execute(self: *Machine, overrides: []const Override) Error!Value {
    if (self.failure != null) return error.RuntimeFailed;
    if (self.started) return self.fail("an execution cannot be reused; create a new Machine", .{});
    self.started = true;
    if (self.program.global_names.len != self.globals.len or self.program.readonly_globals.len != self.globals.len)
        return self.fail("invalid bytecode global metadata", .{});
    if (!self.parameters_prepared) {
        try self.prepareParameters(overrides);
    } else if (overrides.len != 0) return self.fail("parameters have already been prepared", .{});
    if (self.module_states.len != 0) self.module_states[0] = 1;
    try function_calls.enter(self, self.program.entry, 0, .{ .start = 0, .end = 0 });
    return self.run(null);
}

/// Copy metadata while its owner is suspended. Proven read-only task
/// inputs borrow collection nodes until join; mutation checks their owner.
pub fn inherit(self: *Machine, parent: *const Machine) Error!void {
    if (self.started or self.program != parent.program) return error.RuntimeFailed;
    @memcpy(self.globals, parent.globals);
    @memcpy(self.initialized, parent.initialized);
    @memcpy(self.module_states, parent.module_states);
    self.parameters_prepared = true;
}

/// Evaluate one planned RHS using the existing bytecode and interpreter.
/// The following global store belongs to the coordinating execution.
pub fn executeTask(self: *Machine, task: bytecode.Task) Error!Value {
    if (self.started or task.function >= self.program.functions.len) return error.RuntimeFailed;
    const code = self.program.functions[task.function].code;
    if (task.start >= task.end or task.end >= code.len or code[task.end].op != .store_global)
        return error.RuntimeFailed;
    self.started = true;
    try function_calls.enter(self, task.function, 0, code[task.start].span);
    self.frames.items[0].ip = task.start;
    return self.run(task.end);
}

/// Keep a worker failure independently of its temporary arena. The worker's
/// base frame replaces the current frame; enclosing imports/calls remain.
pub fn copyTaskFailure(self: *Machine, child: *const Machine) Error!void {
    const detail = child.failure orelse return;
    var copy = detail;
    copy.native_message = try self.arena.allocator().dupe(u8, detail.native_message);
    const ancestors = self.frames.items.len -| 1;
    const trace = try self.arena.allocator().alloc(TraceEntry, detail.trace.len + ancestors);
    @memcpy(trace[0..detail.trace.len], detail.trace);
    for (0..ancestors) |index| {
        const frame = self.frames.items[ancestors - 1 - index];
        const call_span = self.frames.items[ancestors - index].call_span;
        const call_module = self.frames.items[ancestors - index].call_module;
        trace[detail.trace.len + index] = .{
            .function = self.program.functions[frame.function].name,
            .module = if (call_module == std.math.maxInt(u32)) self.program.functions[frame.function].module else call_module,
            .span = call_span,
        };
    }
    copy.trace = trace;
    self.failure = copy;
}

/// Scheduling/ownership failures are reported on the coordinating thread.
pub fn taskFailure(self: *Machine, cause: anyerror) Error {
    if (cause == error.OutOfMemory) return error.OutOfMemory;
    return self.fail("parallel construction failed: {s}", .{@errorName(cause)});
}

pub fn run(self: *Machine, task_end: ?usize) Error!Value {
    return interpreter.runUntil(self, task_end, 0);
}

/// Synchronous native-to-script callback; shares globals, limits and trace.
pub fn invokeFunction(self: *Machine, function: Value, args: []const Value) Error!Value {
    const depth = self.frames.items.len;
    const stack = self.stack.items.len;
    const locals = self.locals.items.len;
    const span = self.current_span;
    const module = self.current_module;
    defer {
        self.frames.items.len = depth;
        self.stack.items.len = stack;
        self.locals.items.len = locals;
        self.local_initialized.items.len = locals;
        self.current_span = span;
        self.current_module = module;
    }
    for (args) |arg| try self.push(arg);
    try function_calls.callValue(self, function, args.len, span);
    return if (self.frames.items.len == depth) self.pop() else interpreter.runUntil(self, null, depth);
}

/// Validate/parse CLI values before the native host is constructed. Calling
/// execute(&.{}) subsequently reuses these values without parsing twice.
pub fn prepareParameters(self: *Machine, overrides: []const Override) Error!void {
    if (self.failure != null) return error.RuntimeFailed;
    if (self.parameters_prepared) return self.fail("parameters have already been prepared", .{});
    if (self.program.global_names.len != self.globals.len or self.program.readonly_globals.len != self.globals.len)
        return self.fail("invalid bytecode global metadata", .{});
    for (overrides, 0..) |override, index| {
        for (overrides[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, override.name)) return self.fail("parameter '{s}' was supplied twice", .{override.name});
        var found = false;
        for (self.program.parameters) |parameter| if (parameter.module == 0 and std.mem.eql(u8, parameter.name, override.name)) {
            found = true;
            break;
        };
        if (!found) return self.fail("unknown parameter '{s}'", .{override.name});
    }
    for (self.program.parameters) |parameter| {
        self.current_span = parameter.span;
        self.current_module = parameter.module;
        if (parameter.global >= self.globals.len or !self.program.readonly_globals[parameter.global]) return self.fail("invalid bytecode parameter metadata", .{});
        var supplied: ?[]const u8 = null;
        for (overrides) |override| if (parameter.module == 0 and std.mem.eql(u8, parameter.name, override.name)) {
            supplied = override.value;
            break;
        };
        const value = if (supplied) |text| try validation.parseParameter(self, parameter, text) else parameter.default orelse return self.fail("required parameter '{s}' is missing", .{parameter.name});
        try validation.checkFiniteExternal(self, value);
        self.globals[parameter.global] = try validation.coerce(self, value, parameter.kind);
        self.initialized[parameter.global] = true;
    }
    self.parameters_prepared = true;
    self.current_module = 0;
}

pub fn tick(self: *Machine) Error!void {
    if (self.steps >= self.limits.instructions) return self.fail("instruction limit ({d}) exceeded", .{self.limits.instructions});
    self.steps += 1;
}

pub fn push(self: *Machine, value: Value) Error!void {
    try self.stack.append(self.gpa, value);
}
pub fn pop(self: *Machine) Error!Value {
    const base = if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].stack_base;
    if (self.stack.items.len <= base) return self.fail("invalid bytecode operand stack underflow", .{});
    return self.stack.pop().?;
}
pub fn peek(self: *Machine) Error!Value {
    const value = try self.pop();
    try self.push(value);
    return value;
}
pub fn arguments(self: *Machine, count: usize) Error![]Value {
    const base = if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].stack_base;
    if (count > self.stack.items.len - base) return self.fail("invalid bytecode argument stack underflow", .{});
    return self.stack.items[self.stack.items.len - count ..];
}

pub fn fail(self: *Machine, comptime format: []const u8, args: anytype) Error {
    if (self.failure != null) return error.RuntimeFailed;
    self.failure = .{ .diagnostic = .{ .span = self.current_span } };
    const failure = &self.failure.?;
    failure.diagnostic.writeMessage(format, args);
    failures.captureTrace(self, failure) catch return error.OutOfMemory;
    return error.RuntimeFailed;
}

test {
    _ = @import("machine/builtin_calls.zig");
    _ = @import("machine/templates.zig");
    _ = @import("machine/operators.zig");
    _ = @import("machine/iteration.zig");
    _ = @import("machine/aggregates_test.zig");
    _ = @import("machine/validation_test.zig");
    _ = @import("machine/function_calls_test.zig");
    _ = @import("machine/interpreter_test.zig");
    _ = @import("machine/parameters_test.zig");
    _ = @import("machine/failures_test.zig");
    _ = @import("machine/ranges_test.zig");
    _ = @import("machine/slices_test.zig");
    _ = @import("machine/list_append_test.zig");
    _ = @import("machine/literal_append_test.zig");
    _ = @import("machine/text_batch_test.zig");
    _ = @import("machine/typst_captures_test.zig");
}
