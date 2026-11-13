//! Forward immutable-value facts over executable bytecode edges. Analysis
//! failure or a proof budget never changes the language's execution limits.
const std = @import("std");
const bc = @import("../bytecode.zig");
const values = @import("value.zig");
const Allocator = std.mem.Allocator;
const Value = bc.Value;
const Fact = struct {
    value: ?Value = null,
    // Unknown numeric values still cannot enter Host.binary. Keep that
    // distinction so ordinary arithmetic does not discard loop invariants.
    may_handle: bool = true,

    fn literal(value: Value) Fact {
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

const Block = struct {
    start: usize,
    end: usize,
    input: ?[]Fact = null,
    queued: bool = false,
};
const Analysis = struct {
    allocator: Allocator,
    code: []const bc.Instruction,
    constants: []const Value,
    bindings: Bindings,
    blocks: []Block,
    owners: []usize,
    replacements: []?Value,
    pending: std.ArrayList(usize) = .empty,
    stack: std.ArrayList(Fact) = .empty,
    current: []Fact,
    remaining: usize = limits.work,
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

    fn push(self: *Analysis, fact: Fact) Allocator.Error!void {
        if (self.stack.items.len == limits.stack) {
            self.invalid = true;
            return;
        }
        try self.stack.append(self.allocator, fact);
    }

    fn pop(self: *Analysis) Fact {
        return self.stack.pop() orelse blk: {
            self.invalid = true;
            break :blk .{};
        };
    }

    fn unknownResult(self: *Analysis, instruction: bc.Instruction, result: Fact) Allocator.Error!void {
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
            fact.* = .{ .may_handle = mayHandle(kind) };
        for (self.bindings.local_types, self.current[self.bindings.global_types.len..]) |kind, *fact|
            fact.* = .{ .may_handle = mayHandle(kind) };
    }

    fn load(self: *Analysis, ip: usize, slot: usize) Allocator.Error!void {
        const fact = self.current[slot];
        // This is overwritten on every visit: a later loop/back-edge merge
        // which loses a fact must also revoke an earlier replacement.
        self.replacements[ip] = fact.value;
        try self.push(fact);
    }

    fn store(self: *Analysis, slot: usize, kind: bc.Type) void {
        self.current[slot] = preservedStore(kind, self.pop());
    }

    fn bindArguments(self: *Analysis, instruction: bc.Instruction) Allocator.Error!void {
        const binding = self.bindings.argument_bindings[instruction.a];
        const count = instruction.b;
        if (count > self.stack.items.len or !self.charge(count)) {
            self.invalid = true;
            return;
        }
        const ordered = try self.allocator.alloc(Fact, count);
        const offset = self.stack.items.len - count;
        for (self.stack.items[offset..], binding.slots) |fact, slot| ordered[slot] = fact;
        @memcpy(self.stack.items[offset..], ordered);
    }

    fn transfer(self: *Analysis, ip: usize) Allocator.Error!?bool {
        const instruction = self.code[ip];
        switch (instruction.op) {
            .constant => {
                const value = self.constants[instruction.a];
                try self.push(Fact.literal(value));
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
                    @import("../numeric.zig").makeVector(3, .{ x.value.?, y.value.?, z.value.? }) catch null
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
                    try self.push(Fact.literal(component));
                } else {
                    // Unknown fields can enter a host callback. Source
                    // constants already on the operand stack remain values.
                    self.forgetBindings();
                    try self.push(.{});
                }
            },
            .call, .call_value, .call_builtin, .typst, .show_rule, .setup_typst, .import_module => {
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
            for (input[0..self.current.len], self.current) |*fact, incoming| changed = join(fact, incoming) or changed;
            for (input[self.current.len..], self.stack.items) |*fact, incoming| changed = join(fact, incoming) or changed;
        } else {
            if (count > limits.cells - self.cells) {
                self.invalid = true;
                return;
            }
            const input = try self.allocator.alloc(Fact, count);
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

    fn run(self: *Analysis) Allocator.Error!bool {
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
};

/// Match VM storage only when no coercion changes the immutable value. The
/// VM remains the sole implementation of conversions and type diagnostics.
fn preservedStore(kind: bc.Type, fact: Fact) Fact {
    const unknown: Fact = .{ .may_handle = if (kind == .any) fact.may_handle else mayHandle(kind) };
    const value = fact.value orelse return unknown;
    if (!values.scalarValid(value) or !bc.Type.accepts(kind, value.valueType())) return unknown;
    if (kind == .number and value == .int) return unknown;
    if ((kind == .length or kind == .angle) and (value == .int or value == .number)) return unknown;
    return Fact.literal(value);
}

fn join(current: *Fact, incoming: Fact) bool {
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

fn mayHandle(kind: bc.Type) bool {
    return switch (kind) {
        .unit, .int, .number, .length, .angle, .quantity, .scalar, .boolean, .string, .vec2, .vec3, .list, .dict => false,
        else => !kind.isRecord(),
    };
}

fn valid(code: []const bc.Instruction, constants: []const Value, bindings: Bindings) bool {
    var remaining: usize = limits.work - @min(limits.work, code.len);
    for (code) |instruction| switch (instruction.op) {
        .constant => if (instruction.a >= constants.len) return false,
        .field, .set_field, .typst, .show_rule, .setup_typst => if (instruction.a >= constants.len or constants[instruction.a] != .string) return false,
        .bind_arguments => {
            if (instruction.a >= bindings.argument_bindings.len) return false;
            const binding = bindings.argument_bindings[instruction.a];
            if (binding.slots.len != instruction.b or binding.parameter_count != instruction.b or instruction.b > limits.stack) return false;
            if (binding.slots.len > remaining) return false;
            remaining -= binding.slots.len;
            var supplied: std.StaticBitSet(limits.stack) = .empty;
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
pub fn rewrite(allocator: Allocator, code: []const bc.Instruction, constants: *std.array_list.Managed(Value), bindings: Bindings) Error!?[]bc.Instruction {
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
        try constants.append(value);
        instruction.* = .{ .op = .constant, .a = constant, .span = instruction.span, .module = instruction.module };
    };
    return result;
}

const t = std.testing;
fn ins(op: bc.Op, a: u32) bc.Instruction {
    return .{ .op = op, .a = a };
}
fn pool(a: Allocator, items: []const Value) !std.array_list.Managed(Value) {
    var result = std.array_list.Managed(Value).init(a);
    errdefer result.deinit();
    try result.appendSlice(items);
    return result;
}
fn expectInt(code: []const bc.Instruction, constants: []const Value, ip: usize, expected: i64) !void {
    try t.expectEqual(bc.Op.constant, code[ip].op);
    try t.expectEqual(expected, constants[code[ip].a].int);
}

test "propagation follows known branch edges through arithmetic and local stores" {
    var constants = try pool(t.allocator, &.{ .{ .int = 2 }, .{ .int = 3 }, .{ .int = 5 } });
    defer constants.deinit();
    const code = [_]bc.Instruction{
        ins(.constant, 0),     ins(.store_global, 0),   ins(.load_global, 0),  ins(.constant, 1),
        ins(.add, 0),          ins(.store_local, 0),    ins(.load_local, 0),   ins(.constant, 2),
        ins(.equal, 0),        ins(.jump_if_false, 13), ins(.constant, 0),     ins(.store_global, 1),
        ins(.jump, 15),        ins(.constant, 1),       ins(.store_global, 1), ins(.load_global, 1),
        ins(.store_global, 2), ins(.halt, 0),
    };
    const result = (try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .int, .int, .int }, .local_types = &.{.int} })).?;
    defer t.allocator.free(result);
    try expectInt(result, constants.items, 2, 2);
    try expectInt(result, constants.items, 6, 5);
    try expectInt(result, constants.items, 15, 2);
    for (code, result) |before, after| if (before.op == .store_global or before.op == .store_local) {
        try t.expectEqualDeep(before, after);
    };
}

test "propagation joins all executable predecessors and preserves signed zero" {
    const code = [_]bc.Instruction{
        ins(.load_global, 0),  ins(.jump_if_false, 5), ins(.constant, 0),     ins(.store_global, 1),
        ins(.jump, 7),         ins(.constant, 1),      ins(.store_global, 1), ins(.load_global, 1),
        ins(.store_global, 2), ins(.halt, 0),
    };
    for ([_]bool{ false, true }) |equal| {
        var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = if (equal) 7 else 8 } });
        defer constants.deinit();
        const result = try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .boolean, .int, .int } });
        defer if (result) |output| t.allocator.free(output);
        if (equal) {
            try expectInt(result.?, constants.items, 7, 7);
        } else try t.expect(result == null);
    }
    var zeros = try pool(t.allocator, &.{ .{ .number = -0.0 }, .{ .number = 0.0 } });
    defer zeros.deinit();
    try t.expect((try rewrite(t.allocator, &code, &zeros, .{ .global_types = &.{ .boolean, .number, .number } })) == null);

    // One predecessor reaches the read without assigning result at all.
    const uninitialized = [_]bc.Instruction{
        ins(.load_global, 0), ins(.jump_if_false, 4), ins(.constant, 0), ins(.store_global, 1),
        ins(.load_global, 1), ins(.store_global, 2),  ins(.halt, 0),
    };
    var constants = try pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    try t.expect((try rewrite(t.allocator, &uninitialized, &constants, .{ .global_types = &.{ .boolean, .int, .int } })) == null);
}

