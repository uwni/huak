//! Conservative optimization of already checked, linked bytecode. This pass
//! never evaluates host operations or changes a reachable arithmetic failure.
const std = @import("std");
const bc = @import("bytecode.zig");
const Value = bc.Value;
const types = @import("types.zig");
const units = types.units;
const Instruction = bc.Instruction;
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error || error{BytecodeCapacity};

const immutable = @import("optimizer/value.zig");
const propagation = @import("optimizer/propagation.zig");
const Key = immutable.Key;
const KeyContext = immutable.KeyContext;
const keyOf = immutable.keyOf;
const scalarValid = immutable.scalarValid;
const unary = immutable.unary;
const binary = immutable.binary;
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

    fn sync(self: *PoolIndex, values: []const Value) Error!void {
        std.debug.assert(self.indexed_count <= values.len);
        while (self.indexed_count < values.len) : (self.indexed_count += 1) {
            const key = keyOf(values[self.indexed_count]) orelse continue;
            const index = std.math.cast(u32, self.indexed_count) orelse return error.BytecodeCapacity;
            const entry = try self.map.getOrPut(self.allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
    }

    fn intern(self: *PoolIndex, pool: *std.array_list.Managed(Value), value: Value) Error!u32 {
        const index = try internValue(self.allocator, pool, &self.map, value);
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

fn internValue(allocator: Allocator, pool: *std.array_list.Managed(Value), map: *Intern, value: Value) Error!u32 {
    const key = keyOf(value) orelse unreachable;
    if (map.get(key)) |index| return index;
    const index = std.math.cast(u32, pool.items.len) orelse return error.BytecodeCapacity;
    // Reserve both allocations before changing the pool or its shared index.
    try map.ensureUnusedCapacity(allocator, 1);
    try pool.append(value);
    map.putAssumeCapacityNoClobber(key, index);
    return index;
}

fn isJump(op: bc.Op) bool {
    return op == .jump or op == .jump_if_false;
}

/// Propagation exposes constants to folding and reachability; pruning can in
/// turn remove a conflicting incoming value. Repeat until the code stabilizes,
/// within a bounded number of rounds. Only the final code belongs to allocator.
pub fn optimize(allocator: Allocator, code: []const Instruction, constants: *std.array_list.Managed(Value), context: Context) Error![]const Instruction {
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
        const propagated = try propagation.rewrite(scratch, current, constants, .{
            .global_types = context.global_types,
            .local_types = context.local_types,
            .argument_bindings = context.argument_bindings,
        });
        const rewritten = try fold(scratch, propagated orelse current, constants, pool_index);
        if (sameCode(current, rewritten)) break;
        const next = try backing.dupe(Instruction, rewritten);
        if (owned) |previous| backing.free(previous);
        owned = next;
        current = next;
    }
    return allocator.dupe(Instruction, current);
}

fn sameCode(left: []const Instruction, right: []const Instruction) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

/// Fold only immutable operations whose exact VM result is known. A failed
/// operation remains in place so execution reports its original error/span.
fn fold(allocator: Allocator, code: []const Instruction, constants: *std.array_list.Managed(Value), pool_index: *PoolIndex) Error![]const Instruction {
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
    var rewritten: std.array_list.Managed(Instruction) = .init(scratch);
    const old_to_new = try scratch.alloc(usize, code.len + 1);
    var block_start: usize = 0;
    for (code, 0..) |original, index| {
        if (boundary[index]) block_start = rewritten.items.len;
        old_to_new[index] = rewritten.items.len;
        var instruction = original;
        if (instruction.op == .constant) {
            if (keyOf(constants.items[instruction.a])) |key| instruction.a = pool_index.map.get(key).?;
            try rewritten.append(instruction);
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
                try rewritten.append(instruction);
                continue;
            }
            if (instruction.op == .jump_if_false and value == .boolean) {
                rewritten.items.len -= 1;
                if (!value.boolean) try rewritten.append(.{ .op = .jump, .a = original.a, .span = original.span, .module = original.module });
                continue;
            }
            if (unary(instruction.op, value)) |result| {
                const constant = try pool_index.intern(constants, result);
                rewritten.items[rewritten.items.len - 1] = .{ .op = .constant, .a = constant, .span = original.span, .module = original.module };
                continue;
            }
        }
        if (available >= 2) {
            const left = rewritten.items[rewritten.items.len - 2];
            const right = rewritten.items[rewritten.items.len - 1];
            if (left.op == .constant and right.op == .constant) {
                if (binary(instruction.op, constants.items[left.a], constants.items[right.a])) |result| {
                    const constant = try pool_index.intern(constants, result);
                    rewritten.items.len -= 2;
                    try rewritten.append(.{ .op = .constant, .a = constant, .span = original.span, .module = original.module });
                    continue;
                }
            }
        }
        if (instruction.op == .jump and instruction.a == index + 1) continue;
        try rewritten.append(instruction);
    }
    old_to_new[code.len] = rewritten.items.len;
    for (rewritten.items) |*instruction| if (isJump(instruction.op)) {
        instruction.a = std.math.cast(u32, old_to_new[instruction.a]) orelse return error.BytecodeCapacity;
    };
    return removeUnreachable(allocator, scratch, rewritten.items);
}

fn removeUnreachable(allocator: Allocator, scratch: Allocator, code: []const Instruction) Error![]const Instruction {
    if (code.len == 0) return allocator.dupe(Instruction, code);
    const reachable = try scratch.alloc(bool, code.len);
    @memset(reachable, false);
    var pending: std.array_list.Managed(usize) = .init(scratch);
    try pending.append(0);
    while (pending.pop()) |start| {
        var current = start;
        while (current < code.len and !reachable[current]) : (current += 1) {
            reachable[current] = true;
            const instruction = code[current];
            switch (instruction.op) {
                .jump => {
                    try pending.append(instruction.a);
                    break;
                },
                .jump_if_false => try pending.append(instruction.a),
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

fn refersToConstant(op: bc.Op) bool {
    return switch (op) {
        .constant, .field, .set_field, .typst, .typst_module => true,
        else => false,
    };
}

/// Finalize all linked functions together: intern immutable scalar/string
/// values and remove unused constants. Arrays and native handles retain their
/// identities; floating keys preserve their exact bits, including signed zero.
pub fn compactConstants(allocator: Allocator, functions: []bc.Function, constants: *std.array_list.Managed(Value)) Error!void {
    var temporary: std.heap.ArenaAllocator = .init(allocator);
    defer temporary.deinit();
    const scratch = temporary.allocator();
    var used = try scratch.alloc(bool, constants.items.len);
    @memset(used, false);
    for (functions) |function| for (function.code) |instruction| if (refersToConstant(instruction.op)) {
        if (instruction.a >= constants.items.len) return;
        used[instruction.a] = true;
    };
    var pool: std.array_list.Managed(Value) = .init(allocator);
    errdefer pool.deinit();
    var map: Intern = .{};
    const indices = try scratch.alloc(u32, constants.items.len);
    for (constants.items, used, 0..) |value, keep, index| {
        if (!keep) continue;
        indices[index] = if (keyOf(value) != null)
            try internValue(scratch, &pool, &map, value)
        else blk: {
            const new_index = std.math.cast(u32, pool.items.len) orelse return error.BytecodeCapacity;
            try pool.append(value);
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
    constants.deinit();
    constants.* = pool;
}

const TestResult = union(enum) { value: Value, failure: bc.source.Diagnostic };
fn runTest(code: []const Instruction, constants: []const Value, execution_limits: @import("Machine.zig").Limits, host: @import("Machine.zig").Host) !TestResult {
    const Machine = @import("Machine.zig");
    var program: bc.Program = .{
        .arena = .init(std.testing.allocator),
        .source_text = "",
        .name = "optimizer-test.huak",
        .functions = &.{.{ .name = "<script>", .code = code, .parameters = &.{}, .result = .unit, .local_types = &.{} }},
        .constants = constants,
        .parameters = &.{},
        .global_names = &.{"result"},
        .global_types = &.{.any},
        .readonly_globals = &.{false},
    };
    defer program.deinit();
    var machine = try Machine.init(std.testing.allocator, &program, host, execution_limits);
    defer machine.deinit();
    _ = machine.execute(&.{}) catch |err| {
        if (err == error.RuntimeFailed) return .{ .failure = machine.failure.?.diagnostic };
        return err;
    };
    return .{ .value = machine.getGlobal("result") orelse .unit };
}

fn expectSame(before: []const Instruction, after: []const Instruction, constants: []const Value) !void {
    const original = try runTest(before, constants, .{}, .{});
    const optimized = try runTest(after, constants, .{}, .{});
    try std.testing.expectEqual(std.meta.activeTag(original), std.meta.activeTag(optimized));
    switch (original) {
        .value => |value| try std.testing.expectEqualDeep(value, optimized.value),
        .failure => |failure| {
            try std.testing.expectEqualStrings(failure.text(), optimized.failure.text());
            try std.testing.expectEqualDeep(failure.span, optimized.failure.span);
        },
    }
}

test "literal append elision combines one operation with both spans and nested construction" {
    for ([_]u32{ 0, 1, 3 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var pool = std.array_list.Managed(Value).init(arena.allocator());
        try pool.append(.{ .int = 7 });
        var code = std.array_list.Managed(Instruction).init(arena.allocator());
        try code.append(.{ .op = .load_global });
        for (0..count) |_| try code.append(.{ .op = .constant });
        const prepare_span: bc.Span = .{ .start = 5, .end = 10 };
        const append_span: bc.Span = .{ .start = 1, .end = 10 };
        try code.appendSlice(&.{ .{ .op = .make_list, .a = count, .span = prepare_span }, .{ .op = .list_append, .span = append_span }, .{ .op = .halt } });
        const result = try optimize(arena.allocator(), code.items, &pool, .{ .global_types = &.{.list} });
        try std.testing.expectEqual(code.items.len - 1, result.len);
        const append = result[result.len - 2];
        try std.testing.expectEqual(bc.Op.list_append_items, append.op);
        try std.testing.expectEqual(count, append.a);
        try std.testing.expectEqual(prepare_span.start, append.b);
        try std.testing.expectEqualDeep(append_span, append.span);
        try std.testing.expectEqualDeep(Instruction.StackEffect{ .consumed = @as(usize, count) + 1, .produced = 0 }, append.stackEffect());
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    try pool.append(.{ .int = 7 });
    const nested = [_]Instruction{ .{ .op = .load_global }, .{ .op = .constant }, .{ .op = .make_list, .a = 1 }, .{ .op = .make_list, .a = 1 }, .{ .op = .list_append }, .{ .op = .halt } };
    const result = try optimize(arena.allocator(), &nested, &pool, .{ .global_types = &.{.list} });
    try std.testing.expectEqual(bc.Op.make_list, result[2].op);
    try std.testing.expectEqual(bc.Op.list_append_items, result[3].op);
}

test "literal append elision retains original code when both spans cannot be represented" {
    const wide = std.math.add(usize, std.math.maxInt(u32), 1) catch return;
    for ([_]bc.Span{ .{ .start = 5, .end = 9 }, .{ .start = wide, .end = wide + 5 } }) |rhs| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var pool = std.array_list.Managed(Value).init(arena.allocator());
        const code = [_]Instruction{
            .{ .op = .load_global },                                                                         .{ .op = .make_list, .span = rhs },
            .{ .op = .list_append, .span = .{ .start = 1, .end = if (rhs.start == wide) rhs.end else 10 } }, .{ .op = .halt },
        };
        try std.testing.expectEqualDeep(&code, try optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{.list} }));
    }
}

test "literal append elision remaps forward branches and loop back edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    const code = [_]Instruction{
        .{ .op = .load_global, .a = 1 }, .{ .op = .jump_if_false, .a = 6 },
        .{ .op = .load_global },         .{ .op = .make_list },
        .{ .op = .list_append },         .{ .op = .jump, .a = 0 },
        .{ .op = .halt },
    };
    const result = try optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{ .list, .boolean } });
    try std.testing.expectEqual(@as(usize, code.len - 1), result.len);
    try std.testing.expectEqual(@as(u32, 5), result[1].a);
    try std.testing.expectEqual(bc.Op.list_append_items, result[3].op);
    try std.testing.expectEqual(bc.Op.jump, result[4].op);
    try std.testing.expectEqual(@as(u32, 0), result[4].a);
}

test "literal append elision does not cross an incoming branch to append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = std.array_list.Managed(Value).init(arena.allocator());
    const code = [_]Instruction{
        .{ .op = .load_global, .a = 0 },   .{ .op = .load_global, .a = 1 }, .{ .op = .load_global, .a = 2 },
        .{ .op = .jump_if_false, .a = 5 }, .{ .op = .make_list, .a = 1 },   .{ .op = .list_append },
        .{ .op = .halt },
    };
    const result = try optimize(arena.allocator(), &code, &pool, .{ .global_types = &.{ .list, .any, .boolean } });
    try std.testing.expectEqual(bc.Op.make_list, result[4].op);
    try std.testing.expectEqual(bc.Op.list_append, result[5].op);
}

test "constant folding keeps exact integers floats booleans and error behavior" {
    const cases = [_]struct { left: Value, right: Value, op: bc.Op, folds: bool }{
        .{ .left = .{ .int = 20 }, .right = .{ .int = 22 }, .op = .add, .folds = true },
        .{ .left = .{ .int = 3 }, .right = .{ .int = 7 }, .op = .multiply, .folds = true },
        .{ .left = .{ .int = 1 }, .right = .{ .int = 4 }, .op = .divide, .folds = true },
        .{ .left = .{ .number = -0.0 }, .right = .{ .number = 0.0 }, .op = .subtract, .folds = true },
        .{ .left = .{ .int = 9007199254740993 }, .right = .{ .number = 9007199254740992.0 }, .op = .greater, .folds = true },
        .{ .left = .{ .int = 9007199254740993 }, .right = .{ .number = 9007199254740992.0 }, .op = .equal, .folds = true },
        .{ .left = .{ .boolean = true }, .right = .{ .boolean = false }, .op = .not_equal, .folds = true },
        .{ .left = .{ .int = std.math.maxInt(i64) }, .right = .{ .int = 1 }, .op = .add, .folds = false },
        .{ .left = .{ .int = std.math.minInt(i64) }, .right = .{ .int = -1 }, .op = .remainder, .folds = true },
        .{ .left = .{ .int = 1 }, .right = .{ .int = 0 }, .op = .divide, .folds = false },
        .{ .left = .{ .number = 1e308 }, .right = .{ .number = 2 }, .op = .multiply, .folds = false },
        .{ .left = .{ .number = -1 }, .right = .{ .number = 0.5 }, .op = .power, .folds = false },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        try pool.appendSlice(&.{ case.left, case.right });
        const code = [_]Instruction{
            .{ .op = .constant, .a = 0, .span = .{ .start = 1, .end = 2 } },
            .{ .op = .constant, .a = 1, .span = .{ .start = 3, .end = 4 } },
            .{ .op = case.op, .span = .{ .start = 1, .end = 4 } },
            .{ .op = .store_global, .a = 0 },
            .{ .op = .halt },
        };
        const result = try optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, if (case.folds) 3 else 5), result.len);
        try expectSame(&code, result, pool.items);
        if (case.folds and case.op == .subtract) {
            const bits: u64 = @bitCast((try runTest(result, pool.items, .{}, .{})).value.number);
            try std.testing.expectEqual(@as(u64, 1) << 63, bits);
        }
    }
}

