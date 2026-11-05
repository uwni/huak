//! Source navigation over the compiler's existing module graph and lexical
//! identities. This walk classifies syntax; name/import lookup stays in scope.zig.
const std = @import("std");
const ast = @import("../language/ast.zig");
const ModuleGraph = @import("../language/ModuleGraph.zig");
const Lexer = @import("../language/Lexer.zig");
const Frontend = @import("Frontend.zig");
const locations = @import("position.zig");
const standard = @import("huak_std");
const builtins = @import("../language/builtin.zig");

pub const Location = struct { uri: []const u8, range: locations.Range };
const NativeConstant = struct { namespace: builtins.Namespace, name: []const u8 };
const NativeTarget = union(enum) { namespace: builtins.Namespace, function: builtins.Id, constant: NativeConstant };
const Target = struct { unit: *const ModuleGraph.Unit, span: ast.Span, native: ?NativeTarget = null, module_start: bool = false };
const Role = enum { value, callable, type_symbol, precedence, exported };
const RecordTarget = struct { unit: *const ModuleGraph.Unit, statement: *const ast.Stmt };
pub const Completion = struct { label: []const u8, kind: u8, detail: []const u8, insertText: ?[]const u8 = null };

/// The result and all temporary graph storage belong to the caller's arena.
/// Invalid syntax has no destination; allocation failures remain visible.
pub fn find(frontend: *Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !?Location {
    const target = try targetAt(frontend, arena, text, path, byte_offset) orelse return null;
    if (target.native != null) return null;
    return .{ .uri = try uriForPath(arena, target.unit.name), .range = .{ .start = locations.at(target.unit.source_text, target.span.start), .end = locations.at(target.unit.source_text, target.span.end) } };
}

fn targetAt(frontend: *Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !?Target {
    const token = try tokenAt(frontend, text, byte_offset) orelse return null;
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    const graph = frontend.graph(arena, text, path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    const unit = graph.units.items[0];
    const query: Query = .{ .graph = &graph, .unit = unit, .token = token, .name = text[token.span.start..token.span.end] };
    return query.statements(unit.script.statements);
}

pub fn uriForPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (standard.source(path) != null) return std.fmt.allocPrint(arena, "huak-stdlib:/{s}", .{path});
    const address: std.Uri = .{ .scheme = "file", .host = .{ .raw = "" }, .path = .{ .raw = path } };
    return std.fmt.allocPrint(arena, "{f}", .{address.fmt(.all)});
}

/// Shared with hover. The normal lexer skips comments and strings atomically;
/// native Typst blocks use the same upstream block provider as the parser.
pub fn tokenAt(frontend: *Frontend, input: []const u8, byte_offset: usize) !?Lexer.Token {
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = input, .diagnostic = &diagnostic };
    var trailing: ?Lexer.Token = null;
    while (true) {
        const token = scanner.next() catch return null;
        if (token.kind == .eof or token.span.start > byte_offset) return trailing;
        if (token.span.start <= byte_offset and byte_offset < token.span.end) {
            if (token.kind != .identifier and !Lexer.isOperator(token.kind) and trailing != null) return trailing;
            return token;
        }
        if (token.span.end == byte_offset and token.kind == .identifier) trailing = token;
        if (token.kind == .kw_typ or token.kind == .kw_setup_typst) {
            var start = scanner.pos;
            while (start < input.len and (input[start] == ' ' or input[start] == '\t' or input[start] == '\r')) start += 1;
            const length = frontend.sourceBlock(input[start..]) catch |err| {
                if (err == error.OutOfMemory) return err;
                return null;
            };
            scanner.pos = start + length;
            if (byte_offset < scanner.pos) return null;
        }
    }
}

const Query = struct {
    graph: *const ModuleGraph,
    unit: *const ModuleGraph.Unit,
    token: Lexer.Token,
    name: []const u8,

    fn contains(self: Query, span: ast.Span) bool {
        return span.start <= self.token.span.start and self.token.span.end <= span.end;
    }

    fn moduleStart(unit: *const ModuleGraph.Unit) Target {
        return .{ .unit = unit, .span = .{ .start = 0, .end = 0 }, .native = if (unit.native_namespace) |namespace| .{ .namespace = namespace } else null, .module_start = true };
    }

    fn named(self: Query, name: []const u8, offset: usize, role: Role) ?Target {
        const resolver = self.unit.resolverAt(offset);
        const scope = self.unit.scopeAt(offset);
        if (role == .value or role == .exported) {
            if (resolver.readable(scope, name)) |readable| switch (readable) {
                .ordinary => |binding| return .{ .unit = if (binding.module) |id| self.graph.units.items[id] else self.unit, .span = binding.span },
                .imported => |imported| switch (imported) {
                    .namespace => |id| return moduleStart(self.graph.units.items[id]),
                    .member => |member| return self.targetIdentity(member.identity),
                },
            };
        }
        if (role == .callable or role == .value or role == .exported) {
            const call = resolver.callable(scope, name);
            if (role == .callable or role == .value) {
                if (call.namespace) |id| {
                    if (self.graph.units.items[id].native_namespace) |namespace|
                        if (builtins.namespaceConstructor(namespace, name)) |signature|
                            return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
                    return moduleStart(self.graph.units.items[id]);
                }
                if (call.shadowed) return if (role == .value) null else self.named(name, offset, .value);
            }
            if (call.member) |member| return self.targetIdentity(member.identity);
            if (declaration(self.unit, name, .callable)) |span| return .{ .unit = self.unit, .span = span };
        }
        if (role == .type_symbol or role == .callable or role == .exported) {
            if (resolver.typeSymbol(scope, name)) |member| return self.targetIdentity(member.identity);
            if (declaration(self.unit, name, .type_symbol)) |span| return .{ .unit = self.unit, .span = span };
        }
        if (role == .precedence or role == .exported) {
            if (resolver.precedence(scope, name)) |member| return self.targetIdentity(member.identity);
            if (declaration(self.unit, name, .precedence)) |span| return .{ .unit = self.unit, .span = span };
        }
        return null;
    }

    fn targetIdentity(self: Query, identity: ModuleGraph.lexical.Identity) ?Target {
        if (identity.kind == .namespace and identity.module < self.graph.units.items.len)
            return moduleStart(self.graph.units.items[identity.module]);
        if (identity.kind == .builtin) if (builtins.identity(identity.name)) |signature|
            return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
        if (identity.module < self.graph.units.items.len) if (self.graph.units.items[identity.module].native_namespace) |namespace| {
            if (builtins.namespaceConstant(namespace, identity.name) != null)
                return .{ .unit = self.unit, .span = self.token.span, .native = .{ .constant = .{ .namespace = namespace, .name = identity.name } } };
        };
        if (identity.kind != .builtin and identity.module < self.graph.units.items.len) {
            const unit = self.graph.units.items[identity.module];
            if (unit.data != null) return moduleStart(unit);
            const role: Role = switch (identity.kind) {
                .function, .block => .callable,
                .record => .type_symbol,
                .precedence => .precedence,
                else => .value,
            };
            if (declaration(unit, identity.name, role)) |span| return .{ .unit = unit, .span = span };
        }
        return null;
    }

    fn public(self: Query, id: u32, name: []const u8) ?Target {
        const unit = self.graph.units.items[id];
        const exposed = unit.public_names.get(name) orelse return null;
        return self.targetIdentity(exposed.identity);
    }

    fn operator(self: Query, name: ast.OperatorName, role: Role) ?Target {
        if (name.namespace) |namespace| if (self.contains(name.span) and self.token.span.end < name.span.end) {
            if (self.defaultNamespace(namespace, name.span.start)) |native|
                return .{ .unit = self.unit, .span = self.token.span, .native = .{ .namespace = native } };
            return self.namespaceToken(namespace, name.span.start);
        };
        return self.operatorTarget(name, role);
    }

    fn operatorTarget(self: Query, name: ast.OperatorName, role: Role) ?Target {
        if (name.namespace) |namespace| {
            if (self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(name.span.start), namespace, name.span.start)) |id| return self.public(id, name.name);
            const native = self.defaultNamespace(namespace, name.span.start) orelse return null;
            const signature = builtins.namespaceLookup(native, name.name) orelse return null;
            return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
        }
        return self.named(name.name, name.span.start, role);
    }

    fn namespaceToken(self: Query, path: []const u8, start: usize) ?Target {
        var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
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
            if (token.span.start == self.token.span.start) return moduleStart(self.graph.units.items[id]);
        }
        return null;
    }

    fn importNamespaceToken(self: Query, statement: *const ast.Stmt, imported: ModuleGraph.Import) ?Target {
        var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
        var scanner: Lexer = .{ .source = self.unit.source_text, .pos = statement.span.start, .diagnostic = &diagnostic };
        _ = scanner.next() catch return null; // import
        const path = scanner.next() catch return null;
        var current = imported.initializer;
        if (path.span.start == self.token.span.start) return moduleStart(self.graph.units.items[current]);
        for (statement.value.imported.namespace_path) |part| {
            _ = scanner.next() catch return null; // .
            const token = scanner.next() catch return null;
            current = self.graph.exportedNamespace(current, part) orelse return null;
            if (token.span.start == self.token.span.start) return moduleStart(self.graph.units.items[current]);
        }
        return null;
    }

    fn statements(self: Query, body: []const *ast.Stmt) ?Target {
        for (body) |statement| if (self.contains(statement.span)) return self.visitStatement(statement);
        return null;
    }

    fn visitStatement(self: Query, statement_: *const ast.Stmt) ?Target {
        const offset = self.token.span.start;
        switch (statement_.value) {
            .expression, .default_output => |expr| return self.expression(expr),
            .assignment => |assignment| {
                if (assignment.annotation) |annotation| if (self.contains(annotation.span)) return self.resolveAnnotation(annotation);
                if (self.contains(assignment.value.span)) return self.expression(assignment.value);
                if (std.mem.eql(u8, self.name, assignment.name)) return self.named(assignment.name, offset, .value);
            },
            .set => |update| {
                if (self.contains(update.target.span)) return self.expression(update.target);
                return self.expression(update.value);
            },
            .append_to => |append| {
                if (self.contains(append.target.span)) return self.expression(append.target);
                return self.expression(append.value);
            },
            .list_append => |append| {
                if (self.contains(append.value.span)) return self.expression(append.value);
                if (std.mem.eql(u8, self.name, append.name)) return self.named(append.name, offset, .value);
            },
            .parameter => |parameter| {
                if (parameter.annotation) |annotation| if (self.contains(annotation.span)) return self.resolveAnnotation(annotation);
                if (parameter.default) |value| if (self.contains(value.span)) return self.expression(value);
                if (std.mem.eql(u8, self.name, parameter.name)) return self.named(parameter.name, offset, .value);
            },
            inline .function, .expand_block => |function| {
                if (function.result) |annotation| if (self.contains(annotation.span)) return self.resolveAnnotation(annotation);
                for (function.params) |parameter| {
                    if (self.contains(parameter.annotation.span)) return self.resolveAnnotation(parameter.annotation);
                    if (parameter.default) |value| if (self.contains(value.span)) return self.expression(value);
                    const span: ast.Span = .{ .start = parameter.span.start, .end = parameter.span.start + parameter.name.len };
                    if (self.contains(span)) return .{ .unit = self.unit, .span = span };
                }
                if (self.statements(function.body)) |target| return target;
                if (declaration(self.unit, function.name, .callable)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
            },
            .structure => |structure| {
                for (structure.fields) |field| {
                    if (self.contains(field.annotation.span)) return self.resolveAnnotation(field.annotation);
                    if (field.default) |value| if (self.contains(value.span)) return self.expression(value);
                    const span: ast.Span = .{ .start = field.span.start, .end = field.span.start + field.name.len };
                    if (self.contains(span)) return .{ .unit = self.unit, .span = span };
                }
                if (declaration(self.unit, structure.name, .type_symbol)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
            },
            .conditional => |conditional| {
                for (conditional.branches) |branch| {
                    if (self.contains(branch.condition.span)) return self.expression(branch.condition);
                    if (self.statements(branch.body)) |target| return target;
                }
                return self.statements(conditional.otherwise);
            },
            .while_loop => |loop| {
                if (self.contains(loop.condition.span)) return self.expression(loop.condition);
                return self.statements(loop.body);
            },
            .for_loop => |loop| {
                switch (loop.iterable) {
                    .collection => |expr| if (self.contains(expr.span)) {
                        return self.expression(expr);
                    },
                    .range => |range| {
                        if (self.contains(range.start.span)) return self.expression(range.start);
                        if (range.step) |step| if (self.contains(step.span)) return self.expression(step);
                        if (self.contains(range.stop.?.span)) return self.expression(range.stop.?);
                    },
                }
                if (self.statements(loop.body)) |target| return target;
                if (std.mem.eql(u8, self.name, loop.name)) return self.named(loop.name, offset, .value);
            },
            .return_value => |value| if (value) |expr| return self.expression(expr),
            .exported => |exported| {
                if (exported.value) |expr| if (self.contains(expr.span)) return self.expression(expr);
                for (exported.names) |name| if (self.contains(name.span)) return self.named(name.name, offset, .exported);
            },
            .typst_expose => |names| {
                for (names) |name| if (self.contains(name.span)) return self.named(name.name, offset, .value);
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
                    if (self.token.kind == .string) return moduleStart(self.graph.units.items[imported.initializer]);
                    if (self.token.kind == .identifier and imported.form == .namespace and self.token.span.end == statement_.span.end)
                        return moduleStart(self.graph.units.items[imported.target]);
                    if (self.token.kind == .identifier) return self.importNamespaceToken(statement_, imported);
                };
            },
            .precedence_group => |group| {
                for (group.relations) |relation| if (self.contains(relation.target.span)) return self.operator(relation.target, .precedence);
                if (declaration(self.unit, group.name, .precedence)) |span| if (self.contains(span)) return .{ .unit = self.unit, .span = span };
            },
            .mixfix_binding => |binding| {
                if (self.contains(binding.form.group.span)) return self.operator(binding.form.group, .precedence);
                if (self.token.kind == .identifier or Lexer.isOperator(self.token.kind)) return self.operator(binding.target, .callable);
            },
            else => {},
        }
        return null;
    }

    fn expression(self: Query, expr: *const ast.Expr) ?Target {
        if (!self.contains(expr.span)) return null;
        switch (expr.value) {
            .block => |body| return self.statements(body),
            .expansion => |value| {
                for (value.args) |arg| if (self.contains(arg.span)) return self.expression(arg);
                if (self.contains(value.name.span)) return self.operator(value.name, .callable);
                return self.statements(value.body);
            },
            .name => |name| {
                if (self.defaultNamespace(name, expr.span.start)) |namespace|
                    return .{ .unit = self.unit, .span = self.token.span, .native = .{ .namespace = namespace } };
                return self.named(name, expr.span.start, .value);
            },
            .list => |items| for (items) |item| {
                if (self.contains(item.span)) return self.expression(item);
            },
            .dict => |entries| for (entries) |entry| {
                if (self.contains(entry.value.span)) return self.expression(entry.value);
            },
            .pair => |pair| {
                if (self.contains(pair.x.span)) return self.expression(pair.x);
                return self.expression(pair.y);
            },
            .unary => |unary| return self.expression(unary.operand),
            .quantity => |quantity| return self.expression(quantity.operand),
            .binary => |binary| {
                if (self.contains(binary.left.span)) return self.expression(binary.left);
                return self.expression(binary.right);
            },
            .path_join, .path_literal => {
                const path = if (expr.value == .path_join) expr.value.path_join else expr.value.path_literal;
                if (self.contains(path.left.span)) return self.expression(path.left);
                return self.expression(path.right);
            },
            .grouped => |value| return self.expression(value),
            .index => |index| {
                if (self.contains(index.object.span)) return self.expression(index.object);
                return self.expression(index.index);
            },
            .slice => |slice| {
                if (self.contains(slice.object.span)) return self.expression(slice.object);
                if (self.contains(slice.range.start.span)) return self.expression(slice.range.start);
                if (slice.range.step) |step| if (self.contains(step.span)) return self.expression(step);
                if (slice.range.stop) |stop| return self.expression(stop);
            },
            .member => |member_| {
                if (self.contains(member_.object.span)) return self.expression(member_.object);
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
                if (self.recordForExpression(object, 0)) |record| return fieldTarget(record, member_.name);
            },
            .call => |call| {
                for (call.args) |argument| if (self.contains(argument.span)) return self.expression(argument);
                if (call.argument_names.len == call.args.len) for (call.argument_names, call.args, 0..) |name, argument, index| {
                    if (name) |label| if (std.mem.eql(u8, self.name, label) and self.token.span.end <= argument.span.start and
                        (index == 0 or self.token.span.start >= call.args[index - 1].span.end))
                        return self.argumentTarget(expr, label);
                };
                if (!std.mem.eql(u8, self.name, call.name)) return null;
                if (call.dot and call.args.len != 0) {
                    const object = ungroup(call.args[0]);
                    if (self.namespaceReceiver(object)) |id| return self.public(id, call.name);
                    if (self.defaultNamespaceReceiver(object) != null) return self.callTarget(expr);
                }
                return self.named(call.name, expr.span.start, .callable);
            },
            .mixfix_call => |call| {
                for (call.args) |argument| if (self.contains(argument.span)) return self.expression(argument);
                if (call.qualified) |binding| {
                    const owner = self.graph.units.items[binding.target.module.?];
                    return self.inUnit(owner).operatorTarget(binding.target, .callable);
                }
                if (self.token.kind == .identifier or Lexer.isOperator(self.token.kind)) return self.operator(call.operator, .callable);
            },
            else => {},
        }
        return null;
    }

    fn resolveAnnotation(self: Query, annotation_: ast.Annotation) ?Target {
        if (std.mem.lastIndexOfScalar(u8, annotation_.name, '.')) |dot| {
            const namespace = annotation_.name[0..dot];
            const id = self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(annotation_.span.start), namespace, annotation_.span.start) orelse return null;
            if (self.token.span.end < annotation_.span.end)
                return self.namespaceToken(namespace, annotation_.span.start);
            return self.public(id, annotation_.name[dot + 1 ..]);
        }
        return self.named(annotation_.name, annotation_.span.start, .type_symbol);
    }

    fn inUnit(self: Query, unit: *const ModuleGraph.Unit) Query {
        var result = self;
        result.unit = unit;
        return result;
    }

    fn defaultNamespace(self: Query, name: []const u8, offset: usize) ?builtins.Namespace {
        if (self.unit.resolverAt(offset).readable(self.unit.scopeAt(offset), name) != null) return null;
        return builtins.Namespace.parse(name);
    }

    fn defaultNamespaceReceiver(self: Query, expr: *const ast.Expr) ?builtins.Namespace {
        const object = ungroup(expr);
        return if (object.value == .name) self.defaultNamespace(object.value.name, object.span.start) else null;
    }

    fn namespaceReceiver(self: Query, expression_: *const ast.Expr) ?u32 {
        const node = ungroup(expression_);
        return switch (node.value) {
            .name => |name| self.unit.resolverAt(node.span.start).namespace(self.unit.scopeAt(node.span.start), name),
            .member => |member| self.graph.exportedNamespace(self.namespaceReceiver(member.object) orelse return null, member.name),
            else => null,
        };
    }

    fn callTarget(self: Query, expr: *const ast.Expr) ?Target {
        const call = expr.value.call;
        if (call.dot and call.args.len != 0) {
            const object = ungroup(call.args[0]);
            if (self.namespaceReceiver(object)) |id|
                return self.public(id, call.name);
            if (self.defaultNamespaceReceiver(object)) |namespace| {
                const signature = builtins.namespaceLookup(namespace, call.name) orelse return null;
                return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
            }
        }
        return self.named(call.name, expr.span.start, .callable);
    }

    fn argumentTarget(self: Query, expr: *const ast.Expr, label: []const u8) ?Target {
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

    fn recordNamed(self: Query, name: []const u8, offset: usize) ?RecordTarget {
        const target = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| blk: {
            const id = self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(offset), name[0..dot], offset) orelse return null;
            break :blk self.public(id, name[dot + 1 ..]) orelse return null;
        } else self.named(name, offset, .type_symbol) orelse return null;
        return recordAt(target);
    }

    /// Navigation follows explicit annotations, aliases and declared function
    /// results. Unknown dynamic values deliberately have no fabricated fields.
    fn recordForExpression(self: Query, expr_: *const ast.Expr, depth: usize) ?RecordTarget {
        if (depth > 32) return null;
        const expr = ungroup(expr_);
        switch (expr.value) {
            .call => {
                const target = self.callTarget(expr) orelse return null;
                if (target.native != null) return null;
                if (recordAt(target)) |record| return record;
                for (target.unit.script.statements) |statement| if (statement.value == .function and
                    statement.span.start <= target.span.start and target.span.end <= statement.span.end)
                    if (statement.value.function.result) |annotation_| return self.inUnit(target.unit).recordNamed(annotation_.name, annotation_.span.start);
            },
            .name => |name| {
                const target = self.named(name, expr.span.start, .value) orelse return null;
                if (target.native != null) return null;
                return self.inUnit(target.unit).recordForBinding(target.unit.script.statements, target.span, depth + 1);
            },
            .member => |member_| {
                const object = ungroup(member_.object);
                if (self.namespaceReceiver(object)) |id| {
                    const target = self.public(id, member_.name) orelse return null;
                    return self.inUnit(target.unit).recordForBinding(target.unit.script.statements, target.span, depth + 1);
                }
                const parent = self.recordForExpression(member_.object, depth + 1) orelse return null;
                for (parent.statement.value.structure.fields) |field| if (std.mem.eql(u8, field.name, member_.name))
                    return self.inUnit(parent.unit).recordNamed(field.annotation.name, field.annotation.span.start);
            },
            else => {},
        }
        return null;
    }

    fn recordForBinding(self: Query, body: []const *ast.Stmt, span: ast.Span, depth: usize) ?RecordTarget {
        if (statementAt(body, span)) |statement| {
            switch (statement.value) {
                .assignment => |assignment| {
                    if (assignment.annotation) |annotation_| return self.recordNamed(annotation_.name, annotation_.span.start);
                    return self.recordForExpression(assignment.value, depth + 1);
                },
                .exported => |exported| if (exported.value) |value| return self.recordForExpression(value, depth + 1),
                .parameter => |parameter| {
                    if (parameter.annotation) |annotation_| return self.recordNamed(annotation_.name, annotation_.span.start);
                    if (parameter.default) |value| return self.recordForExpression(value, depth + 1);
                },
                inline .function, .expand_block => |function| {
                    for (function.params) |parameter| if (parameter.span.start <= span.start and span.end <= parameter.span.end)
                        return self.recordNamed(parameter.annotation.name, parameter.annotation.span.start);
                    return self.recordForBinding(function.body, span, depth + 1);
                },
                .conditional => |conditional| {
                    for (conditional.branches) |branch| if (self.recordForBinding(branch.body, span, depth + 1)) |record| return record;
                    return self.recordForBinding(conditional.otherwise, span, depth + 1);
                },
                .while_loop => |loop| return self.recordForBinding(loop.body, span, depth + 1),
                .for_loop => |loop| return self.recordForBinding(loop.body, span, depth + 1),
                else => {},
            }
        }
        return null;
    }
};

