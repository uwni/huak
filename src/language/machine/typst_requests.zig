//! Typst requests: capture operands, batching adjacent text assignments, and typ.module values.
const std = @import("std");
const units = @import("../../drawing/units.zig");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const interpreter = @import("interpreter.zig");
const failures = @import("failures.zig");
const validation = @import("validation.zig");
const TypstBinding = Machine.TypstBinding;
const TypstShow = Machine.TypstShow;
const Error = Machine.Error;
const TypstRequest = Machine.TypstRequest;
const TypstBatchDiagnostic = Machine.TypstBatchDiagnostic;
const TypstOrigin = Machine.TypstOrigin;

const invalid_captures = "Typst code can read finite numbers, bool, UTF-8 strings, lengths, colors and typ.module values from huak; typ.show requires typ.module values";

/// Captured operands split into data bindings and the shows marked by a
/// leading '.' before their member path. Both slices are allocated in one
/// allocator.
const Captures = struct {
    bindings: []TypstBinding,
    shows: []TypstShow,

    pub fn deinit(self: Captures, allocator: std.mem.Allocator) void {
        allocator.free(self.bindings);
        allocator.free(self.shows);
    }
};

/// Null rejects malformed operands and values Typst cannot receive.
fn captures(allocator: std.mem.Allocator, operands: []const Value) std.mem.Allocator.Error!?Captures {
    if (operands.len % 2 != 0) return null;
    var shows: usize = 0;
    var index: usize = 0;
    while (index < operands.len) : (index += 2) {
        const name = operands[index];
        if (name != .string or name.string.len == 0 or !std.unicode.utf8ValidateSlice(name.string)) return null;
        const value = operands[index + 1];
        if (name.string[0] == '.') {
            if (name.string.len == 1 or value != .handle or value.handle.kind != .typst_module) return null;
            shows += 1;
            continue;
        }
        const valid = switch (value) {
            .int, .boolean => true,
            .number => |numeric_value| std.math.isFinite(numeric_value),
            .string => |string| std.unicode.utf8ValidateSlice(string),
            .quantity => |quantity| blk: {
                if (!quantity.dimension.eql(.distance)) break :blk false;
                _ = units.toPoints(quantity) catch break :blk false;
                break :blk true;
            },
            .handle => |handle| handle.kind == .color or handle.kind == .typst_module,
            else => false,
        };
        if (!valid) return null;
    }
    const bindings = try allocator.alloc(TypstBinding, operands.len / 2 - shows);
    errdefer allocator.free(bindings);
    const rules = try allocator.alloc(TypstShow, shows);
    var named: usize = 0;
    var shown: usize = 0;
    index = 0;
    while (index < operands.len) : (index += 2) {
        const name = operands[index].string;
        if (name[0] == '.') {
            rules[shown] = .{ .value = operands[index + 1], .path = name[1..] };
            shown += 1;
        } else {
            bindings[named] = .{ .name = name, .value = operands[index + 1] };
            named += 1;
        }
    }
    return .{ .bindings = bindings, .shows = rules };
}

/// Typesets one Typst block, or a batch of adjacent text assignments.
pub fn typesetBlock(self: *Machine, instruction: bytecode.Instruction, frame_index: usize, function: bytecode.Function, ip: usize) Error!void {
    if (try typesetBatch(self, frame_index, function, ip)) return;
    const text = try interpreter.stringConstant(self, instruction.a);
    if (self.host.vtable.typst == null) return self.fail("Typst content requires a host", .{});
    const operands = instruction.typstCaptures();
    const length = @as(usize, operands.pairs) * 2;
    if (length > self.stack.items.len) return self.fail("invalid Typst capture operands", .{});
    const offset = self.stack.items.len - length;
    const captured = (try captures(self.gpa, self.stack.items[offset..])) orelse return self.fail(invalid_captures, .{});
    defer captured.deinit(self.gpa);
    self.stack.shrinkRetainingCapacity(offset);
    const result = self.host.typeset(self.arena.allocator(), .{ .source = text, .bindings = captured.bindings, .shows = captured.shows, .whole = operands.whole }) catch |err| return failures.nativeFailure(self, err);
    try validation.checkFiniteExternal(self, result);
    try self.push(try validation.coerce(self, result, .text));
}