test "quantity folding preserves dimensions errors and constant identities" {
    const cases = [_]struct { left: Value, right: Value, op: bc.Op, folds: bool }{
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .quantity = try units.applyUnit(10, .mm) }, .op = .equal, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2 * std.math.pi, .rad) }, .right = .{ .quantity = try units.applyUnit(360, .deg) }, .op = .equal, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2, .cm) }, .right = .{ .quantity = try units.applyUnit(2, .mm) }, .op = .divide, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(2, .cm) }, .right = .{ .quantity = try units.applyUnit(2, .mm) }, .op = .multiply, .folds = true },
        .{ .left = .{ .int = 0 }, .right = .{ .quantity = try units.applyUnit(2, .cm) }, .op = .make_vec2, .folds = true },
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .quantity = try units.applyUnit(1, .deg) }, .op = .add, .folds = false },
        .{ .left = .{ .quantity = try units.applyUnit(1, .cm) }, .right = .{ .int = 0 }, .op = .divide, .folds = false },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        try pool.appendSlice(&.{ case.left, case.right });
        const code = [_]Instruction{
            .{ .op = .constant, .a = 0 },                          .{ .op = .constant, .a = 1 },
            .{ .op = case.op, .span = .{ .start = 3, .end = 7 } }, .{ .op = .store_global },
            .{ .op = .halt },
        };
        const optimized = try optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, if (case.folds) 3 else 5), optimized.len);
        try expectSame(&code, optimized, pool.items);
    }
    const magnitude: f64 = 1;
    const distance = keyOf(.{ .quantity = .{ .value = magnitude, .dimension = .distance } }).?;
    const rotation = keyOf(.{ .quantity = .{ .value = magnitude, .dimension = .rotation } }).?;
    try std.testing.expect(!KeyContext.eql(.{}, distance, rotation));
    const positive_zero = keyOf(.{ .quantity = .{ .value = 0.0, .dimension = .distance } }).?;
    const negative_zero = keyOf(.{ .quantity = .{ .value = -0.0, .dimension = .distance } }).?;
    try std.testing.expect(!KeyContext.eql(.{}, positive_zero, negative_zero));
}

