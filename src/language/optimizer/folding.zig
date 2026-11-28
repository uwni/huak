//! Constant folding, literal-append elision, static branch pruning and unreachable-code removal within one function.
const std = @import("std");
const bc = @import("../bytecode.zig");
const Value = bc.Value;
const Instruction = bc.Instruction;
const Allocator = std.mem.Allocator;
const immutable = @import("value.zig");
const keyOf = immutable.keyOf;
const scalarValid = immutable.scalarValid;
const unary = immutable.unary;
const binary = immutable.binary;
const optimizer = @import("../optimizer.zig");

fn isJump(op: bc.Op) bool {
    return op == .jump or op == .jump_if_false;
}

/// Fold only immutable operations whose exact VM result is known. A failed
/// operation remains in place so execution reports its original error/span.
pub fn fold(allocator: Allocator, code: []const Instruction, pool_allocator: Allocator, constants: *std.ArrayList(Value), pool_index: *optimizer.PoolIndex) optimizer.Error![]const Instruction {
    if (code.len == 0) return allocator.dupe(Instruction, code);
    // Malformed bytecode remains the VM's responsibility. Avoid changing its
    // error merely because this pass also serves low-level embedding callers.
    for (code) |instruction| {
        if ((isJump(instruction.op) and instruction.a >= code.len) or
            (instruction.op == .constant and instruction.a >= constants.items.len))
            return allocator.dupe(Instruction, code);
    }
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    try pool_index.sync(constants.items);
    const boundary = try scratch.alloc(bool, code.len);
    @memset(boundary, false);
    boundary[0] = true;
    for (code, 0..) |instruction, index| {
        if (isJump(instruction.op)) boundary[instruction.a] = true;
        if (isJump(instruction.op) or instruction.op == .return_value or instruction.op == .halt) {
            if (index + 1 < code.len) boundary[index + 1] = true;
        }
    }
    var rewritten: std.ArrayList(Instruction) = .empty;
    const old_to_new = try scratch.alloc(usize, code.len + 1);
    var block_start: usize = 0;
    for (code, 0..) |original, index| {
        if (boundary[index]) block_start = rewritten.items.len;
        old_to_new[index] = rewritten.items.len;
        var instruction = original;
        if (instruction.op == .constant) {
            if (keyOf(constants.items[instruction.a])) |key| instruction.a = pool_index.map.get(key).?;
            try rewritten.append(scratch, instruction);
            continue;
        }
        const available = rewritten.items.len - block_start;
        if (instruction.op == .list_append and available != 0) {
            const previous = &rewritten.items[rewritten.items.len - 1];
            if (previous.op == .make_list and previous.module == instruction.module and previous.span.end == instruction.span.end) {
                if (std.math.cast(u32, previous.span.start)) |start| {
                    // Both spans share their end. A block boundary excludes
                    // incoming jumps to append, so only one operation remains.
                    previous.* = .{ .op = .list_append_items, .a = previous.a, .b = start, .span = instruction.span, .module = instruction.module };
                    continue;
                }
            }
        }
        if (available >= 1 and rewritten.items[rewritten.items.len - 1].op == .constant) {
            const previous = rewritten.items[rewritten.items.len - 1];
            const value = constants.items[previous.a];
            if (instruction.op == .pop and scalarValid(value)) {
                rewritten.items.len -= 1;
                continue;
            }
            if (instruction.op == .duplicate and scalarValid(value)) {
                instruction = .{ .op = .constant, .a = previous.a, .span = original.span, .module = original.module };
                try rewritten.append(scratch, instruction);
                continue;
            }
            if (instruction.op == .jump_if_false and value == .boolean) {
                rewritten.items.len -= 1;
                if (!value.boolean) try rewritten.append(scratch, .{ .op = .jump, .a = original.a, .span = original.span, .module = original.module });
                continue;
            }
            if (unary(instruction.op, value)) |result| {
                const constant = try pool_index.intern(pool_allocator, constants, result);
                rewritten.items[rewritten.items.len - 1] = .{ .op = .constant, .a = constant, .span = original.span, .module = original.module };
                continue;
            }
        }
        if (available >= 2) {
            const left = rewritten.items[rewritten.items.len - 2];
            const right = rewritten.items[rewritten.items.len - 1];
            if (left.op == .constant and right.op == .constant) {
                if (binary(instruction.op, constants.items[left.a], constants.items[right.a])) |result| {
                    const constant = try pool_index.intern(pool_allocator, constants, result);
                    rewritten.items.len -= 2;
                    try rewritten.append(scratch, .{ .op = .constant, .a = constant, .span = original.span, .module = original.module });
                    continue;
                }
            }
        }
        if (instruction.op == .jump and instruction.a == index + 1) continue;
        try rewritten.append(scratch, instruction);
    }
    old_to_new[code.len] = rewritten.items.len;
    for (rewritten.items) |*instruction| if (isJump(instruction.op)) {
        instruction.a = std.math.cast(u32, old_to_new[instruction.a]) orelse return error.BytecodeCapacity;
    };
    return removeUnreachable(allocator, scratch, rewritten.items);
}

fn removeUnreachable(allocator: Allocator, scratch: Allocator, code: []const Instruction) optimizer.Error![]const Instruction {
    if (code.len == 0) return allocator.dupe(Instruction, code);
    const reachable = try scratch.alloc(bool, code.len);
    @memset(reachable, false);
    var pending: std.ArrayList(usize) = .empty;
    try pending.append(scratch, 0);
    while (pending.pop()) |start| {
        var current = start;
        while (current < code.len and !reachable[current]) : (current += 1) {
            reachable[current] = true;
            const instruction = code[current];
            switch (instruction.op) {
                .jump => {
                    try pending.append(scratch, instruction.a);
                    break;
                },
                .jump_if_false => try pending.append(scratch, instruction.a),
                .return_value, .halt => break,
                else => {},
            }
        }
    }
    // A jump into the next surviving instruction has the same effect as
    // fallthrough. Back edges and self-jumps remain budgeted instructions.
    var next: usize = code.len;
    var reverse = code.len;
    while (reverse != 0) {
        reverse -= 1;
        if (!reachable[reverse]) continue;
        if (code[reverse].op == .jump and code[reverse].a == next) {
            reachable[reverse] = false;
        } else next = reverse;
    }
    const positions = try scratch.alloc(u32, code.len + 1);
    var count: usize = 0;
    for (reachable, 0..) |keep, index| {
        positions[index] = std.math.cast(u32, count) orelse return error.BytecodeCapacity;
        if (keep) count += 1;
    }
    positions[code.len] = std.math.cast(u32, count) orelse return error.BytecodeCapacity;
    const result = try allocator.alloc(Instruction, count);
    var destination: usize = 0;
    for (code, reachable) |instruction, keep| {
        if (!keep) continue;
        result[destination] = instruction;
        if (isJump(instruction.op)) result[destination].a = positions[instruction.a];
        destination += 1;
    }
    return result;
}
