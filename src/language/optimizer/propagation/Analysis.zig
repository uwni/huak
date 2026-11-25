//! The fixed-point abstract interpretation over one function's blocks: stack and binding facts per block, merged until they are stable.
const std = @import("std");
const bc = @import("../../bytecode.zig");
const values = @import("../value.zig");
const Allocator = std.mem.Allocator;
const Value = bc.Value;
const propagation = @import("../propagation.zig");
const Analysis = @This();

allocator: Allocator,
code: []const bc.Instruction,
constants: []const Value,
bindings: propagation.Bindings,
blocks: []propagation.Block,
owners: []usize,
replacements: []?Value,
pending: std.ArrayList(usize) = .empty,
stack: std.ArrayList(propagation.Fact) = .empty,
current: []propagation.Fact,
remaining: usize = propagation.limits.work,
cells: usize = 0,
invalid: bool = false,

fn charge(self: *Analysis, amount: usize) bool {
    if (amount > self.remaining) {
        self.invalid = true;
        return false;
    }
    self.remaining -= amount;
    return true;
}

fn push(self: *Analysis, fact: propagation.Fact) Allocator.Error!void {
    if (self.stack.items.len == propagation.limits.stack) {
        self.invalid = true;
        return;
    }
    try self.stack.append(self.allocator, fact);
}

fn pop(self: *Analysis) propagation.Fact {
    return self.stack.pop() orelse blk: {
        self.invalid = true;
        break :blk .{};
    };
}

fn unknownResult(self: *Analysis, instruction: bc.Instruction, result: propagation.Fact) Allocator.Error!void {
    const effect = instruction.stackEffect();
    if (effect.consumed > self.stack.items.len) {
        self.invalid = true;
        return;
    }
    self.stack.items.len -= effect.consumed;
    for (0..effect.produced) |_| try self.push(result);
}

fn forgetBindings(self: *Analysis) void {
    for (self.bindings.global_types, self.current[0..self.bindings.global_types.len]) |kind, *fact|
        fact.* = .{ .may_handle = propagation.mayHandle(kind) };
    for (self.bindings.local_types, self.current[self.bindings.global_types.len..]) |kind, *fact|
        fact.* = .{ .may_handle = propagation.mayHandle(kind) };
}

fn load(self: *Analysis, ip: usize, slot: usize) Allocator.Error!void {
    const fact = self.current[slot];
    // This is overwritten on every visit: a later loop/back-edge merge
    // which loses a fact must also revoke an earlier replacement.
    self.replacements[ip] = fact.value;
    try self.push(fact);
}

fn store(self: *Analysis, slot: usize, kind: bc.Type) void {
    self.current[slot] = propagation.preservedStore(kind, self.pop());
}

fn bindArguments(self: *Analysis, instruction: bc.Instruction) Allocator.Error!void {
    const binding = self.bindings.argument_bindings[instruction.a];
    const count = instruction.b;
    if (count > self.stack.items.len or !self.charge(count)) {
        self.invalid = true;
        return;
    }
    const ordered = try self.allocator.alloc(propagation.Fact, count);
    const offset = self.stack.items.len - count;
    for (self.stack.items[offset..], binding.slots) |fact, slot| ordered[slot] = fact;
    @memcpy(self.stack.items[offset..], ordered);
}