test "static branch pruning retains host effects only on reachable paths" {
    const Log = struct {
        calls: usize = 0,
        fn call(context: ?*anyopaque, _: Allocator, _: @import("builtin.zig").Id, _: []const Value, _: ?*@import("Machine.zig")) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .unit;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .boolean = false }, .{ .int = 10 }, .{ .int = 32 } });
    const code = [_]Instruction{
        .{ .op = .constant, .a = 0 },
        .{ .op = .jump_if_false, .a = 5 },
        .{ .op = .constant, .a = 1 },
        .{ .op = .call_builtin, .a = @backingInt(@import("builtin.zig").Id.print), .b = 1 },
        .{ .op = .pop },
        .{ .op = .constant, .a = 1 },
        .{ .op = .call_builtin, .a = @backingInt(@import("builtin.zig").Id.print), .b = 1 },
        .{ .op = .pop },
        .{ .op = .constant, .a = 1 },
        .{ .op = .constant, .a = 2 },
        .{ .op = .add },
        .{ .op = .store_global, .a = 0 },
        .{ .op = .halt },
    };
    const result = try optimize(arena.allocator(), &code, &pool, .{});
    try std.testing.expect(result.len < code.len);
    var before: Log = .{};
    var after: Log = .{};
    const original = try runTest(&code, pool.items, .{}, .{ .ptr = &before, .vtable = &.{ .call_builtin = Log.call } });
    const optimized = try runTest(result, pool.items, .{}, .{ .ptr = &after, .vtable = &.{ .call_builtin = Log.call } });
    try std.testing.expectEqual(@as(usize, 1), before.calls);
    try std.testing.expectEqual(before.calls, after.calls);
    try std.testing.expectEqualDeep(original.value, optimized.value);
}

