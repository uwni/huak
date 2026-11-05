//! Linear bytecode with source positions. No AST is needed during execution.
const std = @import("std");
pub const types = @import("types.zig");
pub const source = @import("source.zig");
pub const Type = types.Type;
pub const Value = types.Value;
pub const Span = source.Span;
pub const PrecedenceGroup = @import("precedence.zig").Group;

pub const Op = enum {
    constant,
    load_global,
    store_global,
    load_local,
    store_local,
    pop,
    duplicate,
    add,
    subtract,
    multiply,
    divide,
    remainder,
    power,
    positive,
    negate,
    logical_not,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    jump,
    jump_if_false,
    iterate_init,
    iterate_test,
    iterate_advance,
    call,
    call_builtin,
    /// Callee followed by b arguments; a=0 is positional, otherwise names[a-1].
    call_value,
    bind_function,
    import_module,
    check_module,
    return_value,
    make_pair,
    make_list,
    /// a key/value pairs, in source order.
    make_dict,
    /// a=Program.records index, b=complete field count.
    make_record,
    /// Reorder already evaluated arguments. a=descriptor, b=source count.
    bind_arguments,
    list_append,
    /// target, a literal items -> no result. b=RHS span start; span=append.
    /// Materializes and validates the items before checking the target.
    list_append_items,
    index,
    set_index,
    /// object, start, stop, step -> new shallow list. a=1 omits stop;
    /// its stack slot is unit. a=0 requires an explicit integer stop.
    slice,
    field,
    set_field,
    typst,
    setup_typst,
    halt,
};
pub const Instruction = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    /// Source module, including code expanded into a different module's function.
    /// Hand-built instructions may inherit the containing function's module.
    module: u32 = std.math.maxInt(u32),
    span: Span = .{ .start = 0, .end = 0 },

    pub const StackEffect = struct { consumed: usize, produced: usize };

    /// Stack changes within the current frame. Callee/module execution is
    /// represented by its net effect, independently of the analysis being run.
    pub fn stackEffect(self: Instruction) StackEffect {
        return switch (self.op) {
            .constant, .load_global, .load_local => .{ .consumed = 0, .produced = 1 },
            // Each exposed name is followed by its current value on the stack.
            .typst => .{ .consumed = std.math.mul(usize, self.b, 2) catch std.math.maxInt(usize), .produced = 1 },
            .store_global, .store_local, .pop, .jump_if_false, .return_value => .{ .consumed = 1, .produced = 0 },
            .list_append => .{ .consumed = 2, .produced = 0 },
            .list_append_items => .{ .consumed = @as(usize, self.a) + 1, .produced = 0 },
            .set_index => .{ .consumed = 3, .produced = 0 },
            .set_field => .{ .consumed = 2, .produced = 0 },
            .duplicate => .{ .consumed = 1, .produced = 2 },
            .positive, .negate, .logical_not, .field => .{ .consumed = 1, .produced = 1 },
            .add, .subtract, .multiply, .divide, .remainder, .power, .equal, .not_equal, .less, .less_equal, .greater, .greater_equal, .make_pair, .index => .{ .consumed = 2, .produced = 1 },
            .slice => .{ .consumed = 4, .produced = 1 },
            .iterate_init => .{ .consumed = if (self.a == 0) 3 else 1, .produced = 3 },
            .iterate_test => .{ .consumed = 3, .produced = 2 },
            .iterate_advance => .{ .consumed = 3, .produced = 2 },
            .call, .call_builtin => .{ .consumed = self.b, .produced = 1 },
            .call_value, .bind_function => .{ .consumed = @as(usize, self.b) + 1, .produced = 1 },
            .make_list => .{ .consumed = self.a, .produced = 1 },
            .make_dict => .{ .consumed = std.math.mul(usize, self.a, 2) catch std.math.maxInt(usize), .produced = 1 },
            .make_record => .{ .consumed = self.b, .produced = 1 },
            // The compiler fills b with the count and emits only complete
            // mappings. Program-aware consumers can inspect the descriptor.
            .bind_arguments => .{ .consumed = self.b, .produced = self.b },
            .jump, .import_module, .check_module, .setup_typst, .halt => .{ .consumed = 0, .produced = 0 },
        };
    }

    /// Possible next instructions in this frame; callers validate destinations
    /// against their code slice. ip must identify the current instruction.
    pub fn successors(self: Instruction, ip: usize) [2]?usize {
        return switch (self.op) {
            .return_value, .halt => .{ null, null },
            .jump => .{ self.a, null },
            .jump_if_false => .{ self.a, ip + 1 },
            else => .{ ip + 1, null },
        };
    }
};
pub const Function = struct {
    module: u32 = 0,
    name: []const u8,
    code: []const Instruction,
    parameters: []const Type,
    parameter_names: []const []const u8 = &.{},
    /// Constant default templates, aligned with parameters when nonempty.
    /// Rest slots have no default; a call materializes its missing values.
    defaults: []const ?Value = &.{},
    default_functions: []const ?u32 = &.{},
    /// A variadic function stores its remaining arguments in the final list
    /// parameter. This is the element type used to check each actual argument.
    variadic: ?Type = null,
    result: Type,
    local_types: []const Type,
    span: Span = .{ .start = 0, .end = 0 },

    pub fn fixedCount(self: Function) usize {
        return self.parameters.len -| @intFromBool(self.variadic != null);
    }

    pub fn acceptsCount(self: Function, count: usize) bool {
        if (self.defaults.len != 0 and self.defaults.len != self.parameters.len) return false;
        return count >= self.requiredCount() and (if (self.variadic != null)
            self.parameters.len != 0
        else
            count <= self.fixedCount());
    }

    pub fn requiredCount(self: Function) usize {
        var count = self.fixedCount();
        if (self.defaults.len != self.parameters.len) return count;
        while (count != 0 and (self.defaults[count - 1] != null or (self.default_functions.len == self.parameters.len and self.default_functions[count - 1] != null))) count -= 1;
        return count;
    }
};
pub const Parameter = struct { name: []const u8, kind: Type, default: ?Value, global: u32, span: Span, module: u32 = 0 };
/// Persistent call syntax. Its strings and resolved group belong to Program.
pub const MixfixForm = struct { head: []const u8, parts: []const ?[]const u8, group: u32 };
/// Public binding metadata. Globals are read after execution; functions, types
/// and namespaces resolve during compilation. Export never performs rendering.
pub const Export = struct {
    name: []const u8,
    target: union(enum) { global: u32, function: u32, block: u32, builtin: @import("builtin.zig").Id, precedence: u32, record: u32, namespace: u32 },
    span: Span,
    mixfix: [2]?MixfixForm = .{ null, null },
};
pub const Module = struct { name: []const u8, source_text: []const u8, entry: u32, exports: []const Export };
/// A proven isolated picture computation. [start, end) evaluates its RHS;
/// end identifies the following store_global, which the coordinator commits.
pub const Task = struct {
    function: u32,
    start: u32,
    end: u32,
    global: u32,
    reads: []const u32,
    uses_typst: bool = false,
};
/// Adjacent tasks in one basic block. end is after the final store_global.
/// A read binds to an earlier producer in this region, or to its entry snapshot.
pub const TaskRegion = struct { function: u32, start: u32, end: u32, tasks: []const Task };
pub const RecordField = struct { name: []const u8, kind: Type, span: Span, default_function: ?u32 = null };
pub const Record = struct { name: []const u8, module: u32 = 0, fields: []const RecordField };
/// slots[source index] identifies its destination parameter. Every destination
/// must be supplied once, including defaults evaluated by compiler-emitted code.
pub const ArgumentBinding = struct { slots: []const u32, parameter_count: u32 };
pub const Output = struct { name: []const u8, global: u32, span: Span };

pub const Program = struct {
    outputs: []const Output = &.{},
    arena: std.heap.ArenaAllocator,
    source_text: []const u8,
    name: []const u8,
    functions: []const Function,
    constants: []const Value,
    records: []const Record = &.{},
    argument_bindings: []const ArgumentBinding = &.{},
    argument_names: []const []const ?[]const u8 = &.{},
    parameters: []const Parameter,
    exports: []const Export = &.{},
    modules: []const Module = &.{},
    groups: []const PrecedenceGroup = &.{},
    global_names: []const []const u8,
    global_types: []const Type,
    readonly_globals: []const bool,
    entry: u32 = 0,
    task_regions: []const TaskRegion = &.{},

    pub fn outputNamed(self: *const Program, name: []const u8) ?*const Output {
        for (self.outputs) |*output| if (std.mem.eql(u8, output.name, name)) return output;
        return null;
    }

    pub fn isEntry(self: *const Program, index: usize) bool {
        if (self.entry == index) return true;
        for (self.modules) |module| if (module.entry == index) return true;
        return false;
    }

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
