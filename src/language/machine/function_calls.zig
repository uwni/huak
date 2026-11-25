//! Entering bytecode functions and module entries: argument binding, defaults, variadic lists and function values.
const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const types = @import("../types.zig");
const source = @import("../source.zig");
const Value = types.Value;
const Type = types.Type;
const Span = source.Span;
const Machine = @import("../Machine.zig");
const validation = @import("validation.zig");
const builtin_calls = @import("builtin_calls.zig");
const templates = @import("templates.zig");
const lists = @import("lists.zig");
const Error = Machine.Error;

pub fn callValue(self: *Machine, value: Value, count: usize, span: Span) Error!void {
    if (value != .function) return self.fail("expected function, received {s}", .{validation.typeName(self, value.valueType())});
    if (value.function == .bound) return applyFunction(self, value.function, count, &.{}, false, span);
    switch (value.function) {
        .bytecode => |index| {
            if (index >= self.program.functions.len) return self.fail("invalid function reference", .{});
            const module = self.program.functions[index].module;
            if (module >= self.module_states.len or self.module_states[module] == 0) return self.fail("function module is not initialized", .{});
            try enter(self, index, count, span);
        },
        .native => |index| try builtin_calls.callBuiltin(self, index, count),
        .bound => unreachable,
    }
}

const FunctionParameters = struct {
    names: []const []const u8,
    kinds: []const Type,
    defaults: []const ?Value = &.{},
    default_functions: []const ?u32 = &.{},
    minimum: usize,
    variadic: ?Type,
    native: bool = false,
};

fn functionParameters(self: *Machine, target: types.Function.Target) Error!FunctionParameters {
    return switch (target) {
        .bytecode => |index| blk: {
            if (index >= self.program.functions.len) return self.fail("invalid function reference", .{});
            const function = self.program.functions[index];
            if (function.parameter_names.len < function.fixedCount()) return self.fail("invalid function parameter names", .{});
            break :blk .{ .names = function.parameter_names[0..function.fixedCount()], .kinds = function.parameters[0..function.fixedCount()], .defaults = function.defaults, .default_functions = function.default_functions, .minimum = function.requiredCount(), .variadic = function.variadic };
        },
        .native => |index| blk: {
            const id = std.enums.fromInt(builtin.Id, index) orelse return self.fail("invalid native function reference", .{});
            const signature = builtin.signature(id);
            break :blk .{ .names = signature.parameter_names, .kinds = signature.args, .minimum = signature.minimum, .variadic = signature.variadic, .native = true };
        },
    };
}

/// Both .with and named function-value calls use this binding path. Bound
/// arguments are evaluated at .with; only explicit values are retained.
fn applyFunction(self: *Machine, function: types.Function, count: usize, names: []const ?[]const u8, partial: bool, span: Span) Error!void {
    if (names.len != 0 and names.len != count) return self.fail("invalid function argument names", .{});
    const target = function.target();
    const parameters = try functionParameters(self, target);
    const prior: ?*types.Function.Bound = if (function == .bound) function.bound else null;
    const ordered = @import("../arguments.zig").bind(Value, self.gpa, parameters.names, parameters.variadic != null, if (prior) |bound| bound.arguments else &.{}, if (prior) |bound| bound.names else &.{}, try self.arguments(count), names) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.fail("invalid function arguments: {t}", .{err}),
    };
    defer self.gpa.free(ordered);
    var highest: usize = 0;
    for (ordered, 0..) |value, i| if (value != null) {
        highest = i + 1;
    };
    if (partial) {
        var used: usize = 0;
        for (ordered) |value| if (value != null) {
            used += 1;
        };
        const values = try self.arena.allocator().alloc(Value, used);
        const labels = try self.arena.allocator().alloc(?[]const u8, used);
        var next: usize = 0;
        for (ordered, 0..) |value, i| if (value) |item| {
            values[next] = try validation.coerce(self, try templates.materialize(self, item), if (i < parameters.kinds.len) parameters.kinds[i] else parameters.variadic.?);
            labels[next] = if (i < parameters.names.len) parameters.names[i] else null;
            next += 1;
        };
        const bound = try self.arena.allocator().create(types.Function.Bound);
        bound.* = .{ .target = target, .arguments = values, .names = labels, .owner = self.identity };
        self.stack.items.len -= count;
        return self.push(.{ .function = .{ .bound = bound } });
    }
    highest = @max(highest, parameters.minimum);
    for (ordered[0..highest], 0..) |*value, i| if (value.* == null) {
        if (i < parameters.default_functions.len and parameters.default_functions[i] != null) {
            value.* = try self.invokeFunction(.{ .function = .{ .bytecode = parameters.default_functions[i].? } }, &.{});
        } else if (i < parameters.defaults.len and parameters.defaults[i] != null) {
            value.* = parameters.defaults[i].?;
        } else if (!parameters.native or i < parameters.minimum) return self.fail("missing function argument '{s}'", .{parameters.names[i]}) else value.* = .omitted;
    };
    self.stack.items.len -= count;
    for (ordered[0..highest]) |value| try self.push(value.?);
    switch (target) {
        .bytecode => |index| try callValue(self, .{ .function = .{ .bytecode = index } }, highest, span),
        .native => |index| try builtin_calls.callBuiltin(self, index, highest),
    }
}