test "jump targets form barriers and optimized back edges retain instruction limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.append(.{ .int = 1 });
    // The jump enters at the second constant. Folding across that entry would
    // turn a runtime stack error into a successful computation.
    const incoming = [_]Instruction{
        .{ .op = .jump, .a = 2 },                           .{ .op = .constant },     .{ .op = .constant },
        .{ .op = .add, .span = .{ .start = 8, .end = 9 } }, .{ .op = .store_global }, .{ .op = .halt },
    };
    try expectSame(&incoming, try optimize(arena.allocator(), &incoming, &pool, .{}), pool.items);
    const loop = [_]Instruction{
        .{ .op = .constant }, .{ .op = .pop }, .{ .op = .jump, .a = 0 },
    };
    const optimized = try optimize(arena.allocator(), &loop, &pool, .{});
    try std.testing.expectEqual(@as(usize, 1), optimized.len);
    try std.testing.expectEqual(bc.Op.jump, optimized[0].op);
    const stopped = try runTest(optimized, pool.items, .{ .instructions = 10 }, .{});
    try std.testing.expect(stopped == .failure);
    try std.testing.expect(std.mem.indexOf(u8, stopped.failure.text(), "instruction limit") != null);
}

test "constant pool compaction merges exact values and preserves signed zero and identities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pool: std.array_list.Managed(Value) = .init(a);
    const template = types.listView(&.{.{ .int = 1 }});
    try pool.appendSlice(&.{ .{ .int = 42 }, .{ .int = 42 }, .{ .number = 0 }, .{ .number = -0.0 }, .{ .string = "field" }, .{ .string = "field" }, template, template, .{ .int = 999 } });
    const code = [_]Instruction{
        .{ .op = .constant, .a = 0 }, .{ .op = .constant, .a = 1 }, .{ .op = .constant, .a = 2 }, .{ .op = .constant, .a = 3 },
        .{ .op = .field, .a = 4 },    .{ .op = .typst, .a = 5 },    .{ .op = .constant, .a = 6 }, .{ .op = .constant, .a = 7 },
        .{ .op = .halt },
    };
    var functions = [_]bc.Function{.{ .name = "test", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try compactConstants(a, &functions, &pool);
    try std.testing.expectEqual(@as(usize, 6), pool.items.len);
    const rewritten = functions[0].code;
    try std.testing.expectEqual(rewritten[0].a, rewritten[1].a);
    try std.testing.expect(rewritten[2].a != rewritten[3].a);
    try std.testing.expectEqual(rewritten[4].a, rewritten[5].a);
    try std.testing.expect(rewritten[6].a != rewritten[7].a);
}

test "unary errors and invalid constants remain runtime checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .int = std.math.minInt(i64) }, .{ .number = std.math.inf(f64) }, .{ .boolean = false } });
    const overflow = [_]Instruction{ .{ .op = .constant }, .{ .op = .negate }, .{ .op = .store_global }, .{ .op = .halt } };
    try expectSame(&overflow, try optimize(arena.allocator(), &overflow, &pool, .{}), pool.items);
    const nonfinite = [_]Instruction{ .{ .op = .constant, .a = 1 }, .{ .op = .pop }, .{ .op = .halt } };
    try expectSame(&nonfinite, try optimize(arena.allocator(), &nonfinite, &pool, .{}), pool.items);
    const invalid = [_]Instruction{ .{ .op = .constant, .a = 2 }, .{ .op = .negate }, .{ .op = .pop }, .{ .op = .halt } };
    try expectSame(&invalid, try optimize(arena.allocator(), &invalid, &pool, .{}), pool.items);
}

