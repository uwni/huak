//! Calls: finding a call's callee and binding its arguments.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const expressions = @import("expressions.zig");
const inference = @import("inference.zig");
const modules = @import("modules.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const CallableTarget = modules.CallableTarget;
const CallTarget = modules.CallTarget;
const ungroup = ast.ungroup;

const CallParameters = struct {
    names: []const []const u8,
    kinds: []const Type,
    defaults: []const ?Value = &.{},
    default_functions: []const ?u32 = &.{},
    minimum: usize,
    variadic: ?Type = null,
    native_defaults: bool = false,
};

pub fn compileResolvedCall(self: *Compiler, context: *Context, imported_symbol: CallableTarget, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
    const target = imported_symbol.target;
    if (target == .global) {
        const kind = self.build.types.items[target.global];
        if (kind != .function and kind != .any) return self.fail(span, "export '{s}' is not callable", .{call.name});
        if (imported_symbol.module) |module| try context.checkImport(module, imported_symbol.initializer, span);
        _ = try context.emit(.load_global, target.global, 0, span);
        return dynamicCall(self, context, call, skip, span);
    }
    if (target != .function and target != .builtin and target != .record) return self.fail(span, "export '{s}' is not a function or struct", .{call.name});
    if (imported_symbol.module) |module| try context.checkImport(module, imported_symbol.initializer, span);
    return compileCall(self, context, target, call, skip, span);
}

pub fn callFunction(self: *const Compiler, index: u32) bc.Function {
    return if (index < self.function_base) self.build.functions.items[index] else self.output.items[index - self.function_base];
}

pub fn functionValue(self: *Compiler, context: *Context, target: CallTarget, span: Span) !Type {
    const value: @import("../types.zig").Function = switch (target) {
        .function => |index| .{ .bytecode = index },
        .builtin => |id| .{ .native = @backingInt(id) },
        else => return self.fail(span, "only functions can be used as callable values", .{}),
    };
    try context.constant(.{ .function = value }, span);
    return .function;
}

pub fn dynamicCall(self: *Compiler, context: *Context, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) !Type {
    for (call.args[skip..]) |arg| _ = try expressions.compileExpression(self, context, arg);
    _ = try context.emit(.call_value, try callNames(self, call.argument_names, skip, span), try self.narrow(call.args.len - skip, span), span);
    return .any;
}

pub fn callNames(self: *Compiler, names: []const ?[]const u8, skip: usize, span: Span) !u32 {
    if (names.len == 0) return 0;
    try self.build.argument_names.append(self.allocator, try self.allocator.dupe(?[]const u8, names[skip..]));
    return self.narrow(self.build.argument_names.items.len, span);
}

pub fn compileCall(self: *Compiler, context: *Context, target: CallTarget, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
    switch (target) {
        inline .function, .builtin => |index, kind| {
            const callee = if (kind == .function) callFunction(self, index) else builtin.signature(index);
            const fixed = if (kind == .function) callee.parameters[0..callee.fixedCount()] else callee.args;
            const minimum = if (kind == .function) callee.requiredCount() else callee.minimum;
            const names = if (kind == .function) callee.parameter_names[0..callee.fixedCount()] else callee.parameter_names;
            const args = call.args[skip..];
            const offset: usize = 0;
            const count = if (call.argument_names.len != 0)
                try compileBoundArguments(self, context, call, skip, offset, .{ .names = names, .kinds = fixed, .defaults = if (kind == .function) callee.defaults else &.{}, .default_functions = if (kind == .function) callee.default_functions else &.{}, .minimum = minimum, .variadic = callee.variadic, .native_defaults = kind == .builtin }, span)
            else count: {
                try compileArguments(self, context, call.name, args, offset, fixed, minimum, callee.variadic, span);
                break :count args.len + offset;
            };
            _ = try context.emit(if (kind == .function) .call else .call_builtin, if (kind == .function) index else @backingInt(index), try self.narrow(count, span), span);
            return if (kind == .builtin) inference.builtinResult(self, context, callee, args) else callee.result;
        },
        .record => |index| return compileRecordCall(self, context, index, call, skip, span),
        else => unreachable,
    }
}

pub fn compileRecordCall(self: *Compiler, context: *Context, index: u32, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
    const record = self.build.records.items[index];
    const names = try self.allocator.alloc([]const u8, record.fields.len);
    const kinds = try self.allocator.alloc(Type, record.fields.len);
    const defaults = try self.allocator.alloc(?u32, record.fields.len);
    for (record.fields, names, kinds, defaults) |field, *name, *kind, *default| {
        name.* = field.name;
        kind.* = field.kind;
        default.* = field.default_function;
    }
    const count = try compileBoundArguments(self, context, call, skip, 0, .{ .names = names, .kinds = kinds, .default_functions = defaults, .minimum = 0 }, span);
    _ = try context.emit(.make_record, index, try self.narrow(count, span), span);
    return Type.record(index);
}

/// Evaluate explicit arguments once, in source order, then materialize only
/// the missing defaults and permute the resulting values into parameter slots.
pub fn compileBoundArguments(self: *Compiler, context: *Context, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, offset: usize, parameters: CallParameters, span: Span) anyerror!usize {
    const args = call.args[skip..];
    const labels = if (call.argument_names.len == 0) &.{} else call.argument_names[skip..];
    const used = try self.allocator.alloc(bool, parameters.kinds.len);
    @memset(used, false);
    var slots: std.ArrayList(u32) = .empty;
    for (0..offset) |index| {
        if (index >= used.len) return self.fail(span, "too many implicit arguments", .{});
        used[index] = true;
        try slots.append(self.allocator, @intCast(index));
    }
    var positional = offset;
    var highest = offset;
    for (args, 0..) |argument, source_index| {
        const label = if (labels.len == 0) null else labels[source_index];
        const destination = if (label) |wanted| named: {
            for (parameters.names, 0..) |name, index| if (std.mem.eql(u8, name, wanted)) break :named index;
            return self.fail(argument.span, "unknown argument '{s}' for '{s}'", .{ wanted, call.name });
        } else positional;
        if (label == null) positional += 1;
        if (destination < used.len) {
            if (used[destination]) return self.fail(argument.span, "argument '{s}' supplied more than once", .{parameters.names[destination]});
            used[destination] = true;
        } else if (parameters.variadic == null) return self.fail(argument.span, "too many arguments for '{s}'", .{call.name});
        const kind = if (destination < parameters.kinds.len) parameters.kinds[destination] else parameters.variadic.?;
        try self.require(kind, try expressions.compileExpression(self, context, argument), argument.span);
        try slots.append(self.allocator, try self.narrow(destination, argument.span));
        highest = @max(highest, destination + 1);
    }
    const fixed_count = if (parameters.native_defaults) @max(highest, parameters.minimum) else parameters.kinds.len;
    for (0..@min(fixed_count, used.len)) |index| {
        if (used[index]) continue;
        if (index < parameters.default_functions.len and parameters.default_functions[index] != null) {
            _ = try context.emit(.call, parameters.default_functions[index].?, 0, span);
        } else if (index < parameters.defaults.len and parameters.defaults[index] != null) {
            try context.constant(parameters.defaults[index].?, span);
        } else if (parameters.native_defaults and index >= parameters.minimum) {
            try context.constant(.omitted, span);
        } else return self.fail(span, "missing argument '{s}' for '{s}'", .{ parameters.names[index], call.name });
        try slots.append(self.allocator, @intCast(index));
    }
    var ordered = true;
    for (slots.items, 0..) |slot, index| if (slot != index) {
        ordered = false;
        break;
    };
    if (!ordered) {
        const index = try self.narrow(self.build.argument_bindings.items.len, span);
        const count = try self.narrow(slots.items.len, span);
        try self.build.argument_bindings.append(self.allocator, .{ .slots = try slots.toOwnedSlice(self.allocator), .parameter_count = count });
        const binding = &self.build.argument_bindings.items[index];
        _ = try context.emit(.bind_arguments, index, binding.parameter_count, span);
        return binding.parameter_count;
    }
    return slots.items.len;
}

pub fn compileArguments(self: *Compiler, context: *Context, name: []const u8, args: []const *ast.Expr, offset: usize, fixed: []const Type, minimum: usize, variadic: ?Type, span: Span) anyerror!void {
    const count = args.len + offset;
    if (count < minimum or (variadic == null and count > fixed.len)) {
        if (variadic != null) return self.fail(span, "function '{s}' expects at least {d} arguments, found {d}", .{ name, minimum, count });
        if (minimum == fixed.len) return self.fail(span, "function '{s}' expects {d} arguments, found {d}", .{ name, minimum, count });
        return self.fail(span, "function '{s}' expects {d}..{d} arguments, found {d}", .{ name, minimum, fixed.len, count });
    }
    for (args, 0..) |argument, i| {
        const kind = if (i + offset < fixed.len) fixed[i + offset] else variadic.?;
        try self.require(kind, try expressions.compileExpression(self, context, argument), argument.span);
    }
}

/// A call: partial application, native namespaces, module members, bindings and declared functions.
pub fn compileCallExpression(self: *Compiler, context: *Context, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), span: Span) anyerror!Type {
    if (call.qualified) |name| return compileResolvedCall(self, context, try modules.qualifiedTarget(self, name.*), call, 0, span);
    if (call.dot and std.mem.eql(u8, call.name, "with")) {
        try self.require(.function, try expressions.compileExpression(self, context, call.args[0]), call.args[0].span);
        for (call.args[1..]) |arg| _ = try expressions.compileExpression(self, context, arg);
        _ = try context.emit(.bind_function, try callNames(self, call.argument_names, 1, span), try self.narrow(call.args.len - 1, span), span);
        return .function;
    }
    if (call.dot and call.args.len != 0 and ungroup(call.args[0]).value == .name) {
        if (modules.defaultNamespace(self, context, ungroup(call.args[0]).value.name, span)) |native| {
            const signature = builtin.namespaceLookup(native, call.name) orelse return self.fail(span, "{s} has no function '{s}'", .{ native.name(), call.name });
            return compileCall(self, context, .{ .builtin = signature.id }, call, 1, span);
        }
    }
    if (call.dot and call.args.len != 0) if (modules.moduleExpression(self, call.args[0])) |module_index| {
        const exposed = try modules.importedExport(self, module_index, call.name, span);
        return compileResolvedCall(self, context, .{ .module = module_index, .initializer = modules.moduleInitializer(self, call.args[0]), .target = exposed.target }, call, 1, span);
    };
    const scoped_call = self.environment.unit.resolverAt(span.start).callable(self.environment.unit.scopeAt(span.start), call.name);
    if (context.resolve(call.name, span)) |binding| {
        if (binding.symbol.kind != .function and binding.symbol.kind != .any) return self.fail(span, "binding '{s}' is not callable", .{call.name});
        try context.load(binding, span);
        return dynamicCall(self, context, call, 0, span);
    }
    if (scoped_call.shadowed) return self.fail(span, "binding '{s}' is not callable", .{call.name});
    const target = (if (scoped_call.namespace) |owner| modules.namespaceCallTarget(self, owner, call.name) else modules.callTarget(self, call.name, scoped_call.member)) orelse {
        if (scoped_call.namespace != null) return self.fail(span, "module namespace '{s}' is not callable", .{call.name});
        if (scoped_call.member != null) return self.fail(span, "struct declarations must be at script top level", .{});
        return self.fail(span, "unknown function '{s}'; import its module before calling it", .{call.name});
    };
    if (scoped_call.namespace) |module_index| {
        try context.checkImport(module_index, scoped_call.namespace_initializer, span);
    } else if (scoped_call.member) |member| if (member.module != self.environment.module_index) {
        return compileResolvedCall(self, context, .{ .module = member.module, .initializer = member.initializer, .target = target }, call, 0, span);
    };
    return compileCall(self, context, target, call, 0, span);
}
