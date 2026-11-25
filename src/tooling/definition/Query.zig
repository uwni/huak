const std = @import("std");
const ast = @import("../../language/ast.zig");
const ModuleGraph = @import("../../language/ModuleGraph.zig");
const Lexer = @import("../../language/Lexer.zig");
const builtins = @import("../../language/builtin.zig");
const definition = @import("../definition.zig");
const Query = @This();
const Target = definition.Target;
const Role = definition.Role;
const ungroup = ast.ungroup;

graph: *const ModuleGraph,
unit: *const ModuleGraph.Unit,
token: Lexer.Token,
name: []const u8,

pub fn contains(self: Query, span: ast.Span) bool {
    return span.start <= self.token.span.start and self.token.span.end <= span.end;
}

pub fn moduleStart(unit: *const ModuleGraph.Unit) Target {
    return .{ .unit = unit, .span = .{ .start = 0, .end = 0 }, .native = if (unit.native_namespace) |namespace| .{ .namespace = namespace } else null, .module_start = true };
}

pub fn named(self: Query, name: []const u8, offset: usize, role: Role) ?Target {
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

pub fn targetIdentity(self: Query, identity: ModuleGraph.lexical.Identity) ?Target {
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

pub fn public(self: Query, id: u32, name: []const u8) ?Target {
    const unit = self.graph.units.items[id];
    const exposed = unit.public_names.get(name) orelse return null;
    return self.targetIdentity(exposed.identity);
}

pub fn operatorTarget(self: Query, name: ast.OperatorName, role: Role) ?Target {
    if (name.namespace) |namespace| {
        if (self.graph.resolveNamespaceAt(self.unit, self.unit.scopeAt(name.span.start), namespace, name.span.start)) |id| return self.public(id, name.name);
        const native = self.defaultNamespace(namespace, name.span.start) orelse return null;
        const signature = builtins.namespaceLookup(native, name.name) orelse return null;
        return .{ .unit = self.unit, .span = self.token.span, .native = .{ .function = signature.id } };
    }
    return self.named(name.name, name.span.start, role);
}

pub fn inUnit(self: Query, unit: *const ModuleGraph.Unit) Query {
    var result = self;
    result.unit = unit;
    return result;
}

pub fn defaultNamespace(self: Query, name: []const u8, offset: usize) ?builtins.Namespace {
    if (self.unit.resolverAt(offset).readable(self.unit.scopeAt(offset), name) != null) return null;
    return builtins.Namespace.parse(name);
}

pub fn defaultNamespaceReceiver(self: Query, expr: *const ast.Expr) ?builtins.Namespace {
    const object = ungroup(expr);
    return if (object.value == .name) self.defaultNamespace(object.value.name, object.span.start) else null;
}

pub fn namespaceReceiver(self: Query, expression_: *const ast.Expr) ?u32 {
    const node = ungroup(expression_);
    return switch (node.value) {
        .name => |name| self.unit.resolverAt(node.span.start).namespace(self.unit.scopeAt(node.span.start), name),
        .member => |member| self.graph.exportedNamespace(self.namespaceReceiver(member.object) orelse return null, member.name),
        else => null,
    };
}

pub fn callTarget(self: Query, expr: *const ast.Expr) ?Target {
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

pub fn declaration(unit: *const ModuleGraph.Unit, name: []const u8, role: Role) ?ast.Span {
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
    var diagnostic: ?@import("../../language/source.zig").Diagnostic = null;
    var scanner: Lexer = .{ .source = text, .pos = span.start, .diagnostic = &diagnostic };
    while (true) {
        const token = scanner.next() catch return null;
        if (token.kind == .eof or token.span.end > span.end) return null;
        if (token.kind == .identifier and std.mem.eql(u8, text[token.span.start..token.span.end], name)) return token.span;
    }
}