fn allocationCase(allocator: Allocator) !void {
    var pool: std.array_list.Managed(Value) = .init(allocator);
    defer pool.deinit();
    try pool.appendSlice(&.{ .{ .int = 2 }, .{ .int = 3 }, .{ .boolean = true } });
    const input = [_]Instruction{
        .{ .op = .constant, .a = 2 }, .{ .op = .jump_if_false, .a = 7 },
        .{ .op = .constant },         .{ .op = .constant, .a = 1 },
        .{ .op = .add },              .{ .op = .store_global },
        .{ .op = .jump, .a = 7 },     .{ .op = .halt },
    };
    const output = try optimize(allocator, &input, &pool, .{});
    defer allocator.free(output);
    var functions = [_]bc.Function{.{ .name = "test", .code = output, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try compactConstants(allocator, &functions, &pool);
    if (functions[0].code.ptr != output.ptr) allocator.free(functions[0].code);
}

test "all optimizer and pool-compaction allocation failures release temporary storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "short circuit branch patterns and forward jump chains preserve boolean values" {
    for ([_]bool{ false, true }) |initial| {
        for ([_]bool{ false, true }) |is_or| {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var pool: std.array_list.Managed(Value) = .init(arena.allocator());
            try pool.appendSlice(&.{ .{ .boolean = initial }, .{ .boolean = true } });
            var code: std.array_list.Managed(Instruction) = .init(arena.allocator());
            try code.appendSlice(&.{ .{ .op = .constant }, .{ .op = .duplicate } });
            if (is_or) try code.append(.{ .op = .logical_not });
            const branch = code.items.len;
            try code.appendSlice(&.{ .{ .op = .jump_if_false }, .{ .op = .pop }, .{ .op = .constant, .a = 1 } });
            code.items[branch].a = @intCast(code.items.len);
            const jump = code.items.len;
            try code.append(.{ .op = .jump, .a = @intCast(jump + 1) });
            try code.append(.{ .op = .jump, .a = @intCast(jump + 2) });
            try code.appendSlice(&.{ .{ .op = .store_global }, .{ .op = .halt } });
            try expectSame(code.items, try optimize(arena.allocator(), code.items, &pool, .{}), pool.items);
        }
    }
}

test "deterministic finite expression samples execute identically after folding" {
    var generator = std.Random.DefaultPrng.init(0x4855414b);
    const random = generator.random();
    for (0..64) |_| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var pool: std.array_list.Managed(Value) = .init(arena.allocator());
        for (0..3) |_| try pool.append(.{ .int = random.intRangeAtMost(i64, -100, 100) });
        const code = [_]Instruction{
            .{ .op = .constant },         .{ .op = .constant, .a = 1 }, .{ .op = .subtract },
            .{ .op = .constant, .a = 2 }, .{ .op = .multiply },         .{ .op = .negate },
            .{ .op = .store_global },     .{ .op = .halt },
        };
        const result = try optimize(arena.allocator(), &code, &pool, .{});
        try std.testing.expectEqual(@as(usize, 3), result.len);
        try expectSame(&code, result, pool.items);
    }
}