/// Runs a module entry once: later imports of an initialized module do nothing.
pub fn importModule(self: *Machine, instruction: bytecode.Instruction) Error!void {
    if (instruction.a >= self.module_states.len) return self.fail("invalid bytecode module index", .{});
    if (self.module_states[instruction.a] == 1) return self.fail("cyclic module initialization", .{});
    if (self.module_states[instruction.a] == 2) return;
    self.module_states[instruction.a] = 1;
    try enter(self, self.program.modules[instruction.a].entry, 0, instruction.span);
    self.frames.items[self.frames.items.len - 1].module_init = instruction.a;
}

/// A module export is used only after the module has been initialized.
pub fn checkModule(self: *Machine, instruction: bytecode.Instruction) Error!void {
    if (instruction.a >= self.module_states.len or self.module_states[instruction.a] != 2)
        return self.fail("module is not initialized; execute its import before using its exports", .{});
}

/// Calls or partially applies the function value below the arguments.
pub fn callFromStack(self: *Machine, instruction: bytecode.Instruction) Error!void {
    const count: usize = instruction.b;
    if (count >= self.stack.items.len) return self.fail("invalid function call operands", .{});
    const first = self.stack.items.len - count - 1;
    const callee = self.stack.items[first];
    @memmove(self.stack.items[first..][0..count], self.stack.items[first + 1 ..]);
    self.stack.items.len -= 1;
    if (instruction.op == .call_value and instruction.a == 0) {
        try callValue(self, callee, count, instruction.span);
    } else {
        if (callee != .function) return self.fail("expected function", .{});
        if (instruction.a > self.program.argument_names.len) return self.fail("invalid function argument names", .{});
        const names = if (instruction.a == 0) &.{} else self.program.argument_names[instruction.a - 1];
        try applyFunction(self, callee.function, count, names, instruction.op == .bind_function, instruction.span);
    }
}

pub fn bindArguments(self: *Machine, index: u32, count: u32) Error!void {
    if (index >= self.program.argument_bindings.len) return self.fail("invalid bytecode argument binding", .{});
    const binding = self.program.argument_bindings[index];
    if (binding.slots.len != count or binding.parameter_count != count) return self.fail("invalid bytecode argument binding count", .{});
    const args = try self.arguments(count);
    const ordered = try self.gpa.alloc(Value, count);
    defer self.gpa.free(ordered);
    const supplied = try self.gpa.alloc(bool, count);
    defer self.gpa.free(supplied);
    @memset(supplied, false);
    for (args, binding.slots) |arg, slot| {
        if (slot >= count or supplied[slot]) return self.fail("invalid bytecode argument binding slot", .{});
        ordered[slot] = arg;
        supplied[slot] = true;
    }
    @memcpy(args, ordered);
}

pub fn enter(self: *Machine, function_index: u32, count: usize, call_span: Span) Error!void {
    if (function_index >= self.program.functions.len) return self.fail("invalid bytecode function index", .{});
    if (self.frames.items.len + self.outer_call_depth >= self.limits.call_depth) return self.fail("call depth limit ({d}) exceeded", .{self.limits.call_depth});
    const function = self.program.functions[function_index];
    if (!function.acceptsCount(count) or function.parameters.len > function.local_types.len)
        return self.fail("invalid argument count for '{s}'", .{function.name});
    if (function.variadic != null and (function.parameters.len == 0 or function.parameters[function.parameters.len - 1] != .list))
        return self.fail("invalid variadic parameter for '{s}'", .{function.name});
    const fixed = function.fixedCount();
    if (function.default_functions.len != 0 and function.default_functions.len != function.parameters.len) return self.fail("invalid function defaults", .{});
    if (function.defaults.len != 0) {
        var optional = false;
        for (function.defaults[0..fixed], 0..) |value, i| {
            if (value != null or (function.default_functions.len != 0 and function.default_functions[i] != null)) optional = true else if (optional)
                return self.fail("invalid default parameter order for '{s}'", .{function.name});
        }
        if (function.variadic != null and function.defaults[fixed] != null)
            return self.fail("variadic parameter cannot have a default for '{s}'", .{function.name});
    }
    var supplied = count;
    if (function.default_functions.len != 0) while (supplied < fixed) : (supplied += 1) {
        const value = if (function.default_functions[supplied]) |default|
            try self.invokeFunction(.{ .function = .{ .bytecode = default } }, &.{})
        else
            function.defaults[supplied].?;
        try self.push(value);
    };
    const args = try self.arguments(supplied);
    const local_base = self.locals.items.len;
    const new_length = std.math.add(usize, local_base, function.local_types.len) catch return error.OutOfMemory;
    try self.locals.resize(self.gpa, new_length);
    try self.local_initialized.resize(self.gpa, new_length);
    @memset(self.locals.items[local_base..], .unit);
    @memset(self.local_initialized.items[local_base..], false);
    for (function.parameters[0..fixed], 0..) |expected, index| {
        const arg = if (index < args.len) args[index] else function.defaults[index].?;
        self.locals.items[local_base + index] = try validation.coerce(self, try templates.materialize(self, arg), expected);
        self.local_initialized.items[local_base + index] = true;
    }
    if (function.variadic) |element| {
        const remaining = args[@min(fixed, args.len)..];
        for (remaining) |*arg| arg.* = try validation.coerce(self, try templates.materialize(self, arg.*), element);
        self.locals.items[local_base + fixed] = try lists.makeList(self, remaining);
        self.local_initialized.items[local_base + fixed] = true;
    }
    self.stack.items.len -= supplied;
    try self.frames.append(self.gpa, .{ .function = function_index, .local_base = local_base, .stack_base = self.stack.items.len, .call_span = call_span, .call_module = self.current_module });
}