test "propagation loop fixed points retain invariants and revoke induction facts" {
    var constants = try pool(t.allocator, &.{ .{ .int = 9 }, .{ .int = 0 }, .{ .int = 3 }, .{ .int = 1 } });
    defer constants.deinit();
    const code = [_]bc.Instruction{
        ins(.constant, 0),    ins(.store_global, 0), ins(.constant, 1),   ins(.store_local, 0),
        ins(.load_local, 0),  ins(.constant, 2),     ins(.less, 0),       ins(.jump_if_false, 15),
        ins(.load_global, 0), ins(.store_global, 1), ins(.load_local, 0), ins(.constant, 3),
        ins(.add, 0),         ins(.store_local, 0),  ins(.jump, 4),       ins(.halt, 0),
    };
    const result = (try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .int, .int }, .local_types = &.{.int} })).?;
    defer t.allocator.free(result);
    try t.expectEqual(bc.Op.load_local, result[4].op);
    try t.expectEqual(bc.Op.load_local, result[10].op);
    try expectInt(result, constants.items, 8, 9);
    try t.expectEqualDeep(code[14], result[14]);
}

test "propagation call barriers forget bindings but retain evaluated operand values" {
    var constants = try pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    const code = [_]bc.Instruction{
        ins(.constant, 0),    ins(.store_global, 0), ins(.load_global, 0), ins(.call, 0),
        ins(.pop, 0),         ins(.store_global, 1), ins(.load_global, 0), ins(.pop, 0),
        ins(.load_global, 1), ins(.store_global, 2), ins(.halt, 0),
    };
    const result = (try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .int, .int, .int } })).?;
    defer t.allocator.free(result);
    try expectInt(result, constants.items, 2, 7);
    try t.expectEqual(bc.Op.load_global, result[6].op);
    try expectInt(result, constants.items, 8, 7);
    try t.expectEqualDeep(code[3], result[3]);
}

