//! Classifying the token inside a statement, expression, operator name, annotation or import path into a Target.
const std = @import("std");
const ast = @import("../../language/ast.zig");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Lexer = @import("../../language/Lexer.zig");
const builtins = @import("../../language/builtin.zig");
const definition = @import("../definition.zig");
const records = @import("records.zig");
const Query = @import("Query.zig");
const Role = definition.Role;
const Target = definition.Target;
const declaration = Query.declaration;
const ungroup = ast.ungroup;
const fieldTarget = records.fieldTarget;

pub fn operator(self: Query, name: ast.OperatorName, role: Role) ?Target {
    if (name.namespace) |namespace| if (self.contains(name.span) and self.token.span.end < name.span.end) {
        if (self.defaultNamespace(namespace, name.span.start)) |native|
            return .{ .unit = self.unit, .span = self.token.span, .native = .{ .namespace = native } };
        return namespaceToken(self, namespace, name.span.start);
    };
    return self.operatorTarget(name, role);
}

pub fn namespaceToken(self: Query, path: []const u8, start: usize) ?Target {
    var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = self.unit.source_text, .pos = start, .diagnostic = &diagnostic };
    var parts = std.mem.splitScalar(u8, path, '.');
    var current: ?u32 = null;
    while (parts.next()) |part| {
        if (current != null) {
            const dot = scanner.next() catch return null;
            if (dot.kind != .dot) return null;
        }
        const token = scanner.next() catch return null;
        current = if (current) |parent|
            self.graph.exportedNamespace(parent, part)
        else
            self.unit.resolverAt(start).namespace(self.unit.scopeAt(start), part);
        const id = current orelse return null;
        if (token.span.start == self.token.span.start) return Query.moduleStart(self.graph.units.items[id]);
    }
    return null;
}

pub fn importNamespaceToken(self: Query, statement: *const ast.Stmt, imported: ModuleGraph.Import) ?Target {
    var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = self.unit.source_text, .pos = statement.span.start, .diagnostic = &diagnostic };
    _ = scanner.next() catch return null; // import
    const path = scanner.next() catch return null;
    var current = imported.initializer;
    if (path.span.start == self.token.span.start) return Query.moduleStart(self.graph.units.items[current]);
    for (statement.value.imported.namespace_path) |part| {
        _ = scanner.next() catch return null; // .
        const token = scanner.next() catch return null;
        current = self.graph.exportedNamespace(current, part) orelse return null;
        if (token.span.start == self.token.span.start) return Query.moduleStart(self.graph.units.items[current]);
    }
    return null;
}

