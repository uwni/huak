//! Compile-time lexical names. Variables, imports and operator roles belong
//! to the block which declares them; runtime values live in activation slots.
const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("Parser.zig");

pub const Kind = enum { value, function, block, record, builtin, precedence, namespace, unknown };
pub const Identity = struct { module: u32, name: []const u8, kind: Kind };
/// Forms borrow immutable declaration headers in the graph's syntax arena.
pub const Member = struct { module: u32, name: []const u8, identity: Identity, mixfix: [2]?*const ast.MixfixForm = .{ null, null }, initializer: u32 = std.math.maxInt(u32) };
pub const Value = union(enum) { member: Member, namespace: u32 };
pub const Symbol = struct {
    operators: [2]?Operator = .{ null, null },
    /// An expanded block's local declaration lives in its defining module.
    local: ?struct { span: ast.Span, module: u32 } = null,
    value: ?Value = null,
    namespace_initializer: ?u32 = null,
    callable: ?Member = null,
    type_symbol: ?Member = null,
    precedence: ?Member = null,
    mixfix: [2]?*const ast.MixfixForm = .{ null, null },
    value_since: usize = 0,
    callable_since: usize = 0,
    type_since: usize = 0,
    precedence_since: usize = 0,

    pub fn hasName(self: Symbol) bool {
        return self.local != null or self.value != null or self.callable != null or self.type_symbol != null or self.precedence != null;
    }
};
pub const Operator = struct { name: []const u8, form: *const ast.MixfixForm, since: usize = 0, qualified: ?*const ast.MixfixBinding = null };
/// Entries live in the syntax arena, so map growth never moves a symbol.
pub const Symbols = std.StringHashMapUnmanaged(*Symbol);
pub const Readable = union(enum) { ordinary: struct { scope: Parser.ScopeId, span: ast.Span, module: ?u32 = null }, imported: Value };
/// Resolved metadata borrows arena-owned symbols until they are mutated or
/// the graph is released. Visibility and namespace provenance are values.
pub const Callable = struct { member: ?*const Member = null, mixfix: [2]?*const ast.MixfixForm = .{ null, null }, shadowed: bool = false, namespace: ?u32 = null, namespace_initializer: ?u32 = null };

