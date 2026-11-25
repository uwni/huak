//! Binding names into a unit's symbol tables, and the conflict rules between declarations, imports and operators.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const builtins = @import("../builtin.zig");
const lexical = @import("../scope.zig");
const ModuleGraph = @import("../ModuleGraph.zig");

pub fn symbol(self: *ModuleGraph, unit: *ModuleGraph.Unit, id: Parser.ScopeId, name: []const u8) !*lexical.Symbol {
    const table = &unit.scopes[id];
    const entry = try table.getOrPut(self.syntax, name);
    if (!entry.found_existing) {
        errdefer _ = table.remove(name);
        const stored = try self.syntax.create(lexical.Symbol);
        stored.* = .{};
        entry.value_ptr.* = stored;
    }
    return entry.value_ptr.*;
}

pub fn checkOrdinary(self: *ModuleGraph, unit: *ModuleGraph.Unit, id: Parser.ScopeId, name: []const u8, span: source.Span) !void {
    for (unit.headers.scopes[id].ordinary_names) |ordinary| if (std.mem.eql(u8, name, ordinary.name))
        return self.fail(unit, span, "name '{s}' conflicts with an imported binding in the same scope", .{name});
}

pub fn bindNamespace(self: *ModuleGraph, unit: *ModuleGraph.Unit, id: Parser.ScopeId, alias: []const u8, target: u32, initializer: u32, span: source.Span) !void {
    try checkOrdinary(self, unit, id, alias, span);
    const entry = try symbol(self, unit, id, alias);
    if (entry.callable) |callable| try checkNamespaceCallable(self, unit, target, alias, callable.identity, span);
    if (entry.value) |earlier| {
        if (earlier != .namespace or earlier.namespace != target) return self.fail(unit, span, "duplicate import namespace '{s}'", .{alias});
        if (span.end < entry.value_since) entry.namespace_initializer = initializer;
        entry.value_since = @min(entry.value_since, span.end);
    } else {
        entry.value = .{ .namespace = target };
        entry.namespace_initializer = initializer;
        entry.value_since = span.end;
    }
}

fn checkNamespaceCallable(self: *ModuleGraph, unit: *ModuleGraph.Unit, target: u32, name: []const u8, identity: lexical.Identity, span: source.Span) !void {
    const native = self.units.items[target].native_namespace;
    const constructor = if (native) |namespace| builtins.namespaceConstructor(namespace, name) else null;
    if (constructor == null or identity.kind != .builtin or !std.mem.eql(u8, @tagName(constructor.?.id), identity.name))
        return self.fail(unit, span, "namespace '{s}' conflicts with callable binding", .{name});
}

pub fn bindRecord(self: *ModuleGraph, unit: *ModuleGraph.Unit, id: Parser.ScopeId, statement: *const ast.Stmt) !void {
    const declaration = statement.value.structure;
    const entry = try symbol(self, unit, id, declaration.name);
    if (entry.callable != null or entry.type_symbol != null)
        return self.fail(unit, statement.span, "duplicate struct '{s}'", .{declaration.name});
    const member: lexical.Member = .{
        .module = unit.index,
        .name = declaration.name,
        .identity = .{ .module = unit.index, .name = declaration.name, .kind = .record },
    };
    entry.callable = member;
    entry.type_symbol = member;
}