test "propagation unknown handle arithmetic is a host barrier but numeric arithmetic is not" {
    for ([_]bc.Op{ .add, .negate }) |operation| {
        for ([_]bc.Type{ .any, .variable, .int }) |kind| {
            var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = 1 } });
            defer constants.deinit();
            var code: std.ArrayList(bc.Instruction) = .empty;
            defer code.deinit(t.allocator);
            try code.appendSlice(t.allocator, &.{ ins(.constant, 0), ins(.store_global, 0), ins(.load_global, 1) });
            if (operation == .add) try code.append(t.allocator, ins(.constant, 1));
            try code.appendSlice(t.allocator, &.{ ins(operation, 0), ins(.pop, 0), ins(.load_global, 0), ins(.store_global, 2), ins(.halt, 0) });
            const result = try rewrite(t.allocator, code.items, &constants, .{ .global_types = &.{ .int, kind, .int } });
            defer if (result) |output| t.allocator.free(output);
            if (kind == .int) {
                try expectInt(result.?, constants.items, code.items.len - 3, 7);
            } else try t.expect(result == null);
        }
    }
}

test "propagation preserves a custom native arithmetic mutation after an earlier propagated load" {
    const Machine = @import("../Machine.zig");
    const Host = struct {
        machine: *Machine = undefined,
        calls: usize = 0,
        fn binary(context: ?*anyopaque, _: Allocator, _: bc.Op, _: Value, _: Value) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.machine.globals[0] = .{ .int = 11 };
            return .{ .int = 1 };
        }
    };
    const code = [_]bc.Instruction{
        ins(.constant, 0),    ins(.store_global, 0), ins(.load_global, 0), ins(.pop, 0),
        ins(.load_global, 1), ins(.constant, 1),     ins(.add, 0),         ins(.pop, 0),
        ins(.load_global, 0), ins(.store_global, 2), ins(.halt, 0),
    };
    var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .int = 1 } });
    defer constants.deinit();
    const result = (try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .int, .any, .int } })).?;
    defer t.allocator.free(result);
    try expectInt(result, constants.items, 2, 7);
    try t.expectEqual(bc.Op.load_global, result[8].op);
    for ([_][]const bc.Instruction{ &code, result }) |instructions| {
        var program: bc.Program = .{
            .arena = .init(t.allocator),
            .source_text = "",
            .name = "native-propagation.huak",
            .functions = &.{.{ .name = "script", .code = instructions, .parameters = &.{}, .result = .unit, .local_types = &.{} }},
            .constants = constants.items,
            .parameters = &.{},
            .global_names = &.{ "initial", "dynamic", "result" },
            .global_types = &.{ .int, .any, .int },
            .readonly_globals = &.{ false, false, false },
        };
        defer program.deinit();
        var host: Host = .{};
        var machine = try Machine.init(t.allocator, &program, .{ .ptr = &host, .vtable = &.{ .binary = Host.binary } }, .{});
        defer machine.deinit();
        host.machine = &machine;
        machine.globals[1] = .{ .handle = .{ .kind = .variable, .index = 0 } };
        machine.initialized[1] = true;
        _ = try machine.execute(&.{});
        try t.expectEqual(@as(usize, 1), host.calls);
        try t.expectEqual(@as(i64, 11), machine.getGlobal("result").?.int);
    }
}