pub const Resolver = struct {
    headers: *const Parser.Headers,
    symbols: []const Symbols,
    position: usize = std.math.maxInt(usize),

    pub fn operator(self: Resolver, initial: Parser.ScopeId, name: []const u8, leading: bool) ?Operator {
        var scope: ?Parser.ScopeId = initial;
        while (scope) |id| : (scope = self.headers.scopes[id].parent) {
            if (self.symbols[id].get(name)) |symbol| if (symbol.operators[@intFromBool(leading)]) |binding| {
                if (self.position >= binding.since) return binding;
            };
        }
        return null;
    }

    pub fn symbolAt(self: Resolver, id: Parser.ScopeId, name: []const u8) ?Symbol {
        var symbol = (self.symbols[id].get(name) orelse return null).*;
        if (self.position < symbol.value_since) symbol.value = null;
        if (self.position < symbol.callable_since) symbol.callable = null;
        if (self.position < symbol.type_since) symbol.type_symbol = null;
        if (self.position < symbol.precedence_since) symbol.precedence = null;
        for (&symbol.operators) |*binding| if (binding.*) |value| {
            if (self.position < value.since) binding.* = null;
        };
        if (!symbol.hasName() and
            symbol.mixfix[0] == null and symbol.mixfix[1] == null and symbol.operators[0] == null and symbol.operators[1] == null) return null;
        return symbol;
    }

    pub fn readable(self: Resolver, initial: Parser.ScopeId, name: []const u8) ?Readable {
        var scope: ?Parser.ScopeId = initial;
        while (scope) |id| {
            const lexical = &self.headers.scopes[id];
            for (lexical.ordinary_names) |ordinary| if (std.mem.eql(u8, name, ordinary.name) and !ordinary.initializingAt(self.position)) return .{ .ordinary = .{ .scope = id, .span = ordinary.span } };
            if (self.symbols[id].get(name)) |symbol| {
                if (symbol.local) |local| return .{ .ordinary = .{ .scope = id, .span = local.span, .module = local.module } };
                if (self.position >= symbol.value_since) if (symbol.value) |value| return .{ .imported = value };
            }
            scope = lexical.parent;
        }
        return null;
    }

    pub fn namespace(self: Resolver, initial: Parser.ScopeId, name: []const u8) ?u32 {
        const value = self.readable(initial, name) orelse return null;
        return if (value == .imported and value.imported == .namespace) value.imported.namespace else null;
    }

    /// The binding's owner can differ from its canonical namespace target.
    pub fn namespaceInitializer(self: Resolver, initial: Parser.ScopeId, name: []const u8) ?u32 {
        var scope: ?Parser.ScopeId = initial;
        while (scope) |id| {
            for (self.headers.scopes[id].ordinary_names) |ordinary| if (std.mem.eql(u8, name, ordinary.name) and !ordinary.initializingAt(self.position)) return null;
            if (self.symbols[id].get(name)) |symbol| if (self.position >= symbol.value_since) {
                if (symbol.local != null) return null;
                if (symbol.value) |value| return if (value == .namespace) symbol.namespace_initializer else null;
            };
            scope = self.headers.scopes[id].parent;
        }
        return null;
    }

    pub fn callable(self: Resolver, initial: Parser.ScopeId, name: []const u8) Callable {
        var result: Callable = .{};
        var scope: ?Parser.ScopeId = initial;
        scopes: while (scope) |id| {
            for (self.headers.scopes[id].ordinary_names) |ordinary| if (std.mem.eql(u8, name, ordinary.name)) {
                if (ordinary.initializingAt(self.position)) {
                    scope = self.headers.scopes[id].parent;
                    continue :scopes;
                }
                if (self.symbols[id].get(name)) |symbol| for (0..2) |index| {
                    if (result.mixfix[index] == null) result.mixfix[index] = symbol.mixfix[index];
                };
                result.shadowed = true;
                return result;
            };
            if (self.symbols[id].get(name)) |symbol| {
                if (symbol.local != null) {
                    for (0..2) |index| if (result.mixfix[index] == null) {
                        result.mixfix[index] = symbol.mixfix[index];
                    };
                    result.shadowed = true;
                    return result;
                }
                const member: ?*const Member = if (self.position >= symbol.callable_since) (if (symbol.callable) |*value| value else null) else null;
                if (if (self.position >= symbol.value_since) symbol.value else null) |value| {
                    if (value == .member) return .{ .shadowed = true };
                    result.namespace = value.namespace;
                    result.namespace_initializer = symbol.namespace_initializer;
                    if (member == null) return .{ .namespace = result.namespace, .namespace_initializer = result.namespace_initializer };
                }
                for (0..2) |index| if (result.mixfix[index] == null) {
                    result.mixfix[index] = symbol.mixfix[index];
                };
                if (member) |found| {
                    result.member = found;
                    return result;
                }
            }
            scope = self.headers.scopes[id].parent;
        }
        return result;
    }

    pub fn precedence(self: Resolver, initial: Parser.ScopeId, name: []const u8) ?Member {
        var scope: ?Parser.ScopeId = initial;
        while (scope) |id| {
            if (self.symbols[id].get(name)) |symbol| if (self.position >= symbol.precedence_since) {
                if (symbol.precedence) |member| return member;
            };
            scope = self.headers.scopes[id].parent;
        }
        return null;
    }

    /// Types have their own lexical channel, just as ordinary values and
    /// callable names do. An imported alias retains the declaration identity.
    pub fn typeSymbol(self: Resolver, initial: Parser.ScopeId, name: []const u8) ?Member {
        var scope: ?Parser.ScopeId = initial;
        while (scope) |id| {
            if (self.symbols[id].get(name)) |symbol| if (self.position >= symbol.type_since) {
                if (symbol.type_symbol) |member| return member;
            };
            scope = self.headers.scopes[id].parent;
        }
        return null;
    }
};

