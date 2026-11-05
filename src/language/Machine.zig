//! The bytecode executor. Runtime arithmetic checks remain enabled in every
//! build mode so a malformed drawing cannot invoke undefined behaviour.
const std = @import("std");

const numeric = @import("numeric.zig");
const units = @import("../drawing/units.zig");
const integerAdd = numeric.integerAdd;
const integerSubtract = numeric.integerSubtract;
const integerMultiply = numeric.integerMultiply;
const integerNegate = numeric.integerNegate;
const integerRemainder = numeric.integerRemainder;
const compareIntegerFloat = numeric.compareIntegerFloat;
const reverseOrder = numeric.reverseOrder;

const bytecode = @import("bytecode.zig");
const builtin = @import("builtin.zig");
const types = @import("types.zig");
const source = @import("source.zig");
const Value = types.Value;
const Type = types.Type;
const Span = source.Span;

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
pub const TypstRequest = struct {
    source: []const u8,
    bindings: []const TypstBinding = &.{},
};

fn requestBindings(allocator: std.mem.Allocator, operands: []const Value) std.mem.Allocator.Error!?[]TypstBinding {
    if (operands.len % 2 != 0) return null;
    var index: usize = 0;
    while (index < operands.len) : (index += 2) {
        const name = operands[index];
        if (name != .string or name.string.len == 0 or !std.unicode.utf8ValidateSlice(name.string)) return null;
        const valid = switch (operands[index + 1]) {
            .int, .boolean => true,
            .number => |numeric_value| std.math.isFinite(numeric_value),
            .string => |string| std.unicode.utf8ValidateSlice(string),
            .quantity => |quantity| blk: {
                if (!quantity.dimension.eql(.distance)) break :blk false;
                _ = units.toPoints(quantity) catch break :blk false;
                break :blk true;
            },
            .handle => |handle| handle.kind == .color,
            else => false,
        };
        if (!valid) return null;
    }
    const bindings = try allocator.alloc(TypstBinding, operands.len / 2);
    for (bindings, 0..) |*binding, i| binding.* = .{ .name = operands[i * 2].string, .value = operands[i * 2 + 1] };
    return bindings;
}

/// Host-owned objects are represented by typed handles. Callbacks may allocate
/// returned strings/sequence views in allocator, which lives until deinit.
/// New collections return ownerless templates (listView for lists), which the
/// VM validates and materializes. Existing nodes may borrow script storage.
/// Callbacks must neither mutate input lists/dictionaries/structs (including
/// their reachable graph) nor retain the operand slice. Borrowed task inputs
/// remain frozen until join. Every callback result is fully validated even
/// when it refers to a previously validated script-owned node.
pub const Host = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable = &.{},
    tasks: ?Tasks = null,

    /// Optional entries describe host capabilities. Callers check availability
    /// before invoking a required operation; the context and table are borrowed.
    pub inline fn callBuiltin(self: Host, allocator: std.mem.Allocator, id: builtin.Id, operands: []const Value, machine: ?*Machine) anyerror!Value {
        return self.vtable.call_builtin.?(self.ptr, allocator, id, operands, machine);
    }
    pub inline fn field(self: Host, allocator: std.mem.Allocator, value: Value, name: []const u8) anyerror!Value {
        return self.vtable.field.?(self.ptr, allocator, value, name);
    }
    pub inline fn binary(self: Host, allocator: std.mem.Allocator, op: bytecode.Op, left: Value, right: Value) anyerror!Value {
        return self.vtable.binary.?(self.ptr, allocator, op, left, right);
    }
    pub inline fn typeset(self: Host, allocator: std.mem.Allocator, request: TypstRequest) anyerror!Value {
        return self.vtable.typst.?(self.ptr, allocator, request);
    }
    pub inline fn typesetBatch(self: Host, allocator: std.mem.Allocator, requests: []const TypstRequest, values: []Value, diagnostic: *TypstBatchDiagnostic) anyerror!void {
        return self.vtable.typst_batch.?(self.ptr, allocator, requests, values, diagnostic);
    }
    pub inline fn setupTypst(self: Host, source_text: []const u8) anyerror!void {
        return self.vtable.setup_typst.?(self.ptr, source_text);
    }
    pub fn selectModule(self: Host, index: u32) anyerror!void {
        if (self.vtable.module) |select| try select(self.ptr, index);
    }
    pub fn errorMessage(self: Host) []const u8 {
        return if (self.vtable.error_message) |message| message(self.ptr) else "";
    }

    pub const VTable = struct {
        module: ?*const fn (?*anyopaque, u32) anyerror!void = null,
        /// Arguments are borrowed until the first reentrant call. A host that
        /// invokes a script function must copy the values it still needs first.
        call_builtin: ?*const fn (?*anyopaque, std.mem.Allocator, builtin.Id, []const Value, ?*Machine) anyerror!Value = null,
        field: ?*const fn (?*anyopaque, std.mem.Allocator, Value, []const u8) anyerror!Value = null,
        binary: ?*const fn (?*anyopaque, std.mem.Allocator, bytecode.Op, Value, Value) anyerror!Value = null,
        typst: ?*const fn (?*anyopaque, std.mem.Allocator, TypstRequest) anyerror!Value = null,
        /// Success initializes every output. Errors initialize only the diagnostic's
        /// completed prefix. Neither descriptor slice may be retained by the host.
        typst_batch: ?*const fn (?*anyopaque, std.mem.Allocator, []const TypstRequest, []Value, *TypstBatchDiagnostic) anyerror!void = null,
        setup_typst: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
        error_message: ?*const fn (?*anyopaque) []const u8 = null,
    };

    /// Scheduling has its own implementation state and lifetime.
    pub const Tasks = struct {
        ptr: ?*anyopaque = null,
        vtable: *const Tasks.VTable,

        pub inline fn dispatch(self: Tasks, machine: *Machine, region: *const bytecode.TaskRegion) Error!bool {
            return self.vtable.dispatch(self.ptr, machine, region);
        }

        pub const VTable = struct {
            /// False leaves execution untouched and uses the ordinary instruction loop.
            dispatch: *const fn (?*anyopaque, *Machine, *const bytecode.TaskRegion) Error!bool,
        };
    };
};

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
    try self.enter(self.program.entry, 0, .{ .start = 0, .end = 0 });
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
    try self.enter(task.function, 0, code[task.start].span);
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

fn callBuiltin(self: *Machine, index_: u32, count: usize) Error!void {
    const id = std.enums.fromInt(builtin.Id, index_) orelse return self.fail("invalid bytecode builtin", .{});
    const signature = builtin.signature(id);
    if (!signature.acceptsCount(count)) return self.fail("invalid argument count for '{s}'", .{signature.name});
    const args = try self.arguments(count);
    for (args, 0..) |*arg, index| {
        if (arg.* == .omitted and index >= signature.minimum) continue;
        const expected = if (index < signature.args.len) signature.args[index] else signature.variadic.?;
        arg.* = try self.coerce(arg.*, expected);
    }
    const result = if (try self.coreBuiltin(id, args)) |value| value else native: {
        if (self.host.vtable.call_builtin == null) return self.fail("builtin '{s}' requires a host", .{signature.name});
        const value = self.host.callBuiltin(self.arena.allocator(), id, args, self) catch |err| return self.nativeFailure(err);
        try self.checkFiniteExternal(value);
        break :native value;
    };
    self.stack.items.len -= count;
    try self.checkFinite(result);
    try self.push(try self.coerce(try self.materialize(result), signature.result));
}

fn run(self: *Machine, task_end: ?usize) Error!Value {
    return self.runUntil(task_end, 0);
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
    try self.callValue(function, args.len, span);
    return if (self.frames.items.len == depth) self.pop() else self.runUntil(null, depth);
}

fn callValue(self: *Machine, value: Value, count: usize, span: Span) Error!void {
    if (value != .function) return self.fail("expected function, received {s}", .{self.typeName(value.valueType())});
    if (value.function == .bound) return self.applyFunction(value.function, count, &.{}, false, span);
    switch (value.function) {
        .bytecode => |index| {
            if (index >= self.program.functions.len) return self.fail("invalid function reference", .{});
            const module = self.program.functions[index].module;
            if (module >= self.module_states.len or self.module_states[module] == 0) return self.fail("function module is not initialized", .{});
            try self.enter(index, count, span);
        },
        .native => |index| try self.callBuiltin(index, count),
        .bound => unreachable,
    }
}

const FunctionParameters = struct {
    names: []const []const u8,
    kinds: []const Type,
    defaults: []const ?Value = &.{},
    default_functions: []const ?u32 = &.{},
    minimum: usize,
    variadic: ?Type,
    native: bool = false,
};

fn functionParameters(self: *Machine, target: types.Function.Target) Error!FunctionParameters {
    return switch (target) {
        .bytecode => |index| blk: {
            if (index >= self.program.functions.len) return self.fail("invalid function reference", .{});
            const function = self.program.functions[index];
            if (function.parameter_names.len < function.fixedCount()) return self.fail("invalid function parameter names", .{});
            break :blk .{ .names = function.parameter_names[0..function.fixedCount()], .kinds = function.parameters[0..function.fixedCount()], .defaults = function.defaults, .default_functions = function.default_functions, .minimum = function.requiredCount(), .variadic = function.variadic };
        },
        .native => |index| blk: {
            const id = std.enums.fromInt(builtin.Id, index) orelse return self.fail("invalid native function reference", .{});
            const signature = builtin.signature(id);
            break :blk .{ .names = signature.parameter_names, .kinds = signature.args, .minimum = signature.minimum, .variadic = signature.variadic, .native = true };
        },
    };
}

/// Both .with and named function-value calls use this binding path. Bound
/// arguments are evaluated at .with; only explicit values are retained.
fn applyFunction(self: *Machine, function: types.Function, count: usize, names: []const ?[]const u8, partial: bool, span: Span) Error!void {
    if (names.len != 0 and names.len != count) return self.fail("invalid function argument names", .{});
    const target = function.target();
    const parameters = try self.functionParameters(target);
    const prior: ?*types.Function.Bound = if (function == .bound) function.bound else null;
    const ordered = @import("arguments.zig").bind(Value, self.gpa, parameters.names, parameters.variadic != null, if (prior) |bound| bound.arguments else &.{}, if (prior) |bound| bound.names else &.{}, try self.arguments(count), names) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.fail("invalid function arguments: {t}", .{err}),
    };
    defer self.gpa.free(ordered);
    var highest: usize = 0;
    for (ordered, 0..) |value, i| if (value != null) {
        highest = i + 1;
    };
    if (partial) {
        var used: usize = 0;
        for (ordered) |value| if (value != null) {
            used += 1;
        };
        const values = try self.arena.allocator().alloc(Value, used);
        const labels = try self.arena.allocator().alloc(?[]const u8, used);
        var next: usize = 0;
        for (ordered, 0..) |value, i| if (value) |item| {
            values[next] = try self.coerce(try self.materialize(item), if (i < parameters.kinds.len) parameters.kinds[i] else parameters.variadic.?);
            labels[next] = if (i < parameters.names.len) parameters.names[i] else null;
            next += 1;
        };
        const bound = try self.arena.allocator().create(types.Function.Bound);
        bound.* = .{ .target = target, .arguments = values, .names = labels, .owner = self.identity };
        self.stack.items.len -= count;
        return self.push(.{ .function = .{ .bound = bound } });
    }
    highest = @max(highest, parameters.minimum);
    for (ordered[0..highest], 0..) |*value, i| if (value.* == null) {
        if (i < parameters.default_functions.len and parameters.default_functions[i] != null) {
            value.* = try self.invokeFunction(.{ .function = .{ .bytecode = parameters.default_functions[i].? } }, &.{});
        } else if (i < parameters.defaults.len and parameters.defaults[i] != null) {
            value.* = parameters.defaults[i].?;
        } else if (!parameters.native or i < parameters.minimum) return self.fail("missing function argument '{s}'", .{parameters.names[i]}) else value.* = .omitted;
    };
    self.stack.items.len -= count;
    for (ordered[0..highest]) |value| try self.push(value.?);
    switch (target) {
        .bytecode => |index| try self.callValue(.{ .function = .{ .bytecode = index } }, highest, span),
        .native => |index| try self.callBuiltin(index, highest),
    }
}

fn runUntil(self: *Machine, task_end: ?usize, depth: usize) Error!Value {
    while (self.frames.items.len != 0) {
        const frame_index = self.frames.items.len - 1;
        const function = self.program.functions[self.frames.items[frame_index].function];
        const ip = self.frames.items[frame_index].ip;
        if (task_end) |end| {
            if (frame_index == 0 and ip == end) return self.materialize(try self.pop());
        } else if (self.host.tasks) |schedule| {
            // Only script/module entries contain planned regions. User
            // function loops retain the original interpreter hot path.
            if (frame_index == 0 or self.frames.items[frame_index].module_init != null) {
                if (self.taskRegion(self.frames.items[frame_index].function, ip)) |region| {
                    _ = try schedule.dispatch(self, region);
                }
            }
            if (self.frames.items[frame_index].ip != ip) continue;
        }
        if (ip >= function.code.len) return self.fail("function '{s}' has no return instruction", .{function.name});
        const instruction = function.code[ip];
        self.current_span = instruction.span;
        self.current_module = instruction.module;
        try self.tick();
        self.frames.items[frame_index].ip += 1;
        switch (instruction.op) {
            .import_module => {
                if (instruction.a >= self.module_states.len) return self.fail("invalid bytecode module index", .{});
                if (self.module_states[instruction.a] == 1) return self.fail("cyclic module initialization", .{});
                if (self.module_states[instruction.a] == 2) continue;
                self.module_states[instruction.a] = 1;
                try self.enter(self.program.modules[instruction.a].entry, 0, instruction.span);
                self.frames.items[self.frames.items.len - 1].module_init = instruction.a;
            },
            .check_module => {
                if (instruction.a >= self.module_states.len or self.module_states[instruction.a] != 2)
                    return self.fail("module is not initialized; execute its import before using its exports", .{});
            },
            .constant => {
                if (instruction.a >= self.program.constants.len) return self.fail("invalid bytecode constant index", .{});
                // Internal read-only templates can be passed straight to
                // native readers. Stores and returns materialize them.
                const value = self.program.constants[instruction.a];
                if (value != .omitted) try self.checkFiniteExternal(value);
                try self.push(value);
            },
            .load_global => {
                if (instruction.a >= self.globals.len) return self.fail("invalid bytecode global index", .{});
                if (!self.initialized[instruction.a]) return self.fail("variable '{s}' is used before initialization", .{self.program.global_names[instruction.a]});
                try self.push(self.globals[instruction.a]);
            },
            .store_global => {
                if (instruction.a >= self.globals.len) return self.fail("invalid bytecode global index", .{});
                if (self.program.readonly_globals[instruction.a]) return self.fail("parameter '{s}' is read-only", .{self.program.global_names[instruction.a]});
                self.globals[instruction.a] = try self.coerce(try self.materialize(try self.pop()), self.program.global_types[instruction.a]);
                self.initialized[instruction.a] = true;
            },
            .load_local, .store_local => {
                if (instruction.a >= function.local_types.len) return self.fail("invalid bytecode local index", .{});
                const slot = self.frames.items[frame_index].local_base + instruction.a;
                if (instruction.op == .load_local) {
                    if (!self.local_initialized.items[slot]) return self.fail("local variable is used before initialization", .{});
                    try self.push(self.locals.items[slot]);
                } else {
                    self.locals.items[slot] = try self.coerce(try self.materialize(try self.pop()), function.local_types[instruction.a]);
                    self.local_initialized.items[slot] = true;
                }
            },
            .pop => _ = try self.pop(),
            .duplicate => {
                const value = try self.materialize(try self.peek());
                // Both stack entries represent the same evaluated value,
                // including when that value began as a read-only template.
                self.stack.items[self.stack.items.len - 1] = value;
                try self.push(value);
            },
            .add, .subtract, .multiply, .divide, .remainder, .power => {
                const right = try self.pop();
                const left = try self.pop();
                try self.push(try self.arithmetic(instruction.op, left, right));
            },
            .list_append => {
                const right = try self.pop();
                const left = try self.pop();
                try self.appendList(left, right);
            },
            .list_append_items => try self.appendListItems(instruction),
            .positive => {
                const value = try self.pop();
                switch (value) {
                    .int, .number, .quantity, .pair => {},
                    .handle => |handle| if (handle.kind != .variable and handle.kind != .linear) {
                        return self.fail("cannot apply unary + to {s}", .{self.typeName(handle.kind)});
                    },
                    else => return self.fail("cannot apply unary + to {s}", .{self.typeName(value.valueType())}),
                }
                try self.checkFinite(value);
                try self.push(value);
            },
            .negate => {
                const value = try self.pop();
                const result: Value = switch (value) {
                    .int => |integer| .{ .int = integerNegate(integer) catch return self.fail("integer overflow", .{}) },
                    .number => |numeric_value| .{ .number = -numeric_value },
                    .quantity => |quantity| .{ .quantity = quantity.negate() },
                    .pair => |pair| .{ .pair = pair.scale(-1) },
                    .handle => try self.nativeBinary(.subtract, .{ .int = 0 }, value),
                    else => return self.fail("cannot negate {s}", .{self.typeName(value.valueType())}),
                };
                try self.checkFinite(result);
                try self.push(result);
            },
            .logical_not => {
                const value = try self.boolean(try self.pop());
                try self.push(.{ .boolean = !value });
            },
            .equal, .not_equal => {
                const right = try self.pop();
                const left = try self.pop();
                const equal = try self.valuesEqual(left, right);
                try self.push(.{ .boolean = if (instruction.op == .equal) equal else !equal });
            },
            .less, .less_equal, .greater, .greater_equal => {
                const right = try self.pop();
                const left = try self.pop();
                const order = try self.compare(left, right);
                try self.push(.{ .boolean = switch (instruction.op) {
                    .less => order == .lt,
                    .less_equal => order != .gt,
                    .greater => order == .gt,
                    .greater_equal => order != .lt,
                    else => unreachable,
                } });
            },
            .jump => try self.jump(instruction.a),
            .jump_if_false => if (!try self.boolean(try self.pop())) {
                try self.jump(instruction.a);
            },
            .iterate_init => {
                const values: [3]Value = if (instruction.a == 0) range: {
                    const step = try self.pop();
                    const stop = try self.pop();
                    const start = try self.pop();
                    break :range try self.initializeRange(start, stop, step);
                } else collection: {
                    const value = try self.pop();
                    if (value != .list) return self.fail("for requires a list or numeric range", .{});
                    break :collection .{ .{ .int = 0 }, value, .{ .int = @bitCast(@as(u64, value.list.items().len)) } };
                };
                for (values) |value| try self.push(value);
            },
            .iterate_test => {
                const step = try self.pop();
                const stop = try self.pop();
                const current = try self.pop();
                const more = if (stop == .list) try self.listIterationTest(current, stop, step) else try self.rangeTest(current, stop, step);
                const value: Value = if (!more) .unit else switch (stop) {
                    .list => |list| try self.materialize(list.items()[@intCast(current.int)]),
                    else => current,
                };
                try self.push(value);
                try self.push(.{ .boolean = more });
            },
            .iterate_advance => {
                const step = try self.pop();
                const stop = try self.pop();
                const current = try self.pop();
                const next = if (stop == .list) collection: {
                    _ = try self.listIterationTest(current, stop, step);
                    const next: Value = .{ .int = current.int + 1 };
                    break :collection RangeProgress{ .value = next, .more = try self.listIterationTest(next, stop, step) };
                } else try self.rangeAdvance(current, stop, step);
                try self.push(next.value);
                try self.push(.{ .boolean = next.more });
            },
            .call => try self.enter(instruction.a, instruction.b, instruction.span),
            .call_value, .bind_function => {
                const count: usize = instruction.b;
                if (count >= self.stack.items.len) return self.fail("invalid function call operands", .{});
                const first = self.stack.items.len - count - 1;
                const callee = self.stack.items[first];
                @memmove(self.stack.items[first..][0..count], self.stack.items[first + 1 ..]);
                self.stack.items.len -= 1;
                if (instruction.op == .call_value and instruction.a == 0) {
                    try self.callValue(callee, count, instruction.span);
                } else {
                    if (callee != .function) return self.fail("expected function", .{});
                    if (instruction.a > self.program.argument_names.len) return self.fail("invalid function argument names", .{});
                    const names = if (instruction.a == 0) &.{} else self.program.argument_names[instruction.a - 1];
                    try self.applyFunction(callee.function, count, names, instruction.op == .bind_function, instruction.span);
                }
            },
            .bind_arguments => try self.bindArguments(instruction.a, instruction.b),
            .call_builtin => try self.callBuiltin(instruction.a, instruction.b),
            .return_value => {
                const result = try self.coerce(try self.materialize(try self.pop()), function.result);
                const completed = self.frames.pop().?;
                self.locals.items.len = completed.local_base;
                self.local_initialized.items.len = completed.local_base;
                self.stack.items.len = completed.stack_base;
                if (completed.module_init) |module_index| {
                    self.module_states[module_index] = 2;
                } else {
                    if (self.frames.items.len == depth) return result;
                    try self.push(result);
                }
            },
            .make_pair => {
                const y = try self.pop();
                const x = try self.pop();
                try self.push(numeric.makePair(x, y) catch |err| return self.numericFailure(err));
            },
            .make_list => {
                const args = try self.arguments(instruction.a);
                try self.prepareListItems(args);
                const value = try self.allocateList(args);
                value.list.owned.owner = self.identity;
                self.stack.items.len -= instruction.a;
                try self.push(value);
            },
            .make_dict => {
                const count = std.math.mul(usize, instruction.a, 2) catch return self.fail("invalid bytecode dictionary size", .{});
                const args = try self.arguments(count);
                const value = try self.makeDict(args);
                self.stack.items.len -= count;
                try self.push(value);
            },
            .make_record => {
                const args = try self.arguments(instruction.b);
                const value = try self.makeRecord(instruction.a, args);
                self.stack.items.len -= instruction.b;
                try self.push(value);
            },
            .index => {
                const index_value = try self.pop();
                const object = try self.pop();
                try self.push(try self.readIndex(object, index_value));
            },
            .set_index => {
                const value = try self.pop();
                const key = try self.pop();
                const object = try self.pop();
                try self.setIndex(object, key, value);
            },
            .slice => {
                if (instruction.a > 1) return self.fail("invalid bytecode slice endpoint mode", .{});
                const step = try self.pop();
                const stop = try self.pop();
                const start = try self.pop();
                const object = try self.pop();
                if (instruction.a == 1 and stop != .unit) return self.fail("invalid bytecode open slice endpoint", .{});
                try self.push(try self.sliceList(object, start, if (instruction.a == 1) null else stop, step));
            },
            .field => {
                const name = try self.stringConstant(instruction.a);
                const object = try self.pop();
                if (object == .pair and std.mem.eql(u8, name, "x")) {
                    try self.push(object.pair.component(object.pair.x));
                } else if (object == .pair and std.mem.eql(u8, name, "y")) {
                    try self.push(object.pair.component(object.pair.y));
                } else if (object == .record) {
                    const index = try self.recordField(object.record, name, instruction.b);
                    try self.push(try self.materialize(object.record.fields[index]));
                } else {
                    if (self.host.vtable.field == null) return self.fail("unknown field '{s}' of {s}", .{ name, self.typeName(object.valueType()) });
                    const result = self.host.field(self.arena.allocator(), object, name) catch |err| return self.nativeFailure(err);
                    try self.checkFiniteExternal(result);
                    try self.push(try self.materialize(result));
                }
            },
            .set_field => {
                const name = try self.stringConstant(instruction.a);
                const value = try self.pop();
                const object = try self.pop();
                if (object == .record) {
                    const index = try self.recordField(object.record, name, instruction.b);
                    if (object.record.owner != self.identity) return self.fail("cannot modify a borrowed struct", .{});
                    const descriptor = self.program.records[object.record.kind.recordIndex().?];
                    object.record.fields[index] = try self.coerce(try self.materialize(value), descriptor.fields[index].kind);
                } else return self.fail("cannot assign field '{s}' of {s}", .{ name, object.valueType().name() });
            },
            .typst => {
                if (try self.typesetBatch(frame_index, function, ip)) continue;
                self.host.selectModule(function.module) catch |err| return self.nativeFailure(err);
                const text = try self.stringConstant(instruction.a);
                if (self.host.vtable.typst == null) return self.fail("Typst content requires a host", .{});
                const length = std.math.mul(usize, instruction.b, 2) catch return self.fail("invalid Typst capture count", .{});
                if (length > self.stack.items.len) return self.fail("invalid Typst capture operands", .{});
                const offset = self.stack.items.len - length;
                const bindings = (try requestBindings(self.gpa, self.stack.items[offset..])) orelse return self.fail("typst_expose requires finite numbers, bool, UTF-8 strings, lengths or colors", .{});
                defer self.gpa.free(bindings);
                self.stack.shrinkRetainingCapacity(offset);
                const result = self.host.typeset(self.arena.allocator(), .{ .source = text, .bindings = bindings }) catch |err| return self.nativeFailure(err);
                try self.checkFiniteExternal(result);
                try self.push(try self.coerce(result, .text));
            },
            .setup_typst => {
                self.host.selectModule(function.module) catch |err| return self.nativeFailure(err);
                const text = try self.stringConstant(instruction.a);
                if (self.host.vtable.setup_typst == null) return self.fail("Typst setup requires a host", .{});
                self.host.setupTypst(text) catch |err| return self.nativeFailure(err);
            },
            .halt => {
                if (self.frames.items.len != 1) return self.fail("halt is only valid in the script", .{});
                if (self.module_states.len != 0) self.module_states[0] = 2;
                self.frames.clearRetainingCapacity();
                self.locals.clearRetainingCapacity();
                self.local_initialized.clearRetainingCapacity();
                self.stack.clearRetainingCapacity();
                return .unit;
            },
        }
    }
    return .unit;
}