fn recordAt(target: Target) ?RecordTarget {
    if (target.native != null) return null;
    for (target.unit.script.statements) |statement| if (statement.value == .structure and
        statement.span.start <= target.span.start and target.span.end <= statement.span.end)
        return .{ .unit = target.unit, .statement = statement };
    return null;
}

fn fieldTarget(record: RecordTarget, name: []const u8) ?Target {
    for (record.statement.value.structure.fields) |field| if (std.mem.eql(u8, field.name, name))
        return .{ .unit = record.unit, .span = .{ .start = field.span.start, .end = field.span.start + field.name.len } };
    return null;
}

pub fn describe(frontend: *Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) !?[]const u8 {
    const target = try targetAt(frontend, arena, text, path, byte_offset) orelse return null;
    if (target.native) |native| return switch (native) {
        .namespace => |namespace| try std.fmt.allocPrint(arena, "{s} — native functions and constants", .{namespace.name()}),
        .function => |id| try nativeFunctionText(arena, builtins.signature(id)),
        .constant => |constant| try nativeConstantText(arena, constant),
    };
    if (target.unit.data) |data| return try std.fmt.allocPrint(arena, "{s}: {s}", .{ target.unit.name, data.valueType().name() });
    if (target.module_start) return try std.fmt.allocPrint(arena, "module {s}", .{target.unit.name});
    if (try describeStatements(arena, target.unit.script.statements, target.span)) |detail| return detail;
    if (builtins.lookup(target.unit.source_text[target.span.start..target.span.end])) |signature| return try builtinText(arena, signature);
    return null;
}