test "propagation does not bypass store conversions or mutable identities" {
    var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .number = 7 }, bc.types.listView(&.{.{ .int = 1 }}), .{ .handle = .{ .kind = .picture, .index = 0 } } });
    defer constants.deinit();
    const code = [_]bc.Instruction{
        ins(.constant, 0), ins(.store_global, 0), ins(.load_global, 0), ins(.pop, 0),
        ins(.constant, 1), ins(.store_global, 0), ins(.load_global, 0), ins(.pop, 0),
        ins(.constant, 0), ins(.store_global, 1), ins(.load_global, 1), ins(.pop, 0),
        ins(.constant, 2), ins(.store_global, 2), ins(.load_global, 2), ins(.pop, 0),
        ins(.constant, 3), ins(.store_global, 3), ins(.load_global, 3), ins(.pop, 0),
        ins(.halt, 0),
    };
    const result = (try rewrite(t.allocator, &code, &constants, .{ .global_types = &.{ .number, .length, .list, .picture } })).?;
    defer t.allocator.free(result);
    try t.expectEqual(bc.Op.load_global, result[2].op);
    try t.expectEqual(bc.Op.constant, result[6].op);
    try t.expectEqual(@as(f64, 7), constants.items[result[6].a].number);
    for ([_]usize{ 10, 14, 18 }) |index| try t.expectEqual(bc.Op.load_global, result[index].op);
}

test "propagation unknown fields imports and typography remain host barriers" {
    const barriers = [_]bc.Instruction{ ins(.import_module, 0), ins(.setup_typst, 1), ins(.typst, 1), ins(.field, 1) };
    for (barriers) |barrier| {
        var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .string = "x" } });
        defer constants.deinit();
        var code: std.ArrayList(bc.Instruction) = .empty;
        defer code.deinit(t.allocator);
        try code.appendSlice(t.allocator, &.{ ins(.constant, 0), ins(.store_global, 0) });
        if (barrier.op == .field) try code.append(t.allocator, ins(.constant, 0));
        try code.append(t.allocator, barrier);
        if (barrier.stackEffect().produced != 0) try code.append(t.allocator, ins(.pop, 0));
        try code.appendSlice(t.allocator, &.{ ins(.load_global, 0), ins(.pop, 0), ins(.halt, 0) });
        try t.expect((try rewrite(t.allocator, code.items, &constants, .{ .global_types = &.{.int} })) == null);
    }
}

test "propagation malformed bytecode and proof limits leave the pool untouched" {
    var constants = try pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    const bad = [_][]const bc.Instruction{
        &.{ ins(.jump, 999), ins(.halt, 0) },
        &.{ ins(.constant, 999), ins(.halt, 0) },
        &.{ ins(.load_global, 999), ins(.halt, 0) },
        &.{ ins(.add, 0), ins(.halt, 0) },
        // Diverging stack depth at a reachable join.
        &.{ ins(.load_global, 0), ins(.jump_if_false, 4), ins(.constant, 0), ins(.jump, 4), ins(.halt, 0) },
    };
    for (bad) |code| try t.expect((try rewrite(t.allocator, code, &constants, .{ .global_types = &.{.boolean} })) == null);
    const long = try t.allocator.alloc(bc.Instruction, limits.instructions + 1);
    defer t.allocator.free(long);
    @memset(long, ins(.halt, 0));
    try t.expect((try rewrite(t.allocator, long, &constants, .{})) == null);
    const many = try t.allocator.alloc(bc.Type, limits.bindings + 1);
    defer t.allocator.free(many);
    @memset(many, .any);
    try t.expect((try rewrite(t.allocator, &.{ins(.halt, 0)}, &constants, .{ .global_types = many })) == null);
    try t.expectEqual(@as(usize, 1), constants.items.len);
}