fn taskRegion(self: *const Machine, function: u32, ip: usize) ?*const bytecode.TaskRegion {
    // The compiler emits regions ordered by function and starting offset.
    const Location = struct {
        function: u32,
        ip: usize,

        fn order(key: @This(), region: bytecode.TaskRegion) std.math.Order {
            const by_function = std.math.order(key.function, region.function);
            return if (by_function == .eq) std.math.order(key.ip, @as(usize, region.start)) else by_function;
        }
    };
    const index = std.sort.binarySearch(bytecode.TaskRegion, self.program.task_regions, Location{ .function = function, .ip = ip }, Location.order) orelse return null;
    return &self.program.task_regions[index];
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
        const value = if (supplied) |text| try self.parseParameter(parameter, text) else parameter.default orelse return self.fail("required parameter '{s}' is missing", .{parameter.name});
        try self.checkFiniteExternal(value);
        self.globals[parameter.global] = try self.coerce(value, parameter.kind);
        self.initialized[parameter.global] = true;
    }
    self.parameters_prepared = true;
    self.current_module = 0;
}

fn parseParameter(self: *Machine, parameter: bytecode.Parameter, text: []const u8) Error!Value {
    return switch (parameter.kind) {
        .int => .{ .int = std.fmt.parseInt(i64, text, 10) catch return self.fail("parameter '{s}' must be int", .{parameter.name}) },
        .number => blk: {
            const numeric_value = std.fmt.parseFloat(f64, text) catch return self.fail("parameter '{s}' must be float", .{parameter.name});
            if (!std.math.isFinite(numeric_value)) return self.fail("parameter '{s}' must be finite", .{parameter.name});
            break :blk .{ .number = numeric_value };
        },
        .length, .angle, .quantity => blk: {
            const value: Value = .{ .quantity = units.parseLiteral(text) catch return self.fail("parameter '{s}' requires a finite quantity with a unit", .{parameter.name}) };
            break :blk try self.coerce(value, parameter.kind);
        },
        .boolean => if (std.mem.eql(u8, text, "true")) .{ .boolean = true } else if (std.mem.eql(u8, text, "false")) .{ .boolean = false } else return self.fail("parameter '{s}' must be true or false", .{parameter.name}),
        .string => blk: {
            if (!std.unicode.utf8ValidateSlice(text)) return self.fail("parameter '{s}' must be valid UTF-8", .{parameter.name});
            break :blk .{ .string = try self.arena.allocator().dupe(u8, text) };
        },
        else => return self.fail("parameter '{s}' has an unsupported CLI type", .{parameter.name}),
    };
}

fn tick(self: *Machine) Error!void {
    if (self.steps >= self.limits.instructions) return self.fail("instruction limit ({d}) exceeded", .{self.limits.instructions});
    self.steps += 1;
}

const TextAssignment = struct {
    begin: usize,
    produce: usize,
    end: usize,
    store: bytecode.Instruction,
    request: TypstRequest,
};

/// Inspect only immutable loads between independent text assignments. Any
/// invalid or uninitialized operand is a barrier, preserving an earlier
/// native error before the ordinary VM reports that later operand error.
fn planText(self: *Machine, allocator: std.mem.Allocator, frame_index: usize, function: bytecode.Function, begin: usize, first: bool, previous: []const TextAssignment) Error!?TextAssignment {
    var operands: std.ArrayList(Value) = .empty;
    defer operands.deinit(allocator);
    var position = begin;
    while (position < function.code.len) : (position += 1) {
        const instruction = function.code[position];
        if (instruction.op == .typst) break;
        if (first) return null;
        switch (instruction.op) {
            .constant => {
                if (instruction.a >= self.program.constants.len) return null;
                try operands.append(allocator, self.program.constants[instruction.a]);
            },
            .load_global, .load_local => {
                for (previous) |assignment| if (assignment.store.a == instruction.a and
                    ((assignment.store.op == .store_global and instruction.op == .load_global) or
                        (assignment.store.op == .store_local and instruction.op == .load_local))) return null;
                if (instruction.op == .load_global) {
                    if (instruction.a >= self.globals.len or !self.initialized[instruction.a]) return null;
                    try operands.append(allocator, self.globals[instruction.a]);
                } else {
                    const slot = std.math.add(usize, self.frames.items[frame_index].local_base, instruction.a) catch return null;
                    if (slot >= self.locals.items.len or !self.local_initialized.items[slot]) return null;
                    try operands.append(allocator, self.locals.items[slot]);
                }
            },
            .check_module => if (instruction.a >= self.module_states.len or self.module_states[instruction.a] != 2) return null,
            else => return null,
        }
    }
    if (position + 1 >= function.code.len) return null;
    const produce = function.code[position];
    if (produce.op != .typst or produce.a >= self.program.constants.len or self.program.constants[produce.a] != .string) return null;
    const count = std.math.mul(usize, produce.b, 2) catch return null;
    const values = if (first) blk: {
        if (count > self.stack.items.len) return null;
        break :blk self.stack.items[self.stack.items.len - count ..];
    } else operands.items;
    if (values.len != count) return null;
    const bindings = try requestBindings(allocator, values) orelse return null;
    const store = function.code[position + 1];
    switch (store.op) {
        .store_global => if (store.a >= self.globals.len or store.a >= self.program.global_types.len or
            self.program.readonly_globals[store.a] or self.program.global_types[store.a] != .text) return null,
        .store_local => if (store.a >= function.local_types.len or function.local_types[store.a] != .text) return null,
        else => return null,
    }
    return .{ .begin = begin, .produce = position, .end = position + 2, .store = store, .request = .{ .source = self.program.constants[produce.a].string, .bindings = bindings } };
}

fn chargeText(self: *Machine, frame_index: usize, function: bytecode.Function, begin: usize, end: usize) Error!void {
    for (begin..end) |position| {
        self.current_span = function.code[position].span;
        self.current_module = function.code[position].module;
        try self.tick();
        self.frames.items[frame_index].ip = position + 1;
    }
}

/// Bounded, dependency-free requests share one host call. Captures remain
/// explicit bytecode operands; planning neither mutates VM bindings nor
/// crosses an effect or an operand that can observe a preceding result.
fn typesetBatch(self: *Machine, frame_index: usize, function: bytecode.Function, start: usize) Error!bool {
    if (self.host.vtable.typst_batch == null) return false;
    const maximum = 64;
    var assignments: [maximum]TextAssignment = undefined;
    var requests: [maximum]TypstRequest = undefined;
    var values: [maximum]Value = undefined;
    var temporary: std.heap.ArenaAllocator = .init(self.gpa);
    defer temporary.deinit();
    const available = self.limits.instructions - self.steps + 1;
    var cost: u64 = 0;
    var count: usize = 0;
    var next = start;
    while (count < maximum) {
        const assignment = try self.planText(temporary.allocator(), frame_index, function, next, count == 0, assignments[0..count]) orelse break;
        const needed = assignment.end - assignment.begin;
        if (needed > available - cost) break;
        assignments[count] = assignment;
        requests[count] = assignment.request;
        cost += needed;
        count += 1;
        next = assignment.end;
    }
    if (count < 2) return false;
    self.host.selectModule(function.module) catch |err| return self.nativeFailure(err);
    self.stack.shrinkRetainingCapacity(self.stack.items.len - requests[0].bindings.len * 2);
    var diagnostic: TypstBatchDiagnostic = .{};
    var cause: ?anyerror = null;
    self.host.typesetBatch(self.arena.allocator(), requests[0..count], values[0..count], &diagnostic) catch |err| {
        cause = err;
    };
    const completed = if (cause != null) diagnostic.completed else count;
    const failed_index = diagnostic.request_index orelse completed;
    if (cause != null and (completed > count or failed_index < completed or failed_index >= count))
        return self.fail("host returned an invalid Typst batch failure index", .{});
    var charged = start + 1; // The outer loop already charged the first typ.
    for (values[0..completed], 0..) |value, index| {
        const assignment = assignments[index];
        try self.chargeText(frame_index, function, charged, assignment.produce + 1);
        self.current_span = function.code[assignment.produce].span;
        self.current_module = function.code[assignment.produce].module;
        try self.checkFiniteExternal(value);
        const text = try self.coerce(value, .text);
        try self.chargeText(frame_index, function, assignment.produce + 1, assignment.end);
        charged = assignment.end;
        if (assignment.store.op == .store_global) {
            self.globals[assignment.store.a] = text;
            self.initialized[assignment.store.a] = true;
        } else {
            const slot = self.frames.items[frame_index].local_base + assignment.store.a;
            self.locals.items[slot] = text;
            self.local_initialized.items[slot] = true;
        }
    }
    if (cause) |failure| {
        const failed = assignments[failed_index];
        try self.chargeText(frame_index, function, charged, failed.produce + 1);
        self.current_span = function.code[failed.produce].span;
        self.current_module = function.code[failed.produce].module;
        return self.nativeFailureMessage(failure, diagnostic.message);
    }
    return true;
}

/// Language primitives need no geometry/typesetting host.
fn coreBuiltin(self: *Machine, id: builtin.Id, args: []const Value) Error!?Value {
    switch (id) {
        .seed => {
            self.random = .init(@bitCast(args[0].int));
            return .unit;
        },
        .random => return .{ .number = self.random.random().float(f64) },
        .randn => return .{ .number = self.random.random().floatNorm(f64) },
        .randint => {
            const min = args[0].int;
            const max = args[1].int;
            if (min > max) return self.fail("math.randint requires min <= max", .{});
            return .{ .int = self.random.random().intRangeAtMost(i64, min, max) };
        },
        .panic => {
            const cause = self.fail("panic", .{});
            if (cause == error.OutOfMemory) return error.OutOfMemory;
            self.failure.?.native_message = try self.arena.allocator().dupe(u8, args[0].string);
            return cause;
        },
        .len => switch (args[0]) {
            .string => |text| return .{ .int = @intCast(std.unicode.utf8CountCodepoints(text) catch return self.fail("len requires valid UTF-8", .{})) },
            .list => |list| return .{ .int = @intCast(list.items().len) },
            .dict => |dict| return .{ .int = @intCast(dict.entries.count()) },
            else => {},
        },
        .dict_contains => {
            if (args[0] != .dict or args[1] != .string) return self.fail("dict_contains requires dictionary and string", .{});
            return .{ .boolean = args[0].dict.entries.contains(args[1].string) };
        },
        .dict_remove => {
            if (args[0] != .dict or args[1] != .string) return self.fail("dict_remove requires dictionary and string", .{});
            const dict = args[0].dict;
            if (dict.owner != self.identity) return self.fail("cannot modify a borrowed dictionary", .{});
            return .{ .boolean = dict.entries.orderedRemove(args[1].string) };
        },
        .dict_keys => {
            if (args[0] != .dict) return self.fail("keys requires dictionary", .{});
            const value = try self.makeList(&.{});
            for (args[0].dict.entries.keys()) |key| try value.list.owned.values.append(self.arena.allocator(), .{ .string = key });
            return value;
        },
        .copy => if (args[0] != .object) return try self.copyValue(args[0]),
        else => {},
    }
    return null;
}

/// A new outer container retains its children's runtime identities.
fn copyValue(self: *Machine, input: Value) Error!Value {
    const value = try self.materialize(input);
    try self.checkFinite(value);
    switch (value) {
        .list => |list| {
            const result = try self.allocateList(list.items());
            result.list.owned.owner = self.identity;
            return result;
        },
        .dict => |dict| {
            const result = try self.arena.allocator().create(types.Dict);
            result.* = .{};
            for (dict.entries.keys(), dict.entries.values()) |key, item| try result.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, key), item);
            result.owner = self.identity;
            return .{ .dict = result };
        },
        .record => |record_value| {
            const result = try self.arena.allocator().create(types.Record);
            result.* = .{ .owner = self.identity, .kind = record_value.kind, .fields = try self.arena.allocator().dupe(Value, record_value.fields) };
            return .{ .record = result };
        },
        else => return self.fail("copy requires a list, dictionary or struct", .{}),
    }
}

fn mutableList(self: *Machine, value: Value) Error!*std.ArrayList(Value) {
    if (value != .list) return self.fail("expected a list", .{});
    if (value.list != .owned) return self.fail("cannot modify a borrowed list view", .{});
    if (value.list.owned.owner != self.identity) return self.fail("cannot modify a borrowed task list", .{});
    return &value.list.owned.values;
}

fn makeList(self: *Machine, items: []const Value) Error!Value {
    // Validate before assigning our owner. Internal copies can then rely
    // on this invariant; every mutation validates its new references.
    try self.checkFiniteItems(items);
    const value = try self.allocateList(items);
    value.list.owned.owner = self.identity;
    return value;
}

fn prepareListItems(self: *Machine, items: []Value) Error!void {
    // A later materialization failure must still precede validation of an
    // earlier item. Shallow copies use checkFiniteItems without this step.
    for (items) |*item| item.* = try self.materialize(item.*);
    try self.checkFiniteItems(items);
}

fn checkFiniteItems(self: *Machine, items: []const Value) Error!void {
    for (items) |item| try self.checkFinite(item);
}

/// Graph construction has no owner until every cyclic node has
/// been filled. No partially initialized node can take the fast path.
fn allocateList(self: *Machine, items: []const Value) Error!Value {
    const list = try self.arena.allocator().create(types.List.Owned);
    list.* = .{};
    try list.values.appendSlice(self.arena.allocator(), items);
    return .{ .list = .{ .owned = list } };
}

fn makeDict(self: *Machine, entries: []const Value) Error!Value {
    if (entries.len % 2 != 0) return self.fail("invalid bytecode dictionary entries", .{});
    const dict = try self.arena.allocator().create(types.Dict);
    dict.* = .{};
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const key = entries[i];
        if (key != .string) return self.fail("dictionary key must be string", .{});
        if (!std.unicode.utf8ValidateSlice(key.string)) return self.fail("dictionary key must be valid UTF-8", .{});
        if (dict.entries.contains(key.string)) return self.fail("duplicate dictionary key '{s}'", .{key.string});
        const value = try self.materialize(entries[i + 1]);
        try self.checkFinite(value);
        try dict.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, key.string), value);
    }
    dict.owner = self.identity;
    return .{ .dict = dict };
}

fn makeRecord(self: *Machine, index: u32, values: []const Value) Error!Value {
    if (index >= self.program.records.len) return self.fail("invalid bytecode struct index", .{});
    const descriptor = self.program.records[index];
    if (values.len != descriptor.fields.len) return self.fail("invalid field count for struct '{s}'", .{descriptor.name});
    const record_value = try self.arena.allocator().create(types.Record);
    record_value.* = .{ .kind = Type.record(index), .fields = try self.arena.allocator().alloc(Value, values.len) };
    for (record_value.fields, values, descriptor.fields) |*target, value, field| target.* = try self.coerce(try self.materialize(value), field.kind);
    record_value.owner = self.identity;
    return .{ .record = record_value };
}

fn recordDescriptor(self: *Machine, record_value: *const types.Record) Error!*const bytecode.Record {
    const index = record_value.kind.recordIndex() orelse return self.fail("invalid struct type", .{});
    if (index >= self.program.records.len) return self.fail("invalid struct type index", .{});
    const descriptor = &self.program.records[index];
    if (record_value.fields.len != descriptor.fields.len) return self.fail("invalid field count for struct '{s}'", .{descriptor.name});
    return descriptor;
}

fn recordField(self: *Machine, record_value: *const types.Record, name: []const u8, slot: u32) Error!usize {
    const descriptor = try self.recordDescriptor(record_value);
    if (slot != 0) {
        const index = slot - 1;
        if (index >= descriptor.fields.len or !std.mem.eql(u8, descriptor.fields[index].name, name)) return self.fail("invalid bytecode struct field slot", .{});
        return index;
    }
    for (descriptor.fields, 0..) |field, index| if (std.mem.eql(u8, field.name, name)) return index;
    return self.fail("unknown field '{s}' of struct '{s}'", .{ name, descriptor.name });
}

fn readIndex(self: *Machine, object: Value, key: Value) Error!Value {
    if (object == .dict) {
        if (key != .string) return self.fail("dictionary key must be string", .{});
        const value = object.dict.entries.get(key.string) orelse return self.fail("dictionary has no key '{s}'", .{key.string});
        return self.materialize(value);
    }
    const items = types.sequence(object) orelse return self.fail("indexing requires a list or dictionary", .{});
    if (key != .int) return self.fail("list index must be int", .{});
    return self.materialize(items[try self.listIndex(key.int, items.len)]);
}

fn setIndex(self: *Machine, object: Value, key: Value, input: Value) Error!void {
    if (object == .dict) {
        if (object.dict.owner != self.identity) return self.fail("cannot modify a borrowed dictionary", .{});
        if (key != .string) return self.fail("dictionary key must be string", .{});
        if (!std.unicode.utf8ValidateSlice(key.string)) return self.fail("dictionary key must be valid UTF-8", .{});
        const value = try self.materialize(input);
        try self.checkFinite(value);
        const owned_key = if (object.dict.entries.contains(key.string)) key.string else try self.arena.allocator().dupe(u8, key.string);
        const entry = try object.dict.entries.getOrPut(self.arena.allocator(), owned_key);
        entry.value_ptr.* = value;
        return;
    }
    const list = try self.mutableList(object);
    if (key != .int) return self.fail("list index must be int", .{});
    const index = try self.listIndex(key.int, list.items.len);
    const value = try self.materialize(input);
    try self.checkFinite(value);
    list.items[index] = value;
}

fn bindArguments(self: *Machine, index: u32, count: u32) Error!void {
    if (index >= self.program.argument_bindings.len) return self.fail("invalid bytecode argument binding", .{});
    const binding = self.program.argument_bindings[index];
    if (binding.slots.len != count or binding.parameter_count != count) return self.fail("invalid bytecode argument binding count", .{});
    const args = try self.arguments(count);
    const ordered = try self.gpa.alloc(Value, count);
    defer self.gpa.free(ordered);
    const supplied = try self.gpa.alloc(bool, count);
    defer self.gpa.free(supplied);
    @memset(supplied, false);
    for (args, binding.slots) |arg, slot| {
        if (slot >= count or supplied[slot]) return self.fail("invalid bytecode argument binding slot", .{});
        ordered[slot] = arg;
        supplied[slot] = true;
    }
    @memcpy(args, ordered);
}

fn listIndex(self: *Machine, index: i64, length: usize) Error!usize {
    if (index < 0 or @as(u64, @intCast(index)) >= length)
        return self.fail("list index {d} is outside length {d}", .{ index, length });
    return @intCast(index);
}

