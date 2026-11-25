//! A unit's precedence groups and relations, and checking each mixfix binding against its callee.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const builtin = @import("../builtin.zig");
const Span = source.Span;
const precedence = @import("../precedence.zig");
const modules = @import("modules.zig");
const calls = @import("calls.zig");
const Compiler = @import("Compiler.zig");

pub fn groupNamed(self: *Compiler, name: ast.OperatorName) !u32 {
    const previous = self.environment;
    if (name.module) |module| self.environment = self.build.environments[module];
    defer self.environment = previous;
    if (name.namespace) |alias| {
        const owner = modules.imported(self, alias, name.span) orelse return self.fail(name.span, "unknown module namespace '{s}'", .{alias});
        const exposed = try modules.importedExport(self, owner, name.name, name.span);
        if (exposed.target != .precedence) return self.fail(name.span, "export '{s}' is not a precedence group", .{name.name});
        return exposed.target.precedence;
    }
    if (self.environment.unit.resolverAt(name.span.start).precedence(self.environment.unit.scopeAt(name.span.start), name.name)) |member| return modules.memberExport(self, member).target.precedence;
    if (self.environment.group_names.get(name.name)) |id| return id;
    return precedence.builtinNamed(name.name) orelse self.fail(name.span, "unknown precedence group '{s}'", .{name.name});
}

pub fn collectPrecedence(self: *Compiler) !void {
    const table = &self.build.precedence;
    const scratch = self.build.syntax_allocator;
    for (self.environment.unit.script.statements) |statement| {
        if (statement.value != .precedence_group) continue;
        const group = statement.value.precedence_group;
        if (self.environment.group_names.contains(group.name)) return self.fail(statement.span, "duplicate precedence group '{s}'", .{group.name});
        if (self.environment.unit.resolverAt(statement.span.start).precedence(0, group.name) != null or modules.imported(self, group.name, statement.span) != null)
            return self.fail(statement.span, "precedence group '{s}' conflicts with an imported name", .{group.name});
        if (precedence.builtinNamed(group.name) != null) return self.fail(statement.span, "cannot redefine builtin precedence group '{s}'", .{group.name});
        const id = table.add(group.name, self.environment.module_index, group.associativity, statement.span) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(statement.span, "cannot declare precedence group '{s}': {s}", .{ group.name, @errorName(err) });
        };
        try self.environment.group_names.put(scratch, group.name, id);
    }
    if (self.environment.group_names.count() != 0) try linkPrecedenceRelations(self);
    for (self.environment.unit.headers.operators) |header| {
        const statement = header.statement;
        const binding = statement.value.mixfix_binding;
        const name = binding.target.name;
        const group = binding.form.group;
        const call = self.environment.unit.resolverAt(statement.span.start).callable(header.scope, name);
        var enclosing: ?Parser.ScopeId = header.scope;
        var expansion = false;
        while (enclosing) |id| : (enclosing = self.environment.unit.headers.scopes[id].parent) if (self.environment.unit.headers.scopes[id].kind == .expansion) {
            expansion = true;
            break;
        };
        if (binding.target.namespace == null and expansion) continue;
        if (binding.target.namespace == null and call.shadowed) {
            _ = try groupNamed(self, group);
            continue;
        }
        const target = if (binding.target.namespace != null) (try modules.qualifiedTarget(self, binding.target)).target else modules.callTarget(self, name, call.member);
        const arity = binding.form.arity();
        switch (target orelse return self.fail(statement.span, "mixfix binding requires a callable function '{s}'", .{name})) {
            inline .function, .builtin => |index, kind| {
                const callee = if (kind == .function) calls.callFunction(self, index) else builtin.signature(index);
                if (!callee.acceptsCount(arity)) return self.fail(statement.span, "mixfix function '{s}' does not accept {d} arguments", .{ name, arity });
            },
            .record => |index| {
                const declared = self.build.records.items[index];
                if (arity > declared.fields.len) return self.fail(statement.span, "struct '{s}' does not accept {d} arguments", .{ name, arity });
                for (declared.fields[arity..]) |field| if (field.default_function == null) return self.fail(statement.span, "struct '{s}' requires field '{s}'", .{ name, field.name });
            },
            else => return self.fail(statement.span, "mixfix binding requires a callable function '{s}'", .{name}),
        }
        _ = try groupNamed(self, group);
    }
}

pub fn linkPrecedenceRelations(self: *Compiler) !void {
    const table = &self.build.precedence;
    const scratch = self.build.syntax_allocator;
    // A module can insert its groups into an established order, but must
    // not change the meaning of two groups owned by another module.
    const count = table.groups.items.len;
    var before = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(scratch, count * count);
    defer before.deinit(scratch);
    for (table.groups.items, 0..) |left, i| {
        if (left.module == self.environment.module_index) continue;
        for (table.groups.items[0..i], 0..) |right, j| {
            if (right.module == self.environment.module_index) continue;
            if ((try table.compare(@intCast(i), @intCast(j))) == .unrelated) before.set(i * count + j);
        }
    }
    var last_span: Span = .{ .start = 0, .end = 0 };
    for (self.environment.unit.script.statements) |statement| {
        if (statement.value != .precedence_group) continue;
        last_span = statement.span;
        const group = statement.value.precedence_group;
        const id = self.environment.group_names.get(group.name).?;
        for (group.relations) |relation| {
            const other = try groupNamed(self, relation.target);
            const higher = if (relation.direction == .above) id else other;
            const lower = if (relation.direction == .above) other else id;
            table.above(higher, lower) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.fail(relation.span, "invalid precedence relation: {s}", .{@errorName(err)});
            };
        }
    }
    table.validate() catch |err| {
        if (err == error.OutOfMemory) return err;
        return self.fail(last_span, "invalid precedence graph: {s}", .{@errorName(err)});
    };
    for (table.groups.items, 0..) |left, i| {
        if (left.module == self.environment.module_index) continue;
        for (table.groups.items[0..i], 0..) |right, j| {
            if (right.module == self.environment.module_index or !before.isSet(i * count + j)) continue;
            if ((try table.compare(@intCast(i), @intCast(j))) != .unrelated)
                return self.fail(last_span, "cannot change the precedence relationship between existing groups '{s}' and '{s}'", .{ left.name, right.name });
        }
    }
}