pub fn builtinText(arena: std.mem.Allocator, signature: builtins.Signature) ![]u8 {
    return builtinNamedText(arena, signature, signature.name);
}

fn builtinNamedText(arena: std.mem.Allocator, signature: builtins.Signature, name: []const u8) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    errdefer text.deinit();
    try text.writer.print("fn {s}(", .{name});
    for (signature.args, 0..) |argument, index| {
        if (index != 0) try text.writer.writeAll(", ");
        if (index < signature.parameter_names.len) try text.writer.print("{s}: ", .{signature.parameter_names[index]});
        try text.writer.print("{s}{s}", .{ argument.name(), if (index >= signature.minimum) "?" else "" });
    }
    if (signature.variadic) |element| {
        if (signature.args.len != 0) try text.writer.writeAll(", ");
        try text.writer.print("{s}...", .{element.name()});
    }
    try text.writer.print(") -> {s}", .{signature.result.name()});
    return text.toOwnedSlice();
}

fn nativeFunctionText(arena: std.mem.Allocator, signature: builtins.Signature) ![]const u8 {
    const name = if (signature.namespace) |namespace|
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ namespace.name(), signature.name })
    else
        signature.name;
    return builtinNamedText(arena, signature, name);
}

fn nativeConstantText(arena: std.mem.Allocator, constant: NativeConstant) ![]const u8 {
    const value = builtins.namespaceConstant(constant.namespace, constant.name) orelse return "unknown native constant";
    return switch (value) {
        .number => |number| std.fmt.allocPrint(arena, "{s}.{s}: number = {d}", .{ constant.namespace.name(), constant.name, number }),
        else => std.fmt.allocPrint(arena, "{s}.{s}: {s}", .{ constant.namespace.name(), constant.name, value.valueType().name() }),
    };
}