fn sliceList(self: *Machine, object: Value, start: Value, stop: ?Value, step: Value) Error!Value {
    const items = types.sequence(object) orelse return self.fail("slicing requires a list", .{});
    if (start != .int or step != .int or (stop != null and stop.? != .int))
        return self.fail("list slice bounds and step must be int", .{});
    const end = stop orelse blk: {
        const length = std.math.cast(i64, items.len) orelse return self.fail("list length exceeds the index range", .{});
        if (start.int < 0 or start.int > length)
            return self.fail("list slice start {d} is outside length {d}", .{ start.int, items.len });
        break :blk Value{ .int = length - 1 };
    };
    const range = try self.initializeRange(start, end, step);
    const result = try self.allocateList(&.{});
    // Import selected template elements together so repeated and cyclic
    // children retain their aliases without copying an unselected prefix.
    var seen: std.AutoHashMapUnmanaged(SequenceKey, Value) = .empty;
    defer seen.deinit(self.gpa);
    var current = range[0];
    while (try self.rangeTest(current, range[1], range[2])) {
        // One instruction cannot bypass the execution budget by selecting
        // an arbitrarily large list. Charge each selected element.
        try self.tick();
        const index = try self.listIndex(current.int, items.len);
        try self.checkFinite(items[index]);
        const value = try self.materializeGraph(items[index], &seen, 0);
        try result.list.owned.values.append(self.arena.allocator(), value);
        const next = try self.rangeAdvance(current, range[1], range[2]);
        if (!next.more) break;
        current = next.value;
    }
    self.finishGraph(&seen);
    result.list.owned.owner = self.identity;
    return result;
}

/// A native sequence or constant template never becomes mutable Program
/// storage. Native graphs retain sharing within one returned value.
fn materialize(self: *Machine, value: Value) Error!Value {
    if (!isTemplate(value)) return value;
    // Source descriptors remain external/immutable. Validate their entire
    // graph before any clone receives the execution's trusted owner.
    try self.checkFiniteExternal(value);
    if (value == .list) {
        const items = value.list.items();
        var nested = false;
        for (items) |item| if (isTemplate(item)) {
            nested = true;
            break;
        };
        if (!nested) return self.makeList(items);
    }
    var seen: std.AutoHashMapUnmanaged(SequenceKey, Value) = .empty;
    defer seen.deinit(self.gpa);
    const result = try self.materializeGraph(value, &seen, 0);
    self.finishGraph(&seen);
    return result;
}

fn finishGraph(self: *Machine, seen: *std.AutoHashMapUnmanaged(SequenceKey, Value)) void {
    var values = seen.valueIterator();
    while (values.next()) |value| switch (value.*) {
        .list => |list| list.owned.owner = self.identity,
        .dict => |dict| dict.owner = self.identity,
        .record => |record_value| record_value.owner = self.identity,
        .function => |function| function.bound.owner = self.identity,
        else => unreachable,
    };
}

const SequenceKey = struct { address: usize, length: usize = 0, kind: enum { list, dict, record, function } = .list };
fn isTemplate(value: Value) bool {
    return switch (value) {
        .list => |list| list == .view,
        .dict => |dict| dict.owner == null,
        .record => |record_value| record_value.owner == null,
        .function => |function| function == .bound and function.bound.owner == null,
        else => false,
    };
}
fn materializeGraph(self: *Machine, value: Value, seen: *std.AutoHashMapUnmanaged(SequenceKey, Value), depth: usize) Error!Value {
    if (!isTemplate(value)) return value;
    const key: SequenceKey = switch (value) {
        .list => |list| .{ .address = @intFromPtr(list.items().ptr), .length = list.items().len },
        .dict => |dict| .{ .address = @intFromPtr(dict), .kind = .dict },
        .record => |record_value| .{ .address = @intFromPtr(record_value), .kind = .record },
        .function => |function| .{ .address = @intFromPtr(function.bound), .kind = .function },
        else => unreachable,
    };
    if (seen.get(key)) |previous| return previous;
    if (depth > 256) return self.fail("native collection nesting exceeds 256", .{});
    switch (value) {
        .list => |list| {
            const result = try self.allocateList(list.items());
            if (list.items().len != 0) try seen.put(self.gpa, key, result) else result.list.owned.owner = self.identity;
            for (result.list.owned.values.items) |*item| item.* = try self.materializeGraph(item.*, seen, depth + 1);
            return result;
        },
        .dict => |dict| {
            const result = try self.arena.allocator().create(types.Dict);
            result.* = .{};
            const output: Value = .{ .dict = result };
            try seen.put(self.gpa, key, output);
            for (dict.entries.keys(), dict.entries.values()) |name, item| {
                try result.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, name), try self.materializeGraph(item, seen, depth + 1));
            }
            return output;
        },
        .record => |record_value| {
            _ = try self.recordDescriptor(record_value);
            const result = try self.arena.allocator().create(types.Record);
            result.* = .{ .kind = record_value.kind, .fields = try self.arena.allocator().alloc(Value, record_value.fields.len) };
            const output: Value = .{ .record = result };
            try seen.put(self.gpa, key, output);
            for (result.fields, record_value.fields) |*target, item| target.* = try self.materializeGraph(item, seen, depth + 1);
            return output;
        },
        .function => |function| {
            const bound = function.bound;
            const result = try self.arena.allocator().create(types.Function.Bound);
            result.* = .{ .target = bound.target, .arguments = try self.arena.allocator().alloc(Value, bound.arguments.len), .names = try self.arena.allocator().dupe(?[]const u8, bound.names) };
            for (@constCast(result.names)) |*name| if (name.*) |label| {
                name.* = try self.arena.allocator().dupe(u8, label);
            };
            const output: Value = .{ .function = .{ .bound = result } };
            try seen.put(self.gpa, key, output);
            for (result.arguments, bound.arguments) |*destination, item| destination.* = try self.materializeGraph(item, seen, depth + 1);
            return output;
        },
        else => unreachable,
    }
}

fn appendList(self: *Machine, target: Value, input: Value) Error!void {
    const list = try self.mutableList(target);
    // Appending exposes nested elements through a mutable script list.
    // Import the complete graph once, retaining its internal aliases.
    const value = try self.materialize(input);
    try self.checkFinite(value);
    if (value.valueType() == .list) {
        const other = types.sequence(value) orelse return self.fail("expected a list", .{});
        if (value.list == .owned and target.list.owned == value.list.owned) {
            const count = list.items.len;
            try list.ensureUnusedCapacity(self.arena.allocator(), count);
            // Reserve first: the old prefix may have moved during growth.
            list.appendSliceAssumeCapacity(list.items[0..count]);
        } else try list.appendSlice(self.arena.allocator(), other);
    } else try list.append(self.arena.allocator(), value);
}

fn appendListItems(self: *Machine, instruction: bytecode.Instruction) Error!void {
    self.current_span.start = instruction.b;
    const items = try self.arguments(instruction.a);
    try self.prepareListItems(items);
    self.current_span = instruction.span;
    const start = self.stack.items.len - items.len;
    const base = self.frames.items[self.frames.items.len - 1].stack_base;
    if (start <= base) return self.fail("invalid bytecode operand stack underflow", .{});
    const target = self.stack.items[start - 1];
    self.stack.items.len = start - 1;
    const list = try self.mutableList(target);
    try list.appendSlice(self.arena.allocator(), items);
}

fn push(self: *Machine, value: Value) Error!void {
    try self.stack.append(self.gpa, value);
}
fn pop(self: *Machine) Error!Value {
    const base = if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].stack_base;
    if (self.stack.items.len <= base) return self.fail("invalid bytecode operand stack underflow", .{});
    return self.stack.pop().?;
}
fn peek(self: *Machine) Error!Value {
    const value = try self.pop();
    try self.push(value);
    return value;
}
fn arguments(self: *Machine, count: usize) Error![]Value {
    const base = if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].stack_base;
    if (count > self.stack.items.len - base) return self.fail("invalid bytecode argument stack underflow", .{});
    return self.stack.items[self.stack.items.len - count ..];
}
fn stringConstant(self: *Machine, index: u32) Error![]const u8 {
    if (index >= self.program.constants.len or self.program.constants[index] != .string) return self.fail("invalid bytecode string constant", .{});
    return self.program.constants[index].string;
}
fn jump(self: *Machine, destination: u32) Error!void {
    const frame = &self.frames.items[self.frames.items.len - 1];
    if (destination >= self.program.functions[frame.function].code.len) return self.fail("invalid bytecode jump destination", .{});
    frame.ip = destination;
}
fn enter(self: *Machine, function_index: u32, count: usize, call_span: Span) Error!void {
    if (function_index >= self.program.functions.len) return self.fail("invalid bytecode function index", .{});
    if (self.frames.items.len + self.outer_call_depth >= self.limits.call_depth) return self.fail("call depth limit ({d}) exceeded", .{self.limits.call_depth});
    const function = self.program.functions[function_index];
    if (!function.acceptsCount(count) or function.parameters.len > function.local_types.len)
        return self.fail("invalid argument count for '{s}'", .{function.name});
    if (function.variadic != null and (function.parameters.len == 0 or function.parameters[function.parameters.len - 1] != .list))
        return self.fail("invalid variadic parameter for '{s}'", .{function.name});
    const fixed = function.fixedCount();
    if (function.default_functions.len != 0 and function.default_functions.len != function.parameters.len) return self.fail("invalid function defaults", .{});
    if (function.defaults.len != 0) {
        var optional = false;
        for (function.defaults[0..fixed], 0..) |value, i| {
            if (value != null or (function.default_functions.len != 0 and function.default_functions[i] != null)) optional = true else if (optional)
                return self.fail("invalid default parameter order for '{s}'", .{function.name});
        }
        if (function.variadic != null and function.defaults[fixed] != null)
            return self.fail("variadic parameter cannot have a default for '{s}'", .{function.name});
    }
    var supplied = count;
    if (function.default_functions.len != 0) while (supplied < fixed) : (supplied += 1) {
        const value = if (function.default_functions[supplied]) |default|
            try self.invokeFunction(.{ .function = .{ .bytecode = default } }, &.{})
        else
            function.defaults[supplied].?;
        try self.push(value);
    };
    const args = try self.arguments(supplied);
    const local_base = self.locals.items.len;
    const new_length = std.math.add(usize, local_base, function.local_types.len) catch return error.OutOfMemory;
    try self.locals.resize(self.gpa, new_length);
    try self.local_initialized.resize(self.gpa, new_length);
    @memset(self.locals.items[local_base..], .unit);
    @memset(self.local_initialized.items[local_base..], false);
    for (function.parameters[0..fixed], 0..) |expected, index| {
        const arg = if (index < args.len) args[index] else function.defaults[index].?;
        self.locals.items[local_base + index] = try self.coerce(try self.materialize(arg), expected);
        self.local_initialized.items[local_base + index] = true;
    }
    if (function.variadic) |element| {
        const remaining = args[@min(fixed, args.len)..];
        for (remaining) |*arg| arg.* = try self.coerce(try self.materialize(arg.*), element);
        self.locals.items[local_base + fixed] = try self.makeList(remaining);
        self.local_initialized.items[local_base + fixed] = true;
    }
    self.stack.items.len -= supplied;
    try self.frames.append(self.gpa, .{ .function = function_index, .local_base = local_base, .stack_base = self.stack.items.len, .call_span = call_span, .call_module = self.current_module });
}
fn coerce(self: *Machine, value: Value, expected: Type) Error!Value {
    const actual = value.valueType();
    if (!Type.accepts(expected, actual))
        return self.fail("expected {s}, received {s}", .{ self.typeName(expected), self.typeName(actual) });
    try self.checkFinite(value);
    if (expected == .number and value == .int) return .{ .number = @floatFromInt(value.int) };
    if ((expected == .length or expected == .angle) and (value == .int or value == .number)) {
        const magnitude = try self.number(value);
        return .{ .quantity = if (expected == .length) units.fromPoints(magnitude) else .{ .value = magnitude, .dimension = .rotation } };
    }
    return value;
}
fn typeName(self: *const Machine, kind: Type) []const u8 {
    if (kind.recordIndex()) |index| if (index < self.program.records.len) return self.program.records[index].name;
    return kind.name();
}
fn checkFinite(self: *Machine, value: Value) Error!void {
    return self.checkFiniteGraph(value, false);
}
/// Ownership is a validation invariant, not a shortcut at an FFI boundary.
/// Validate Host results and Program descriptors regardless of their owner.
fn checkFiniteExternal(self: *Machine, value: Value) Error!void {
    return self.checkFiniteGraph(value, true);
}
fn ownsValidated(self: *const Machine, value: Value) bool {
    return switch (value) {
        .list => |list| list == .owned and list.owned.owner == self.identity,
        .dict => |dict| dict.owner == self.identity,
        .record => |record_value| record_value.owner == self.identity,
        .function => |function| function == .bound and function.bound.owner == self.identity,
        else => false,
    };
}
fn checkFiniteGraph(self: *Machine, value: Value, external: bool) Error!void {
    try self.checkFiniteLeaf(value);
    switch (value) {
        .list, .dict, .record => {},
        .function => |function| if (function != .bound) return,
        else => return,
    }
    if (!external and self.ownsValidated(value)) return;
    var pending: std.ArrayList(Value) = .empty;
    defer pending.deinit(self.gpa);
    var seen: std.AutoHashMapUnmanaged(SequenceKey, void) = .empty;
    defer seen.deinit(self.gpa);
    try pending.append(self.gpa, value);
    while (pending.pop()) |item| {
        try self.checkFiniteLeaf(item);
        if (!external and self.ownsValidated(item)) continue;
        const key: SequenceKey = switch (item) {
            .list => |list| .{ .address = @intFromPtr(list.items().ptr), .length = list.items().len },
            .dict => |dict| .{ .address = @intFromPtr(dict), .kind = .dict },
            .record => |record_value| .{ .address = @intFromPtr(record_value), .kind = .record },
            .function => |function| if (function == .bound) .{ .address = @intFromPtr(function.bound), .kind = .function } else continue,
            else => continue,
        };
        const visited = try seen.getOrPut(self.gpa, key);
        if (visited.found_existing) continue;
        switch (item) {
            .list => |list| try pending.appendSlice(self.gpa, list.items()),
            .dict => |dict| {
                for (dict.entries.keys()) |name| if (!std.unicode.utf8ValidateSlice(name)) return self.fail("dictionary key must be valid UTF-8", .{});
                try pending.appendSlice(self.gpa, dict.entries.values());
            },
            .record => |record_value| {
                const descriptor = try self.recordDescriptor(record_value);
                for (descriptor.fields, record_value.fields) |field, field_value| {
                    if (!Type.accepts(field.kind, field_value.valueType())) return self.fail("field '{s}' expects {s}, received {s}", .{ field.name, self.typeName(field.kind), self.typeName(field_value.valueType()) });
                }
                try pending.appendSlice(self.gpa, record_value.fields);
            },
            .function => |function| {
                const bound = function.bound;
                if (bound.names.len != bound.arguments.len) return self.fail("invalid bound function argument names", .{});
                try pending.appendSlice(self.gpa, bound.arguments);
            },
            else => unreachable,
        }
    }
}
fn checkFiniteLeaf(self: *Machine, value: Value) Error!void {
    switch (value) {
        .omitted => return self.fail("omitted argument marker cannot be used as a value", .{}),
        .number => |numeric_value| if (!std.math.isFinite(numeric_value)) {
            return self.fail("arithmetic produced a non-finite value", .{});
        },
        .quantity => |quantity| if (!std.math.isFinite(quantity.value)) {
            return self.fail("arithmetic produced a non-finite quantity", .{});
        },
        .pair => |pair| if (!pair.isFinite()) {
            return self.fail("arithmetic produced a non-finite pair", .{});
        },
        .handle => |handle| switch (handle.kind) {
            .path, .color, .pen, .transform, .solver, .variable, .linear, .solution, .text, .measure => {},
            else => return self.fail("host returned an invalid native handle type", .{}),
        },
        else => {},
    }
}
fn number(self: *Machine, value: Value) Error!f64 {
    const result = switch (value) {
        .int => |integer| @as(f64, @floatFromInt(integer)),
        .number => |float| float,
        else => return self.fail("expected a number, received {s}", .{self.typeName(value.valueType())}),
    };
    if (!std.math.isFinite(result)) return self.fail("number must be finite", .{});
    return result;
}
fn boolean(self: *Machine, value: Value) Error!bool {
    return switch (value) {
        .boolean => |result| result,
        else => self.fail("condition must be bool", .{}),
    };
}
fn arithmetic(self: *Machine, op: bytecode.Op, left: Value, right: Value) Error!Value {
    if (left == .handle or right == .handle) return self.nativeBinary(op, left, right);
    if (op == .add and left == .string and right == .string) {
        const len = std.math.add(usize, left.string.len, right.string.len) catch return error.OutOfMemory;
        const result = try self.arena.allocator().alloc(u8, len);
        @memcpy(result[0..left.string.len], left.string);
        @memcpy(result[left.string.len..], right.string);
        return .{ .string = result };
    }
    return numeric.valueArithmetic(op, left, right) catch |err| return self.numericFailure(err);
}
fn numericFailure(self: *Machine, err: anyerror) Error {
    return switch (err) {
        error.DivisionByZero => self.fail("division by zero", .{}),
        error.Overflow => self.fail("integer overflow", .{}),
        error.DimensionMismatch => self.fail("incompatible quantity dimensions", .{}),
        error.DimensionOverflow => self.fail("quantity dimension exponent overflow", .{}),
        error.InvalidPower => self.fail("quantity power requires compatible integer dimensions", .{}),
        error.TypeMismatch => self.fail("operator requires compatible numeric or pair operands", .{}),
        else => self.fail("arithmetic produced a non-finite value", .{}),
    };
}
fn nativeBinary(self: *Machine, op: bytecode.Op, left: Value, right: Value) Error!Value {
    if (self.host.vtable.binary == null) return self.fail("operator {s} requires a host for these operands", .{@tagName(op)});
    const result = self.host.binary(self.arena.allocator(), op, left, right) catch |err| return self.nativeFailure(err);
    try self.checkFiniteExternal(result);
    return self.materialize(result);
}
fn listIterationTest(self: *Machine, current: Value, collection: Value, step: Value) Error!bool {
    if (current != .int or current.int < 0 or step != .int) return self.fail("invalid iterator state", .{});
    if (collection.list.items().len != @as(u64, @bitCast(step.int))) return self.fail("collection structure changed during iteration", .{});
    const length = collection.list.items().len;
    return @as(u64, @intCast(current.int)) < length;
}