pub fn bindMember(self: *ModuleGraph, unit: *ModuleGraph.Unit, id: Parser.ScopeId, alias: []const u8, target: u32, initializer: u32, name: []const u8, exposed: ModuleGraph.PublicSymbol, span: source.Span) !void {
    const member: lexical.Member = .{ .module = target, .name = name, .identity = exposed.identity, .mixfix = exposed.mixfix, .initializer = initializer };
    const entry = try symbol(self, unit, id, alias);
    switch (exposed.identity.kind) {
        .namespace => try bindNamespace(self, unit, id, alias, exposed.identity.module, initializer, span),
        .function, .block, .record, .builtin => {
            if (entry.value) |value| if (value == .namespace) try checkNamespaceCallable(self, unit, value.namespace, alias, exposed.identity, span);
            if (entry.callable) |earlier| {
                if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                if (!sameMixfixParts(earlier.mixfix, exposed.mixfix)) return self.fail(unit, span, "conflicting imported mixfix forms for '{s}'", .{alias});
                entry.callable_since = @min(entry.callable_since, span.end);
            } else {
                entry.callable = member;
                entry.callable_since = span.end;
            }
            if (exposed.identity.kind == .record) {
                if (entry.type_symbol) |earlier| {
                    if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported type '{s}'", .{alias});
                    entry.type_since = @min(entry.type_since, span.end);
                } else {
                    entry.type_symbol = member;
                    entry.type_since = span.end;
                }
            }
        },
        .precedence => {
            if (entry.precedence) |earlier| {
                if (!lexical.sameIdentity(earlier.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                entry.precedence_since = @min(entry.precedence_since, span.end);
            } else {
                entry.precedence = member;
                entry.precedence_since = span.end;
            }
        },
        .value, .unknown => {
            try checkOrdinary(self, unit, id, alias, span);
            if (entry.value) |earlier| {
                if (earlier != .member or !lexical.sameIdentity(earlier.member.identity, exposed.identity)) return self.fail(unit, span, "conflicting imported name '{s}'", .{alias});
                entry.value_since = @min(entry.value_since, span.end);
            } else {
                entry.value = .{ .member = member };
                entry.value_since = span.end;
            }
        },
    }
    for (exposed.mixfix) |form| if (form) |value| try bindOperator(self, unit, id, .{ .name = alias, .form = value, .since = span.end }, span);
}

pub fn bindOperator(self: *ModuleGraph, unit: *ModuleGraph.Unit, scope: Parser.ScopeId, binding: lexical.Operator, span: source.Span) !void {
    const spelling = binding.form.head;
    const entry = try symbol(self, unit, scope, spelling);
    const role = &entry.operators[@intFromBool(binding.form.leading)];
    if (role.*) |earlier| {
        if (earlier.form == binding.form) {
            if (binding.since < earlier.since) role.* = binding;
            return;
        }
        if (earlier.qualified != null or binding.qualified != null or !std.mem.eql(u8, earlier.name, binding.name))
            return self.fail(unit, span, "conflicting mixfix operator '{s}'", .{spelling});
        if (binding.since >= earlier.since) return;
    }
    role.* = binding;
}

fn sameMixfixParts(left: [2]?*const ast.MixfixForm, right: [2]?*const ast.MixfixForm) bool {
    for (left, right) |one, two| {
        if (one == null or two == null) {
            if (one != null or two != null) return false;
            continue;
        }
        if (one.?.parts.len != two.?.parts.len) return false;
        if (!std.mem.eql(u8, one.?.head, two.?.head)) return false;
        for (one.?.parts, two.?.parts) |a, b| {
            if (a == null or b == null) {
                if (a != null or b != null) return false;
            } else if (!std.mem.eql(u8, a.?, b.?)) return false;
        }
    }
    return true;
}

test "same function imported with different prefix roles is rejected in either order" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            if (std.mem.eql(u8, path, "base")) return .{ .name = "base.huak", .source = "export fn f(x:int)->int return x end" };
            return .{ .name = "bridge.huak", .source = "import \"base\".f;mixfix(f) f _ in unary;export f" };
        }
    };
    for ([_][]const u8{ "import \"base\".f;import \"bridge\".f", "import \"bridge\".f;import \"base\".f" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var context: u8 = 0;
        var diagnostic: ?source.Diagnostic = null;
        var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
        try std.testing.expectError(error.LanguageError, graph.root("root.huak", input));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicting imported mixfix forms") != null);
    }
}

