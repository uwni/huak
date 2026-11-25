//! Conservative effect proofs for isolated picture builders. This analysis
//! never executes source code or a host callback. Loops and branches join their
//! operand stacks and local provenance until the bytecode CFG reaches a fixed
//! point; a mutable picture is writable only when every incoming value is fresh.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Allocator = std.mem.Allocator;
const Type = bc.Type;
const Analysis = @import("effects/Analysis.zig");

/// Proof limits are serial fallbacks, never language/execution limits. They
/// bound both CFG storage and repeated work across a long helper call graph.
pub const limits = struct {
    pub const functions = 512;
    pub const instructions = 65_536;
    pub const globals = 4_096;
    pub const rounds = 64;
    pub const cells = 262_144;
    pub const work = 4_000_000;
};
pub const Budget = struct {
    remaining: usize = limits.work,
    exhausted: bool = false,

    pub fn consume(self: *Budget, amount: usize) bool {
        if (amount > self.remaining) {
            self.exhausted = true;
            self.remaining = 0;
            return false;
        }
        self.remaining -= amount;
        return true;
    }
};

pub const Summary = struct {
    safe: bool = false,
    fresh_owner: bool = false,
    reads: []const u32 = &.{},
    uses_typst: bool = false,
    observes_identity: bool = false,
};

pub const Value = struct {
    kind: Type = .any,
    initialized: bool = false,
    fresh_owner: bool = false,
    callable: ?bc.types.Function = null,
    bound: ?*const Bound = null,

    pub const Bound = struct { target: bc.types.Function.Target, values: []const Value, names: []const ?[]const u8 };

    pub fn ordinary(kind: Type) Value {
        return .{ .kind = kind, .initialized = true };
    }
    fn join(self: *Value, other: Value) bool {
        const before = self.*;
        self.kind = joinType(self.kind, other.kind);
        self.initialized = self.initialized and other.initialized;
        self.fresh_owner = self.fresh_owner and other.fresh_owner;
        if (!std.meta.eql(self.callable, other.callable)) self.callable = null;
        if (self.bound != other.bound) self.bound = null;
        return !std.meta.eql(before, self.*);
    }
};

pub const State = struct {
    stack: std.ArrayList(Value) = .empty,
    locals: []Value,

    pub fn pop(self: *State, analysis: *Analysis) Value {
        return self.stack.pop() orelse blk: {
            analysis.safe = false;
            analysis.malformed = true;
            break :blk .{};
        };
    }
};

pub fn supportedType(kind: Type) bool {
    return switch (kind) {
        .any, .unit, .int, .number, .length, .angle, .quantity, .scalar, .boolean, .string, .vec2, .vec3, .list, .path, .shape, .path_or_shape, .color, .gradient, .paint, .pen, .transform, .text, .typst_module, .picture, .function, .measure, .anchor, .object => true,
        else => false,
    };
}

pub fn joinType(a: Type, b: Type) Type {
    if (a == b) return a;
    if (a.isScalar() and b.isScalar()) return .scalar;
    return .any;
}

fn same(a: Summary, b: Summary) bool {
    return a.safe == b.safe and a.fresh_owner == b.fresh_owner and a.uses_typst == b.uses_typst and a.observes_identity == b.observes_identity and std.mem.eql(u32, a.reads, b.reads);
}