fn initializeRange(self: *Machine, start: Value, stop: Value, step: Value) Error![3]Value {
    if (start == .quantity or stop == .quantity or step == .quantity) {
        const dimension = if (start == .quantity) start.quantity.dimension else if (stop == .quantity) stop.quantity.dimension else step.quantity.dimension;
        var values = [_]Value{ start, stop, step };
        for (&values) |*value| {
            var quantity = types.asQuantity(value.*) catch return self.fail("range bounds and step must be numeric", .{});
            if (quantity.dimension.eql(.scalar) and quantity.value == 0) quantity.dimension = dimension;
            if (!quantity.dimension.eql(dimension)) return self.fail("range bounds and step require compatible dimensions", .{});
            _ = quantity.checked() catch |err| return self.numericFailure(err);
            value.* = types.fromQuantity(quantity);
        }
        if ((types.asQuantity(values[2]) catch unreachable).value == 0) return self.fail("range step must not be zero", .{});
        return values;
    }
    // Validate even an empty range before its first comparison or body.
    _ = try self.number(start);
    _ = try self.number(stop);
    if (try self.number(step) == 0) return self.fail("range step must not be zero", .{});
    if (start == .number or stop == .number or step == .number) {
        return .{ try self.coerce(start, .number), try self.coerce(stop, .number), try self.coerce(step, .number) };
    }
    return .{ start, stop, step };
}
fn rangeTest(self: *Machine, current: Value, stop: Value, step: Value) Error!bool {
    const direction = (types.asQuantity(step) catch return self.fail("range step must be numeric", .{})).value;
    if (direction == 0) return self.fail("range step must not be zero", .{});
    try self.checkFinite(current);
    try self.checkFinite(stop);
    const order = try self.compare(current, stop);
    return if (direction > 0) order != .gt else order != .lt;
}
const RangeProgress = struct { value: Value, more: bool };
fn rangeAdvance(self: *Machine, current: Value, stop: Value, step: Value) Error!RangeProgress {
    const finished: RangeProgress = .{ .value = current, .more = false };
    if (!try self.rangeTest(current, stop, step) or try self.compare(current, stop) == .eq) return finished;
    const next: Value = if (current == .int and step == .int) blk: {
        const result = @addWithOverflow(current.int, step.int);
        // A monotonic range has passed its finite stop when the next
        // integer cannot be represented; this is normal loop completion.
        if (result[1] != 0) return finished;
        break :blk .{ .int = result[0] };
    } else if (current == .quantity) blk: {
        const sum = numeric.valueArithmetic(.add, current, step) catch |err| {
            if (err == error.NonFinite) return finished;
            return self.numericFailure(err);
        };
        break :blk sum;
    } else blk: {
        const sum = try self.number(current) + try self.number(step);
        if (!std.math.isFinite(sum)) return finished;
        break :blk .{ .number = sum };
    };
    if (try self.compare(next, current) == .eq) return self.fail("range step is too small to advance the current value", .{});
    return if (try self.rangeTest(next, stop, step)) .{ .value = next, .more = true } else finished;
}
fn compare(self: *Machine, left: Value, right: Value) Error!std.math.Order {
    try self.checkFinite(left);
    try self.checkFinite(right);
    if (left == .quantity or right == .quantity) return units.compare(types.asQuantity(left) catch return self.fail("comparison requires compatible values", .{}), types.asQuantity(right) catch return self.fail("comparison requires compatible values", .{})) catch |err| return self.numericFailure(err);
    return switch (left) {
        .int => |integer| switch (right) {
            .int => |other| std.math.order(integer, other),
            .number => |float| compareIntegerFloat(integer, float),
            else => self.fail("comparison requires compatible values", .{}),
        },
        .number => |float| switch (right) {
            .int => |integer| reverseOrder(compareIntegerFloat(integer, float)),
            .number => |other| std.math.order(float, other),
            else => self.fail("comparison requires compatible values", .{}),
        },
        .string => |string| if (right == .string) std.mem.order(u8, string, right.string) else self.fail("comparison requires compatible values", .{}),
        else => self.fail("ordering requires numbers or strings", .{}),
    };
}
fn valuesEqual(self: *Machine, left: Value, right: Value) Error!bool {
    const Comparison = struct { left: Value, right: Value };
    const SequencePair = struct { left: usize, right: usize, length: usize, kind: enum { list, dict, record } = .list };
    var pending: std.ArrayList(Comparison) = .empty;
    defer pending.deinit(self.gpa);
    var seen: std.AutoHashMapUnmanaged(SequencePair, void) = .empty;
    defer seen.deinit(self.gpa);
    try self.checkFinite(left);
    try self.checkFinite(right);
    try pending.append(self.gpa, .{ .left = left, .right = right });
    while (pending.pop()) |comparison| {
        try self.tick();
        const a = comparison.left;
        const b = comparison.right;
        try self.checkFiniteLeaf(a);
        try self.checkFiniteLeaf(b);
        if (a.valueType().isScalar() and b.valueType().isScalar()) {
            if (try self.compare(a, b) != .eq) return false;
            continue;
        }
        if (a == .dict) {
            if (b != .dict or a.dict.entries.count() != b.dict.entries.count()) return false;
            const pair: SequencePair = .{ .left = @intFromPtr(a.dict), .right = @intFromPtr(b.dict), .length = a.dict.entries.count(), .kind = .dict };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (a.dict.entries.keys(), a.dict.entries.values()) |key, value| {
                const other = b.dict.entries.get(key) orelse return false;
                try pending.append(self.gpa, .{ .left = value, .right = other });
            }
            continue;
        }
        if (a == .record) {
            if (b != .record or a.record.kind != b.record.kind) return false;
            const pair: SequencePair = .{ .left = @intFromPtr(a.record), .right = @intFromPtr(b.record), .length = a.record.fields.len, .kind = .record };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (a.record.fields, b.record.fields) |value, other| try pending.append(self.gpa, .{ .left = value, .right = other });
            continue;
        }
        if (types.sequence(a)) |items| {
            const other = types.sequence(b) orelse return false;
            if (items.len != other.len) return false;
            if (items.len == 0) continue;
            const pair: SequencePair = .{ .left = @intFromPtr(items.ptr), .right = @intFromPtr(other.ptr), .length = items.len };
            const visited = try seen.getOrPut(self.gpa, pair);
            if (visited.found_existing) continue;
            for (items, other) |a_value, b_value| try pending.append(self.gpa, .{ .left = a_value, .right = b_value });
            continue;
        }
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        switch (a) {
            .unit => {},
            .omitted => unreachable,
            .int, .number, .quantity => unreachable,
            .boolean => |boolean_value| if (boolean_value != b.boolean) {
                return false;
            },
            .string => |string| if (!std.mem.eql(u8, string, b.string)) {
                return false;
            },
            .pair => |pair| if (!pair.dimension.eql(b.pair.dimension) or pair.x != b.pair.x or pair.y != b.pair.y) {
                return false;
            },
            .handle => |handle| if (handle.kind != b.handle.kind or handle.index != b.handle.index) {
                return false;
            },
            .function => |fun| if (!std.meta.eql(fun, b.function)) return false,
            .object => |object| if (!std.meta.eql(object, b.object)) return false,
            .list, .dict, .record => unreachable,
        }
    }
    return true;
}
fn nativeFailure(self: *Machine, err: anyerror) Error {
    if (err == error.RuntimeFailed and self.failure != null) return error.RuntimeFailed;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const message = self.host.errorMessage();
    return self.nativeFailureMessage(err, message);
}
fn nativeFailureMessage(self: *Machine, err: anyerror, message: []const u8) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const failure_error = self.fail("native operation failed: {s}", .{@errorName(err)});
    if (failure_error == error.OutOfMemory) return error.OutOfMemory;
    if (self.failure) |*failure| failure.native_message = self.arena.allocator().dupe(u8, message) catch return error.OutOfMemory;
    return error.RuntimeFailed;
}
fn fail(self: *Machine, comptime format: []const u8, args: anytype) Error {
    if (self.failure == null) {
        self.failure = .{ .diagnostic = source.Diagnostic.init(self.current_span, format, args) };
        const origin = if (self.current_module == std.math.maxInt(u32) and self.frames.items.len != 0)
            self.program.functions[self.frames.items[self.frames.items.len - 1].function].module
        else
            self.current_module;
        if (origin < self.program.modules.len) {
            const module_ = self.program.modules[origin];
            self.failure.?.diagnostic.setSource(module_.name, module_.source_text);
        }
        const trace = self.arena.allocator().alloc(TraceEntry, self.frames.items.len) catch return error.OutOfMemory;
        for (trace, 0..) |*entry, index| {
            const frame = self.frames.items[self.frames.items.len - 1 - index];
            const span = if (index == 0) self.current_span else self.frames.items[self.frames.items.len - index].call_span;
            const module = if (index == 0) origin else self.frames.items[self.frames.items.len - index].call_module;
            entry.* = .{ .function = self.program.functions[frame.function].name, .module = if (module == std.math.maxInt(u32)) self.program.functions[frame.function].module else module, .span = span };
        }
        self.failure.?.trace = trace;
    }
    return error.RuntimeFailed;
}

fn testProgram(functions: []const bytecode.Function, constants: []const Value, names: []const []const u8, global_types: []const Type) !bytecode.Program {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const readonly = try arena.allocator().alloc(bool, names.len);
    @memset(readonly, false);
    return .{ .arena = arena, .source_text = "", .name = "vm-test", .functions = functions, .constants = constants, .parameters = &.{}, .global_names = names, .global_types = global_types, .readonly_globals = readonly };
}

const I = bytecode.Instruction;
fn ins(op: bytecode.Op, a: u32) I {
    return .{ .op = op, .a = a };
}

test "aggregate VM dictionary aliases insertion order and shallow copy" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child = try machine.makeList(&.{.{ .int = 1 }});
    const original = try machine.makeDict(&.{ .{ .string = "a" }, child, .{ .string = "b" }, .{ .int = 2 } });
    const alias = original;
    try machine.setIndex(alias, .{ .string = "a" }, child);
    try machine.setIndex(alias, .{ .string = "b" }, .{ .int = 3 });
    const copied = (try machine.coreBuiltin(.copy, &.{original})).?;
    try std.testing.expect(original.dict != copied.dict);
    try std.testing.expectEqual(@as(i64, 3), original.dict.entries.get("b").?.int);
    try machine.appendList(child, .{ .int = 4 });
    try std.testing.expectEqual(@as(usize, 2), copied.dict.entries.get("a").?.list.items().len);
    try machine.setIndex(copied, .{ .string = "c" }, .{ .int = 5 });
    try std.testing.expect(!original.dict.entries.contains("c"));
    try std.testing.expect((try machine.coreBuiltin(.dict_remove, &.{ alias, .{ .string = "a" } })).?.boolean);
    try std.testing.expect(!(try machine.coreBuiltin(.dict_remove, &.{ alias, .{ .string = "a" } })).?.boolean);
    try machine.setIndex(alias, .{ .string = "a" }, child);
    const keys = (try machine.coreBuiltin(.dict_keys, &.{original})).?.list.items();
    try std.testing.expectEqualStrings("b", keys[0].string);
    try std.testing.expectEqualStrings("a", keys[1].string);
    try std.testing.expect((try machine.coreBuiltin(.dict_contains, &.{ original, .{ .string = "b" } })).?.boolean);
    try std.testing.expectEqual(@as(i64, 2), (try machine.coreBuiltin(.len, &.{original})).?.int);
}

fn copyListExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    const child = try machine.makeList(&.{.{ .int = 7 }});
    const original = try machine.makeList(&.{ child, child });
    try machine.appendList(original, try machine.makeList(&.{original}));
    // A foreign graph must be checked, while the shallow copy retains its
    // nested identities and receives an independently mutable outer list.
    var foreign: types.Ownership = .{};
    original.list.owned.owner = &foreign;
    const copied = try machine.copyValue(original);
    try std.testing.expect(copied.list.owned != original.list.owned);
    try std.testing.expectEqual(machine.identity, copied.list.owned.owner.?);
    try std.testing.expect(copied.list.items()[0].list.owned == child.list.owned);
    try std.testing.expect(copied.list.items()[0].list.owned == copied.list.items()[1].list.owned);
    try std.testing.expect(copied.list.items()[2].list.owned == original.list.owned);
    try machine.appendList(copied, .{ .int = 9 });
    try std.testing.expectEqual(@as(usize, 3), original.list.items().len);
}

test "aggregate VM shallow list copy validates once and preserves cycles through allocation failures" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    try copyListExercise(std.testing.allocator, &program);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyListExercise, .{&program});
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child = try machine.makeList(&.{.{ .int = 7 }});
    var foreign: types.Ownership = .{};
    child.list.owned.owner = &foreign;
    const original = try machine.makeList(&.{child});
    original.list.owned.owner = &foreign;
    // Graph traversal uses gpa, while the new container uses the existing
    // arena. Count traversal allocations independently of container growth.
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const previous = machine.gpa;
    machine.gpa = counter.allocator();
    defer machine.gpa = previous;
    try machine.checkFinite(original);
    const one_validation = counter.allocations;
    try std.testing.expect(one_validation > 0);
    _ = try machine.copyValue(original);
    try std.testing.expectEqual(one_validation * 2, counter.allocations);
    child.list.owned.values.items[0] = .{ .number = std.math.nan(f64) };
    try std.testing.expectError(error.RuntimeFailed, machine.copyValue(original));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
}

test "aggregate VM dictionary opcodes validate duplicate and missing keys" {
    const code = [_]I{
        ins(.constant, 0), ins(.constant, 1),     ins(.make_dict, 1), ins(.duplicate, 0),   ins(.store_global, 0),
        ins(.constant, 0), ins(.constant, 2),     ins(.set_index, 0), ins(.load_global, 0), ins(.constant, 0),
        ins(.index, 0),    ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "Ω" }, .{ .int = 1 }, .{ .int = 7 } }, &.{ "dict", "result" }, &.{ .dict, .int });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("result").?.int);
    try std.testing.expectError(error.RuntimeFailed, machine.readIndex(machine.getGlobal("dict").?, .{ .string = "absent" }));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "has no key 'absent'") != null);
    var duplicate = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer duplicate.deinit();
    try std.testing.expectError(error.RuntimeFailed, duplicate.makeDict(&.{ .{ .string = "same" }, .unit, .{ .string = "same" }, .unit }));
    try std.testing.expect(std.mem.indexOf(u8, duplicate.failure.?.text(), "duplicate dictionary key") != null);
}

test "aggregate VM nominal struct field typing and static slots" {
    const code = [_]I{
        ins(.constant, 0),     .{ .op = .make_record, .a = 0, .b = 1 }, ins(.duplicate, 0),   ins(.store_global, 0),
        ins(.constant, 1),     .{ .op = .set_field, .a = 2, .b = 1 },   ins(.load_global, 0), .{ .op = .field, .a = 2, .b = 1 },
        ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .int = 9 }, .{ .string = "count" } }, &.{ "state", "result" }, &.{ Type.record(0), .int });
    defer program.deinit();
    program.records = &.{
        .{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} },
        .{ .name = "Other", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} },
    };
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("result").?.int);
    const state = machine.getGlobal("state").?;
    const alias = state;
    alias.record.fields[0] = .{ .int = 12 };
    try std.testing.expectEqual(@as(i64, 12), state.record.fields[0].int);
    const copy = try machine.copyValue(state);
    copy.record.fields[0] = .{ .int = 13 };
    try std.testing.expectEqual(@as(i64, 12), state.record.fields[0].int);
    try std.testing.expectError(error.RuntimeFailed, machine.coerce(state, Type.record(1)));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "expected Other, received State") != null);
    var wrong = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.RuntimeFailed, wrong.makeRecord(0, &.{.{ .string = "wrong" }}));
}

test "aggregate VM default mixed graphs clone cycles and aliases freshly per call" {
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    try dict.entries.put(std.testing.allocator, "self", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "record", .{ .record = &record_value });
    const list_values = [_]Value{ .{ .dict = &dict }, .{ .record = &record_value } };
    try dict.entries.put(std.testing.allocator, "list", types.listView(&list_values));
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ .{ .op = .call, .a = 1 }, ins(.store_global, 0), .{ .op = .call, .a = 1 }, ins(.store_global, 1), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "fresh", .code = &.{ ins(.load_local, 0), ins(.return_value, 0) }, .parameters = &.{.dict}, .defaults = &.{Value{ .dict = &dict }}, .result = .dict, .local_types = &.{.dict} },
    }, &.{}, &.{ "first", "second" }, &.{ .dict, .dict });
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    for ([_]*Machine{ &first, &second }) |machine| {
        _ = try machine.execute(&.{});
        const a = machine.getGlobal("first").?.dict;
        const b = machine.getGlobal("second").?.dict;
        try std.testing.expect(a != b);
        try std.testing.expectEqual(a, a.entries.get("self").?.dict);
        try std.testing.expectEqual(a, a.entries.get("record").?.record.fields[0].dict);
        const list = a.entries.get("list").?.list.items();
        try std.testing.expectEqual(a, list[0].dict);
        try std.testing.expectEqual(a.entries.get("record").?.record, list[1].record);
        try std.testing.expect(try machine.valuesEqual(.{ .dict = a }, .{ .dict = b }));
        try machine.setIndex(.{ .dict = a }, .{ .string = "extra" }, .{ .int = 1 });
        try std.testing.expect(!b.entries.contains("extra"));
        try std.testing.expect(!try machine.valuesEqual(.{ .dict = a }, .{ .dict = b }));
    }
    try std.testing.expect(first.getGlobal("first").?.dict != second.getGlobal("first").?.dict);
    try std.testing.expect(!dict.entries.contains("extra"));
    try std.testing.expect(record_value.owner == null);
}

test "aggregate VM owner checks reject foreign dictionaries lists and structs" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.load_global, 0), ins(.constant, 0), .{ .op = .set_field, .a = 1, .b = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .string = "count" } }, &.{"state"}, &.{Type.record(0)});
    defer program.deinit();
    program.records = &.{.{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
    var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer owner.deinit();
    const dict = try owner.makeDict(&.{});
    var borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer borrower.deinit();
    try std.testing.expectError(error.RuntimeFailed, borrower.setIndex(dict, .{ .string = "x" }, .unit));
    try std.testing.expectEqual(@as(usize, 0), dict.dict.entries.count());
    const list = try owner.makeList(&.{.unit});
    var list_borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer list_borrower.deinit();
    try std.testing.expectError(error.RuntimeFailed, list_borrower.setIndex(list, .{ .int = 0 }, .{ .int = 1 }));
    try std.testing.expectEqual(Value.unit, list.list.items()[0]);
    const copied = try owner.copyValue(dict);
    try std.testing.expectEqual(owner.identity, copied.dict.owner.?);
    const record_value = try owner.makeRecord(0, &.{.{ .int = 0 }});
    var record_borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer record_borrower.deinit();
    record_borrower.globals[0] = record_value;
    record_borrower.initialized[0] = true;
    try std.testing.expectError(error.RuntimeFailed, record_borrower.execute(&.{}));
    try std.testing.expectEqual(@as(i64, 0), record_value.record.fields[0].int);
    try std.testing.expect(std.mem.indexOf(u8, record_borrower.failure.?.text(), "cannot modify a borrowed struct") != null);
}

test "aggregate VM argument binding reorders only already evaluated operands" {
    const Log = struct {
        values: [2]i64 = undefined,
        count: usize = 0,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.values[self.count] = args[0].int;
            self.count += 1;
            return .unit;
        }
    };
    const code = [_]I{
        ins(.constant, 0),                          .{ .op = .call, .a = 1, .b = 1 }, ins(.constant, 1),     .{ .op = .call, .a = 1, .b = 1 },
        .{ .op = .bind_arguments, .a = 0, .b = 2 }, ins(.make_list, 2),               ins(.store_global, 0), ins(.halt, 0),
    };
    var program = try testProgram(&.{
        .{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "mark", .code = &.{ ins(.load_local, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.print), .b = 1 }, ins(.pop, 0), ins(.load_local, 0), ins(.return_value, 0) }, .parameters = &.{.int}, .result = .int, .local_types = &.{.int} },
    }, &.{ .{ .int = 11 }, .{ .int = 22 } }, &.{"result"}, &.{.list});
    defer program.deinit();
    program.argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }};
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .call_builtin = Log.call } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(i64, &.{ 11, 22 }, &log.values);
    const result = machine.getGlobal("result").?.list.items();
    try std.testing.expectEqual(@as(i64, 22), result[0].int);
    try std.testing.expectEqual(@as(i64, 11), result[1].int);
    try std.testing.expectEqual(@as(usize, 2), log.count);
}

test "aggregate VM malformed struct fields and bindings fail with diagnostics" {
    const cases = [_]struct { code: []const I, message: []const u8 }{
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, ins(.constant, 2), .{ .op = .set_field, .a = 1, .b = 1 } }, .message = "expected int" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, .{ .op = .field, .a = 1, .b = 2 } }, .message = "invalid bytecode struct field slot" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 0, .b = 1 }, .{ .op = .field, .a = 2 } }, .message = "unknown field 'wrong'" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .make_record, .a = 1, .b = 1 } }, .message = "invalid bytecode struct index" },
        .{ .code = &.{ ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 1 } }, .message = "argument binding count" },
        .{ .code = &.{ ins(.constant, 0), ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 2 } }, .message = "argument binding slot" },
    };
    for (cases) |case| {
        var program = try testProgram(&.{.{ .name = "script", .code = case.code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .string = "count" }, .{ .string = "wrong" } }, &.{}, &.{});
        defer program.deinit();
        program.records = &.{.{ .name = "State", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
        program.argument_bindings = &.{.{ .slots = &.{ 0, 0 }, .parameter_count = 2 }};
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
    }
}

test "aggregate VM optional builtin omissions remain distinct from explicit unit" {
    const Probe = struct {
        seen: bool = false,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(builtin.Id.rgb, id);
            try std.testing.expectEqual(@as(usize, 4), args.len);
            try std.testing.expect(args[3] == .omitted);
            self.seen = true;
            return .{ .handle = .{ .kind = .color, .index = 0 } };
        }
    };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 0), ins(.constant, 0), ins(.constant, 1), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.rgb), .b = 4 }, ins(.pop, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .number = 0 }, .omitted }, &.{}, &.{});
    defer program.deinit();
    var probe: Probe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .call_builtin = Probe.call } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expect(probe.seen);
    program.constants = &.{ .{ .number = 0 }, .unit };
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "expected number") != null);
}

test "aggregate VM finite validation walks cyclic nested containers" {
    var dict: types.Dict = .{};
    defer dict.entries.deinit(std.testing.allocator);
    var fields = [_]Value{.{ .dict = &dict }};
    var record_value: types.Record = .{ .kind = Type.record(0), .fields = &fields };
    const list_values = [_]Value{ .{ .record = &record_value }, .{ .number = std.math.nan(f64) } };
    try dict.entries.put(std.testing.allocator, "cycle", .{ .dict = &dict });
    try dict.entries.put(std.testing.allocator, "list", types.listView(&list_values));
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.checkFinite(.{ .dict = &dict }));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
}

fn aggregateAllocationProbe(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    const graph = try machine.materialize(program.constants[0]);
    const dict = try machine.makeDict(&.{ .{ .string = "graph" }, graph });
    try machine.setIndex(dict, .{ .string = "self" }, dict);
    const record_value = try machine.makeRecord(0, &.{dict});
    try machine.setIndex(dict, .{ .string = "record" }, record_value);
    const copied = try machine.copyValue(dict);
    try std.testing.expect(try machine.valuesEqual(dict, copied));
    _ = try machine.coreBuiltin(.dict_keys, &.{dict});
    _ = try machine.coreBuiltin(.dict_contains, &.{ dict, .{ .string = "graph" } });
    _ = try machine.coreBuiltin(.dict_remove, &.{ copied, .{ .string = "record" } });
    try machine.push(dict);
    try machine.push(record_value);
    try machine.bindArguments(0, 2);
    try std.testing.expect(machine.stack.items[0] == .record);
    try std.testing.expect(machine.stack.items[1] == .dict);
}

test "aggregate VM every allocation failure releases mixed graphs and argument buffers" {
    var template_dict: types.Dict = .{};
    defer template_dict.entries.deinit(std.testing.allocator);
    try template_dict.entries.put(std.testing.allocator, "self", .{ .dict = &template_dict });
    const template_list = [_]Value{ .{ .dict = &template_dict }, .{ .dict = &template_dict } };
    try template_dict.entries.put(std.testing.allocator, "list", types.listView(&template_list));
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .dict = &template_dict }}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    program.argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }};
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aggregateAllocationProbe, .{&program});
}

test "aggregate VM internal coercion reuses validated execution ownership without allocations" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Node", .fields = &.{.{ .name = "data", .kind = .dict, .span = .{ .start = 0, .end = 0 } }} }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const list = try machine.makeList(&.{.{ .int = 1 }});
    const dict = try machine.makeDict(&.{ .{ .string = "items" }, list });
    const record_value = try machine.makeRecord(0, &.{dict});
    try machine.setIndex(dict, .{ .string = "node" }, record_value);
    try machine.appendList(list, record_value);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original = machine.gpa;
    machine.gpa = failing.allocator();
    defer machine.gpa = original;
    for (0..64) |_| {
        _ = try machine.coerce(record_value, Type.record(0));
        _ = try machine.coerce(list, .list);
        _ = try machine.coerce(dict, .dict);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "aggregate VM external validation ignores forged owners and template clones validate owned children" {
    const Invalid = enum { nonfinite, field_type, dictionary_key, native_handle };
    for ([_]Invalid{ .nonfinite, .field_type, .dictionary_key, .native_handle }) |invalid| for ([_]bool{ false, true }) |template| {
        var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
        defer program.deinit();
        program.records = &.{.{ .name = "Count", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        var forged: types.List.Owned = .{ .owner = machine.identity };
        defer forged.values.deinit(std.testing.allocator);
        var fields = [_]Value{.{ .string = "wrong" }};
        var record_value: types.Record = .{ .owner = machine.identity, .kind = Type.record(0), .fields = &fields };
        var dict: types.Dict = .{ .owner = machine.identity };
        defer dict.entries.deinit(std.testing.allocator);
        try dict.entries.put(std.testing.allocator, "\xff", .unit);
        const bad: Value = switch (invalid) {
            .nonfinite => .{ .number = std.math.nan(f64) },
            .field_type => .{ .record = &record_value },
            .dictionary_key => .{ .dict = &dict },
            .native_handle => .{ .handle = .{ .kind = .dict, .index = 0 } },
        };
        try forged.values.appendSlice(std.testing.allocator, &.{ bad, .{ .list = .{ .owned = &forged } } });
        const value: Value = .{ .list = .{ .owned = &forged } };
        if (template) {
            try std.testing.expectError(error.RuntimeFailed, machine.materialize(types.listView(&.{value})));
        } else try std.testing.expectError(error.RuntimeFailed, machine.checkFiniteExternal(value));
        const expected = switch (invalid) {
            .nonfinite => "non-finite",
            .field_type => "expects int",
            .dictionary_key => "valid UTF-8",
            .native_handle => "invalid native handle",
        };
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), expected) != null);
    };
}

