//! Calls: of user functions, of values and bound functions, and of builtins;
//! what the callee's summary, or the builtin, does to the caller's.
const std = @import("std");
const bc = @import("../../bytecode.zig");
const builtin = @import("../../builtin.zig");
const Allocator = std.mem.Allocator;
const effects = @import("../effects.zig");
const builtins = @import("builtins.zig");
const Analysis = @import("Analysis.zig");
const State = effects.State;
const Value = effects.Value;
const limits = effects.limits;
const analyzeFunction = effects.analyzeFunction;

/// Calls of functions by index and of values, binding a function's
/// arguments, and calls of builtins.
pub fn call(self: *Analysis, state: *State, instruction_: bc.Instruction, comptime op: bc.Op) !void {
    switch (op) {
        .call => {
            if (instruction_.a >= self.program.functions.len or instruction_.a >= self.summaries.len) return self.invalid();
            const callee = self.program.functions[instruction_.a];
            if (!callee.acceptsCount(instruction_.b)) return self.invalid();
            const arguments = self.args(state, instruction_.b);
            if (self.malformed) return;
            for (arguments) |arg| {
                self.observe(arg);
            }
            const result = try userCall(self, instruction_.a, arguments);
            self.saw_user_call = true;
            state.stack.items.len -= instruction_.b;
            try self.push(state, result);
        },
        .call_value, .bind_function => {
            const effect = instruction_.stackEffect();
            if (effect.consumed > state.stack.items.len) return self.invalid();
            const values = state.stack.items[state.stack.items.len - effect.consumed ..];
            const function = values[0];
            const result = try apply(self, function, values[1..], instruction_);
            state.stack.items.len -= effect.consumed;
            try self.push(state, result);
        },
        .call_builtin => {
            const id = std.enums.fromInt(builtin.Id, instruction_.a) orelse return self.invalid();
            const signature = builtin.signature(id);
            if (!signature.acceptsCount(instruction_.b)) return self.invalid();
            const arguments = self.args(state, instruction_.b);
            if (self.malformed) return;
            const result = builtins.builtinResult(self, &signature, arguments);
            state.stack.items.len -= instruction_.b;
            try self.push(state, result);
        },
        else => comptime unreachable,
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
            summary = try analyzeFunction(self.allocator, self.scratch_allocator, self.program, self.summaries, index, self.budget, arguments, self.depth + 1);
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
    const ordered = @import("../../arguments.zig").bind(Value, self.allocator, names, variadic, if (value.bound) |bound| bound.values else &.{}, if (value.bound) |bound| bound.names else &.{}, incoming, labels) catch |err| switch (err) {
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
                if (i < function.default_functions.len) if (function.default_functions[i]) |callee| break :blk try userCall(self, callee, &.{});
                if (i < function.defaults.len) if (function.defaults[i]) |default| break :blk Value.ordinary(default.valueType());
                self.invalid();
                return .{};
            },
        };
    }
    return switch (target) {
        .bytecode => |index| try userCall(self, index, arguments),
        .native => |index| blk: {
            const signature = builtin.signature(std.enums.fromInt(builtin.Id, index).?);
            if (!signature.acceptsCount(arguments.len)) {
                self.invalid();
                return .{};
            }
            break :blk builtins.builtinResult(self, &signature, arguments);
        },
    };
}
