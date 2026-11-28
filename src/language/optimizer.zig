//! Conservative optimization of already checked, linked bytecode. This pass
//! never evaluates host operations or changes a reachable arithmetic failure.
const std = @import("std");
const bc = @import("bytecode.zig");
const Value = bc.Value;
const Instruction = bc.Instruction;
const Allocator = std.mem.Allocator;
const folding = @import("optimizer/folding.zig");
pub const Error = Allocator.Error || error{BytecodeCapacity};

const immutable = @import("optimizer/value.zig");
const propagation = @import("optimizer/propagation.zig");
const Key = immutable.Key;
const KeyContext = immutable.KeyContext;
const keyOf = immutable.keyOf;
const Intern = std.HashMapUnmanaged(Key, u32, KeyContext, 80);

/// An immutable-value index for one append-only constant pool. Share it across
/// functions and rounds, then release it before compacting or replacing the
/// pool. Keys borrow the pool's immutable values; no Program storage is owned.
pub const PoolIndex = struct {
    allocator: Allocator,
    map: Intern = .{},
    indexed_count: usize = 0,

    pub fn init(allocator: Allocator) PoolIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PoolIndex) void {
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sync(self: *PoolIndex, values: []const Value) Error!void {
        std.debug.assert(self.indexed_count <= values.len);
        while (self.indexed_count < values.len) : (self.indexed_count += 1) {
            const key = keyOf(values[self.indexed_count]) orelse continue;
            const index = std.math.cast(u32, self.indexed_count) orelse return error.BytecodeCapacity;
            const entry = try self.map.getOrPut(self.allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
    }

    pub fn intern(self: *PoolIndex, pool_allocator: Allocator, pool: *std.ArrayList(Value), value: Value) Error!u32 {
        const index = try internValue(self.allocator, pool_allocator, pool, &self.map, value);
        self.indexed_count = pool.items.len;
        return index;
    }
};

pub const Context = struct {
    global_types: []const bc.Type = &.{},
    local_types: []const bc.Type = &.{},
    argument_bindings: []const bc.ArgumentBinding = &.{},
    /// Backing allocator for per-round temporaries, separate from Program.
    scratch_allocator: ?Allocator = null,
    /// Optional index shared across functions using the same append-only pool.
    pool_index: ?*PoolIndex = null,
};
pub const limits = struct {
    pub const rounds = 32;
};

fn internValue(map_allocator: Allocator, pool_allocator: Allocator, pool: *std.ArrayList(Value), map: *Intern, value: Value) Error!u32 {
    const key = keyOf(value).?;
    if (map.get(key)) |index| return index;
    const index = std.math.cast(u32, pool.items.len) orelse return error.BytecodeCapacity;
    // Reserve both allocations before changing the pool or its shared index.
    try map.ensureUnusedCapacity(map_allocator, 1);
    try pool.append(pool_allocator, value);
    map.putAssumeCapacityNoClobber(key, index);
    return index;
}

/// Propagation exposes constants to folding and reachability; pruning can in
/// turn remove a conflicting incoming value. Repeat until the code stabilizes,
/// within a bounded number of rounds. Only the final code belongs to allocator.
pub fn optimize(allocator: Allocator, code: []const Instruction, constants: *std.ArrayList(Value), context: Context) Error![]const Instruction {
    const backing = context.scratch_allocator orelse allocator;
    var local_index: PoolIndex = .init(backing);
    defer local_index.deinit();
    const pool_index = context.pool_index orelse &local_index;
    var current = code;
    var owned: ?[]const Instruction = null;
    defer if (owned) |previous| backing.free(previous);
    for (0..limits.rounds) |_| {
        var temporary: std.heap.ArenaAllocator = .init(backing);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const propagated = try propagation.rewrite(scratch, current, allocator, constants, .{
            .global_types = context.global_types,
            .local_types = context.local_types,
            .argument_bindings = context.argument_bindings,
        });
        const rewritten = try folding.fold(scratch, propagated orelse current, allocator, constants, pool_index);
        if (sameCode(current, rewritten)) break;
        const next = try backing.dupe(Instruction, rewritten);
        if (owned) |previous| backing.free(previous);
        owned = next;
        current = next;
    }
    return allocator.dupe(Instruction, current);
}

pub fn sameCode(left: []const Instruction, right: []const Instruction) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn refersToConstant(op: bc.Op) bool {
    return switch (op) {
        .constant, .field, .set_field, .typst, .typst_module => true,
        else => false,
    };
}

/// Finalize all linked functions together: intern immutable scalar/string
/// values and remove unused constants. Arrays and native handles retain their
/// identities; floating keys preserve their exact bits, including signed zero.
pub fn compactConstants(allocator: Allocator, functions: []bc.Function, constants: *std.ArrayList(Value)) Error!void {
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var used = try scratch.alloc(bool, constants.items.len);
    @memset(used, false);
    for (functions) |function| for (function.code) |instruction| if (refersToConstant(instruction.op)) {
        if (instruction.a >= constants.items.len) return;
        used[instruction.a] = true;
    };
    var pool: std.ArrayList(Value) = .empty;
    errdefer pool.deinit(allocator);
    var map: Intern = .{};
    const indices = try scratch.alloc(u32, constants.items.len);
    for (constants.items, used, 0..) |value, keep, index| {
        if (!keep) continue;
        indices[index] = if (keyOf(value) != null)
            try internValue(scratch, allocator, &pool, &map, value)
        else blk: {
            const new_index = std.math.cast(u32, pool.items.len) orelse return error.BytecodeCapacity;
            try pool.append(allocator, value);
            break :blk new_index;
        };
    }
    // Stage all rewritten slices before mutating the linked Program so an
    // allocation failure cannot leave it referring to a half-compacted pool.
    const replacements = try scratch.alloc(?[]Instruction, functions.len);
    @memset(replacements, null);
    errdefer for (replacements) |replacement| if (replacement) |code| allocator.free(code);
    for (functions, replacements) |function, *replacement| {
        for (function.code) |instruction| if (refersToConstant(instruction.op) and indices[instruction.a] != instruction.a) {
            replacement.* = try allocator.dupe(Instruction, function.code);
            break;
        };
        if (replacement.*) |code| for (code) |*instruction| if (refersToConstant(instruction.op)) {
            instruction.a = indices[instruction.a];
        };
    }
    for (functions, replacements) |*function, replacement| if (replacement) |code| {
        function.code = code;
    };
    constants.deinit(allocator);
    constants.* = pool;
}

test {
    _ = @import("optimizer/folding_test.zig");
    _ = @import("optimizer/elision_test.zig");
    _ = @import("optimizer/pool_test.zig");
    _ = @import("optimizer/pipeline_test.zig");
}
