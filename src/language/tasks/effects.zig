//! Conservative effect proofs for isolated picture builders. This analysis
//! never executes source code or a host callback. Loops and branches join their
//! operand stacks and local provenance until the bytecode CFG reaches a fixed
//! point; a mutable picture is writable only when every incoming value is fresh.
const std = @import("std");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Allocator = std.mem.Allocator;
const Type = bc.Type;

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
const Budget = struct {
    remaining: usize = limits.work,
    exhausted: bool = false,

    fn consume(self: *Budget, amount: usize) bool {
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

const Value = struct {
    kind: Type = .any,
    initialized: bool = false,
    fresh_owner: bool = false,
    callable: ?bc.types.Function = null,
    bound: ?*const Bound = null,

    const Bound = struct { target: bc.types.Function.Target, values: []const Value, names: []const ?[]const u8 };

    fn ordinary(kind: Type) Value {
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

const State = struct {
    stack: std.ArrayList(Value) = .empty,
    locals: []Value,

    fn pop(self: *State, analysis: *Analysis) Value {
        return self.stack.pop() orelse blk: {
            analysis.safe = false;
            analysis.malformed = true;
            break :blk .{};
        };
    }
};

const Analysis = struct {
    allocator: Allocator,
    program: *const bc.Program,
    summaries: []const Summary,
    budget: *Budget,
    reads: []bool,
    local_types: []const Type = &.{},
    safe: bool = true,
    malformed: bool = false,
    uses_typst: bool = false,
    returned: bool = false,
    all_returns_fresh: bool = true,
    saw_user_call: bool = false,
    observes_identity: bool = false,
    depth: usize = 0,

    fn init(allocator: Allocator, program: *const bc.Program, summaries: []const Summary, budget: *Budget) !Analysis {
        const reads = try allocator.alloc(bool, program.global_types.len);
        @memset(reads, false);
        return .{ .allocator = allocator, .program = program, .summaries = summaries, .budget = budget, .reads = reads };
    }

    fn observe(self: *Analysis, value: Value) void {
        if (!value.initialized or !supportedType(value.kind)) self.safe = false;
    }

    fn args(self: *Analysis, state: *State, count: u32) []const Value {
        if (count > state.stack.items.len) {
            self.safe = false;
            self.malformed = true;
            return &.{};
        }
        return state.stack.items[state.stack.items.len - count ..];
    }

    fn push(self: *Analysis, state: *State, value: Value) !void {
        try state.stack.append(self.allocator, value);
    }

    fn bindArguments(self: *Analysis, state: *State, instruction_: bc.Instruction) !void {
        if (instruction_.a >= self.program.argument_bindings.len) return self.invalid();
        const binding = self.program.argument_bindings[instruction_.a];
        if (binding.slots.len != instruction_.b or binding.parameter_count != instruction_.b) return self.invalid();
        const arguments = self.args(state, instruction_.b);
        if (self.malformed or !self.budget.consume(arguments.len)) return self.invalid();
        const ordered = try self.allocator.alloc(Value, arguments.len);
        const supplied = try self.allocator.alloc(bool, arguments.len);
        @memset(supplied, false);
        for (arguments, binding.slots) |value, slot| {
            if (slot >= arguments.len or supplied[slot]) return self.invalid();
            ordered[slot] = value;
            supplied[slot] = true;
        }
        @memcpy(state.stack.items[state.stack.items.len - arguments.len ..], ordered);
    }

    fn instruction(self: *Analysis, state: *State, instruction_: bc.Instruction) !void {
        if (!self.budget.consume(1)) return self.invalid();
        switch (instruction_.op) {
            .constant => {
                if (instruction_.a >= self.program.constants.len) return self.invalid();
                const constant = self.program.constants[instruction_.a];
                if (!constantSafe(constant)) self.safe = false;
                var value = Value.ordinary(constant.valueType());
                if (constant == .function and constant.function != .bound) value.callable = constant.function;
                try self.push(state, value);
            },
            .load_global => {
                if (instruction_.a >= self.program.global_types.len) return self.invalid();
                self.reads[instruction_.a] = true;
                const kind = self.program.global_types[instruction_.a];
                if (!supportedType(kind)) self.safe = false;
                try self.push(state, Value.ordinary(kind));
            },
            .load_local => {
                if (instruction_.a >= state.locals.len) return self.invalid();
                const value = state.locals[instruction_.a];
                self.observe(value);
                try self.push(state, value);
            },
            .store_local => {
                if (instruction_.a >= state.locals.len) return self.invalid();
                state.locals[instruction_.a] = state.pop(self);
                if (self.local_types[instruction_.a] != .any) state.locals[instruction_.a].kind = self.local_types[instruction_.a];
            },
            .pop => _ = state.pop(self),
            .duplicate => {
                const value = state.pop(self);
                try self.push(state, value);
                try self.push(state, value);
            },
            .bind_arguments => try self.bindArguments(state, instruction_),
            .list_append => {
                _ = state.pop(self);
                _ = state.pop(self);
                self.safe = false;
            },
            .list_append_items => {
                const arguments = self.args(state, instruction_.a);
                if (self.malformed) return;
                state.stack.items.len -= arguments.len;
                _ = state.pop(self);
                self.safe = false;
            },
            .set_index => {
                for (0..3) |_| _ = state.pop(self);
                self.safe = false;
            },
            .set_field => {
                if (instruction_.a >= self.program.constants.len or self.program.constants[instruction_.a] != .string) return self.invalid();
                _ = state.pop(self);
                _ = state.pop(self);
                self.safe = false;
            },
            .add, .subtract, .multiply, .divide, .remainder, .power => {
                const right = state.pop(self);
                const left = state.pop(self);
                self.observe(left);
                self.observe(right);
                const ordinary = (left.kind.isScalar() and right.kind.isScalar()) or
                    (left.kind.isVector() and (right.kind.isVector() or right.kind.isScalar())) or
                    (right.kind.isVector() and left.kind.isScalar()) or
                    (instruction_.op == .add and left.kind == .string and right.kind == .string);
                if (!ordinary) self.safe = false; // nativeBinary includes solver effects.
                const kind: Type = if (left.kind.isVector()) left.kind else if (right.kind.isVector()) right.kind else if (left.kind == .string and right.kind == .string) .string else joinType(left.kind, right.kind);
                try self.push(state, Value.ordinary(kind));
            },
            .positive, .negate, .logical_not => {
                var operand = state.pop(self);
                self.observe(operand);
                if (instruction_.op == .logical_not) {
                    operand = Value.ordinary(.boolean);
                } else if (!operand.kind.isScalar() and !operand.kind.isVector()) self.safe = false;
                try self.push(state, operand);
            },
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
                const right = state.pop(self);
                const left = state.pop(self);
                self.observe(left);
                self.observe(right);
                try self.push(state, Value.ordinary(.boolean));
            },
            .jump_if_false => {
                const condition = state.pop(self);
                self.observe(condition);
            },
            .iterate_init, .iterate_test, .iterate_advance => {
                if (instruction_.op == .iterate_init and instruction_.a == 1) {
                    const collection = state.pop(self);
                    self.observe(collection);
                    try self.push(state, Value.ordinary(.int));
                    try self.push(state, collection);
                    try self.push(state, Value.ordinary(.int));
                    return;
                }
                const step = state.pop(self);
                const stop = state.pop(self);
                const start = state.pop(self);
                for ([_]Value{ start, stop, step }) |value| {
                    if (!value.kind.isScalar() or !value.initialized) self.safe = false;
                }
                const kind = joinType(joinType(start.kind, stop.kind), step.kind);
                switch (instruction_.op) {
                    .iterate_init => for (0..3) |_| try self.push(state, Value.ordinary(kind)),
                    .iterate_test => {
                        try self.push(state, Value.ordinary(if (stop.kind == .list) .any else kind));
                        try self.push(state, Value.ordinary(.boolean));
                    },
                    .iterate_advance => {
                        try self.push(state, Value.ordinary(kind));
                        try self.push(state, Value.ordinary(.boolean));
                    },
                    else => unreachable,
                }
            },
            .call => {
                if (instruction_.a >= self.program.functions.len or instruction_.a >= self.summaries.len) return self.invalid();
                const callee = self.program.functions[instruction_.a];
                if (!callee.acceptsCount(instruction_.b)) return self.invalid();
                const arguments = self.args(state, instruction_.b);
                if (self.malformed) return;
                for (arguments) |arg| {
                    self.observe(arg);
                }
                const result = try self.userCall(instruction_.a, arguments);
                self.saw_user_call = true;
                state.stack.items.len -= instruction_.b;
                try self.push(state, result);
            },
            .call_value, .bind_function => {
                const effect = instruction_.stackEffect();
                if (effect.consumed > state.stack.items.len) return self.invalid();
                const values = state.stack.items[state.stack.items.len - effect.consumed ..];
                const function = values[0];
                const result = try self.apply(function, values[1..], instruction_);
                state.stack.items.len -= effect.consumed;
                try self.push(state, result);
            },
            .call_builtin => {
                const id = std.enums.fromInt(builtin.Id, instruction_.a) orelse return self.invalid();
                const signature = builtin.signature(id);
                if (!signature.acceptsCount(instruction_.b)) return self.invalid();
                const arguments = self.args(state, instruction_.b);
                if (self.malformed) return;
                const result = self.builtinResult(&signature, arguments);
                state.stack.items.len -= instruction_.b;
                try self.push(state, result);
            },
            .make_vec2, .make_vec3 => {
                const is_three = instruction_.op == .make_vec3;
                for (0..@as(usize, if (is_three) 3 else 2)) |_| {
                    if (!state.pop(self).kind.isScalar()) self.safe = false;
                }
                try self.push(state, Value.ordinary(if (is_three) .vec3 else .vec2));
            },
            .make_list => {
                const arguments = self.args(state, instruction_.a);
                if (self.malformed) return;
                for (arguments) |arg| {
                    self.observe(arg);
                }
                state.stack.items.len -= instruction_.a;
                try self.push(state, Value.ordinary(.list));
            },
            .make_dict, .make_record => {
                const effect = instruction_.stackEffect();
                const count = std.math.cast(u32, effect.consumed) orelse return self.invalid();
                const arguments = self.args(state, count);
                if (self.malformed) return;
                var kind: Type = .dict;
                if (instruction_.op == .make_record) {
                    if (instruction_.a >= self.program.records.len or self.program.records[instruction_.a].fields.len != instruction_.b) return self.invalid();
                    kind = Type.record(instruction_.a);
                }
                state.stack.items.len -= arguments.len;
                self.safe = false;
                try self.push(state, Value.ordinary(kind));
            },
            .index => {
                const index = state.pop(self);
                const list = state.pop(self);
                if (list.kind != .list or index.kind != .int) self.safe = false;
                // A list can contain aliases. Never promote its element to fresh.
                try self.push(state, Value.ordinary(.any));
            },
            .slice => {
                const step = state.pop(self);
                const stop = state.pop(self);
                const start = state.pop(self);
                const list = state.pop(self);
                const end_matches = switch (instruction_.a) {
                    0 => stop.kind == .int,
                    1 => stop.kind == .unit,
                    else => false,
                };
                if ((list.kind != .list and list.kind != .any) or start.kind != .int or
                    step.kind != .int or !end_matches) self.safe = false;
                // The container is new; its elements can still alias inputs.
                try self.push(state, Value.ordinary(.list));
            },
            .field => {
                const object = state.pop(self);
                if (instruction_.a >= self.program.constants.len or self.program.constants[instruction_.a] != .string) return self.invalid();
                const name = self.program.constants[instruction_.a].string;
                if (!object.kind.isVector() and object.kind != .text and object.kind != .picture and object.kind != .object and object.kind != .measure) self.safe = false;
                if (object.kind == .text) self.uses_typst = true;
                const raw_paths = object.kind.isObject() and std.mem.eql(u8, name, "paths");
                if (raw_paths) self.uses_typst = true;
                const kind = object.kind.fieldType(name) orelse invalid: {
                    self.safe = false;
                    break :invalid Type.any;
                };
                var value = Value.ordinary(kind);
                if (kind.isObject()) value.fresh_owner = object.fresh_owner;
                try self.push(state, value);
            },
            .typst => {
                self.uses_typst = true;
                const count = std.math.mul(u32, instruction_.b, 2) catch return self.invalid();
                const captures = self.args(state, count);
                if (captures.len != count) return self.invalid();
                var index: usize = 0;
                while (index < captures.len) : (index += 2) {
                    if (captures[index].kind != .string) self.safe = false;
                    switch (captures[index + 1].kind) {
                        .int, .number, .boolean, .string, .scalar, .length, .quantity, .color, .any => {},
                        else => self.safe = false,
                    }
                }
                state.stack.shrinkRetainingCapacity(state.stack.items.len - captures.len);
                try self.push(state, Value.ordinary(.text));
            },
            .check_module, .jump => {},
            .return_value => {
                const value = state.pop(self);
                self.observe(value);
                self.returned = true;
                self.all_returns_fresh = self.all_returns_fresh and value.fresh_owner and (value.kind == .picture or value.kind == .object or value.kind == .any);
                if (state.stack.items.len != 0) self.invalid();
            },
            .store_global => {
                _ = state.pop(self);
                self.safe = false;
            },
            // Import/setup/observable effects and global writes cannot be
            // replayed by an isolated worker. Unknown opcodes stay barriers.
            .import_module, .setup_typst, .halt => self.safe = false,
        }
    }

    fn userCall(self: *Analysis, index: u32, arguments: []const Value) Allocator.Error!Value {
        if (index >= self.summaries.len) {
            self.invalid();
            return .{};
        }
        const function = self.program.functions[index];
        var summary = self.summaries[index];
        if (!summary.safe and self.depth < limits.rounds) for (arguments) |arg| {
            if (arg.fresh_owner or arg.callable != null or arg.bound != null) {
                summary = try analyzeFunction(self.allocator, self.program, self.summaries, index, self.budget, arguments, self.depth + 1);
                break;
            }
        };
        _ = self.mergeSummary(summary);
        for (function.default_functions[@min(arguments.len, function.default_functions.len)..]) |default|
            if (default) |callee| {
                _ = self.mergeCall(callee);
            };
        var result = Value.ordinary(function.result);
        result.fresh_owner = summary.fresh_owner;
        self.saw_user_call = true;
        return result;
    }

    fn apply(self: *Analysis, value: Value, incoming: []const Value, instruction_: bc.Instruction) Allocator.Error!Value {
        const target = if (value.bound) |bound| bound.target else if (value.callable) |callable| callable.target() else {
            self.safe = false;
            if (instruction_.op == .call_value) self.observes_identity = true;
            return Value.ordinary(.any);
        };
        const names: []const []const u8, const variadic: bool = switch (target) {
            .bytecode => |index| blk: {
                if (index >= self.program.functions.len) {
                    self.invalid();
                    return .{};
                }
                const function = self.program.functions[index];
                break :blk .{ function.parameter_names[0..function.fixedCount()], function.variadic != null };
            },
            .native => |index| blk: {
                const id = std.enums.fromInt(builtin.Id, index) orelse {
                    self.invalid();
                    return .{};
                };
                const signature = builtin.signature(id);
                break :blk .{ signature.parameter_names, signature.variadic != null };
            },
        };
        if (instruction_.a > self.program.argument_names.len) {
            self.invalid();
            return .{};
        }
        const labels = if (instruction_.a == 0) &.{} else self.program.argument_names[instruction_.a - 1];
        const ordered = @import("../arguments.zig").bind(Value, self.allocator, names, variadic, if (value.bound) |bound| bound.values else &.{}, if (value.bound) |bound| bound.names else &.{}, incoming, labels) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.invalid();
                return .{};
            },
        };
        var count: usize = 0;
        var highest: usize = 0;
        for (ordered, 0..) |item, i| if (item != null) {
            count += 1;
            highest = i + 1;
        };
        if (instruction_.op == .bind_function) {
            const bound = try self.allocator.create(Value.Bound);
            const values = try self.allocator.alloc(Value, count);
            const bound_names = try self.allocator.alloc(?[]const u8, count);
            var next: usize = 0;
            for (ordered, 0..) |item, i| if (item) |arg| {
                values[next] = arg;
                bound_names[next] = if (i < names.len) names[i] else null;
                next += 1;
            };
            bound.* = .{ .target = target, .values = values, .names = bound_names };
            return .{ .kind = .function, .initialized = true, .bound = bound };
        }
        const arguments = try self.allocator.alloc(Value, highest);
        for (arguments, ordered[0..highest], 0..) |*arg, item, i| {
            arg.* = item orelse switch (target) {
                .native => Value.ordinary(.unit),
                .bytecode => |index| blk: {
                    const function = self.program.functions[index];
                    if (i < function.default_functions.len) if (function.default_functions[i]) |callee| break :blk try self.userCall(callee, &.{});
                    if (i < function.defaults.len) if (function.defaults[i]) |default| break :blk Value.ordinary(default.valueType());
                    self.invalid();
                    return .{};
                },
            };
        }
        return switch (target) {
            .bytecode => |index| try self.userCall(index, arguments),
            .native => |index| blk: {
                const signature = builtin.signature(std.enums.fromInt(builtin.Id, index).?);
                if (!signature.acceptsCount(arguments.len)) {
                    self.invalid();
                    return .{};
                }
                break :blk self.builtinResult(&signature, arguments);
            },
        };
    }

    fn builtinResult(self: *Analysis, signature: *const builtin.Signature, arguments: []const Value) Value {
        const id = signature.id;
        for (arguments) |arg| {
            // Unknown elements can be consumed by a fixed read-only signature;
            // dynamic arithmetic and mutable targets need stronger provenance.
            if (!arg.initialized) self.safe = false;
        }
        var result = Value.ordinary(signature.result);
        switch (id) {
            .print => {
                self.safe = false;
                if (arguments.len != 1 or !simpleType(arguments[0].kind)) self.observes_identity = true;
            },
            .solver, .unknown, .equation, .solve, .value => self.safe = false,
            // A script's random stream advances in source order, including
            // calls through aliases and helpers. It cannot be replayed by workers.
            .seed, .random, .randint, .randn => self.safe = false,
            .picture => result.fresh_owner = true,
            .object, .draw, .fill, .filldraw, .label => {
                result.fresh_owner = true;
                if (id == .label or (id == .object and arguments.len != 0 and (arguments[0].kind == .text or arguments[0].kind == .any))) self.uses_typst = true;
            },
            .append => {
                if (arguments.len < 2) {
                    self.safe = false;
                    return result;
                }
                result = arguments[1];
                if (!arguments[0].fresh_owner or !result.fresh_owner) self.safe = false;
            },
            .canvas, .timeline, .animate, .motion, .object_transform, .object_remove, .object_before, .object_style, .object_visible => {
                if (arguments.len == 0 or !arguments[0].fresh_owner or (arguments[0].kind != .picture and arguments[0].kind != .object and arguments[0].kind != .any)) self.safe = false;
                // Animation ownership is currently published on the serial path.
                if (id == .animate or id == .motion) self.safe = false;
                if (result.kind == .object and arguments.len != 0) result.fresh_owner = arguments[0].fresh_owner;
                if (id == .object_before and (arguments.len < 2 or !arguments[1].fresh_owner)) self.safe = false;
            },
            .to_string => {
                if (arguments.len != 1 or !simpleType(arguments[0].kind)) {
                    self.safe = false;
                    self.observes_identity = true;
                }
            },
            .dict_remove, .object_exclude => self.safe = false,
            .copy => {
                result.kind = arguments[0].kind;
                result.fresh_owner = result.kind.isObject();
                // Collection copies are shallow; copying an object clones its subtree.
                if (!supportedType(result.kind)) self.safe = false;
            },
            .width, .height, .baseline => self.uses_typst = true,
            .bounds => {
                if (arguments.len != 0 and arguments[0].kind.isObject()) self.uses_typst = true;
            },
            .outlines, .region, .snapshot, .object_clip => {
                if (id != .region) result.fresh_owner = true;
                if (arguments.len == 0) self.safe = false else switch (arguments[0].kind) {
                    .path, .path_or_shape => {},
                    .text, .object, .picture => self.uses_typst = true,
                    else => self.safe = false,
                }
            },
            .transformed => {
                result.kind = if (arguments.len != 0) arguments[0].kind else .any;
                result.fresh_owner = result.kind.isObject();
            },
            .mapped, .bent => {
                if (arguments.len < 2) self.safe = false else {
                    result.kind = arguments[0].kind;
                    // Any picture returned by a map is newly owned, including
                    // generic wrappers whose input type is checked at runtime.
                    result.fresh_owner = result.kind.isObject() or result.kind == .any;
                    if (result.kind != .path and result.kind != .path_or_shape and !result.kind.isObject() and result.kind != .any) self.safe = false;
                    if (id == .mapped) {
                        if (arguments[1].callable) |function| switch (function) {
                            .bytecode => |index| _ = self.mergeCall(index),
                            .native, .bound => self.safe = false,
                        } else if (arguments[1].kind != .transform) self.safe = false;
                    }
                }
            },
            else => {},
        }
        return result;
    }

    fn mergeCall(self: *Analysis, index: u32) Summary {
        if (index >= self.summaries.len) {
            self.invalid();
            return .{};
        }
        return self.mergeSummary(self.summaries[index]);
    }

    fn mergeSummary(self: *Analysis, summary: Summary) Summary {
        if (!self.budget.consume(summary.reads.len)) {
            self.invalid();
            return .{};
        }
        self.safe = self.safe and summary.safe;
        self.uses_typst = self.uses_typst or summary.uses_typst;
        self.observes_identity = self.observes_identity or summary.observes_identity;
        for (summary.reads) |global| {
            if (global >= self.reads.len) {
                self.invalid();
                return .{};
            }
            self.reads[global] = true;
        }
        return summary;
    }

    fn invalid(self: *Analysis) void {
        self.safe = false;
        self.malformed = true;
    }

    fn finish(self: *const Analysis, allocator: Allocator, fresh: bool) !Summary {
        var count: usize = 0;
        for (self.reads) |read| if (read) {
            count += 1;
        };
        const reads = try allocator.alloc(u32, count);
        var next: usize = 0;
        for (self.reads, 0..) |read, index| if (read) {
            reads[next] = @intCast(index);
            next += 1;
        };
        return .{ .safe = self.safe and !self.malformed, .fresh_owner = fresh and self.safe and !self.malformed, .reads = reads, .uses_typst = self.uses_typst, .observes_identity = self.observes_identity or self.malformed };
    }
};

fn supportedType(kind: Type) bool {
    return switch (kind) {
        .any, .unit, .int, .number, .length, .angle, .quantity, .scalar, .boolean, .string, .vec2, .vec3, .list, .path, .shape, .path_or_shape, .color, .pen, .transform, .text, .picture, .function, .measure, .object => true,
        else => false,
    };
}

fn simpleType(kind: Type) bool {
    return kind.isScalar() or switch (kind) {
        .unit, .boolean, .string, .vec2, .vec3, .object, .picture => true,
        else => false,
    };
}

fn constantSafe(value: bc.Value) bool {
    return switch (value) {
        .handle, .dict, .record, .object => false,
        .function => |function| function != .bound,
        .list => |list| blk: {
            if (list != .view) break :blk false;
            for (list.items()) |item| if (!constantSafe(item)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

fn joinType(a: Type, b: Type) Type {
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
pub fn observesIdentity(allocator: Allocator, program: *const bc.Program, summaries: []const Summary) Allocator.Error!bool {
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
        const summary = if (program.isEntry(index)) try analyzeFunction(allocator, program, summaries, index, &budget, null, 0) else summaries[index];
        if (budget.exhausted) return true;
        if (summary.observes_identity) return true;
    }
    return false;
}

/// The least fixed point admits only proven callees. Recursive SCCs therefore
/// remain serial in this first version, including recursion hidden by helpers.
pub fn analyze(allocator: Allocator, program: *const bc.Program) Allocator.Error!?[]const Summary {
    if (program.functions.len > limits.functions or program.global_types.len > limits.globals) return null;
    var instruction_count: usize = 0;
    for (program.functions) |function| {
        if (function.code.len > limits.instructions - instruction_count) return null;
        instruction_count += function.code.len;
    }
    var temporary: std.heap.ArenaAllocator = .init(allocator);
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
            const result = try analyzeFunction(scratch, program, summaries, @intCast(index), &budget, null, 0);
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

fn analyzeFunction(allocator: Allocator, program: *const bc.Program, summaries: []const Summary, index: u32, budget: *Budget, arguments: ?[]const Value, depth: usize) Allocator.Error!Summary {
    // Discard the per-function CFG after every pass instead of retaining its
    // stacks in the compilation arena across interprocedural iterations.
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    const function = program.functions[index];
    if (!budget.consume(function.code.len) or !budget.consume(function.local_types.len) or !budget.consume(program.global_types.len)) return .{};
    var analysis = try Analysis.init(scratch, program, summaries, budget);
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
pub fn expression(allocator: Allocator, program: *const bc.Program, summaries: []const Summary, code: []const bc.Instruction, remaining: *usize) Allocator.Error!?Summary {
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    var budget: Budget = .{ .remaining = remaining.* };
    defer remaining.* = budget.remaining;
    if (!budget.consume(program.global_types.len) or !budget.consume(code.len)) return null;
    var analysis = try Analysis.init(temporary.allocator(), program, summaries, &budget);
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

test "dictionary reads and shallow copies never create fresh picture provenance" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var program: bc.Program = .{
        .arena = .init(std.testing.allocator),
        .source_text = "",
        .name = "effects",
        .functions = &.{},
        .constants = &.{},
        .parameters = &.{},
        .global_names = &.{},
        .global_types = &.{},
        .readonly_globals = &.{},
    };
    defer program.deinit();
    var budget: Budget = .{};
    var analysis = try Analysis.init(arena.allocator(), &program, &.{}, &budget);
    const dictionary = Value.ordinary(.dict);
    const key = Value.ordinary(.string);
    const contains = analysis.builtinResult(&builtin.signature(.dict_contains), &.{ dictionary, key });
    try std.testing.expect(analysis.safe);
    try std.testing.expectEqual(Type.boolean, contains.kind);
    try std.testing.expect(!contains.fresh_owner);
    const keys = analysis.builtinResult(&builtin.signature(.dict_keys), &.{dictionary});
    try std.testing.expect(analysis.safe);
    try std.testing.expectEqual(Type.list, keys.kind);
    try std.testing.expect(!keys.fresh_owner);
    var picture = Value.ordinary(.picture);
    picture.fresh_owner = true;
    const copied_picture = analysis.builtinResult(&builtin.signature(.copy), &.{picture});
    try std.testing.expectEqual(Type.picture, copied_picture.kind);
    try std.testing.expect(copied_picture.fresh_owner);
    const copied_list = analysis.builtinResult(&builtin.signature(.copy), &.{Value.ordinary(.list)});
    try std.testing.expectEqual(Type.list, copied_list.kind);
    try std.testing.expect(!copied_list.fresh_owner);
    _ = analysis.builtinResult(&builtin.signature(.dict_remove), &.{ dictionary, key });
    try std.testing.expect(!analysis.safe);
    try std.testing.expect(!supportedType(Type.record(0)));
    try std.testing.expect(!supportedType(@fromBackingInt(0xffff)));
}
