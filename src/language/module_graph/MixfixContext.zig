//! The parser's mixfix and block lookup provider for one unit: declarations visible at a position, entered blocks, and module namespaces.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const lexical = @import("../scope.zig");
const ModuleGraph = @import("../ModuleGraph.zig");
const symbols = @import("symbols.zig");
const MixfixContext = @This();

graph: *ModuleGraph,
unit: *ModuleGraph.Unit,

pub fn block(ptr: *anyopaque, name: ast.OperatorName) ?Parser.BlockLookup.Definition {
    const context: *MixfixContext = @ptrCast(@alignCast(ptr));
    const unit = context.unit;
    const scope = unit.scopeAt(name.span.start);
    const identity = if (name.namespace) |namespace| resolved: {
        const owner = context.graph.resolveNamespaceAt(unit, scope, namespace, name.span.start) orelse return null;
        const symbol_ = context.graph.units.items[owner].public_names.get(name.name) orelse return null;
        break :resolved symbol_.identity;
    } else resolved: {
        const callable = unit.resolverAt(name.span.start).callable(scope, name.name);
        if (callable.shadowed) return null;
        break :resolved (callable.member orelse return null).identity;
    };
    if (identity.kind != .block) return null;
    const owner = context.graph.units.items[identity.module];
    for (owner.headers.expansions) |header| if (std.mem.eql(u8, header.statement.value.expand_block.name, identity.name))
        return .{ .statement = header.statement, .module = identity.module };
    return null;
}

pub fn enterBlock(ptr: *anyopaque, definition: Parser.BlockLookup.Definition, scope: Parser.ScopeId) !void {
    const context: *MixfixContext = @ptrCast(@alignCast(ptr));
    const owner = context.graph.units.items[definition.module];
    var source_scope: ?Parser.ScopeId = null;
    for (owner.headers.expansions) |header| if (header.statement == definition.statement) {
        source_scope = header.scope;
        break;
    };
    const origin = source_scope orelse return;
    const insertion = owner.headers.scopes[origin].insertion orelse return;
    var scopes: std.ArrayList(Parser.ScopeId) = .empty;
    var current: ?Parser.ScopeId = owner.scopeAt(insertion);
    while (current) |id| : (current = owner.headers.scopes[id].parent) {
        try scopes.append(context.graph.syntax, id);
        if (id == origin) break;
    }
    var injected: lexical.Symbols = .{};
    var remaining = scopes.items.len;
    while (remaining != 0) {
        remaining -= 1;
        const id = scopes.items[remaining];
        for (owner.headers.scopes[id].ordinary_names) |name| {
            const symbol_ = try context.graph.syntax.create(lexical.Symbol);
            symbol_.* = .{ .local = .{ .span = name.span, .module = owner.index } };
            try injected.put(context.graph.syntax, name.name, symbol_);
        }
        var bound = owner.scopes[id].iterator();
        while (bound.next()) |entry| {
            var symbol_ = owner.resolverAt(insertion).symbolAt(id, entry.key_ptr.*) orelse continue;
            if (injected.get(entry.key_ptr.*)) |earlier| {
                if (symbol_.local == null and symbol_.value == null and symbol_.callable == null) symbol_.local = earlier.local;
            }
            for (&symbol_.mixfix) |*form| if (form.*) |value| {
                const copy = try context.graph.syntax.create(ast.MixfixForm);
                copy.* = value.*;
                if (copy.group.module == null) copy.group.module = owner.index;
                form.* = copy;
            };
            for (&symbol_.operators) |*binding| if (binding.*) |*value| {
                value.since = 0;
            };
            symbol_.value_since = 0;
            symbol_.callable_since = 0;
            symbol_.type_since = 0;
            symbol_.precedence_since = 0;
            const value = try context.graph.syntax.create(lexical.Symbol);
            value.* = symbol_;
            try injected.put(context.graph.syntax, entry.key_ptr.*, value);
        }
    }
    var bindings = injected.iterator();
    while (bindings.next()) |entry| {
        const span = context.unit.headers.scopes[scope].body;
        const destination = try symbols.symbol(context.graph, context.unit, scope, entry.key_ptr.*);
        var incoming = entry.value_ptr.*.*;
        if (incoming.hasName()) {
            try symbols.checkOrdinary(context.graph, context.unit, scope, entry.key_ptr.*, span);
            if (destination.hasName())
                return context.graph.fail(context.unit, span, "duplicate block binding '{s}'", .{entry.key_ptr.*});
        }
        inline for (.{ "mixfix", "operators" }) |field| for (&@field(incoming, field), @field(destination.*, field)) |*binding, local| {
            if (local != null and binding.* != null)
                return context.graph.fail(context.unit, span, "duplicate mixfix binding '{s}'", .{entry.key_ptr.*});
            if (binding.* == null) binding.* = local;
        };
        if (incoming.hasName()) destination.* = incoming else {
            destination.mixfix = incoming.mixfix;
            destination.operators = incoming.operators;
        }
    }
}