fn symbolDetail(arena: std.mem.Allocator, query: Query, identity: ModuleGraph.lexical.Identity) ![]const u8 {
    if (identity.kind == .namespace)
        return std.fmt.allocPrint(arena, "module {s}", .{query.graph.units.items[identity.module].name});
    if (identity.kind == .builtin) if (builtins.identity(identity.name)) |signature| return nativeFunctionText(arena, signature);
    if (query.targetIdentity(identity)) |target| {
        if (target.native) |native| if (native == .constant) return nativeConstantText(arena, native.constant);
        if (try describeStatements(arena, target.unit.script.statements, target.span)) |detail| return detail;
    }
    return "Huak symbol";
}

/// Select the innermost statement, including declarations inside expressions.
fn statementAt(body: []const *ast.Stmt, span: ast.Span) ?*ast.Stmt {
    const Visitor = struct {
        span: ast.Span,
        found: ?*ast.Stmt = null,
        pub fn enter(self: *@This(), node: ast.Node) !bool {
            const candidate = switch (node) {
                .statement => |s| s.span,
                .expression => |e| e.span,
            };
            if (candidate.start > self.span.start or candidate.end < self.span.end) return false;
            if (node == .statement) self.found = node.statement;
            return true;
        }
    };
    var visitor: Visitor = .{ .span = span };
    ast.walkStatements(&visitor, body) catch unreachable;
    return visitor.found;
}

fn describeStatements(arena: std.mem.Allocator, body: []const *ast.Stmt, span: ast.Span) anyerror!?[]const u8 {
    if (statementAt(body, span)) |statement| {
        switch (statement.value) {
            .structure => |structure| {
                for (structure.fields) |field| if (field.span.start == span.start)
                    return try std.fmt.allocPrint(arena, "{s}.{s}: {s}", .{ structure.name, field.name, field.annotation.name });
                var text: std.Io.Writer.Allocating = .init(arena);
                try text.writer.print("struct {s}", .{structure.name});
                for (structure.fields) |field| try text.writer.print("\n    {s}: {s}{s}", .{ field.name, field.annotation.name, if (field.default != null) " = …" else "" });
                try text.writer.writeAll("\nend");
                return try text.toOwnedSlice();
            },
            inline .function, .expand_block => |function| {
                for (function.params) |parameter| if (parameter.span.start == span.start)
                    return try std.fmt.allocPrint(arena, "parameter {s}: {s}", .{ parameter.name, parameter.annotation.name });
                if (try describeStatements(arena, function.body, span)) |detail| return detail;
                return try functionText(arena, statement);
            },
            .assignment => |assignment| return try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ assignment.name, if (assignment.annotation != null) ": " else "", if (assignment.annotation) |annotation_| annotation_.name else "" }),
            .parameter => |parameter| return try std.fmt.allocPrint(arena, "param {s}{s}{s}", .{ parameter.name, if (parameter.annotation != null) ": " else "", if (parameter.annotation) |annotation_| annotation_.name else "" }),
            .conditional => |conditional| {
                for (conditional.branches) |branch| if (try describeStatements(arena, branch.body, span)) |detail| return detail;
                return try describeStatements(arena, conditional.otherwise, span);
            },
            .for_loop => |loop| return try describeStatements(arena, loop.body, span),
            .while_loop => |loop| return try describeStatements(arena, loop.body, span),
            else => {},
        }
    }
    return null;
}

fn functionText(arena: std.mem.Allocator, statement: *const ast.Stmt) ![]const u8 {
    const function = switch (statement.value) {
        inline .function, .expand_block => |value| .{ .name = value.name, .params = value.params, .result = value.result },
        else => unreachable,
    };
    var text: std.Io.Writer.Allocating = .init(arena);
    try text.writer.print("{s} {s}(", .{ if (statement.value == .expand_block) "expand_block" else "fn", function.name });
    for (function.params, 0..) |parameter, index| {
        if (index != 0) try text.writer.writeAll(", ");
        try text.writer.print("{s}: {s}{s}{s}", .{ parameter.name, parameter.annotation.name, if (parameter.variadic) "..." else "", if (parameter.default != null) " = …" else "" });
    }
    try text.writer.print(") -> {s}", .{if (function.result) |annotation_| annotation_.name else "unit"});
    return text.toOwnedSlice();
}

fn appendCompletion(arena: std.mem.Allocator, items: *std.ArrayList(Completion), item: Completion) !void {
    for (items.items) |previous| if (std.mem.eql(u8, previous.label, item.label)) return;
    try items.append(arena, item);
}

fn appendNativeCompletions(arena: std.mem.Allocator, items: *std.ArrayList(Completion), namespace: builtins.Namespace) !void {
    for (builtins.signatures) |signature| if (signature.namespace == namespace)
        try appendCompletion(arena, items, .{ .label = signature.name, .kind = 3, .detail = try nativeFunctionText(arena, signature) });
    for (builtins.constantNames(namespace)) |name|
        try appendCompletion(arena, items, .{ .label = name, .kind = 21, .detail = try nativeConstantText(arena, .{ .namespace = namespace, .name = name }) });
}

fn completionKind(kind: ModuleGraph.lexical.Kind) u8 {
    return switch (kind) {
        .namespace => 9,
        .record => 22,
        .function, .builtin => 3,
        else => 6,
    };
}

fn appendModuleCompletions(arena: std.mem.Allocator, items: *std.ArrayList(Completion), query: Query, id: u32) !void {
    var exports = query.graph.units.items[id].public_names.iterator();
    while (exports.next()) |entry| {
        const exposed = entry.value_ptr.*;
        try appendCompletion(arena, items, .{ .label = entry.key_ptr.*, .kind = completionKind(exposed.identity.kind), .detail = try symbolDetail(arena, query, exposed.identity) });
    }
}

/// Syntax requests do not execute or typecheck a program. Completing an empty
/// member after '.' repairs only that missing identifier in a request snapshot.
pub fn complete(frontend: *Frontend, arena: std.mem.Allocator, text: []const u8, path: []const u8, byte_offset: usize) ![]const Completion {
    var input = text;
    if (byte_offset != 0 and text[byte_offset - 1] == '.')
        input = try std.fmt.allocPrint(arena, "{s}__huak_completion__{s}", .{ text[0..byte_offset], text[byte_offset..] });
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    const graph = frontend.graph(arena, input, path, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        return &.{};
    };
    const unit = graph.units.items[0];
    const query: Query = .{ .graph = &graph, .unit = unit, .token = .{ .kind = .identifier, .span = .{ .start = byte_offset, .end = byte_offset } }, .name = "" };
    var items: std.ArrayList(Completion) = .empty;
    if (contextStatements(unit.script.statements, byte_offset)) |context| switch (context.value) {
        .member => |member_| {
            const object = ungroup(member_.object);
            if (query.defaultNamespaceReceiver(object)) |namespace| {
                try appendNativeCompletions(arena, &items, namespace);
                return items.toOwnedSlice(arena);
            }
            if (query.namespaceReceiver(object)) |id| {
                try appendModuleCompletions(arena, &items, query, id);
                return items.toOwnedSlice(arena);
            }
            if (query.recordForExpression(object, 0)) |record| {
                for (record.statement.value.structure.fields) |field| try appendCompletion(arena, &items, .{ .label = field.name, .kind = 5, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ field.name, field.annotation.name }) });
                return items.toOwnedSlice(arena);
            }
            return items.toOwnedSlice(arena);
        },
        .call => |call| {
            if (call.dot and call.args.len != 0) if (query.defaultNamespaceReceiver(call.args[0])) |namespace| {
                if (std.mem.indexOfScalarPos(u8, input, call.args[0].span.end, '(')) |opening| if (byte_offset <= opening) {
                    try appendNativeCompletions(arena, &items, namespace);
                    return items.toOwnedSlice(arena);
                };
            };
            if (call.dot and call.args.len != 0) if (query.namespaceReceiver(call.args[0])) |id| {
                if (std.mem.indexOfScalarPos(u8, input, call.args[0].span.end, '(')) |opening| if (byte_offset <= opening) {
                    try appendModuleCompletions(arena, &items, query, id);
                    return items.toOwnedSlice(arena);
                };
            };
            const positional = positionalArguments(query, context);
            if (query.callTarget(context)) |target| {
                if (target.native) |native| {
                    if (native == .function) {
                        const signature = builtins.signature(native.function);
                        for (signature.parameter_names, signature.args, 0..) |name, kind, index| if (index >= positional and !argumentSupplied(call.argument_names, name))
                            try appendCompletion(arena, &items, .{ .label = name, .kind = 6, .detail = kind.name(), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{name}) });
                    }
                } else if (recordAt(target)) |record| {
                    for (record.statement.value.structure.fields, 0..) |field, index| if (index >= positional and !argumentSupplied(call.argument_names, field.name))
                        try appendCompletion(arena, &items, .{ .label = field.name, .kind = 5, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ field.name, field.annotation.name }), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{field.name}) });
                } else for (target.unit.script.statements) |statement| if (statement.value == .function and statement.span.start <= target.span.start and target.span.end <= statement.span.end) {
                    for (statement.value.function.params, 0..) |parameter, index| if (index >= positional and !parameter.variadic and !argumentSupplied(call.argument_names, parameter.name))
                        try appendCompletion(arena, &items, .{ .label = parameter.name, .kind = 6, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ parameter.name, parameter.annotation.name }), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{parameter.name}) });
                };
            } else if (builtins.implicit(call.name)) |signature| {
                for (signature.parameter_names, signature.args, 0..) |name, kind, index| if (index >= positional and !argumentSupplied(call.argument_names, name))
                    try appendCompletion(arena, &items, .{ .label = name, .kind = 6, .detail = kind.name(), .insertText = try std.fmt.allocPrint(arena, "{s}: ", .{name}) });
            }
            if (items.items.len != 0) return items.toOwnedSlice(arena);
        },
        else => {},
    };
    var scope: ?@import("../language/Parser.zig").ScopeId = unit.scopeAt(byte_offset);
    while (scope) |id| {
        for (unit.headers.scopes[id].ordinary_names) |binding| try appendCompletion(arena, &items, .{ .label = binding.name, .kind = 6, .detail = "Huak binding" });
        var symbols = unit.scopes[id].iterator();
        while (symbols.next()) |entry| {
            const symbol = unit.resolverAt(byte_offset).symbolAt(id, entry.key_ptr.*) orelse continue;
            const constructor: ?builtins.Signature = if (symbol.value != null and symbol.value.? == .namespace)
                if (graph.units.items[symbol.value.?.namespace].native_namespace) |namespace| builtins.namespaceConstructor(namespace, entry.key_ptr.*) else null
            else
                null;
            const detail = if (constructor) |signature| try builtinText(arena, signature) else if (symbol.type_symbol) |member| try symbolDetail(arena, query, member.identity) else if (symbol.callable) |member| try symbolDetail(arena, query, member.identity) else "Huak symbol";
            try appendCompletion(arena, &items, .{ .label = entry.key_ptr.*, .kind = if (constructor != null) 4 else if (symbol.type_symbol != null) 22 else if (symbol.callable != null) 3 else if (symbol.value != null and symbol.value.? == .namespace) 9 else 6, .detail = detail });
        }
        scope = unit.headers.scopes[id].parent;
    }
    for (unit.script.statements) |statement| switch (statement.value) {
        .structure => |structure| try appendCompletion(arena, &items, .{ .label = structure.name, .kind = 22, .detail = try std.fmt.allocPrint(arena, "struct {s}", .{structure.name}) }),
        inline .function, .expand_block => |function| try appendCompletion(arena, &items, .{ .label = function.name, .kind = 3, .detail = try functionText(arena, statement) }),
        else => {},
    };
    for (std.enums.values(builtins.Namespace)) |namespace| if (query.defaultNamespace(namespace.name(), byte_offset) != null) {
        const constructor = builtins.namespaceConstructor(namespace, namespace.name());
        try appendCompletion(arena, &items, .{ .label = namespace.name(), .kind = if (constructor != null) 4 else 9, .detail = if (constructor) |signature| try builtinText(arena, signature) else "Native namespace" });
    };
    return items.toOwnedSlice(arena);
}

