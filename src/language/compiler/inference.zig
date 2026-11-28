//! Static result types of builtins that depend on their argument types.
const std = @import("std");
const ast = @import("../ast.zig");
const bc = @import("../bytecode.zig");
const builtin = @import("../builtin.zig");
const Type = bc.Type;
const modules = @import("modules.zig");
const calls = @import("calls.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const ungroup = ast.ungroup;
const CallTarget = modules.CallTarget;

pub fn builtinResult(self: *Compiler, context: *Context, signature: builtin.Signature, args: []const *ast.Expr) Type {
    if (signature.id == .unit or signature.id == .lerp or signature.id == .apply) {
        // Both vector parameters of lerp must have the same dimension.
        // Named calls can supply them in either order.
        for (args) |arg| if (expressionType(self, context, arg)) |kind| {
            if (kind.isVector()) return kind;
        };
    }
    switch (signature.id) {
        .rectangle, .circle, .ellipse, .arc, .bezier, .path => for (args) |arg| {
            if (expressionType(self, context, arg)) |kind| {
                if (kind == .vec2) return .path;
                if (kind == .vec3) return .shape;
            }
        },
        .reverse, .closed => if (args.len == 1) return expressionType(self, context, args[0]) orelse signature.result,
        .joined, .region_union, .region_intersection, .region_difference => if (args.len >= 2) {
            const left = expressionType(self, context, args[0]);
            const right = expressionType(self, context, args[1]);
            if (left == .shape or right == .shape) return .shape;
            if (left == .path and right == .path) return .path;
        },
        else => {},
    }
    return if (signature.id == .copy and args.len == 1) expressionType(self, context, args[0]) orelse signature.result else signature.result;
}

pub fn expressionType(self: *Compiler, context: *Context, expression: *ast.Expr) ?Type {
    const inner = ungroup(expression);
    if (inner.value == .name) if (context.resolve(inner.value.name, inner.span)) |binding| return binding.symbol.kind;
    if (inner.value == .dict) return .dict;
    if (inner.value == .list) return .list;
    if (inner.value == .vector) return if (inner.value.vector.z == null) .vec2 else .vec3;
    if (inner.value == .member) {
        const member = inner.value.member;
        if (ungroup(member.object).value == .name) {
            const name = ungroup(member.object).value.name;
            if (modules.defaultNamespace(self, context, name, inner.span)) |native| if (builtin.namespaceConstant(native, member.name)) |value| return value.valueType();
        }
        if (modules.moduleExpression(self, member.object)) |module_index| for (self.build.modules[module_index].exports) |exposed| {
            if (std.mem.eql(u8, exposed.name, member.name) and exposed.target == .global) return self.build.types.items[exposed.target.global];
        };
        const object = expressionType(self, context, member.object) orelse return null;
        if (object.recordIndex()) |index| if (index < self.build.records.items.len) {
            for (self.build.records.items[index].fields) |field| if (std.mem.eql(u8, field.name, member.name)) return field.kind;
        };
    }
    if (inner.value == .call) {
        const call = inner.value.call;
        var target: ?CallTarget = null;
        var skip: usize = 0;
        if (call.qualified) |name| {
            target = (modules.qualifiedTarget(self, name.*) catch return null).target;
        } else if (call.dot and call.args.len != 0) {
            if (ungroup(call.args[0]).value == .name) if (modules.defaultNamespace(self, context, ungroup(call.args[0]).value.name, inner.span)) |native| {
                const signature = builtin.namespaceLookup(native, call.name) orelse return null;
                return builtinResult(self, context, signature, call.args[1..]);
            };
            if (modules.moduleExpression(self, call.args[0])) |module_index| {
                skip = 1;
                for (self.build.modules[module_index].exports) |exposed| {
                    if (std.mem.eql(u8, exposed.name, call.name)) target = exposed.target;
                }
            }
        }
        if (target == null) {
            const resolved = self.environment.unit.resolverAt(inner.span.start).callable(self.environment.unit.scopeAt(inner.span.start), call.name);
            if (resolved.shadowed) return null;
            target = if (resolved.namespace) |owner| modules.namespaceCallTarget(self, owner, call.name) else modules.callTarget(self, call.name, resolved.member);
        }
        return switch (target orelse return null) {
            .record => |index| Type.record(index),
            .function => |index| calls.callFunction(self, index).result,
            .builtin => |id| builtinResult(self, context, builtin.signature(id), call.args[skip..]),
            else => null,
        };
    }
    return null;
}