fn transfer(self: *Analysis, ip: usize) Allocator.Error!?bool {
    const instruction = self.code[ip];
    switch (instruction.op) {
        .constant => {
            const value = self.constants[instruction.a];
            try self.push(propagation.Fact.literal(value));
        },
        .load_global => try self.load(ip, instruction.a),
        .store_global => self.store(instruction.a, self.bindings.global_types[instruction.a]),
        .load_local => try self.load(ip, self.bindings.global_types.len + instruction.a),
        .store_local => self.store(self.bindings.global_types.len + instruction.a, self.bindings.local_types[instruction.a]),
        .pop => _ = self.pop(),
        .duplicate => {
            const fact = self.pop();
            try self.push(fact);
            try self.push(fact);
        },
        .bind_arguments => try self.bindArguments(instruction),
        .positive, .negate, .logical_not => {
            const operand = self.pop();
            if (instruction.op == .negate and operand.may_handle) self.forgetBindings();
            try self.push(.{
                .value = if (operand.value) |value| values.unary(instruction.op, value) else null,
                .may_handle = instruction.op != .logical_not and operand.may_handle,
            });
        },
        .add,
        .subtract,
        .multiply,
        .divide,
        .remainder,
        .power,
        .equal,
        .not_equal,
        .less,
        .less_equal,
        .greater,
        .greater_equal,
        .make_vec2,
        => {
            const right = self.pop();
            const left = self.pop();
            const native = switch (instruction.op) {
                .add, .subtract, .multiply, .divide, .remainder, .power => left.may_handle or right.may_handle,
                else => false,
            };
            if (native) self.forgetBindings();
            const result = if (left.value != null and right.value != null) values.binary(instruction.op, left.value.?, right.value.?) else null;
            try self.push(.{ .value = if (result != null and values.scalarValid(result.?)) result else null, .may_handle = native });
        },
        .make_vec3 => {
            const z = self.pop();
            const y = self.pop();
            const x = self.pop();
            const value = if (x.value != null and y.value != null and z.value != null)
                @import("../../numeric.zig").makeVector(3, .{ x.value.?, y.value.?, z.value.? }) catch null
            else
                null;
            try self.push(.{ .value = value });
        },
        .jump_if_false => {
            const condition = self.pop();
            return if (condition.value != null and condition.value.? == .boolean) condition.value.?.boolean else null;
        },
        .field => {
            const object = self.pop();
            const name = self.constants[instruction.a].string;
            if (if (object.value) |v| v.vectorField(name) else null) |component| {
                try self.push(propagation.Fact.literal(component));
            } else {
                // Unknown fields can enter a host callback. Source
                // constants already on the operand stack remain values.
                self.forgetBindings();
                try self.push(.{});
            }
        },
        .call, .call_value, .call_builtin, .typst, .typst_module, .import_module => {
            self.forgetBindings();
            try self.unknownResult(instruction, .{});
        },
        .iterate_init,
        .iterate_advance,
        .make_list,
        .make_dict,
        .make_record,
        .bind_function,
        .slice,
        => try self.unknownResult(instruction, .{ .may_handle = false }),
        .set_index, .set_field => {
            self.forgetBindings();
            try self.unknownResult(instruction, .{});
        },
        .iterate_test, .list_append, .index, .return_value => try self.unknownResult(instruction, .{}),
        .list_append_items => try self.unknownResult(instruction, .{}),
        .jump, .check_module, .halt => {},
    }
    return null;
}

fn merge(self: *Analysis, ip: usize) Allocator.Error!void {
    if (ip >= self.owners.len) {
        self.invalid = true;
        return;
    }
    const index = self.owners[ip];
    const block = &self.blocks[index];
    const count = self.current.len + self.stack.items.len;
    if (!self.charge(count)) return;
    var changed = false;
    if (block.input) |input| {
        if (input.len != count) {
            self.invalid = true;
            return;
        }
        for (input[0..self.current.len], self.current) |*fact, incoming| changed = propagation.join(fact, incoming) or changed;
        for (input[self.current.len..], self.stack.items) |*fact, incoming| changed = propagation.join(fact, incoming) or changed;
    } else {
        if (count > propagation.limits.cells - self.cells) {
            self.invalid = true;
            return;
        }
        const input = try self.allocator.alloc(propagation.Fact, count);
        self.cells += count;
        @memcpy(input[0..self.current.len], self.current);
        @memcpy(input[self.current.len..], self.stack.items);
        block.input = input;
        changed = true;
    }
    if (changed and !block.queued) {
        try self.pending.append(self.allocator, index);
        block.queued = true;
    }
}

pub fn run(self: *Analysis) Allocator.Error!bool {
    self.forgetBindings();
    try self.merge(0);
    while (self.pending.pop()) |index| {
        self.blocks[index].queued = false;
        const block = self.blocks[index];
        const input = block.input.?;
        if (!self.charge(input.len + block.end - block.start)) return false;
        @memcpy(self.current, input[0..self.current.len]);
        try self.stack.resize(self.allocator, input.len - self.current.len);
        @memcpy(self.stack.items, input[self.current.len..]);
        var condition: ?bool = null;
        for (block.start..block.end) |ip| {
            condition = try self.transfer(ip);
            if (self.invalid) return false;
        }
        const final = block.end - 1;
        const instruction = self.code[final];
        for (instruction.successors(final), 0..) |successor, edge| if (successor) |destination| {
            if (instruction.op == .jump_if_false and condition != null and edge != @intFromBool(condition.?)) continue;
            try self.merge(destination);
            if (self.invalid) return false;
        };
    }
    return !self.invalid;
}