test "aggregate VM borrowed nodes retain complete finite and nominal field validation" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    program.records = &.{.{ .name = "Count", .fields = &.{.{ .name = "count", .kind = .int, .span = .{ .start = 0, .end = 0 } }} }};
    for ([_]bool{ false, true }) |record_case| {
        var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer owner.deinit();
        var borrower = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer borrower.deinit();
        const value = if (record_case) try owner.makeRecord(0, &.{.{ .int = 1 }}) else try owner.makeList(&.{.{ .int = 1 }});
        try borrower.checkFinite(value);
        // Simulate changed foreign storage to prove that a borrowed owner is
        // never cached. Production task parents stay frozen until join.
        if (record_case) value.record.fields[0] = .{ .string = "wrong" } else value.list.owned.values.items[0] = .{ .number = std.math.nan(f64) };
        try std.testing.expectError(error.RuntimeFailed, borrower.checkFinite(value));
        try std.testing.expect(std.mem.indexOf(u8, borrower.failure.?.text(), if (record_case) "expects int" else "non-finite") != null);
    }
}

test "aggregate VM every host return path fully checks nested values despite a matching owner" {
    const Probe = struct {
        owner: *const types.Ownership,
        calls: usize = 0,
        fn bad(self: *@This(), allocator: std.mem.Allocator) !Value {
            self.calls += 1;
            const list = try allocator.create(types.List.Owned);
            list.* = .{ .owner = self.owner };
            try list.values.append(allocator, .{ .number = std.math.nan(f64) });
            return .{ .list = .{ .owned = list } };
        }
        fn from(context: ?*anyopaque) *@This() {
            return @ptrCast(@alignCast(context.?));
        }
        fn call(context: ?*anyopaque, allocator: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            return from(context).bad(allocator);
        }
        fn field(context: ?*anyopaque, allocator: std.mem.Allocator, _: Value, _: []const u8) !Value {
            return from(context).bad(allocator);
        }
        fn binary(context: ?*anyopaque, allocator: std.mem.Allocator, _: bytecode.Op, _: Value, _: Value) !Value {
            return from(context).bad(allocator);
        }
        fn typst(context: ?*anyopaque, allocator: std.mem.Allocator, _: TypstRequest) !Value {
            return from(context).bad(allocator);
        }
        fn batch(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const TypstRequest, values: []Value, _: *TypstBatchDiagnostic) !void {
            for (values) |*value| value.* = try from(context).bad(allocator);
        }
    };
    const cases = [_]struct { code: []const I, batch: bool = false }{
        .{ .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.bounds), .b = 1 }, ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.constant, 0), ins(.field, 1), ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.constant, 0), ins(.constant, 0), ins(.add, 0), ins(.pop, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.typst, 1), ins(.store_global, 0), ins(.halt, 0) } },
        .{ .code = &.{ ins(.typst, 1), ins(.store_global, 0), ins(.halt, 0) }, .batch = true },
    };
    for (cases) |case| {
        var program = try testProgram(&.{.{ .name = "script", .code = case.code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .handle = .{ .kind = .variable, .index = 0 } }, .{ .string = "sample" } }, &.{"text"}, &.{.text});
        defer program.deinit();
        var probe: Probe = .{ .owner = undefined };
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .call_builtin = Probe.call, .field = Probe.field, .binary = Probe.binary, .typst = Probe.typst, .typst_batch = if (case.batch) Probe.batch else null } }, .{});
        defer machine.deinit();
        probe.owner = machine.identity;
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "non-finite") != null);
    }
}

test "read-only templates materialize independently before script mutation" {
    const constants = [_]Value{ types.listView(&.{.{ .int = 1 }}), .{ .int = 2 } };
    const code = [_]I{
        ins(.constant, 0),    ins(.store_global, 0), ins(.constant, 0),    ins(.store_global, 1),
        ins(.load_global, 0), ins(.constant, 1),     ins(.list_append, 0), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "first", "second" }, &.{ .list, .list });
    defer program.deinit();
    for (0..2) |_| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 2), types.sequence(machine.getGlobal("first").?).?.len);
        try std.testing.expectEqual(@as(usize, 1), types.sequence(machine.getGlobal("second").?).?.len);
        try std.testing.expect(machine.getGlobal("first").?.list.owned != machine.getGlobal("second").?.list.owned);
        try std.testing.expectEqual(@as(usize, 1), constants[0].list.items().len);
        try std.testing.expectEqual(@as(i64, 1), constants[0].list.items()[0].int);
    }
}

test "duplicating a template preserves one evaluated list identity" {
    const template: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{ types.listView(template), .{ .int = 2 } };
    const code = [_]I{
        ins(.constant, 0),    ins(.duplicate, 0), ins(.store_global, 0), ins(.store_global, 1),
        ins(.load_global, 0), ins(.constant, 1),  ins(.list_append, 0),  ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "first", "second" }, &.{ .list, .list });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const first = machine.getGlobal("first").?.list.owned;
    const second = machine.getGlobal("second").?.list.owned;
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), second.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), template.len);
}

test "variadic calls pack and coerce every remaining argument into a fresh list" {
    var code: std.ArrayList(I) = .empty;
    defer code.deinit(std.testing.allocator);
    try code.append(std.testing.allocator, ins(.constant, 0));
    for (0..32) |_| try code.append(std.testing.allocator, ins(.constant, 1));
    try code.appendSlice(std.testing.allocator, &.{
        .{ .op = .call, .a = 1, .b = 33 }, ins(.store_global, 0),
        ins(.constant, 0),                 .{ .op = .call, .a = 1, .b = 1 },
        ins(.store_global, 1),             ins(.constant, 0),
        .{ .op = .call, .a = 1, .b = 1 },  ins(.store_global, 2),
        ins(.halt, 0),
    });
    var program = try testProgram(&.{
        .{ .name = "script", .code = code.items, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "tail", .code = &.{ ins(.load_local, 1), ins(.return_value, 0) }, .parameters = &.{ .number, .list }, .variadic = .number, .result = .list, .local_types = &.{ .number, .list } },
    }, &.{ .{ .int = 1 }, .{ .int = 2 } }, &.{ "many", "empty", "another" }, &.{ .list, .list, .list });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const many = machine.getGlobal("many").?.list.owned;
    try std.testing.expectEqual(@as(usize, 32), many.values.items.len);
    for (many.values.items) |item| try std.testing.expectEqualDeep(Value{ .number = 2 }, item);
    const empty = machine.getGlobal("empty").?.list.owned;
    const another = machine.getGlobal("another").?.list.owned;
    try std.testing.expectEqual(@as(usize, 0), empty.values.items.len);
    try std.testing.expect(empty != another);
    try std.testing.expectEqual(@as(i64, 2), program.constants[1].int);
}

test "malformed variadic layouts return diagnostics without crossing local bounds" {
    const caller = [_]I{ .{ .op = .call, .a = 1, .b = 0 }, ins(.halt, 0) };
    for ([_][]const Type{ &.{}, &.{.number} }) |parameters| {
        var program = try testProgram(&.{
            .{ .name = "script", .code = &caller, .parameters = &.{}, .result = .unit, .local_types = &.{} },
            .{ .name = "invalid", .code = &.{ins(.halt, 0)}, .parameters = parameters, .variadic = .number, .result = .unit, .local_types = parameters },
        }, &.{}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(machine.failure != null);
    }
}

test "appended nested templates retain child aliases within each isolated execution" {
    const child: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{
        types.listView(&.{ types.listView(child), types.listView(child) }),
        .{ .int = 0 },
        .{ .int = 2 },
    };
    const code = [_]I{
        ins(.make_list, 0),    ins(.store_global, 0), ins(.load_global, 0), ins(.constant, 0),
        ins(.list_append, 0),  ins(.load_global, 0),  ins(.constant, 1),    ins(.index, 0),
        ins(.store_global, 1), ins(.load_global, 1),  ins(.constant, 2),    ins(.list_append, 0),
        ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "rows", "row" }, &.{ .list, .list });
    defer program.deinit();
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    for ([_]*Machine{ &first, &second }) |machine| {
        _ = try machine.execute(&.{});
        const rows = machine.getGlobal("rows").?.list.owned.values.items;
        const row = machine.getGlobal("row").?.list.owned;
        try std.testing.expect(rows[0] == .list and rows[1] == .list);
        try std.testing.expectEqual(row, rows[0].list.owned);
        try std.testing.expectEqual(row, rows[1].list.owned);
        try std.testing.expectEqual(@as(usize, 2), row.values.items.len);
        try std.testing.expectEqual(@as(i64, 2), row.values.items[1].int);
    }
    try std.testing.expect(first.getGlobal("row").?.list.owned != second.getGlobal("row").?.list.owned);
    try std.testing.expectEqual(@as(usize, 2), first.getGlobal("row").?.list.owned.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), child.len);
    try std.testing.expectEqual(@as(i64, 1), child[0].int);
}

test "task results materialize templates like the coordinating store" {
    const constants = [_]Value{types.listView(&.{.{ .int = 1 }})};
    const code = [_]I{ ins(.constant, 0), ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"value"}, &.{.list});
    defer program.deinit();
    var worker = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer worker.deinit();
    const result = try worker.executeTask(.{ .function = 0, .start = 0, .end = 1, .global = 0, .reads = &.{} });
    try std.testing.expect(result == .list);
    try std.testing.expectEqual(worker.identity, result.list.owned.owner.?);
    try worker.appendList(result, .{ .int = 2 });
    var serial = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer serial.deinit();
    _ = try serial.execute(&.{});
    try std.testing.expectEqual(@as(usize, 2), result.list.owned.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), serial.getGlobal("value").?.list.owned.values.items.len);
    try std.testing.expect(result.list.owned != serial.getGlobal("value").?.list.owned);
    try std.testing.expectEqual(@as(usize, 1), constants[0].list.items().len);
}

test "dimensional bytecode parameters vectors and ratios retain native values" {
    const constants = [_]Value{
        .{ .quantity = try units.applyUnit(2, .cm) },
        .{ .quantity = try units.applyUnit(3, .mm) },
        .{ .int = 0 },
        .{ .string = "y" },
    };
    const instructions = [_]I{
        ins(.constant, 0),     ins(.constant, 1), ins(.add, 0),       ins(.store_global, 0),
        ins(.constant, 2),     ins(.constant, 0), ins(.make_pair, 0), ins(.field, 3),
        ins(.store_global, 1), ins(.constant, 0), ins(.constant, 1),  ins(.divide, 0),
        ins(.store_global, 2), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &instructions, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{ "length", "coordinate", "ratio", "spin" }, &.{ .length, .length, .number, .angle });
    defer program.deinit();
    program.parameters = &.{.{ .name = "spin", .kind = .angle, .default = null, .global = 3, .span = .{ .start = 0, .end = 4 } }};
    program.readonly_globals = &.{ false, false, false, true };
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{.{ .name = "spin", .value = "2 pi rad" }});
    try std.testing.expectEqual(@as(f64, 23), machine.getGlobal("length").?.quantity.value);
    try std.testing.expectEqual(@as(f64, 20), machine.getGlobal("coordinate").?.quantity.value);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 3.0), machine.getGlobal("ratio").?.number, 1e-12);
    try std.testing.expectEqual(try units.applyUnit(360, .deg), machine.getGlobal("spin").?.quantity);
    var wrong = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.RuntimeFailed, wrong.execute(&.{.{ .name = "spin", .value = "1cm" }}));
    try std.testing.expect(std.mem.indexOf(u8, wrong.failure.?.diagnostic.text(), "angle") != null);
}

test "dimensionless quantity inputs normalize safely in ranges" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const normalized = try machine.initializeRange(.{ .quantity = .{ .value = 0 } }, .{ .int = 2 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(f64, 0), normalized[0].number);
    try std.testing.expectEqual(@as(f64, 1), normalized[2].number);
    try std.testing.expect(try machine.rangeTest(normalized[0], normalized[1], normalized[2]));
}

test "named exports read final bindings while ordinary assignments keep their values" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\export late
        \\export named:=4
        \\export saved:=named
        \\named=9
        \\late:=named+1
        \\alias:=named
        \\export alias
    , "export-values.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const expected_names = [_][]const u8{ "late", "named", "saved", "alias" };
    const expected_values = [_]i64{ 10, 9, 4, 9 };
    try std.testing.expectEqual(expected_names.len, program.exports.len);
    for (expected_names, expected_values, program.exports) |name, value, exported| {
        try std.testing.expectEqualStrings(name, exported.name);
        try std.testing.expectEqual(value, machine.getGlobal(program.global_names[exported.target.global]).?.int);
    }
}

test "exported values retain initialization when reassignment is not executed" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\export retained:=0
        \\if false then
        \\  retained=1%0
        \\end
        \\fn produced()->int; return 12; end
        \\export produced_value:=produced()
    , "retained-export.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("retained").?.int);
    try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("produced_value").?.int);
}

test "inferred script parameters retain typed overrides and exported parameter values" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\param folder="."
        \\param count=3
        \\param scale=1.5
        \\param enabled=true
        \\export folder
        \\export count
        \\calculated:=count*scale
    , "inferred-overrides.huak", .{}, &diagnostic);
    defer program.deinit();
    var defaults = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer defaults.deinit();
    _ = try defaults.execute(&.{});
    try std.testing.expectEqualStrings(".", defaults.getGlobal("folder").?.string);
    try std.testing.expectEqual(@as(i64, 3), defaults.getGlobal("count").?.int);
    var overrides = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer overrides.deinit();
    _ = try overrides.execute(&.{ .{ .name = "folder", .value = "out dir" }, .{ .name = "count", .value = "7" }, .{ .name = "scale", .value = "2.5" }, .{ .name = "enabled", .value = "false" } });
    try std.testing.expectEqualStrings("out dir", overrides.getGlobal("folder").?.string);
    try std.testing.expectEqual(@as(i64, 7), overrides.getGlobal("count").?.int);
    try std.testing.expectEqual(@as(f64, 17.5), overrides.getGlobal("calculated").?.number);
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{.{ .name = "count", .value = "7.5" }}));
    try std.testing.expectEqual(@as(u64, 0), invalid.steps);
}

test "bytecode calls use separate locals and preserve recursive caller operands" {
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call, .a = 1, .b = 1 }, ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "factorial", .code = &.{
            ins(.load_local, 0),   ins(.constant, 1),     ins(.less_equal, 0),              ins(.jump_if_false, 6),
            ins(.constant, 1),     ins(.return_value, 0), ins(.load_local, 0),              ins(.load_local, 0),
            ins(.constant, 1),     ins(.subtract, 0),     .{ .op = .call, .a = 1, .b = 1 }, ins(.multiply, 0),
            ins(.return_value, 0),
        }, .parameters = &.{.int}, .result = .int, .local_types = &.{.int} },
    }, &.{ .{ .int = 6 }, .{ .int = 1 } }, &.{"answer"}, &.{.int});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(usize, 0), machine.locals.items.len);
    try std.testing.expectEqual(@as(usize, 0), machine.frames.items.len);
}

test "one program can run with distinct readonly parameter values" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.load_global, 0), ins(.constant, 0), ins(.multiply, 0), ins(.store_global, 1), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .int = 2 }}, &.{ "count", "answer" }, &.{ .int, .int });
    defer program.deinit();
    program.parameters = &.{.{ .name = "count", .kind = .int, .default = .{ .int = 5 }, .global = 0, .span = .{ .start = 12, .end = 17 } }};
    const readonly = try program.arena.allocator().dupe(bool, &.{ true, false });
    program.readonly_globals = readonly;
    var first = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer first.deinit();
    try first.prepareParameters(&.{.{ .name = "count", .value = "7" }});
    try std.testing.expectEqual(@as(i64, 7), first.getGlobal("count").?.int);
    _ = try first.execute(&.{});
    var second = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer second.deinit();
    _ = try second.execute(&.{});
    try std.testing.expectEqual(@as(i64, 14), first.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 10), second.getGlobal("answer").?.int);
    try std.testing.expectError(error.RuntimeFailed, first.execute(&.{}));
}

test "parameters reject unknown duplicate missing and invalid values before execution" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ins(.halt, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{"count"}, &.{.int});
    defer program.deinit();
    program.parameters = &.{.{ .name = "count", .kind = .int, .default = null, .global = 0, .span = .{ .start = 8, .end = 13 } }};
    program.readonly_globals = &.{true};
    const cases = [_][]const Override{
        &.{.{ .name = "other", .value = "1" }},
        &.{ .{ .name = "count", .value = "1" }, .{ .name = "count", .value = "2" } },
        &.{},
        &.{.{ .name = "count", .value = "2.5" }},
    };
    for (cases) |overrides| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.prepareParameters(overrides));
        try std.testing.expectEqual(@as(u64, 0), machine.steps);
        try std.testing.expect(machine.failure != null);
    }
    program.functions = &.{.{ .name = "script", .code = &.{ ins(.constant, 0), ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    program.constants = &.{.{ .int = 3 }};
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{.{ .name = "count", .value = "1" }}));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "read-only") != null);
}

test "arithmetic lists pairs and finite errors execute without a native library" {
    var program = try testProgram(&.{.{ .name = "script", .code = &.{
        ins(.constant, 0), ins(.constant, 1), ins(.make_pair, 0), ins(.constant, 1), ins(.multiply, 0), ins(.store_global, 0),
        ins(.constant, 2), ins(.constant, 1), ins(.make_list, 2), ins(.constant, 3), ins(.index, 0),    ins(.store_global, 1),
        ins(.halt, 0),
    }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 3 }, .{ .int = 2 }, .{ .string = "first" }, .{ .int = 0 } }, &.{ "point", "first" }, &.{ .pair, .string });
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const point = machine.getGlobal("point").?.pair;
    try std.testing.expectEqual(@as(f64, 6), point.x);
    try std.testing.expectEqual(@as(f64, 4), point.y);
    try std.testing.expectEqualStrings("first", machine.getGlobal("first").?.string);
    try std.testing.expectError(error.RuntimeFailed, machine.arithmetic(.multiply, .{ .number = 1e308 }, .{ .number = 1e308 }));
}

test "instruction and recursion limits report positioned call stacks" {
    const call_span: Span = .{ .start = 25, .end = 31 };
    var program = try testProgram(&.{.{ .name = "recurse", .code = &.{ .{ .op = .call, .a = 0, .span = call_span }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{ .call_depth = 8 });
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(usize, 8), machine.failure.?.trace.len);
    try std.testing.expectEqual(call_span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings("recurse", machine.failure.?.trace[0].function);
    program.functions = &.{.{ .name = "loop", .code = &.{ins(.jump, 0)}, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    var loop = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = 100 });
    defer loop.deinit();
    try std.testing.expectError(error.RuntimeFailed, loop.execute(&.{}));
    try std.testing.expectEqual(@as(u64, 100), loop.steps);
}

test "range progression terminates after representable endpoints without overflow" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const max: Value = .{ .int = std.math.maxInt(i64) };
    const min: Value = .{ .int = std.math.minInt(i64) };
    try std.testing.expect(!(try machine.rangeAdvance(max, max, .{ .int = 1 })).more);
    try std.testing.expect(!(try machine.rangeAdvance(.{ .int = std.math.maxInt(i64) - 1 }, max, .{ .int = 2 })).more);
    try std.testing.expect(!(try machine.rangeAdvance(.{ .int = std.math.minInt(i64) + 1 }, min, .{ .int = -2 })).more);
    try std.testing.expectEqual(@as(i64, 2), (try machine.rangeAdvance(.{ .int = 3 }, .{ .int = 0 }, .{ .int = -1 })).value.int);
    try std.testing.expectError(error.RuntimeFailed, machine.rangeTest(.{ .int = 0 }, .{ .int = 1 }, .{ .int = 0 }));
}

test "list slices use inclusive range progression in both directions" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const values = types.listView(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 }, .{ .int = 5 } });
    const cases = [_]struct { start: i64, stop: ?i64, step: i64, expected: []const i64 }{
        .{ .start = 1, .stop = 3, .step = 1, .expected = &.{ 1, 2, 3 } },
        .{ .start = 0, .stop = 5, .step = 2, .expected = &.{ 0, 2, 4 } },
        .{ .start = 5, .stop = 0, .step = -2, .expected = &.{ 5, 3, 1 } },
        .{ .start = 3, .stop = 3, .step = std.math.minInt(i64), .expected = &.{3} },
        .{ .start = 2, .stop = std.math.maxInt(i64), .step = std.math.maxInt(i64), .expected = &.{2} },
        .{ .start = 4, .stop = 1, .step = 1, .expected = &.{} },
        .{ .start = 2, .stop = 4, .step = -1, .expected = &.{} },
        .{ .start = 3, .stop = null, .step = 1, .expected = &.{ 3, 4, 5 } },
        .{ .start = 6, .stop = null, .step = 1, .expected = &.{} },
        .{ .start = 0, .stop = 9, .step = 10, .expected = &.{0} },
    };
    for (cases) |case| {
        const result = try machine.sliceList(values, .{ .int = case.start }, if (case.stop) |stop| .{ .int = stop } else null, .{ .int = case.step });
        const items = types.sequence(result).?;
        try std.testing.expectEqual(case.expected.len, items.len);
        for (items, case.expected) |item, expected| try std.testing.expectEqual(expected, item.int);
    }
    const empty = try machine.sliceList(types.listView(&.{}), .{ .int = 0 }, null, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 0), empty.list.items().len);
    const empty_range = try machine.sliceList(types.listView(&.{}), .{ .int = 0 }, .{ .int = -1 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 0), empty_range.list.items().len);
    try std.testing.expect(empty.list.owned != empty_range.list.owned);
}