test "pruning exposes another folding round before pipeline convergence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var pool: std.array_list.Managed(Value) = .init(arena.allocator());
    try pool.appendSlice(&.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 999 } });
    const input = [_]Instruction{
        .{ .op = .constant, .a = 0 },
        .{ .op = .jump, .a = 3 },
        .{ .op = .constant, .a = 2 },
        .{ .op = .constant, .a = 1 },
        .{ .op = .add },
        .{ .op = .store_global },
        .{ .op = .halt },
    };
    const output = try optimize(arena.allocator(), &input, &pool, .{ .global_types = &.{.any} });
    try expectSame(&input, output, pool.items);
    for (output) |instruction| if (instruction.op == .add or instruction.op == .jump) return error.UnstableOptimizationPipeline;
    const again = try optimize(arena.allocator(), output, &pool, .{ .global_types = &.{.any} });
    try std.testing.expect(sameCode(output, again));
}

test "pool compaction remaps field writes and never interns mutable aggregate or omitted constants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dictionary: types.Dict = .{};
    var fields = [_]Value{.{ .int = 1 }};
    var record: types.Record = .{ .kind = bc.Type.record(0), .fields = &fields };
    var pool: std.array_list.Managed(Value) = .init(a);
    try pool.appendSlice(&.{
        .{ .int = 999 },          .{ .string = "count" },   .{ .string = "count" },
        .{ .dict = &dictionary }, .{ .dict = &dictionary }, .{ .record = &record },
        .{ .record = &record },   .omitted,                 .omitted,
    });
    const code = [_]Instruction{
        .{ .op = .field, .a = 1, .b = 1 }, .{ .op = .set_field, .a = 2, .b = 1 },
        .{ .op = .constant, .a = 3 },      .{ .op = .constant, .a = 4 },
        .{ .op = .constant, .a = 5 },      .{ .op = .constant, .a = 6 },
        .{ .op = .constant, .a = 7 },      .{ .op = .constant, .a = 8 },
        .{ .op = .halt },
    };
    var functions = [_]bc.Function{.{ .name = "test", .code = &code, .parameters = &.{}, .result = .unit, .local_types = &.{} }};
    try compactConstants(a, &functions, &pool);
    try std.testing.expectEqual(@as(usize, 7), pool.items.len);
    const rewritten = functions[0].code;
    try std.testing.expectEqual(@as(u32, 0), rewritten[1].a);
    try std.testing.expectEqual(rewritten[0].a, rewritten[1].a);
    try std.testing.expectEqual(@as(u32, 1), rewritten[1].b);
    for ([_]usize{ 2, 4, 6 }) |index| try std.testing.expect(rewritten[index].a != rewritten[index + 1].a);
    try std.testing.expect(keyOf(.{ .dict = &dictionary }) == null);
    try std.testing.expect(keyOf(.{ .record = &record }) == null);
    try std.testing.expect(!scalarValid(.omitted));
}

