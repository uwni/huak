//! Name tables, and declaring globals, locals, record types and default-expression functions.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Span = source.Span;
const ModuleGraph = @import("../ModuleGraph.zig");
const evaluation = @import("evaluation.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");

pub const Symbol = struct { index: u32, kind: Type, readonly: bool = false, inferable: bool = false, available_after: usize = 0 };

const Names = std.StringHashMapUnmanaged(Symbol);

pub const Binding = struct { symbol: Symbol, local: bool, declaration: usize = 0, module: ?u32 = null, initializer: ?u32 = null };

pub const ExpressionDefault = struct { expression: *ast.Expr, function: u32, kind: Type, span: Span };

pub const Environment = struct {
    globals: Names = .{},
    functions: std.StringHashMapUnmanaged(u32) = .{},
    records: std.StringHashMapUnmanaged(u32) = .{},
    group_names: std.StringHashMapUnmanaged(u32) = .{},
    unit: *ModuleGraph.Unit,
    module_index: u32,
};

pub fn parameterType(self: *Compiler, parameter: @FieldType(@FieldType(ast.Stmt, "value"), "parameter")) !Type {
    if (parameter.annotation) |annotation| return self.typeOf(annotation);
    return (try evaluation.constantValue(self, parameter.default.?, null)).valueType();
}

pub fn declareGlobal(self: *Compiler, name: []const u8, kind: Type, readonly: bool, inferable: bool, span: Span) !void {
    if (self.environment.globals.contains(name)) return self.fail(span, "duplicate declaration '{s}'", .{name});
    const index = try self.narrow(self.global_names.items.len + self.global_base, span);
    try self.environment.globals.put(self.allocator, name, .{ .index = index, .kind = kind, .readonly = readonly, .inferable = inferable });
    try self.global_names.append(self.allocator, name);
    try self.global_types.append(self.allocator, kind);
    try self.readonly_globals.append(self.allocator, readonly);
}

pub fn collectGlobals(self: *Compiler, statements: []const *ast.Stmt) !void {
    var visitor: Declarations = .{ .compiler = self };
    try ast.walkStatements(&visitor, statements);
}

pub fn collectLocals(self: *Compiler, context: *Context, statements: []const *ast.Stmt) !void {
    var visitor: Declarations = .{ .compiler = self, .context = context };
    try ast.walkStatements(&visitor, statements);
}

pub const Declarations = struct {
    compiler: *Compiler,
    context: ?*Context = null,

    fn declare(self: *Declarations, name: []const u8, kind: Type, readonly: bool, inferable: bool, span: Span) !void {
        const global = self.compiler.environment.unit.scopeAt(span.start) == 0;
        if (self.context) |context| {
            if (context.entry and global) return;
            try declareLocal(self.compiler, context, name, kind, inferable, span);
        } else if (global) try declareGlobal(self.compiler, name, kind, readonly, inferable, span);
    }
    pub fn enter(self: *Declarations, node: ast.Node) !bool {
        if (node != .statement) return true;
        const statement = node.statement;
        switch (statement.value) {
            .function, .structure, .expand_block => return false,
            .assignment => |value| if (value.declaration) {
                try self.declare(value.name, if (value.annotation) |annotation| try self.compiler.typeOf(annotation) else .any, false, value.annotation == null, statement.span);
            },
            .parameter => |value| if (self.context == null) {
                try self.declare(value.name, try parameterType(self.compiler, value), true, false, statement.span);
            },
            .exported => |value| if (value.value != null) {
                try self.declare(value.names[0].name, .any, false, true, statement.span);
            },
            .for_loop => |value| if (self.context) |context| {
                try declareLocal(self.compiler, context, value.name, .any, true, value.name_span);
            },
            else => {},
        }
        return true;
    }
};

pub fn declareLocal(self: *Compiler, context: *Context, name: []const u8, kind: Type, inferable: bool, span: Span) !void {
    if (context.locals.contains(span.start)) return self.fail(span, "duplicate declaration '{s}'", .{name});
    const index = try context.temporary(kind, span);
    try context.locals.put(self.allocator, span.start, .{ .index = index, .kind = kind, .inferable = inferable, .available_after = span.end });
}

pub fn declareRecords(self: *Compiler) !void {
    for (self.environment.unit.script.statements) |statement| {
        if (statement.value != .structure) continue;
        const structure = statement.value.structure;
        if (self.environment.records.contains(structure.name) or Type.parse(structure.name) != null)
            return self.fail(statement.span, "duplicate or builtin type '{s}'", .{structure.name});
        const index = try self.narrow(self.build.records.items.len, statement.span);
        try self.environment.records.put(self.allocator, structure.name, index);
        try self.build.records.append(self.allocator, .{ .name = structure.name, .module = self.environment.module_index, .fields = &.{} });
    }
    for (self.environment.unit.script.statements) |statement| {
        if (statement.value != .structure) continue;
        const structure = statement.value.structure;
        const fields = try self.allocator.alloc(bc.RecordField, structure.fields.len);
        for (structure.fields, fields, 0..) |field, *destination, index| {
            for (structure.fields[0..index]) |previous| if (std.mem.eql(u8, previous.name, field.name))
                return self.fail(field.span, "duplicate field '{s}'", .{field.name});
            destination.* = .{ .name = field.name, .kind = try self.typeOf(field.annotation), .span = field.span };
        }
        self.build.records.items[self.environment.records.get(structure.name).?].fields = fields;
    }
}

pub fn declareExpressionDefaults(self: *Compiler) !void {
    for (self.environment.unit.script.statements) |statement| {
        if (statement.value != .structure) continue;
        const structure = statement.value.structure;
        const record_index = self.environment.records.get(structure.name).?;
        for (structure.fields, 0..) |field, index| {
            const expression = field.default orelse continue;
            const function = try self.narrow(self.output.items.len + self.function_base, field.span);
            const kind = self.build.records.items[record_index].fields[index].kind;
            @constCast(self.build.records.items[record_index].fields)[index].default_function = function;
            try self.output.append(self.allocator, .{
                .module = self.environment.module_index,
                .name = try self.allocator.print("<{s}.{s} default>", .{ structure.name, field.name }),
                .code = &.{},
                .parameters = &.{},
                .result = kind,
                .local_types = &.{},
                .span = field.span,
            });
            try self.expression_defaults.append(self.allocator, .{ .expression = expression, .function = function, .kind = kind, .span = field.span });
        }
    }
    // Function defaults use the same expression functions as struct fields.
    // Literal defaults remain immutable Program values and need no call.
    for (self.declarations.items[1..], 1..) |declaration, function_index| {
        const function = declaration.?.value.function;
        for (function.params, 0..) |param, parameter_index| {
            const expression = param.default orelse continue;
            if (self.output.items[function_index].defaults[parameter_index] != null) continue;
            if (self.output.items[function_index].default_functions.len == 0) {
                const slots = try self.allocator.alloc(?u32, function.params.len);
                @memset(slots, null);
                self.output.items[function_index].default_functions = slots;
            }
            const index: u32 = @intCast(self.output.items.len + self.function_base);
            const kind = self.output.items[function_index].parameters[parameter_index];
            @constCast(self.output.items[function_index].default_functions)[parameter_index] = index;
            try self.output.append(self.allocator, .{ .module = self.environment.module_index, .name = try self.allocator.print("<{s}.{s} default>", .{ function.name, param.name }), .code = &.{}, .parameters = &.{}, .result = kind, .local_types = &.{}, .span = param.span });
            try self.expression_defaults.append(self.allocator, .{ .expression = expression, .function = index, .kind = kind, .span = param.span });
        }
    }
}