test "list slices reject invalid selected indices and validate empty range operands" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    const values = types.listView(&.{ .{ .int = 10 }, .{ .int = 20 } });
    const cases = [_]struct { start: Value, stop: ?Value, step: Value, message: []const u8 }{
        .{ .start = .{ .int = 1 }, .stop = .{ .int = 0 }, .step = .{ .int = 0 }, .message = "range step must not be zero" },
        .{ .start = .{ .int = -1 }, .stop = .{ .int = 0 }, .step = .{ .int = 1 }, .message = "index -1 is outside length 2" },
        .{ .start = .{ .int = 0 }, .stop = .{ .int = 2 }, .step = .{ .int = 1 }, .message = "index 2 is outside length 2" },
        .{ .start = .{ .int = -1 }, .stop = null, .step = .{ .int = 1 }, .message = "slice start -1 is outside length 2" },
        .{ .start = .{ .int = 3 }, .stop = null, .step = .{ .int = 1 }, .message = "slice start 3 is outside length 2" },
        .{ .start = .{ .int = 0 }, .stop = .unit, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .boolean = true }, .stop = .{ .int = 0 }, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .int = 1 }, .stop = .{ .number = 0 }, .step = .{ .int = 1 }, .message = "bounds and step must be int" },
        .{ .start = .{ .int = 1 }, .stop = .{ .int = 0 }, .step = .{ .number = 1 }, .message = "bounds and step must be int" },
    };
    for (cases) |case| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.sliceList(values, case.start, case.stop, case.step));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
    }
    var wrong_object = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer wrong_object.deinit();
    try std.testing.expectError(error.RuntimeFailed, wrong_object.sliceList(.{ .int = 1 }, .{ .int = 0 }, null, .{ .int = 1 }));
    try std.testing.expectEqualStrings("slicing requires a list", wrong_object.failure.?.text());
}

test "explicit dynamically void slice endpoints are not treated as omitted" {
    const compiler = @import("compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\fn missing()->any
            \\    return
            \\end
            \\xs:=[1,2]
            \\part:=xs[0:missing()]
        , "void-slice-endpoint.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqualStrings("list slice bounds and step must be int", machine.failure.?.text());
        try std.testing.expect(machine.getGlobal("part") == null);
    }
}

test "slice endpoint modes reject malformed bytecode before interpreting a sentinel" {
    const constants = [_]Value{ types.listView(&.{.{ .int = 1 }}), .{ .int = 0 }, .{ .int = 1 } };
    const codes = [_][]const I{
        &.{ins(.slice, 2)},
        &.{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 1), ins(.constant, 2), ins(.slice, 1) },
    };
    for (codes) |code| {
        var program = try testProgram(&.{.{ .name = "script", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.startsWith(u8, machine.failure.?.text(), "invalid bytecode"));
    }
}

test "list slices create shallow containers and preserve selected template aliases and cycles" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    const child: []const Value = &.{.{ .int = 1 }};
    const source_view = types.listView(&.{ types.listView(child), types.listView(child) });
    const source_owned = try machine.materialize(source_view);
    const shallow = try machine.sliceList(source_owned, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expect(shallow.list.owned != source_owned.list.owned);
    try machine.appendList(shallow, .{ .int = 3 });
    try std.testing.expectEqual(@as(usize, 2), source_owned.list.items().len);
    try std.testing.expectEqual(@as(usize, 3), shallow.list.items().len);
    try machine.appendList(shallow.list.items()[0], .{ .int = 2 });
    for (source_owned.list.items()) |row| try std.testing.expectEqual(@as(usize, 2), row.list.items().len);

    const selected = try machine.sliceList(source_view, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expect(selected.list.items()[0].list.owned == selected.list.items()[1].list.owned);
    try machine.appendList(selected.list.items()[0], .{ .int = 4 });
    try std.testing.expectEqual(@as(usize, 2), selected.list.items()[1].list.items().len);
    try std.testing.expectEqual(@as(usize, 1), child.len);
    const another = try machine.sliceList(source_view, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 });
    try std.testing.expectEqual(@as(usize, 1), another.list.items()[0].list.items().len);

    var cyclic: [1]Value = undefined;
    cyclic[0] = types.listView(&cyclic);
    const cycle_slice = try machine.sliceList(types.listView(&cyclic), .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 });
    const cycle = cycle_slice.list.items()[0];
    try std.testing.expect(cycle.list.owned != cycle_slice.list.owned);
    try std.testing.expect(cycle.list.items()[0].list.owned == cycle.list.owned);
}

test "worker slices own their container while nested borrowed lists stay protected" {
    var program = try testProgram(&.{}, &.{}, &.{}, &.{});
    defer program.deinit();
    var coordinator = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer coordinator.deinit();
    var worker = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer worker.deinit();
    const child = try coordinator.makeList(&.{.{ .int = 1 }});
    const input = try coordinator.makeList(&.{child});
    const result = try worker.sliceList(input, .{ .int = 0 }, null, .{ .int = 1 });
    try std.testing.expectEqual(worker.identity, result.list.owned.owner.?);
    try std.testing.expectEqual(coordinator.identity, result.list.items()[0].list.owned.owner);
    try worker.appendList(result, .{ .int = 2 });
    try std.testing.expectEqual(@as(usize, 1), input.list.items().len);
    try std.testing.expectError(error.RuntimeFailed, worker.appendList(result.list.items()[0], .{ .int = 3 }));
    try std.testing.expectEqual(@as(usize, 1), child.list.items().len);
}

test "slice element work respects the execution budget at the slice source position" {
    const span: Span = .{ .start = 20, .end = 26 };
    const constants = [_]Value{ types.listView(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } }), .{ .int = 0 }, .{ .int = 3 }, .{ .int = 1 } };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 2), ins(.constant, 3), .{ .op = .slice, .span = span }, ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"result"}, &.{.list});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = 7 });
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(u64, 7), machine.steps);
    try std.testing.expectEqual(span, machine.failure.?.diagnostic.span);
    try std.testing.expect(machine.getGlobal("result") == null);
    var complete = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer complete.deinit();
    _ = try complete.execute(&.{});
    try std.testing.expectEqual(@as(u64, code.len + 4), complete.steps);
    try std.testing.expectEqual(@as(usize, 4), complete.getGlobal("result").?.list.items().len);
}

fn sliceAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const result = machine.getGlobal("result").?;
    try std.testing.expectEqual(@as(usize, 2), result.list.items().len);
    try std.testing.expect(result.list.items()[0].list.owned == result.list.items()[1].list.owned);
}

test "slice allocation failures free partial results and template alias tracking" {
    const child: []const Value = &.{.{ .int = 1 }};
    const constants = [_]Value{ types.listView(&.{ types.listView(child), types.listView(child) }), .{ .int = 0 }, .{ .int = 1 }, .unit };
    const code = [_]I{ ins(.constant, 0), ins(.constant, 1), ins(.constant, 3), ins(.constant, 2), ins(.slice, 1), ins(.store_global, 0), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &constants, &.{"result"}, &.{.list});
    defer program.deinit();
    try sliceAllocationExercise(std.testing.allocator, &program);
    // Backing resize can replace an allocation depending on heap placement.
    // Keep successful resizing covered above, and enumerate every allocation
    // failure with the same stable no-resize strategy as list append/builders.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), sliceAllocationExercise, .{&program});
    try std.testing.expectEqual(@as(usize, 1), child.len);
}

const FailingHost = struct {
    fn call(_: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) anyerror!Value {
        return error.UpstreamDiagnostic;
    }
    fn message(_: ?*anyopaque) []const u8 {
        return "failed Typst layout: unknown variable α in content";
    }
};
test "native errors preserve the upstream diagnostic and source position" {
    const failure_span: Span = .{ .start = 42, .end = 55 };
    var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.print), .b = 1, .span = failure_span }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{.{ .string = "x" }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{ .vtable = &.{ .call_builtin = FailingHost.call, .error_message = FailingHost.message } }, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(failure_span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings(FailingHost.message(null), machine.failure.?.native_message);
}

test "compiler output runs recursive functions loops short circuits and zero based lists" {
    const compiler = @import("compiler.zig");
    const input =
        \\param n:int=6
        \\answer:=fact(n)
        \\fn fact(x:int)->int
        \\    if x<=1 then
        \\        return 1
        \\    end
        \\    return x*fact(x-1)
        \\end
        \\total:=0
        \\for i in 1:10 do
        \\    if i==3 then; continue; end
        \\    if i==7 then; break; end
        \\    total=total+i
        \\    i=999
        \\end
        \\j:=0
        \\while j<3 do
        \\    j=j+1
        \\end
        \\skipped:=false and (1/0>0)
        \\taken:=true or (1/0>0)
        \\list:=[1,2,3]
        \\last:=list[2]
        \\point:=(2,3)*2
        \\px:=point.x
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, input, "control.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 18), machine.getGlobal("total").?.int);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("j").?.int);
    try std.testing.expect(!machine.getGlobal("skipped").?.boolean);
    try std.testing.expect(machine.getGlobal("taken").?.boolean);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("last").?.int);
    try std.testing.expectEqual(@as(f64, 4), machine.getGlobal("px").?.number);
}

test "inline then and do blocks match multiline execution with and without optimization" {
    const compiler = @import("compiler.zig");
    const inline_source = "selected:=0; total:=0; for i in 1:3 do j:=0; while j<2 do j=j+1; if true then j:=99; j=100 end; if i==1 then total=total+1 elseif i==2 then total=total+10 else total=total+100 end end end; if false and (1/0>0) then selected=0 elseif true or (1/0>0) then selected=total+1 else selected=1%0 end";
    const multiline_source =
        \\selected:=0; total:=0
        \\for i in 1:3 do
        \\    j:=0
        \\    while j<2 do
        \\        j=j+1
        \\        if true then j:=99; j=100 end
        \\        if i==1 then
        \\            total=total+1
        \\        elseif i==2 then
        \\            total=total+10
        \\        else
        \\            total=total+100
        \\        end
        \\    end
        \\end
        \\if false and (1/0>0) then
        \\    selected=0
        \\elseif true or (1/0>0) then
        \\    selected=total+1
        \\else
        \\    selected=1%0
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        for ([_][]const u8{ inline_source, multiline_source }) |input| {
            var diagnostic: ?source.Diagnostic = null;
            var program = try compiler.compile(std.testing.allocator, input, "block-boundaries.huak", .{ .optimize = optimize }, &diagnostic);
            defer program.deinit();
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            try std.testing.expectEqual(@as(i64, 222), machine.getGlobal("total").?.int);
            try std.testing.expectEqual(@as(i64, 223), machine.getGlobal("selected").?.int);
            try std.testing.expect(machine.getGlobal("i") == null and machine.getGlobal("j") == null);
        }
    }
}

fn listAppendAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const before = types.sequence(machine.getGlobal("before").?).?;
    const after = types.sequence(machine.getGlobal("after").?).?;
    try std.testing.expectEqual(@as(usize, 12), before.len);
    try std.testing.expectEqual(@as(usize, 26), after.len);
    try std.testing.expectEqual(@as(i64, 26), machine.getGlobal("alias_count").?.int);
    try std.testing.expectEqualSlices(u8, "tail", after[25].string);
    try std.testing.expectEqual(@as(usize, 2), types.sequence(after[24]).?.len);
    for (after[0..12], after[12..24]) |first, second| try std.testing.expectEqualDeep(first, second);
    const source_values = types.sequence(machine.getGlobal("source").?).?;
    try std.testing.expectEqual(@as(usize, 2), source_values.len);
    try std.testing.expectEqual(@as(i64, 3), source_values[0].int);
}

test "list append preserves aliases snapshots and self append through allocation failures" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\values:=[1,2]
        \\other:=[3,4]
        \\alias:=values
        \\for i in 1:5 do alias+=other end
        \\before:=[];before+=values
        \\values+=alias
        \\values+=[[7,8]]
        \\values+="tail"
        \\source:=[];source+=other
        \\after:=[];after+=values
        \\alias_count:=len(alias)
    , "list-append-allocation.huak", .{}, &diagnostic);
    defer program.deinit();
    try listAppendAllocationExercise(std.testing.allocator, &program);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), listAppendAllocationExercise, .{&program});
}

test "list append checks dynamic targets before mutating a collection" {
    const compiler = @import("compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, "values:any:=42;values+=1", "invalid-list-append.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "expected a list") != null);
        try std.testing.expectEqual(@as(i64, 42), machine.getGlobal("values").?.int);
    }
}

fn listItemsAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const items = machine.getGlobal("items").?.list.owned;
    const nested = machine.getGlobal("nested").?.list.owned;
    try std.testing.expectEqual(@as(usize, 5), items.values.items.len);
    try std.testing.expect(items == machine.getGlobal("alias").?.list.owned);
    try std.testing.expectEqual(@as(i64, 1), items.values.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), items.values.items[1].int);
    try std.testing.expect(items.values.items[2].list.owned == nested);
    try std.testing.expect(items.values.items[3].record.fields[0].list.owned == nested);
    try std.testing.expect(items.values.items[4].list.owned == items);
    try std.testing.expectEqual(@as(usize, 2), nested.values.items.len);
}

test "list literal append retains empty multi-item nested any and self aliases through allocation failures" {
    const compiler = @import("compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\struct Entry
            \\    value:any
            \\end
            \\fn insert(dst:list, value:any) dst += [value] end
            \\items:=[]
            \\items+=[]
            \\items+=[1,2]
            \\nested:=[9]
            \\insert(items,nested)
            \\items+=[Entry(value:nested)]
            \\alias:=items
            \\items+=[items]
            \\nested+=10
        , "list-items.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var combined: usize = 0;
        for (program.functions) |function| for (function.code) |instruction| {
            if (instruction.op == .list_append_items) combined += 1;
        };
        try std.testing.expect(if (optimize) combined != 0 else combined == 0);
        try listItemsAllocationExercise(std.testing.allocator, &program);
        var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
        try std.testing.checkAllAllocationFailures(stable.allocator(), listItemsAllocationExercise, .{&program});
    }
}

test "compiled literal append handles branches loops and grouped span fallback" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\items:=[]
        \\for i in 1:4 do
        \\    if i > 1 then items += [i] end
        \\end
        \\items += ([5])
    , "literal-append-spans.huak", .{}, &diagnostic);
    defer program.deinit();
    var combined: usize = 0;
    var separate: usize = 0;
    for (program.functions) |function| for (function.code) |instruction| {
        if (instruction.op == .list_append_items) {
            combined += 1;
            try std.testing.expectEqualStrings("[i]", program.source_text[instruction.b..instruction.span.end]);
        }
        if (instruction.op == .list_append) separate += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), combined);
    try std.testing.expectEqual(@as(usize, 1), separate);
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const items = machine.getGlobal("items").?.list.items();
    try std.testing.expectEqual(@as(usize, 4), items.len);
    for (items, 2..) |item, expected| try std.testing.expectEqual(@as(i64, @intCast(expected)), item.int);
}

test "literal append uses one instruction with identical scheduled and serial budget prefixes" {
    const Scheduler = struct {
        fn unchanged(_: ?*anyopaque, _: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            return false;
        }
    };
    const code = [_]I{
        ins(.make_list, 0),                                                                 ins(.store_global, 0), ins(.load_global, 0), ins(.constant, 0), ins(.constant, 1),
        .{ .op = .list_append_items, .a = 2, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .int = 1 }, .{ .int = 2 } }, &.{"items"}, &.{.list});
    defer program.deinit();
    program.task_regions = &.{.{ .function = 0, .start = 5, .end = 6, .tasks = &.{} }};
    for (0..code.len + 1) |limit| {
        var serial = try Machine.init(std.testing.allocator, &program, .{}, .{ .instructions = limit });
        defer serial.deinit();
        var scheduled = try Machine.init(std.testing.allocator, &program, .{ .tasks = .{ .vtable = &.{ .dispatch = Scheduler.unchanged } } }, .{ .instructions = limit });
        defer scheduled.deinit();
        if (serial.execute(&.{})) |_| {
            _ = try scheduled.execute(&.{});
        } else |err| try std.testing.expectError(err, scheduled.execute(&.{}));
        try std.testing.expectEqual(serial.steps, scheduled.steps);
        try std.testing.expectEqualDeep(serial.initialized, scheduled.initialized);
        if (serial.getGlobal("items")) |value| try std.testing.expectEqualDeep(value.list.items(), scheduled.getGlobal("items").?.list.items());
        if (serial.failure) |failure| {
            try std.testing.expectEqualDeep(failure.diagnostic.span, scheduled.failure.?.diagnostic.span);
            try std.testing.expectEqualStrings(failure.text(), scheduled.failure.?.text());
            try std.testing.expectEqual(serial.frames.items[0].ip, scheduled.frames.items[0].ip);
        }
    }
}

test "literal append validates its items once with or without a scheduler" {
    const Scheduler = struct {
        fn unexpected(_: ?*anyopaque, _: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            return error.RuntimeFailed;
        }
    };
    const code = [_]I{ ins(.list_append_items, 1), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var owner = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer owner.deinit();
    const borrowed = try owner.makeList(&.{.{ .int = 7 }});
    for ([_]bool{ false, true }) |with_scheduler| {
        var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var machine = try Machine.init(counter.allocator(), &program, .{ .tasks = if (with_scheduler) .{ .vtable = &.{ .dispatch = Scheduler.unexpected } } else null }, .{});
        defer machine.deinit();
        const target = try machine.makeList(&.{});
        try target.list.owned.values.ensureUnusedCapacity(machine.arena.allocator(), 1);
        try machine.enter(0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, &.{ target, borrowed });
        var one = [_]Value{borrowed};
        const before_reference = counter.allocations;
        try machine.prepareListItems(&one);
        const one_preparation = counter.allocations - before_reference;
        try std.testing.expect(one_preparation > 0);
        const before_execution = counter.allocations;
        _ = try machine.run(null);
        try std.testing.expectEqual(one_preparation, counter.allocations - before_execution);
        try std.testing.expect(target.list.items()[0].list.owned == borrowed.list.owned);
        try std.testing.expectEqual(@as(u64, code.len), machine.steps);
    }
}

test "literal append validates jump entries and respects task suspension and scheduler boundaries" {
    const code = [_]I{
        ins(.jump, 1), .{ .op = .list_append_items, .a = 1, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
    defer program.deinit();
    var suspended = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer suspended.deinit();
    const untouched = try suspended.makeList(&.{});
    try suspended.enter(0, 0, .{ .start = 0, .end = 0 });
    try suspended.stack.appendSlice(suspended.gpa, &.{ untouched, .{ .int = 7 } });
    const result = try suspended.run(1);
    try std.testing.expectEqual(@as(i64, 7), result.int);
    try std.testing.expectEqual(@as(usize, 0), untouched.list.items().len);
    try std.testing.expectEqual(@as(usize, 1), suspended.frames.items[0].ip);
    try std.testing.expectEqual(@as(u64, 1), suspended.steps);

    const Scheduler = struct {
        calls: usize = 0,
        fn mutate(context: ?*anyopaque, machine: *Machine, _: *const bytecode.TaskRegion) Error!bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            machine.stack.items[machine.stack.items.len - 1] = .{ .number = std.math.nan(f64) };
            return false;
        }
    };
    for ([_]bool{ false, true }) |with_scheduler| {
        var scheduler: Scheduler = .{};
        program.task_regions = &.{.{ .function = 0, .start = 1, .end = 2, .tasks = &.{} }};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .tasks = if (with_scheduler) .{ .ptr = &scheduler, .vtable = &.{ .dispatch = Scheduler.mutate } } else null }, .{});
        defer machine.deinit();
        const target = try machine.makeList(&.{});
        try machine.enter(0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, &.{ target, if (with_scheduler) Value{ .int = 7 } else Value{ .number = std.math.nan(f64) } });
        try std.testing.expectError(error.RuntimeFailed, machine.run(null));
        try std.testing.expectEqual(@as(usize, if (with_scheduler) 1 else 0), scheduler.calls);
        try std.testing.expectEqual(@as(usize, 0), target.list.items().len);
        try std.testing.expectEqual(@as(usize, 10), machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(u64, 2), machine.steps);
    }
}

test "list item opcodes validate standalone inputs and retain construction before target errors" {
    for ([_]bool{ false, true }) |optimized| for ([_]bool{ false, true }) |bad_input| {
        const original = [_]I{ ins(.load_global, 0), ins(.load_global, 1), .{ .op = .make_list, .a = 1, .span = .{ .start = 10, .end = 20 } }, .{ .op = .list_append, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        const combined = [_]I{ ins(.load_global, 0), ins(.load_global, 1), .{ .op = .list_append_items, .a = 1, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = if (optimized) &combined else &original, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "input" }, &.{ .any, .any });
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = .{ .int = 42 };
        machine.globals[1] = if (bad_input) .{ .number = std.math.nan(f64) } else .{ .int = 7 };
        @memset(machine.initialized, true);
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, if (bad_input) 10 else 5), machine.failure.?.diagnostic.span.start);
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), if (bad_input) "non-finite" else "expected a list") != null);
        try std.testing.expectEqual(@as(i64, 42), machine.globals[0].int);
    };
    const code = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.list_append_items, 1), ins(.halt, 0) };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "input" }, &.{ .any, .any });
    defer program.deinit();
    for ([_]bool{ false, true }) |bad_input| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = try machine.makeList(&.{});
        machine.globals[1] = types.listView(if (bad_input) &.{.{ .number = std.math.nan(f64) }} else &.{.{ .int = 7 }});
        @memset(machine.initialized, true);
        if (bad_input) {
            try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try std.testing.expectEqual(@as(usize, 0), machine.globals[0].list.items().len);
        } else {
            _ = try machine.execute(&.{});
            const nested = machine.globals[0].list.items()[0].list.owned;
            try std.testing.expectEqual(machine.identity, nested.owner);
            try std.testing.expectEqual(@as(i64, 7), nested.values.items[0].int);
            try std.testing.expect(machine.globals[1].list == .view);
        }
    }
}