test "shared pool index preserves standalone folding through append growth and propagation" {
    const t = std.testing;
    var actual = std.array_list.Managed(Value).init(t.allocator);
    defer actual.deinit();
    var expected = std.array_list.Managed(Value).init(t.allocator);
    defer expected.deinit();
    const template = types.listView(&.{.{ .int = 7 }});
    const initial = [_]Value{
        .{ .int = 2 },      .{ .int = 3 },      .{ .int = 2 }, .{ .number = 0 }, .{ .number = -0.0 },
        .{ .string = "x" }, .{ .string = "x" }, template,      template,         .omitted,
    };
    try actual.appendSlice(&initial);
    try expected.appendSlice(&initial);
    var index = PoolIndex.init(t.allocator);
    defer index.deinit();
    const cases = [_][]const Instruction{
        &.{ .{ .op = .constant, .a = 2 }, .{ .op = .constant, .a = 1 }, .{ .op = .add }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 1 }, .{ .op = .store_global }, .{ .op = .load_global }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 3 }, .{ .op = .constant, .a = 4 }, .{ .op = .subtract }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 6 }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 7 }, .{ .op = .constant, .a = 8 }, .{ .op = .constant, .a = 9 }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 0 }, .{ .op = .constant, .a = 3 }, .{ .op = .divide, .span = .{ .start = 10, .end = 12 } }, .{ .op = .store_global }, .{ .op = .halt } },
        &.{ .{ .op = .constant, .a = 999 }, .{ .op = .halt } },
    };
    for (cases, 0..) |code, round| {
        const standalone = try optimize(t.allocator, code, &expected, .{ .global_types = &.{.int} });
        defer t.allocator.free(standalone);
        const shared = try optimize(t.allocator, code, &actual, .{ .global_types = &.{.int}, .pool_index = &index });
        defer t.allocator.free(shared);
        try t.expect(sameCode(standalone, shared));
        try t.expectEqualDeep(expected.items, actual.items);
        // Force append/reallocation independently of the optimizer. Duplicate
        // values must keep their earliest index across function boundaries.
        const extra: Value = .{ .int = @intCast(round) };
        try actual.appendSlice(&.{ extra, extra });
        try expected.appendSlice(&.{ extra, extra });
    }
    try index.sync(actual.items);
    try t.expectEqual(@as(u32, 0), index.map.get(keyOf(.{ .int = 2 }).?).?);
    try t.expect(index.map.get(keyOf(.{ .number = 0 }).?).? != index.map.get(keyOf(.{ .number = -0.0 }).?).?);
    try t.expectEqual(@as(u32, 5), index.map.get(keyOf(.{ .string = "x" }).?).?);
}