/// Member completion returns only the resolved namespace/object's members.
/// Whitespace around the dot is insignificant to ordinary member syntax.
pub fn memberRequest(input: []const u8, offset: usize) bool {
    var index = @min(offset, input.len);
    while (index != 0 and (std.ascii.isAlphanumeric(input[index - 1]) or input[index - 1] == '_')) index -= 1;
    while (index != 0 and (input[index - 1] == ' ' or input[index - 1] == '\t')) index -= 1;
    return index != 0 and input[index - 1] == '.';
}

fn positionalArguments(query: Query, expression: *const ast.Expr) usize {
    const call = expression.value.call;
    var skip: usize = 0;
    if (call.dot and call.args.len != 0) {
        const object = ungroup(call.args[0]);
        if (query.namespaceReceiver(object) != null or query.defaultNamespaceReceiver(object) != null) skip = 1;
    }
    var count: usize = 0;
    for (skip..call.args.len) |index| {
        if (call.argument_names.len != 0 and call.argument_names[index] != null) break;
        count += 1;
    }
    return count;
}

fn argumentSupplied(names: []const ?[]const u8, name: []const u8) bool {
    for (names) |item| if (item) |label| if (std.mem.eql(u8, label, name)) return true;
    return false;
}

fn contextStatements(body: []const *ast.Stmt, offset: usize) ?*const ast.Expr {
    for (body) |statement| {
        if (offset < statement.span.start or offset > statement.span.end) continue;
        switch (statement.value) {
            .expression, .default_output => |expr| return contextExpression(expr, offset),
            .assignment => |assignment| return contextExpression(assignment.value, offset),
            .set => |set| return contextExpression(set.target, offset) orelse contextExpression(set.value, offset),
            .append_to => |append| return contextExpression(append.target, offset) orelse contextExpression(append.value, offset),
            .list_append => |append| return contextExpression(append.value, offset),
            .parameter => |parameter| if (parameter.default) |value| return contextExpression(value, offset),
            inline .function, .expand_block => |function| {
                for (function.params) |parameter| if (parameter.default) |value| if (contextExpression(value, offset)) |context| return context;
                return contextStatements(function.body, offset);
            },
            .structure => |structure| for (structure.fields) |field| {
                if (field.default) |value| if (contextExpression(value, offset)) |context| return context;
            },
            .exported => |exported| if (exported.value) |value| return contextExpression(value, offset),
            .return_value => |value| if (value) |expr| return contextExpression(expr, offset),
            .conditional => |conditional| {
                for (conditional.branches) |branch| {
                    if (contextExpression(branch.condition, offset)) |context| return context;
                    if (contextStatements(branch.body, offset)) |context| return context;
                }
                return contextStatements(conditional.otherwise, offset);
            },
            .for_loop => |loop| return (switch (loop.iterable) {
                .collection => |expr| contextExpression(expr, offset),
                .range => |range| contextExpression(range.start, offset) orelse (if (range.step) |step| contextExpression(step, offset) else null) orelse contextExpression(range.stop.?, offset),
            }) orelse contextStatements(loop.body, offset),
            .while_loop => |loop| return contextExpression(loop.condition, offset) orelse contextStatements(loop.body, offset),
            else => {},
        }
    }
    return null;
}

fn contextExpression(expr_: *const ast.Expr, offset: usize) ?*const ast.Expr {
    if (offset < expr_.span.start or offset > expr_.span.end) return null;
    const expr = ungroup(expr_);
    switch (expr.value) {
        .block => |body| return contextStatements(body, offset),
        .expansion => |value| {
            for (value.args) |arg| if (contextExpression(arg, offset)) |found| return found;
            return contextStatements(value.body, offset);
        },
        .member => |member_| return contextExpression(member_.object, offset) orelse if (offset >= member_.object.span.end) expr else null,
        .call => |call| {
            for (call.args) |argument| if (argument.span.start <= offset and offset < argument.span.end) return contextExpression(argument, offset);
            return expr;
        },
        .list => |items| for (items) |item| {
            if (contextExpression(item, offset)) |context| return context;
        },
        .dict => |entries| for (entries) |entry| {
            if (contextExpression(entry.value, offset)) |context| return context;
        },
        .pair => |pair| return contextExpression(pair.x, offset) orelse contextExpression(pair.y, offset),
        .unary => |unary| return contextExpression(unary.operand, offset),
        .quantity => |quantity| return contextExpression(quantity.operand, offset),
        .binary => |binary| return contextExpression(binary.left, offset) orelse contextExpression(binary.right, offset),
        .path_join, .path_literal => {
            const join = if (expr.value == .path_join) expr.value.path_join else expr.value.path_literal;
            return contextExpression(join.left, offset) orelse contextExpression(join.right, offset);
        },
        .index => |index| return contextExpression(index.object, offset) orelse contextExpression(index.index, offset),
        .slice => |slice| return contextExpression(slice.object, offset) orelse contextExpression(slice.range.start, offset) orelse (if (slice.range.step) |step| contextExpression(step, offset) else null) orelse (if (slice.range.stop) |stop| contextExpression(stop, offset) else null),
        .mixfix_call => |call| for (call.args) |argument| {
            if (contextExpression(argument, offset)) |context| return context;
        },
        else => {},
    }
    return null;
}

fn ungroup(expr: *const ast.Expr) *const ast.Expr {
    return if (expr.value == .grouped) ungroup(expr.value.grouped) else expr;
}

fn declaration(unit: *const ModuleGraph.Unit, name: []const u8, role: Role) ?ast.Span {
    if (role == .value) for (unit.headers.scopes[0].ordinary_names) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding.span;
    };
    for (unit.script.statements) |statement| {
        const matches = switch (statement.value) {
            inline .function, .expand_block => |function| role == .callable and std.mem.eql(u8, function.name, name),
            .structure => |structure| role == .type_symbol and std.mem.eql(u8, structure.name, name),
            .precedence_group => |group| role == .precedence and std.mem.eql(u8, group.name, name),
            else => false,
        };
        if (matches) return nameInHeader(unit.source_text, statement.span, name);
    }
    return null;
}