test "literal append reports item underflow and validation before missing target" {
    const cases = [_]struct { count: u32, values: []const Value, start: usize }{
        .{ .count = 0, .values = &.{}, .start = 5 },
        .{ .count = 1, .values = &.{.{ .int = 7 }}, .start = 5 },
        .{ .count = 1, .values = &.{.{ .number = std.math.nan(f64) }}, .start = 10 },
        .{ .count = 2, .values = &.{.{ .int = 7 }}, .start = 10 },
    };
    for (cases) |case| {
        const code = [_]I{ .{ .op = .list_append_items, .a = case.count, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try machine.enter(0, 0, .{ .start = 0, .end = 0 });
        try machine.stack.appendSlice(machine.gpa, case.values);
        try std.testing.expectError(error.RuntimeFailed, machine.run(null));
        try std.testing.expectEqual(case.start, machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(usize, 20), machine.failure.?.diagnostic.span.end);
        try std.testing.expectEqual(@as(u64, 1), machine.steps);
    }
}

test "list item preparation materializes every item before validating an earlier scalar" {
    for ([_]bool{ false, true }) |optimized| {
        const original = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.load_global, 2), .{ .op = .make_list, .a = 2, .span = .{ .start = 10, .end = 20 } }, .{ .op = .list_append, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        const combined = [_]I{ ins(.load_global, 0), ins(.load_global, 1), ins(.load_global, 2), .{ .op = .list_append_items, .a = 2, .b = 10, .span = .{ .start = 5, .end = 20 } }, ins(.halt, 0) };
        var program = try testProgram(&.{.{ .name = "script", .code = if (optimized) &combined else &original, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{}, &.{ "target", "first", "second" }, &.{ .any, .any, .any });
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        machine.globals[0] = try machine.makeList(&.{});
        machine.globals[1] = .{ .number = std.math.nan(f64) };
        machine.globals[2] = types.listView(&.{.omitted});
        @memset(machine.initialized, true);
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "omitted argument marker") != null);
        try std.testing.expectEqual(@as(usize, 10), machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqual(@as(usize, 0), machine.globals[0].list.items().len);
    }
}

test "list equality terminates on cycles and native sequences become owned lists" {
    const compiler = @import("compiler.zig");
    const Native = struct {
        fn call(_: ?*anyopaque, allocator: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            if (id != .bounds) return error.UnexpectedBuiltin;
            const shared = try allocator.dupe(Value, &.{.{ .int = 1 }});
            const rows = try allocator.dupe(Value, &.{ types.listView(shared), types.listView(shared) });
            return types.listView(rows);
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\import object.bounds
            \\a:=[];a+=[a]
            \\b:=[];b+=[b]
            \\same:=a==b
            \\different:=a==[[]]
            \\rows:=bounds(0)
            \\row:=rows[0]
            \\row+=2
            \\shared:=len(rows[1])
            \\contents:=rows==[[1,2],[1,2]]
        , "list-graphs.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try Machine.init(std.testing.allocator, &program, .{ .vtable = &.{ .call_builtin = Native.call } }, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            try std.testing.expect(machine.getGlobal("same").?.boolean);
            try std.testing.expect(!machine.getGlobal("different").?.boolean);
            try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("shared").?.int);
            try std.testing.expect(machine.getGlobal("contents").?.boolean);
            try std.testing.expectEqual(machine.identity, machine.getGlobal("rows").?.list.owned.owner);
        }
    }
}

test "list append resolves handles after RHS growth and preserves preceding RHS effects" {
    const compiler = @import("compiler.zig");
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator,
            \\values:=[1]
            \\fn grown(target:list)->list
            \\    for i in 1:64 do scratch:=[i] end
            \\    target+=2
            \\    return [3,4]
            \\end
            \\values+=grown(values)
            \\empty:=[]
            \\empty+=empty
            \\values+=empty
            \\snapshot:=[];snapshot+=values
            \\values+=5
        , "list-rhs-growth.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const snapshot = types.sequence(machine.getGlobal("snapshot").?).?;
        try std.testing.expectEqual(@as(usize, 4), snapshot.len);
        for (snapshot, 1..) |value, expected| try std.testing.expectEqual(@as(i64, @intCast(expected)), value.int);

        var failing_program = try compiler.compile(std.testing.allocator,
            \\values:=[1]
            \\fn failing(target:list)->int
            \\    target+=2
            \\    return 1%0
            \\end
            \\values+=failing(values)
        , "list-rhs-error.huak", .{ .optimize = optimize }, &diagnostic);
        defer failing_program.deinit();
        var failing = try Machine.init(std.testing.allocator, &failing_program, .{}, .{});
        defer failing.deinit();
        try std.testing.expectError(error.RuntimeFailed, failing.execute(&.{}));
        const remaining = try failing.mutableList(failing.getGlobal("values").?);
        try std.testing.expectEqual(@as(usize, 2), remaining.items.len);
        try std.testing.expectEqual(@as(i64, 2), remaining.items[1].int);
        try std.testing.expect(std.mem.indexOf(u8, failing.failure.?.text(), "division by zero") != null);
    }
}

test "compiled ranges include endpoints descending steps and safe integer overshoot" {
    const compiler = @import("compiler.zig");
    const input =
        \\up:=0
        \\for i in 0:2:4 do
        \\up=up+i
        \\end
        \\down:=0
        \\for i in 3:-1:0 do
        \\down=down+i
        \\end
        \\edge:=0
        \\for i in 9223372036854775806:2:9223372036854775807 do
        \\edge=edge+1
        \\end
        \\empty:=0
        \\for i in 3:1 do
        \\empty=empty+1
        \\end
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, input, "range.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("up").?.int);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("down").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("edge").?.int);
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
}

test "dynamic integer ranges preserve precision endpoints and independent iteration state" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\bounds:=[1,3]
        \\sum:=0
        \\for i in bounds[0]:bounds[1] do; sum=sum+i; end
        \\large:=[9007199254740993,9007199254740993]
        \\visits:=0
        \\observed:=[]; for exact in large[0]:large[1] do; observed+=exact; visits=visits+1; end
        \\hi:=[9223372036854775806,9223372036854775807]
        \\hi_count:=0
        \\for hi_value in hi[0]:2:hi[1] do; hi_count=hi_count+1; end
        \\for hi_endpoint in hi[1]:hi[1] do; observed+=hi_endpoint; visits=visits+1; end
        \\lo:=[-9223372036854775807,-9223372036854775808]
        \\lo_count:=0
        \\for lo_value in lo[0]:-2:lo[1] do; lo_count=lo_count+1; end
        \\for lo_endpoint in lo[1]:-1:lo[1] do; observed+=lo_endpoint; visits=visits+1; end
        \\selected:=0
        \\for changed in bounds[0]:5 do
        \\    saved:=changed
        \\    changed=100
        \\    if saved==2 then; continue; end
        \\    selected=selected+saved
        \\    if saved==4 then; break; end
        \\end
    , "dynamic-integer-ranges.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("sum").?.int);
    try std.testing.expectEqual(@as(i64, 9007199254740993), types.sequence(machine.getGlobal("observed").?).?[0].int);
    try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("visits").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("hi_count").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("lo_count").?.int);
    try std.testing.expectEqual(std.math.maxInt(i64), types.sequence(machine.getGlobal("observed").?).?[1].int);
    try std.testing.expectEqual(std.math.minInt(i64), types.sequence(machine.getGlobal("observed").?).?[2].int);
    try std.testing.expectEqual(@as(i64, 8), machine.getGlobal("selected").?.int);
    try std.testing.expect(machine.getGlobal("changed") == null);
}

test "one compiled dynamic range normalizes actual types separately for each execution" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\param floating:bool=false
        \\bounds:=[1,3,1]
        \\if floating then; bounds=[1,3.0,1]; end
        \\result:=collect(bounds[0],bounds[1],bounds[2])
        \\from_start:=collect([1.0][0],3,1)
        \\from_step:=collect(1,2,[0.5][0])
        \\fn collect(start:any,stop:any,step:any)->list
        \\    count:=0
        \\    first:any:=0
        \\    last:any:=0
        \\    for i in start:step:stop do
        \\        if count==0 then; first=i; end
        \\        last=i
        \\        count=count+1
        \\    end
        \\    return [first,last,count]
        \\end
    , "reusable-dynamic-range.huak", .{}, &diagnostic);
    defer program.deinit();
    for ([_]bool{ false, true }) |floating| {
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{.{ .name = "floating", .value = if (floating) "true" else "false" }});
        const result = types.sequence(machine.getGlobal("result").?).?;
        try std.testing.expectEqual(@as(i64, 3), result[2].int);
        if (floating) {
            try std.testing.expectEqual(@as(f64, 1), result[0].number);
            try std.testing.expectEqual(@as(f64, 3), result[1].number);
        } else {
            try std.testing.expectEqual(@as(i64, 1), result[0].int);
            try std.testing.expectEqual(@as(i64, 3), result[1].int);
        }
        const from_start = types.sequence(machine.getGlobal("from_start").?).?;
        try std.testing.expectEqual(@as(f64, 1), from_start[0].number);
        try std.testing.expectEqual(@as(f64, 3), from_start[1].number);
        const from_step = types.sequence(machine.getGlobal("from_step").?).?;
        try std.testing.expectEqual(@as(f64, 1), from_step[0].number);
        try std.testing.expectEqual(@as(f64, 2), from_step[1].number);
        try std.testing.expectEqual(@as(i64, 3), from_step[2].int);
    }
}

test "floating bounds normalize the first value and loop variables shadow outer bindings" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\observed:=[]; for dynamic_start in [1.0][0]:3 do; observed+=dynamic_start; break; end
        \\for dynamic_stop in 1:[3.0][0] do; observed+=dynamic_stop; break; end
        \\for dynamic_step in 1:[0.5][0]:2 do; observed+=dynamic_step; break; end
        \\for static_float in 1:0.5:2 do; observed+=static_float; break; end
        \\typed:float:=0
        \\for typed in 1:3 do; break; end
        \\down:=0
        \\for descending in [3][0]:[-1][0]:[1][0] do; down=down+descending; end
        \\empty:=0
        \\for none in [3][0]:[1][0] do; empty=empty+1; end
    , "floating-range.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    for (types.sequence(machine.getGlobal("observed").?).?) |value| {
        try std.testing.expectEqual(@as(f64, 1), value.number);
    }
    try std.testing.expectEqual(@as(f64, 0), machine.getGlobal("typed").?.number);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("down").?.int);
    try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
    try std.testing.expect(machine.getGlobal("none") == null);
}

test "range operands are evaluated once before normalization in their existing order" {
    const Log = struct {
        labels: [3][]const u8 = undefined,
        count: usize = 0,

        fn print(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print or self.count == self.labels.len) return error.UnexpectedCall;
            self.labels[self.count] = args[0].string;
            self.count += 1;
            return .unit;
        }
    };
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\sum:=0
        \\for i in bound(1,"start"):bound(1,"step"):bound(3,"stop") do; sum=sum+i; end
        \\fn bound(value:any,label:string)->any
        \\    print(label)
        \\    return value
        \\end
    , "range-evaluation.huak", .{}, &diagnostic);
    defer program.deinit();
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .call_builtin = Log.print } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(usize, 3), log.count);
    try std.testing.expectEqualStrings("start", log.labels[0]);
    try std.testing.expectEqualStrings("stop", log.labels[1]);
    try std.testing.expectEqualStrings("step", log.labels[2]);
    try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("sum").?.int);
}

test "range initialization validates every operand even before an empty range" {
    const compiler = @import("compiler.zig");
    const cases = [_]struct { values: []const u8, message: []const u8 }{
        .{ .values = "[true,1,1]", .message = "expected a number" },
        .{ .values = "[3,\"stop\",1]", .message = "expected a number" },
        .{ .values = "[3,1,false]", .message = "expected a number" },
        .{ .values = "[3,1,0]", .message = "range step must not be zero" },
        .{ .values = "[3,1,-0.0]", .message = "range step must not be zero" },
        .{ .values = "[9223372036854775807,9223372036854775807,0]", .message = "range step must not be zero" },
        .{ .values = "[-9223372036854775808,-9223372036854775808,0]", .message = "range step must not be zero" },
    };
    for (cases) |case| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "values:={s}\nentered:=false\nfor i in values[0]:values[2]:values[1] do; entered=true; end\n", .{case.values});
        defer std.testing.allocator.free(input);
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "invalid-range.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), case.message) != null);
        try std.testing.expect(!machine.getGlobal("entered").?.boolean);
        try std.testing.expect(machine.getGlobal("i") == null);
    }
    // Non-finite data can arrive through an external host's dynamic values.
    // Test every position directly; source literals already reject these.
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |nonfinite| {
        for (0..3) |position| {
            var program = try testProgram(&.{}, &.{}, &.{}, &.{});
            defer program.deinit();
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            var operands = [_]Value{ .{ .int = 3 }, .{ .int = 1 }, .{ .int = 1 } };
            operands[position] = .{ .number = nonfinite };
            try std.testing.expectError(error.RuntimeFailed, machine.initializeRange(operands[0], operands[1], operands[2]));
            try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "finite") != null);
        }
    }
}

test "compiled runtime failures report actual source spans and do not trap" {
    const compiler = @import("compiler.zig");
    const cases = [_][]const u8{
        "x:=9223372036854775807+1\n",
        "x:=(-9223372036854775807-1)*(-1)\n",
        "x:=1/0\n",
        "x:=1e308*1e308\n",
        "x:=(-1)^0.5\n",
        "x:=[1][-1]\n",
        "for i in 0:0:1 do\nend\n",
    };
    for (cases) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "failure.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(machine.failure.?.diagnostic.span.end > machine.failure.?.diagnostic.span.start);
        try std.testing.expect(machine.failure.?.trace.len > 0);
    }
}

test "panic is a host-independent failure with source and script call stack" {
    const HostProbe = struct {
        calls: usize = 0,

        fn call(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
            const probe: *@This() = @ptrCast(@alignCast(context.?));
            probe.calls += 1;
            return error.UnexpectedHostCall;
        }
    };
    const script =
        \\fn stop(message:string) panic(message) end
        \\fn caller() stop("几何失败 Ω") end
        \\caller()
        \\after:=1
    ;
    var diagnostic: ?source.Diagnostic = null;
    var program = try @import("compiler.zig").compile(std.testing.allocator, script, "panic.huak", .{}, &diagnostic);
    defer program.deinit();
    var probe: HostProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &probe, .vtable = &.{ .call_builtin = HostProbe.call } }, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    const detail = machine.failure.?;
    try std.testing.expectEqualStrings("panic", detail.text());
    try std.testing.expectEqualStrings("几何失败 Ω", detail.native_message);
    try std.testing.expectEqualStrings("panic.huak", detail.diagnostic.fileName().?);
    try std.testing.expectEqual(@as(usize, 1), detail.diagnostic.position(script).line);
    try std.testing.expectEqual(std.mem.indexOf(u8, script, "panic(message)").?, detail.diagnostic.span.start);
    try std.testing.expectEqual(@as(usize, 3), detail.trace.len);
    try std.testing.expectEqualStrings("stop", detail.trace[0].function);
    try std.testing.expectEqualStrings("caller", detail.trace[1].function);
    try std.testing.expect(machine.getGlobal("after") == null);
    const steps = machine.steps;
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(steps, machine.steps);
    try std.testing.expectEqualSlices(TraceEntry, detail.trace, machine.failure.?.trace);
    try std.testing.expect(builtin.lookup("assert") == null);
}

test "standard assert uses ordinary calls defaults and panic without a host" {
    const cases = [_]struct { call: []const u8, message: []const u8 }{
        .{ .call = "assert(false)", .message = "assertion failed" },
        .{ .call = "assert(false,\"自定义失败 Ω\")", .message = "自定义失败 Ω" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        const script = try std.fmt.allocPrint(
            std.testing.allocator,
            "import \"std/assertions.huak\".assert\nassert(true)\nassert(true,\"must not fail\")\n{s}\nafter:=42",
            .{case.call},
        );
        defer std.testing.allocator.free(script);
        var diagnostic: ?source.Diagnostic = null;
        var program = try @import("compiler.zig").compile(std.testing.allocator, script, "assertion.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 2), program.modules.len);
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        const detail = machine.failure.?;
        try std.testing.expectEqualStrings(case.message, detail.native_message);
        try std.testing.expectEqualStrings("std/assertions.huak", detail.diagnostic.fileName().?);
        try std.testing.expectEqualStrings("assert", detail.trace[0].function);
        try std.testing.expectEqual(@as(usize, 2), detail.trace.len);
        try std.testing.expectEqual(std.mem.indexOf(u8, script, case.call).?, detail.trace[1].span.start);
        try std.testing.expect(machine.getGlobal("after") == null);
    };
}

test "panic owns its complete long UTF8 message independently of program buffers" {
    const prefix = "数学诊断 Ω\n";
    const message = try std.testing.allocator.alloc(u8, prefix.len * 1024);
    defer std.testing.allocator.free(message);
    for (0..1024) |index| @memcpy(message[index * prefix.len ..][0..prefix.len], prefix);
    const expected = try std.testing.allocator.dupe(u8, message);
    defer std.testing.allocator.free(expected);
    var program = try testProgram(&.{.{
        .name = "script",
        .code = &.{ ins(.constant, 0), .{ .op = .call_builtin, .a = @backingInt(builtin.Id.panic), .b = 1 }, ins(.halt, 0) },
        .parameters = &.{},
        .result = .unit,
        .local_types = &.{},
    }}, &.{.{ .string = message }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    @memset(message, 0);
    try std.testing.expectEqualStrings(expected, machine.failure.?.native_message);
    try std.testing.expect(std.unicode.utf8ValidateSlice(machine.failure.?.native_message));
}

fn panicAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = machine.execute(&.{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqualStrings("完整失败消息 Ω", machine.failure.?.native_message);
        return;
    };
    return error.ExpectedRuntimeFailure;
}

test "panic releases machine frames message and diagnostics at every allocation failure" {
    var diagnostic: ?source.Diagnostic = null;
    var program = try @import("compiler.zig").compile(std.testing.allocator, "fn stop() panic(\"完整失败消息 Ω\") end; stop()", "panic-oom.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, panicAllocationExercise, .{&program});
}

const default_lists =
    \\fn collect(head:list=[[]],rest:int...)->list
    \\    nested:=head[0]
    \\    nested+=len(rest)
    \\    return head
    \\end
    \\first:=collect()
    \\second:=collect()
    \\third:=collect([[]],7,8)
    \\child:=first[0]
    \\child+=9
    \\first_length:=len(first[0])
    \\second_length:=len(second[0])
    \\third_value:=third[0][0]
;

fn defaultAllocationExercise(allocator: std.mem.Allocator, program: *const bytecode.Program) !void {
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("first_length").?.int);
    try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("second_length").?.int);
    try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("third_value").?.int);
}

test "default collections and rest lists are owned independently per call and execution" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try @import("compiler.zig").compile(std.testing.allocator, default_lists, "default-lists.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| try defaultAllocationExercise(std.testing.allocator, &program);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, defaultAllocationExercise, .{&program});
    }
}

test "default metadata is validated for external bytecode before entering a function" {
    const cases = [_]bytecode.Function{
        .{ .name = "mismatched_defaults", .parameters = &.{.int}, .defaults = &.{}, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_defaults_length", .parameters = &.{.int}, .defaults = &.{ .{ .int = 1 }, .{ .int = 2 } }, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_default_type", .parameters = &.{.int}, .defaults = &.{.{ .boolean = true }}, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.int} },
        .{ .name = "wrong_default_order", .parameters = &.{ .int, .int }, .defaults = &.{ .{ .int = 1 }, null }, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{ .int, .int } },
        .{ .name = "rest_default", .parameters = &.{.list}, .defaults = &.{types.listView(&.{})}, .variadic = .int, .code = &.{ins(.return_value, 0)}, .result = .unit, .local_types = &.{.list} },
    };
    for (cases, 0..) |function, index| {
        const code: []const I = if (index == 3)
            &.{ ins(.constant, 0), ins(.constant, 0), .{ .op = .call, .a = 1, .b = 2 }, ins(.halt, 0) }
        else
            &.{ .{ .op = .call, .a = 1 }, ins(.halt, 0) };
        var program = try testProgram(&.{
            .{ .name = "script", .parameters = &.{}, .code = code, .result = .unit, .local_types = &.{} },
            function,
        }, &.{.{ .int = 1 }}, &.{}, &.{});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
}

test "runtime checks function arguments and returns even for externally constructed bytecode" {
    const function_code = &.{ ins(.constant, 0), ins(.return_value, 0) };
    var program = try testProgram(&.{
        .{ .name = "script", .code = &.{ .{ .op = .call, .a = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "bad_result", .code = function_code, .parameters = &.{}, .result = .int, .local_types = &.{} },
    }, &.{.{ .boolean = true }}, &.{}, &.{});
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "expected int") != null);
    program.functions = &.{
        .{ .name = "script", .code = &.{ ins(.constant, 0), .{ .op = .call, .a = 1, .b = 1 }, ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} },
        .{ .name = "int_argument", .code = function_code, .parameters = &.{.int}, .result = .boolean, .local_types = &.{.int} },
    };
    var arguments_machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer arguments_machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, arguments_machine.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, arguments_machine.failure.?.text(), "expected int") != null);
}

test "invalid bytecode and uninitialized variables fail without accessing invalid memory" {
    const codes = [_][]const I{
        &.{ins(.pop, 0)},
        &.{ins(.constant, 100)},
        &.{ins(.jump, 100)},
        &.{ins(.load_global, 0)},
        &.{ins(.load_local, 0)},
        &.{.{ .op = .call, .a = 100 }},
        &.{ins(.make_list, 1)},
        &.{ins(.slice, 0)},
        &.{.{ .op = .call_builtin, .a = std.math.maxInt(u32) }},
    };
    for (codes) |code| {
        var program = try testProgram(&.{.{ .name = "script", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{.int} }}, &.{}, &.{"uninitialized"}, &.{.int});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
}

fn allocationExercise(allocator: std.mem.Allocator, fail_execution: bool) !void {
    const normal = [_]I{
        ins(.load_global, 0), ins(.constant, 0), ins(.add, 0), ins(.constant, 1), ins(.make_list, 2), ins(.constant, 2), ins(.index, 0), ins(.store_global, 1), ins(.halt, 0),
    };
    const failing = [_]I{ ins(.constant, 1), ins(.constant, 2), ins(.divide, 0), ins(.halt, 0) };
    var program: bytecode.Program = .{
        .arena = .init(allocator),
        .source_text = "allocation exercise",
        .name = "allocation.huak",
        .functions = &.{.{ .name = "script", .code = if (fail_execution) &failing else &normal, .parameters = &.{}, .result = .unit, .local_types = &.{ .any, .any } }},
        .constants = &.{ .{ .string = "完整输出" }, .{ .int = 2 }, .{ .int = 0 } },
        .parameters = &.{.{ .name = "prefix", .kind = .string, .default = null, .global = 0, .span = .{ .start = 0, .end = 1 } }},
        .global_names = &.{ "prefix", "result" },
        .global_types = &.{ .string, .string },
        .readonly_globals = &.{ true, false },
    };
    defer program.deinit();
    var machine = try Machine.init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = machine.execute(&.{.{ .name = "prefix", .value = "中文：" }}) catch |err| {
        if (err == error.RuntimeFailed and fail_execution) return;
        return err;
    };
    if (fail_execution) return error.ExpectedRuntimeFailure;
    try std.testing.expectEqualStrings("中文：完整输出", machine.getGlobal("result").?.string);
}

test "every allocation failure frees VM globals lists operands locals frames and diagnostics" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{true});
}