/// Isolated workers do not retain unused object allocations. Until allocation
/// identity has an independent representation, a program that observes native
/// handle/token numbering must keep its original ordered execution throughout.
pub fn observesIdentity(allocator: Allocator, scratch_allocator: Allocator, program: *const bc.Program, summaries: []const Summary) Allocator.Error!bool {
    // Library definitions do not execute merely because their module was
    // imported. Follow executable references before applying the barrier.
    const reachable = try allocator.alloc(bool, program.functions.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, program.entry);
    var budget: Budget = .{};
    while (pending.pop()) |index| {
        if (index >= reachable.len) return true;
        if (reachable[index]) continue;
        reachable[index] = true;
        const function = program.functions[index];
        for (function.code) |instruction| switch (instruction.op) {
            .call => try pending.append(allocator, instruction.a),
            .import_module => {
                if (instruction.a >= program.modules.len) return true;
                try pending.append(allocator, program.modules[instruction.a].entry);
            },
            .constant => {
                if (instruction.a >= program.constants.len) return true;
                const value = program.constants[instruction.a];
                if (value == .function and value.function == .bytecode)
                    try pending.append(allocator, value.function.bytecode);
            },
            else => {},
        };
        for (function.default_functions) |default| if (default) |callee| try pending.append(allocator, callee);
        const summary = if (program.isEntry(index)) try analyzeFunction(allocator, scratch_allocator, program, summaries, index, &budget, null, 0) else summaries[index];
        if (budget.exhausted) return true;
        if (summary.observes_identity) return true;
    }
    return false;
}