fn nameInHeader(text: []const u8, span: ast.Span, name: []const u8) ?ast.Span {
    var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = text, .pos = span.start, .diagnostic = &diagnostic };
    while (true) {
        const token = scanner.next() catch return null;
        if (token.kind == .eof or token.span.end > span.end) return null;
        if (token.kind == .identifier and std.mem.eql(u8, text[token.span.start..token.span.end], name)) return token.span;
    }
}

const Fixture = struct {
    name: []const u8 = "/tmp/definition.huak",
    source: []const u8,
    files: []const struct { name: []const u8, source: []const u8 } = &.{},

    fn resolve(context: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.eql(u8, path, file.name)) return .{ .name = file.name, .source = file.source };
        return error.FileNotFound;
    }

    fn lookup(self: *const Fixture, allocator: std.mem.Allocator, query: []const u8) !?Location {
        var frontend: Frontend = .{ .allocator = allocator, .io = std.testing.io, .library_path = "/missing-unused-library", .overlay = .{ .ptr = @constCast(self), .vtable = &.{ .resolve = resolve } } };
        defer frontend.deinit();
        const offset = std.mem.lastIndexOf(u8, self.source, query) orelse return error.MissingTestQuery;
        return find(&frontend, allocator, self.source, self.name, offset);
    }

    fn expect(self: *const Fixture, query: []const u8, uri: []const u8, target_source: []const u8, target_name: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const result = (try self.lookup(arena.allocator(), query)) orelse return error.MissingDefinition;
        const start = std.mem.indexOf(u8, target_source, target_name) orelse return error.MissingTestTarget;
        var diagnostic: ?@import("../language/source.zig").Diagnostic = null;
        var scanner: Lexer = .{ .source = target_source, .pos = start, .diagnostic = &diagnostic };
        const token = try scanner.next();
        try std.testing.expectEqualStrings(uri, result.uri);
        try std.testing.expectEqualDeep(locations.Range{ .start = locations.at(target_source, start), .end = locations.at(target_source, token.span.end) }, result.range);
    }

    fn expectNone(self: *const Fixture, query: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expect(try self.lookup(arena.allocator(), query) == null);
    }
};

test "definitions respect block locals parameters global bindings and UFCS" {
    const source =
        \\global_value:=4
        \\fn increment(value:int)->int
        \\local_value:=value+global_value
        \\if true then local_value=8 end
        \\if true then
        \\    local_value:=9
        \\    print(local_value)
        \\end
        \\for value in [1] do print(value) end
        \\return local_value
        \\end
        \\result:=global_value.increment()
    ;
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("value+", "file:///tmp/definition.huak", source, "value:int");
    try fixture.expect("global_value\n", "file:///tmp/definition.huak", source, "global_value");
    try fixture.expect("local_value\n", "file:///tmp/definition.huak", source, "local_value");
    try fixture.expect("local_value)", "file:///tmp/definition.huak", source, "local_value:=9");
    try fixture.expect("value) end", "file:///tmp/definition.huak", source, "value in");
    try fixture.expect("increment()", "file:///tmp/definition.huak", source, "increment");
}

test "definitions follow selected aliases namespace calls values and reexports" {
    const library = "export fn increment(value:int)->int return value+1 end\nexport amount:=3\n";
    const facade = "import \"/tmp/library.huak\".{increment as bump,amount}\nexport bump,amount\n";
    const source =
        \\import "/tmp/facade.huak".{bump as shifted,amount}
        \\import "/tmp/library.huak" as library
        \\result:=shifted(amount)+library.increment(library.amount)
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{ .{ .name = "/tmp/library.huak", .source = library }, .{ .name = "/tmp/facade.huak", .source = facade } } };
    try fixture.expect("shifted(amount)", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("increment(library", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("amount)", "file:///tmp/library.huak", library, "amount");
    try fixture.expect("amount}", "file:///tmp/library.huak", library, "amount");
    try fixture.expectNone("as shifted");
    try fixture.expectNone("as library");
}

test "Typst exposure names navigate through ordinary local and imported value bindings" {
    const library = "export amount:=3\n";
    const source =
        \\import "/tmp/library.huak".amount as count
        \\title:="Figure"
        \\typst_expose title, count
        \\fn label(title:string)->string
        \\    typst_expose title
        \\    return title
        \\end
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("title, count", "file:///tmp/definition.huak", source, "title:=");
    try fixture.expect("count\n", "file:///tmp/library.huak", library, "amount");
    try fixture.expect("title\n    return", "file:///tmp/definition.huak", source, "title:string");
    try fixture.expectNone("typst_expose title, count");
}

test "definitions use scoped callable imports and restore outer callable after block" {
    const library = "export fn increment(value:int)->int return value end\n";
    const source =
        \\fn count(value:int)->int return value end
        \\if true then
        \\import "/tmp/library.huak".increment as count
        \\inside:=count(1)
        \\end
        \\outside:=count(2)
    ;
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("count(1)", "file:///tmp/library.huak", library, "increment");
    try fixture.expect("count(2)", "file:///tmp/definition.huak", source, "count");
}

test "definitions classify operators and mixfix labels without treating arguments as labels" {
    const source =
        \\precedence transform above addition;associativity left end
        \\fn shifted(left:int,right:int)->int return left+right end
        \\mixfix(shifted) _ shifted _ in transform
        \\fn twice(value:int)->int return 2*value end
        \\mixfix(twice) twice _ in unary
        \\fn combine(left:int,right:int)->int return left+right end
        \\mixfix(combine) sum from _ to _ in unary
        \\amount:=3
        \\a:=amount shifted 4
        \\b:=twice amount
        \\c:=sum from amount to 5
    ;
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("shifted 4", "file:///tmp/definition.huak", source, "shifted");
    try fixture.expect("twice amount", "file:///tmp/definition.huak", source, "twice");
    try fixture.expect("sum from amount", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("from amount", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("to 5", "file:///tmp/definition.huak", source, "combine");
    try fixture.expect("amount to", "file:///tmp/definition.huak", source, "amount");
    try fixture.expect("transform\n", "file:///tmp/definition.huak", source, "transform");
}

test "definitions keep comments literals native fields and builtins opaque" {
    const source = "fn target()->int return 1 end\n// target\nvalue:=\"target\"\npoint:=(1,2)\nresult:=point.x+sin(0)\n";
    const fixture: Fixture = .{ .source = source };
    try fixture.expectNone("target\n");
    try fixture.expectNone("target\"");
    try fixture.expectNone("x+sin");
    try fixture.expectNone("sin(0)");
    try (Fixture{ .source = "fn broken(\nx=broken()" }).expectNone("broken()");
}

test "standard definitions expose source functions while native functions remain opaque" {
    const source = "import assertions.assert\nassert(true)\n";
    const fixture: Fixture = .{ .source = source };
    try fixture.expect("assert(true)", "huak-stdlib:/std/assertions.huak", standard.source("std/assertions.huak").?, "assert");
    const native: Fixture = .{ .source = "import paint.*\np:=circle((0,0),2)\n" };
    try native.expectNone("circle((");
}

test "definitions preserve UTF16 columns and percent encode filenames" {
    const source = "label:=\"🙂\";value:=1\nresult:=value\n";
    const fixture: Fixture = .{ .name = "/tmp/figure space.huak", .source = source };
    try fixture.expect("value\n", "file:///tmp/figure%20space.huak", source, "value");
}

test "an imported data value navigates to its file" {
    const fixture: Fixture = .{
        .source = "import \"/tmp/points.csv\" as rows\nfirst:=rows[0]",
        .files = &.{.{ .name = "/tmp/points.csv", .source = "1,2" }},
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const target = (try fixture.lookup(arena.allocator(), "rows[0]")).?;
    try std.testing.expectEqualStrings("file:///tmp/points.csv", target.uri);
    try std.testing.expectEqual(locations.at("1,2", 0), target.range.start);
}

test "definition request arenas release allocations on every allocation failure" {
    const fixture: Fixture = .{ .source = "fn target(value:int)->int return value end\nresult:=target(4)\n" };
    const Check = struct {
        fn run(allocator: std.mem.Allocator, input: *const Fixture) !void {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            try std.testing.expect(try input.lookup(arena.allocator(), "target(4)") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{&fixture});
}

test "definition and hover token selection accepts identifier endpoints before punctuation" {
    const source = "fn target()->int return 1 end\nresult:=target()\n";
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const offset = std.mem.lastIndexOf(u8, source, "target()").? + "target".len;
    const token = (try tokenAt(&frontend, source, offset)).?;
    try std.testing.expectEqualStrings("target", source[token.span.start..token.span.end]);
    const result = (try find(&frontend, arena.allocator(), source, "/tmp/definition.huak", offset)).?;
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 3 }, result.range.start);
}

test "qualified operators share exported identities while namespace tokens navigate to module" {
    const library = "export fn shifted(left:int,right:int)->int return left+right end\nmixfix(shifted) _ shifted _ in addition\nexport fn twice(value:int)->int return value*2 end\nmixfix(twice) twice _ in unary\n";
    const source = "import \"/tmp/library.huak\" as lib\nx:=1 lib.shifted 2\ny:=lib.twice 3\nmixfix(lib.twice) double _ in unary\nz:=double 3\n";
    const fixture: Fixture = .{ .source = source, .files = &.{.{ .name = "/tmp/library.huak", .source = library }} };
    try fixture.expect("shifted 2", "file:///tmp/library.huak", library, "shifted");
    try fixture.expect("twice 3", "file:///tmp/library.huak", library, "twice");
    try fixture.expect("twice) double", "file:///tmp/library.huak", library, "twice");
    try fixture.expect("double 3", "file:///tmp/library.huak", library, "twice");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = (try fixture.lookup(arena.allocator(), "lib.twice")).?;
    try std.testing.expectEqualStrings("file:///tmp/library.huak", result.uri);
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 0 }, result.range.start);
}

test "record navigation follows type annotations constructors aliases fields and named arguments" {
    const input =
        \\struct Widget
        \\    width:int
        \\    options:dict={"key": 1}
        \\end
        \\item:Widget:=Widget(width:3)
        \\alias:=item
        \\value:=alias.width
        \\fn measure(target:Widget)->int
        \\    return target.width
        \\end
        \\answer:=measure(target:alias)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("Widget:=Widget", "file:///tmp/definition.huak", input, "Widget");
    try fixture.expect("Widget(width", "file:///tmp/definition.huak", input, "Widget");
    try fixture.expect("width:3", "file:///tmp/definition.huak", input, "width");
    try fixture.expect("width\n", "file:///tmp/definition.huak", input, "width");
    try fixture.expect("target:alias", "file:///tmp/definition.huak", input, "target");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const offset = std.mem.indexOf(u8, input, "width:3").?;
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, offset)).?;
    try std.testing.expectEqualStrings("Widget.width: int", detail);
}