pub fn statementTarget(self: Query, statement_: *const ast.Stmt) ?Target {
    const offset = self.token.span.start;
    switch (statement_.value) {
        .assignment => |assignment| {
            if (assignment.annotation) |annotation| if (self.contains(annotation.span)) return resolveAnnotation(self, annotation);
            if (std.mem.eql(u8, self.name, assignment.name)) return self.named(assignment.name, offset, .value);
        },
        .list_append => |append| {
            if (std.mem.eql(u8, self.name, append.name)) return self.named(append.name, offset, .value);
        },
        .parameter => |parameter| {
            if (parameter.annotation) |annotation| if (self.contains(annotation.span)) return resolveAnnotation(self, annotation);
            if (std.mem.eql(u8, self.name, parameter.name)) return self.named(parameter.name, offset, .value);
        },
        inline .function, .expand_block => |function| {
            if (function.result) |annotation| if (self.contains(annotation.span)) return resolveAnnotation(self, annotation);
            for (function.params) |parameter| {
                if (self.contains(parameter.annotation.span)) return resolveAnnotation(self, parameter.annotation);
                const span: ast.Span = .{ .start = parameter.span.start, .end = parameter.span.start + parameter.name.len };
                if (self.contains(span)) return .{ .unit = self.unit, .span = span };
            }
            if (declaration(self.unit, function.name, .callable)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
        },
        .structure => |structure| {
            for (structure.fields) |field| {
                if (self.contains(field.annotation.span)) return resolveAnnotation(self, field.annotation);
                const span: ast.Span = .{ .start = field.span.start, .end = field.span.start + field.name.len };
                if (self.contains(span)) return .{ .unit = self.unit, .span = span };
            }
            if (declaration(self.unit, structure.name, .type_symbol)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
        },
        .for_loop => |loop| if (std.mem.eql(u8, self.name, loop.name)) {
            return self.named(loop.name, offset, .value);
        },
        .exported => |exported| {
            for (exported.names) |name| if (self.contains(name.span)) return self.named(name.name, offset, .exported);
        },
        // The path's Huak names lead through namespaces to a value; the
        // remaining names are Typst members.
        .typst_show => |path| {
            const resolver = self.unit.resolverAt(statement_.span.start);
            const scope = self.unit.scopeAt(statement_.span.start);
            if (self.contains(path[0].span)) return self.named(path[0].name, offset, .value);
            var namespace: ?u32 = if (resolver.readable(scope, path[0].name)) |readable| switch (readable) {
                .imported => |imported| switch (imported) {
                    .namespace => |id| id,
                    .member => null,
                },
                .ordinary => null,
            } else null;
            for (path[1..]) |segment| {
                const id = namespace orelse return null;
                if (self.contains(segment.span)) return self.public(id, segment.name);
                namespace = self.graph.exportedNamespace(id, segment.name);
            }
        },
        .imported => {
            for (self.unit.imports.items) |imported| if (imported.span.start == statement_.span.start) {
                if (imported.form == .selected) for (imported.form.selected) |binding| {
                    if (self.contains(binding.span)) {
                        if (self.token.span.start == binding.span.start or self.token.span.end == binding.span.end)
                            return self.public(imported.target, binding.name);
                        return null;
                    }
                };
                // Only the path and namespace name denote a module. Syntax
                // keywords and punctuation have no definition.
                if (self.token.kind == .string) return Query.moduleStart(self.graph.units.items[imported.initializer]);
                if (self.token.kind == .identifier and imported.form == .namespace and self.token.span.end == statement_.span.end)
                    return Query.moduleStart(self.graph.units.items[imported.target]);
                if (self.token.kind == .identifier) return importNamespaceToken(self, statement_, imported);
            };
        },
        .precedence_group => |group| {
            for (group.relations) |relation| if (self.contains(relation.target.span)) return operator(self, relation.target, .precedence);
            if (declaration(self.unit, group.name, .precedence)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
        },
        .mixfix_binding => |binding| {
            if (self.contains(binding.form.group.span)) return operator(self, binding.form.group, .precedence);
            if (self.token.kind == .identifier or Lexer.isOperator(self.token.kind)) return operator(self, binding.target, .callable);
        },
        else => {},
    }
    return null;
}

pub fn expressionTarget(self: Query, expr: *const ast.Expr) ?Target {
    switch (expr.value) {
        .expansion => |value| if (self.contains(value.name.span)) {
            return operator(self, value.name, .callable);
        },
        .name => |name| {
            if (self.defaultNamespace(name, expr.span.start)) |namespace|
                return .{ .unit = self.unit, .span = self.token.span, .native = .{ .namespace = namespace } };
            return self.named(name, expr.span.start, .value);
        },
        .member => |member_| {
            if (!std.mem.eql(u8, self.name, member_.name)) return null;
            const object = ungroup(member_.object);
            if (self.namespaceReceiver(object)) |id| return self.public(id, member_.name);
            if (self.defaultNamespaceReceiver(object)) |namespace| {
                if (builtins.namespaceLookup(namespace, member_.name)) |signature|
                    return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
                if (builtins.namespaceConstant(namespace, member_.name) != null)
                    return .{ .unit = self.unit, .span = self.token.span, .native = .{ .constant = .{ .namespace = namespace, .name = member_.name } } };
                return null;
            }
            if (records.recordForExpression(self, object, 0)) |record| return fieldTarget(record, member_.name);
        },
        .call => |call| {
            if (call.argument_names.len == call.args.len) for (call.argument_names, call.args, 0..) |name, argument, index| {
                if (name) |label| if (std.mem.eql(u8, self.name, label) and self.token.span.end <= argument.span.start and
                    (index == 0 or self.token.span.start >= call.args[index - 1].span.end))
                    return argumentTarget(self, expr, label);
            };
            if (!std.mem.eql(u8, self.name, call.name)) return null;
            return self.callTarget(expr);
        },
        .mixfix_call => |call| {
            if (call.qualified) |binding| {
                const owner = self.graph.units.items[binding.target.module.?];
                return self.inUnit(owner).operatorTarget(binding.target, .callable);
            }
            if (self.token.kind == .identifier or Lexer.isOperator(self.token.kind)) return operator(self, call.operator, .callable);
        },
        else => {},
    }
    return null;
}

pub fn resolveAnnotation(self: Query, annotation_: ast.Annotation) ?Target {
    if (std.mem.lastIndexOfScalar(u8, annotation_.name, '.')) |dot| {
        const namespace = annotation_.name[0..dot];
        const id = self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(annotation_.span.start), namespace, annotation_.span.start) orelse return null;
        if (self.token.span.end < annotation_.span.end)
            return namespaceToken(self, namespace, annotation_.span.start);
        return self.public(id, annotation_.name[dot + 1 ..]);
    }
    return self.named(annotation_.name, annotation_.span.start, .type_symbol);
}

pub fn argumentTarget(self: Query, expr: *const ast.Expr, label: []const u8) ?Target {
    const target = self.callTarget(expr) orelse return null;
    if (target.native != null) return null;
    for (target.unit.script.statements) |statement| {
        if (statement.value == .structure and statement.span.start <= target.span.start and target.span.end <= statement.span.end)
            return fieldTarget(.{ .unit = target.unit, .statement = statement }, label);
        if (statement.value == .function and statement.span.start <= target.span.start and target.span.end <= statement.span.end)
            for (statement.value.function.params) |parameter| if (std.mem.eql(u8, parameter.name, label))
                return .{ .unit = target.unit, .span = .{ .start = parameter.span.start, .end = parameter.span.start + parameter.name.len } };
    }
    return null;
}