pub fn lookup(opaque_context: *anyopaque, name: ast.OperatorName, leading: bool) ?Parser.MixfixLookup.Binding {
    const context: *MixfixContext = @ptrCast(@alignCast(opaque_context));
    const id = context.unit.scopeAt(name.span.start);
    const resolver_ = context.unit.resolverAt(name.span.start);
    const index = @intFromBool(leading);
    if (name.namespace) |alias| {
        if (context.graph.resolveNamespaceAt(context.unit, id, alias, name.span.start)) |module| {
            return context.graph.units.items[module].publicTemplate(name.name, index);
        }
        if (resolver_.readable(id, alias) != null) return null;
    } else {
        if (resolver_.operator(id, name.name, leading)) |binding| {
            if (binding.qualified) |qualified| return .{ .form = binding.form.*, .target = binding.name, .qualified = qualified };
            const call = resolver_.callable(id, binding.name);
            const form = call.mixfix[index] orelse (if (call.member) |member| member.mixfix[index] else null) orelse return null;
            if (std.mem.eql(u8, form.head, name.name)) return .{ .form = form.*, .target = binding.name };
        }
    }
    const options = context.graph.options;
    if (options.mixfix) |fallback| return fallback.lookup(name, leading);
    return null;
}

test "module graph exposes only exported prefix declarations while parsing callers" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            if (!std.mem.eql(u8, path, "library")) return error.UnknownModule;
            return .{ .name = "library.huak", .source =
            \\mixfix(wrap) wrap _ in addition
            \\export wrap
            \\fn wrap(x:int)->int;return x;end
            \\mixfix(hidden) hidden _ in addition
            \\fn hidden(x:int)->int;return x;end
            };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    const memory = arena.allocator();
    const resolver: ModuleGraph.ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    var graph = ModuleGraph.init(memory, memory, .{}, resolver, &diagnostic);
    try graph.root("root.huak", "import \"library\" as lib\nx:=lib.wrap 2+3\ny:=lib.wrap(4)\n");
    const script = graph.units.items[0].script;
    const call = script.statements[1].value.assignment.value.value.mixfix_call;
    try std.testing.expectEqualStrings("lib", call.operator.namespace.?);
    try std.testing.expectEqualStrings("wrap", call.operator.name);
    try std.testing.expect(script.statements[2].value.assignment.value.value.call.dot);
    const library = graph.units.items[1];
    const form = &library.headers.operators[0].statement.value.mixfix_binding.form;
    try std.testing.expect(library.scopes[0].get("wrap").?.mixfix[0].? == form);
    try std.testing.expect(library.public_names.get("wrap").?.mixfix[0].? == form);
    var private_graph = ModuleGraph.init(memory, memory, .{}, resolver, &diagnostic);
    try std.testing.expectError(error.LanguageError, private_graph.root("private.huak", "import \"library\" as lib\nx:=lib.hidden 2\n"));
    try std.testing.expectEqualStrings("private.huak", diagnostic.?.fileName().?);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position("").line);
}

test "lexical function imports replace prefix roles and imported data shadows calls" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            if (std.mem.eql(u8, path, "prefix")) return .{ .name = "prefix.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int return x end" };
            if (std.mem.eql(u8, path, "ordinary")) return .{ .name = "ordinary.huak", .source = "export fn wrap(a:int,b:int)->int return a+b end" };
            return .{ .name = "data.huak", .source = "export wrap:=7" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "prefix".wrap as act
        \\if true then
        \\    import "ordinary".wrap as act
        \\    inside:=act (2,3)
        \\end
        \\if true then
        \\    import "data".wrap as act
        \\    mixed:=act
        \\end
        \\outside:=wrap 5
    );
    const script = graph.units.items[0].script;
    const ordinary = script.statements[1].value.conditional.branches[0].body[1].value.assignment.value;
    try std.testing.expect(ordinary.value == .call);
    try std.testing.expectEqual(@as(usize, 2), ordinary.value.call.args.len);
    const mixed = script.statements[2].value.conditional.branches[0].body[1].value.assignment.value;
    try std.testing.expect(mixed.value == .name);
    const unit = graph.units.items[0];
    try std.testing.expect(unit.resolverAt(mixed.span.start).callable(unit.scopeAt(mixed.span.start), "act").shadowed);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .mixfix_call);
}

test "whole function data bindings shadow outer namespaces during prefix parsing" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ModuleGraph.ResolvedSource {
            return .{ .name = "library.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int return x end" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "library" as lib
        \\fn parameter(lib:any)->any return lib.wrap+1 end
        \\fn local()->any
        \\    before:=lib.wrap+1
        \\    lib:=7
        \\    return before
        \\end
    );
    const script = graph.units.items[0].script;
    const parameter = script.statements[1].value.function.body[0].value.return_value.?;
    const local = script.statements[2].value.function.body[0].value.assignment.value;
    for ([_]*ast.Expr{ parameter, local }) |expression| {
        try std.testing.expect(expression.value == .binary);
        try std.testing.expect(expression.value.binary.left.value == .member);
    }
}