test "imports become visible after declarations and preserve earlier outer bindings" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ModuleGraph.ResolvedSource {
            if (std.mem.eql(u8, path, "outer")) return .{ .name = "outer.huak", .source = "mixfix(wrap) wrap _ in unary;export fn wrap(x:int)->int;return x;end" };
            if (std.mem.eql(u8, path, "inner")) return .{ .name = "inner.huak", .source = "export fn wrap(x:int,y:int)->int;return x+y;end" };
            return .{ .name = "data.huak", .source = "export wrap:=7" };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var context: u8 = 0;
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try graph.root("root.huak",
        \\import "outer".wrap as act
        \\if true then
        \\    before:=wrap 1
        \\    import "inner".wrap as act
        \\    after:=act(2,3)
        \\end
        \\if true then
        \\    before:=wrap 4
        \\    import "data".wrap as act
        \\    after:=act
        \\end
    );
    const unit = graph.units.items[0];
    try std.testing.expect(unit.resolverAt(0).callable(0, "act").member == null);
    const outer = unit.resolverAt(unit.imports.items[0].span.end).callable(0, "act").member.?.identity;
    for (unit.script.statements[1..]) |conditional| {
        const body = conditional.value.conditional.branches[0].body;
        const before = body[0].value.assignment.value;
        const after = body[2].value.assignment.value;
        const id = unit.scopeAt(before.span.start);
        try std.testing.expect(before.value == .mixfix_call);
        try std.testing.expect(lexical.sameIdentity(outer, unit.resolverAt(before.span.start).callable(id, "act").member.?.identity));
        const selected = unit.resolverAt(after.span.start).callable(id, "act");
        if (after.value == .call) {
            try std.testing.expect(!selected.shadowed);
            try std.testing.expect(!lexical.sameIdentity(outer, selected.member.?.identity));
        } else {
            try std.testing.expect(after.value == .name);
            try std.testing.expect(selected.shadowed);
            try std.testing.expect(selected.member == null);
        }
    }
    var rejected = ModuleGraph.init(arena.allocator(), arena.allocator(), .{}, .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } }, &diagnostic);
    try std.testing.expectError(error.LanguageError, rejected.root("early.huak", "value:=act 2;import \"outer\".wrap as act"));
}

test "symbol storage survives map growth and rolls back failed allocation" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    const memory = failing.allocator();
    var tables = [_]lexical.Symbols{.{}};
    defer {
        var values = tables[0].valueIterator();
        while (values.next()) |stored| memory.destroy(stored.*);
        tables[0].deinit(memory);
    }
    var unit: ModuleGraph.Unit = .{
        .index = 0,
        .name = "symbols.huak",
        .source_text = "",
        .script = .{ .statements = &.{} },
        .headers = .{ .scopes = &.{}, .imports = &.{}, .operators = &.{} },
        .scopes = &tables,
    };
    var diagnostic: ?source.Diagnostic = null;
    var graph = ModuleGraph.init(memory, memory, .{}, null, &diagnostic);
    try t.expectError(error.OutOfMemory, symbol(&graph, &unit, 0, "first"));
    try t.expectEqual(@as(u32, 0), tables[0].count());

    // The table allocation succeeds, but allocating the new symbol fails.
    failing.fail_index = 1;
    try t.expectError(error.OutOfMemory, symbol(&graph, &unit, 0, "first"));
    try t.expect(tables[0].capacity() != 0);
    try t.expectEqual(@as(u32, 0), tables[0].count());
    try t.expect(tables[0].get("first") == null);

    failing.fail_index = std.math.maxInt(usize);
    const first = try symbol(&graph, &unit, 0, "first");
    first.value = .{ .namespace = 7 };
    const initial_capacity = tables[0].capacity();
    var names: [32][16]u8 = undefined;
    for (&names, 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "symbol-{d}", .{index});
        _ = try symbol(&graph, &unit, 0, name);
    }
    try t.expect(tables[0].capacity() > initial_capacity);
    try t.expect(first == try symbol(&graph, &unit, 0, "first"));
    try t.expectEqual(@as(u32, 7), first.value.?.namespace);
}
