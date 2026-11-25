//! Statements: the dispatcher, assignments, mutations through members, indexes and list appends, and top-level declarations.
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Span = source.Span;
const typst = @import("typst.zig");
const expressions = @import("expressions.zig");
const blocks = @import("blocks.zig");
const modules = @import("modules.zig");
const control = @import("control.zig");
const symbols = @import("symbols.zig");
const evaluation = @import("evaluation.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const ungroup = ast.ungroup;

pub fn compileStatements(self: *Compiler, context: *Context, statements_: []const *ast.Stmt) anyerror!void {
    context.block_depth += 1;
    defer context.block_depth -= 1;
    for (statements_) |statement| try compileStatement(self, context, statement);
}

pub fn compileAssignment(self: *Compiler, context: *Context, name: []const u8, value: *ast.Expr, span: Span) !void {
    const binding = context.resolve(name, span) orelse return self.fail(span, "name '{s}' is not an assignable value", .{name});
    if (binding.local and span.start < binding.declaration)
        return self.fail(span, "local variable assigned before its declaration", .{});
    if (binding.symbol.readonly) return self.fail(span, "cannot assign readonly parameter '{s}'", .{name});
    // A module assigned to a name is named after it, like a file.
    const actual = if (value.value == .typst_module) try typst.compileTypstModule(self, context, value.value.typst_module, value.span, name) else try expressions.compileExpression(self, context, value);
    if (binding.symbol.inferable) {
        if (binding.local) {
            context.locals.getPtr(binding.declaration).?.kind = actual;
            context.locals.getPtr(binding.declaration).?.inferable = false;
            context.local_types.items[binding.symbol.index] = actual;
        } else {
            self.environment.globals.getPtr(name).?.kind = actual;
            self.environment.globals.getPtr(name).?.inferable = false;
            self.global_types.items[binding.symbol.index - self.global_base] = actual;
        }
    } else try self.require(binding.symbol.kind, actual, value.span);
    try context.store(binding, span);
}

pub fn compileStatement(self: *Compiler, context: *Context, statement_: *ast.Stmt) anyerror!void {
    const span = statement_.span;
    switch (statement_.value) {
        .expression => |expression| {
            _ = try expressions.compileExpression(self, context, expression);
            _ = try context.emit(.pop, 0, 0, span);
        },
        .expand_block, .default_output, .exported, .parameter, .function, .structure, .precedence_group => try compileDeclaration(self, context, statement_),
        .insertion => try blocks.compileInsertion(self, context, span),
        .assignment => |assignment| try compileAssignment(self, context, assignment.name, assignment.value, span),
        .set, .list_append, .append_to => try compileMutation(self, context, statement_),
        .imported => {
            if (modules.importInitializer(self, span)) |module| _ = try context.emit(.import_module, module, 0, span);
        },
        .mixfix_binding => |binding| {
            if (binding.target.namespace == null) if (context.resolve(binding.target.name, span)) |value| {
                try self.require(.function, value.symbol.kind, span);
                if (value.local and span.start < value.symbol.available_after)
                    return self.fail(span, "mixfix function used before its declaration is complete", .{});
            };
        },
        // A show path is lexical metadata, not an evaluated statement. It
        // is checked here, where template bodies still see the expansion's
        // locals, and loaded again by each typ block in its scope.
        .typst_show => |path| _ = try typst.typstShowBase(self, context, path, span),
        .return_value, .break_loop, .continue_loop, .conditional, .while_loop, .for_loop => try control.compileControl(self, context, statement_),
    }
}

/// Assignments through a member or an index, and list appends.
pub fn compileMutation(self: *Compiler, context: *Context, statement_: *ast.Stmt) anyerror!void {
    const span = statement_.span;
    switch (statement_.value) {
        .set => |assignment| {
            const target = ungroup(assignment.target);
            switch (target.value) {
                .member => |member| {
                    const object = try expressions.compileExpression(self, context, member.object);
                    const field_index = try self.recordField(object, member.name, target.span);
                    if (field_index == null and object != .any) return self.fail(target.span, "type {s} has no writable field '{s}'", .{ self.typeName(object), member.name });
                    const actual = try expressions.compileExpression(self, context, assignment.value);
                    if (field_index) |index| try self.require(self.build.records.items[object.recordIndex().?].fields[index].kind, actual, assignment.value.span);
                    _ = try context.emit(.set_field, try self.addConstant(.{ .string = member.name }, target.span), if (field_index) |index| try self.narrow(index + 1, target.span) else 0, span);
                },
                .index => |index| {
                    const object = try expressions.compileExpression(self, context, index.object);
                    if (object != .list and object != .dict and object != .any) return self.fail(target.span, "indexed assignment requires a list or dictionary", .{});
                    const key = try expressions.compileExpression(self, context, index.index);
                    if (object == .list) try self.require(.int, key, index.index.span);
                    if (object == .dict) try self.require(.string, key, index.index.span);
                    _ = try expressions.compileExpression(self, context, assignment.value);
                    _ = try context.emit(.set_index, 0, 0, span);
                },
                else => return self.fail(target.span, "invalid assignment target", .{}),
            }
        },
        .list_append => |append| {
            const binding = context.resolve(append.name, span) orelse return self.fail(span, "unknown list variable '{s}'", .{append.name});
            if (binding.symbol.readonly and binding.module == null) return self.fail(span, "cannot modify readonly parameter '{s}'", .{append.name});
            try self.require(.list, binding.symbol.kind, span);
            try context.load(binding, span);
            _ = try expressions.compileExpression(self, context, append.value);
            _ = try context.emit(.list_append, 0, 0, span);
        },
        .append_to => |append| {
            try self.require(.list, try expressions.compileExpression(self, context, append.target), append.target.span);
            _ = try expressions.compileExpression(self, context, append.value);
            _ = try context.emit(.list_append, 0, 0, span);
        },
        else => unreachable,
    }
}

/// Declarations allowed only at script top level, and the default output.
pub fn compileDeclaration(self: *Compiler, context: *Context, statement_: *ast.Stmt) anyerror!void {
    const span = statement_.span;
    switch (statement_.value) {
        .expand_block => |definition| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "expand_block declarations must be at script top level", .{});
            if (definition.exported) try modules.exportName(self, definition.name, span, span, .block);
        },
        .default_output => |value| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "default output must be at script top level", .{});
            if (self.default_output != null) return self.fail(span, "duplicate default output", .{});
            try self.require(.picture, try expressions.compileExpression(self, context, value), value.span);
            try symbols.declareGlobal(self, "<default>", .picture, false, false, span);
            const slot = self.environment.globals.get("<default>").?.index;
            self.default_output = .{ .name = bc.Output.default_name, .global = slot, .span = span };
            _ = try context.emit(.store_global, slot, 0, span);
        },
        .exported => |exported| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "export declarations must be at script top level", .{});
            if (exported.value) |value| try compileAssignment(self, context, exported.names[0].name, value, span);
            for (exported.names) |name| try modules.exportName(self, name.name, span, name.span, null);
        },
        .parameter => |parameter| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "param declarations must be at script top level", .{});
            const binding = self.environment.globals.get(parameter.name).?;
            switch (binding.kind) {
                .int, .number, .boolean, .string, .length, .angle => {},
                else => return self.fail(if (parameter.annotation) |annotation| annotation.span else span, "command-line parameters support int, float, bool, string, length, and angle", .{}),
            }
            const default = if (parameter.default) |expression| try evaluation.constantValue(self, expression, null) else null;
            if (default) |value| try self.require(binding.kind, value.valueType(), parameter.default.?.span);
            if (self.environment.module_index != 0 and default == null) return self.fail(span, "imported module parameter '{s}' requires a default", .{parameter.name});
            try self.parameters.append(.{ .name = parameter.name, .kind = binding.kind, .default = default, .global = binding.index, .span = span, .module = self.environment.module_index });
        },
        .function => |function| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "functions must be declared at script top level", .{});
            if (function.exported) try modules.exportName(self, function.name, span, span, .function);
        },
        .structure => |structure| {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "struct declarations must be at script top level", .{});
            if (structure.exported) try modules.exportName(self, structure.name, span, span, .record);
        },
        .precedence_group => {
            if (!context.entry or context.block_depth != 1) return self.fail(span, "precedence declarations must be at script top level", .{});
        },
        else => unreachable,
    }
}

pub fn definitelyReturns(statements: []const *ast.Stmt) bool {
    for (statements) |statement| switch (statement.value) {
        .return_value => return true,
        .conditional => |conditional| {
            if (conditional.otherwise.len == 0 or !definitelyReturns(conditional.otherwise)) continue;
            var all = true;
            for (conditional.branches) |branch| if (!definitelyReturns(branch.body)) {
                all = false;
                break;
            };
            if (all) return true;
        },
        else => {},
    };
    return false;
}