pub fn sameIdentity(a: Identity, b: Identity) bool {
    return a.module == b.module and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
}

test "callable lookup retains namespace provenance and constructor roles only at their visible binding" {
    const t = std.testing;
    var scopes = [_]Parser.Scope{
        .{ .parent = null, .kind = .module, .body = .{ .start = 0, .end = 500 }, .ordinary_names = &.{} },
        .{ .parent = 0, .kind = .branch, .body = .{ .start = 100, .end = 400 }, .ordinary_names = &.{} },
    };
    const headers: Parser.Headers = .{ .scopes = &scopes, .imports = &.{}, .operators = &.{} };
    var symbols = [_]Symbols{ .{}, .{} };
    defer for (&symbols) |*table| table.deinit(t.allocator);
    const constructor: Member = .{ .module = 7, .name = "pen", .identity = .{ .module = 7, .name = "pen", .kind = .builtin }, .mixfix = .{ &.{ .head = "pen", .parts = &.{null}, .group = .{ .name = "unary", .span = .{ .start = 1, .end = 2 } } }, null }, .initializer = 5 };
    var outer_symbol: Symbol = .{
        .value = .{ .namespace = 7 },
        .namespace_initializer = 5,
        .callable = constructor,
        .callable_since = 50,
        .mixfix = .{
            &.{ .head = "pen", .parts = &.{ "with", null }, .group = .{ .name = "unary", .span = .{ .start = 5, .end = 6 } } },
            &.{ .head = "pen", .parts = &.{null}, .group = .{ .name = "addition", .span = .{ .start = 3, .end = 4 } }, .leading = true },
        },
    };
    var inner_symbol: Symbol = .{ .value = .{ .namespace = 9 }, .namespace_initializer = 8, .value_since = 200 };
    try symbols[0].put(t.allocator, "pen", &outer_symbol);
    try symbols[1].put(t.allocator, "pen", &inner_symbol);
    var resolver: Resolver = .{ .headers = &headers, .symbols = &symbols, .position = 25 };
    const before_constructor = resolver.callable(0, "pen");
    try t.expectEqual(@as(?u32, 7), before_constructor.namespace);
    try t.expectEqual(@as(?u32, 5), before_constructor.namespace_initializer);
    try t.expect(before_constructor.member == null and before_constructor.mixfix[0] == null);
    resolver.position = 150;
    const outer = resolver.callable(1, "pen");
    try t.expectEqualDeep(constructor, outer.member.?.*);
    try t.expect(outer.member.? == &outer_symbol.callable.?);
    try t.expectEqual(@as(?u32, 7), outer.namespace);
    try t.expectEqual(@as(?u32, 5), outer.namespace_initializer);
    try t.expect(outer.mixfix[0].? == outer_symbol.mixfix[0].?);
    try t.expect(outer.mixfix[1].? == outer_symbol.mixfix[1].?);
    resolver.position = 200;
    const inner = resolver.callable(1, "pen");
    try t.expectEqual(@as(?u32, 9), inner.namespace);
    try t.expectEqual(@as(?u32, 8), inner.namespace_initializer);
    try t.expect(inner.member == null and inner.mixfix[0] == null and !inner.shadowed);
    var ordinary = [_]Parser.Local{.{ .name = "pen", .span = .{ .start = 110, .end = 113 } }};
    scopes[1].ordinary_names = &ordinary;
    const data = resolver.callable(1, "pen");
    try t.expect(data.shadowed and data.member == null and data.namespace == null and data.namespace_initializer == null);
    resolver.position = 25;
    try t.expect(resolver.symbolAt(0, "pen").?.callable == null);
    resolver.position = 150;
    const snapshot = resolver.symbolAt(0, "pen").?;
    outer_symbol.callable.?.mixfix[0] = null;
    try t.expect(snapshot.callable.?.mixfix[0] != null);
}