test "record navigation preserves imported reexported type identities and field annotations" {
    const library = "export struct Settings\nsize:int=2\nend\n";
    const facade = "import \"/tmp/settings.huak\".Settings as Options\nexport Options\n";
    const input = "import \"/tmp/facade.huak\" as config\nitem:config.Options:=config.Options(size:3)\nvalue:=item.size\n";
    const fixture: Fixture = .{ .source = input, .files = &.{ .{ .name = "/tmp/settings.huak", .source = library }, .{ .name = "/tmp/facade.huak", .source = facade } } };
    try fixture.expect("Options:=config", "file:///tmp/settings.huak", library, "Settings");
    try fixture.expect("Options(size", "file:///tmp/settings.huak", library, "Settings");
    try fixture.expect("size:3", "file:///tmp/settings.huak", library, "size");
    try fixture.expect("size\n", "file:///tmp/settings.huak", library, "size");
}

test "record completions infer member receivers and offer unsupplied constructor labels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const prefix = "struct Widget\nwidth:int\nheight:int=2\nend\nitem:=Widget(width:1)\n";
    const source = prefix ++ "value:=item.";
    const fields = try complete(&frontend, arena.allocator(), source, "/tmp/completion.huak", source.len);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("width", fields[0].label);
    try std.testing.expectEqualStrings("height", fields[1].label);
    const named = prefix ++ "value:=Widget(width:1,)";
    const arguments = try complete(&frontend, arena.allocator(), named, "/tmp/completion.huak", named.len - 1);
    try std.testing.expectEqual(@as(usize, 1), arguments.len);
    try std.testing.expectEqualStrings("height", arguments[0].label);
    try std.testing.expectEqualStrings("height: ", arguments[0].insertText.?);
    const positional = prefix ++ "value:=Widget(1,)";
    const remaining = try complete(&frontend, arena.allocator(), positional, "/tmp/completion.huak", positional.len - 1);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("height", remaining[0].label);
}

test "default math completion and hover use native metadata without source navigation" {
    const input = "fn sin(value:int)->int return value end\nvalue:=math.sin(0)\nangle:=math.PI\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sin(0)");
    try fixture.expectNone("PI\n");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const function = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "sin(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, function, "fn math.sin("));
    const constant = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "PI\n").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant, "math.PI: number = 3.14"));
    const unfinished = "value:=math.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    var sin = false;
    var pi = false;
    for (members) |item| {
        sin = sin or std.mem.eql(u8, item.label, "sin");
        pi = pi or std.mem.eql(u8, item.label, "PI");
        try std.testing.expect(!std.mem.eql(u8, item.label, "print") and !std.mem.eql(u8, item.label, "picture"));
    }
    try std.testing.expect(sin and pi);
    const ordinary = try complete(&frontend, arena.allocator(), "value:=1", fixture.name, 0);
    var namespace = false;
    for (ordinary) |item| {
        namespace = namespace or std.mem.eql(u8, item.label, "math");
        try std.testing.expect(!std.mem.eql(u8, item.label, "sin"));
    }
    try std.testing.expect(namespace);
    try std.testing.expect(frontend.native == null);
}

test "data and imported namespace bindings shadow default math tooling" {
    const input = "struct Settings\nPI:int\nend\nmath:=Settings(PI:2)\nvalue:=math.PI\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("PI\n", "file:///tmp/definition.huak", input, "PI");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.lastIndexOf(u8, input, "PI\n").?)).?;
    try std.testing.expectEqualStrings("Settings.PI: int", detail);
    const unfinished = "struct Settings\nPI:int\nend\nmath:=Settings(PI:2)\nvalue:=math.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqualStrings("PI", members[0].label);
    const library = "export fn sin(value:int)->int return value end\n";
    const namespaced: Fixture = .{ .source = "import \"/tmp/custom-math.huak\" as math\nvalue:=math.sin(2)\n", .files = &.{.{ .name = "/tmp/custom-math.huak", .source = library }} };
    try namespaced.expect("sin(2)", "file:///tmp/custom-math.huak", library, "sin");
}

test "explicit math imports retain native hover and never invent a source document" {
    const input = "import math.sin as sine\nimport math.PI as pi\nimport math as native\nvalue:=sine(0)\nangle:=pi\nother:=native.cos(0)\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sine(0)");
    try fixture.expectNone("pi\n");
    try fixture.expectNone("cos(0)");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const function = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "sine(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, function, "fn math.sin("));
    const constant = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.lastIndexOf(u8, input, "pi\n").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant, "math.PI: number"));
    const cosine = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "cos(0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, cosine, "fn math.cos("));
    try std.testing.expect(frontend.native == null);
}

test "default native domains expose only their owned members and canonical hover" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    for (std.enums.values(builtins.Namespace)) |namespace| {
        const input = try std.fmt.allocPrint(a, "value:={s}.", .{namespace.name()});
        const members = try complete(&frontend, a, input, "/tmp/domains.huak", input.len);
        var expected: usize = 0;
        for (builtins.signatures) |signature| if (signature.namespace == namespace) {
            expected += 1;
            var found = false;
            for (members) |member| if (std.mem.eql(u8, member.label, signature.name)) {
                found = true;
                const prefix = try std.fmt.allocPrint(a, "fn {s}.{s}(", .{ namespace.name(), signature.name });
                try std.testing.expect(std.mem.startsWith(u8, member.detail, prefix));
            };
            try std.testing.expect(found);
        };
        expected += builtins.constantNames(namespace).len;
        try std.testing.expectEqual(expected, members.len);
        const namespace_source = try std.fmt.allocPrint(a, "value:={s}", .{namespace.name()});
        const namespace_hover = (try describe(&frontend, a, namespace_source, "/tmp/domains.huak", "value:=".len)).?;
        try std.testing.expect(std.mem.startsWith(u8, namespace_hover, namespace.name()));
    }
    try std.testing.expect(frontend.native == null);
}

