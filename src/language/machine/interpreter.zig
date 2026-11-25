//! The dispatch loop: one instruction at a time within the instruction budget, task regions, jumps and string constants.
const std = @import("std");
const numeric = @import("../numeric.zig");
const bytecode = @import("../bytecode.zig");
const types = @import("../types.zig");
const Value = types.Value;
const Machine = @import("../Machine.zig");
const templates = @import("templates.zig");
const function_calls = @import("function_calls.zig");
const validation = @import("validation.zig");
const operators = @import("operators.zig");
const lists = @import("lists.zig");
const iteration = @import("iteration.zig");
const builtin_calls = @import("builtin_calls.zig");
const failures = @import("failures.zig");
const aggregates = @import("aggregates.zig");
const typst_requests = @import("typst_requests.zig");
const Error = Machine.Error;

pub fn runUntil(self: *Machine, task_end: ?usize, depth: usize) Error!Value {
    while (self.frames.items.len != 0) {
        const frame_index = self.frames.items.len - 1;
        const function = self.program.functions[self.frames.items[frame_index].function];
        const ip = self.frames.items[frame_index].ip;
        if (task_end) |end| {
            if (frame_index == 0 and ip == end) return templates.materialize(self, try self.pop());
        } else if (self.host.tasks) |schedule| {
            // Only script/module entries contain planned regions. User
            // function loops retain the original interpreter hot path.
            if (frame_index == 0 or self.frames.items[frame_index].module_init != null) {
                if (taskRegion(self, self.frames.items[frame_index].function, ip)) |region| {
                    _ = try schedule.dispatch(self, region);
                }
            }
            if (self.frames.items[frame_index].ip != ip) continue;
        }
        if (ip >= function.code.len) return self.fail("function '{s}' has no return instruction", .{function.name});
        const instruction = function.code[ip];
        self.current_span = instruction.span;
        self.current_module = instruction.module;
        try self.tick();
        self.frames.items[frame_index].ip += 1;
        switch (instruction.op) {
            .import_module => try function_calls.importModule(self, instruction),
            .check_module => try function_calls.checkModule(self, instruction),
            .constant => {
                if (instruction.a >= self.program.constants.len) return self.fail("invalid bytecode constant index", .{});
                // Internal read-only templates can be passed straight to
                // native readers. Stores and returns materialize them.
                const value = self.program.constants[instruction.a];
                if (value != .omitted) try validation.checkFiniteExternal(self, value);
                try self.push(value);
            },
            .load_global => {
                if (instruction.a >= self.globals.len) return self.fail("invalid bytecode global index", .{});
                if (!self.initialized[instruction.a]) return self.fail("variable '{s}' is used before initialization", .{self.program.global_names[instruction.a]});
                try self.push(self.globals[instruction.a]);
            },
            .store_global => {
                if (instruction.a >= self.globals.len) return self.fail("invalid bytecode global index", .{});
                if (self.program.readonly_globals[instruction.a]) return self.fail("parameter '{s}' is read-only", .{self.program.global_names[instruction.a]});
                self.globals[instruction.a] = try validation.coerce(self, try templates.materialize(self, try self.pop()), self.program.global_types[instruction.a]);
                self.initialized[instruction.a] = true;
            },
            .load_local, .store_local => {
                if (instruction.a >= function.local_types.len) return self.fail("invalid bytecode local index", .{});
                const slot = self.frames.items[frame_index].local_base + instruction.a;
                if (instruction.op == .load_local) {
                    if (!self.local_initialized.items[slot]) return self.fail("local variable is used before initialization", .{});
                    try self.push(self.locals.items[slot]);
                } else {
                    self.locals.items[slot] = try validation.coerce(self, try templates.materialize(self, try self.pop()), function.local_types[instruction.a]);
                    self.local_initialized.items[slot] = true;
                }
            },
            .pop => _ = try self.pop(),
            .duplicate => {
                const value = try templates.materialize(self, try self.peek());
                // Both stack entries represent the same evaluated value,
                // including when that value began as a read-only template.
                self.stack.items[self.stack.items.len - 1] = value;
                try self.push(value);
            },
            .add, .subtract, .multiply, .divide, .remainder, .power => {
                const right = try self.pop();
                const left = try self.pop();
                try self.push(try operators.arithmetic(self, instruction.op, left, right));
            },
            .list_append => {
                const right = try self.pop();
                const left = try self.pop();
                try lists.appendList(self, left, right);
            },
            .list_append_items => try lists.appendListItems(self, instruction),
            .positive => try operators.positive(self),
            .negate => try operators.negate(self),
            .logical_not => {
                const value = try validation.boolean(self, try self.pop());
                try self.push(.{ .boolean = !value });
            },
            .equal, .not_equal => {
                const right = try self.pop();
                const left = try self.pop();
                const equal = try operators.valuesEqual(self, left, right);
                try self.push(.{ .boolean = if (instruction.op == .equal) equal else !equal });
            },
            .less, .less_equal, .greater, .greater_equal => {
                const right = try self.pop();
                const left = try self.pop();
                const order = try operators.compare(self, left, right);
                try self.push(.{ .boolean = switch (instruction.op) {
                    .less => order == .lt,
                    .less_equal => order != .gt,
                    .greater => order == .gt,
                    .greater_equal => order != .lt,
                    else => unreachable,
                } });
            },
            .jump => try jump(self, instruction.a),
            .jump_if_false => if (!try validation.boolean(self, try self.pop())) {
                try jump(self, instruction.a);
            },
            .iterate_init => try iteration.iterateInit(self, instruction),
            .iterate_test => try iteration.iterateTest(self),
            .iterate_advance => try iteration.iterateAdvance(self),
            .call => try function_calls.enter(self, instruction.a, instruction.b, instruction.span),
            .call_value, .bind_function => try function_calls.callFromStack(self, instruction),
            .bind_arguments => try function_calls.bindArguments(self, instruction.a, instruction.b),
            .call_builtin => try builtin_calls.callBuiltin(self, instruction.a, instruction.b),
            .return_value => {
                const result = try validation.coerce(self, try templates.materialize(self, try self.pop()), function.result);
                const completed = self.frames.pop().?;
                self.locals.items.len = completed.local_base;
                self.local_initialized.items.len = completed.local_base;
                self.stack.items.len = completed.stack_base;
                if (completed.module_init) |module_index| {
                    self.module_states[module_index] = 2;
                } else {
                    if (self.frames.items.len == depth) return result;
                    try self.push(result);
                }
            },
            .make_vec3 => {
                const z = try self.pop();
                const y = try self.pop();
                const x = try self.pop();
                try self.push(numeric.makeVector(3, .{ x, y, z }) catch |err| return failures.numericFailure(self, err));
            },
            .make_vec2 => {
                const y = try self.pop();
                const x = try self.pop();
                try self.push(numeric.makeVec2(x, y) catch |err| return failures.numericFailure(self, err));
            },
            .make_list => {
                const args = try self.arguments(instruction.a);
                try lists.prepareListItems(self, args);
                const value = try lists.allocateList(self, args);
                value.list.owned.owner = self.identity;
                self.stack.items.len -= instruction.a;
                try self.push(value);
            },
            .make_dict => {
                const count = std.math.mul(usize, instruction.a, 2) catch return self.fail("invalid bytecode dictionary size", .{});
                const args = try self.arguments(count);
                const value = try aggregates.makeDict(self, args);
                self.stack.items.len -= count;
                try self.push(value);
            },
            .make_record => {
                const args = try self.arguments(instruction.b);
                const value = try aggregates.makeRecord(self, instruction.a, args);
                self.stack.items.len -= instruction.b;
                try self.push(value);
            },
            .index => {
                const index_value = try self.pop();
                const object = try self.pop();
                try self.push(try aggregates.readIndex(self, object, index_value));
            },
            .set_index => {
                const value = try self.pop();
                const key = try self.pop();
                const object = try self.pop();
                try aggregates.setIndex(self, object, key, value);
            },
            .slice => try lists.slice(self, instruction),
            .field => try aggregates.readField(self, instruction),
            .set_field => try aggregates.writeField(self, instruction),
            .typst => try typst_requests.typesetBlock(self, instruction, frame_index, function, ip),
            .typst_module => try typst_requests.createModule(self, instruction, function),
            .halt => {
                if (self.frames.items.len != 1) return self.fail("halt is only valid in the script", .{});
                if (self.module_states.len != 0) self.module_states[0] = 2;
                self.frames.clearRetainingCapacity();
                self.locals.clearRetainingCapacity();
                self.local_initialized.clearRetainingCapacity();
                self.stack.clearRetainingCapacity();
                return .unit;
            },
        }
    }
    return .unit;
}

fn taskRegion(self: *const Machine, function: u32, ip: usize) ?*const bytecode.TaskRegion {
    // The compiler emits regions ordered by function and starting offset.
    const Location = struct {
        function: u32,
        ip: usize,

        fn order(key: @This(), region: bytecode.TaskRegion) std.math.Order {
            const by_function = std.math.order(key.function, region.function);
            return if (by_function == .eq) std.math.order(key.ip, @as(usize, region.start)) else by_function;
        }
    };
    const index = std.sort.binarySearch(bytecode.TaskRegion, self.program.task_regions, Location{ .function = function, .ip = ip }, Location.order) orelse return null;
    return &self.program.task_regions[index];
}

pub fn stringConstant(self: *Machine, index: u32) Error![]const u8 {
    if (index >= self.program.constants.len or self.program.constants[index] != .string) return self.fail("invalid bytecode string constant", .{});
    return self.program.constants[index].string;
}

fn jump(self: *Machine, destination: u32) Error!void {
    const frame = &self.frames.items[self.frames.items.len - 1];
    if (destination >= self.program.functions[frame.function].code.len) return self.fail("invalid bytecode jump destination", .{});
    frame.ip = destination;
}
