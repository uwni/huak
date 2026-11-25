//! Instructions that move or build values: constants, loads and stores,
//! operators, lists, dictionaries, records and fields, and Typst blocks; for
//! each, the stack it leaves, the provenance of what it pushes, and whether
//! it is a barrier to tasks.
const std = @import("std");
const bc = @import("../../bytecode.zig");
const Type = bc.Type;
const effects = @import("../effects.zig");
const Analysis = @import("Analysis.zig");
const State = effects.State;
const Value = effects.Value;
const supportedType = effects.supportedType;
const joinType = effects.joinType;

/// Constants, loads and stores, stack shuffles and argument binding.
pub fn variable(self: *Analysis, state: *State, instruction_: bc.Instruction, comptime op: bc.Op) !void {
    switch (op) {
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
        .bind_arguments => try bindArguments(self, state, instruction_),
        .store_global => {
            _ = state.pop(self);
            self.safe = false;
        },
        else => comptime unreachable,
    }
}

/// Arithmetic, the unary operators and comparisons.
pub fn operator(self: *Analysis, state: *State, instruction_: bc.Instruction, comptime op: bc.Op) !void {
    switch (op) {
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
        else => comptime unreachable,
    }
}

/// Appends to lists, writes by index and field, vectors, lists,
/// dictionaries and records, and reads by index, slice and field.
pub fn aggregate(self: *Analysis, state: *State, instruction_: bc.Instruction, comptime op: bc.Op) !void {
    switch (op) {
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
            if (!object.kind.isVector() and object.kind != .text and object.kind != .picture and object.kind != .object and object.kind != .measure and object.kind != .anchor) self.safe = false;
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
        else => comptime unreachable,
    }
}

/// Typst blocks and modules.
pub fn typst(self: *Analysis, state: *State, instruction_: bc.Instruction, comptime op: bc.Op) !void {
    switch (op) {
        // Workers read the modules made before their group; a module made
        // in a task stays in the worker, since only the task's picture escapes.
        .typst, .typst_module => {
            self.uses_typst = true;
            // A module's name precedes its captured pairs.
            const named = instruction_.op == .typst_module;
            const count = @as(u32, instruction_.typstCaptures().pairs) * 2 + @intFromBool(named);
            const operands = self.args(state, count);
            if (operands.len != count) return self.invalid();
            if (named and operands[0].kind != .string) self.safe = false;
            const captures = operands[@intFromBool(named)..];
            var index: usize = 0;
            while (index < captures.len) : (index += 2) {
                if (captures[index].kind != .string) self.safe = false;
                switch (captures[index + 1].kind) {
                    .int, .number, .boolean, .string, .scalar, .length, .quantity, .color, .typst_module, .any => {},
                    else => self.safe = false,
                }
            }
            state.stack.shrinkRetainingCapacity(state.stack.items.len - operands.len);
            try self.push(state, Value.ordinary(if (named) .typst_module else .text));
        },
        else => comptime unreachable,
    }
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