test "unary positive preserves numbers pairs and linear handles but checks dynamic types" {
    const accepted = [_]Value{
        .{ .int = 7 },                                     .{ .number = 2.5 },                              .{ .pair = .{ .x = 1, .y = 2 } },
        .{ .handle = .{ .kind = .variable, .index = 0 } }, .{ .handle = .{ .kind = .linear, .index = 1 } },
    };
    for (accepted) |value| {
        var program = try testProgram(&.{.{ .name = "script", .code = &.{ ins(.constant, 0), ins(.positive, 0), ins(.store_global, 0), ins(.halt, 0) }, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{value}, &.{"result"}, &.{value.valueType()});
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expect(try machine.valuesEqual(value, machine.getGlobal("result").?));
    }
    const compiler = @import("compiler.zig");
    const rejected = [_][]const u8{ "v:=[true][0];result:=+v", "v:=[\"text\"][0];result:=+v", "v:=[[1]][0];result:=+v" };
    for (rejected) |input| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "positive.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "unary +") != null);
    }
}

const ParallelRun = struct {
    program: *const bytecode.Program,
    parameter: []const u8,
    result: ?i64 = null,
    failed: bool = false,

    fn run(self: *ParallelRun) void {
        var machine = Machine.init(std.heap.page_allocator, self.program, .{}, .{}) catch {
            self.failed = true;
            return;
        };
        defer machine.deinit();
        _ = machine.execute(&.{.{ .name = "n", .value = self.parameter }}) catch {
            self.failed = true;
            return;
        };
        self.result = (machine.getGlobal("answer") orelse {
            self.failed = true;
            return;
        }).int;
    }
};

test "immutable bytecode can run concurrently with isolated parameters and globals" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, "param n:int=1; answer:=fact(n)\nfn fact(x:int)->int\nif x<=1 then;return 1;end\nreturn x*fact(x-1)\nend", "parallel.huak", .{}, &diagnostic);
    defer program.deinit();
    var contexts = [_]ParallelRun{
        .{ .program = &program, .parameter = "4" }, .{ .program = &program, .parameter = "5" },
        .{ .program = &program, .parameter = "6" }, .{ .program = &program, .parameter = "7" },
    };
    var threads: [contexts.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&contexts, &threads) |*context, *thread| {
        thread.* = try std.Thread.spawn(.{}, ParallelRun.run, .{context});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (contexts, [_]i64{ 24, 120, 720, 5040 }) |context, expected| {
        try std.testing.expect(!context.failed);
        try std.testing.expectEqual(@as(?i64, expected), context.result);
    }
}

test "string parameters validate UTF-8 before native host initialization" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator, "param title:string=\"默认\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    var invalid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.prepareParameters(&.{.{ .name = "title", .value = "\xff" }}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "UTF-8") != null);
    try std.testing.expectEqual(@as(u64, 0), invalid.steps);
    var valid = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer valid.deinit();
    try valid.prepareParameters(&.{.{ .name = "title", .value = "中文 Ω" }});
    try std.testing.expectEqualStrings("中文 Ω", valid.getGlobal("title").?.string);
}

test "dot calls execute forward recursive chained indexed and expression receivers" {
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\answer:=6.fact()
        \\chained:=(1+2).combine(4).combine(5)
        \\indexed:=[7,8][1].combine(9)
        \\point:=(2,3).move((4,5))
        \\property:=point.x
        \\called:=point.x()
        \\fn fact(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*(x-1).fact()
        \\end
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn move(p:pair,delta:pair)->pair; return p+delta; end
        \\fn x(p:pair)->float; return p.y; end
    , "dot-execution.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 720), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(i64, 345), machine.getGlobal("chained").?.int);
    try std.testing.expectEqual(@as(i64, 89), machine.getGlobal("indexed").?.int);
    try std.testing.expectEqual(@as(f64, 6), machine.getGlobal("point").?.pair.x);
    try std.testing.expectEqual(@as(f64, 8), machine.getGlobal("point").?.pair.y);
    try std.testing.expectEqual(@as(f64, 6), machine.getGlobal("property").?.number);
    try std.testing.expectEqual(@as(f64, 8), machine.getGlobal("called").?.number);
}

test "dot calls evaluate the receiver once before arguments and use the builtin host" {
    const Log = struct {
        labels: [4][]const u8 = undefined,
        count: usize = 0,

        fn print(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*Machine) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print or self.count == self.labels.len) return error.UnexpectedCall;
            self.labels[self.count] = args[0].string;
            self.count += 1;
            return .unit;
        }
    };
    const compiler = @import("compiler.zig");
    var diagnostic: ?source.Diagnostic = null;
    var program = try compiler.compile(std.testing.allocator,
        \\answer:=mark(2,"receiver").combine(mark(3,"first"),mark(4,"second"))
        \\caption:="unrelated data does not change receiver evaluation"
        \\"builtin".print()
        \\fn mark(value:int,label:string)->int
        \\  label.print()
        \\  return value
        \\end
        \\fn combine(x:int,y:int,z:int)->int; return x*100+y*10+z; end
    , "dot-evaluation.huak", .{}, &diagnostic);
    defer program.deinit();
    var log: Log = .{};
    var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &log, .vtable = &.{ .call_builtin = Log.print } }, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 234), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(@as(usize, 4), log.count);
    for ([_][]const u8{ "receiver", "first", "second", "builtin" }, log.labels) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

/// Pure VM probes check batching and sequencing, independently of native FFI
/// acceptance. Source blocks in these fixtures contain no nested delimiters.
const TypstBatchProbe = struct {
    single_calls: usize = 0,
    batch_sizes: [256]usize = @splat(0),
    batch_count: usize = 0,
    seen: [256][]const u8 = undefined,
    captures: [256][]const TypstBinding = undefined,
    generations: [256]usize = undefined,
    seen_count: usize = 0,
    generation: usize = 0,
    fields: usize = 0,
    effects: usize = 0,
    fatal_index: ?usize = null,
    message_storage: [64]u8 = @splat(0),
    message_length: usize = 0,

    fn from(context: ?*anyopaque) *TypstBatchProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn value(self: *TypstBatchProbe, allocator: std.mem.Allocator, request: TypstRequest) !Value {
        const text = request.source;
        const index = self.seen_count;
        self.seen[index] = text;
        self.captures[index] = try allocator.dupe(TypstBinding, request.bindings);
        self.generations[index] = self.generation;
        self.seen_count += 1;
        if (std.mem.indexOf(u8, text, "FAIL") != null) return error.TypesetFailed;
        return .{ .handle = .{ .kind = .text, .index = index } };
    }

    fn one(context: ?*anyopaque, allocator: std.mem.Allocator, request: TypstRequest) !Value {
        const self = from(context);
        self.single_calls += 1;
        return self.value(allocator, request) catch |err| {
            self.message_length = @min(request.source.len, self.message_storage.len);
            @memcpy(self.message_storage[0..self.message_length], request.source[0..self.message_length]);
            return err;
        };
    }

    fn batch(context: ?*anyopaque, allocator: std.mem.Allocator, requests: []const TypstRequest, values: []Value, diagnostic: *TypstBatchDiagnostic) !void {
        const self = from(context);
        self.batch_sizes[self.batch_count] = requests.len;
        self.batch_count += 1;
        if (self.fatal_index) |index| {
            diagnostic.* = .{ .request_index = index, .message = "fatal native probe" };
            return error.TypstPanic;
        }
        for (requests, values, 0..) |request, *result, index| {
            const text = request.source;
            result.* = self.value(allocator, request) catch |err| {
                const length = @min(text.len, self.message_storage.len);
                @memcpy(self.message_storage[0..length], text[0..length]);
                diagnostic.* = .{ .completed = index, .request_index = index, .message = self.message_storage[0..length] };
                return err;
            };
        }
    }

    fn setup(context: ?*anyopaque, _: []const u8) !void {
        from(context).generation += 1;
    }

    fn field(context: ?*anyopaque, _: std.mem.Allocator, text: Value, _: []const u8) !Value {
        from(context).fields += 1;
        return .{ .quantity = units.fromPoints(@floatFromInt(text.handle.index + 1)) };
    }

    fn effect(context: ?*anyopaque, _: std.mem.Allocator, _: builtin.Id, _: []const Value, _: ?*Machine) !Value {
        from(context).effects += 1;
        return .unit;
    }

    const host_vtable: Host.VTable = .{ .typst = one, .typst_batch = batch, .setup_typst = setup, .field = field, .call_builtin = effect, .error_message = message };
    const single_host_vtable = blk: {
        var table = host_vtable;
        table.typst_batch = null;
        break :blk table;
    };

    fn host(self: *TypstBatchProbe, batched: bool) Host {
        return .{ .ptr = self, .vtable = if (batched) &host_vtable else &single_host_vtable };
    }

    fn message(context: ?*anyopaque) []const u8 {
        const self = from(context);
        return self.message_storage[0..self.message_length];
    }

    fn block(_: *anyopaque, text: []const u8) !usize {
        const close: u8 = if (text[0] == '[') ']' else '}';
        return (std.mem.indexOfScalar(u8, text, close) orelse return error.UnclosedFixture) + 1;
    }

    fn compile(input: []const u8, optimize: bool) !bytecode.Program {
        const compiler = @import("compiler.zig");
        var marker: u8 = 0;
        var diagnostic: ?source.Diagnostic = null;
        return compiler.compile(std.testing.allocator, input, "typst-batch-vm.huak", .{ .optimize = optimize, .source_parser = .{ .ptr = &marker, .vtable = &.{ .block = block } } }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
    }
};

test "adjacent text assignments batch across neither settings nor result observations" {
    const input =
        \\a:=typ[A]
        \\b:=typ[B]
        \\setup_typst { set text(size:20pt) }
        \\c:=typ[C]
        \\d:=typ[D]
        \\width:=c.width
        \\e:=typ[E]
        \\f:=typ[F]
        \\print(width)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 0), probe.single_calls);
        try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
        try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 1, 1, 1 }, probe.generations[0..probe.seen_count]);
        try std.testing.expectEqual(@as(usize, 1), probe.fields);
        try std.testing.expectEqual(@as(usize, 1), probe.effects);
        try std.testing.expectEqual(units.fromPoints(3), machine.getGlobal("width").?.quantity);
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        _ = try serial.execute(&.{});
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualSlices(usize, serial_probe.generations[0..serial_probe.seen_count], probe.generations[0..probe.seen_count]);
    }
}

test "text batching supports locals and treats function calls as barriers" {
    var program = try TypstBatchProbe.compile(
        \\fn make() -> text
        \\ local_a:=typ[Local A]
        \\ local_b:=typ[Local B]
        \\ return local_b
        \\end
        \\a:=typ[A]
        \\b:=typ[B]
        \\result:=make()
        \\c:=typ[C]
        \\d:=typ[D]
    , true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expectEqual(@as(usize, 3), machine.getGlobal("result").?.handle.index);
    try std.testing.expectEqual(@as(usize, 0), machine.locals.items.len);
}

test "text batch failures preserve successful bindings source positions and effects" {
    const input =
        \\first:=typ[First]
        \\second:=typ[FAIL first error]
        \\third:=typ[FAIL later error]
        \\print("must not execute")
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.batch_count);
        try std.testing.expect(machine.getGlobal("first") != null);
        try std.testing.expect(machine.getGlobal("second") == null);
        try std.testing.expect(machine.getGlobal("third") == null);
        try std.testing.expectEqual(@as(usize, 0), probe.effects);
        try std.testing.expectEqual(std.mem.indexOf(u8, input, "typ[FAIL first").?, machine.failure.?.diagnostic.span.start);
        try std.testing.expectEqualStrings(probe.seen[1], machine.failure.?.native_message);
        @memset(&probe.message_storage, '?');
        try std.testing.expectEqualStrings(probe.seen[1], machine.failure.?.native_message);
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqual(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
    }
}

test "text batch planning preserves instruction limits without speculative requests" {
    var program = try TypstBatchProbe.compile(
        \\a:=typ[A]
        \\b:=typ[B]
        \\c:=typ[C]
        \\print("complete")
    , true);
    defer program.deinit();
    for (0..12) |limit| {
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{ .instructions = limit });
        defer machine.deinit();
        const actual = machine.execute(&.{});
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{ .instructions = limit });
        defer serial.deinit();
        const expected = serial.execute(&.{});
        if (expected) |value| {
            try std.testing.expectEqualDeep(value, try actual);
        } else |err| try std.testing.expectError(err, actual);
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqual(serial_probe.seen_count, probe.seen_count);
        try std.testing.expectEqual(serial_probe.effects, probe.effects);
        if (serial.failure) |failure| try std.testing.expectEqual(failure.diagnostic.span, machine.failure.?.diagnostic.span);
    }
}

test "text batching has a bounded descriptor budget" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    for (0..130) |index| try writer.writer.print("text_{d}:=typ[Label {d}]\n", .{ index, index });
    var program = try TypstBatchProbe.compile(writer.written(), true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{ 64, 64, 2 }, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expectEqual(@as(usize, 130), probe.seen_count);
    try std.testing.expectEqual(@as(usize, 129), machine.getGlobal("text_129").?.handle.index);
}

test "fatal text batch failures locate their request without a recoverable prefix" {
    const input =
        \\first:=typ[First]
        \\second:=typ[Second]
        \\third:=typ[Third]
        \\print("must not execute")
    ;
    var program = try TypstBatchProbe.compile(input, true);
    defer program.deinit();
    var probe: TypstBatchProbe = .{ .fatal_index = 2 };
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "typ[Third]").?, machine.failure.?.diagnostic.span.start);
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "TypstPanic") != null);
    try std.testing.expectEqual(@as(u64, 5), machine.steps);
    try std.testing.expect(machine.getGlobal("first") == null);
    try std.testing.expectEqual(@as(usize, 0), probe.effects);
    var invalid_probe: TypstBatchProbe = .{ .fatal_index = 3 };
    var invalid = try Machine.init(std.testing.allocator, &program, invalid_probe.host(true), .{});
    defer invalid.deinit();
    try std.testing.expectError(error.RuntimeFailed, invalid.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, invalid.failure.?.text(), "invalid Typst batch failure index") != null);
}

test "text batch planning preserves malformed bytecode error order" {
    for (0..3) |kind| {
        var code = [_]I{
            .{ .op = .typst, .a = 0, .span = .{ .start = 10, .end = 11 } },
            .{ .op = .store_global, .a = 0, .span = .{ .start = 12, .end = 13 } },
            .{ .op = .typst, .a = 1, .span = .{ .start = 20, .end = 21 } },
            .{ .op = .store_global, .a = 1, .span = .{ .start = 22, .end = 23 } },
            .{ .op = .typst, .a = 2, .span = .{ .start = 30, .end = 31 } },
            .{ .op = .store_global, .a = 2, .span = .{ .start = 32, .end = 33 } },
            ins(.halt, 0),
        };
        var readonly = [_]bool{ false, false, false };
        switch (kind) {
            0 => code[4].a = 100,
            1 => code[5].a = 100,
            2 => readonly[2] = true,
            else => unreachable,
        }
        var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "A" }, .{ .string = "B" }, .{ .string = "C" } }, &.{ "a", "b", "c" }, &.{ .text, .text, .text });
        defer program.deinit();
        program.readonly_globals = &readonly;
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
        try std.testing.expectEqual(@as(usize, 1), probe.batch_count);
        try std.testing.expectEqual(serial_probe.seen_count, probe.seen_count);
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqual(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
        try std.testing.expectEqualStrings(serial.failure.?.text(), machine.failure.?.text());
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        try std.testing.expectEqualDeep(serial.initialized, machine.initialized);
        try std.testing.expectEqualDeep(serial.stack.items, machine.stack.items);
    }
}

test "text batching honors entry jumps and repeated target assignments" {
    const code = [_]I{
        ins(.jump, 3),         ins(.typst, 0),        ins(.store_global, 0),
        ins(.typst, 1),        ins(.store_global, 1), ins(.typst, 2),
        ins(.store_global, 1), ins(.halt, 0),
    };
    var program = try testProgram(&.{.{ .name = "script", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }}, &.{ .{ .string = "Skipped" }, .{ .string = "A" }, .{ .string = "B" } }, &.{ "skipped", "result" }, &.{ .text, .text });
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqualSlices(usize, &.{2}, probe.batch_sizes[0..probe.batch_count]);
    try std.testing.expect(machine.getGlobal("skipped") == null);
    try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("result").?.handle.index);
    try std.testing.expectEqual(@as(u64, 6), machine.steps);
}

test "Typst captures batch current scalar snapshots and local shadows without changing VM accounting" {
    const input =
        \\param initial:int=2
        \\count:=initial
        \\typst_expose count,title
        \\title:="first"
        \\a:=typ[A]
        \\b:=typ[B]
        \\count=7;title="second"
        \\c:=typ[C]
        \\d:=typ[D]
        \\fn make_caption(count:int)->text
        \\title:="local"
        \\x:=typ[X]
        \\y:=typ[Y]
        \\return y
        \\end
        \\result:=make_caption(11)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try TypstBatchProbe.compile(input, optimize);
        defer program.deinit();
        var probe: TypstBatchProbe = .{};
        var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 0), probe.single_calls);
        try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, probe.batch_sizes[0..probe.batch_count]);
        for ([_]i64{ 2, 2, 7, 7, 11, 11 }, 0..) |count, index| {
            try std.testing.expectEqual(@as(usize, 2), probe.captures[index].len);
            try std.testing.expectEqualStrings("count", probe.captures[index][0].name);
            try std.testing.expectEqual(count, probe.captures[index][0].value.int);
            try std.testing.expectEqualStrings("title", probe.captures[index][1].name);
            try std.testing.expectEqualStrings(if (index < 2) "first" else if (index < 4) "second" else "local", probe.captures[index][1].value.string);
        }
        var serial_probe: TypstBatchProbe = .{};
        var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
        defer serial.deinit();
        _ = try serial.execute(&.{});
        try std.testing.expectEqual(serial.steps, machine.steps);
        try std.testing.expectEqualDeep(serial.globals, machine.globals);
        for (0..probe.seen_count) |index| try std.testing.expectEqualDeep(serial_probe.captures[index], probe.captures[index]);
        for ([_]u64{ 1, 3, 8, 12, 18, 24, 36, 48, 60, 80, 100 }) |limit| {
            var batch_limited: TypstBatchProbe = .{};
            var one_limited: TypstBatchProbe = .{};
            var actual = try Machine.init(std.testing.allocator, &program, batch_limited.host(true), .{ .instructions = limit });
            defer actual.deinit();
            var expected = try Machine.init(std.testing.allocator, &program, one_limited.host(false), .{ .instructions = limit });
            defer expected.deinit();
            const expected_result = expected.execute(&.{});
            const actual_result = actual.execute(&.{});
            if (expected_result) |_| {
                _ = try actual_result;
            } else |err| try std.testing.expectError(err, actual_result);
            try std.testing.expectEqual(expected.steps, actual.steps);
            try std.testing.expectEqualDeep(expected.initialized, actual.initialized);
            if (expected.failure) |failure| try std.testing.expectEqualDeep(failure.diagnostic.span, actual.failure.?.diagnostic.span);
        }
    }
}

test "Typst captured batch failure publishes only its successful prefix and does not read later operands early" {
    var program = try TypstBatchProbe.compile("count:=4\ntypst_expose count\nfirst:=typ[First]\nsecond:=typ[FAIL second]\nthird:=typ[Third]\n", false);
    defer program.deinit();
    var probe: TypstBatchProbe = .{};
    var machine = try Machine.init(std.testing.allocator, &program, probe.host(true), .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(machine.getGlobal("first") != null);
    try std.testing.expect(machine.getGlobal("second") == null);
    try std.testing.expect(machine.getGlobal("third") == null);
    var serial_probe: TypstBatchProbe = .{};
    var serial = try Machine.init(std.testing.allocator, &program, serial_probe.host(false), .{});
    defer serial.deinit();
    try std.testing.expectError(error.RuntimeFailed, serial.execute(&.{}));
    try std.testing.expectEqual(serial.steps, machine.steps);
    try std.testing.expectEqualDeep(serial.failure.?.diagnostic.span, machine.failure.?.diagnostic.span);
    try std.testing.expectEqualStrings(serial.failure.?.native_message, machine.failure.?.native_message);
}

test "list iteration and dictionary key snapshots share loop control and evaluate once" {
    const compiler = @import("compiler.zig");
    const input =
        \\calls:=[]
        \\fn items()->list calls+=1; return [1,2,3,4] end
        \\sum:=0
        \\for item in items() do
        \\    if item==2 then continue end
        \\    if item==4 then break end
        \\    sum=sum+item
        \\    item=100
        \\end
        \\empty:=0
        \\for unused in [] do empty=empty+1 end
        \\dict:={"first": 1,"second": 2}
        \\seen:=[]
        \\for key in dict.keys() do
        \\    seen+=[key]
        \\    dict_remove(dict,key)
        \\    dict["added"]=3
        \\end
        \\values:=[1,2,3]
        \\updated:=0
        \\for item in values do
        \\    values[2]=10
        \\    updated=updated+item
        \\end
        \\nested:=0
        \\for row in [[1,2],[3,4]] do
        \\    for value in row do nested=nested+value end
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, input, "iterables.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("calls").?.list.items().len);
        try std.testing.expectEqual(@as(i64, 4), machine.getGlobal("sum").?.int);
        try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("empty").?.int);
        try std.testing.expectEqual(@as(i64, 13), machine.getGlobal("updated").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("nested").?.int);
        const seen = machine.getGlobal("seen").?.list.items();
        try std.testing.expectEqual(@as(usize, 2), seen.len);
        try std.testing.expectEqualStrings("first", seen[0].string);
        try std.testing.expectEqualStrings("second", seen[1].string);
        try std.testing.expectEqual(@as(usize, 1), machine.getGlobal("dict").?.dict.entries.count());
    }
    for ([_][]const u8{ "items:=[1];for x in items do items+=2 end", "values:=[{}];for x in values[0] do end" }) |invalid| {
        var diagnostic: ?source.Diagnostic = null;
        var program = try compiler.compile(std.testing.allocator, invalid, "invalid-iterable.huak", .{}, &diagnostic);
        defer program.deinit();
        var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    }
    var diagnostic: ?source.Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compiler.compile(std.testing.allocator, "for key in {} do end", "dictionary.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "for requires a list or numeric range") != null);
}
