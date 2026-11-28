//! Forward immutable-value facts over executable bytecode edges. Analysis
//! failure or a proof budget never changes the language's execution limits.
const std = @import("std");
const bc = @import("../bytecode.zig");
const values = @import("value.zig");
const Allocator = std.mem.Allocator;
const Value = bc.Value;
const Analysis = @import("propagation/Analysis.zig");
pub const Fact = struct {
    value: ?Value = null,
    // Unknown numeric values still cannot enter Host.binary. Keep that
    // distinction so ordinary arithmetic does not discard loop invariants.
    may_handle: bool = true,

    pub fn literal(value: Value) Fact {
        return .{ .value = if (values.scalarValid(value)) value else null, .may_handle = value == .handle };
    }
};
pub const Error = Allocator.Error || error{BytecodeCapacity};
pub const Bindings = struct {
    global_types: []const bc.Type = &.{},
    local_types: []const bc.Type = &.{},
    argument_bindings: []const bc.ArgumentBinding = &.{},
};

/// These are optimizer proof limits, not script restrictions. Basic-block
/// states keep memory proportional to joins, and cells bounds the product of
/// those joins with bindings/stack values in unusually large functions.
pub const limits = struct {
    pub const instructions = 65_536;
    pub const bindings = 4_096;
    pub const stack = 4_096;
    pub const cells = 262_144;
    pub const work = 4_000_000;
};

pub const Block = struct {
    start: usize,
    end: usize,
    input: ?[]Fact = null,
    queued: bool = false,
};

/// Match VM storage only when no coercion changes the immutable value. The
/// VM remains the sole implementation of conversions and type diagnostics.
pub fn preservedStore(kind: bc.Type, fact: Fact) Fact {
    const unknown: Fact = .{ .may_handle = if (kind == .any) fact.may_handle else mayHandle(kind) };
    const value = fact.value orelse return unknown;
    if (!values.scalarValid(value) or !bc.Type.accepts(kind, value.valueType())) return unknown;
    if (kind == .number and value == .int) return unknown;
    if ((kind == .length or kind == .angle) and (value == .int or value == .number)) return unknown;
    return Fact.literal(value);
}

pub fn join(current: *Fact, incoming: Fact) bool {
    var changed = false;
    if (current.value != null and (incoming.value == null or !values.exactSame(current.value.?, incoming.value.?))) {
        current.value = null;
        changed = true;
    }
    if (!current.may_handle and incoming.may_handle) {
        current.may_handle = true;
        changed = true;
    }
    return changed;
}

pub fn mayHandle(kind: bc.Type) bool {
    return switch (kind) {
        .unit, .int, .number, .length, .angle, .quantity, .scalar, .boolean, .string, .vec2, .vec3, .list, .dict => false,
        else => !kind.isRecord(),
    };
}

fn valid(code: []const bc.Instruction, constants: []const Value, bindings: Bindings) bool {
    var remaining: usize = limits.work - @min(limits.work, code.len);
    for (code) |instruction| switch (instruction.op) {
        .constant => if (instruction.a >= constants.len) return false,
        .field, .set_field, .typst, .typst_module => if (instruction.a >= constants.len or constants[instruction.a] != .string) return false,
        .bind_arguments => {
            if (instruction.a >= bindings.argument_bindings.len) return false;
            const binding = bindings.argument_bindings[instruction.a];
            if (binding.slots.len != instruction.b or binding.parameter_count != instruction.b or instruction.b > limits.stack) return false;
            if (binding.slots.len > remaining) return false;
            remaining -= binding.slots.len;
            var supplied: std.bit_set.Static(limits.stack) = .empty;
            for (binding.slots) |slot| {
                if (slot >= instruction.b or supplied.isSet(slot)) return false;
                supplied.set(slot);
            }
        },
        .load_global, .store_global => if (instruction.a >= bindings.global_types.len) return false,
        .load_local, .store_local => if (instruction.a >= bindings.local_types.len) return false,
        .jump, .jump_if_false => if (instruction.a >= code.len) return false,
        else => {},
    };
    return true;
}

fn makeBlocks(allocator: Allocator, code: []const bc.Instruction, owners: []usize) Allocator.Error![]Block {
    const starts = try allocator.alloc(bool, code.len);
    @memset(starts, false);
    starts[0] = true;
    for (code, 0..) |instruction, ip| switch (instruction.op) {
        .jump, .jump_if_false => {
            starts[instruction.a] = true;
            if (ip + 1 < code.len) starts[ip + 1] = true;
        },
        .return_value, .halt => if (ip + 1 < code.len) {
            starts[ip + 1] = true;
        },
        else => {},
    };
    var blocks: std.ArrayList(Block) = .empty;
    for (starts, 0..) |start, ip| {
        if (start) {
            if (blocks.items.len != 0) blocks.items[blocks.items.len - 1].end = ip;
            try blocks.append(allocator, .{ .start = ip, .end = code.len });
        }
        owners[ip] = blocks.items.len - 1;
    }
    return blocks.toOwnedSlice(allocator);
}

/// Returned instructions belong to allocator. A null result leaves input and
/// constant pool untouched, including malformed or over-budget analysis.
/// Facts are never seeded from parameter defaults or another function's state.
pub fn rewrite(allocator: Allocator, code: []const bc.Instruction, pool_allocator: Allocator, constants: *std.ArrayList(Value), bindings: Bindings) Error!?[]bc.Instruction {
    const slots = std.math.add(usize, bindings.global_types.len, bindings.local_types.len) catch return null;
    if (code.len == 0 or code.len > limits.instructions or slots > limits.bindings or !valid(code, constants.items, bindings)) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const owners = try scratch.alloc(usize, code.len);
    const blocks = try makeBlocks(scratch, code, owners);
    const replacements = try scratch.alloc(?Value, code.len);
    @memset(replacements, null);
    var analysis: Analysis = .{
        .allocator = scratch,
        .code = code,
        .constants = constants.items,
        .bindings = bindings,
        .blocks = blocks,
        .owners = owners,
        .replacements = replacements,
        .current = try scratch.alloc(Fact, slots),
    };
    if (!try analysis.run()) return null;
    var changes: usize = 0;
    for (replacements) |fact| if (fact != null) {
        changes += 1;
    };
    if (changes == 0) return null;
    const result = try allocator.dupe(bc.Instruction, code);
    errdefer allocator.free(result);
    const original_constants = constants.items.len;
    errdefer constants.items.len = original_constants;
    for (result, replacements) |*instruction, fact| if (fact) |value| {
        const constant = std.math.cast(u32, constants.items.len) orelse return error.BytecodeCapacity;
        try constants.append(pool_allocator, value);
        instruction.* = .{ .op = .constant, .a = constant, .span = instruction.span, .module = instruction.module };
    };
    return result;
}

test {
    _ = @import("propagation_test.zig");
    _ = @import("propagation_limits_test.zig");
}