fn allocationExercise(a: Allocator) !void {
    var constants = try pool(a, &.{.{ .int = 7 }});
    defer constants.deinit();
    const code = [_]bc.Instruction{ ins(.constant, 0), ins(.store_global, 0), ins(.load_global, 0), ins(.store_global, 1), ins(.halt, 0) };
    const result = (try rewrite(a, &code, &constants, .{ .global_types = &.{ .int, .int } })).?;
    defer a.free(result);
    try expectInt(result, constants.items, 2, 7);
}

test "propagation releases all allocations including partial pool rewrites" {
    try allocationExercise(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

fn argumentAllocationExercise(a: Allocator) !void {
    var constants = try pool(a, &.{ .{ .int = 7 }, .{ .int = 11 } });
    defer constants.deinit();
    const code = [_]bc.Instruction{
        ins(.constant, 0),     ins(.constant, 1),     .{ .op = .bind_arguments, .a = 0, .b = 2 },
        ins(.store_global, 0), ins(.store_global, 1), ins(.load_global, 0),
        ins(.store_global, 2), ins(.load_global, 1),  ins(.store_global, 3),
        ins(.halt, 0),
    };
    const result = (try rewrite(a, &code, &constants, .{
        .global_types = &.{ .int, .int, .int, .int },
        .argument_bindings = &.{.{ .slots = &.{ 1, 0 }, .parameter_count = 2 }},
    })).?;
    defer a.free(result);
    try expectInt(result, constants.items, 5, 7);
    try expectInt(result, constants.items, 7, 11);
    try t.expectEqualDeep(code[2], result[2]);
}

test "argument permutations preserve evaluated facts and release every failed allocation" {
    try argumentAllocationExercise(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, argumentAllocationExercise, .{});
}

test "invalid argument descriptors leave propagation and the constant pool unchanged" {
    var constants = try pool(t.allocator, &.{.{ .int = 7 }});
    defer constants.deinit();
    const code = [_]bc.Instruction{ ins(.constant, 0), ins(.constant, 0), .{ .op = .bind_arguments, .a = 0, .b = 2 }, ins(.halt, 0) };
    for ([_]bc.ArgumentBinding{
        .{ .slots = &.{ 0, 0 }, .parameter_count = 2 },
        .{ .slots = &.{ 0, 2 }, .parameter_count = 2 },
        .{ .slots = &.{0}, .parameter_count = 2 },
        .{ .slots = &.{ 0, 1 }, .parameter_count = 3 },
    }) |binding| {
        try t.expect((try rewrite(t.allocator, &code, &constants, .{ .argument_bindings = &.{binding} })) == null);
        try t.expectEqual(@as(usize, 1), constants.items.len);
    }
    try t.expect((try rewrite(t.allocator, &code, &constants, .{})) == null);
}

test "aggregate writes stop binding propagation without replacing aggregate identities" {
    for ([_]bc.Op{ .set_index, .set_field }) |operation| {
        var constants = try pool(t.allocator, &.{ .{ .int = 7 }, .{ .string = "field" } });
        defer constants.deinit();
        var code: std.ArrayList(bc.Instruction) = .empty;
        defer code.deinit(t.allocator);
        try code.appendSlice(t.allocator, &.{ ins(.constant, 0), ins(.store_global, 0), ins(.load_global, 0), ins(.pop, 0), ins(.load_global, 1) });
        if (operation == .set_index) try code.append(t.allocator, ins(.constant, 0));
        try code.appendSlice(t.allocator, &.{ ins(.constant, 0), ins(operation, 1), ins(.load_global, 0), ins(.pop, 0), ins(.halt, 0) });
        const result = (try rewrite(t.allocator, code.items, &constants, .{ .global_types = &.{ .int, if (operation == .set_index) .dict else bc.Type.record(0) } })).?;
        defer t.allocator.free(result);
        try expectInt(result, constants.items, 2, 7);
        try t.expectEqual(bc.Op.load_global, result[result.len - 3].op);
        try t.expectEqual(bc.Op.load_global, result[4].op);
    }
}