/// The least fixed point admits only proven callees. Recursive SCCs therefore
/// remain serial in this first version, including recursion hidden by helpers.
/// The summaries belong to `allocator`. Working state lives in arenas over
/// `scratch_allocator`, which must return freed memory, and is gone on return.
pub fn analyze(allocator: Allocator, scratch_allocator: Allocator, program: *const bc.Program) Allocator.Error!?[]const Summary {
    if (program.functions.len > limits.functions or program.global_types.len > limits.globals) return null;
    var instruction_count: usize = 0;
    for (program.functions) |function| {
        if (function.code.len > limits.instructions - instruction_count) return null;
        instruction_count += function.code.len;
    }
    var temporary: std.heap.ArenaAllocator = .init(scratch_allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const summaries = try scratch.alloc(Summary, program.functions.len);
    @memset(summaries, .{});
    var changed = true;
    var rounds: usize = 0;
    var budget: Budget = .{};
    while (changed) {
        if (rounds >= limits.rounds) return null;
        rounds += 1;
        changed = false;
        for (program.functions, 0..) |_, index| {
            if (program.isEntry(index)) continue;
            const result = try analyzeFunction(scratch, scratch_allocator, program, summaries, @intCast(index), &budget, null, 0);
            if (budget.exhausted) return null;
            if (!same(result, summaries[index])) {
                summaries[index] = result;
                changed = true;
            }
        }
    }
    const output = try allocator.alloc(Summary, summaries.len);
    errdefer allocator.free(output);
    var completed: usize = 0;
    errdefer for (output[0..completed]) |summary| allocator.free(summary.reads);
    for (output, summaries) |*destination, summary| {
        destination.* = summary;
        destination.reads = try allocator.dupe(u32, summary.reads);
        completed += 1;
    }
    return output;
}

pub fn analyzeFunction(allocator: Allocator, scratch_allocator: Allocator, program: *const bc.Program, summaries: []const Summary, index: u32, budget: *Budget, arguments: ?[]const Value, depth: usize) Allocator.Error!Summary {
    // Release the per-function CFG after every pass. Only the summary goes to
    // `allocator`; the stacks do not stay across interprocedural iterations.
    var temporary: std.heap.ArenaAllocator = .init(scratch_allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const function = program.functions[index];
    if (!budget.consume(function.code.len) or !budget.consume(function.local_types.len) or !budget.consume(program.global_types.len)) return .{};
    var analysis = try Analysis.init(scratch, scratch_allocator, program, summaries, budget);
    analysis.local_types = function.local_types;
    analysis.depth = depth;
    if (function.code.len == 0 or function.parameters.len > function.local_types.len) return .{};
    var working: State = .{ .locals = try scratch.alloc(Value, function.local_types.len) };
    @memset(working.locals, .{});
    for (function.parameters, 0..) |kind, parameter| {
        if (!supportedType(kind)) analysis.safe = false;
        working.locals[parameter] = if (arguments != null and parameter < arguments.?.len) arguments.?[parameter] else Value.ordinary(kind);
        working.locals[parameter].kind = kind;
    }
    const states = try scratch.alloc(?State, function.code.len);
    @memset(states, null);
    var pending: std.ArrayList(usize) = .empty;
    var cells: usize = 0;
    try propagate(&analysis, states, &pending, &cells, 0, &working);
    while (pending.pop()) |ip| {
        const incoming = states[ip].?;
        working.stack.clearRetainingCapacity();
        try working.stack.appendSlice(scratch, incoming.stack.items);
        @memcpy(working.locals, incoming.locals);
        const instruction = function.code[ip];
        try analysis.instruction(&working, instruction);
        if (analysis.malformed) break;
        for (instruction.successors(ip)) |successor| if (successor) |destination|
            try propagate(&analysis, states, &pending, &cells, destination, &working);
        if (analysis.malformed) break;
    }
    return analysis.finish(allocator, (function.result == .picture or function.result == .object or function.result == .any) and analysis.returned and analysis.all_returns_fresh);
}

fn propagate(analysis: *Analysis, states: []?State, pending: *std.ArrayList(usize), cells: *usize, ip: usize, incoming: *const State) !void {
    if (ip >= states.len) return analysis.invalid();
    const count = incoming.stack.items.len + incoming.locals.len;
    if (!analysis.budget.consume(count)) return analysis.invalid();
    if (states[ip]) |*state| {
        if (state.stack.items.len != incoming.stack.items.len or state.locals.len != incoming.locals.len) return analysis.invalid();
        var changed = false;
        for (state.stack.items, incoming.stack.items) |*destination, value| changed = destination.join(value) or changed;
        for (state.locals, incoming.locals) |*destination, value| changed = destination.join(value) or changed;
        if (changed) try pending.append(analysis.allocator, ip);
    } else {
        // A proof budget makes unusually large CFGs a serial fallback rather
        // than multiplying compiler memory by their local-variable count.
        if (count > limits.cells - @min(cells.*, limits.cells)) return analysis.invalid();
        cells.* += count;
        var stack: std.ArrayList(Value) = .empty;
        try stack.appendSlice(analysis.allocator, incoming.stack.items);
        states[ip] = .{ .stack = stack, .locals = try analysis.allocator.dupe(Value, incoming.locals) };
        try pending.append(analysis.allocator, ip);
    }
}

/// Analyze one straight RHS with an initially empty stack. Local execution
/// frames, jumps and settings changes must stay with the coordinating VM.
pub fn expression(allocator: Allocator, scratch_allocator: Allocator, program: *const bc.Program, summaries: []const Summary, code: []const bc.Instruction, remaining: *usize) Allocator.Error!?Summary {
    var temporary: std.heap.ArenaAllocator = .init(scratch_allocator);
    defer temporary.deinit();
    var budget: Budget = .{ .remaining = remaining.* };
    defer remaining.* = budget.remaining;
    if (!budget.consume(program.global_types.len) or !budget.consume(code.len)) return null;
    var analysis = try Analysis.init(temporary.allocator(), scratch_allocator, program, summaries, &budget);
    var state: State = .{ .locals = &.{} };
    for (code) |instruction| {
        switch (instruction.op) {
            .constant, .load_global, .pop, .duplicate, .add, .subtract, .multiply, .divide, .remainder, .power, .positive, .negate, .logical_not, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .call, .call_builtin, .check_module, .make_vec2, .make_vec3, .make_list, .bind_arguments, .index, .slice, .field => {},
            else => return null,
        }
        try analysis.instruction(&state, instruction);
        if (!analysis.safe or analysis.malformed) return null;
    }
    if (!analysis.saw_user_call or state.stack.items.len != 1 or !state.stack.items[0].fresh_owner) return null;
    if (state.stack.items[0].kind != .picture and state.stack.items[0].kind != .object) return null;
    return try analysis.finish(allocator, true);
}

test {
    _ = @import("effects/builtins.zig");
}