/// Makes a typ.module value from its code and captured bindings.
pub fn createModule(self: *Machine, instruction: bytecode.Instruction, function: bytecode.Function) Error!void {
    const code = try interpreter.stringConstant(self, instruction.a);
    if (self.host.vtable.typstModule == null) return self.fail("typ.module requires a Typst host", .{});
    const operands = instruction.typstCaptures();
    const length = @as(usize, operands.pairs) * 2;
    if (length >= self.stack.items.len) return self.fail("invalid Typst capture operands", .{});
    const offset = self.stack.items.len - length - 1;
    const name = self.stack.items[offset];
    if (name != .string or name.string.len == 0 or !std.unicode.utf8ValidateSlice(name.string)) return self.fail("invalid Typst capture operands", .{});
    const captured = (try captures(self.gpa, self.stack.items[offset + 1 ..])) orelse return self.fail(invalid_captures, .{});
    defer captured.deinit(self.gpa);
    if (captured.shows.len != 0) return self.fail("invalid Typst capture operands", .{});
    self.stack.shrinkRetainingCapacity(offset);
    const origin = typstOrigin(self, if (instruction.module == std.math.maxInt(u32)) function.module else instruction.module, instruction.span.start);
    const result = self.host.typstModule(self.arena.allocator(), .{ .code = code, .name = name.string, .bindings = captured.bindings, .whole = operands.whole, .origin = origin }) catch |err| return failures.nativeFailure(self, err);
    try self.push(try validation.coerce(self, result, .typst_module));
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
    const count = @as(usize, produce.typstCaptures().pairs) * 2;
    const values = if (first) blk: {
        if (count > self.stack.items.len) return null;
        break :blk self.stack.items[self.stack.items.len - count ..];
    } else operands.items;
    if (values.len != count) return null;
    const captured = try captures(allocator, values) orelse return null;
    const store = function.code[position + 1];
    switch (store.op) {
        .store_global => if (store.a >= self.globals.len or store.a >= self.program.global_types.len or
            self.program.readonly_globals[store.a] or self.program.global_types[store.a] != .text) return null,
        .store_local => if (store.a >= function.local_types.len or function.local_types[store.a] != .text) return null,
        else => return null,
    }
    return .{ .begin = begin, .produce = position, .end = position + 2, .store = store, .request = .{ .source = self.program.constants[produce.a].string, .bindings = captured.bindings, .shows = captured.shows, .whole = produce.typstCaptures().whole } };
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
    if (self.host.vtable.typstBatch == null) return false;
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
        const assignment = try planText(self, temporary.allocator(), frame_index, function, next, count == 0, assignments[0..count]) orelse break;
        const needed = assignment.end - assignment.begin;
        if (needed > available - cost) break;
        assignments[count] = assignment;
        requests[count] = assignment.request;
        cost += needed;
        count += 1;
        next = assignment.end;
    }
    if (count < 2) return false;
    self.stack.shrinkRetainingCapacity(self.stack.items.len - (requests[0].bindings.len + requests[0].shows.len) * 2);
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
        try chargeText(self, frame_index, function, charged, assignment.produce + 1);
        self.current_span = function.code[assignment.produce].span;
        self.current_module = function.code[assignment.produce].module;
        try validation.checkFiniteExternal(self, value);
        const text = try validation.coerce(self, value, .text);
        try chargeText(self, frame_index, function, assignment.produce + 1, assignment.end);
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
        try chargeText(self, frame_index, function, charged, failed.produce + 1);
        self.current_span = function.code[failed.produce].span;
        self.current_module = function.code[failed.produce].module;
        return failures.nativeFailureMessage(self, failure, diagnostic.message);
    }
    return true;
}

fn typstOrigin(self: *const Machine, module: u32, offset: usize) TypstOrigin {
    const name, const text = if (module < self.program.modules.len)
        .{ self.program.modules[module].name, self.program.modules[module].source_text }
    else
        .{ self.program.name, self.program.source_text };
    const position = std.zig.findLineColumn(text, @min(offset, text.len));
    return .{ .name = name, .line = position.line, .column = position.column };
}
