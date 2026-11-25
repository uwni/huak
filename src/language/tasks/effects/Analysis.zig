const std = @import("std");
const bc = @import("../../bytecode.zig");
const Allocator = std.mem.Allocator;
const Type = bc.Type;
const effects = @import("../effects.zig");
const Analysis = @This();
const Summary = effects.Summary;
const Budget = effects.Budget;
const Value = effects.Value;
const supportedType = effects.supportedType;
const State = effects.State;
const joinType = effects.joinType;
const values = @import("values.zig");
const calls = @import("calls.zig");

/// The working arena of this analysis.
allocator: Allocator,
/// Backs the working arenas of the context analyses it starts.
scratch_allocator: Allocator,
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

pub fn init(allocator: Allocator, scratch_allocator: Allocator, program: *const bc.Program, summaries: []const Summary, budget: *Budget) !Analysis {
    const reads = try allocator.alloc(bool, program.global_types.len);
    @memset(reads, false);
    return .{ .allocator = allocator, .scratch_allocator = scratch_allocator, .program = program, .summaries = summaries, .budget = budget, .reads = reads };
}

pub fn observe(self: *Analysis, value: Value) void {
    if (!value.initialized or !supportedType(value.kind)) self.safe = false;
}

pub fn args(self: *Analysis, state: *State, count: u32) []const Value {
    if (count > state.stack.items.len) {
        self.safe = false;
        self.malformed = true;
        return &.{};
    }
    return state.stack.items[state.stack.items.len - count ..];
}

pub fn push(self: *Analysis, state: *State, value: Value) !void {
    try state.stack.append(self.allocator, value);
}

/// The abstract effect of one bytecode instruction on the stack, locals,
/// provenance and the function's summary: control flow here, the other
/// families in `values.zig` and `calls.zig`.
pub fn instruction(self: *Analysis, state: *State, instruction_: bc.Instruction) !void {
    if (!self.budget.consume(1)) return self.invalid();
    switch (instruction_.op) {
        inline .constant, .load_global, .load_local, .store_local, .store_global, .pop, .duplicate, .bind_arguments => |op| try values.variable(self, state, instruction_, op),
        inline .add, .subtract, .multiply, .divide, .remainder, .power, .positive, .negate, .logical_not, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => |op| try values.operator(self, state, instruction_, op),
        inline .list_append, .list_append_items, .set_index, .set_field, .make_vec2, .make_vec3, .make_list, .make_dict, .make_record, .index, .slice, .field => |op| try values.aggregate(self, state, instruction_, op),
        inline .typst, .typst_module => |op| try values.typst(self, state, instruction_, op),
        inline .call, .call_value, .bind_function, .call_builtin => |op| try calls.call(self, state, instruction_, op),
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
        .check_module, .jump => {},
        .return_value => {
            const value = state.pop(self);
            self.observe(value);
            self.returned = true;
            self.all_returns_fresh = self.all_returns_fresh and value.fresh_owner and (value.kind == .picture or value.kind == .object or value.kind == .any);
            if (state.stack.items.len != 0) self.invalid();
        },
        // Import/observable effects and global writes cannot be
        // replayed by an isolated worker. Unknown opcodes stay barriers.
        .import_module, .halt => self.safe = false,
    }
}

pub fn mergeCall(self: *Analysis, index: u32) Summary {
    if (index >= self.summaries.len) {
        self.invalid();
        return .{};
    }
    return self.mergeSummary(self.summaries[index]);
}

pub fn mergeSummary(self: *Analysis, summary: Summary) Summary {
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

pub fn invalid(self: *Analysis) void {
    self.safe = false;
    self.malformed = true;
}

pub fn finish(self: *const Analysis, allocator: Allocator, fresh: bool) !Summary {
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