fn sharedAllocationCase(allocator: Allocator) !void {
    var constants = std.array_list.Managed(Value).init(allocator);
    defer constants.deinit();
    try constants.appendSlice(&.{ .{ .int = 2 }, .{ .int = 3 } });
    var index = PoolIndex.init(allocator);
    defer index.deinit();
    const code = [_]Instruction{
        .{ .op = .constant },     .{ .op = .constant, .a = 1 }, .{ .op = .add },
        .{ .op = .store_global }, .{ .op = .load_global },      .{ .op = .store_global },
        .{ .op = .halt },
    };
    for (0..3) |_| {
        const output = try optimize(allocator, &code, &constants, .{ .global_types = &.{.int}, .pool_index = &index });
        defer allocator.free(output);
        try std.testing.expectEqual(@as(i64, 5), constants.items[output[0].a].int);
        try constants.append(.{ .int = 5 });
    }
}

test "shared pool index releases all partial allocations" {
    try sharedAllocationCase(std.testing.allocator);
    // Force growth to allocate consistently instead of depending on whether
    // the backing allocator can extend a particular block in place.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), sharedAllocationCase, .{});
}

test "pool index can retry after partial synchronization or failed insertion" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var index = PoolIndex.init(failing.allocator());
    defer index.deinit();
    var pool = std.array_list.Managed(Value).init(t.allocator);
    defer pool.deinit();
    for (0..100) |value| try pool.append(.{ .int = @intCast(value) });
    try t.expectError(error.OutOfMemory, index.sync(pool.items));
    try t.expect(index.indexed_count > 0 and index.indexed_count < pool.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try index.sync(pool.items);
    try t.expectEqual(pool.items.len, index.indexed_count);
    for (pool.items, 0..) |value, expected| try t.expectEqual(@as(u32, @intCast(expected)), index.map.get(keyOf(value).?).?);

    var failed_pool = std.array_list.Managed(Value).init(failing.allocator());
    defer failed_pool.deinit();
    var empty_index = PoolIndex.init(t.allocator);
    defer empty_index.deinit();
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, empty_index.intern(&failed_pool, .{ .int = 9 }));
    try t.expectEqual(@as(usize, 0), failed_pool.items.len);
    try t.expectEqual(@as(usize, 0), empty_index.indexed_count);
    try t.expectEqual(@as(u32, 0), empty_index.map.count());
    failing.fail_index = std.math.maxInt(usize);
    try t.expectEqual(@as(u32, 0), try empty_index.intern(&failed_pool, .{ .int = 9 }));
    try t.expectEqual(@as(usize, 1), empty_index.indexed_count);
}