test "native domain data shadowing and imported aliases preserve their distinct targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    for (std.enums.values(builtins.Namespace)) |namespace| {
        const prefix = try std.fmt.allocPrint(a, "struct Settings value:int end\n{s}:=Settings(value:2)\nanswer:={s}.", .{ namespace.name(), namespace.name() });
        const members = try complete(&frontend, a, prefix, "/tmp/shadow.huak", prefix.len);
        try std.testing.expectEqual(@as(usize, 1), members.len);
        try std.testing.expectEqualStrings("value", members[0].label);
        const input = try std.fmt.allocPrint(a, "{s}value\n", .{prefix});
        const detail = (try describe(&frontend, a, input, "/tmp/shadow.huak", prefix.len)).?;
        try std.testing.expectEqualStrings("Settings.value: int", detail);
    }
    const facade = "import geometry.circle as disk\nexport disk\n";
    const input = "import \"/tmp/domain-facade.huak\".disk as ring\nvalue:=ring((0,0),1)\n";
    const fixture: Fixture = .{ .source = input, .files = &.{.{ .name = "/tmp/domain-facade.huak", .source = facade }} };
    try fixture.expectNone("ring((");
    frontend.overlay = .{ .ptr = @constCast(&fixture), .vtable = &.{ .resolve = Fixture.resolve } };
    const detail = (try describe(&frontend, a, input, fixture.name, std.mem.indexOf(u8, input, "ring((").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
}

test "nested exported namespaces retain definitions types and module identities" {
    const library = "export struct Widget\nwidth:int\nend\nexport fn increment(value:int)->int return value+1 end\n";
    const facade = "import \"/tmp/nested-library.huak\" as tools\nexport tools\n";
    const input =
        \\import "/tmp/nested-facade.huak" as facade
        \\import "/tmp/nested-facade.huak".tools.{increment as bump,Widget}
        \\item:facade.tools.Widget:=facade.tools.Widget(width:3)
        \\result:=facade.tools.increment(bump(item.width))
    ;
    const fixture: Fixture = .{ .source = input, .files = &.{ .{ .name = "/tmp/nested-library.huak", .source = library }, .{ .name = "/tmp/nested-facade.huak", .source = facade } } };
    try fixture.expect("increment(bump", "file:///tmp/nested-library.huak", library, "increment");
    try fixture.expect("bump(item", "file:///tmp/nested-library.huak", library, "increment");
    try fixture.expect("Widget:=facade", "file:///tmp/nested-library.huak", library, "Widget");
    try fixture.expect("Widget(width", "file:///tmp/nested-library.huak", library, "Widget");
    try fixture.expect("width:3", "file:///tmp/nested-library.huak", library, "width");
    try fixture.expect("width))", "file:///tmp/nested-library.huak", library, "width");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library", .overlay = .{ .ptr = @constCast(&fixture), .vtable = &.{ .resolve = Fixture.resolve } } };
    defer frontend.deinit();
    const module_hover = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "tools.Widget:=").?)).?;
    try std.testing.expectEqualStrings("module /tmp/nested-library.huak", module_hover);
    const module_location = (try fixture.lookup(arena.allocator(), "tools.Widget:=")).?;
    try std.testing.expectEqualStrings("file:///tmp/nested-library.huak", module_location.uri);
    try std.testing.expectEqualDeep(locations.Position{ .line = 0, .character = 0 }, module_location.range.start);
    const unfinished = "import \"/tmp/nested-facade.huak\" as facade\nvalue:=facade.tools.";
    const members = try complete(&frontend, arena.allocator(), unfinished, fixture.name, unfinished.len);
    try std.testing.expectEqual(@as(usize, 2), members.len);
    for (members) |member| try std.testing.expect(std.mem.eql(u8, member.label, "Widget") or std.mem.eql(u8, member.label, "increment"));
}

test "standard root completes modules and nested native members without fake definitions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const root = "import std\nvalue:=std.";
    const modules_ = try complete(&frontend, a, root, "/tmp/standard-root.huak", root.len);
    var has_weave = false;
    var has_regions = false;
    for (modules_) |module| {
        has_weave = has_weave or std.mem.eql(u8, module.label, "weave");
        has_regions = has_regions or std.mem.eql(u8, module.label, "regions");
        try std.testing.expectEqual(@as(u8, 9), module.kind);
        try std.testing.expect(!std.mem.eql(u8, module.label, "assert") and !std.mem.eql(u8, module.label, "circle"));
        try std.testing.expect(std.mem.startsWith(u8, module.detail, "module "));
    }
    try std.testing.expect(has_weave and has_regions);
    const input = "import std\nimport std.math.{cos as cosine,PI as pi}\nvalue:=std.math.sin(cosine(pi))\n";
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("sin(cosine");
    try fixture.expectNone("cosine(pi)");
    try fixture.expectNone("pi))");
    const native_hover = (try describe(&frontend, a, input, fixture.name, std.mem.indexOf(u8, input, "sin(cosine").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, native_hover, "fn math.sin("));
    const alias_hover = (try describe(&frontend, a, input, fixture.name, std.mem.indexOf(u8, input, "cosine(pi)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, alias_hover, "fn math.cos("));
    const constant_hover = (try describe(&frontend, a, input, fixture.name, std.mem.indexOf(u8, input, "pi))").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, constant_hover, "math.PI: number"));
    const math = "import std\nvalue:=std.math.";
    const members = try complete(&frontend, a, math, fixture.name, math.len);
    var has_sin = false;
    var has_pi = false;
    for (members) |member| {
        has_sin = has_sin or std.mem.eql(u8, member.label, "sin");
        has_pi = has_pi or std.mem.eql(u8, member.label, "PI");
        try std.testing.expect(!std.mem.eql(u8, member.label, "circle"));
    }
    try std.testing.expect(has_sin and has_pi);
    const named = "import std\nvalue:=std.geometry.circle(center:(0,0),)";
    const labels = try complete(&frontend, a, named, fixture.name, named.len - 1);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("radius", labels[0].label);
    try std.testing.expect(frontend.native == null);
}

test "tooling follows ordinary data shadowing and imports become visible at their declaration" {
    const input =
        \\fn count(value:int)->int return value end
        \\fn probe(count:int)->int
        \\    return count(1)
        \\end
        \\before:=disk((0,0),1)
        \\import geometry.circle as disk
        \\after:=disk((0,0),1)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expect("count(1)", "file:///tmp/definition.huak", input, "count:int");
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const before = std.mem.indexOf(u8, input, "disk((").?;
    try std.testing.expect(try describe(&frontend, arena.allocator(), input, fixture.name, before) == null);
    const after = std.mem.lastIndexOf(u8, input, "disk((").?;
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, after)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
    const early = try complete(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "before:=").?);
    for (early) |item| try std.testing.expect(!std.mem.eql(u8, item.label, "disk"));
    const late = try complete(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "after:=").?);
    var found = false;
    for (late) |item| found = found or std.mem.eql(u8, item.label, "disk");
    try std.testing.expect(found);
}

test "nested drawing modules preserve imported mixfix and infix navigation" {
    const input =
        \\import std
        \\import std.paint.circle as disk
        \\curve:=std.paint.circle with center (0,0) radius 2
        \\other:=circle with center (2,3) radius 4
        \\placed:=content std.paint.at (5,6)
    ;
    const fixture: Fixture = .{ .source = input };
    try fixture.expectNone("center (0,0)");
    try fixture.expectNone("center (2,3)");
    try fixture.expect("at (5,6)", "huak-stdlib:/std/paint.huak", standard.source("std/paint.huak").?, "at(content");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const detail = (try describe(&frontend, arena.allocator(), input, fixture.name, std.mem.indexOf(u8, input, "center (0,0)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn geometry.circle("));
    const template = "export expand_block drawing(target:int)\nplace:=len.with(\"abc\")\nmixfix(place) place _ in unary\n...\nreturn target\nend\n";
    const caller = "import \"/tmp/commands.huak\".drawing as paint\nanswer:=paint 3 do\nplace()\nend\n";
    const expanded: Fixture = .{ .source = caller, .files = &.{.{ .name = "/tmp/commands.huak", .source = template }} };
    try expanded.expect("paint 3", "file:///tmp/commands.huak", template, "drawing");
    try expanded.expect("place()", "file:///tmp/commands.huak", template, "place:=");
    const symbolic: Fixture = .{ .source = "fn subtract(a:int,b:int)->int return a-b end\nmixfix(subtract) _ + _ in addition\nx:=8+3\n" };
    try symbolic.expect("+ _", "file:///tmp/definition.huak", symbolic.source, "subtract(a");
    try symbolic.expect("+3", "file:///tmp/definition.huak", symbolic.source, "subtract(a");
    const bound: Fixture = .{ .source = "fn command(value:int)->int return value end\nanswer:=block\ncommand:=command.with(value:1)\nreturn command()\nend\n" };
    try bound.expect("command.with", "file:///tmp/definition.huak", bound.source, "command(value");
    try bound.expect("command()", "file:///tmp/definition.huak", bound.source, "command:=");
}

test "primary native constructors remain callable through their normal namespace binding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var frontend: Frontend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .library_path = "/missing-unused-library" };
    defer frontend.deinit();
    const input = "import std.pen\nnib:=pen(color.rgb(0,0,0))\n";
    const detail = (try describe(&frontend, arena.allocator(), input, "/tmp/constructors.huak", std.mem.indexOf(u8, input, "pen(color").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, detail, "fn pen.pen("));
    const members = try complete(&frontend, arena.allocator(), input, "/tmp/constructors.huak", std.mem.indexOf(u8, input, "nib:=").?);
    var found = false;
    for (members) |member| if (std.mem.eql(u8, member.label, "pen")) {
        try std.testing.expectEqual(@as(u8, 4), member.kind);
        try std.testing.expect(std.mem.startsWith(u8, member.detail, "fn pen("));
        found = true;
    };
    try std.testing.expect(found);
    const alias = "import std.math as pen\nnib:=pen(1)\n";
    const invalid = (try describe(&frontend, arena.allocator(), alias, "/tmp/constructors.huak", std.mem.indexOf(u8, alias, "pen(1)").?)).?;
    try std.testing.expect(std.mem.startsWith(u8, invalid, "math —"));
}
