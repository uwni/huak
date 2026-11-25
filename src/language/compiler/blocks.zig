//! Block expressions, and expand_block templates with their insertion.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const ModuleGraph = @import("../ModuleGraph.zig");
const statements = @import("statements.zig");
const evaluation = @import("evaluation.zig");
const calls = @import("calls.zig");
const symbols = @import("symbols.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const Symbol = symbols.Symbol;
const Environment = symbols.Environment;
const definitelyReturns = statements.definitelyReturns;

/// Compile-time return destination; block expressions use ordinary local slots
/// and branches, without allocating a runtime scope or call frame.
pub const ReturnBlock = struct {
    slot: u32,
    kind: ?Type = null,
    stack_depth: usize,
    exits: std.ArrayList(u32) = .empty,
};

pub const Expansion = struct {
    parent: ?*Expansion,
    definition: *ModuleGraph.Unit,
    definition_body: Span,
    definition_locals: std.AutoHashMapUnmanaged(usize, Symbol),
    insertion_position: usize,
    environment: *Environment,
    scope: Parser.ScopeId,
    locals: std.AutoHashMapUnmanaged(usize, Symbol),
    body: []const *ast.Stmt,
    insertion_parent: ?*Expansion,
    inserted: bool = false,
};

/// A block expression: its statements, with a slot for the value it returns.
pub fn compileBlock(self: *Compiler, context: *Context, body: []const *ast.Stmt, span: Span) anyerror!Type {
    var block: ReturnBlock = .{
        .slot = try context.temporary(.any, span),
        .stack_depth = context.stack_depth,
    };
    const previous = context.return_block;
    context.return_block = &block;
    defer context.return_block = previous;
    try statements.compileStatements(self, context, body);
    return finishBlock(self, context, &block, !definitelyReturns(body), span);
}

pub fn finishBlock(self: *Compiler, context: *Context, block: *ReturnBlock, fallthrough: bool, span: Span) !Type {
    _ = self;
    if (fallthrough) {
        block.kind = if (block.kind == null or block.kind == .unit) .unit else .any;
        try context.constant(.unit, span);
        _ = try context.emit(.store_local, block.slot, 0, span);
    }
    for (block.exits.items) |exit| try context.patch(exit, context.code.items.len);
    _ = try context.emit(.load_local, block.slot, 0, span);
    return block.kind orelse .unit;
}

pub fn compileInsertion(self: *Compiler, context: *Context, span: Span) !void {
    const insertion = context.insertion orelse return self.fail(span, "'...' requires an expand_block definition", .{});
    const owner = self.environment;
    const locals = context.locals;
    const pending = context.insertion;
    defer {
        self.environment = owner;
        context.locals = locals;
        context.insertion = pending;
    }
    self.environment = insertion.environment;
    context.locals = insertion.locals;
    context.insertion = insertion.insertion_parent;
    try statements.compileStatements(self, context, insertion.body);
    insertion.inserted = true;
}

pub fn compileExpansion(self: *Compiler, context: *Context, invocation: @FieldType(@FieldType(ast.Expr, "value"), "expansion"), span: Span) anyerror!Type {
    const definition = invocation.definition.value.expand_block;
    const caller = self.environment;
    const caller_locals = context.locals;
    const parent_expansion = context.expansion;
    const parent_insertion = context.insertion;
    const parent_return = context.return_block;
    defer {
        self.environment = caller;
        context.locals = caller_locals;
        context.expansion = parent_expansion;
        context.insertion = parent_insertion;
        context.return_block = parent_return;
    }
    const owner = self.build.environments[invocation.module];
    if (owner != caller) {
        const resolver = caller.unit.resolverAt(span.start);
        const scope = caller.unit.scopeAt(span.start);
        const initializer = if (invocation.name.namespace) |namespace|
            resolver.namespaceInitializer(scope, namespace[0 .. std.mem.indexOfScalar(u8, namespace, '.') orelse namespace.len])
        else if (resolver.callable(scope, invocation.name.name).member) |member|
            (if (member.initializer == std.math.maxInt(u32)) null else member.initializer)
        else
            null;
        try context.checkImport(invocation.module, initializer, span);
    }
    self.environment = owner;
    const params = definition.params;
    const variadic = params.len != 0 and params[params.len - 1].variadic;
    const fixed = params.len - @intFromBool(variadic);
    const kinds = try self.build.syntax_allocator.alloc(Type, params.len);
    const names = try self.build.syntax_allocator.alloc([]const u8, fixed);
    const defaults = try self.build.syntax_allocator.alloc(?Value, fixed);
    @memset(defaults, null);
    var minimum = fixed;
    for (params, 0..) |param, i| {
        kinds[i] = try self.typeOf(param.annotation);
        if (i < fixed) {
            names[i] = param.name;
            if (param.default) |expression| {
                defaults[i] = try evaluation.constantValue(self, expression, params);
                try self.require(kinds[i], defaults[i].?.valueType(), expression.span);
                minimum = @min(minimum, i);
            }
        }
    }
    self.environment = caller;
    const count = try calls.compileBoundArguments(self, context, .{ .name = definition.name, .args = invocation.args, .argument_names = invocation.argument_names }, 0, 0, .{ .names = names, .kinds = kinds[0..fixed], .defaults = defaults, .minimum = minimum, .variadic = if (variadic) kinds[fixed] else null }, span);
    if (variadic) _ = try context.emit(.make_list, @intCast(count - fixed), 0, span);
    // Validate/store parameters in declaration order, as ordinary calls do.
    if (params.len > 1) {
        const slots = try self.allocator.alloc(u32, params.len);
        for (slots, 0..) |*slot, i| slot.* = @intCast(params.len - 1 - i);
        const index: u32 = @intCast(self.build.argument_bindings.items.len);
        try self.build.argument_bindings.append(.{ .slots = slots, .parameter_count = @intCast(params.len) });
        _ = try context.emit(.bind_arguments, index, @intCast(params.len), span);
    }
    self.environment = owner;
    context.locals = .{};
    for (params, 0..) |param, i| {
        try symbols.declareLocal(self, context, param.name, if (param.variadic) .list else kinds[i], false, param.span);
        const store = try context.emit(.store_local, context.locals.get(param.span.start).?.index, 0, span);
        context.code.items[store].module = caller.module_index;
    }
    try symbols.collectLocals(self, context, definition.body);
    var scope_id: Parser.ScopeId = 0;
    for (owner.unit.headers.expansions) |header| if (header.statement == invocation.definition) {
        scope_id = header.scope;
        break;
    };
    var expansion: Expansion = .{ .parent = parent_expansion, .definition = owner.unit, .definition_body = owner.unit.headers.scopes[scope_id].body, .definition_locals = context.locals, .insertion_position = owner.unit.headers.scopes[scope_id].insertion.?, .environment = caller, .scope = invocation.scope, .locals = caller_locals, .body = invocation.body, .insertion_parent = parent_insertion };
    context.expansion = &expansion;
    var block: ReturnBlock = .{ .slot = try context.temporary(.any, span), .stack_depth = context.stack_depth };
    context.return_block = &block;
    context.insertion = &expansion;
    try statements.compileStatements(self, context, definition.body);
    const kind = try finishBlock(self, context, &block, !definitelyReturns(definition.body), invocation.definition.span);
    if (definition.result) |annotation| try self.require(try self.typeOf(annotation), kind, annotation.span);
    return kind;
}
